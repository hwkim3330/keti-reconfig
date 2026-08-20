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

from . import netstat, pktgen, presets

ROOT = pathlib.Path(__file__).resolve().parent.parent
WEB = ROOT / "web"
CONFIG_PATH = pathlib.Path(os.environ.get("TRAFGEN_CONFIG", "/etc/pi-trafgen/config.json"))

SAMPLE_PERIOD = 0.5
HISTORY_LEN = 240  # 2 minutes at 0.5 s

app = FastAPI(title="pi-trafgen")
runner = pktgen.Runner()


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


class State:
    def __init__(self) -> None:
        self.config = load_config()
        self.meter: netstat.RateMeter | None = None
        self.history: list[dict] = []
        self.started_at: float | None = None
        self.last: dict = {"pps": 0.0, "mbps": 0.0, "sent_packets": 0}

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


# --------------------------------------------------------------------------
# live push
# --------------------------------------------------------------------------
async def sampler() -> None:
    while True:
        await asyncio.sleep(SAMPLE_PERIOD)
        if state.meter is None:
            continue
        try:
            sample = state.meter.sample()
        except OSError:
            continue
        if not runner.running:
            sample = {**sample, "pps": 0.0, "mbps": 0.0}
        sample["t"] = time.monotonic() - (state.started_at or time.monotonic())
        state.last = sample
        state.history.append(sample)
        del state.history[:-HISTORY_LEN]


@app.on_event("startup")
async def on_startup() -> None:
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


app.mount("/", StaticFiles(directory=WEB), name="web")
