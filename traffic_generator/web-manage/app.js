'use strict';
// KETI TSN Console — one UI over the flood generator (this Pi's pktgen API) and
// the Kontron D10 switches (WebStaX JSON-RPC, proxied by the backend).
//   switch calls -> /api/d10/rpc?host=<sw>   flood calls -> /api/start etc.

const $ = (id) => document.getElementById(id);
function toast(msg, kind = '') {
  const t = document.createElement('div');
  t.className = 'toast ' + kind; t.textContent = msg;
  $('toastTray').appendChild(t); setTimeout(() => t.remove(), 3500);
}

// ── switch JSON-RPC ─────────────────────────────────────────────────────────
let RPCID = 1, HOST = null, PORTS = [];
async function rpc(method, params = []) {
  const r = await fetch('/api/d10/rpc?host=' + encodeURIComponent(HOST || ''), {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: RPCID++, method, params }),
  });
  const j = await r.json();
  if (j.error) throw new Error(j.error.message + (j.error.data ? ' — ' + JSON.stringify(j.error.data) : ''));
  return j.result;
}

// ── tabs ────────────────────────────────────────────────────────────────────
document.querySelectorAll('.tab').forEach((b) => b.addEventListener('click', () => {
  document.querySelectorAll('.tab').forEach((x) => x.classList.remove('active'));
  document.querySelectorAll('.view').forEach((x) => x.classList.remove('active'));
  b.classList.add('active'); $(b.dataset.view).classList.add('active');
}));

// ── switches + health ───────────────────────────────────────────────────────
async function initSwitches() {
  const { switches, default: def } = await (await fetch('/api/d10/switches')).json();
  HOST = def || switches[0];
  const sel = $('switchSel');
  sel.innerHTML = switches.map((s, i) => `<option value="${s}">SW${i + 1} · ${s}</option>`).join('');
  sel.value = HOST;
  sel.addEventListener('change', async () => { HOST = sel.value; try { await loadPorts(); fillFrerPorts(); } catch {} });
}
async function health() {
  try {
    const h = await (await fetch('/api/d10/health')).json();
    const st = (h.switches || {})[HOST];
    const pill = $('d10Link');
    pill.textContent = st === 'up' ? 'online' : (st || 'offline');
    pill.className = 'pill ' + (st === 'up' ? 'up' : 'down');
    const sel = $('switchSel');
    [...sel.options].forEach((o) => {
      const s = (h.switches || {})[o.value];
      o.textContent = o.textContent.replace(/ [●○]$/, '') + (s === 'up' ? ' ●' : ' ○');
    });
  } catch { $('d10Link').textContent = 'offline'; $('d10Link').className = 'pill down'; }
}

// ── ports ───────────────────────────────────────────────────────────────────
function prettySpeed(s) {
  if (!s || s === 'undefined') return '';
  return String(s).replace(/^speed/, '').replace('2500M', '2.5G').replace('1000M', '1G');
}
async function loadPorts() {
  const res = await rpc('port.status.get', []);          // [{key,val}]
  PORTS = res.map((e) => e.key);
  const grid = $('portGrid'); if (grid) { grid.innerHTML = '';
    res.forEach((e) => {
      const up = e.val && (e.val.Link === true || e.val.Link === 'up');
      const d = document.createElement('div');
      d.className = 'port ' + (up ? 'up' : 'down');
      d.innerHTML = `<div class="pno">${e.key}</div><div class="plink">${up ? (prettySpeed(e.val.Speed) || 'up') : 'down'}</div><div class="prole"></div>`;
      grid.appendChild(d);
    });
  }
  ['cbsPort', 'tasPort', 'qosPort', 'demoPort', 'strmIngress'].forEach((id) => {
    const sel = $(id); if (!sel) return; const cur = sel.value;
    sel.innerHTML = PORTS.map((p) => `<option>${p}</option>`).join('');
    if (cur && PORTS.includes(cur)) sel.value = cur;
  });
}

