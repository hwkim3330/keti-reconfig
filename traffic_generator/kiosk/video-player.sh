#!/usr/bin/env bash
# Native full-screen video player for the receiver (video) kiosk.
#
# Why this exists instead of the browser <video> tab:
#   The browser path is  UDP -> Python relay -> WebSocket -> mpegts.js -> MSE.
#   Measured on this bench it tops out at ~20 Mbps: the single-threaded asyncio
#   relay can't drain the UDP socket fast enough and the kernel drops the rest
#   (recv-Q overflows), and Chromium's MSE has no hardware decode on the Pi.
#   That 20 Mbps ceiling is why a 1 Gbps flood never actually hurt the video -
#   the video on the wire was tiny.
#
#   mpv reads the UDP MPEG-TS directly in C and decodes on the Pi-4 hardware
#   H.264 block (/dev/video10, h264_v4l2m2m). It sustains the full stream
#   (verified 220 Mbps 720p at real-time), so the video can finally be a real
#   fraction of the gigabit link and the flood collision becomes visible.
#
# The source Pi streams MPEG-TS to udp://<this-host>:5000; mpv owns that port.
# The Python server's relay only binds :5000 lazily when a browser video tab
# connects - which this kiosk never opens - so there is no port conflict.
set -u

PORT="${TRAFGEN_VIDEO_PORT:-5000}"
OSD="$(dirname "$(readlink -f "$0")")/video-osd.lua"

# Wayland (labwc/wayfire, the bookworm/trixie default) exports these into the
# desktop session; inherit them so a systemd/autostart launch reaches the seat.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

# Pick the video output that matches the session. On Wayland prefer a zero-copy
# dmabuf path so the hardware-decoded frames never touch the CPU; fall back to
# the generic GPU vo, then to KMS/DRM if we're on a bare console.
if [ -n "${WAYLAND_DISPLAY:-}" ]; then
  VO="--vo=dmabuf-wl --gpu-context=wayland"
elif [ -n "${DISPLAY:-}" ]; then
  VO="--vo=gpu"
else
  VO="--vo=drm --drm-connector=HDMI-A-1"
fi

# Backend, best-available first:
#   mpv  - hardware decode + the Lua PROTECTED/DEGRADED overlay (preferred)
#   gst  - GStreamer/KMS, lowest latency, no overlay (see video-gst.sh)
#   cvlc - VLC, ships on Pi OS already, HW decode via avcodec, no overlay
# Override with TRAFGEN_PLAYER=mpv|gst|cvlc.
PLAYER="${TRAFGEN_PLAYER:-}"
if [ -z "$PLAYER" ]; then
  if   command -v mpv           >/dev/null 2>&1; then PLAYER=mpv
  elif command -v gst-launch-1.0 >/dev/null 2>&1; then PLAYER=gst
  elif command -v cvlc          >/dev/null 2>&1; then PLAYER=cvlc
  else echo "video-player: no mpv / gstreamer / vlc installed" >&2; exit 1
  fi
fi

# GStreamer path lives in its own script (KMS sink, own restart loop).
if [ "$PLAYER" = "gst" ]; then
  exec "$(dirname "$(readlink -f "$0")")/video-gst.sh"
fi

URL="udp://@0.0.0.0:${PORT}?fifo_size=8000000&overrun_nonfatal=1"

# Restart loop: a live UDP stream pauses when the source restarts or a flood
# starves it to nothing; the player then hits EOF and exits. Come straight back.
while true; do
  case "$PLAYER" in
    mpv)
      mpv "$URL" \
        --profile=low-latency \
        --hwdec=auto-safe \
        $VO \
        --fullscreen \
        --no-osc --no-osd-bar --osd-level=0 \
        --no-input-default-bindings --input-conf=/dev/null \
        --cursor-autohide=always --no-input-cursor \
        --demuxer-lavf-o=fflags=+nobuffer \
        --cache=no --keep-open=no --idle=no \
        --msg-level=all=error \
        --script="$OSD" \
        2>/dev/null
      ;;
    cvlc)
      # VLC decodes H.264 on the Pi via the MMAL/V4L2 hardware path.
      cvlc --intf dummy --fullscreen --no-video-title-show \
        --no-osd --avcodec-hw=any --network-caching=200 \
        "udp://@:${PORT}" vlc://quit \
        2>/dev/null
      ;;
  esac
  sleep 1
done
