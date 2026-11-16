#!/usr/bin/env node
// Meridian task server — the self-hosted backend for the Meridian clock.
//
// Zero npm dependencies: only node:http / node:fs / node:crypto / node:path /
// node:url. One file, one JSON data file, one bearer token. The wire contract
// lives in docs/API.md and mirrors ios/Meridian/Core/Models.swift; keep the
// two in step.
//
//   MERIDIAN_TOKEN=... node meridian-server.mjs
//
// Node 18+ (crypto.randomUUID, server.closeAllConnections).

import http from 'node:http';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import crypto from 'node:crypto';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const NAME = 'meridian';
const DEFAULT_PORT = 8787;
const MAX_BODY_BYTES = 64 * 1024;
const SSE_RETRY_MS = 3000;
const DEFAULT_HEARTBEAT_MS = 25_000;
const MAX_TITLE_LENGTH = 500;
const MAX_NOTE_LENGTH = 4000;
const MAX_DURATION_MINUTES = 24 * 60;
const TOKEN_COOKIE = 'meridian_token';
const COOKIE_MAX_AGE = 60 * 60 * 24 * 30;

// ---------------------------------------------------------------------------
// Time
// ---------------------------------------------------------------------------

/** UTC ISO 8601 without fractional seconds — the only date format on the wire. */
function isoTimestamp(date = new Date()) {
  return date.toISOString().replace(/\.\d{3}Z$/, 'Z');
}

const pad2 = (value) => String(value).padStart(2, '0');

/** Local calendar day, `yyyy-MM-dd`, never the device locale. */
function localDayKey(date = new Date()) {
  return `${date.getFullYear()}-${pad2(date.getMonth() + 1)}-${pad2(date.getDate())}`;
}

/** Short local wall-clock label for the /push footer. */
function localClockLabel(date = new Date()) {
  return `${pad2(date.getHours())}:${pad2(date.getMinutes())}`;
}

function isValidDayKey(value) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const [year, month, day] = value.split('-').map(Number);
  if (month < 1 || month > 12 || day < 1) return false;
  const probe = new Date(Date.UTC(year, month - 1, day));
  return (
    probe.getUTCFullYear() === year &&
    probe.getUTCMonth() === month - 1 &&
    probe.getUTCDate() === day
  );
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

class ApiError extends Error {
  constructor(status, error, message) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
    this.error = error;
  }
}

function errorBody(status, error, message) {
  return { error, code: status, message };
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

const has = (object, key) => Object.prototype.hasOwnProperty.call(object, key);

function requireString(value, field, maxLength, { allowEmpty = false, trim = false } = {}) {
  if (typeof value !== 'string') {
    throw new ApiError(400, 'validation_error', `${field} must be a string`);
  }
  const result = trim ? value.trim() : value;
  if (!allowEmpty && result === '') {
    throw new ApiError(400, 'validation_error', `${field} must not be empty`);
  }
  if (result.length > maxLength) {
    throw new ApiError(
      400,
      'validation_error',
      `${field} must be at most ${maxLength} characters`,
    );
  }
  return result;
}

/** Accepts `undefined` (absent), `null` (cleared) or an ISO 8601 string. */
function parseDateField(value, field) {
  if (value === undefined || value === null) return null;
  if (typeof value !== 'string' || value.trim() === '') {
    throw new ApiError(400, 'validation_error', `${field} must be an ISO 8601 timestamp`);
  }
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    throw new ApiError(400, 'validation_error', `${field} must be an ISO 8601 timestamp`);
  }
  return isoTimestamp(date);
}

function requireDay(value, field) {
  if (!isValidDayKey(value)) {
    throw new ApiError(
      400,
      'validation_error',
      `${field} must be a valid local calendar day formatted yyyy-MM-dd`,
    );
  }
  return value;
}

function requirePriority(value, field) {
  if (typeof value !== 'number' || !Number.isInteger(value) || value < 0 || value > 2) {
    throw new ApiError(400, 'validation_error', `${field} must be an integer 0, 1 or 2`);
  }
  return value;
}

function requireDuration(value, field) {
  if (
    typeof value !== 'number' ||
    !Number.isInteger(value) ||
    value < 1 ||
    value > MAX_DURATION_MINUTES
  ) {
    throw new ApiError(
      400,
      'validation_error',
      `${field} must be an integer between 1 and ${MAX_DURATION_MINUTES} minutes`,
    );
  }
  return value;
}

/** POST /api/v1/tasks body → a complete AgendaTask with server-owned fields. */
function buildNewTask(body) {
  if (!has(body, 'title') || typeof body.title !== 'string' || body.title.trim() === '') {
    throw new ApiError(400, 'validation_error', 'title is required');
  }
  const title = requireString(body.title, 'title', MAX_TITLE_LENGTH, { trim: true });

  const note =
    !has(body, 'note') || body.note === null
      ? ''
      : requireString(body.note, 'note', MAX_NOTE_LENGTH, { allowEmpty: true });

  const day = !has(body, 'day') || body.day === null ? localDayKey() : requireDay(body.day, 'day');

  const due = has(body, 'due') ? parseDateField(body.due, 'due') : null;

  const priority = !has(body, 'priority') || body.priority === null
    ? 0
    : requirePriority(body.priority, 'priority');

  const durationMinutes =
    !has(body, 'durationMinutes') || body.durationMinutes === null
      ? null
      : requireDuration(body.durationMinutes, 'durationMinutes');

  return {
    id: crypto.randomUUID(),
    title,
    note,
    day,
    due,
    priority,
    isDone: false,
    updatedAt: isoTimestamp(),
    origin: 'remote',
    durationMinutes,
  };
}