// ── Traffic: flood generator (this Pi's pktgen API) ─────────────────────────
async function genInit() {
  try {
    const sys = await (await fetch('/api/system')).json();
    $('genPreset').innerHTML = Object.entries(sys.presets || {})
      .map(([k, v]) => `<option value="${k}">${v.label || k}</option>`).join('');
    if ([...$('genPreset').options].some((o) => o.value === 'line_rate_1500')) $('genPreset').value = 'line_rate_1500';
  } catch {}
}
async function genStart() {
  try {
    const key = $('genPreset').value;
    await fetch('/api/preset/' + encodeURIComponent(key), { method: 'POST' });
    await fetch('/api/start', { method: 'POST' });
    toast('flood ON · ' + key, 'ok');
  } catch (e) { toast('start: ' + e.message, 'err'); }
}
async function genStop() {
  try { await fetch('/api/stop', { method: 'POST' }); toast('flood OFF', ''); } catch (e) { toast(e.message, 'err'); }
}
const genHist = [];
async function genPoll() {
  try {
    const s = await (await fetch('/api/status')).json();
    const last = s.last || {}, mbps = Math.round(last.mbps || 0), kpps = Math.round((last.pps || 0) / 1000);
    $('genMbps').textContent = mbps; $('genKpps').textContent = kpps;
    $('genSent').textContent = (last.sent_packets || 0).toLocaleString();
    $('genState').textContent = s.running ? 'RUNNING' : 'idle';
    $('genState').className = 'pill ' + (s.running ? 'up' : '');
    genHist.push(mbps); if (genHist.length > 120) genHist.shift();
    drawSpark('genChart', genHist, 1000);
  } catch {}
}
function drawSpark(id, data, max) {
  const c = $(id); if (!c) return; const ctx = c.getContext('2d');
  const w = c.width = c.clientWidth, h = c.height;
  ctx.clearRect(0, 0, w, h);
  ctx.strokeStyle = getComputedStyle(document.body).getPropertyValue('--accent') || '#7C7CFF';
  ctx.lineWidth = 2; ctx.beginPath();
  data.forEach((v, i) => { const x = (i / Math.max(data.length - 1, 1)) * w, y = h - (Math.min(v, max) / max) * (h - 4) - 2; i ? ctx.lineTo(x, y) : ctx.moveTo(x, y); });
  ctx.stroke();
}

// ── Video receiver (Pi2 state, best-effort) ─────────────────────────────────
async function vidPoll() {
  try {
    const d = await (await fetch('/api/video/state')).json();
    $('vidRx').textContent = (d.kbps ? (d.kbps / 1000).toFixed(1) : '—');
    $('vidLink').textContent = d.link_rx_mbps != null ? Math.round(d.link_rx_mbps) : '—';
    $('vidUp').textContent = (d.receiving || d.recv) ? 'yes' : 'no';
  } catch {}
}

// ── Demo: CBS protect on the video egress port ──────────────────────────────
function fillDemoQueues() { $('demoQueue').innerHTML = Array.from({ length: 8 }, (_, q) => `<option value="${q}">Q${q}</option>`).join(''); $('demoQueue').value = 6; }
async function demoProtect() {
  const port = $('demoPort').value, q = +$('demoQueue').value, mbps = +$('demoCir').value || 250;
  try {
    await rpc('qos.config.interface.queueShaper.set', [port, q, { Enable: true, Credit: true, Cir: mbps * 1000, RateType: 'line', Excess: false }]);
    $('demoStatus').textContent = `PROTECTED · CBS reserves ${mbps} Mbps for ${port} Q${q}`;
    $('demoStatus').className = 'demo-status protected';
    $('demoHint').textContent = `queueShaper.set(${port}, ${q}, {Enable, Credit, Cir:${mbps * 1000}})`;
    toast('CBS protect on', 'ok');
  } catch (e) { toast(e.message, 'err'); }
}
async function demoOff() {
  const port = $('demoPort').value, q = +$('demoQueue').value;
  try { await rpc('qos.config.interface.queueShaper.set', [port, q, { Enable: false, Credit: false, Cir: 500, RateType: 'line', Excess: false }]); $('demoStatus').textContent = '— CBS off —'; $('demoStatus').className = 'demo-status degraded'; toast('CBS off', ''); } catch (e) { toast(e.message, 'err'); }
}

