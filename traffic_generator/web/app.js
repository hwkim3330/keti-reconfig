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
  // pktgen problems are surfaced in the message line (the header pill was dropped
  // to keep the bar on one row).
  if (state.system && !state.system.pktgen) showMsg("pktgen module not loaded on the Pi", true);
  else if (state.system && !state.system.root) showMsg("server is not running as root", true);

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
  $("btn-tsn").onclick = async () => {
    // one-tap TSN test: load the CBS profile (9662 PCP->TC mapping) and start
    try {
      state.config = await api("/api/preset/cbs_tc2_tc6", { method: "POST" });
      renderStreams(); refreshPlan();
      await api("/api/start", { method: "POST" });
      showMsg("TSN ON - CBS TC2 (1.5M) + TC6 (3.5M)");
    } catch (e) { showMsg(e.message, true); }
  };
  $("btn-add").onclick = () => { state.config.streams.push(newStream()); pushConfig(); };
  $("btn-save").onclick = saveCurrentPreset;

  // tabs: Monitor / Video / Config
  document.querySelectorAll(".tabbtn").forEach((b) => {
    b.onclick = () => {
      document.querySelectorAll(".tabbtn").forEach((x) => x.classList.toggle("active", x === b));
      const tab = b.dataset.tab;
      document.querySelectorAll(".tab").forEach((t) => { t.hidden = (t.id !== "tab-" + tab); });
      if (tab === "monitor") { chart.resize(); chart.draw(); }
      const v = $("video");
      if (tab === "video") v.play().catch(() => {}); // resume when shown
    };
  });

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
  loadVideo();
  connectWs();
  requestAnimationFrame(loop);

  // Role view: one identical UI, kiosks differ only by ?view=.
  //   ?view=tx    -> sender panel: the transmit graph (Monitor), tab bar hidden
  //   ?view=video -> receiver panel: the video + receive graph, tab bar hidden
  const view = new URLSearchParams(location.search).get("view");
  if (view === "tx" || view === "video") {
    const tab = view === "tx" ? "monitor" : "video";
    const btn = document.querySelector(`.tabbtn[data-tab="${tab}"]`);
    if (btn) btn.onclick();               // select and lay out that tab
    document.querySelector(".tabbar").hidden = true;
    document.documentElement.classList.add("kiosk-locked");
    $("title").textContent = view === "tx" ? "Transmit" : "Receive";
  }
}

// The "protected video flow". Two sources:
//  - Live: the MPEG-TS stream the *sender* Pi pushes over the network (through the
//    9662). The server relays it on /ws/video and mpegts.js feeds it into <video>.
//    This is the real transmission demo - with TSN off the picture stutters.
//  - Local: the sample clip served from this Pi (fallback / when no sender yet).
let mpegtsPlayer = null;
let videoSrcMode = "live";
let videoMonitorStarted = false;
let localVideos = [];

const wsVideoURL = () =>
  (location.protocol === "https:" ? "wss" : "ws") + "://" + location.host + "/ws/video";

function destroyLive() {
  if (mpegtsPlayer) {
    try { mpegtsPlayer.destroy(); } catch (e) {}
    mpegtsPlayer = null;
  }
}

async function setVideoSource(mode) {
  const v = $("video");
  $("video-card").hidden = false;
  document.querySelectorAll("#video-src .seg-btn").forEach((b) =>
    b.classList.toggle("active", b.dataset.src === mode));
  if (!videoMonitorStarted) { startVideoMonitor(v); videoMonitorStarted = true; }
  vhist.length = 0;

  if (mode === "live") {
    videoSrcMode = "live";
    destroyLive();
    v.removeAttribute("src"); v.load();
    if (!(window.mpegts && mpegts.isSupported())) {
      $("video-note").textContent = "live playback unsupported here - use Local file";
      return setVideoSource("local");
    }
    mpegtsPlayer = mpegts.createPlayer(
      { type: "mpegts", isLive: true, url: wsVideoURL() },
      { enableWorker: true, liveBufferLatencyChasing: true,
        liveBufferLatencyMaxLatency: 1.8, liveBufferLatencyMinRemain: 0.3 });
    mpegtsPlayer.attachMediaElement(v);
    mpegtsPlayer.load();
    v.play().catch(() => {});
    pollVideoState();
  } else {
    videoSrcMode = "local";
    destroyLive();
    if (!localVideos.length) { $("video-note").textContent = "no local media"; return; }
    v.src = "/media/" + encodeURIComponent(localVideos[0]);
    $("video-note").textContent = localVideos[0] + " (local)";
    v.play().catch(() => {});
  }
}

// Received-stream rate straight from the relay: this is the "receive graph". It
// sits flat at the clip's rate, and dips/collapses when a flood collides with it
// on the shared link (no TSN) - the mirror image of the sender's transmit graph.
const rxhist = [];
async function pollVideoState() {
  if (videoSrcMode !== "live") return;
  try {
    const s = await api("/api/video/state");
    const note = $("video-note");
    if (s.receiving) note.textContent = `live · udp:${s.port} · ${fmt(s.kbps / 1000, 2)} Mbps · from ${(s.peers || []).slice(-1)[0] || "?"}`;
    else note.textContent = `waiting for stream on udp:${s.port || "5000"} …`;
    const mbps = (s.receiving ? s.kbps : 0) / 1000;
    rxhist.push(mbps); if (rxhist.length > 120) rxhist.shift();
    if ($("rx-mbps")) {
      $("rx-mbps").textContent = fmt(mbps, 2);
      $("rx-mbps").style.color = s.receiving ? "var(--ok)" : "var(--bad)";
    }
    drawRxchart();
  } catch (e) {}
  if (videoSrcMode === "live") setTimeout(pollVideoState, 500);
}

