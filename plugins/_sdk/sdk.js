// Minimal Stream Deck SDK client for OpenDeck plugins. No dependencies (Node 22+).
// Usage: const { connect } = require('./_sdk/sdk'); connect({ keyDown(ev, deck) {...} });
'use strict';

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith('-') && i + 1 < argv.length) out[argv[i].slice(1)] = argv[++i];
  }
  return out;
}

function connect(handlers, argv = process.argv.slice(2)) {
  const args = parseArgs(argv);
  const ws = new WebSocket(`ws://127.0.0.1:${args.port}`);
  const queue = [];
  const send = (msg) => {
    if (ws.readyState === 1) ws.send(JSON.stringify(msg));
    else if (ws.readyState === 0) queue.push(msg); // not open yet, flush on open
  };

  const deck = {
    uuid: args.pluginUUID,
    info: args.info ? JSON.parse(args.info) : {},
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
    log: (message) => send({ event: 'logMessage', payload: { message: String(message) } }),
  };

  ws.addEventListener('open', () => {
    send({ event: args.registerEvent, uuid: args.pluginUUID });
    while (queue.length) send(queue.shift());
  });
  ws.addEventListener('close', () => process.exit(0));
  ws.addEventListener('message', async (m) => {
    let ev;
    try { ev = JSON.parse(m.data); } catch { return; }
    const h = handlers[ev.event];
    if (!h) return;
    try { await h(ev, deck); } catch (e) { deck.log(`${ev.event} handler failed: ${e && e.stack || e}`); }
  });
  return deck;
}

module.exports = { connect, parseArgs };