/** PATCH /api/v1/tasks/:id body → only the fields actually present. */
function buildTaskPatch(body) {
  const patch = {};

  if (has(body, 'title')) {
    if (typeof body.title !== 'string' || body.title.trim() === '') {
      throw new ApiError(400, 'validation_error', 'title must not be empty');
    }
    patch.title = requireString(body.title, 'title', MAX_TITLE_LENGTH, { trim: true });
  }
  if (has(body, 'note')) {
    patch.note =
      body.note === null
        ? ''
        : requireString(body.note, 'note', MAX_NOTE_LENGTH, { allowEmpty: true });
  }
  if (has(body, 'day')) {
    patch.day = requireDay(body.day, 'day');
  }
  if (has(body, 'due')) {
    patch.due = parseDateField(body.due, 'due');
  }
  if (has(body, 'priority')) {
    patch.priority = requirePriority(body.priority, 'priority');
  }
  if (has(body, 'isDone')) {
    if (typeof body.isDone !== 'boolean') {
      throw new ApiError(400, 'validation_error', 'isDone must be a boolean');
    }
    patch.isDone = body.isDone;
  }
  if (has(body, 'durationMinutes')) {
    patch.durationMinutes =
      body.durationMinutes === null
        ? null
        : requireDuration(body.durationMinutes, 'durationMinutes');
  }
  // `id`, `updatedAt` and `deleted` are part of TaskMutation on the client but
  // are server-owned / handled by DELETE; they are accepted and ignored.
  return Object.keys(patch).length > 0 ? patch : null;
}

// ---------------------------------------------------------------------------
// Ordering — mirrors AgendaTask.ordered in Models.swift
// ---------------------------------------------------------------------------

function compareTasks(a, b) {
  if (a.isDone !== b.isDone) return a.isDone ? 1 : -1;
  if (a.due !== null && b.due !== null && a.due !== b.due) return a.due < b.due ? -1 : 1;
  if (a.due === null && b.due !== null) return 1;
  if (a.due !== null && b.due === null) return -1;
  if (a.priority !== b.priority) return b.priority - a.priority;
  if (a.updatedAt === b.updatedAt) return 0;
  return a.updatedAt < b.updatedAt ? 1 : -1;
}

// ---------------------------------------------------------------------------
// Store — one JSON file, atomic replace, corrupt-file quarantine
// ---------------------------------------------------------------------------

function sanitizeStoredTask(raw) {
  if (!raw || typeof raw !== 'object') return null;
  if (typeof raw.id !== 'string' || raw.id === '') return null;
  if (typeof raw.title !== 'string') return null;

  const due =
    typeof raw.due === 'string' && !Number.isNaN(Date.parse(raw.due))
      ? isoTimestamp(new Date(raw.due))
      : null;
  const updatedAt =
    typeof raw.updatedAt === 'string' && !Number.isNaN(Date.parse(raw.updatedAt))
      ? isoTimestamp(new Date(raw.updatedAt))
      : isoTimestamp();

  return {
    id: raw.id,
    title: raw.title,
    note: typeof raw.note === 'string' ? raw.note : '',
    day: isValidDayKey(raw.day) ? raw.day : localDayKey(),
    due,
    priority: [0, 1, 2].includes(raw.priority) ? raw.priority : 0,
    isDone: raw.isDone === true,
    updatedAt,
    origin: raw.origin === 'local' ? 'local' : 'remote',
    durationMinutes:
      Number.isInteger(raw.durationMinutes) && raw.durationMinutes > 0
        ? Math.min(raw.durationMinutes, MAX_DURATION_MINUTES)
        : null,
  };
}

class TaskStore {
  constructor(dataFile, logger) {
    this.dataFile = dataFile;
    this.logger = logger;
    this.rev = 0;
    /** @type {Map<string, object>} */
    this.tasks = new Map();
    this.writeChain = Promise.resolve();
    this.load();
  }

  load() {
    let raw;
    try {
      raw = fs.readFileSync(this.dataFile, 'utf8');
    } catch (error) {
      if (error.code === 'ENOENT') return;
      throw error;
    }

    try {
      const parsed = JSON.parse(raw);
      if (!parsed || typeof parsed !== 'object' || !Array.isArray(parsed.tasks)) {
        throw new Error('unexpected data file shape');
      }
      const rev = Number.isInteger(parsed.rev) && parsed.rev >= 0 ? parsed.rev : 0;
      const tasks = new Map();
      for (const entry of parsed.tasks) {
        const task = sanitizeStoredTask(entry);
        if (task) tasks.set(task.id, task);
      }
      this.rev = rev;
      this.tasks = tasks;
    } catch {
      this.quarantineCorruptFile();
      this.rev = 0;
      this.tasks = new Map();
    }
  }

