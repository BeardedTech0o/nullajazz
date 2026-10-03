'use strict';
let sdk;
try { sdk = require('./_sdk/sdk'); } catch { sdk = require('../_sdk/sdk'); }

const POLL_MS = 5000;
const SERVICE_RE = /^[a-z0-9_]+\.[a-z0-9_]+$/;
const ENTITY_RE = /^[a-z0-9_]+\.[a-z0-9_]+$/;
const actions = new Map(); // context -> settings
const refreshing = new Set(); // contexts with a poll in flight
const press = sdk.guard(300);
let global = { baseUrl: '', token: '' };

function api(path, init = {}) {
  const base = sdk.baseUrl(global.baseUrl);
  const token = sdk.str(global.token, 512);
  if (!token) throw new Error('Home Assistant token not set');
  return sdk.fetchLimited(base + path, {
    ...init,
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
  });
}

function cleanSettings(raw) {
  const s = raw && typeof raw === 'object' && !Array.isArray(raw) ? raw : {};
  return {
    service: sdk.str(s.service, 100),
    entity: sdk.str(s.entity, 100),
    data: sdk.str(s.data, 2000),
    label: sdk.str(s.label, 40),
    showState: s.showState === true,
  };
}

async function callService(s) {
  if (!SERVICE_RE.test(s.service)) throw new Error('Service must look like light.toggle');
  if (s.entity && !ENTITY_RE.test(s.entity)) throw new Error('Entity must look like light.desk');
  const [domain, service] = s.service.split('.');
  let data = {};
  if (s.data.trim()) {
    data = JSON.parse(s.data);
    if (!data || typeof data !== 'object' || Array.isArray(data)) throw new Error('Extra data must be a JSON object');
  }
  if (s.entity) data.entity_id = s.entity;
  const r = await api(`/api/services/${encodeURIComponent(domain)}/${encodeURIComponent(service)}`, {
    method: 'POST',
    body: JSON.stringify(data),
  });
  if (!r.ok) throw new Error(`HA returned ${r.status}`);
}

async function refresh(context, deck) {
  const s = actions.get(context);
  if (!s || !s.entity || !s.showState || refreshing.has(context)) return;
  refreshing.add(context);
  try {
    if (!ENTITY_RE.test(s.entity)) throw new Error('bad entity');
    const r = await api(`/api/states/${encodeURIComponent(s.entity)}`);
    if (!r.ok) throw new Error(String(r.status));
    const st = r.json();
    const attrs = st && typeof st.attributes === 'object' && st.attributes ? st.attributes : {};
    const unit = typeof attrs.unit_of_measurement === 'string' ? ` ${attrs.unit_of_measurement.slice(0, 8)}` : '';
    const name = s.label || (typeof attrs.friendly_name === 'string' ? attrs.friendly_name.slice(0, 20) : s.entity);
    deck.setTitle(context, `${name}\n${String(st.state).slice(0, 20)}${unit}`);
    // State 0 = off/unavailable look, 1 = on look (only matters if the user gave two images).
    deck.setState(context, st.state === 'on' ? 1 : 0);
  } catch {
    deck.setTitle(context, `${s.label || s.entity}\n?`);
  } finally {
    refreshing.delete(context);
  }
}

const deck = sdk.connect({
  didReceiveGlobalSettings(ev, d) {
    const g = sdk.settings(ev);
    global = { baseUrl: sdk.str(g.baseUrl, 512), token: sdk.str(g.token, 512) };
    for (const c of actions.keys()) refresh(c, d);
  },
  willAppear(ev, d) {
    const s = cleanSettings(sdk.settings(ev));
    actions.set(ev.context, s);
    if (s.label && !s.showState) d.setTitle(ev.context, s.label);
    refresh(ev.context, d);
  },
  willDisappear(ev) { actions.delete(ev.context); },
  didReceiveSettings(ev, d) {
    actions.set(ev.context, cleanSettings(sdk.settings(ev)));
    refresh(ev.context, d);
  },
  async keyDown(ev, d) {
    const s = actions.get(ev.context);
    if (!s) return;
    await press(ev.context, async () => {
      try {
        await callService(s);
        d.showOk(ev.context);
        setTimeout(() => refresh(ev.context, d), 500);
      } catch (e) {
        d.log(`service call failed: ${e.message}`);
        d.showAlert(ev.context);
      }
    });
  },
});

deck.getGlobalSettings();
setInterval(() => { for (const c of actions.keys()) refresh(c, deck); }, POLL_MS);