// ── CBS tab ─────────────────────────────────────────────────────────────────
async function cbsLoad() {
  const port = $('cbsPort').value; if (!port) return; const body = $('cbsRows'); body.innerHTML = '';
  for (let q = 0; q < 8; q++) {
    let s = {}; try { s = await rpc('qos.config.interface.queueShaper.get', [port, q]); } catch {}
    const tr = document.createElement('tr');
    tr.innerHTML = `<td class="mono">Q${q}</td><td><input type="checkbox" ${s.Enable ? 'checked' : ''} data-f="Enable"></td><td><input type="checkbox" ${s.Credit ? 'checked' : ''} data-f="Credit"></td><td><input type="number" value="${s.Cir ?? 0}" style="width:90px" data-f="Cir"></td><td><select data-f="RateType"><option ${s.RateType === 'line' ? 'selected' : ''}>line</option><option ${s.RateType === 'data' ? 'selected' : ''}>data</option></select></td><td><input type="checkbox" ${s.Excess ? 'checked' : ''} data-f="Excess"></td><td><button class="small">Set</button></td>`;
    tr.querySelector('button').addEventListener('click', async () => {
      const g = (f) => tr.querySelector(`[data-f="${f}"]`);
      try { await rpc('qos.config.interface.queueShaper.set', [port, q, { Enable: g('Enable').checked, Credit: g('Credit').checked, Cir: +g('Cir').value || 0, RateType: g('RateType').value, Excess: g('Excess').checked }]); toast(`CBS ${port} Q${q}`, 'ok'); } catch (e) { toast(e.message, 'err'); }
    });
    body.appendChild(tr);
  }
}

// ── TAS tab ─────────────────────────────────────────────────────────────────
async function tasLoad() {
  const port = $('tasPort').value; if (!port) return;
  try { const p = await rpc('tsn.config.interface.tas.params.get', [port]); $('tasEnable').value = String(!!p.GateEnabled); $('tasCycle').value = Math.round(1e6 * (p.AdminCycleTimeNumerator / p.AdminCycleTimeDenominator)); $('tasLen').value = p.AdminControlListLength ?? 0; } catch (e) { toast(e.message, 'err'); }
  const body = $('tasRows'); body.innerHTML = '';
  for (let i = 0; i < Math.max(+$('tasLen').value || 0, 2); i++) {
    let g = {}; try { g = await rpc('tsn.config.interface.tas.gclEntry.get', [port, i]); } catch {}
    const tr = document.createElement('tr'); tr.dataset.idx = i;
    tr.innerHTML = `<td class="mono">${i}</td><td><input value="${g.GateState ?? 'ff'}" style="width:80px" data-f="GateState"></td><td><input type="number" value="${g.TimeInterval ?? 0}" style="width:130px" data-f="TimeInterval"></td>`;
    body.appendChild(tr);
  }
}
async function tasApply() {
  const port = $('tasPort').value; if (!port) return; const cyc = +$('tasCycle').value || 1000;
  try {
    await rpc('tsn.config.interface.tas.params.set', [port, { GateEnabled: $('tasEnable').value === 'true', AdminControlListLength: +$('tasLen').value || 0, AdminCycleTimeNumerator: cyc, AdminCycleTimeDenominator: 1000000, AdminGateStates: 'ff', AdminCycleTimeExtension: 256 }]);
    for (const tr of $('tasRows').querySelectorAll('tr')) { const i = +tr.dataset.idx; if (i >= (+$('tasLen').value || 0)) continue; await rpc('tsn.config.interface.tas.gclEntry.set', [port, i, { GateState: tr.querySelector('[data-f="GateState"]').value, TimeInterval: +tr.querySelector('[data-f="TimeInterval"]').value || 0 }]); }
    toast('TAS applied', 'ok');
  } catch (e) { toast(e.message, 'err'); }
}

