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
import urllib.parse
import urllib.request

from bluezero import adapter, async_tools, peripheral

API = "http://127.0.0.1:8080"

SERVICE_UUID = "4b455449-5447-454e-0000-000000000000"
CONTROL_UUID = "4b455449-5447-454e-0000-000000000001"
STATUS_UUID = "4b455449-5447-454e-0000-000000000002"

LOCAL_NAME = "KETI-TRAFGEN"
NOTIFY_MS = 500


# -- HTTP bridge to the local server ----------------------------------------
def _post(path: str) -> None:
    req = urllib.request.Request(API + path, method="POST")
    urllib.request.urlopen(req, timeout=4).read()


def _get(path: str) -> dict:
    with urllib.request.urlopen(API + path, timeout=4) as r:
        return json.loads(r.read().decode())


def handle_command(text: str) -> None:
    text = text.strip()
    try:
        if text == "start":
            _post("/api/start")
        elif text == "stop":
            _post("/api/stop")
        elif text.startswith("preset:"):
            _post(f"/api/preset/{text[7:]}")
        elif text.startswith("user:"):
            _post(f"/api/userpresets/{urllib.parse.quote(text[5:])}/load")
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
def build() -> peripheral.Peripheral:
    dongle = list(adapter.Adapter.available())[0]
    trafgen = peripheral.Peripheral(dongle.address, local_name=LOCAL_NAME)
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
