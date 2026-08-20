"use strict";
/* pi-trafgen kiosk front-end. No build step, no external libs - it runs off the
   Pi's loopback and must work with the network cable pulled. */

const $ = (id) => document.getElementById(id);

// Chart colours follow the theme - read the live CSS custom properties so the
// canvas matches whichever theme (light/dark) is active.
function themeColors() {
  const cs = getComputedStyle(document.documentElement);
  const v = (n, fb) => (cs.getPropertyValue(n).trim() || fb);
  return {
    blue: v("--accent", "#1668b3"),
    orange: v("--accent-2", "#ff6b1f"),
    grid: v("--grid-line", "#ececf1"),
  };
}
let C = themeColors();

function applyTheme(theme) {
  document.documentElement.setAttribute("data-theme", theme);
  try { localStorage.setItem("tg-theme", theme); } catch (e) {}
  C = themeColors();
}
const api = (path, opts) => fetch(path, opts).then((r) => r.json().then((j) => {
  if (!r.ok) throw new Error(j.detail || r.statusText);
  return j;
}));

const state = {
  system: null,
  config: { iface: "eth0", streams: [] },
  history: [],
  running: false,
  lineRatePps: 1488095, // updated from /api/plan
};

// ---------------------------------------------------------------- formatting
const fmt = (n, d = 0) => Number(n).toLocaleString("en-US", { minimumFractionDigits: d, maximumFractionDigits: d });
const compact = (n) => n >= 1e6 ? (n / 1e6).toFixed(2) + "M" : n >= 1e3 ? (n / 1e3).toFixed(1) + "k" : fmt(n);

// ---------------------------------------------------------------- live chart
const chart = (() => {
  const cv = $("chart");
  const ctx = cv.getContext("2d");
  let W = 0, H = 0, dpr = 1;

  function resize() {
    dpr = window.devicePixelRatio || 1;
    W = cv.clientWidth; H = cv.clientHeight;
    cv.width = W * dpr; cv.height = H * dpr;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  }
  new ResizeObserver(resize).observe(cv);

  function draw() {
    if (!W) resize();
    ctx.clearRect(0, 0, W, H);
    const pad = { l: 46, r: 46, t: 14, b: 18 };
    const pw = W - pad.l - pad.r, ph = H - pad.t - pad.b;

    const hist = state.history.slice(-120);
    const mbps = hist.map((h) => h.mbps || 0);
    const pps = hist.map((h) => h.pps || 0);
    const maxMbps = Math.max(10, ...mbps) * 1.15;
    const maxPps = Math.max(1000, ...pps) * 1.15;

    // grid + axis ticks
    ctx.font = "600 10px -apple-system, sans-serif";
    ctx.textBaseline = "middle";
    for (let i = 0; i <= 4; i++) {
      const y = pad.t + (ph * i) / 4;
      ctx.strokeStyle = C.grid; ctx.lineWidth = 1;
      ctx.beginPath(); ctx.moveTo(pad.l, y); ctx.lineTo(pad.l + pw, y); ctx.stroke();
      ctx.textAlign = "right";
      ctx.fillStyle = C.blue;
      ctx.fillText(fmt(maxMbps * (1 - i / 4)), pad.l - 6, y);
      ctx.textAlign = "left";
      ctx.fillStyle = C.orange;
      ctx.fillText(compact(maxPps * (1 - i / 4)), pad.l + pw + 6, y);
    }

    const plot = (data, max, color, fill) => {
      if (data.length < 2) return;
      ctx.strokeStyle = color; ctx.lineWidth = 2.5;
      ctx.lineJoin = "round"; ctx.lineCap = "round";
      ctx.beginPath();
      data.forEach((v, i) => {
        const x = pad.l + (pw * i) / (data.length - 1);
        const y = pad.t + ph * (1 - Math.min(v / max, 1));
        i ? ctx.lineTo(x, y) : ctx.moveTo(x, y);
      });
      ctx.stroke();
      ctx.lineTo(pad.l + pw, pad.t + ph); ctx.lineTo(pad.l, pad.t + ph); ctx.closePath();
      ctx.fillStyle = fill; ctx.fill();
    };
    plot(mbps, maxMbps, C.blue, "rgba(22,104,179,0.10)");
    plot(pps, maxPps, C.orange, "rgba(255,107,31,0.09)");
  }

  return { draw, resize };
})();

