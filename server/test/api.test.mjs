// 冒烟测试：node --test test/ （或 node --test test/api.test.mjs）
//
// 每个用例自己起一个监听随机端口的服务实例，数据文件落在临时目录，
// 用例之间不共享状态。SSE 用裸 http.get 读帧，不引入任何测试依赖。

import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import fsp from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createServer } from '../meridian-server.mjs';

const TOKEN = 'test-token-0123456789abcdef';
const ISO_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function localDay(date = new Date()) {
  const pad = (n) => String(n).padStart(2, '0');
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
}

async function tempDir() {
  return fsp.mkdtemp(path.join(os.tmpdir(), 'meridian-test-'));
}

/**
 * @param {object} [opts]
 * @param {string} [opts.dir] 复用已存在的目录（重启/损坏文件用例）
 * @param {string} [opts.token]
 * @param {number} [opts.heartbeatMs]
 */
async function startServer(opts = {}) {
  const dir = opts.dir ?? (await tempDir());
  const dataFile = opts.dataFile ?? path.join(dir, 'data.json');
  const server = createServer({
    dataFile,
    token: opts.token ?? TOKEN,
    heartbeatMs: opts.heartbeatMs,
    silent: true,
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const { port } = server.address();
  const base = `http://127.0.0.1:${port}`;
  return {
    server,
    base,
    dir,
    dataFile,
    async close() {
      server.closeAllConnections?.();
      await new Promise((resolve) => server.close(resolve));
    },
  };
}

async function request(base, pathname, options = {}) {
  const { method = 'GET', token = TOKEN, body, raw, redirect = 'follow' } = options;
  /** @type {Record<string,string>} */
  const headers = { ...(options.headers ?? {}) };
  if (token !== null) headers.authorization = `Bearer ${token}`;
  let payload;
  if (raw !== undefined) {
    payload = raw;
    headers['content-type'] ??= 'application/json';
  } else if (body !== undefined) {
    payload = typeof body === 'string' ? body : JSON.stringify(body);
    headers['content-type'] ??= 'application/json';
  }
  const res = await fetch(base + pathname, { method, headers, body: payload, redirect });
  const text = await res.text();
  let json;
  try {
    json = JSON.parse(text);
  } catch {
    json = undefined;
  }
  return { res, status: res.status, text, json, headers: res.headers };
}

function connectSse(base, { token = TOKEN, query = '' } = {}) {
  return new Promise((resolve, reject) => {
    const req = http.get(
      `${base}/api/v1/stream${query}`,
      { headers: token ? { authorization: `Bearer ${token}` } : {} },
      (res) => {
        res.setEncoding('utf8');
        let buffer = '';
        res.on('data', (chunk) => {
          buffer += chunk;
        });
        resolve({ req, res, status: res.statusCode, headers: res.headers, text: () => buffer });
      },
    );
    req.on('error', reject);
  });
}

async function waitFor(check, message, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  let last;
  while (Date.now() < deadline) {
    last = check();
    if (last) return last;
    await sleep(20);
  }
  throw new Error(`${message} (buffer was: ${JSON.stringify(last)})`);
}

function frames(text) {
  return text.split('\n\n').filter((frame) => frame.trim() !== '');
}

function dataOf(frame, event) {
  const lines = frame.split('\n');
  if (!lines[0].startsWith(`event: ${event}`)) return undefined;
  const data = lines
    .filter((line) => line.startsWith('data: '))
    .map((line) => line.slice(6))
    .join('\n');
  return JSON.parse(data);
}

function tasksOf(text) {
  return frames(text)
    .map((frame) => dataOf(frame, 'task'))
    .filter(Boolean);
}

async function createTask(base, body = { title: '测试任务' }) {
  const res = await request(base, '/api/v1/tasks', { method: 'POST', body });
  assert.equal(res.status, 201, res.text);
  return res.json;
}

// ---------------------------------------------------------------------------
// /health
// ---------------------------------------------------------------------------

test('GET /health 是公开端点，返回 name/rev/time', async (t) => {
  const ctx = await startServer();
  t.after(() => ctx.close());

  const health = await request(ctx.base, '/health', { token: null });
  assert.equal(health.status, 200);
  assert.match(health.headers.get('content-type'), /application\/json/);
  assert.deepEqual(Object.keys(health.json).sort(), ['name', 'ok', 'rev', 'time']);
  assert.equal(health.json.ok, true);
  assert.equal(health.json.name, 'meridian');
  assert.equal(health.json.rev, 0);
  assert.match(health.json.time, ISO_RE);
});

// ---------------------------------------------------------------------------
// 鉴权
// ---------------------------------------------------------------------------

test('受保护端点拒绝缺失或错误的 Bearer token', async (t) => {
  const ctx = await startServer();
  t.after(() => ctx.close());

  const paths = [
    ['GET', '/api/v1/snapshot'],
    ['GET', '/api/v1/tasks'],
    ['POST', '/api/v1/tasks'],
    ['PATCH', '/api/v1/tasks/some-id'],
    ['DELETE', '/api/v1/tasks/some-id'],
    ['GET', '/api/v1/stream'],
  ];

  for (const [method, pathname] of paths) {
    const missing = await request(ctx.base, pathname, { method, token: null });
    assert.equal(missing.status, 401, `${method} ${pathname} without token`);
    assert.equal(missing.json.error, 'unauthorized');
    assert.equal(missing.json.code, 401);
    assert.match(missing.headers.get('www-authenticate') ?? '', /Bearer/);

    const wrong = await request(ctx.base, pathname, { method, token: 'nope' });
    assert.equal(wrong.status, 401, `${method} ${pathname} with wrong token`);
  }

  // 401 也要带 CORS 头，否则浏览器侧错误被隐藏成网络错误
  const unauth = await request(ctx.base, '/api/v1/snapshot', { token: null });
  assert.equal(unauth.headers.get('access-control-allow-origin'), '*');
});

test('没有 token 时 createServer 拒绝启动（fail closed）', async () => {
  const dir = await tempDir();
  assert.throws(
    () => createServer({ dataFile: path.join(dir, 'data.json'), token: '' }),
    /MERIDIAN_TOKEN/,
  );
  assert.throws(() => createServer({ dataFile: path.join(dir, 'data.json') }), /MERIDIAN_TOKEN/);
});

// ---------------------------------------------------------------------------
// CRUD
// ---------------------------------------------------------------------------

test('POST /api/v1/tasks 生成完整 AgendaTask（服务端字段）', async (t) => {
  const ctx = await startServer();
  t.after(() => ctx.close());

  const res = await request(ctx.base, '/api/v1/tasks', {
    method: 'POST',
    body: {
      title: '  写周报  ',
      note: '带上附件',
      day: '2026-11-15',
      due: '2026-11-15T09:30:00+08:00',
      priority: 2,
      durationMinutes: 45,
    },
  });
  assert.equal(res.status, 201, res.text);
  const task = res.json;
  assert.deepEqual(
    Object.keys(task).sort(),
    ['day', 'due', 'durationMinutes', 'id', 'isDone', 'note', 'origin', 'priority', 'title', 'updatedAt'],
  );
  assert.match(task.id, UUID_RE);
  assert.equal(task.title, '写周报');
  assert.equal(task.note, '带上附件');
  assert.equal(task.day, '2026-11-15');
  assert.equal(task.due, '2026-11-15T01:30:00Z');
  assert.equal(task.priority, 2);
  assert.equal(task.durationMinutes, 45);
  assert.equal(task.isDone, false);
  assert.equal(task.origin, 'remote');
  assert.match(task.updatedAt, ISO_RE);
});

test('POST 缺省 day 用服务器本地日，可选字段落为 null', async (t) => {
  const ctx = await startServer();
  t.after(() => ctx.close());

  const task = await createTask(ctx.base, { title: '默认字段' });
  assert.equal(task.day, localDay());
  assert.equal(task.note, '');
  assert.equal(task.due, null);
  assert.equal(task.durationMinutes, null);
  assert.equal(task.priority, 0);
});

test('GET /api/v1/snapshot 返回全量快照；GET tasks 可按 day 过滤', async (t) => {
  const ctx = await startServer();
  t.after(() => ctx.close());

  const a = await createTask(ctx.base, { title: 'A', day: '2026-11-15' });
  const b = await createTask(ctx.base, { title: 'B', day: '2026-11-16' });

  const snapshot = await request(ctx.base, '/api/v1/snapshot');
  assert.equal(snapshot.status, 200);
  assert.match(snapshot.json.serverTime, ISO_RE);
  assert.equal(snapshot.json.rev, 2);
  assert.equal(snapshot.json.message, null);
  assert.equal(snapshot.json.weather, null);
  assert.equal(snapshot.json.tasks.length, 2);
  assert.deepEqual(snapshot.json.tasks.map((task) => task.id).sort(), [a.id, b.id].sort());

  const day = await request(ctx.base, '/api/v1/tasks?day=2026-11-15');
  assert.equal(day.status, 200);
  assert.equal(day.json.rev, 2);
  assert.deepEqual(day.json.tasks.map((task) => task.id), [a.id]);

  const empty = await request(ctx.base, '/api/v1/tasks?day=1999-01-01');
  assert.equal(empty.status, 200);
  assert.deepEqual(empty.json.tasks, []);

  const all = await request(ctx.base, '/api/v1/tasks');
  assert.equal(all.json.tasks.length, 2);

  const badDay = await request(ctx.base, '/api/v1/tasks?day=2026-13-01');
  assert.equal(badDay.status, 400);
  assert.equal(badDay.json.error, 'validation_error');
});

test('PATCH 合并子集字段、服务端写 updatedAt 并忽略客户端时间', async (t) => {
  const ctx = await startServer();
  t.after(() => ctx.close());

  const created = await createTask(ctx.base, { title: '旧标题', day: '2026-11-15' });
  const before = (await request(ctx.base, '/api/v1/snapshot')).json.rev;

  const patched = await request(ctx.base, `/api/v1/tasks/${created.id}`, {
    method: 'PATCH',
    body: {
      id: created.id,
      title: '新标题',
      isDone: true,
      priority: 1,
      due: '2026-11-15T18:00:00Z',
      durationMinutes: 90,
      updatedAt: '2020-01-01T00:00:00Z',
    },
  });
  assert.equal(patched.status, 200, patched.text);
  assert.equal(patched.json.id, created.id);
  assert.equal(patched.json.title, '新标题');
  assert.equal(patched.json.isDone, true);
  assert.equal(patched.json.priority, 1);
  assert.equal(patched.json.note, created.note);
  assert.equal(patched.json.day, created.day);
  assert.equal(patched.json.due, '2026-11-15T18:00:00Z');
  assert.equal(patched.json.durationMinutes, 90);
  assert.equal(patched.json.origin, 'remote');
  assert.match(patched.json.updatedAt, ISO_RE);
  assert.notEqual(patched.json.updatedAt, '2020-01-01T00:00:00Z');
  assert.ok(Math.abs(Date.parse(patched.json.updatedAt) - Date.now()) < 60_000);

  const after = (await request(ctx.base, '/api/v1/snapshot')).json.rev;
  assert.equal(after, before + 1);

  // due 可显式清空
  const cleared = await request(ctx.base, `/api/v1/tasks/${created.id}`, {
    method: 'PATCH',
    body: { due: null },
  });
  assert.equal(cleared.status, 200);
  assert.equal(cleared.json.due, null);
});

test('PATCH 未知 id → 404 JSON', async (t) => {
  const ctx = await startServer();
  t.after(() => ctx.close());

  const res = await request(ctx.base, '/api/v1/tasks/does-not-exist', {
    method: 'PATCH',
    body: { title: 'x' },
  });
  assert.equal(res.status, 404);
  assert.equal(res.json.error, 'not_found');
});

test('DELETE 删除且幂等：不存在也 204，rev 不再增长', async (t) => {
  const ctx = await startServer();
  t.after(() => ctx.close());

  const task = await createTask(ctx.base, { title: '待删除' });
  const first = await request(ctx.base, `/api/v1/tasks/${task.id}`, { method: 'DELETE' });
  assert.equal(first.status, 204);
  assert.equal(first.text, '');

  const revAfterDelete = (await request(ctx.base, '/api/v1/snapshot')).json.rev;
  const again = await request(ctx.base, `/api/v1/tasks/${task.id}`, { method: 'DELETE' });
  assert.equal(again.status, 204);
  const revAfterAgain = (await request(ctx.base, '/api/v1/snapshot')).json.rev;
  assert.equal(revAfterAgain, revAfterDelete);
  assert.deepEqual((await request(ctx.base, '/api/v1/tasks')).json.tasks, []);
});

test('rev 单调递增，重启后从 data.json 恢复', async (t) => {
  const ctx = await startServer();
  const task = await createTask(ctx.base, { title: '持久化' });
  await request(ctx.base, `/api/v1/tasks/${task.id}`, { method: 'PATCH', body: { isDone: true } });
  const before = (await request(ctx.base, '/api/v1/snapshot')).json;
  await ctx.close();

  const restarted = await startServer({ dir: ctx.dir, dataFile: ctx.dataFile });
  t.after(() => restarted.close());
  const after = (await request(restarted.base, '/api/v1/snapshot')).json;
  assert.equal(after.rev, before.rev);
  assert.equal(after.tasks.length, 1);
  assert.equal(after.tasks[0].id, task.id);
  assert.equal(after.tasks[0].isDone, true);

  await createTask(restarted.base, { title: '重启后新增' });
  assert.equal((await request(restarted.base, '/api/v1/snapshot')).json.rev, before.rev + 1);
});

test('data.json 原子写：落盘内容合法且没有残留临时文件', async (t) => {
  const ctx = await startServer();
  t.after(() => ctx.close());

  const task = await createTask(ctx.base, { title: '原子写' });
  await request(ctx.base, `/api/v1/tasks/${task.id}`, { method: 'PATCH', body: { note: 'x' } });

  const raw = await fsp.readFile(ctx.dataFile, 'utf8');
  const parsed = JSON.parse(raw);
  assert.equal(parsed.rev, 2);
  assert.equal(parsed.tasks.length, 1);
  const entries = await fsp.readdir(ctx.dir);
  assert.deepEqual(
    entries.filter((name) => name.includes('.tmp')),
    [],
  );
});

test('data.json 损坏时备份为 data.corrupt-<ts>.json 并以空库启动', async (t) => {
  const dir = await tempDir();
  const dataFile = path.join(dir, 'data.json');
  await fsp.writeFile(dataFile, '{ this is not json', 'utf8');

  const ctx = await startServer({ dir, dataFile });
  t.after(() => ctx.close());

  const snapshot = await request(ctx.base, '/api/v1/snapshot');
  assert.equal(snapshot.status, 200);
  assert.equal(snapshot.json.rev, 0);
  assert.deepEqual(snapshot.json.tasks, []);

  const entries = await fsp.readdir(dir);
  const backup = entries.find((name) => /^data\.corrupt-.*\.json$/.test(name));
  assert.ok(backup, `备份文件缺失，目录内容：${entries.join(', ')}`);
  assert.equal(await fsp.readFile(path.join(dir, backup), 'utf8'), '{ this is not json');
});

// ---------------------------------------------------------------------------
// 错误码 / 边界
// ---------------------------------------------------------------------------

test('参数校验、坏 JSON、超大 body、未知路由与 CORS 预检', async (t) => {
  const ctx = await startServer();
  t.after(() => ctx.close());

  const cases = [
    [{}, 'title is required'],
    [{ title: '   ' }, 'title is required'],
    [{ title: 42 }, 'title'],
    [{ title: 'x', priority: 5 }, 'priority'],
    [{ title: 'x', priority: 'high' }, 'priority'],
    [{ title: 'x', day: '2026-13-01' }, 'day'],
    [{ title: 'x', day: '2026-02-30' }, 'day'],
    [{ title: 'x', day: '15.11.2026' }, 'day'],
    [{ title: 'x', due: 'not-a-date' }, 'due'],
    [{ title: 'x', durationMinutes: -5 }, 'durationMinutes'],
    [{ title: 'x'.repeat(501) }, 'title'],
  ];
  for (const [body, hint] of cases) {
    const res = await request(ctx.base, '/api/v1/tasks', { method: 'POST', body });
    assert.equal(res.status, 400, `body=${JSON.stringify(body)} → ${res.text}`);
    assert.equal(res.json.error, 'validation_error');
    assert.match(res.json.message, new RegExp(hint, 'i'));
  }

  const badJson = await request(ctx.base, '/api/v1/tasks', {
    method: 'POST',
    raw: '{"title":',
  });
  assert.equal(badJson.status, 400);
  assert.equal(badJson.json.error, 'invalid_json');

  // Windows 编辑器常带 UTF-8 BOM；服务端应剥掉它而不是回 400
  const bom = await request(ctx.base, '/api/v1/tasks', {
    method: 'POST',
    raw: '\uFEFF{"title":"BOM 任务"}',
  });
  assert.equal(bom.status, 201, bom.text);
  assert.equal(bom.json.title, 'BOM 任务');

  const huge = await request(ctx.base, '/api/v1/tasks', {
    method: 'POST',
    body: { title: 'x', note: 'a'.repeat(70 * 1024) },
  });
  assert.equal(huge.status, 413);
  assert.equal(huge.json.error, 'payload_too_large');

  const unknown = await request(ctx.base, '/definitely-not-a-route');
  assert.equal(unknown.status, 404);
  assert.equal(unknown.json.error, 'not_found');
  assert.match(unknown.headers.get('content-type'), /application\/json/);

  const unknownApi = await request(ctx.base, '/api/v1/nope');
  assert.equal(unknownApi.status, 404);
  assert.equal(unknownApi.json.error, 'not_found');

  const preflight = await request(ctx.base, '/api/v1/tasks', { method: 'OPTIONS', token: null });
  assert.equal(preflight.status, 204);
  assert.equal(preflight.headers.get('access-control-allow-origin'), '*');
  assert.match(preflight.headers.get('access-control-allow-headers') ?? '', /Authorization/i);
  assert.match(preflight.headers.get('access-control-allow-methods') ?? '', /PATCH/);

  const wrongMethod = await request(ctx.base, '/api/v1/snapshot', { method: 'POST', body: {} });
  assert.equal(wrongMethod.status, 405);
  assert.match(wrongMethod.headers.get('allow') ?? '', /GET/);
});

// ---------------------------------------------------------------------------
// SSE
// ---------------------------------------------------------------------------

test('SSE：首帧 retry + snapshot，变更推送 task/delete，心跳注释行', async (t) => {
  const ctx = await startServer({ heartbeatMs: 80 });
  t.after(() => ctx.close());

  const stream = await connectSse(ctx.base);
  t.after(() => stream.req.destroy());
  assert.equal(stream.status, 200);
  assert.match(stream.headers['content-type'], /text\/event-stream/);
  assert.equal(stream.headers['cache-control'].includes('no-cache'), true);

  await waitFor(
    () => stream.text().startsWith('retry: 3000\n\n') && stream.text().includes('event: snapshot'),
    '没有收到 retry/snapshot 首帧',
  );

  const snapshotFrame = frames(stream.text()).find((frame) => frame.startsWith('event: snapshot'));
  const snapshot = dataOf(snapshotFrame, 'snapshot');
  assert.equal(snapshot.rev, 0);
  assert.deepEqual(snapshot.tasks, []);
  assert.match(snapshot.serverTime, ISO_RE);
  assert.equal(snapshot.message, null);
  assert.equal(snapshot.weather, null);

  const created = await createTask(ctx.base, { title: 'SSE 推送' });
  await waitFor(
    () => tasksOf(stream.text()).some((task) => task.id === created.id),
    '没有收到 task 事件',
  );

  await request(ctx.base, `/api/v1/tasks/${created.id}`, {
    method: 'PATCH',
    body: { isDone: true },
  });
  await waitFor(
    () => tasksOf(stream.text()).some((task) => task.id === created.id && task.isDone === true),
    '没有收到 PATCH 后的 task 事件',
  );

  await request(ctx.base, `/api/v1/tasks/${created.id}`, { method: 'DELETE' });
  await waitFor(
    () => {
      const del = frames(stream.text())
        .map((frame) => dataOf(frame, 'delete'))
        .find(Boolean);
      return del && del.id === created.id;
    },
    '没有收到 delete 事件',
  );

  await waitFor(() => stream.text().includes(': ping\n\n'), '没有收到心跳注释行');
});

test('SSE 支持 ?token= 查询参数（EventSource 无法自定义 header）', async (t) => {
  const ctx = await startServer();
  t.after(() => ctx.close());

  const stream = await connectSse(ctx.base, {
    token: null,
    query: `?token=${encodeURIComponent(TOKEN)}`,
  });
  t.after(() => stream.req.destroy());
  assert.equal(stream.status, 200);
  await waitFor(() => stream.text().includes('event: snapshot'), '没有收到 snapshot 首帧');

  const bad = await request(ctx.base, '/api/v1/stream?token=wrong', { token: null });
  assert.equal(bad.status, 401);
});

// ---------------------------------------------------------------------------
// /push 网页表单
// ---------------------------------------------------------------------------

test('/push：口令页 → 表单页 → 表单提交落库', async (t) => {
  const ctx = await startServer();
  t.after(() => ctx.close());

  const locked = await request(ctx.base, '/push', { token: null });
  assert.equal(locked.status, 200);
  assert.match(locked.headers.get('content-type'), /text\/html/);
  assert.match(locked.text, /name="token"/);
  assert.match(locked.text, /口令/);

  const unlocked = await request(ctx.base, '/push?token=' + encodeURIComponent(TOKEN), {
    token: null,
  });
  assert.equal(unlocked.status, 200);
  assert.match(unlocked.text, /name="title"/);
  assert.match(unlocked.text, /name="priority"/);
  assert.match(unlocked.headers.get('set-cookie') ?? '', /meridian_token=/);
  assert.doesNotMatch(unlocked.text, /cdn\.|googleapis|unpkg|jsdelivr/i);

  // 带 cookie 也能直接进表单页（手机第一次用 ?token= 登录之后）
  const cookiePair = (unlocked.headers.get('set-cookie') ?? '').split(';')[0];
  const viaCookie = await request(ctx.base, '/push', {
    token: null,
    headers: { cookie: cookiePair },
  });
  assert.equal(viaCookie.status, 200);
  assert.match(viaCookie.text, /name="title"/);

  // 失效的 ?token= 不应压过仍然有效的 cookie
  const staleQuery = await request(ctx.base, '/push?token=stale', {
    token: null,
    headers: { cookie: cookiePair },
  });
  assert.equal(staleQuery.status, 200);
  assert.match(staleQuery.text, /name="title"/);

  const form = new URLSearchParams({
    token: TOKEN,
    title: '晚上浇花',
    due: '2026-11-15T20:30',
    priority: '2',
  }).toString();
  const posted = await request(ctx.base, '/push', {
    method: 'POST',
    token: null,
    raw: form,
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
  });
  assert.equal(posted.status, 200, posted.text);
  assert.match(posted.text, /晚上浇花/);

  const snapshot = await request(ctx.base, '/api/v1/snapshot');
  assert.equal(snapshot.json.rev, 1);
  assert.equal(snapshot.json.tasks.length, 1);
  assert.equal(snapshot.json.tasks[0].title, '晚上浇花');
  assert.equal(snapshot.json.tasks[0].priority, 2);
  assert.equal(snapshot.json.tasks[0].origin, 'remote');
  assert.equal(snapshot.json.tasks[0].day, '2026-11-15');

  const badToken = await request(ctx.base, '/push', {
    method: 'POST',
    token: null,
    raw: new URLSearchParams({ token: 'wrong', title: 'x' }).toString(),
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
  });
  assert.equal(badToken.status, 401);

  // 只提交 token 视为登录，303 回表单页
  const login = await request(ctx.base, '/push', {
    method: 'POST',
    token: null,
    raw: new URLSearchParams({ token: TOKEN }).toString(),
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    redirect: 'manual',
  });
  assert.equal(login.status, 303);
  assert.equal(login.headers.get('location'), '/push');
});