  quarantineCorruptFile() {
    const base = path.basename(this.dataFile);
    const stem = base.endsWith('.json') ? base.slice(0, -'.json'.length) : base;
    const stamp = new Date().toISOString().replace(/[:.]/g, '');
    const target = path.join(path.dirname(this.dataFile), `${stem}.corrupt-${stamp}.json`);
    try {
      fs.renameSync(this.dataFile, target);
      this.logger(
        `[meridian] data file was unreadable; backed it up to ${path.basename(target)} and started with an empty agenda`,
      );
    } catch (error) {
      this.logger(
        `[meridian] data file was unreadable and could not be backed up: ${error.message}`,
      );
    }
  }

  list(day) {
    const tasks = [...this.tasks.values()].filter((task) => !day || task.day === day);
    return tasks.sort(compareTasks);
  }

  get(id) {
    return this.tasks.get(id);
  }

  add(task) {
    this.tasks.set(task.id, task);
    this.rev += 1;
    return task;
  }

  update(id, patch) {
    const existing = this.tasks.get(id);
    // Spread keeps the canonical key order from creation.
    const merged = { ...existing, ...patch, updatedAt: isoTimestamp() };
    this.tasks.set(id, merged);
    this.rev += 1;
    return merged;
  }

  remove(id) {
    const removed = this.tasks.delete(id);
    if (removed) this.rev += 1;
    return removed;
  }

  serialize() {
    return `${JSON.stringify(
      { version: 1, rev: this.rev, tasks: [...this.tasks.values()] },
      null,
      2,
    )}\n`;
  }

  /** Queue writes so two concurrent mutations can never interleave renames. */
  persist() {
    const payload = this.serialize();
    const run = this.writeChain.then(() => this.writeAtomic(payload));
    this.writeChain = run.catch(() => {});
    return run;
  }

  async writeAtomic(payload) {
    const tmp = `${this.dataFile}.tmp-${process.pid}-${crypto.randomBytes(4).toString('hex')}`;
    try {
      await fsp.writeFile(tmp, payload, 'utf8');
      await fsp.rename(tmp, this.dataFile);
    } catch (error) {
      await fsp.rm(tmp, { force: true }).catch(() => {});
      throw error;
    }
  }
}

// ---------------------------------------------------------------------------
// HTTP plumbing
// ---------------------------------------------------------------------------

function corsHeaders() {
  return {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, PATCH, DELETE, OPTIONS',
    'Access-Control-Allow-Headers': 'Authorization, Content-Type',
    'Access-Control-Max-Age': '86400',
  };
}

function sendJson(res, status, body, extraHeaders = {}) {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    ...corsHeaders(),
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(payload),
    'Cache-Control': 'no-store',
    ...extraHeaders,
  });
  res.end(payload);
}

function sendHtml(res, status, html, extraHeaders = {}) {
  res.writeHead(status, {
    ...corsHeaders(),
    'Content-Type': 'text/html; charset=utf-8',
    'Content-Length': Buffer.byteLength(html),
    'Cache-Control': 'no-store',
    'Content-Security-Policy':
      "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'",
    ...extraHeaders,
  });
  res.end(html);
}

function sendNoContent(res, status) {
  res.writeHead(status, corsHeaders());
  res.end();
}

function methodNotAllowed(res, allowed) {
  return sendJson(
    res,
    405,
    errorBody(405, 'method_not_allowed', `allowed methods: ${allowed.join(', ')}`),
    { Allow: allowed.join(', ') },
  );
}

function bearerToken(req) {
  const header = req.headers.authorization;
  if (typeof header !== 'string') return null;
  const match = /^Bearer\s+(\S+)\s*$/i.exec(header.trim());
  return match ? match[1] : null;
}

function safeEqual(left, right) {
  if (typeof left !== 'string' || typeof right !== 'string') return false;
  const a = Buffer.from(left, 'utf8');
  const b = Buffer.from(right, 'utf8');
  if (a.length !== b.length) return false;
  return crypto.timingSafeEqual(a, b);
}

function readCookie(req, name) {
  const header = req.headers.cookie;
  if (typeof header !== 'string') return null;
  for (const part of header.split(';')) {
    const index = part.indexOf('=');
    if (index === -1) continue;
    if (part.slice(0, index).trim() !== name) continue;
    try {
      return decodeURIComponent(part.slice(index + 1).trim());
    } catch {
      return part.slice(index + 1).trim();
    }
  }
  return null;
}

function cookieHeader(value) {
  return `${TOKEN_COOKIE}=${encodeURIComponent(value)}; Path=/; HttpOnly; SameSite=Lax; Max-Age=${COOKIE_MAX_AGE}`;
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const declared = Number(req.headers['content-length'] ?? 0);
    if (Number.isFinite(declared) && declared > MAX_BODY_BYTES) {
      req.resume();
      reject(
        new ApiError(413, 'payload_too_large', `request body exceeds ${MAX_BODY_BYTES} bytes`),
      );
      return;
    }

    const chunks = [];
    let size = 0;
    let settled = false;

    const fail = (error) => {
      if (settled) return;
      settled = true;
      req.removeAllListeners('data');
      req.resume();
      reject(error);
    };

    req.on('data', (chunk) => {
      if (settled) return;
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        chunks.length = 0;
        fail(new ApiError(413, 'payload_too_large', `request body exceeds ${MAX_BODY_BYTES} bytes`));
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      if (settled) return;
      settled = true;
      resolve(Buffer.concat(chunks));
    });
    req.on('error', (error) => {
      if (settled) return;
      settled = true;
      reject(error);
    });
  });
}

