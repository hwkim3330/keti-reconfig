"""Thin driver around the kernel pktgen /proc interface.

pktgen layout
-------------
    /proc/net/pktgen/pgctrl          "start" | "stop" | "reset"
    /proc/net/pktgen/kpktgend_<cpu>  "rem_device_all" | "add_device <if>@<q>"
    /proc/net/pktgen/<if>@<q>        per-device parameters

Two things bite everyone who scripts this by hand:

  * ``add_device eth0@0`` creates a proc entry literally named ``eth0@0``.
    Writing to ``/proc/net/pktgen/eth0`` afterwards fails with ENOENT.
  * ``echo start > pgctrl`` BLOCKS until every thread finishes.  With
    ``count 0`` that is forever, so the write has to live on its own thread
    and ``stop`` gets written from somewhere else.
"""

from __future__ import annotations

import os
import re
import threading
from dataclasses import dataclass, field

_SOFAR_RE = re.compile(r"pkts-sofar:\s*(\d+)")
_ERRORS_RE = re.compile(r"errors:\s*(\d+)")

PKTGEN_DIR = "/proc/net/pktgen"
PGCTRL = os.path.join(PKTGEN_DIR, "pgctrl")

# preamble (7) + SFD (1) + inter-frame gap (12); FCS is counted inside frame_size
WIRE_OVERHEAD = 20


class PktgenUnavailable(RuntimeError):
    pass


def available() -> bool:
    return os.path.isdir(PKTGEN_DIR)


def require() -> None:
    if not available():
        raise PktgenUnavailable(
            "/proc/net/pktgen missing - run `modprobe pktgen`. If the module "
            "does not exist this kernel was built without CONFIG_NET_PKTGEN."
        )


def threads() -> list[str]:
    """Names of the per-CPU kpktgend_N control files, ordered by CPU."""
    require()
    names = [n for n in os.listdir(PKTGEN_DIR) if n.startswith("kpktgend_")]
    return sorted(names, key=lambda n: int(n.split("_")[1]))


def _write(path: str, command: str) -> None:
    # One command per write(2) - pktgen parses a single line per call.
    with open(path, "w") as fh:
        fh.write(command + "\n")


def wire_bps(pps: float, frame_size: int) -> float:
    """Bits/s actually consumed on the medium by `pps` frames of `frame_size`."""
    return pps * (frame_size + WIRE_OVERHEAD) * 8


def pps_for_bps(bps: float, frame_size: int) -> float:
    return bps / ((frame_size + WIRE_OVERHEAD) * 8)


@dataclass
class Stream:
    """One pktgen device: a single CPU thread feeding a single TX queue."""

    name: str = "stream"
    enabled: bool = True
    iface: str = "eth0"
    queue: int = 0
    cpu: int = 0

    # On-wire frame size INCLUDING the 4-byte FCS. pktgen's own `pkt_size`
    # excludes the FCS, so we subtract 4 when programming it.
    frame_size: int = 512
    count: int = 0  # 0 = run until stopped

    dst_mac: str = "ff:ff:ff:ff:ff:ff"
    src_mac: str = ""  # blank = use the interface's own MAC
    dst_ip: str = "10.0.100.2"
    src_ip: str = ""
    udp_src: int = 9
    udp_dst: int = 9

    vlan_id: int | None = None  # None = send untagged
    pcp: int = 0

    # "max" = as fast as the CPU manages, otherwise a pps or wire-Mbps target
    rate_mode: str = "max"  # max | pps | mbps
    rate_value: float = 0.0

    clone_skb: int = 0  # >0 reuses the skb: much faster, but not every driver likes it
    burst: int = 0  # xmit_more batching
    flags: list[str] = field(default_factory=list)

    @property
    def device(self) -> str:
        return f"{self.iface}@{self.queue}"

    @property
    def procfile(self) -> str:
        return os.path.join(PKTGEN_DIR, self.device)

    def target_pps(self) -> float:
        """The pps this stream is configured to emit (0.0 = unthrottled)."""
        if self.rate_mode == "pps":
            return self.rate_value
        if self.rate_mode == "mbps":
            return pps_for_bps(self.rate_value * 1e6, self.frame_size)
        return 0.0

    def commands(self) -> list[str]:
        """The full ordered parameter program for this device."""
        cmds = [
            f"pkt_size {max(self.frame_size - 4, 42)}",
            f"count {self.count}",
            f"dst_mac {self.dst_mac}",
            f"dst {self.dst_ip}",
            f"udp_src_min {self.udp_src}",
            f"udp_src_max {self.udp_src}",
            f"udp_dst_min {self.udp_dst}",
            f"udp_dst_max {self.udp_dst}",
            f"clone_skb {self.clone_skb}",
        ]
        if self.src_mac:
            cmds.append(f"src_mac {self.src_mac}")
        if self.src_ip:
            cmds.append(f"src_min {self.src_ip}")
            cmds.append(f"src_max {self.src_ip}")
        if self.burst:
            cmds.append(f"burst {self.burst}")

        if self.vlan_id is None:
            cmds.append("vlan_id 4095")  # pktgen's "no VLAN" sentinel
        else:
            cmds += [f"vlan_id {self.vlan_id}", f"vlan_p {self.pcp}", "vlan_cfi 0"]

        pps = self.target_pps()
        cmds.append(f"ratep {int(round(pps))}" if pps > 0 else "delay 0")

        for flag in self.flags:
            cmds.append(f"flag {flag}")
        return cmds


