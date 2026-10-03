'use strict';
let sdk;
try { sdk = require('./_sdk/sdk'); } catch { sdk = require('../_sdk/sdk'); }

const POLL_MS = 5000;
const actions = new Map(); // context -> settings
let global = { baseUrl: '', token: '' };

function api(path, init = {}) {
  const base = (global.baseUrl || '').replace(/\/+$/, '');
  if (!base || !global.token) throw new Error('Home Assistant URL or token not set');
  return fetch(base + path, {
    ...init,
    headers: { Authorization: `Bearer ${global.token}`, 'Content-Type': 'application/json', ...init.headers },
    signal: AbortSignal.timeout(8000),
  });
}

async function callService(s) {
  const [domain, service] = String(s.service || '').split('.');
  if (!domain || !service) throw new Error('Service must look like light.toggle');
  let data = {};
  if (s.data && s.data.trim()) data = JSON.parse(s.data);
  if (s.entity) data.entity_id = s.entity;
  const r = await api(`/api/services/${domain}/${service}`, { method: 'POST', body: JSON.stringify(data) });
  if (!r.ok) throw new Error(`HA returned ${r.status}`);
}

async function refresh(context, deck) {
  const s = actions.get(context);
  if (!s || !s.entity || !s.showState) return;
  try {
    const r = await api(`/api/states/${encodeURIComponent(s.entity)}`);
    if (!r.ok) throw new Error(String(r.status));
    const st = await r.json();
    const unit = st.attributes && st.attributes.unit_of_measurement ? ` ${st.attributes.unit_of_measurement}` : '';
    const name = s.label || (st.attributes && st.attributes.friendly_name) || s.entity;
    deck.setTitle(context, `${name}\n${st.state}${unit}`);
    // State 0 = off/unavailable look, 1 = on look (only matters if the user gave two images).
    deck.setState(context, st.state === 'on' ? 1 : 0);
  } catch (e) {
    deck.setTitle(context, `${s.label || s.entity}\n?`);
  }
}

const deck = sdk.connect({
  didReceiveGlobalSettings(ev, d) {
    global = { ...global, ...(ev.payload.settings || {}) };
    for (const c of actions.keys()) refresh(c, d);
  },
  willAppear(ev, d) {
    actions.set(ev.context, ev.payload.settings || {});
    if (ev.payload.settings && ev.payload.settings.label && !ev.payload.settings.showState) {
      d.setTitle(ev.context, ev.payload.settings.label);
    }
    refresh(ev.context, d);
  },
  willDisappear(ev) { actions.delete(ev.context); },
  didReceiveSettings(ev, d) {
    actions.set(ev.context, ev.payload.settings || {});
    refresh(ev.context, d);
  },
  async keyDown(ev, d) {
    const s = actions.get(ev.context) || ev.payload.settings || {};
    try {
      await callService(s);
      d.showOk(ev.context);
      setTimeout(() => refresh(ev.context, d), 500);
    } catch (e) {
      d.log(`service call failed: ${e.message}`);
      d.showAlert(ev.context);
    }
  },
});

deck.getGlobalSettings();
setInterval(() => { for (const c of actions.keys()) refresh(c, deck); }, POLL_MS);