// ---------------------------------------------------------------- gauges
function paintGauges(s) {
  const mbps = s.mbps || 0, pps = s.pps || 0;
  const lineMbps = (state.lineRatePps * 0) || 1000; // display % against 1G
  $("mbps").textContent = fmt(mbps, 1);
  $("pps").textContent = fmt(pps);
  $("kpps").textContent = fmt(pps / 1000, 1);
  const pct = Math.min(100, (mbps / 1000) * 100);
  $("mbps-bar").style.width = pct + "%";
  $("mbps-pct").textContent = fmt(pct, 0) + "%";
  $("pps-bar").style.width = Math.min(100, (pps / state.lineRatePps) * 100) + "%";
  $("sent").textContent = compact(s.sent_packets || 0);
  const err = s.tx_errors || 0, drop = s.tx_dropped || 0;
  const ed = $("errdrop");
  ed.textContent = `${fmt(err)} err / ${fmt(drop)} drop`;
  ed.style.color = (err || drop) ? "var(--bad)" : "var(--ink-2)";
}

// ---------------------------------------------------------------- status bar
function paintStatus(st) {
  state.running = st.running;
  $("iface-pill").textContent = st.iface;
  $("link-pill").textContent = st.link_mbps ? `${st.link_mbps} Mbps` : "no link";
  $("link-pill").className = "pill " + (st.operstate === "up" ? "good" : "bad");
  const pk = $("pktgen-pill");
  if (state.system && !state.system.pktgen) { pk.textContent = "pktgen MISSING"; pk.className = "pill bad"; }
  else if (state.system && !state.system.root) { pk.textContent = "not root"; pk.className = "pill bad"; }
  else { pk.textContent = "pktgen ok"; pk.className = "pill good"; }

  const el = Math.floor(st.elapsed || 0);
  $("elapsed").textContent = `${String(Math.floor(el / 60)).padStart(2, "0")}:${String(el % 60).padStart(2, "0")}`;

  $("btn-start").disabled = st.running;
  $("btn-stop").disabled = !st.running;
  document.querySelector(".app").classList.toggle("locked", st.running);
  document.querySelector(".streams").classList.toggle("locked", st.running);

  if (st.error) showMsg(st.error, true);
}

let msgTimer;
function showMsg(text, err = false) {
  const m = $("msg"); m.textContent = text; m.className = "msg" + (err ? " err" : "");
  clearTimeout(msgTimer);
  if (!err) msgTimer = setTimeout(() => { m.textContent = ""; }, 4000);
}

// ---------------------------------------------------------------- stream editor
const FIELDS = [
  ["frame_size", "frame B", "number"],
  ["rate_value", "rate", "number"],
  ["vlan_id", "VLAN", "number"],
  ["pcp", "PCP", "number"],
  ["dst_mac", "dst MAC", "text"],
  ["dst_ip", "dst IP", "text"],
  ["cpu", "CPU", "number"],
  ["queue", "queue", "number"],
];

