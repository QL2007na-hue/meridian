#!/usr/bin/env node
// Meridian — local static checks.
//
// The development machine is Windows: no Swift compiler, no Xcode. CI is the
// only place a real `swiftc` runs, so every failure that CI would report thirty
// seconds in should be caught here in fifty milliseconds instead.
//
// What it checks, and why each one earns its keep:
//
//   1. Brackets, braces and string literals balance. A stray `}` in one file
//      produces a cascade of "type not found" errors in five others; finding
//      the file that is actually broken is the whole point.
//   2. A blacklist of APIs that are newer than the iOS 17 deployment target or
//      simply not part of this design (Observation, SwiftData, previews,
//      iOS 18 Tab/symbol effects, widgets). CI on the newest Xcode would
//      happily compile some of them, and the app would then crash on the
//      user's iPad — the exact failure this project cannot afford.
//   3. The panel types the shell instantiates are declared `: View` somewhere.
//      Cross-file, because `RootView` refers to `SettingsSheet` and the compiler
//      only notices once every file is parsed.
//   4. Every `Palette.*`, `Typeface.*`, ... member used anywhere exists in
//      Design/Theme.swift. This catches the design-system contract breaking
//      when two people edit the theme and the views in parallel.
//   5. The XcodeGen spec, the hand-written Info.plist and the asset catalog
//      agree with the filesystem. The Info.plist keys are the ones whose
//      absence silently letterboxes the app (UILaunchScreen) or leaves the LAN
//      server unreachable (NSAppTransportSecurity / NSLocalNetworkUsage...).
//
// Zero dependencies, Node 18+. Exit code 0 = PASS, 1 = FAIL.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const SRC_ROOT = path.join(ROOT, 'ios', 'Meridian');
const THEME = path.join(SRC_ROOT, 'Design', 'Theme.swift');

const failures = [];
const notes = [];

const rel = (p) => path.relative(ROOT, p).split(path.sep).join('/');

function fail(file, line, message) {
  failures.push({ file: rel(file), line, message });
}

// ---------------------------------------------------------------------------
// 1. Tokenizer: mask strings/comments, then check bracket balance.
// ---------------------------------------------------------------------------

/**
 * Returns the source with string literals and comments replaced by spaces
 * (newlines preserved, so line numbers stay honest), plus any structural
 * errors found on the way.
 *
 * Swift has three literal flavours that matter here: "…", """…""" and raw
 * #"…"#. Interpolation \\(…) is code again, so it re-enters the code state and
 * returns to the string when its parenthesis closes.
 */
