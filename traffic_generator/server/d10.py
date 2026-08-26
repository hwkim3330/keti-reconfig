"""Kontron KSwitch D10 (Microchip WebStaX) JSON-RPC proxy.

The unified UI drives the switch through here. Only this Pi has an in-band route
to the 192.168.100.x management net, so the browser can't reach the switch
directly — it POSTs to us and we forward. Pure stdlib (urllib), no new deps.

    Browser ─▶ traffic_generator (this Pi) ─JSON-RPC/Basic─▶ D10 192.168.100.2 / .4
"""

from __future__ import annotations

import base64
import json
import os
import urllib.request

# Switch 1 = generation side, switch 2 = recovery side of the FRER ring.
SWITCHES = [
    s.strip() for s in os.environ.get("D10_HOSTS", "192.168.100.2,192.168.100.4").split(",") if s.strip()
]
DEFAULT_HOST = SWITCHES[0] if SWITCHES else "192.168.100.2"
_ALLOWED = set(SWITCHES)

USER = os.environ.get("D10_USER", "admin")
PASS = os.environ.get("D10_PASS", "")            # WebStaX default: blank
_AUTH = "Basic " + base64.b64encode(f"{USER}:{PASS}".encode()).decode()


def rpc(body: dict | list | str, host: str | None = None, timeout: float = 8.0) -> dict:
    """Forward a JSON-RPC body (single or batch) to a chosen switch.

    Returns the parsed JSON reply, or a JSON-RPC-shaped error dict on transport
    failure so the caller always gets JSON.
    """
    target = host if host in _ALLOWED else DEFAULT_HOST
    data = (body if isinstance(body, str) else json.dumps(body)).encode()
    req = urllib.request.Request(
        f"http://{target}/json_rpc",
        data=data,
        headers={"Content-Type": "application/json", "Authorization": _AUTH},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode())
    except Exception as exc:  # noqa: BLE001 - report any transport error as JSON
        return {"id": None, "error": {"code": -32000, "message": f"D10 {target}: {exc}"}}


def health() -> dict:
    """Per-switch liveness for the UI's status pills."""
    out: dict[str, str] = {}
    for h in SWITCHES:
        r = rpc({"id": 1, "method": "port.status.get", "params": []}, host=h, timeout=4.0)
        out[h] = "up" if isinstance(r, dict) and r.get("result") is not None else (
            "auth?" if isinstance(r, dict) and r.get("error", {}).get("code") == -32601 else "unreachable"
        )
    return {"switches": out, "default": DEFAULT_HOST}