function renderStreams() {
  const list = $("stream-list");
  list.innerHTML = "";
  state.config.streams.forEach((s, i) => {
    const el = document.createElement("div");
    el.className = "stream" + (s.enabled ? "" : " off");

    const top = document.createElement("div");
    top.className = "stream-top";
    const tog = document.createElement("div");
    tog.className = "tog" + (s.enabled ? " on" : "");
    tog.onclick = () => { s.enabled = !s.enabled; pushConfig(); };
    const name = document.createElement("input");
    name.className = "name"; name.value = s.name;
    name.onchange = () => { s.name = name.value; pushConfig(); };
    const rateSel = document.createElement("select");
    rateSel.className = "mini";
    [["max", "max"], ["mbps", "Mbps"], ["pps", "pps"]].forEach(([v, t]) => {
      const o = document.createElement("option"); o.value = v; o.textContent = t;
      if (s.rate_mode === v) o.selected = true; rateSel.appendChild(o);
    });
    rateSel.onchange = () => { s.rate_mode = rateSel.value; pushConfig(); };
    const del = document.createElement("button");
    del.className = "del"; del.textContent = "✕";
    del.onclick = () => { state.config.streams.splice(i, 1); pushConfig(); };
    top.append(tog, name, rateSel, del);

    const grid = document.createElement("div");
    grid.className = "stream-grid";
    FIELDS.forEach(([key, lbl, type]) => {
      const f = document.createElement("div"); f.className = "fld" + (key === "pcp" ? " pcp" : "");
      const l = document.createElement("label"); l.textContent = lbl;
      const inp = document.createElement("input");
      inp.type = type;
      inp.value = s[key] === null || s[key] === undefined ? "" : s[key];
      if (key === "rate_value" && s.rate_mode === "max") inp.disabled = true;
      inp.onchange = () => {
        let v = inp.value;
        if (type === "number") v = v === "" ? (key === "vlan_id" ? null : 0) : Number(v);
        s[key] = v; pushConfig();
      };
      f.append(l, inp); grid.appendChild(f);
    });

    el.append(top, grid);
    list.appendChild(el);
  });
}

function newStream() {
  const cpus = state.system ? state.system.cpus : 4;
  const n = state.config.streams.length;
  return {
    name: `stream ${n + 1}`, enabled: true, queue: n % 4, cpu: n % cpus,
    frame_size: 512, count: 0, dst_mac: "ff:ff:ff:ff:ff:ff", src_mac: "",
    dst_ip: "10.0.100.2", src_ip: "", udp_src: 9, udp_dst: 9,
    vlan_id: null, pcp: 0, rate_mode: "max", rate_value: 0, clone_skb: 100000, burst: 8,
  };
}

// ---------------------------------------------------------------- plan preview
async function refreshPlan() {
  try {
    const p = await api("/api/plan");
    if (p.line_rate_pps) state.lineRatePps = p.line_rate_pps;
    const over = p.total_mbps > 1000;
    $("plan").innerHTML =
      `planned: <b>${fmt(p.total_mbps, 1)}</b> Mbps · <b>${compact(p.total_pps)}</b> pps` +
      (over ? ` <span class="over">&gt; 1G line rate</span>` : "") +
      ` · line rate @${p.streams[0] ? p.streams[0].frame_size : 512}B = ${compact(state.lineRatePps)} pps`;
  } catch (e) { $("plan").textContent = ""; }
}

let pushTimer;
function pushConfig() {
  renderStreams();
  clearTimeout(pushTimer);
  pushTimer = setTimeout(async () => {
    try {
      await api("/api/config", {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify(state.config),
      });
      refreshPlan();
    } catch (e) { showMsg(e.message, true); }
  }, 250);
}

// ---------------------------------------------------------------- presets
function chip(title, sub, { custom = false, onTap, onDelete } = {}) {
  const b = document.createElement("button");
  b.className = "chip" + (custom ? " custom" : "");
  const t = document.createElement("span"); t.className = "chip-title"; t.textContent = title;
  b.appendChild(t);
  if (sub) { const s = document.createElement("span"); s.className = "chip-sub"; s.textContent = sub; b.appendChild(s); }
  b.onclick = onTap;
  if (onDelete) {
    const d = document.createElement("button");
    d.className = "chip-del"; d.textContent = "✕";
    d.onclick = (ev) => { ev.stopPropagation(); onDelete(); };
    b.appendChild(d);
  }
  return b;
}

function renderPresets() {
  const box = $("presets"); box.innerHTML = "";
  const p = state.system.presets || {};
  Object.entries(p).forEach(([key, meta]) => {
    box.appendChild(chip(meta.label, null, {
      onTap: async () => {
        try {
          state.config = await api(`/api/preset/${key}`, { method: "POST" });
          renderStreams(); refreshPlan(); showMsg(meta.note);
        } catch (e) { showMsg(e.message, true); }
      },
    })).title = meta.note;
  });
}