class Runner:
    """Owns the pktgen global state: configure, start, stop."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._thread: threading.Thread | None = None
        self._streams: list[Stream] = []
        self._error: str | None = None

    # -- introspection -------------------------------------------------
    @property
    def running(self) -> bool:
        return self._thread is not None and self._thread.is_alive()

    @property
    def error(self) -> str | None:
        return self._error

    @property
    def streams(self) -> list[Stream]:
        return list(self._streams)

    # -- lifecycle -----------------------------------------------------
    def clear(self) -> None:
        """Detach every device from every thread and reset pktgen."""
        require()
        for t in threads():
            _write(os.path.join(PKTGEN_DIR, t), "rem_device_all")
        _write(PGCTRL, "reset")

    def configure(self, streams: list[Stream]) -> list[Stream]:
        """Program `streams` into pktgen. Returns the streams actually armed."""
        require()
        if self.running:
            raise RuntimeError("cannot reconfigure while running - stop first")

        active = [s for s in streams if s.enabled]
        if not active:
            raise ValueError("no enabled streams")

        cpus = len(threads())
        seen: set[str] = set()
        for s in active:
            if not 0 <= s.cpu < cpus:
                raise ValueError(f"{s.name}: cpu {s.cpu} out of range (0..{cpus - 1})")
            if s.device in seen:
                raise ValueError(
                    f"{s.device} used twice - pktgen allows one thread per device@queue"
                )
            seen.add(s.device)

        self.clear()
        for s in active:
            _write(os.path.join(PKTGEN_DIR, f"kpktgend_{s.cpu}"), f"add_device {s.device}")
        for s in active:
            if not os.path.exists(s.procfile):
                raise RuntimeError(
                    f"{s.procfile} was not created - is {s.iface} up, and does it "
                    f"have at least {s.queue + 1} TX queues?"
                )
            for cmd in s.commands():
                _write(s.procfile, cmd)

        self._streams = active
        return active

    def start(self) -> None:
        require()
        with self._lock:
            if self.running:
                return
            if not self._streams:
                raise RuntimeError("nothing configured")
            self._error = None

            def _run() -> None:
                try:
                    _write(PGCTRL, "start")  # blocks until all threads stop
                except Exception as exc:  # noqa: BLE001 - surfaced to the UI
                    self._error = str(exc)

            self._thread = threading.Thread(target=_run, daemon=True, name="pktgen-start")
            self._thread.start()

    def stop(self, timeout: float = 5.0) -> None:
        if not available():
            return
        try:
            _write(PGCTRL, "stop")
        except OSError:
            pass
        t = self._thread
        if t is not None:
            t.join(timeout=timeout)
        self._thread = None

    # -- results -------------------------------------------------------
    def results(self) -> dict[str, str]:
        """Raw per-device proc dumps - pktgen's own counters and Result: line."""
        out: dict[str, str] = {}
        for s in self._streams:
            try:
                with open(s.procfile) as fh:
                    out[s.device] = fh.read()
            except OSError as exc:
                out[s.device] = f"<unreadable: {exc}>"
        return out

    def wire_totals(self) -> tuple[int, int, int]:
        """Authoritative TX totals straight from pktgen's own counters.

        Returns (packets, on-wire bytes, errors) summed across every configured
        device. This is read instead of the interface's sysfs tx_packets because
        clone_skb (which we use to reach line rate) leaves the sysfs counter flat
        on some drivers - bcmgenet on the Pi is one - while pktgen's pkts-sofar is
        always correct.
        """
        total_pkts = 0
        total_bytes = 0
        total_errs = 0
        for s in self._streams:
            try:
                with open(s.procfile) as fh:
                    text = fh.read()
            except OSError:
                continue
            m = _SOFAR_RE.search(text)
            if m:
                pkts = int(m.group(1))
                total_pkts += pkts
                total_bytes += pkts * (s.frame_size + WIRE_OVERHEAD)
            e = _ERRORS_RE.search(text)
            if e:
                total_errs += int(e.group(1))
        return total_pkts, total_bytes, total_errs
