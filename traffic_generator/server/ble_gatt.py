"""BLE GATT peripheral for pi-trafgen.

Lets the tablet (the BLE central in the KETI reconfig demo) start/stop the traffic
generator and watch its rate over Bluetooth - no WiFi needed. It advertises as
``KETI-TRAFGEN`` alongside the switch/path peripherals and bridges every command
to the local HTTP server (localhost:8080), so all the pktgen logic stays in one
place.

GATT layout (UUIDs spell "KETI"/"TGEN"):

    service  4b455449-5447-454e-0000-000000000000
      control 4b455449-5447-454e-0000-000000000001  write   UTF-8 command
      status  4b455449-5447-454e-0000-000000000002  notify  compact JSON

Control commands (UTF-8 written to the control characteristic):
    start | stop | preset:<key> | user:<name>

Status notification (every ~500 ms), compact JSON so it fits one MTU:
    {"r":1,"m":999.8,"p":81258,"s":223390,"e":0}
     r running  m Mbps  p pps  s sent packets  e tx errors

Runs on the system Python (needs python3-dbus / python3-gi), NOT the server venv.
"""

from __future__ import annotations

import json
import re
import subprocess
import urllib.parse
import urllib.request

from bluezero import adapter, async_tools, peripheral

API = "http://127.0.0.1:8080"

SERVICE_UUID = "4b455449-5447-454e-0000-000000000000"
CONTROL_UUID = "4b455449-5447-454e-0000-000000000001"
STATUS_UUID = "4b455449-5447-454e-0000-000000000002"

# D10 3-switch triangle (Pi1/TX bridges to all three by JSON-RPC).
#   A .100.1  video zone / FRER generation   (video Pi on its port 1)
#   B .100.2  detour zone + flood            (flood Pi on its port 1)
#   C .100.4  rear / FRER recovery / receiver (receiver Pi on its port 1)
# Ring: A<->B (Gi1/4 each), A<->C (A Gi1/6 -> C Gi1/4), B<->C (B Gi1/6 -> C Gi1/6).
# The video on A reaches C over the DIRECT link A-C and the DETOUR A-B-C.
D10_GEN = "192.168.100.1"     # A — generation (video source)
D10_MID = "192.168.100.2"     # B — detour + flood
D10_REC = "192.168.100.4"     # C rear — recovery (receiver)
VIDEO_EGRESS = "Gi 1/2"       # C egress carrying the FRER-recovered video (CBS lives here)
VIDEO_QUEUE = 6               # CoS/queue the video (PCP 6) is mapped to; flood is PCP 0 -> q0
# App cut:1 = direct route (A→C, drop A's Gi1/6); cut:2 = detour (A→B, drop A's Gi1/4).
RING_PORT = {"1": (D10_GEN, "Gi 1/6"), "2": (D10_GEN, "Gi 1/4")}
_cbs_mbps = 250               # remembered CBS reservation (Mbps), applied on cbs:on
_cbs_port = VIDEO_EGRESS      # remembered CBS egress port, changeable from the tablet
_cbs_queue = VIDEO_QUEUE      # remembered CBS queue/TC, changeable from the tablet
_resp = ""                    # last on-demand query result (ping / port status), sent in the notify

def _local_name() -> str:
    # Distinguish the two Pis for the tablet: name by role (/etc/pi-trafgen/view).
    try:
        view = open("/etc/pi-trafgen/view").read().strip()
    except OSError:
        view = ""
    return {"tx": "KETI-TRAFGEN-TX", "video": "KETI-TRAFGEN-RX"}.get(view, "KETI-TRAFGEN")


LOCAL_NAME = _local_name()
NOTIFY_MS = 500


# -- HTTP bridge to the local server ----------------------------------------
def _post(path: str) -> None:
    req = urllib.request.Request(API + path, method="POST")
    urllib.request.urlopen(req, timeout=4).read()


def _get(path: str) -> dict:
    with urllib.request.urlopen(API + path, timeout=4) as r:
        return json.loads(r.read().decode())


# -- D10 switch bridge (JSON-RPC via the local /api/d10 proxy) --------------
def _d10(host: str, method: str, params: list) -> dict:
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(
        f"{API}/api/d10/rpc?host={host}", data=body,
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=8) as r:
        return json.loads(r.read().decode())


def _d10_get(host: str, method: str, params: list):
    return _d10(host, method, params).get("result")