function maskSource(src) {
  const masked = src.split('');
  const issues = [];
  const brackets = [];
  const stack = [{ kind: 'code' }];
  let line = 1;
  let i = 0;

  const blank = (from, to) => {
    for (let k = from; k < to && k < src.length; k += 1) {
      if (src[k] !== '\n') masked[k] = ' ';
    }
  };

  const isInterpStart = (j, hashes) => {
    if (src[j] !== '\\') return 0;
    let k = j + 1;
    for (let h = 0; h < hashes; h += 1) {
      if (src[k] !== '#') return 0;
      k += 1;
    }
    return src[k] === '(' ? k - j + 1 : 0;
  };

  while (i < src.length) {
    const ctx = stack[stack.length - 1];
    const c = src[i];

    if (c === '\n') {
      line += 1;
      if (ctx.kind === 'line') stack.pop();
      i += 1;
      continue;
    }

    switch (ctx.kind) {
      case 'line':
        blank(i, i + 1);
        i += 1;
        break;

      case 'block':
        if (src.startsWith('/*', i)) {
          ctx.depth += 1;
          blank(i, i + 2);
          i += 2;
        } else if (src.startsWith('*/', i)) {
          blank(i, i + 2);
          i += 2;
          ctx.depth -= 1;
          if (ctx.depth === 0) stack.pop();
        } else {
          blank(i, i + 1);
          i += 1;
        }
        break;

      case 'string':
      case 'mstring': {
        const multiline = ctx.kind === 'mstring';
        if (!multiline && c === '"') {
          stack.pop();
          i += 1;
          break;
        }
        if (multiline && src.startsWith('"""', i)) {
          stack.pop();
          i += 3;
          break;
        }
        if (c === '\\') {
          const step = isInterpStart(i, 0);
          if (step > 0) {
            blank(i, i + step);
            stack.push({ kind: 'interp', paren: 0, line });
            i += step;
            break;
          }
          // Escaped character (possibly a line continuation: keep the newline).
          blank(i, i + 2);
          i += 2;
          break;
        }
        blank(i, i + 1);
        i += 1;
        break;
      }

      case 'raw':
      case 'mraw': {
        const multiline = ctx.kind === 'mraw';
        if (multiline && c === '"' && src.startsWith('"""', i)) {
          blank(i, i + 3);
          stack.pop();
          i += 3;
          break;
        }
        if (c === '"' && !multiline) {
          blank(i, i + 1);
          stack.pop();
          i += 1;
          break;
        }
        if (c === '\\') {
          const step = isInterpStart(i, ctx.hashes);
          if (step > 0) {
            blank(i, i + step);
            stack.push({ kind: 'interp', paren: 0, line });
            i += step;
            break;
          }
        }
        blank(i, i + 1);
        i += 1;
        break;
      }

      case 'interp':
        // Falls through to the code rules below, with one addition: an
        // unmatched ')' ends the interpolation.
        if (c === ')' && ctx.paren === 0) {
          stack.pop();
          i += 1;
          break;
        }
      // eslint-disable-next-line no-fallthrough
      case 'code': {
        if (src.startsWith('//', i)) {
          stack.push({ kind: 'line' });
          i += 2;
          break;
        }
        if (src.startsWith('/*', i)) {
          stack.push({ kind: 'block', depth: 1, line });
          i += 2;
          break;
        }
        if (c === '"') {
          if (src.startsWith('"""', i)) {
            stack.push({ kind: 'mstring', line });
            i += 3;
          } else {
            stack.push({ kind: 'string', line });
            i += 1;
          }
          break;
        }
        if (c === '#') {
          let hashes = 0;
          while (src[i + hashes] === '#') hashes += 1;
          if (src.startsWith('"""', i + hashes)) {
            stack.push({ kind: 'mraw', hashes, line });
            i += hashes + 3;
            break;
          }
          if (src[i + hashes] === '"') {
            stack.push({ kind: 'raw', hashes, line });
            i += hashes + 1;
            break;
          }
        }
        if (c === '(' || c === '[' || c === '{') {
          brackets.push({ ch: c, line });
          if (c === '(' && ctx.kind === 'interp') ctx.paren += 1;
          i += 1;
          break;
        }
        if (c === ')' || c === ']' || c === '}') {
          // A ')' inside \\( … ) that closes a nested call is still a real
          // bracket; only the one at paren depth 0 ends the interpolation.
          if (c === ')' && ctx.kind === 'interp') ctx.paren -= 1;
          const want = { ')': '(', ']': '[', '}': '{' }[c];
          const open = brackets.pop();
          if (!open) {
            issues.push({ line, message: `unmatched closing '${c}'` });
          } else if (open.ch !== want) {
            issues.push({
              line,
              message: `closing '${c}' closes '${open.ch}' opened on line ${open.line}`,
            });
          }
          i += 1;
          break;
        }
        i += 1;
        break;
      }

      default:
        i += 1;
    }
  }

  // Anything still open at EOF is a real error, reported at its opening line.
  for (const ctx of stack.slice(1)) {
    if (ctx.kind === 'string' || ctx.kind === 'mstring' || ctx.kind === 'raw' || ctx.kind === 'mraw') {
      issues.push({ line: ctx.line, message: 'unterminated string literal' });
    } else if (ctx.kind === 'block') {
      issues.push({ line: ctx.line, message: 'unterminated block comment' });
    } else if (ctx.kind === 'interp') {
      issues.push({ line: ctx.line, message: 'unterminated string interpolation' });
    }
  }
  for (const open of brackets) {
    issues.push({ line: open.line, message: `unclosed '${open.ch}'` });
  }

  return { code: masked.join(''), issues };
}

// ---------------------------------------------------------------------------
// 2. Blacklist.
// ---------------------------------------------------------------------------

