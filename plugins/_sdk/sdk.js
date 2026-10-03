// Minimal Stream Deck SDK client for OpenDeck plugins. No dependencies (Node 22+).
// Usage: const { connect } = require('./_sdk/sdk'); connect({ keyDown(ev, deck) {...} });
//
// Security notes for plugin authors:
//  - Per-action settings travel inside shareable profiles. Treat them as untrusted input.
//  - Keep secrets (tokens) in global settings only.
//  - Never build shell strings from settings. Use run() below, which has no shell.
'use strict';
const { execFile } = require('child_process');

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith('-') && i + 1 < argv.length) out[argv[i].slice(1)] = argv[++i];
  }
  return out;
}

// Returns a plain object from untrusted settings, or {}.
function settings(ev) {
  const s = ev && ev.payload && ev.payload.settings;
  return s && typeof s === 'object' && !Array.isArray(s) ? s : {};
}

function str(v, max = 256) {
  return typeof v === 'string' ? v.slice(0, max) : '';
}

// Parses and checks a base URL. Throws on anything other than http(s).
function baseUrl(raw) {
  const u = new URL(str(raw, 512));
  if (u.protocol !== 'http:' && u.protocol !== 'https:') throw new Error('URL must be http or https');
  if (u.username || u.password) throw new Error('URL must not contain credentials');
  return u.origin + u.pathname.replace(/\/+$/, '');
}

// fetch with timeout, no redirects, and a response size cap. Returns { status, ok, json() , text }.
async function fetchLimited(url, init = {}, { timeoutMs = 8000, maxBytes = 1 << 20 } = {}) {
  const r = await fetch(url, { ...init, redirect: 'error', signal: AbortSignal.timeout(timeoutMs) });
  const reader = r.body && r.body.getReader();
  const chunks = [];
  let total = 0;
  if (reader) {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.length;
      if (total > maxBytes) { await reader.cancel(); throw new Error('response too large'); }
      chunks.push(value);
    }
  }
  const text = Buffer.concat(chunks).toString('utf8');
  return { status: r.status, ok: r.ok, text, json: () => JSON.parse(text) };
}

// Run a program with an argv array and NO shell. Resolves with stdout.
function run(file, args = [], { timeoutMs = 10000 } = {}) {
  return new Promise((resolve, reject) => {
    if (typeof file !== 'string' || !file || !Array.isArray(args) || !args.every((a) => typeof a === 'string')) {
      return reject(new Error('run() needs a program and string arguments'));
    }
    execFile(file, args, { timeout: timeoutMs, maxBuffer: 1 << 20, shell: false }, (err, stdout) => (err ? reject(err) : resolve(stdout)));
  });
}

// Per-key guard: ignore a call while one is already running for this context, and enforce a minimum gap.
function guard(minGapMs = 300) {
  const busy = new Map();
  return async (context, fn) => {
    const now = Date.now();
    const last = busy.get(context);
    if (last === 'running' || (typeof last === 'number' && now - last < minGapMs)) return false;
    busy.set(context, 'running');
    try { await fn(); } finally { busy.set(context, Date.now()); }
    return true;
  };
}

function connect(handlers, argv = process.argv.slice(2)) {
  const args = parseArgs(argv);
  if (!/^\d{1,5}$/.test(args.port || '')) throw new Error('missing or invalid -port');
  let info = {};
  try { info = args.info ? JSON.parse(args.info) : {}; } catch { /* host-supplied, ignore */ }

  const ws = new WebSocket(`ws://127.0.0.1:${args.port}`);
  const queue = [];
  const send = (msg) => {
    if (ws.readyState === 1) ws.send(JSON.stringify(msg));
    else if (ws.readyState === 0) queue.push(msg); // not open yet, flush on open
  };

  const deck = {
    uuid: args.pluginUUID,
    info,
    send,
    setTitle: (context, title, state) => send({ event: 'setTitle', context, payload: { title, target: 0, state } }),
    setImage: (context, image, state) => send({ event: 'setImage', context, payload: { image, target: 0, state } }),
    setState: (context, state) => send({ event: 'setState', context, payload: { state } }),
    setSettings: (context, payload) => send({ event: 'setSettings', context, payload }),
    getSettings: (context) => send({ event: 'getSettings', context }),
    setGlobalSettings: (payload) => send({ event: 'setGlobalSettings', context: args.pluginUUID, payload }),
    getGlobalSettings: () => send({ event: 'getGlobalSettings', context: args.pluginUUID }),
    showOk: (context) => send({ event: 'showOk', context }),
    showAlert: (context) => send({ event: 'showAlert', context }),
    // Logs a message only. Never pass tokens or whole request objects here.
    log: (message) => send({ event: 'logMessage', payload: { message: String(message).slice(0, 500) } }),
  };

  ws.addEventListener('open', () => {
    send({ event: args.registerEvent, uuid: args.pluginUUID });
    while (queue.length) send(queue.shift());
  });
  ws.addEventListener('error', () => process.stderr.write('websocket error\n'));
  ws.addEventListener('close', () => process.exit(0));
  ws.addEventListener('message', async (m) => {
    let ev;
    try { ev = JSON.parse(m.data); } catch { return; }
    if (!ev || typeof ev.event !== 'string' || !Object.hasOwn(handlers, ev.event)) return;
    try { await handlers[ev.event](ev, deck); } catch (e) { deck.log(`${ev.event} handler failed: ${e && e.message}`); }
  });
  return deck;
}

module.exports = { connect, parseArgs, settings, str, baseUrl, fetchLimited, run, guard };
