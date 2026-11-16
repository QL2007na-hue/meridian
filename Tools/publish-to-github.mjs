#!/usr/bin/env node
// Meridian — publish to GitHub without git.
//
// The development machine has no git. That is not a limitation here: the
// GitHub REST API can create the repository, write every file as a blob, build
// one tree, commit it and move `main` in five requests — instead of one
// PUT /contents per file, which would turn a 40-file project into 40 commits
// and 40 chances to fail halfway.
//
// Then it triggers the iOS workflow, polls the run, and downloads the unsigned
// IPA straight from the Release that build.yml creates. No artifact zip to
// unpack, no S3 console, no `gh` CLI.
//
// Usage
//   GITHUB_TOKEN=ghp_xxx node Tools/publish-to-github.mjs
//
// Environment
//   GITHUB_TOKEN    required (classic PAT, scopes: repo + workflow)
//   GITHUB_OWNER    default: the token's /user login
//   GITHUB_REPO     default: meridian
//   GITHUB_PRIVATE  1 → create the repository as private
//   GITHUB_API      default: https://api.github.com (GitHub Enterprise)
//
//   node Tools/publish-to-github.mjs --dry-run   # no network, lists the files
//
// Exit codes: 0 success (IPA downloaded), 1 failure (logs printed), 2 timeout.

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import https from 'node:https';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const API = process.env.GITHUB_API || 'https://api.github.com';
const TOKEN = process.env.GITHUB_TOKEN || '';
const UA = 'meridian-publish/1.0 (+https://github.com)';

const POLL_MS = 8_000;
const POLL_MAX_MS = 35 * 60 * 1000;

