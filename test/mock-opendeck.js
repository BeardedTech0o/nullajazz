'use strict';
// Fake OpenDeck host + fake Home Assistant. Spawns the plugin and checks the Stream Deck protocol round trip.
// Run: node test/mock-opendeck.js
const http = require('http');
const { spawn } = require('child_process');
const path = require('path');
const assert = require('assert');

const PLUGIN = path.join(__dirname, '..', 'plugins', 'homeassistant.sdPlugin', 'plugin.js');
const CTX = 'ctx1';
const seen = { ha: [], sd: [] };

const ha = http.createServer((req, res) => {
  let body = '';
  req.on('data', (c) => (body += c));
  req.on('end', () => {
    seen.ha.push({ method: req.method, url: req.url, auth: req.headers.authorization, body });
    res.setHeader('Content-Type', 'application/json');
    if (req.url.startsWith('/api/states/')) res.end(JSON.stringify({ state: 'on', attributes: { friendly_name: 'Desk' } }));
    else res.end('[]');
  });
});

ha.listen(0, '127.0.0.1', async () => {
  const haPort = ha.address().port;
  const { WebSocketServer } = (() => { try { return require('ws'); } catch { return {}; } })();
  assert(!WebSocketServer, 'unexpected ws dependency');

  // Node has no built-in WebSocket server, so speak a minimal RFC6455 server by hand.
  const net = require('net');
  const crypto = require('crypto');
  const frame = (obj) => {
    const p = Buffer.from(JSON.stringify(obj));
    const h = p.length < 126 ? Buffer.from([0x81, p.length]) : Buffer.from([0x81, 126, p.length >> 8, p.length & 255]);
    return Buffer.concat([h, p]);
  };
  const parse = (buf) => {
    const out = [];
    let i = 0;
    while (i + 2 <= buf.length) {
      let len = buf[i + 1] & 0x7f, off = i + 2;
      if (len === 126) { len = buf.readUInt16BE(off); off += 2; }
      const mask = buf.slice(off, off + 4); off += 4;
      const data = Buffer.from(buf.slice(off, off + len)).map((b, k) => b ^ mask[k % 4]);
      if ((buf[i] & 0x0f) === 1) out.push(JSON.parse(data.toString()));
      i = off + len;
    }
    return out;
  };

  const wss = net.createServer((sock) => {
    let upgraded = false;
    sock.on('data', (d) => {
      if (!upgraded) {
        const key = /Sec-WebSocket-Key: (.+)\r\n/i.exec(d.toString())[1].trim();
        const acc = crypto.createHash('sha1').update(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
        sock.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${acc}\r\n\r\n`);
        upgraded = true;
        return;
      }
      for (const m of parse(d)) {
        seen.sd.push(m);
        if (m.event === 'registerPlugin') {
          sock.write(frame({ event: 'didReceiveGlobalSettings', payload: { settings: { baseUrl: `http://127.0.0.1:${haPort}`, token: 'TESTTOKEN' } } }));
          sock.write(frame({ event: 'willAppear', action: 'dev.nullajazz.homeassistant.service', context: CTX, payload: { settings: { service: 'light.toggle', entity: 'light.desk', showState: true } } }));
          setTimeout(() => sock.write(frame({ event: 'keyDown', context: CTX, payload: { settings: {} } })), 400);
        }
      }
    });
  });

  wss.listen(0, '127.0.0.1', () => {
    const child = spawn('node', [PLUGIN, '-port', String(wss.address().port), '-pluginUUID', 'uuid1', '-registerEvent', 'registerPlugin', '-info', '{}'], { stdio: 'inherit' });
    setTimeout(() => {
      try {
        assert(seen.sd.some((m) => m.event === 'registerPlugin'), 'plugin did not register');
        assert(seen.sd.some((m) => m.event === 'getGlobalSettings'), 'plugin did not request global settings');
        const title = seen.sd.find((m) => m.event === 'setTitle');
        assert(title && /Desk\non/.test(title.payload.title), 'state title not set: ' + JSON.stringify(title));
        const call = seen.ha.find((r) => r.method === 'POST');
        assert(call && call.url === '/api/services/light/toggle', 'service not called');
        assert.strictEqual(call.auth, 'Bearer TESTTOKEN');
        assert.deepStrictEqual(JSON.parse(call.body), { entity_id: 'light.desk' });
        assert(seen.sd.some((m) => m.event === 'showOk'), 'no showOk');
        console.log('PASS');
        process.exitCode = 0;
      } catch (e) {
        console.error('FAIL:', e.message);
        process.exitCode = 1;
      } finally {
        child.kill();
        wss.close();
        ha.close();
        setTimeout(() => process.exit(process.exitCode), 100);
      }
    }, 2000);
  });
});