function parseJsonObject(buffer) {
  let text = buffer.toString('utf8');
  if (text.charCodeAt(0) === 0xfeff) text = text.slice(1); // Windows editors like BOMs
  text = text.trim();
  if (text === '') {
    throw new ApiError(400, 'invalid_json', 'request body must be a JSON object');
  }
  let value;
  try {
    value = JSON.parse(text);
  } catch {
    throw new ApiError(400, 'invalid_json', 'request body is not valid JSON');
  }
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new ApiError(400, 'invalid_json', 'request body must be a JSON object');
  }
  return value;
}

function normalizePath(pathname) {
  const trimmed = pathname.replace(/\/+$/, '');
  return trimmed === '' ? '/' : trimmed;
}

// ---------------------------------------------------------------------------
// /push page — inline CSS, no scripts, no external assets, works offline
// ---------------------------------------------------------------------------

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (character) => {
    switch (character) {
      case '&':
        return '&amp;';
      case '<':
        return '&lt;';
      case '>':
        return '&gt;';
      case '"':
        return '&quot;';
      default:
        return '&#39;';
    }
  });
}

function formatDueForDisplay(due, day) {
  if (!due) return '';
  const date = new Date(due);
  if (Number.isNaN(date.getTime())) return '';
  const time = `${pad2(date.getHours())}:${pad2(date.getMinutes())}`;
  const today = localDayKey();
  if (day && day !== today) {
    const [, month, dayOfMonth] = day.split('-').map(Number);
    return `${month}月${dayOfMonth}日 ${time}`;
  }
  return time;
}

function renderTaskRows(tasks) {
  if (tasks.length === 0) {
    return '<p class="empty">还没有待办。加一条，iPad 上就看见了。</p>';
  }
  return `<ul class="tasks">${tasks
    .map((task) => {
      const due = formatDueForDisplay(task.due, task.day);
      const meta = [due, task.isDone ? '已完成' : ''].filter(Boolean).join(' · ');
      return `<li class="task${task.isDone ? ' done' : ''}">
        <span class="dot p${task.priority}" aria-hidden="true"></span>
        <div class="task-body">
          <p class="task-title">${escapeHtml(task.title)}</p>
          ${meta ? `<p class="task-meta">${escapeHtml(meta)}</p>` : ''}
        </div>
      </li>`;
    })
    .join('')}</ul>`;
}