// Directories and files that never belong in the repository. Kept in sync with
// .gitignore: the generated .xcodeproj, build output and local caches.
const SKIP_DIRS = new Set([
  '.git',
  '.DS_Store',
  'node_modules',
  'build',
  'out',
  'DerivedData',
  '.build',
  '.swiftpm',
  '__pycache__',
  '.venv',
  '.idea',
]);
const SKIP_FILE_RE = [/\.log$/i, /\.ipa$/i, /\.xcarchive$/i, /^\.DS_Store$/i, /^Thumbs\.db$/i];
// Runtime state written by a local server run — machine-specific, never shared.
const SKIP_PATH_RE = [/^server\/data\.json$/, /^server\/data\//, /^build\//];
const BINARY_RE = /\.(png|jpe?g|gif|webp|heic|ico|pdf|zip|ipa|p12|mobileprovision|otf|ttf|woff2?|mp4|mov|mp3)$/i;

const args = new Set(process.argv.slice(2));
const DRY_RUN = args.has('--dry-run');

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------

const started = Date.now();
function log(message) {
  const elapsed = ((Date.now() - started) / 1000).toFixed(1).padStart(5);
  console.log(`[${elapsed}s] ${message}`);
}
function warn(message) {
  console.warn(`[warn] ${message}`);
}
function die(message, code = 1) {
  console.error(`\n✗ ${message}`);
  process.exit(code);
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------

class ApiError extends Error {
  constructor(method, pathname, status, payload) {
    const detail = payload?.message ? ` — ${payload.message}` : '';
    super(`${method} ${pathname} → HTTP ${status}${detail}`);
    this.status = status;
    this.payload = payload;
  }
}

function request(url, { method = 'GET', headers = {}, body = null } = {}) {
  return new Promise((resolve, reject) => {
    const target = new URL(url);
    const requestHeaders = { 'User-Agent': UA, ...headers };
    if (body !== null) requestHeaders['Content-Length'] = Buffer.byteLength(body);

    const req = https.request(
      {
        protocol: target.protocol,
        hostname: target.hostname,
        port: target.port || 443,
        path: target.pathname + target.search,
        method,
        headers: requestHeaders,
        timeout: 60_000,
      },
      (res) => {
        const chunks = [];
        res.on('data', (chunk) => chunks.push(chunk));
        res.on('end', () =>
          resolve({ status: res.statusCode, headers: res.headers, buffer: Buffer.concat(chunks) }),
        );
      },
    );
    req.on('timeout', () => req.destroy(new Error(`timeout ${method} ${url}`)));
    req.on('error', reject);
    if (body !== null) req.write(body);
    req.end();
  });
}

/** Follows GitHub's 302 → signed S3 URL redirects, dropping the token off-host. */
async function requestFollow(url, { headers = {}, maxHops = 10 } = {}) {
  let current = url;
  let currentHeaders = { 'User-Agent': UA, ...headers };
  for (let hop = 0; hop <= maxHops; hop += 1) {
    const res = await request(current, { headers: currentHeaders });
    const location = res.headers.location;
    if ([301, 302, 303, 307, 308].includes(res.status) && location) {
      const next = new URL(location, current);
      if (next.hostname !== new URL(current).hostname) delete currentHeaders.Authorization;
      current = next.toString();
      continue;
    }
    return { ...res, url: current };
  }
  throw new Error(`too many redirects from ${url}`);
}

async function api(method, pathname, { body, accept = 'application/vnd.github+json' } = {}) {
  const headers = {
    Authorization: `Bearer ${TOKEN}`,
    Accept: accept,
    'X-GitHub-Api-Version': '2022-11-28',
  };
  let payload;
  if (body !== undefined) {
    payload = JSON.stringify(body);
    headers['Content-Type'] = 'application/json';
  }
  const res = await request(`${API}${pathname}`, { method, headers, body: payload ?? null });
  const text = res.buffer.toString('utf8');
  let json = null;
  try {
    json = text ? JSON.parse(text) : null;
  } catch {
    json = null;
  }
  if (res.status >= 400) throw new ApiError(method, pathname, res.status, json);
  return json;
}

/** Like api(), but returns null on 404 instead of throwing. */
async function apiOrNull(method, pathname, options) {
  try {
    return await api(method, pathname, options);
  } catch (error) {
    // 404 = no such thing; 409 = repository exists but has no commits yet
    // ("Git Repository is empty"), which is the normal state of a repo this
    // script just created. Both mean "nothing there".
    if (error instanceof ApiError && (error.status === 404 || error.status === 409)) return null;
    throw error;
  }
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// ---------------------------------------------------------------------------
// Local tree
// ---------------------------------------------------------------------------

function collectFiles(dir, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    // Skip the repository metadata directory only. `.github/` and `.gitignore`
    // start with the same three characters and are part of the project — the
    // Actions workflow lives in `.github/workflows/`.
    if (entry.name === '.git') continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (SKIP_DIRS.has(entry.name) || entry.name.endsWith('.xcodeproj')) continue;
      collectFiles(full, out);
      continue;
    }
    if (!entry.isFile()) continue;
    if (SKIP_FILE_RE.some((re) => re.test(entry.name))) continue;
    out.push(full);
  }
  return out;
}

function gitBlobSha(buffer) {
  return crypto.createHash('sha1').update(`blob ${buffer.length}\0`).update(buffer).digest('hex');
}

function isBinary(buffer, filename) {
  if (BINARY_RE.test(filename)) return true;
  const sample = buffer.subarray(0, 8000);
  return sample.includes(0);
}

function plan() {
  const files = collectFiles(ROOT)
    .map((full) => {
      const buffer = fs.readFileSync(full);
      return {
        path: path.relative(ROOT, full).split(path.sep).join('/'),
        full,
        size: buffer.length,
        sha: gitBlobSha(buffer),
        binary: isBinary(buffer, full),
        buffer,
      };
    })
    .filter((file) => !SKIP_PATH_RE.some((re) => re.test(file.path)))
    .sort((a, b) => a.path.localeCompare(b.path));

  if (files.length === 0) die(`没有可提交的文件：${ROOT}`);
  const total = files.reduce((sum, file) => sum + file.size, 0);
  return { files, total };
}

// ---------------------------------------------------------------------------
// Repository / commit
// ---------------------------------------------------------------------------

async function resolveOwner() {
  const explicit = process.env.GITHUB_OWNER?.trim();
  if (explicit) return explicit;
  const user = await api('GET', '/user');
  if (!user?.login) die('无法从 /user 读取登录名，请设置 GITHUB_OWNER');
  log(`token 属于 ${user.login}`);
  return user.login;
}

async function ensureRepo(owner, repoName) {
  const existing = await apiOrNull('GET', `/repos/${owner}/${repoName}`);
  if (existing) {
    if (!existing.permissions?.push) {
      warn(`对 ${owner}/${repoName} 没有 push 权限，提交可能被拒绝`);
    }
    log(`仓库已存在：${existing.html_url}（默认分支 ${existing.default_branch}）`);
    return { repo: existing, created: false };
  }

  const self = await api('GET', '/user');
  const endpoint = owner === self.login ? '/user/repos' : `/orgs/${owner}/repos`;
  const body = {
    name: repoName,
    private: process.env.GITHUB_PRIVATE === '1',
    description: 'Meridian — iPad 横屏全屏时钟（SwiftUI，iOS 17，零依赖）',
    has_issues: true,
    has_wiki: false,
    auto_init: false,
  };
  try {
    const repo = await api('POST', endpoint, { body });
    log(`已创建仓库：${repo.html_url}`);
    return { repo, created: true };
  } catch (error) {
    if (error instanceof ApiError && (error.status === 422 || error.status === 409)) {
      // 422: name already exists (or invalid); 409: conflict. Re-read it: the
      // repo may have been created between our GET and POST.
      const race = await apiOrNull('GET', `/repos/${owner}/${repoName}`);
      if (race) {
        log(`仓库已存在（并发创建）：${race.html_url}`);
        return { repo: race, created: false };
      }
      die(`创建仓库失败（${owner}/${repoName}）：${error.message}`);
    }
    throw error;
  }
}

async function currentHead(owner, repoName, branch) {
  const ref = await apiOrNull('GET', `/repos/${owner}/${repoName}/git/ref/heads/${branch}`);
  return ref?.object?.sha ?? null;
}

async function remoteBlobShas(owner, repoName, branch) {
  const map = new Map();
  if (!branch) return map;
  try {
    const tree = await api(
      'GET',
      `/repos/${owner}/${repoName}/git/trees/${encodeURIComponent(branch)}?recursive=1`,
    );
    for (const entry of tree?.tree ?? []) {
      if (entry.type === 'blob') map.set(entry.path, entry.sha);
    }
    log(`远端 ${branch} 有 ${map.size} 个文件`);
  } catch (error) {
    // 409 = empty repository, 404 = branch vanished; both mean "no files yet".
    if (error instanceof ApiError && (error.status === 404 || error.status === 409)) {
      log(`远端 ${branch} 还没有提交`);
      return map;
    }
    throw error;
  }
  return map;
}

async function createBlobs(owner, repoName, files) {
  const results = new Map();
  const queue = files.slice();
  const worker = async () => {
    while (queue.length) {
      const file = queue.shift();
      const body = file.binary
        ? { content: file.buffer.toString('base64'), encoding: 'base64' }
        : { content: file.buffer.toString('utf8'), encoding: 'utf-8' };
      const blob = await api('POST', `/repos/${owner}/${repoName}/git/blobs`, { body });
      results.set(file.path, blob.sha);
      process.stdout.write(`\r  上传 blob ${results.size}/${files.length}`);
    }
  };
  await Promise.all(Array.from({ length: 6 }, worker));
  process.stdout.write('\n');
  return results;
}

async function seedEmptyRepo(owner, repoName, branch) {
  // GitHub rejects `POST /git/blobs` with 409 "Git Repository is empty" until
  // the repository has at least one commit, so the first push has to go through
  // the Contents API. A zero-byte `.keep` is enough to create that commit; the
  // tree we submit next does not include it, so it is gone again immediately.
  log('空仓库：先写一个 .keep 建立首个提交');
  try {
    await api('PUT', `/repos/${owner}/${repoName}/contents/.keep`, {
      body: {
        message: 'Meridian: initialise repository',
        content: Buffer.from('').toString('base64'),
        branch,
      },
    });
  } catch (error) {
    if (error instanceof ApiError && (error.status === 409 || error.status === 422)) {
      log('  .keep 已存在，跳过');
      return;
    }
    throw error;
  }
}

async function commitTree(owner, repoName, branch, headSha, files) {
  if (!headSha) {
    await seedEmptyRepo(owner, repoName, branch);
    headSha = await currentHead(owner, repoName, branch);
  }
  const remote = await remoteBlobShas(owner, repoName, branch);
  const changed = files.filter((file) => remote.get(file.path) !== file.sha);
  const removed = [...remote.keys()].filter((p) => !files.some((file) => file.path === p));

  log(
    `文件差异：${changed.length} 个新增/修改，${removed.length} 个删除，` +
      `${files.length - changed.length} 个未变`,
  );
  for (const file of changed) log(`  + ${file.path} (${file.size} B)`);
  for (const file of removed) log(`  - ${file}`);

  if (changed.length === 0 && removed.length === 0 && headSha) {
    log('工作区与远端一致，跳过提交（幂等）');
    return headSha;
  }

  const blobShas = await createBlobs(owner, repoName, changed);
  const tree = files.map((file) => ({
    path: file.path,
    mode: '100644',
    type: 'blob',
    // Changed files point at the blob we just uploaded; unchanged ones reuse
    // the sha already on the remote, so a no-op edit costs no upload.
    sha: blobShas.get(file.path) ?? remote.get(file.path) ?? file.sha,
  }));

  // No base_tree: the new tree is exactly these entries, so deleted files are
  // deleted from the repository instead of lingering forever.
  const newTree = await api('POST', `/repos/${owner}/${repoName}/git/trees`, { body: { tree } });
  log(`tree ${newTree.sha.slice(0, 12)}（${tree.length} 项）`);

  const commit = await api('POST', `/repos/${owner}/${repoName}/git/commits`, {
    body: {
      message: `Meridian ${new Date().toISOString()} — ${files.length} files`,
      tree: newTree.sha,
      parents: headSha ? [headSha] : [],
    },
  });
  log(`commit ${commit.sha.slice(0, 12)}`);

  if (headSha) {
    try {
      await api('PATCH', `/repos/${owner}/${repoName}/git/refs/heads/${branch}`, {
        body: { sha: commit.sha, force: false },
      });
    } catch (error) {
      if (error instanceof ApiError && (error.status === 422 || error.status === 409)) {
        // Someone else moved the branch. Re-parent onto the fresh head and
        // move the ref once. (Never force-push: a colleague's commit wins.)
        const fresh = await currentHead(owner, repoName, branch);
        if (!fresh) die(`分支 ${branch} 被删除，无法更新`);
        const rebased = await api('POST', `/repos/${owner}/${repoName}/git/commits`, {
          body: {
            message: `Meridian ${new Date().toISOString()} — ${files.length} files (rebased)`,
            tree: newTree.sha,
            parents: [fresh],
          },
        });
        await api('PATCH', `/repos/${owner}/${repoName}/git/refs/heads/${branch}`, {
          body: { sha: rebased.sha, force: false },
        });
        log(`分支被并发修改，已重放到 ${rebased.sha.slice(0, 12)}`);
      } else {
        throw error;
      }
    }
  } else {
    await api('POST', `/repos/${owner}/${repoName}/git/refs`, {
      body: { ref: `refs/heads/${branch}`, sha: commit.sha },
    });
    log(`已创建分支 ${branch}`);
  }

  const head = await currentHead(owner, repoName, branch);
  return head ?? commit.sha;
}

// ---------------------------------------------------------------------------
// Workflow dispatch + polling
// ---------------------------------------------------------------------------

async function dispatchWorkflow(owner, repoName, branch) {
  const workflow = await api(
    'GET',
    `/repos/${owner}/${repoName}/actions/workflows/build.yml`,
  ).catch((error) => {
    if (error instanceof ApiError && error.status === 404) return null;
    throw error;
  });
  if (!workflow) warn('暂时看不到 build.yml，等待 GitHub 注册 workflow');

  for (let attempt = 1; attempt <= 10; attempt += 1) {
    try {
      await api('POST', `/repos/${owner}/${repoName}/actions/workflows/build.yml/dispatches`, {
        body: { ref: branch },
      });
      log(`已触发 workflow_dispatch（ref=${branch}）`);
      return;
    } catch (error) {
      if (error instanceof ApiError && (error.status === 404 || error.status === 422)) {
        log(`workflow 尚未就绪（第 ${attempt}/10 次），2s 后重试`);
        await sleep(2000);
        continue;
      }
      throw error;
    }
  }
  die('无法触发 build.yml；确认 .github/workflows/build.yml 已在默认分支上');
}

/// The commit pushed above already triggers the workflow (on: push). Dispatching
/// a second run for the same commit makes the two cancel each other through the
/// workflow's concurrency group, so a run is reused when one is already in
/// flight; a dispatch is only the fallback for the very first push (when GitHub
/// has not indexed the workflow yet).
async function ensureRun(owner, repoName, branch, headSha) {
  for (let attempt = 1; attempt <= 8; attempt += 1) {
    const runs = await apiOrNull(
      'GET',
      `/repos/${owner}/${repoName}/actions/runs?branch=${encodeURIComponent(branch)}&per_page=10`,
    );
    const active = (runs?.workflow_runs ?? []).find(
      (run) => run.head_sha === headSha && run.status !== 'completed',
    );
    if (active) {
      log(`复用本提交已触发的 run #${active.run_number}`);
      return;
    }
    if (attempt < 8) await sleep(2000);
  }
  log('没有出现 push 触发的 run，改为手动 dispatch');
  await dispatchWorkflow(owner, repoName, branch);
}

async function findRun(owner, repoName, headSha, dispatchedAt) {
  const runs = await api(
    'GET',
    `/repos/${owner}/${repoName}/actions/workflows/build.yml/runs?per_page=30`,
  );
  const candidates = (runs?.workflow_runs ?? []).filter(
    (run) => run.head_sha === headSha && new Date(run.created_at).getTime() >= dispatchedAt - 120_000,
  );
  // Prefer a finished run over a queued duplicate of the same commit.
  const done = candidates.find((run) => run.status === 'completed');
  return done ?? candidates[0] ?? null;
}

async function waitForRun(owner, repoName, headSha, dispatchedAt) {
  const deadline = Date.now() + POLL_MAX_MS;
  let lastLine = '';
  let lastBeat = 0;
  while (Date.now() < deadline) {
    const run = await findRun(owner, repoName, headSha, dispatchedAt);
    if (run) {
      const line = `run #${run.run_number}: ${run.status}${run.conclusion ? ` / ${run.conclusion}` : ''}`;
      if (line !== lastLine) {
        log(line);
        lastLine = line;
      }
      if (run.status === 'completed') return run;
      if (Date.now() - lastBeat > 80_000) {
        log(`仍在构建…… ${run.html_url}`);
        lastBeat = Date.now();
      }
    } else if (Date.now() - lastBeat > 20_000) {
      log('等待 GitHub 注册这次 run……');
      lastBeat = Date.now();
    }
    await sleep(POLL_MS);
  }
  die(`等待超时（35 分钟），请打开 https://github.com/${owner}/${repoName}/actions 查看`, 2);
}

// ---------------------------------------------------------------------------
// Failure logs / success download
// ---------------------------------------------------------------------------

async function printFailureLogs(owner, repoName, run) {
  console.error(`\n✗ 构建失败：${run.html_url}\n`);
  try {
    const jobs = await api('GET', `/repos/${owner}/${repoName}/actions/runs/${run.id}/jobs`);
    const failed = (jobs?.jobs ?? []).filter((job) => job.conclusion === 'failure');
    const targets = failed.length ? failed : jobs?.jobs ?? [];
    for (const job of targets) {
      console.error(`── job: ${job.name} (${job.conclusion}) ──`);
      for (const step of job.steps ?? []) {
        if (step.conclusion === 'failure') console.error(`   失败步骤：${step.name}`);
      }
      const res = await requestFollow(
        `${API}/repos/${owner}/${repoName}/actions/jobs/${job.id}/logs`,
        { headers: { Authorization: `Bearer ${TOKEN}`, Accept: 'application/vnd.github+json' } },
      );
      if (res.status !== 200) {
        console.error(`   （无法下载日志：HTTP ${res.status}）`);
        continue;
      }
      const type = String(res.headers['content-type'] || '');
      if (type.includes('zip')) {
        console.error('   （日志是 zip 包，请到上面的链接下载）');
        continue;
      }
      const text = res.buffer.toString('utf8');
      const lines = text.split('\n');
      console.error(lines.slice(-120).join('\n'));
    }
  } catch (error) {
    console.error(`   （拉取日志时出错：${error.message}）`);
  }
}

async function findReleaseAsset(owner, repoName, tag) {
  for (let attempt = 1; attempt <= 15; attempt += 1) {
    const release = await apiOrNull('GET', `/repos/${owner}/${repoName}/releases/tags/${tag}`);
    const asset = release?.assets?.find((item) => item.name.endsWith('.ipa'));
    if (asset) return { release, asset };
    log(`等待 release ${tag} 的 IPA asset（第 ${attempt}/15 次）`);
    await sleep(3000);
  }
  return { release: null, asset: null };
}

async function downloadIpa(owner, repoName, run) {
  const tag = `build-${run.run_number}`;
  const { release, asset } = await findReleaseAsset(owner, repoName, tag);
  if (!asset) die(`run 成功了，但没有找到 release ${tag} 的 .ipa asset。请确认 workflow 的 release 步骤生效。`);

  const outDir = path.join(ROOT, 'build', 'ipa');
  fs.mkdirSync(outDir, { recursive: true });
  const outFile = path.join(outDir, `Meridian-unsigned-${run.run_number}.ipa`);

  log(`下载 ${asset.name}（${(asset.size / 1024 / 1024).toFixed(1)} MB）`);
  const res = await requestFollow(
    `${API}/repos/${owner}/${repoName}/releases/assets/${asset.id}`,
    { headers: { Authorization: `Bearer ${TOKEN}`, Accept: 'application/octet-stream' } },
  );
  if (res.status !== 200) die(`下载失败：HTTP ${res.status}`);
  const bytes = res.buffer;
  // An IPA is a zip: verify the magic before writing a "successful" download.
  if (bytes.length < 4 || bytes[0] !== 0x50 || bytes[1] !== 0x4b) {
    die(`下载内容不是 zip（前 4 字节 ${bytes.subarray(0, 4).toString('hex')}），未写入 ${outFile}`);
  }
  fs.writeFileSync(outFile, bytes);
  log(`IPA 已保存：${outFile}`);
  log(`release：${release.html_url}`);
  console.log(`\n✓ 完成。用 AltStore / Sideloadly 选这个文件侧载到 iPad：\n  ${outFile}`);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  const { files, total } = plan();

  if (DRY_RUN) {
    console.log('Meridian → GitHub（dry run，不联网）\n');
    console.log(`根目录：${ROOT}`);
    console.log(`仓库：  ${process.env.GITHUB_OWNER || '<token 的 login>'}/${process.env.GITHUB_REPO || 'meridian'}`);
    console.log(`文件：  ${files.length} 个，共 ${total.toLocaleString()} 字节\n`);
    for (const file of files) {
      console.log(`  ${String(file.size).padStart(8)} B  ${file.sha.slice(0, 8)}  ${file.path}`);
    }
    console.log('\n将执行：1) 建仓（若无）2) 上传变更 blob → tree → commit → 更新 main');
    console.log('         3) workflow_dispatch 4) 每 8s 轮询（≤35 min）5) 从 release asset 下载 IPA');
    return;
  }

  if (!TOKEN) {
    die(
      '缺少 GITHUB_TOKEN。\n' +
        '  1. GitHub → Settings → Developer settings → Personal access tokens (classic)\n' +
        '  2. New token，勾选 repo 与 workflow\n' +
        '  3. PowerShell: $env:GITHUB_TOKEN="ghp_..." ; node Tools/publish-to-github.mjs\n' +
        '  只想先看会提交什么：node Tools/publish-to-github.mjs --dry-run',
    );
  }

  console.log(`Meridian → GitHub（${files.length} 个文件，${total.toLocaleString()} 字节）\n`);

  const owner = await resolveOwner();
  const repoName = process.env.GITHUB_REPO || 'meridian';

  const { repo } = await ensureRepo(owner, repoName);
  const branch = repo.default_branch || 'main';

  const headSha = await currentHead(owner, repoName, branch);
  const newHead = await commitTree(owner, repoName, branch, headSha, files);
  log(`分支 ${branch} → ${newHead.slice(0, 12)}`);

  const dispatchedAt = Date.now();
  await ensureRun(owner, repoName, branch, newHead);

  const run = await waitForRun(owner, repoName, newHead, dispatchedAt);
  if (run.conclusion !== 'success') {
    await printFailureLogs(owner, repoName, run);
    process.exitCode = 1;
    return;
  }
  log('构建成功，准备下载 IPA');
  await downloadIpa(owner, repoName, run);
}

main().catch((error) => {
  if (error instanceof ApiError) {
    console.error(`\n✗ GitHub API 错误：${error.message}`);
    if (error.status === 401) console.error('  token 无效或已过期。');
    if (error.status === 403)
      console.error('  token 缺权限（需要 repo + workflow），或触发了速率限制。');
  } else {
    console.error(`\n✗ ${error.message}`);
  }
  process.exit(1);
});