# -- on-demand diagnostics (call-based, not continuous) ---------------------
def _run_ping(target: str) -> str:
    """ICMP ping the target from this Pi (the bridge reaches the switch subnet).
    Returns a short human string for the tablet, e.g. '192.168.100.1: 0.5 ms avg · 0% loss'."""
    try:
        out = subprocess.run(["ping", "-c", "5", "-W", "1", target],
                             capture_output=True, text=True, timeout=12).stdout
        loss = "?"
        avg = "?"
        m = re.search(r"(\d+)% packet loss", out)
        if m:
            loss = m.group(1)
        m = re.search(r"=\s*[\d.]+/([\d.]+)/", out)  # rtt min/avg/max
        if m:
            avg = m.group(1)
        return f"{target}: {avg} ms avg · {loss}% loss"
    except Exception:  # noqa: BLE001
        return f"{target}: unreachable"


def _fetch_ports(host: str) -> str:
    """Live per-port link state of one D10 (JSON-RPC), compact for one MTU."""
    res = _d10_get(host, "port.status.get", [])
    if not isinstance(res, list):
        return f"{host}: ports n/a"
    up, down = [], []
    for e in res:
        name = (e.get("key", "") if isinstance(e, dict) else "").replace("Gi ", "").strip()
        val = e.get("val", {}) if isinstance(e, dict) else {}
        if not name:
            continue
        if val.get("Link"):
            up.append(f"{name}({val.get('Speed', '').replace('speed', '')})")
        else:
            down.append(name)
    return "UP " + " ".join(up) + (" · DOWN " + " ".join(down) if down else "")


def handle_command(text: str) -> None:
    global _cbs_mbps, _cbs_port, _cbs_queue, _resp
    text = text.strip()
    try:
        # -- traffic generator (this node's local API) ----------------------
        if text == "start":
            _post("/api/start")
        elif text == "stop":
            _post("/api/stop")
        elif text.startswith("preset:"):
            _post(f"/api/preset/{text[7:]}")
        elif text.startswith("user:"):
            _post(f"/api/userpresets/{urllib.parse.quote(text[5:])}/load")

        # -- CBS (802.1Qav) credit-based shaper on an egress queue ----------
        # cbs:on / cbs:off          -> apply/clear on the remembered port+queue+rate
        # cbs:mbps:<N>              -> set the reservation (Mbps), applied on next cbs:on
        # cbs:cfg:<port>:<q>:<N>:<on|off>  -> tablet picks port(index, e.g. 2 = Gi 1/2),
        #                             queue/TC, rate(Mbps) and state, so CBS can be tried
        #                             at any point of contention, not just one hardcoded spot.
        elif text == "cbs:on":
            _d10(D10_REC, "qos.config.interface.queueShaper.set", [_cbs_port, _cbs_queue,
                 {"Enable": True, "Credit": True, "Cir": _cbs_mbps * 1000, "RateType": "line", "Excess": False}])
        elif text == "cbs:off":
            _d10(D10_REC, "qos.config.interface.queueShaper.set", [_cbs_port, _cbs_queue,
                 {"Enable": False, "Credit": False, "Cir": 500, "RateType": "line", "Excess": False}])
        elif text.startswith("cbs:mbps:"):
            _cbs_mbps = int(text.rsplit(":", 1)[1])   # applied on the next cbs:on
        elif text.startswith("cbs:cfg:"):
            _, _, port, q, mbps, state = text.split(":")
            _cbs_port = f"Gi 1/{port}"
            _cbs_queue = int(q)
            _cbs_mbps = int(mbps)
            on = state == "on"
            _d10(D10_REC, "qos.config.interface.queueShaper.set", [_cbs_port, _cbs_queue,
                 {"Enable": on, "Credit": on, "Cir": (_cbs_mbps * 1000) if on else 500,
                  "RateType": "line", "Excess": False}])

        # -- on-demand diagnostics (result comes back in the status notify's "q") --
        elif text.startswith("q:ping:"):
            _resp = _run_ping(text.split(":", 2)[2])
        elif text.startswith("q:ports:"):
            _resp = _fetch_ports(text.split(":", 2)[2])

        # -- FRER (802.1CB) instance 1 on both switches ---------------------
        elif text in ("frer:on", "frer:off"):
            active = text == "frer:on"
            for sw in (D10_GEN, D10_REC):
                conf = _d10_get(sw, "frer.config.get", [1])
                if isinstance(conf, dict):
                    conf["AdminActive"] = active
                    _d10(sw, "frer.config.set", [1, conf])
        elif text.startswith("frer:alg:"):
            alg = text.rsplit(":", 1)[1]              # vector | match
            for sw in (D10_GEN, D10_REC):
                conf = _d10_get(sw, "frer.config.get", [1])
                if isinstance(conf, dict):
                    conf["Algorithm"] = alg
                    _d10(sw, "frer.config.set", [1, conf])

        # -- TAS (802.1Qbv) gates on the receiver egress --------------------
        elif text in ("tas:on", "tas:off"):
            p = _d10_get(D10_REC, "tsn.config.interface.tas.params.get", [VIDEO_EGRESS])
            if isinstance(p, dict):
                p["GateEnabled"] = text == "tas:on"
                _d10(D10_REC, "tsn.config.interface.tas.params.set", [VIDEO_EGRESS, p])
        elif text.startswith("tas:cycle:"):
            us = int(text.rsplit(":", 1)[1])
            p = _d10_get(D10_REC, "tsn.config.interface.tas.params.get", [VIDEO_EGRESS])
            if isinstance(p, dict):
                p["AdminCycleTimeNumerator"] = us
                p["AdminCycleTimeDenominator"] = 1000000
                _d10(D10_REC, "tsn.config.interface.tas.params.set", [VIDEO_EGRESS, p])

        # -- FRER route cut / restore (shutdown a ring port) ----------------
        elif text.startswith(("cut:", "restore:")):
            action, which = text.split(":", 1)
            hp = RING_PORT.get(which)
            if hp:
                host, port = hp
                cfg = _d10_get(host, "port.config.get", [port])
                if isinstance(cfg, dict):
                    cfg["Shutdown"] = action == "cut"
                    _d10(host, "port.config.set", [port, cfg])
    except Exception as exc:  # noqa: BLE001 - a bad command must not kill the peripheral
        print(f"[ble] command {text!r} failed: {exc}")


