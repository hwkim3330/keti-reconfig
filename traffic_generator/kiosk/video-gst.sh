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

# Sink must match the session. kmssink drives the display plane directly and
# needs DRM master - it FAILS if a compositor (labwc/wayfire, the Pi OS desktop
# default) already owns the screen. So auto-pick: waylandsink inside Wayland,
# glimagesink inside X11, kmssink only on a bare console. Override with
# TRAFGEN_GST_SINK.
if [ -n "${TRAFGEN_GST_SINK:-}" ]; then
  SINK="$TRAFGEN_GST_SINK"
elif [ -n "${WAYLAND_DISPLAY:-}" ]; then
  SINK="waylandsink fullscreen=true"
elif [ -n "${DISPLAY:-}" ]; then
  SINK="glimagesink"
else
  SINK="kmssink force-modesetting=true"
fi

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