const FORBIDDEN = [
  [/\@Observable\b/, 'Observation 的 @Observable 宏（本项目用 ObservableObject）'],
  [/\@Model\b/, 'SwiftData 的 @Model 宏'],
  [/\bSwiftData\b/, 'SwiftData（部署目标 17.0 之外的设计依赖）'],
  [/#Preview\s*\(/, '#Preview 宏（不走预览，改用真机/模拟器）'],
  [/\@Entry\b/, '@Entry 宏（Xcode 16 / iOS 18）'],
  [/\bWidgetKit\b|\bWidgetBundle\b|\bimport\s+WidgetKit\b/, 'WidgetKit（App 不是小组件）'],
  [/\.symbolEffect\s*\(/, '.symbolEffect( 是 iOS 17 中 SwiftUI 的符号效果；本项目要兼容更早设备且不允许动效堆叠'],
  [/\.scrollTargetBehavior\s*\(/, '.scrollTargetBehavior( 是 iOS 18 API'],
  [/\.containerRelativeFrame\s*\(/, '.containerRelativeFrame( 是 iOS 18 API'],
  [/\.onScrollGeometryChange\s*\(/, '.onScrollGeometryChange( 是 iOS 18 API'],
  [/\bTab\s*\(/, 'iOS 18 的 Tab { } / Tab( ) 新 TabView API'],
  [/\bTimelineSchedule\s*\(/, 'TimelineSchedule 不能被实例化（用 .animation / .periodic）'],
];

// ---------------------------------------------------------------------------
// 3. Panels the shell instantiates.
// ---------------------------------------------------------------------------

const REQUIRED_VIEWS = [
  'ClockStage',
  'AgendaPanel',
  'NextPanel',
  'ServerPanel',
  'FocusPanel',
  'WorldPanel',
  'SettingsSheet',
];

// ---------------------------------------------------------------------------
// 4. Design-system namespaces.
// ---------------------------------------------------------------------------

const THEME_NAMESPACES = ['Palette', 'Surface', 'Space', 'Radius', 'Typeface', 'Motion', 'Metrics'];

function themeMembers(themeSource) {
  const { code } = maskSource(themeSource);
  const members = new Map();
  for (const name of THEME_NAMESPACES) {
    members.set(name, new Set());
    const re = new RegExp(`enum\\s+${name}\\s*\\{`, 'g');
    let match;
    while ((match = re.exec(code))) {
      let depth = 1; // we are already inside the enum's opening brace
      let end = match.index + match[0].length;
      for (let k = match.index + match[0].length; k < code.length; k += 1) {
        if (code[k] === '{') depth += 1;
        else if (code[k] === '}') {
          depth -= 1;
          if (depth === 0) {
            end = k;
            break;
          }
        }
      }
      const body = code.slice(match.index, end);
      const memberRe = /static\s+(?:let|var|func)\s+(\w+)/g;
      let member;
      while ((member = memberRe.exec(body))) members.get(name).add(member[1]);
    }
  }
  return members;
}

// ---------------------------------------------------------------------------
// 5. Filesystem / spec agreement.
// ---------------------------------------------------------------------------

function readPngSize(file) {
  const buf = fs.readFileSync(file);
  const signature = buf.subarray(0, 8).toString('hex');
  if (signature !== '89504e470d0a1a0a') return null;
  return { width: buf.readUInt32BE(16), height: buf.readUInt32BE(20) };
}

const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

function checkProjectFiles() {
  const specPath = path.join(ROOT, 'project.yml');
  if (!fs.existsSync(specPath)) {
    fail(specPath, 0, 'project.yml 不存在');
    return;
  }
  const spec = fs.readFileSync(specPath, 'utf8');
  const sourceMatch = spec.match(/sources:\s*\n\s*-\s*path:\s*(\S+)/);
  if (!sourceMatch) {
    fail(specPath, 0, 'project.yml 里找不到 sources: - path:');
  } else {
    const sourcePath = path.join(ROOT, sourceMatch[1].replace(/^\.\//, ''));
    if (!fs.existsSync(sourcePath) || !fs.statSync(sourcePath).isDirectory()) {
      fail(specPath, 0, `project.yml 的 sources 路径不存在：${sourceMatch[1]}`);
    }
  }

  const plistMatch = spec.match(/INFOPLIST_FILE:\s*(\S+)/);
  const plistPath = path.join(ROOT, plistMatch ? plistMatch[1] : 'ios/Meridian/Info.plist');
  if (!fs.existsSync(plistPath)) {
    fail(specPath, 0, `Info.plist 不存在：${rel(plistPath)}`);
  } else {
    const plist = fs.readFileSync(plistPath, 'utf8');
    for (const key of [
      'UILaunchScreen',
      'UIRequiresFullScreen',
      'UISupportedInterfaceOrientations~ipad',
      'NSLocalNetworkUsageDescription',
      'NSAppTransportSecurity',
    ]) {
      if (!new RegExp(`<key>${esc(key)}</key>`).test(plist)) {
        fail(plistPath, 0, `Info.plist 缺少关键键 ${key}`);
      }
    }
    // UILaunchScreen references the colour by name; if the name is not in the
    // plist the launch screen falls back to white.
    if (!/<string>LaunchBackground<\/string>/.test(plist)) {
      fail(plistPath, 0, 'Info.plist 的 UILaunchScreen 没有引用 LaunchBackground 颜色');
    }
  }

  const assets = path.join(SRC_ROOT, 'Assets.xcassets');
  const appIcon = path.join(assets, 'AppIcon.appiconset', 'Contents.json');
  if (!fs.existsSync(appIcon)) {
    fail(appIcon, 0, 'AppIcon.appiconset/Contents.json 不存在（先运行 python Tools/make-icon.py）');
  } else {
    let catalog;
    try {
      catalog = JSON.parse(fs.readFileSync(appIcon, 'utf8'));
    } catch (error) {
      fail(appIcon, 0, `Contents.json 不是合法 JSON：${error.message}`);
    }
    if (catalog) {
      const images = Array.isArray(catalog.images) ? catalog.images : [];
      if (images.length < 15) {
        fail(appIcon, 0, `AppIcon 尺寸不足：${images.length} 项，应为完整尺寸集`);
      }
      const marketing = images.find(
        (entry) => entry.size === '1024x1024' && entry.idiom === 'ios-marketing',
      );
      const universal1024 = images.find(
        (entry) => entry.size === '1024x1024' && entry.idiom === 'universal' && entry.platform === 'ios',
      );
      if (!marketing) fail(appIcon, 0, 'AppIcon 缺少 ios-marketing 1024x1024');
      if (!universal1024) fail(appIcon, 0, 'AppIcon 缺少 Xcode 16 单尺寸 1024x1024（universal + platform ios）');
      for (const entry of images) {
        if (!entry.filename) continue;
        const file = path.join(assets, 'AppIcon.appiconset', entry.filename);
        if (!fs.existsSync(file)) {
          fail(appIcon, 0, `Contents.json 引用的文件不存在：${entry.filename}`);
          continue;
        }
        if (entry.size === '1024x1024' || entry.size === '83.5x83.5') {
          const png = readPngSize(file);
          const expected = entry.size === '1024x1024' ? 1024 : 167;
          if (!png || png.width !== png.height || png.width !== expected) {
            fail(file, 0, `${entry.filename} 尺寸不对（期望 ${expected}×${expected}）`);
          }
        }
      }
    }
  }

  for (const name of ['AccentColor.colorset', 'LaunchBackground.colorset']) {
    const manifest = path.join(assets, name, 'Contents.json');
    if (!fs.existsSync(manifest)) fail(manifest, 0, `${name} 缺失（Info.plist / 主题会引用它）`);
    else {
      try {
        const json = JSON.parse(fs.readFileSync(manifest, 'utf8'));
        if (!Array.isArray(json.colors) || json.colors.length === 0) {
          fail(manifest, 0, `${name} 没有 colors 条目`);
        }
      } catch (error) {
        fail(manifest, 0, `不是合法 JSON：${error.message}`);
      }
    }
  }

  const top = path.join(assets, 'Contents.json');
  if (!fs.existsSync(top)) fail(top, 0, 'Assets.xcassets/Contents.json 缺失');

  if (!fs.existsSync(THEME)) fail(THEME, 0, 'Design/Theme.swift 不存在，无法校验设计令牌');
}

// ---------------------------------------------------------------------------
// Run.
// ---------------------------------------------------------------------------

function walkSwift(dir, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walkSwift(full, out);
    else if (entry.isFile() && entry.name.endsWith('.swift')) out.push(full);
  }
  return out;
}

if (!fs.existsSync(SRC_ROOT)) {
  console.error(`FAIL — 源码目录不存在：${rel(SRC_ROOT)}`);
  process.exit(1);
}

const swiftFiles = walkSwift(SRC_ROOT).sort();
const masked = new Map();
for (const file of swiftFiles) {
  const src = fs.readFileSync(file, 'utf8');
  const { code, issues } = maskSource(src);
  masked.set(file, code);
  for (const issue of issues) fail(file, issue.line, issue.message);
}

// Panels are located in the *masked* code of every file.
const viewDecls = new Map();
for (const file of swiftFiles) {
  const code = masked.get(file);
  const re = /(?:^|\n)\s*(?:public\s+|internal\s+|private\s+|fileprivate\s+)?struct\s+(\w+)\s*(?::[^{]*)?\{/g;
  let match;
  while ((match = re.exec(code))) viewDecls.set(match[1], file);
}
for (const name of REQUIRED_VIEWS) {
  const owner = viewDecls.get(name);
  if (!owner) {
    fail(SRC_ROOT, 0, `缺少视图类型 struct ${name}: View（整个 ios/Meridian 里没有定义）`);
    continue;
  }
  const code = masked.get(owner);
  const decl = new RegExp(`struct\\s+${name}\\s*:\\s*View\\b`);
  if (!decl.test(code)) fail(owner, 0, `struct ${name} 没有声明为 : View`);
}

// Blacklist, on masked code only: a comment that says "no @Observable here"
// must not fail the build.
for (const [file, code] of masked) {
  const lines = code.split('\n');
  for (const [pattern, why] of FORBIDDEN) {
    for (let index = 0; index < lines.length; index += 1) {
      pattern.lastIndex = 0;
      if (pattern.test(lines[index])) {
        fail(file, index + 1, `禁用 API：${why}`);
      }
    }
  }
}

// Design-system members.
if (fs.existsSync(THEME)) {
  const members = themeMembers(fs.readFileSync(THEME, 'utf8'));
  const usageRe = /\b(Palette|Surface|Space|Radius|Typeface|Motion|Metrics)\.(\w+)/g;
  for (const [file, code] of masked) {
    if (path.resolve(file) === path.resolve(THEME)) continue;
    const lines = code.split('\n');
    for (let index = 0; index < lines.length; index += 1) {
      usageRe.lastIndex = 0;
      let match;
      while ((match = usageRe.exec(lines[index]))) {
        const namespace = match[1];
        const member = match[2];
        const known = members.get(namespace);
        if (!known || known.size === 0) {
          fail(file, index + 1, `${namespace} 在 Theme.swift 里没有定义`);
        } else if (!known.has(member)) {
          fail(file, index + 1, `${namespace}.${member} 未在 Theme.swift 定义（已知：${[...known].join(', ')}）`);
        }
      }
    }
  }
  if (members.get('Palette')?.size === 0) notes.push('Theme.swift 里没解析到 Palette 成员，设计系统校验可能失效');
}

checkProjectFiles();

const unique = [];
const seen = new Set();
for (const item of failures) {
  const key = `${item.file}:${item.line}:${item.message}`;
  if (!seen.has(key)) {
    seen.add(key);
    unique.push(item);
  }
}

if (unique.length > 0) {
  console.error(`FAIL — ${unique.length} 个问题 / ${swiftFiles.length} 个 Swift 文件\n`);
  for (const item of unique) {
    console.error(`  ${item.file}:${item.line}  ${item.message}`);
  }
  process.exit(1);
}

console.log(`PASS — ${swiftFiles.length} 个 Swift 文件，${viewDecls.size} 个类型`);
console.log('  ✓ 括号/引号/注释平衡');
console.log('  ✓ 无禁用 API（Observation / SwiftData / #Preview / iOS 18 Tab 等）');
console.log(`  ✓ 必需视图存在且为 : View（${REQUIRED_VIEWS.length} 个）`);
console.log('  ✓ Palette / Typeface / Motion / Space / Radius / Metrics 引用全部已定义');
console.log('  ✓ project.yml sources、Info.plist 关键键、AppIcon 1024、颜色集齐备');
for (const note of notes) console.log(`  ! ${note}`);