# -- characteristic callbacks -----------------------------------------------
def control_write(value, options):  # noqa: ANN001 - bluezero signature
    try:
        text = bytes(value).decode("utf-8", "ignore")
    except Exception:  # noqa: BLE001
        return
    print(f"[ble] <- {text!r}")
    handle_command(text)


def status_payload() -> bytes:
    try:
        st = _get("/api/status")
        last = st.get("last", {})
        obj = {
            "r": 1 if st.get("running") else 0,
            "m": round(float(last.get("mbps", 0)), 1),
            "p": int(last.get("pps", 0)),
            "s": int(last.get("sent_packets", 0)),
            "e": int(last.get("tx_errors", 0)),
            "q": _resp,   # last on-demand ping / port-status result
        }
    except Exception:  # noqa: BLE001 - server momentarily down => report idle
        obj = {"r": 0, "m": 0, "p": 0, "s": 0, "e": 0}
    return json.dumps(obj, separators=(",", ":")).encode()


def make_notifier(characteristic):  # noqa: ANN001
    """Return the GLib timer callback that pushes status while a client listens."""

    def _tick():
        if not characteristic.is_notifying:
            return False  # stop the timer once the central unsubscribes
        characteristic.set_value(status_payload())
        return True

    return _tick


def status_notify(notifying, characteristic):  # noqa: ANN001 - bluezero signature
    if notifying:
        async_tools.add_timer_ms(NOTIFY_MS, make_notifier(characteristic))


def status_read(options):  # noqa: ANN001
    return status_payload()


# -- assembly ----------------------------------------------------------------
def on_connect(device):  # noqa: ANN001 - bluezero passes the remote device
    print(f"[ble] central connected: {getattr(device, 'address', device)}")


def on_disconnect(adapter_addr, device_addr):  # noqa: ANN001
    # bluezero keeps the advertisement registered across disconnects, so the
    # peripheral stays discoverable for the next connection without any work here.
    print(f"[ble] central disconnected: {device_addr} (still advertising)")


def build() -> peripheral.Peripheral:
    dongle = list(adapter.Adapter.available())[0]
    # Keep the controller powered and connectable across reconnects.
    try:
        dongle.powered = True
    except Exception:  # noqa: BLE001
        pass
    trafgen = peripheral.Peripheral(dongle.address, local_name=LOCAL_NAME)
    # Re-advertise automatically after a central drops (attributes exist on the
    # bluezero Peripheral; guard in case of an older build).
    try:
        trafgen.on_connect = on_connect
        trafgen.on_disconnect = on_disconnect
    except Exception:  # noqa: BLE001
        pass
    trafgen.add_service(srv_id=1, uuid=SERVICE_UUID, primary=True)
    trafgen.add_characteristic(
        srv_id=1, chr_id=1, uuid=CONTROL_UUID,
        value=[], notifying=False,
        flags=["write", "write-without-response"],
        write_callback=control_write,
    )
    trafgen.add_characteristic(
        srv_id=1, chr_id=2, uuid=STATUS_UUID,
        value=[], notifying=False,
        flags=["read", "notify"],
        read_callback=status_read,
        notify_callback=status_notify,
    )
    return trafgen


def main() -> None:
    trafgen = build()
    print(f"[ble] advertising as {LOCAL_NAME} ({SERVICE_UUID})")
    trafgen.publish()  # blocks on the GLib main loop


if __name__ == "__main__":
    main()