// ── FRER tab ────────────────────────────────────────────────────────────────
function fillFrerPorts() { const box = $('frerPorts'); if (box) box.innerHTML = PORTS.map((p) => `<label class="port" style="cursor:pointer"><input type="checkbox" value="${p}"> ${p}</label>`).join(''); }
function frerConf() {
  const egress = [...$('frerPorts').querySelectorAll('input:checked')].map((c) => c.value);
  const ids = ($('frerStreams').value || '').split(',').map((s) => parseInt(s.trim(), 10)).filter((n) => !isNaN(n));
  const c = { Mode: $('frerMode').value, FrerVlan: +$('frerVlan').value || 0, EgressPorts: egress, Algorithm: $('frerAlg').value, HistoryLen: +$('frerHist').value || 8, ResetTimeoutMsec: +$('frerReset').value || 100, TakeNoSequence: false, IndividualRecovery: false, Terminate: $('frerMode').value === 'recovery', LaErrDetection: false, LaErrDifference: 100, LaErrPeriodMsec: 2000, LaErrPaths: 2, LaErrResetPeriodMsec: 30000, AdminActive: $('frerActive').value === 'true' };
  for (let i = 0; i < 8; i++) c['StreamId' + i] = ids[i] != null ? ids[i] : 0;   // unused = 0, NOT -1
  return c;
}
async function frerApply() {
  const id = +$('frerId').value || 1;
  try { try { await rpc('frer.config.add', [id, frerConf()]); } catch {} await rpc('frer.config.set', [id, frerConf()]); toast(`FRER ${id} on ${HOST}`, 'ok'); frerReload(); } catch (e) { toast(e.message, 'err'); }
}
async function frerDelete() { const id = +$('frerId').value || 1; try { await rpc('frer.config.del', [id]); toast(`FRER ${id} deleted`, ''); frerReload(); } catch (e) { toast(e.message, 'err'); } }
async function strmCreate() {
  const id = +$('strmId').value || 1, vlan = +$('strmVlan').value || 0, dmac = ($('strmDmac').value || '').trim();
  const hasMac = /^[0-9a-fA-F:.-]{11,}$/.test(dmac) && dmac.toLowerCase() !== 'any';
  const conf = { MulticastDMac: 'any', BroadcastDMac: 'any', destinationMacAddress: hasMac ? dmac.replace(/-/g, ':') : '00:00:00:00:00:00', destinationMacMask: hasMac ? 'ff:ff:ff:ff:ff:ff' : '00:00:00:00:00:00', sourceMacAddress: '00:00:00:00:00:00', sourceMacMask: '00:00:00:00:00:00', outerTag: vlan ? 'one' : 'any', outerTagIsSTag: 'any', outerTagVidValue: vlan, outerTagVidMask: vlan ? 4095 : 0, outerTagPcpValue: 0, outerTagPcpMask: 0, outerTagDei: 'any', innerTag: 'any', innerTagIsSTag: 'any', innerTagVidValue: 0, innerTagVidMask: 0, innerTagPcpValue: 0, innerTagPcpMask: 0, innerTagDei: 'any', protocol: 'ANY' };
  try { try { await rpc('vcl.config.stream.add', [id, conf]); } catch {} await rpc('vcl.config.stream.set', [id, conf]); if ($('strmIngress').value) await rpc('vcl.config.interface.stream.add', [$('strmIngress').value, id]); toast(`stream ${id} created`, 'ok'); } catch (e) { toast(e.message, 'err'); }
}
async function frerReload() {
  const body = $('frerRows'); body.innerHTML = ''; let n = 0;
  for (let id = 1; id <= 20; id++) {
    let c; try { c = await rpc('frer.config.get', [id]); } catch { continue; } if (!c) continue; n++;
    const eg = Array.isArray(c.EgressPorts) ? c.EgressPorts.join(', ') : (c.EgressPorts || '');
    const tr = document.createElement('tr');
    tr.innerHTML = `<td class="mono">${id}</td><td>${c.Mode}</td><td>${c.FrerVlan}</td><td class="mono">${eg}</td><td>${c.Algorithm}</td><td><span class="dot ${c.AdminActive ? 'g' : 'r'}"></span>${c.AdminActive ? 'on' : 'off'}</td><td><button class="small">Edit</button></td>`;
    tr.querySelector('button').addEventListener('click', () => {
      $('frerId').value = id; $('frerMode').value = c.Mode; $('frerVlan').value = c.FrerVlan; $('frerAlg').value = c.Algorithm; $('frerHist').value = c.HistoryLen; $('frerReset').value = c.ResetTimeoutMsec; $('frerActive').value = String(!!c.AdminActive);
      const s = []; for (let i = 0; i < 8; i++) if (c['StreamId' + i] > 0) s.push(c['StreamId' + i]); $('frerStreams').value = s.join(',');
      const eg2 = Array.isArray(c.EgressPorts) ? c.EgressPorts : []; $('frerPorts').querySelectorAll('input').forEach((cb) => { cb.checked = eg2.includes(cb.value); });
    });
    body.appendChild(tr);
  }
  if (!n) body.innerHTML = '<tr><td colspan="7" class="hint">no instances on this switch</td></tr>';
}

