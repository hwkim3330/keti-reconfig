#!/usr/bin/env python3
"""UDP interference generator for the software (tc) TSN demo.

The main generator uses kernel pktgen, which injects *below* the qdisc - great
for line-rate stress through the 9662 (the switch classifies by VLAN/PCP), but it
bypasses Linux tc, so tc priority classes can't touch it. This blaster instead
sends with ordinary UDP sockets, so its packets traverse the egress qdisc and
fall into whatever tc class matches their destination port. That makes it the
"high-priority interference" that competes with the video in tsn_tc.sh.

    ./udp_flood.py <dst_ip> [--port 9999] [--size 1400] [--seconds 0] [--procs 3]

seconds=0 runs until killed. Uses several processes so it can actually saturate a
fast link past the Python GIL.
"""
from __future__ import annotations

import argparse
import os
import signal
import socket
import time


def blast(dst: str, port: int, size: int, seconds: float) -> None:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    pkt = b"\x00" * size
    end = (time.monotonic() + seconds) if seconds else None
    while end is None or time.monotonic() < end:
        for _ in range(500):
            try:
                s.sendto(pkt, (dst, port))
            except OSError:
                pass


def main() -> None:
    ap = argparse.ArgumentParser(description="UDP interference blaster (tc-classifiable)")
    ap.add_argument("dst", help="destination IP")
    ap.add_argument("--port", type=int, default=9999)
    ap.add_argument("--size", type=int, default=1400)
    ap.add_argument("--seconds", type=float, default=0.0, help="0 = run until killed")
    ap.add_argument("--procs", type=int, default=3)
    a = ap.parse_args()

    pids = []
    for _ in range(max(1, a.procs)):
        pid = os.fork()
        if pid == 0:
            blast(a.dst, a.port, a.size, a.seconds)
            os._exit(0)
        pids.append(pid)
    try:
        for p in pids:
            os.waitpid(p, 0)
    except KeyboardInterrupt:
        for p in pids:
            try:
                os.kill(p, signal.SIGTERM)
            except OSError:
                pass


if __name__ == "__main__":
    main()