const PAGE_STYLE = `
:root {
  color-scheme: dark;
  --canvas: #08090b;
  --surface-1: #0f1113;
  --surface-2: #14171a;
  --hairline: #23272c;
  --hairline-strong: #31363c;
  --ink: #f2eee7;
  --ink-muted: #a8a39a;
  --ink-subtle: #8b867d;
  --accent: #e0a662;
  --accent-soft: rgba(224, 166, 98, 0.16);
  --danger: #d99a92;
  --danger-line: rgba(201, 115, 106, 0.32);
  --radius: 12px;
  --radius-sm: 10px;
  --ease: cubic-bezier(0.2, 0.7, 0.2, 1);
}
* { box-sizing: border-box; }
html, body { margin: 0; }
body {
  min-height: 100dvh;
  background: var(--canvas);
  color: var(--ink);
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", Roboto,
    "Helvetica Neue", Arial, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif;
  font-size: 15px;
  line-height: 1.55;
  -webkit-font-smoothing: antialiased;
  text-rendering: optimizeLegibility;
  padding: max(22px, env(safe-area-inset-top)) 20px max(22px, env(safe-area-inset-bottom));
}
.shell { width: 100%; max-width: 460px; margin: 0 auto; }
.brand {
  display: flex; align-items: center; gap: 9px;
  margin-bottom: 30px;
}
.mark {
  width: 7px; height: 7px; border-radius: 50%;
  background: var(--accent);
  box-shadow: 0 0 0 3px var(--accent-soft);
}
.brand-name {
  font-size: 11px; font-weight: 600; letter-spacing: 0.18em;
  color: var(--ink-subtle);
  font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
}
h1 {
  margin: 0 0 6px;
  font-size: 24px; line-height: 1.2; font-weight: 600; letter-spacing: -0.025em;
}
.lede {
  margin: 0 0 22px;
  font-size: 13px; color: var(--ink-muted);
  max-width: 34em;
}
.notice, .error {
  margin: 0 0 16px;
  padding: 11px 13px;
  border-radius: var(--radius-sm);
  font-size: 13px;
  border: 1px solid;
}
.notice { background: rgba(224, 166, 98, 0.08); border-color: rgba(224, 166, 98, 0.24); color: var(--ink); }
.error { background: rgba(201, 115, 106, 0.08); border-color: var(--danger-line); color: var(--danger); }
.form { display: flex; flex-direction: column; gap: 16px; }
.field { display: flex; flex-direction: column; gap: 7px; }
.field label {
  font-size: 11px; font-weight: 600; letter-spacing: 0.09em;
  text-transform: uppercase; color: var(--ink-subtle);
}
input, select, button {
  font: inherit;
  color: var(--ink);
  width: 100%;
}
input, select {
  height: 46px;
  padding: 0 13px;
  font-size: 16px; /* 16px keeps iOS Safari from zooming on focus */
  background: var(--surface-1);
  border: 1px solid var(--hairline);
  border-radius: var(--radius-sm);
  outline: none;
  transition: border-color 160ms var(--ease), box-shadow 160ms var(--ease);
}
input::placeholder { color: var(--ink-subtle); }
input:focus, select:focus {
  border-color: var(--accent);
  box-shadow: 0 0 0 3px rgba(224, 166, 98, 0.18);
}
.row { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
button {
  height: 48px;
  border: 0;
  border-radius: var(--radius-sm);
  background: var(--accent);
  color: #17120a;
  font-weight: 600;
  letter-spacing: 0.01em;
  cursor: pointer;
  transition: background-color 160ms var(--ease), transform 120ms var(--ease);
}
button:hover { background: #eab378; }
button:active { transform: translateY(1px); }
button:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
.recent { margin-top: 34px; }
.section-head {
  display: flex; align-items: baseline; justify-content: space-between;
  padding-bottom: 10px;
}
h2 {
  margin: 0;
  font-size: 11px; font-weight: 600; letter-spacing: 0.14em;
  text-transform: uppercase; color: var(--ink-subtle);
}
.rev {
  font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
  font-size: 11px; color: var(--ink-subtle);
}
.tasks { list-style: none; margin: 0; padding: 0; border-top: 1px solid var(--hairline); }
.task { display: flex; gap: 12px; align-items: flex-start; padding: 13px 0; border-bottom: 1px solid var(--hairline); }
.dot { flex: 0 0 auto; width: 6px; height: 6px; margin-top: 8px; border-radius: 50%; background: var(--hairline-strong); }
.dot.p1 { background: var(--ink-muted); }
.dot.p2 { background: var(--accent); box-shadow: 0 0 0 3px var(--accent-soft); }
.task-body { min-width: 0; }
.task-title { margin: 0; font-size: 15px; overflow-wrap: anywhere; }
.task.done .task-title { color: var(--ink-subtle); text-decoration: line-through; text-decoration-color: var(--hairline-strong); }
.task-meta {
  margin: 2px 0 0;
  font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
  font-size: 12px; color: var(--ink-subtle);
}
.empty { margin: 0; padding: 16px 0; border-bottom: 1px solid var(--hairline); font-size: 13px; color: var(--ink-subtle); }
footer {
  margin-top: 30px;
  font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
  font-size: 11px; color: var(--ink-subtle);
  display: flex; justify-content: space-between; gap: 12px;
}
@keyframes rise {
  from { opacity: 0; transform: translateY(7px); }
  to { opacity: 1; transform: none; }
}
.brand, .compose, .recent, footer { animation: rise 340ms var(--ease) both; }
.compose { animation-delay: 30ms; }
.recent { animation-delay: 60ms; }
footer { animation-delay: 90ms; }
@media (prefers-reduced-motion: reduce) {
  .brand, .compose, .recent, footer { animation: none; }
  input, select, button { transition: none; }
}
@media (max-width: 360px) {
  .row { grid-template-columns: 1fr; }
}
`;

function pageShell({ title, main }) {
  return `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#08090b">
<meta name="color-scheme" content="dark">
<meta name="robots" content="noindex, nofollow">
<title>${escapeHtml(title)}</title>
<style>${PAGE_STYLE}</style>
</head>
<body>
<main class="shell">
${main}
</main>
</body>
</html>`;
}

function renderBrand() {
  return `<div class="brand"><span class="mark" aria-hidden="true"></span><span class="brand-name">MERIDIAN</span></div>`;
}

function renderLoginPage({ error = '' } = {}) {
  const main = `${renderBrand()}
<section class="compose">
  <h1>需要口令</h1>
  <p class="lede">输入服务器上配置的 MERIDIAN_TOKEN，就能从这台手机往墙上的时钟推任务。</p>
  ${error ? `<p class="error" role="alert">${escapeHtml(error)}</p>` : ''}
  <form class="form" method="post" action="/push">
    <div class="field">
      <label for="token">口令</label>
      <input id="token" name="token" type="password" required autocomplete="current-password" autofocus spellcheck="false">
    </div>
    <button type="submit">进入</button>
  </form>
</section>`;
  return pageShell({ title: 'Meridian · 口令', main });
}

function renderPushPage({ token, tasks, error = '', notice = '', rev = 0, serverClock = '' }) {
  const list = tasks.slice(0, 5);
  const main = `${renderBrand()}
<section class="compose">
  <h1>随手加一条</h1>
  <p class="lede">推到今天的待办，iPad 上几秒内就会多一行。</p>
  ${error ? `<p class="error" role="alert">${escapeHtml(error)}</p>` : ''}
  ${notice ? `<p class="notice" role="status">${escapeHtml(notice)}</p>` : ''}
  <form class="form" method="post" action="/push">
    <input type="hidden" name="token" value="${escapeHtml(token)}">
    <div class="field">
      <label for="title">待办</label>
      <input id="title" name="title" type="text" maxlength="500" required autocomplete="off"
        placeholder="例如：把投影仪还回去" enterkeyhint="done" autofocus>
    </div>
    <div class="row">
      <div class="field">
        <label for="due">时间</label>
        <input id="due" name="due" type="datetime-local" step="60">
      </div>
      <div class="field">
        <label for="priority">优先级</label>
        <select id="priority" name="priority">
          <option value="0">普通</option>
          <option value="1">重要</option>
          <option value="2">紧急</option>
        </select>
      </div>
    </div>
    <button type="submit">加入今日</button>
  </form>
</section>
<section class="recent">
  <div class="section-head"><h2>最近</h2><span class="rev">rev ${rev}</span></div>
  ${renderTaskRows(list)}
</section>
<footer><span>服务器 ${escapeHtml(serverClock)}</span><span>Meridian</span></footer>`;
  return pageShell({ title: 'Meridian · 加一条待办', main });
}

