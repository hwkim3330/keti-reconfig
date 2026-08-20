"""Interface enumeration and TX counter sampling from sysfs."""

from __future__ import annotations

import os
import time

SYS_NET = "/sys/class/net"

# Per frame, on top of what tx_bytes counts: FCS (4) + preamble/SFD (8) + IFG (12).
# tx_bytes is the skb length, so it includes the L2 header but not the FCS.
WIRE_PER_FRAME = 24


def _read(path: str) -> str | None:
    try:
        with open(path) as fh:
            return fh.read().strip()
    except OSError:
        return None


def _int(path: str) -> int:
    v = _read(path)
    try:
        return int(v)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return 0


def interfaces() -> list[dict]:
    """Physical, non-virtual interfaces that pktgen can plausibly drive."""
    out = []
    for name in sorted(os.listdir(SYS_NET)):
        base = os.path.join(SYS_NET, name)
        if name == "lo" or not os.path.exists(os.path.join(base, "device")):
            continue
        speed = _read(os.path.join(base, "speed"))
        out.append(
            {
                "name": name,
                "mac": _read(os.path.join(base, "address")) or "",
                "operstate": _read(os.path.join(base, "operstate")) or "unknown",
                "speed_mbps": int(speed) if speed and speed.lstrip("-").isdigit() else None,
                "mtu": _int(os.path.join(base, "mtu")),
                "tx_queues": tx_queue_count(name),
                "driver": driver(name),
            }
        )
    return out


def tx_queue_count(iface: str) -> int:
    qdir = os.path.join(SYS_NET, iface, "queues")
    try:
        return sum(1 for q in os.listdir(qdir) if q.startswith("tx-")) or 1
    except OSError:
        return 1


def driver(iface: str) -> str:
    link = os.path.join(SYS_NET, iface, "device", "driver")
    try:
        return os.path.basename(os.readlink(link))
    except OSError:
        return ""


def snapshot(iface: str) -> dict:
    st = os.path.join(SYS_NET, iface, "statistics")
    return {
        "t": time.monotonic(),
        "tx_packets": _int(os.path.join(st, "tx_packets")),
        "tx_bytes": _int(os.path.join(st, "tx_bytes")),
        "tx_errors": _int(os.path.join(st, "tx_errors")),
        "tx_dropped": _int(os.path.join(st, "tx_dropped")),
    }


class RateMeter:
    """Turns successive sysfs snapshots into on-wire rates."""

    def __init__(self, iface: str) -> None:
        self.iface = iface
        self._prev = snapshot(iface)
        self._base = self._prev

    def reset(self) -> None:
        self._prev = snapshot(self.iface)
        self._base = self._prev

    def sample(self) -> dict:
        now = snapshot(self.iface)
        dt = now["t"] - self._prev["t"]
        dpkts = now["tx_packets"] - self._prev["tx_packets"]
        dbytes = now["tx_bytes"] - self._prev["tx_bytes"]

        if dt <= 0 or dpkts < 0 or dbytes < 0:  # counter wrap or a bogus clock
            self._prev = now
            return {"pps": 0.0, "mbps": 0.0, "sent_packets": 0, "tx_errors": 0, "tx_dropped": 0}

        pps = dpkts / dt
        # Add back the bytes the NIC puts on the wire but the counter never sees.
        wire_bytes = dbytes + dpkts * WIRE_PER_FRAME
        mbps = (wire_bytes * 8 / dt) / 1e6

        self._prev = now
        return {
            "pps": pps,
            "mbps": mbps,
            "sent_packets": now["tx_packets"] - self._base["tx_packets"],
            "sent_bytes": now["tx_bytes"] - self._base["tx_bytes"],
            "tx_errors": now["tx_errors"] - self._base["tx_errors"],
            "tx_dropped": now["tx_dropped"] - self._base["tx_dropped"],
        }
