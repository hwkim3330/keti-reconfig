#!/usr/bin/env bash
# Stream a video file as the "protected" flow for the TSN demo.
#
# The video is sent over UDP (MPEG-TS) from this Pi's eth0. Optionally it is put
# on a VLAN with a high PCP so the switch (9662) can classify it into a protected
# traffic class (CBS/TAS). Run pi-trafgen at the same time as the *background
# flood* (low PCP) - with TSN on, this video keeps playing; with TSN off, it
# stutters as the flood starves it.
#
#   ./stream_video.sh <receiver_ip> [video] [pcp]
#
# Receiver (2nd Pi, tablet, or this PC):
#   ffplay -fflags nobuffer -flags low_delay udp://@:5000
set -euo pipefail

DST="${1:?usage: stream_video.sh <receiver_ip> [video] [pcp]}"
VIDEO="${2:-$HOME/media/Big_Buck_Bunny_720_10s_5MB.mp4}"
PCP="${3:-3}"                # protected class; 0 = best effort
PORT=5000
IFACE=eth0
VLAN=100

# If a PCP is requested, egress on a VLAN subinterface that stamps it. The 9662
# then sees VLAN $VLAN / PCP $PCP and applies the class's CBS/TAS. (PCP 0 = plain.)
if [[ "$PCP" != "0" ]]; then
  if ! ip link show "$IFACE.$VLAN" >/dev/null 2>&1; then
    sudo ip link add link "$IFACE" name "$IFACE.$VLAN" type vlan id "$VLAN" \
      egress-qos-map "0:$PCP"
    sudo ip link set "$IFACE.$VLAN" up
  fi
  echo "video -> $DST:$PORT  (VLAN $VLAN, PCP $PCP, protected class)"
else
  echo "video -> $DST:$PORT  (untagged, best effort)"
fi

# -re = real-time pacing; loop so a short clip runs forever for the demo.
exec ffmpeg -hide_banner -loglevel warning -stream_loop -1 -re -i "$VIDEO" \
  -c copy -f mpegts "udp://$DST:$PORT?pkt_size=1316"
