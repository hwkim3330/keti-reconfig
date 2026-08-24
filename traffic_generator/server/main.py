"""pi-trafgen - kernel-pktgen traffic generator with a touch-friendly web UI.

Runs as root on the Pi (pktgen needs it). Serves the UI on :8080 and pushes
live TX rates over a WebSocket.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import os
import pathlib
import time
from dataclasses import asdict

from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from . import netstat, pktgen, presets, video

ROOT = pathlib.Path(__file__).resolve().parent.parent
WEB = ROOT / "web"
CONFIG_PATH = pathlib.Path(os.environ.get("TRAFGEN_CONFIG", "/etc/pi-trafgen/config.json"))
USER_PRESETS_PATH = pathlib.Path(
    os.environ.get("TRAFGEN_USER_PRESETS", "/etc/pi-trafgen/user_presets.json")
)


def _find_media_dir() -> pathlib.Path | None:
    env = os.environ.get("TRAFGEN_MEDIA")
    cands = [env] if env else []
    cands += ["/home/keti/media", "/home/pi/media", str(pathlib.Path.home() / "media"),
              str(ROOT / "media")]
    for c in cands:
        if c and pathlib.Path(c).is_dir():
            return pathlib.Path(c)
    return None


MEDIA_DIR = _find_media_dir()
VIDEO_EXT = {".mp4", ".webm", ".mkv", ".mov", ".m4v"}

SAMPLE_PERIOD = 0.5
HISTORY_LEN = 240  # 2 minutes at 0.5 s

app = FastAPI(title="pi-trafgen")
runner = pktgen.Runner()
relay = video.VideoRelay()
VIDEO_PORT = int(os.environ.get("TRAFGEN_VIDEO_PORT", "5000"))


# --------------------------------------------------------------------------
# state
# --------------------------------------------------------------------------
class StreamModel(BaseModel):
    name: str = "stream"
    enabled: bool = True
    queue: int = 0
    cpu: int = 0
    frame_size: int = Field(512, ge=64, le=9018)
    count: int = Field(0, ge=0)
    dst_mac: str = "ff:ff:ff:ff:ff:ff"
    src_mac: str = ""
    dst_ip: str = "10.0.100.2"
    src_ip: str = ""
    udp_src: int = Field(9, ge=0, le=65535)
    udp_dst: int = Field(9, ge=0, le=65535)
    vlan_id: int | None = Field(None, ge=0, le=4094)
    pcp: int = Field(0, ge=0, le=7)
    rate_mode: str = "max"
    rate_value: float = Field(0.0, ge=0)
    clone_skb: int = Field(0, ge=0)
    burst: int = Field(0, ge=0, le=64)


class ConfigModel(BaseModel):
    iface: str = "eth0"
    streams: list[StreamModel] = Field(default_factory=list)


def default_config() -> ConfigModel:
    ifaces = netstat.interfaces()
    iface = next((i["name"] for i in ifaces if i["operstate"] == "up"), None)
    if iface is None:
        iface = ifaces[0]["name"] if ifaces else "eth0"
    return ConfigModel(iface=iface, streams=[StreamModel(name="stream 1")])


def load_config() -> ConfigModel:
    try:
        return ConfigModel(**json.loads(CONFIG_PATH.read_text()))
    except (OSError, ValueError, TypeError):
        return default_config()


def save_config(cfg: ConfigModel) -> None:
    try:
        CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
        CONFIG_PATH.write_text(json.dumps(cfg.model_dump(), indent=2))
    except OSError:
        pass  # a read-only rootfs shouldn't take the UI down


def load_user_presets() -> dict[str, dict]:
    try:
        data = json.loads(USER_PRESETS_PATH.read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save_user_presets(presets: dict[str, dict]) -> None:
    try:
        USER_PRESETS_PATH.parent.mkdir(parents=True, exist_ok=True)
        USER_PRESETS_PATH.write_text(json.dumps(presets, indent=2))
    except OSError:
        pass


class State:
    def __init__(self) -> None:
        self.config = load_config()
        self.meter: netstat.RateMeter | None = None
        self.history: list[dict] = []
        self.started_at: float | None = None
        self.last: dict = {"pps": 0.0, "mbps": 0.0, "sent_packets": 0}
        # pktgen's own counters, for the rate math that sysfs can't do under clone_skb
        self._pk_prev: tuple[float, int, int] | None = None  # (t, pkts, bytes)

    def status(self) -> dict:
        iface = self.config.iface
        info = next((i for i in netstat.interfaces() if i["name"] == iface), None)
        return {
            "running": runner.running,
            "iface": iface,
            "link_mbps": (info or {}).get("speed_mbps"),
            "operstate": (info or {}).get("operstate", "unknown"),
            "elapsed": (time.monotonic() - self.started_at) if self.started_at else 0.0,
            "error": runner.error,
            "last": self.last,
        }


state = State()


def to_stream(m: StreamModel, iface: str) -> pktgen.Stream:
    return pktgen.Stream(iface=iface, **m.model_dump())


# --------------------------------------------------------------------------
# api
# --------------------------------------------------------------------------
@app.get("/api/system")
def api_system() -> dict:
    avail = pktgen.available()
    return {
        "pktgen": avail,
        "cpus": len(pktgen.threads()) if avail else os.cpu_count() or 1,
        "interfaces": netstat.interfaces(),
        "presets": {k: {"label": v["label"], "note": v["note"]} for k, v in presets.PRESETS.items()},
        "root": os.geteuid() == 0,
    }


@app.get("/api/config")
def api_get_config() -> dict:
    return state.config.model_dump()


@app.post("/api/config")
def api_set_config(cfg: ConfigModel) -> dict:
    if runner.running:
        raise HTTPException(409, "stop the generator before changing the configuration")
    state.config = cfg
    save_config(cfg)
    return cfg.model_dump()


@app.post("/api/preset/{key}")
def api_preset(key: str) -> dict:
    preset = presets.PRESETS.get(key)
    if preset is None:
        raise HTTPException(404, f"unknown preset {key!r}")
    if runner.running:
        raise HTTPException(409, "stop the generator before loading a preset")

    cpus = len(pktgen.threads()) if pktgen.available() else (os.cpu_count() or 1)
    iface = state.config.iface
    queues = netstat.tx_queue_count(iface)

    streams = []
    for spec in preset["streams"]:
        s = StreamModel(**spec)
        s.cpu = min(s.cpu, cpus - 1)
        s.queue = min(s.queue, queues - 1)
        # keep any dst that the operator already dialled in
        if state.config.streams:
            s.dst_mac = state.config.streams[0].dst_mac
            s.dst_ip = state.config.streams[0].dst_ip
        streams.append(s)

    state.config = ConfigModel(iface=iface, streams=streams)
    save_config(state.config)
    return state.config.model_dump()


def _summarise(cfg: ConfigModel) -> dict:
    """Planned totals for a stored config, for the chip subtitle."""
    total_pps = total_bps = 0.0
    for m in cfg.streams:
        if not m.enabled:
            continue
        s = to_stream(m, cfg.iface)
        pps = s.target_pps()
        total_pps += pps
        total_bps += pktgen.wire_bps(pps, s.frame_size) if pps else 0.0
    return {
        "streams": len([s for s in cfg.streams if s.enabled]),
        "mbps": total_bps / 1e6,
        "pps": total_pps,
        "unthrottled": any(s.enabled and s.rate_mode == "max" for s in cfg.streams),
    }


@app.get("/api/userpresets")
def api_userpresets() -> dict:
    out = {}
    for name, raw in load_user_presets().items():
        try:
            out[name] = _summarise(ConfigModel(**raw))
        except (ValueError, TypeError):
            continue
    return {"presets": out}


@app.post("/api/userpresets/{name}")
def api_userpreset_save(name: str) -> dict:
    name = name.strip()
    if not name:
        raise HTTPException(400, "empty name")
    presets = load_user_presets()
    presets[name] = state.config.model_dump()
    save_user_presets(presets)
    return {"saved": name, "count": len(presets)}


@app.post("/api/userpresets/{name}/load")
def api_userpreset_load(name: str) -> dict:
    if runner.running:
        raise HTTPException(409, "stop the generator before loading a preset")
    presets = load_user_presets()
    if name not in presets:
        raise HTTPException(404, f"no saved preset {name!r}")
    try:
        state.config = ConfigModel(**presets[name])
    except (ValueError, TypeError) as exc:
        raise HTTPException(400, f"stored preset is invalid: {exc}") from exc
    save_config(state.config)
    return state.config.model_dump()


@app.delete("/api/userpresets/{name}")
def api_userpreset_delete(name: str) -> dict:
    presets = load_user_presets()
    presets.pop(name, None)
    save_user_presets(presets)
    return {"deleted": name, "count": len(presets)}


@app.get("/api/status")
def api_status() -> dict:
    return state.status()


@app.post("/api/start")
def api_start() -> dict:
    if runner.running:
        return state.status()
    if not pktgen.available():
        raise HTTPException(503, "pktgen module not loaded (`modprobe pktgen`)")

    iface = state.config.iface
    streams = [to_stream(s, iface) for s in state.config.streams]
    try:
        runner.configure(streams)
    except (ValueError, RuntimeError, OSError) as exc:
        raise HTTPException(400, str(exc)) from exc

    state.meter = netstat.RateMeter(iface)
    state.history = []
    state.started_at = time.monotonic()
    state._pk_prev = None
    runner.start()
    return state.status()


@app.post("/api/stop")
def api_stop() -> dict:
    runner.stop()
    state.started_at = None
    return state.status()


@app.get("/api/results")
def api_results() -> dict:
    return {"devices": runner.results()}


@app.get("/api/history")
def api_history() -> dict:
    return {"history": state.history, "period": SAMPLE_PERIOD}


@app.get("/api/plan")
def api_plan() -> dict:
    """What the current config *should* produce, before running it."""
    iface = state.config.iface
    rows, total_pps, total_bps = [], 0.0, 0.0
    for m in state.config.streams:
        if not m.enabled:
            continue
        s = to_stream(m, iface)
        pps = s.target_pps()
        bps = pktgen.wire_bps(pps, s.frame_size) if pps else 0.0
        total_pps += pps
        total_bps += bps
        rows.append(
            {
                "name": s.name,
                "frame_size": s.frame_size,
                "pps": pps,
                "mbps": bps / 1e6,
                "unthrottled": pps == 0,
                "vlan_id": s.vlan_id,
                "pcp": s.pcp,
                "cpu": s.cpu,
                "queue": s.queue,
            }
        )
    return {
        "streams": rows,
        "total_pps": total_pps,
        "total_mbps": total_bps / 1e6,
        "line_rate_pps": pktgen.pps_for_bps(1e9, state.config.streams[0].frame_size)
        if state.config.streams
        else 0.0,
    }


@app.get("/api/media")
def api_media() -> dict:
    """Video files available to play in the UI."""
    if MEDIA_DIR is None:
        return {"dir": None, "videos": []}
    vids = sorted(
        f.name for f in MEDIA_DIR.iterdir()
        if f.is_file() and f.suffix.lower() in VIDEO_EXT
    )
    return {"dir": str(MEDIA_DIR), "videos": vids}


# --------------------------------------------------------------------------
# live video receiver (network stream from the sender Pi -> browser via MSE)
# --------------------------------------------------------------------------
class VideoRxModel(BaseModel):
    action: str = "start"  # start | stop
    port: int | None = None


@app.get("/api/video/state")
def api_video_state() -> dict:
    return relay.state()


@app.post("/api/video/receiver")
async def api_video_receiver(m: VideoRxModel) -> dict:
    if m.action == "stop":
        await relay.stop()
    else:
        await relay.start(m.port or VIDEO_PORT)
    return relay.state()


@app.websocket("/ws/video")
async def ws_video(sock: WebSocket) -> None:
    """Raw MPEG-TS byte stream for mpegts.js (isLive). Starts the receiver on
    demand so the kiosk 'Live' toggle just works."""
    await sock.accept()
    if not relay.running:
        await relay.start(VIDEO_PORT)
    q = relay.subscribe()
    try:
        while True:
            data = await q.get()
            await sock.send_bytes(data)
    except (WebSocketDisconnect, RuntimeError):
        return
    finally:
        relay.unsubscribe(q)


# --------------------------------------------------------------------------
# live push
# --------------------------------------------------------------------------
async def sampler() -> None:
    while True:
        await asyncio.sleep(SAMPLE_PERIOD)
        if state.meter is None:
            continue

        # sysfs meter is still read for tx_errors/dropped and as a fallback, but the
        # headline pps/mbps come from pktgen's own counters when running - see
        # Runner.wire_totals for why sysfs lies under clone_skb.
        try:
            sample = state.meter.sample()
        except OSError:
            sample = {"pps": 0.0, "mbps": 0.0, "sent_packets": 0, "tx_errors": 0, "tx_dropped": 0}

        if runner.running:
            now = time.monotonic()
            # pktgen zeroes pkts-sofar on each start, so the raw total is this run's.
            pkts, wbytes, errs = runner.wire_totals()
            if state._pk_prev is not None:
                pt, pp, pb = state._pk_prev
                dt = now - pt
                if dt > 0 and pkts >= pp:
                    sample["pps"] = (pkts - pp) / dt
                    sample["mbps"] = ((wbytes - pb) * 8 / dt) / 1e6
            state._pk_prev = (now, pkts, wbytes)
            sample["sent_packets"] = pkts
            sample["tx_errors"] = errs
        else:
            sample = {**sample, "pps": 0.0, "mbps": 0.0}
            state._pk_prev = None

        sample["t"] = time.monotonic() - (state.started_at or time.monotonic())
        state.last = sample
        state.history.append(sample)
        del state.history[:-HISTORY_LEN]


@app.on_event("startup")
async def on_startup() -> None:
    video.set_rx_iface(state.config.iface)   # link-RX meter reads this NIC
    app.state.sampler = asyncio.create_task(sampler())


@app.on_event("shutdown")
async def on_shutdown() -> None:
    app.state.sampler.cancel()
    with contextlib.suppress(asyncio.CancelledError):
        await app.state.sampler
    runner.stop()


@app.websocket("/ws")
async def ws(sock: WebSocket) -> None:
    await sock.accept()
    try:
        await sock.send_json({"type": "history", "history": state.history, "status": state.status()})
        while True:
            await asyncio.sleep(SAMPLE_PERIOD)
            await sock.send_json({"type": "tick", "sample": state.last, "status": state.status()})
    except (WebSocketDisconnect, RuntimeError):
        return


# --------------------------------------------------------------------------
# ui
# --------------------------------------------------------------------------
@app.get("/")
def index() -> FileResponse:
    return FileResponse(WEB / "index.html")


# video files (served with range support by StaticFiles, so <video> can seek)
if MEDIA_DIR is not None:
    app.mount("/media", StaticFiles(directory=str(MEDIA_DIR)), name="media")

app.mount("/", StaticFiles(directory=WEB), name="web")