function summary(s) {
  const rate = s.unthrottled ? "max" : `${fmt(s.mbps, 1)} Mbps`;
  return `${s.streams} stream${s.streams === 1 ? "" : "s"} · ${rate}`;
}

async function renderUserPresets() {
  const box = $("user-presets"); box.innerHTML = "";
  let data;
  try { data = (await api("/api/userpresets")).presets || {}; }
  catch { return; }
  Object.entries(data).forEach(([name, s]) => {
    box.appendChild(chip(name, summary(s), {
      custom: true,
      onTap: async () => {
        try {
          state.config = await api(`/api/userpresets/${encodeURIComponent(name)}/load`, { method: "POST" });
          renderStreams(); refreshPlan(); showMsg(`loaded "${name}"`);
        } catch (e) { showMsg(e.message, true); }
      },
      onDelete: async () => {
        try {
          await api(`/api/userpresets/${encodeURIComponent(name)}`, { method: "DELETE" });
          renderUserPresets(); showMsg(`deleted "${name}"`);
        } catch (e) { showMsg(e.message, true); }
      },
    }));
  });
}

async function saveCurrentPreset() {
  if (state.running) { showMsg("stop before saving", true); return; }
  const name = (window.prompt("Save current setup as:", "") || "").trim();
  if (!name) return;
  try {
    await api(`/api/userpresets/${encodeURIComponent(name)}`, { method: "POST" });
    renderUserPresets(); showMsg(`saved "${name}"`);
  } catch (e) { showMsg(e.message, true); }
}

// ---------------------------------------------------------------- iface select
function renderIfaces() {
  const sel = $("iface-select"); sel.innerHTML = "";
  (state.system.interfaces || []).forEach((i) => {
    const o = document.createElement("option");
    o.value = i.name;
    o.textContent = `${i.name} (${i.speed_mbps || "?"}M ${i.operstate})`;
    if (i.name === state.config.iface) o.selected = true;
    sel.appendChild(o);
  });
  sel.onchange = () => { state.config.iface = sel.value; pushConfig(); };
}

// ---------------------------------------------------------------- ws
function connectWs() {
  const proto = location.protocol === "https:" ? "wss" : "ws";
  const ws = new WebSocket(`${proto}://${location.host}/ws`);
  ws.onmessage = (ev) => {
    const msg = JSON.parse(ev.data);
    if (msg.type === "history") { state.history = msg.history || []; }
    else if (msg.type === "tick") { state.history.push({ ...msg.sample }); state.history = state.history.slice(-240); }
    if (msg.status) paintStatus(msg.status);
    if (msg.sample) paintGauges(msg.sample);
    else if (state.history.length) paintGauges(state.history[state.history.length - 1]);
  };
  ws.onclose = () => setTimeout(connectWs, 1500);
}

// ---------------------------------------------------------------- render loop
function loop() { chart.draw(); requestAnimationFrame(loop); }

// ---------------------------------------------------------------- boot
async function boot() {
  $("btn-start").onclick = async () => {
    try { await api("/api/start", { method: "POST" }); showMsg("started"); }
    catch (e) { showMsg(e.message, true); }
  };
  $("btn-stop").onclick = async () => {
    try { await api("/api/stop", { method: "POST" }); showMsg("stopped"); }
    catch (e) { showMsg(e.message, true); }
  };
  $("btn-add").onclick = () => { state.config.streams.push(newStream()); pushConfig(); };
  $("btn-save").onclick = saveCurrentPreset;

  // theme: default dark (best legibility on the panel), remembered per device
  let theme = "dark";
  try { theme = localStorage.getItem("tg-theme") || "dark"; } catch (e) {}
  applyTheme(theme);
  $("btn-theme").onclick = () =>
    applyTheme(document.documentElement.getAttribute("data-theme") === "dark" ? "light" : "dark");

  try {
    state.system = await api("/api/system");
    state.config = await api("/api/config");
  } catch (e) { showMsg("server unreachable: " + e.message, true); return; }

  renderIfaces();
  renderPresets();
  renderUserPresets();
  renderStreams();
  refreshPlan();
  connectWs();
  requestAnimationFrame(loop);
}

boot();