// ── QoS / PCP tab ───────────────────────────────────────────────────────────
async function qosLoad() {
  const port = $('qosPort').value; if (!port) return; const body = $('qosRows'); body.innerHTML = '';
  for (let pcp = 0; pcp < 8; pcp++) {
    let m = {}; try { m = await rpc('qos.config.interface.tagToCos.get', [port, pcp, 0]); } catch { try { m = await rpc('qos.config.interface.tagToCos.get', [port, pcp]); } catch {} }
    const cos = m.Cos ?? pcp, dpl = m.Dpl ?? 0;
    const tr = document.createElement('tr'); tr.dataset.pcp = pcp;
    tr.innerHTML = `<td class="mono">${pcp}</td><td><input type="number" min="0" max="7" value="${cos}" style="width:60px" data-f="Cos"></td><td><input type="number" min="0" max="3" value="${dpl}" style="width:60px" data-f="Dpl"></td>`;
    tr.querySelectorAll('input').forEach((inp) => inp.addEventListener('change', async () => {
      const cfg = { Cos: +tr.querySelector('[data-f="Cos"]').value || 0, Dpl: +tr.querySelector('[data-f="Dpl"]').value || 0 };
      try { await rpc('qos.config.interface.tagToCos.set', [port, pcp, 0, cfg]); toast(`PCP${pcp}→CoS${cfg.Cos}`, 'ok'); } catch { try { await rpc('qos.config.interface.tagToCos.set', [port, pcp, cfg]); toast(`PCP${pcp}→CoS${cfg.Cos}`, 'ok'); } catch (e) { toast(e.message, 'err'); } }
    }));
    body.appendChild(tr);
  }
}

// ── Console ─────────────────────────────────────────────────────────────────
async function rpcSend() {
  const method = $('rpcMethod').value.trim(); let params;
  try { params = JSON.parse($('rpcParams').value || '[]'); } catch { return toast('params must be JSON array', 'err'); }
  try { $('rpcOut').textContent = JSON.stringify(await rpc(method, params), null, 2); } catch (e) { $('rpcOut').textContent = 'ERROR: ' + e.message; }
}
const COMMON = ['port.status.get', 'qos.config.interface.queueShaper.get', 'tsn.config.interface.tas.params.get', 'qos.config.interface.tagToCos.get', 'frer.config.get', 'frer.status.get'];

// ── wire + boot ─────────────────────────────────────────────────────────────
$('genStart').addEventListener('click', genStart);
$('genStop').addEventListener('click', genStop);
$('demoProtect').addEventListener('click', demoProtect);
$('demoOff').addEventListener('click', demoOff);
$('vidRefresh').addEventListener('click', vidPoll);
$('refreshPorts').addEventListener('click', loadPorts);
$('cbsLoad').addEventListener('click', cbsLoad);
$('tasLoad').addEventListener('click', tasLoad);
$('tasApply').addEventListener('click', tasApply);
$('qosLoad').addEventListener('click', qosLoad);
$('frerReload').addEventListener('click', frerReload);
$('frerApply').addEventListener('click', frerApply);
$('frerDelete').addEventListener('click', frerDelete);
$('strmCreate').addEventListener('click', strmCreate);
$('rpcSend').addEventListener('click', rpcSend);

async function boot() {
  $('methodList').innerHTML = COMMON.map((m) => `<option value="${m}">`).join('');
  fillDemoQueues();
  await genInit();
  await initSwitches();
  await health();
  try { await loadPorts(); fillFrerPorts(); } catch (e) { toast('ports: ' + e.message, 'err'); }
  setInterval(health, 5000);
  setInterval(genPoll, 1000);
  setInterval(vidPoll, 2000);
  genPoll(); vidPoll();
}
boot();
