#!/usr/bin/env bash
# Lowest-latency, most robust alternative to video-player.sh (mpv).
#
# GStreamer with the Pi's stateful V4L2 decoder (v4l2h264dec -> /dev/video10)
# and a direct KMS sink. This is the digital-signage-grade path: no browser,
# no compositor, no window manager - the decoded frame goes straight to the
# display plane. Use it when you want the tightest glass-to-glass latency or
# when running on a bare console with no Wayland session.
#
# Trade-off vs mpv: no Lua OSD, so it carries no PROTECTED/DEGRADED overlay -
# pair it with the receive graph on another panel if you need the readout.
#
# Requires: gstreamer1.0-plugins-{base,good,bad} and gstreamer1.0-libav.
set -u

PORT="${TRAFGEN_VIDEO_PORT:-5000}"

# kmssink drives the display plane directly (bare console / DRM master).
# If a desktop compositor owns the screen, swap kmssink for `glimagesink` or
# `waylandsink` and run this inside the session instead.
SINK="${TRAFGEN_GST_SINK:-kmssink force-modesetting=true}"

while true; do
  gst-launch-1.0 -q \
    udpsrc port="$PORT" buffer-size=8388608 \
      caps="video/mpegts,systemstream=true,packetsize=188" \
    ! tsparse ! tsdemux ! h264parse \
    ! v4l2h264dec ! videoconvert \
    ! $SINK \
    2>/dev/null
  sleep 1
done