async function loadVideo() {
  try {
    const m = await api("/api/media");
    localVideos = m.videos || [];
  } catch (e) { localVideos = []; }
  const btns = document.querySelectorAll("#video-src .seg-btn");
  btns.forEach((b) => { b.onclick = () => setVideoSource(b.dataset.src); });
  setVideoSource("live");
}

// Video health: dropped frames / stalls over time. When the flow is starved
// (TSN off under load) playback stutters -> dropped frames spike; TSN on -> flat.
const vhist = [];
let vStalls = 0;
function startVideoMonitor(v) {
  v.addEventListener("waiting", () => { vStalls++; });
  v.addEventListener("stalled", () => { vStalls++; });
  let prevDrop = 0, prevTotal = 0, prevT = 0;
  setInterval(() => {
    const q = v.getVideoPlaybackQuality ? v.getVideoPlaybackQuality() : null;
    const now = performance.now() / 1000;
    let dps = 0, fps = 0;
    if (q && prevT) {
      const dt = now - prevT || 0.5;
      dps = Math.max(0, (q.droppedVideoFrames - prevDrop) / dt);
      fps = Math.max(0, (q.totalVideoFrames - prevTotal) / dt);
      prevDrop = q.droppedVideoFrames; prevTotal = q.totalVideoFrames;
    } else if (q) { prevDrop = q.droppedVideoFrames; prevTotal = q.totalVideoFrames; }
    prevT = now;
    vhist.push(dps); if (vhist.length > 120) vhist.shift();
    $("v-drop").textContent = fmt(dps, 0);
    $("v-drop").style.color = dps > 1 ? "var(--bad)" : "var(--ink)";
    $("v-stall").textContent = vStalls;
    $("v-fps").textContent = fmt(fps, 0);
    drawVchart();
  }, 500);
}
function drawVchart() {
  const cv = $("vchart"); if (!cv) return;
  const dpr = window.devicePixelRatio || 1, W = cv.clientWidth, H = cv.clientHeight;
  if (!W) return;
  cv.width = W * dpr; cv.height = H * dpr;
  const x = cv.getContext("2d"); x.setTransform(dpr, 0, 0, dpr, 0, 0);
  x.clearRect(0, 0, W, H);
  const max = Math.max(5, ...vhist) * 1.15;
  x.strokeStyle = C.grid; x.lineWidth = 1;
  x.beginPath(); x.moveTo(0, H - 1); x.lineTo(W, H - 1); x.stroke();
  if (vhist.length > 1) {
    x.beginPath();
    vhist.forEach((val, i) => {
      const px = W * i / (vhist.length - 1), py = H - (H - 4) * Math.min(val / max, 1) - 2;
      i ? x.lineTo(px, py) : x.moveTo(px, py);
    });
    const bad = vhist[vhist.length - 1] > 1;
    x.strokeStyle = bad ? "#ff453a" : "#34c759"; x.lineWidth = 2; x.lineJoin = "round"; x.stroke();
    x.lineTo(W, H); x.lineTo(0, H); x.closePath();
    x.fillStyle = bad ? "rgba(255,69,58,0.12)" : "rgba(52,199,89,0.12)"; x.fill();
  }
}

// Received rate over time. Reference = the healthy plateau (recent peak); the line
// goes red when the current rate falls well below it, i.e. a flood is winning.
function drawRxchart() {
  const cv = $("rxchart"); if (!cv) return;
  const dpr = window.devicePixelRatio || 1, W = cv.clientWidth, H = cv.clientHeight;
  if (!W) return;
  cv.width = W * dpr; cv.height = H * dpr;
  const x = cv.getContext("2d"); x.setTransform(dpr, 0, 0, dpr, 0, 0);
  x.clearRect(0, 0, W, H);
  const ref = Math.max(0.2, ...rxhist);
  const max = ref * 1.2;
  x.strokeStyle = C.grid; x.lineWidth = 1;
  x.beginPath(); x.moveTo(0, H - 1); x.lineTo(W, H - 1); x.stroke();
  if (rxhist.length > 1) {
    x.beginPath();
    rxhist.forEach((val, i) => {
      const px = W * i / (rxhist.length - 1), py = H - (H - 4) * Math.min(val / max, 1) - 2;
      i ? x.lineTo(px, py) : x.moveTo(px, py);
    });
    const cur = rxhist[rxhist.length - 1];
    const bad = cur < ref * 0.7;   // collapsed well below the healthy plateau
    x.strokeStyle = bad ? "#ff453a" : "#34c759"; x.lineWidth = 2; x.lineJoin = "round"; x.stroke();
    x.lineTo(W, H); x.lineTo(0, H); x.closePath();
    x.fillStyle = bad ? "rgba(255,69,58,0.14)" : "rgba(52,199,89,0.14)"; x.fill();
  }
}

boot();
