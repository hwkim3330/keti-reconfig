"""Live video receiver for the TSN demo.

The *sender* Pi streams an MPEG-TS video over UDP (see demo/stream_video.sh),
tagged with a high PCP so the 9662 can protect it. This module is the *receiver*
side: it listens on a UDP port, and fans the raw TS bytes out to any browser
tabs connected on /ws/video. In the browser, mpegts.js feeds those bytes into a
<video> via MSE - so the kiosk plays the *received network stream*, not a local
file. When the background flood starves the link (TSN off) the picture stutters
and the health graph spikes; with TSN on the protected class keeps it smooth.

No transcoding happens here - it is a pure byte relay, so a Pi can do it at line
rate. Packet loss on the wire shows up directly as decode glitches downstream.
"""

from __future__ import annotations

import asyncio
import time


class _RxProtocol(asyncio.DatagramProtocol):
    def __init__(self, relay: "VideoRelay") -> None:
        self._relay = relay

    def datagram_received(self, data: bytes, addr) -> None:  # noqa: ANN001
        self._relay._feed(data, addr)


class VideoRelay:
    """UDP MPEG-TS listener that broadcasts to WebSocket subscribers."""

    def __init__(self) -> None:
        self._transport: asyncio.DatagramTransport | None = None
        self._subs: set[asyncio.Queue[bytes]] = set()
        self.port: int | None = None
        self.pkts = 0
        self.bytes = 0
        self.last_rx = 0.0
        self._rate_bytes = 0
        self._rate_t = 0.0
        self.kbps = 0.0
        self.peers: set[str] = set()

    @property
    def running(self) -> bool:
        return self._transport is not None

    async def start(self, port: int) -> None:
        if self.running:
            if port == self.port:
                return
            await self.stop()
        loop = asyncio.get_running_loop()
        transport, _ = await loop.create_datagram_endpoint(
            lambda: _RxProtocol(self),
            local_addr=("0.0.0.0", port),
        )
        self._transport = transport
        self.port = port
        self.pkts = self.bytes = 0
        self._rate_bytes = 0
        self._rate_t = time.monotonic()
        self.peers = set()

    async def stop(self) -> None:
        if self._transport is not None:
            self._transport.close()
            self._transport = None
        self.port = None
        self.kbps = 0.0

    def _feed(self, data: bytes, addr) -> None:  # noqa: ANN001
        self.pkts += 1
        self.bytes += len(data)
        self.peers.add(addr[0])
        now = time.monotonic()
        self._rate_bytes += len(data)
        if now - self._rate_t >= 0.5:
            self.kbps = (self._rate_bytes * 8 / (now - self._rate_t)) / 1e3
            self._rate_bytes = 0
            self._rate_t = now
        self.last_rx = now
        for q in self._subs:
            if q.full():
                # slow consumer - drop the oldest datagram to keep latency bounded
                try:
                    q.get_nowait()
                except asyncio.QueueEmpty:
                    pass
            try:
                q.put_nowait(data)
            except asyncio.QueueFull:
                pass

    def subscribe(self) -> asyncio.Queue[bytes]:
        q: asyncio.Queue[bytes] = asyncio.Queue(maxsize=256)
        self._subs.add(q)
        return q

    def unsubscribe(self, q: asyncio.Queue[bytes]) -> None:
        self._subs.discard(q)

    def state(self) -> dict:
        alive = self.running and (time.monotonic() - self.last_rx) < 2.0
        return {
            "running": self.running,
            "port": self.port,
            "receiving": alive,
            "kbps": round(self.kbps, 1),
            "pkts": self.pkts,
            "clients": len(self._subs),
            "peers": sorted(self.peers),
        }
