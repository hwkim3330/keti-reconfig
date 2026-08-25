# Kiosk panels

Each Pi runs one full-screen panel, chosen by `/etc/pi-trafgen/view`:

| `view`  | role      | panel |
|---------|-----------|-------|
| `tx`    | sender    | Chromium → transmit graph (flood START/STOP, 1000 Mbps gauge) |
| `video` | receiver  | **native player** → the protected video, full-screen HW decode |
| (empty) | control   | Chromium → full tabbed UI |

`launch-kiosk.sh` is the single autostart entry point. For `tx`/empty it opens
Chromium; for `video` it hands off to `video-player.sh` and never starts a
browser.

## Why the video panel is not a browser

The browser video path was:

```
source Pi ──UDP MPEG-TS──▶ Python relay ──WebSocket──▶ mpegts.js ──▶ MSE (Chromium)
```

Measured on this bench it **caps at ~20 Mbps**, for two independent reasons:

1. The single-threaded asyncio relay can't drain the UDP socket fast enough.
   At 440 Mbps in, the NIC received 345 Mbps but the relay forwarded only
   19 Mbps — the kernel recv-Q overflowed and dropped the rest.
2. Chromium's MSE has **no hardware decode** on the Pi, so even past the relay
   it can't sustain a high-bitrate stream.

That ceiling is why a 1 Gbps flood never visibly hurt the video: the video on
the wire was tiny (≈0.4 % of the link), so a dumb switch's proportional
tail-drop barely touched it. To make the collision real the video has to be a
real fraction of the gigabit — hundreds of Mbps — which the browser path simply
cannot carry.

## The native path

```
source Pi ──UDP MPEG-TS──▶ mpv / GStreamer ──▶ Pi-4 H.264 HW decoder (/dev/video10)
```

`video-player.sh` reads the UDP MPEG-TS directly in C and decodes on the
hardware block. **Verified: 220 Mbps 720p H.264 at real-time (fps 30,
speed 1.03×).** Now the video can be a real share of the link and a 1 Gbps
flood shears visible packet loss off it — the demo's "지지직", honestly, at
line rate and with no throttling hacks. A 9692 with CBS then reserves the video
class and it goes smooth again.

### Backends (auto-selected, override with `TRAFGEN_PLAYER`)

| backend | HW decode | overlay | notes |
|---------|-----------|---------|-------|
| **mpv**  | v4l2m2m | ✅ `video-osd.lua` (RX Mbps, drops, PROTECTED/DEGRADED) | preferred; `apt install mpv` |
| **gst**  | v4l2h264dec | ❌ | `video-gst.sh`, KMS sink, lowest latency, no compositor needed |
| **cvlc** | avcodec-hw | ❌ | ships on Pi OS, zero-install fallback |

`video-player.sh` picks mpv → gst → cvlc by what's installed. The Python server
still runs for flood control and the link-RX meter; its browser video relay is
only bound lazily when a browser video tab connects, which this panel never
does, so mpv owns UDP :5000 without conflict.

## Player ceiling

The native pipeline is clean up to ~250–346 Mbps on a Pi 4; 440 Mbps already
drops frames at baseline (before any flood). Keep the demo video **≤ 250 Mbps**
(H.264, ≤ 1080p60 — the Pi-4 HW decoder's limit). At 220 Mbps video + 1000 Mbps
flood the receiver loses ≈ 1 − 1000/1220 ≈ 18 % → clearly visible glitching.