// ---------------------------------------------------------------------------
// Server factory
// ---------------------------------------------------------------------------

/**
 * @param {object} options
 * @param {string} options.token   required; server refuses to build without it
 * @param {string} [options.dataFile] absolute or relative path to data.json
 * @param {number} [options.heartbeatMs] SSE ping interval (tests shorten it)
 * @param {boolean} [options.silent] suppress request logging (tests)
 */
export function createServer(options = {}) {
  const token = typeof options.token === 'string' ? options.token : '';
  if (token.trim() === '') {
    throw new Error(
      'MERIDIAN_TOKEN is required — refusing to start without an auth token (fail closed)',
    );
  }

  const dataFile = path.resolve(
    options.dataFile ?? path.join(path.dirname(fileURLToPath(import.meta.url)), 'data.json'),
  );
  const heartbeatMs = options.heartbeatMs ?? DEFAULT_HEARTBEAT_MS;
  const logger = options.silent ? () => {} : (line) => console.log(line);

  fs.mkdirSync(path.dirname(dataFile), { recursive: true });
  const store = new TaskStore(dataFile, logger);
  /** @type {Set<{res: http.ServerResponse}>} */
  const sseClients = new Set();

  function snapshotPayload() {
    return {
      serverTime: isoTimestamp(),
      rev: store.rev,
      tasks: store.list(),
      message: null,
      weather: null,
    };
  }

  function healthPayload() {
    return { ok: true, name: NAME, rev: store.rev, time: isoTimestamp() };
  }

  function broadcast(event, data) {
    const frame = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
    for (const client of sseClients) {
      try {
        client.res.write(frame);
      } catch {
        sseClients.delete(client);
      }
    }
  }

  function closeSseClients() {
    for (const client of sseClients) {
      try {
        client.res.end();
      } catch {
        /* already gone */
      }
    }
    sseClients.clear();
  }

  function openStream(req, res) {
    res.writeHead(200, {
      ...corsHeaders(),
      'Content-Type': 'text/event-stream; charset=utf-8',
      'Cache-Control': 'no-cache, no-transform',
      Connection: 'keep-alive',
      'X-Accel-Buffering': 'no',
    });
    res.write(`retry: ${SSE_RETRY_MS}\n\n`);
    res.write(`event: snapshot\ndata: ${JSON.stringify(snapshotPayload())}\n\n`);

    const client = { res };
    sseClients.add(client);

    const heartbeat = setInterval(() => {
      if (res.writableEnded || res.destroyed) return;
      try {
        res.write(': ping\n\n');
      } catch {
        /* handled by close */
      }
    }, heartbeatMs);
    heartbeat.unref?.();

    const cleanup = () => {
      clearInterval(heartbeat);
      sseClients.delete(client);
    };
    req.on('close', cleanup);
    res.on('close', cleanup);
    res.on('error', cleanup);
  }

  async function handleCreateTask(req, res) {
    const body = parseJsonObject(await readBody(req));
    const task = buildNewTask(body);
    store.add(task);
    await store.persist();
    broadcast('task', task);
    return sendJson(res, 201, task);
  }

  async function handlePatchTask(req, res, id) {
    const existing = store.get(id);
    if (!existing) {
      return sendJson(res, 404, errorBody(404, 'not_found', `no task with id ${id}`));
    }
    const body = parseJsonObject(await readBody(req));
    const patch = buildTaskPatch(body);
    if (!patch) return sendJson(res, 200, existing);

    const merged = store.update(id, patch);
    await store.persist();
    broadcast('task', merged);
    return sendJson(res, 200, merged);
  }

  async function handleDeleteTask(res, id) {
    const removed = store.remove(id);
    if (removed) {
      await store.persist();
      broadcast('delete', { id });
    }
    // Idempotent by contract: a missing task is still 204.
    return sendNoContent(res, 204);
  }

  async function routeApi(req, res, url, pathname) {
    const method = req.method;

    if (pathname === '/api/v1/snapshot') {
      if (method !== 'GET') return methodNotAllowed(res, ['GET']);
      return sendJson(res, 200, snapshotPayload());
    }

    if (pathname === '/api/v1/tasks') {
      if (method === 'GET') {
        const dayParam = url.searchParams.get('day');
        if (dayParam !== null && !isValidDayKey(dayParam)) {
          return sendJson(
            res,
            400,
            errorBody(400, 'validation_error', 'day must be a valid yyyy-MM-dd local calendar day'),
          );
        }
        return sendJson(res, 200, { rev: store.rev, tasks: store.list(dayParam ?? undefined) });
      }
      if (method === 'POST') return handleCreateTask(req, res);
      return methodNotAllowed(res, ['GET', 'POST']);
    }

    if (pathname === '/api/v1/stream') {
      if (method !== 'GET') return methodNotAllowed(res, ['GET']);
      return openStream(req, res);
    }

    const taskMatch = /^\/api\/v1\/tasks\/([^/]+)$/.exec(pathname);
    if (taskMatch) {
      let id;
      try {
        id = decodeURIComponent(taskMatch[1]);
      } catch {
        return sendJson(res, 400, errorBody(400, 'validation_error', 'malformed task id'));
      }
      if (method === 'PATCH') return handlePatchTask(req, res, id);
      if (method === 'DELETE') return handleDeleteTask(res, id);
      return methodNotAllowed(res, ['PATCH', 'DELETE']);
    }

    return sendJson(res, 404, errorBody(404, 'not_found', `no route for ${method} ${pathname}`));
  }

  async function handlePushGet(req, res, url) {
    const queryToken = url.searchParams.get('token');
    const cookieToken = readCookie(req, TOKEN_COOKIE);
    const authedViaQuery =
      queryToken !== null && queryToken !== '' && safeEqual(queryToken, token);
    const authed = authedViaQuery || safeEqual(cookieToken, token);

    if (!authed) {
      return sendHtml(res, 200, renderLoginPage());
    }

    const extraHeaders = authedViaQuery ? { 'Set-Cookie': cookieHeader(token) } : {};
    return sendHtml(
      res,
      200,
      renderPushPage({
        token,
        tasks: store
          .list()
          .sort((a, b) => (a.updatedAt < b.updatedAt ? 1 : a.updatedAt > b.updatedAt ? -1 : 0)),
        rev: store.rev,
        serverClock: localClockLabel(),
      }),
      extraHeaders,
    );
  }

  async function handlePushPost(req, res, url) {
    const buffer = await readBody(req);
    const bodyText = buffer.toString('utf8').replace(/^\uFEFF/, '');
    const form = new URLSearchParams(bodyText);

    // Any of the three carriers may authenticate: the hidden form field, the
    // cookie from a previous ?token= visit, or the query string.
    const candidates = [
      form.get('token'),
      readCookie(req, TOKEN_COOKIE),
      url.searchParams.get('token'),
    ];
    if (!candidates.some((candidate) => safeEqual(candidate, token))) {
      return sendHtml(res, 401, renderLoginPage({ error: '口令不对，再试一次。' }));
    }

    // A form with no title is a login: set the cookie and bounce to the form.
    if (!form.has('title')) {
      res.writeHead(303, { ...corsHeaders(), Location: '/push', 'Set-Cookie': cookieHeader(token) });
      return res.end();
    }

    const dueRaw = (form.get('due') ?? '').trim();
    const priorityRaw = (form.get('priority') ?? '0').trim();

    try {
      const title = (form.get('title') ?? '').trim();
      if (title === '') {
        throw new ApiError(400, 'validation_error', '待办内容不能为空');
      }
      if (title.length > MAX_TITLE_LENGTH) {
        throw new ApiError(400, 'validation_error', `待办最多 ${MAX_TITLE_LENGTH} 个字`);
      }

      let due = null;
      let day = localDayKey();
      if (dueRaw !== '') {
        if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?$/.test(dueRaw)) {
          throw new ApiError(400, 'validation_error', '时间格式不对');
        }
        // datetime-local has no offset: interpret it in the server's local zone.
        const localDate = new Date(dueRaw);
        if (Number.isNaN(localDate.getTime())) {
          throw new ApiError(400, 'validation_error', '时间格式不对');
        }
        due = isoTimestamp(localDate);
        day = localDayKey(localDate);
      }

      const priority =
        priorityRaw === '' ? 0 : requirePriority(Number(priorityRaw), 'priority');

      const task = {
        id: crypto.randomUUID(),
        title,
        note: '',
        day,
        due,
        priority,
        isDone: false,
        updatedAt: isoTimestamp(),
        origin: 'remote',
        durationMinutes: null,
      };
      store.add(task);
      await store.persist();
      broadcast('task', task);

      return sendHtml(
        res,
        200,
        renderPushPage({
          token,
          tasks: store
            .list()
            .sort((a, b) => (a.updatedAt < b.updatedAt ? 1 : a.updatedAt > b.updatedAt ? -1 : 0)),
          rev: store.rev,
          serverClock: localClockLabel(),
          notice: `已加入「${title}」`,
        }),
        { 'Set-Cookie': cookieHeader(token) },
      );
    } catch (error) {
      if (!(error instanceof ApiError)) throw error;
      return sendHtml(
        res,
        400,
        renderPushPage({
          token,
          tasks: store
            .list()
            .sort((a, b) => (a.updatedAt < b.updatedAt ? 1 : a.updatedAt > b.updatedAt ? -1 : 0)),
          rev: store.rev,
          serverClock: localClockLabel(),
          error: error.message,
        }),
        { 'Set-Cookie': cookieHeader(token) },
      );
    }
  }

  async function handle(req, res) {
    const startedAt = process.hrtime.bigint();
    let pathname = '/';
    let logged = false;
    const logOnce = () => {
      if (logged) return;
      logged = true;
      const elapsedMs = Number(process.hrtime.bigint() - startedAt) / 1e6;
      logger(`${req.method} ${pathname} ${res.statusCode} ${elapsedMs.toFixed(1)}ms`);
    };
    res.on('finish', logOnce);
    res.on('close', logOnce);

    try {
      const url = new URL(req.url ?? '/', `http://${req.headers.host ?? 'localhost'}`);
      pathname = normalizePath(url.pathname);

      if (req.method === 'OPTIONS') {
        return sendNoContent(res, 204);
      }

      if (pathname === '/health') {
        if (req.method !== 'GET') return methodNotAllowed(res, ['GET']);
        return sendJson(res, 200, healthPayload());
      }

      // `/api/health` is the same payload as `/health`. The public portal is
      // served under /meridian/ and proxies /meridian/api/* here, so without
      // this alias the status card would need a token it must not have.
      if (pathname === '/api/health') {
        if (req.method !== 'GET') return methodNotAllowed(res, ['GET']);
        return sendJson(res, 200, healthPayload());
      }

      if (pathname === '/push') {
        if (req.method === 'GET') return await handlePushGet(req, res, url);
        if (req.method === 'POST') return await handlePushPost(req, res, url);
        return methodNotAllowed(res, ['GET', 'POST']);
      }

      if (pathname === '/api' || pathname.startsWith('/api/')) {
        // EventSource cannot set headers, so the SSE endpoint also accepts
        // ?token=; every other /api route only trusts the Authorization header.
        const presented =
          bearerToken(req) ??
          (pathname === '/api/v1/stream' ? url.searchParams.get('token') : null);
        if (!safeEqual(presented, token)) {
          return sendJson(res, 401, errorBody(401, 'unauthorized', 'missing or invalid bearer token'), {
            'WWW-Authenticate': 'Bearer realm="meridian"',
          });
        }
        return await routeApi(req, res, url, pathname);
      }

      return sendJson(res, 404, errorBody(404, 'not_found', `no route for ${req.method} ${pathname}`));
    } catch (error) {
      if (error instanceof ApiError) {
        if (!res.headersSent) {
          return sendJson(res, error.status, errorBody(error.status, error.error, error.message));
        }
        res.destroy();
        return;
      }
      logger(`[meridian] unhandled error: ${error && error.stack ? error.stack : error}`);
      if (!res.headersSent) {
        return sendJson(
          res,
          500,
          errorBody(500, 'internal_error', 'internal server error'),
        );
      }
      res.destroy();
    }
  }

  const server = http.createServer((req, res) => {
    handle(req, res).catch((error) => {
      logger(`[meridian] top-level error: ${error && error.stack ? error.stack : error}`);
      if (!res.headersSent) {
        sendJson(res, 500, errorBody(500, 'internal_error', 'internal server error'));
      } else {
        res.destroy();
      }
    });
  });

  server.on('close', closeSseClients);
  // Exposed for the CLI's graceful shutdown (end SSE, then close).
  server.meridian = { store, closeSseClients, dataFile };

  return server;
}

// ---------------------------------------------------------------------------
// CLI entry
// ---------------------------------------------------------------------------

const isEntryPoint =
  process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href;

if (isEntryPoint) {
  const token = (process.env.MERIDIAN_TOKEN ?? '').trim();
  if (token === '') {
    console.error('[meridian] MERIDIAN_TOKEN is not set — refusing to start (fail closed).');
    console.error('[meridian] generate one with: openssl rand -hex 24');
    process.exit(1);
  }

  const port = Number(process.env.MERIDIAN_PORT ?? DEFAULT_PORT);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    console.error(`[meridian] MERIDIAN_PORT must be a port number, got: ${process.env.MERIDIAN_PORT}`);
    process.exit(1);
  }

  const host = (process.env.MERIDIAN_HOST ?? '').trim() || '0.0.0.0';
  const dataFile = path.resolve(
    process.env.MERIDIAN_DATA?.trim() ||
      path.join(path.dirname(fileURLToPath(import.meta.url)), 'data.json'),
  );

  let server;
  try {
    server = createServer({ token, dataFile });
  } catch (error) {
    console.error(`[meridian] ${error.message}`);
    process.exit(1);
  }

  server.on('error', (error) => {
    console.error(`[meridian] server error: ${error.message}`);
    process.exit(1);
  });

  server.listen(port, host, () => {
    const address = server.address();
    console.log(`[meridian] listening on http://${host}:${address.port}`);
    console.log(`[meridian] data file: ${dataFile}`);
    console.log(`[meridian] push page: http://<this-host>:${address.port}/push`);
  });

  let shuttingDown = false;
  const shutdown = (signal) => {
    if (shuttingDown) return;
    shuttingDown = true;
    console.log(`[meridian] ${signal} received, shutting down`);
    server.meridian.closeSseClients();
    server.close(() => process.exit(0));
    // Keep-alive sockets (or a stuck client) must not block the exit forever.
    setTimeout(() => {
      server.closeAllConnections?.();
      process.exit(0);
    }, 1500).unref();
  };
  process.on('SIGINT', () => shutdown('SIGINT'));
  process.on('SIGTERM', () => shutdown('SIGTERM'));
}
