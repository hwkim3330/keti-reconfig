#!/usr/bin/env bash
# Software traffic-class demo with tc: put the VIDEO in a low class and the
# INTERFERING FLOOD in a high class, on a shared bottleneck. Under contention the
# high-priority flood is served first and starves the low-priority video, so the
# picture stutters. 'protect' instead gives the video class a *guaranteed* rate,
# so it survives the flood - the same idea TSN/CBS (802.1Qav) enforces in the
# 9662 hardware, done here in Linux software as a rehearsal.
#
#   ./tsn_tc.sh starve     # video low prio, flood high prio  -> video stutters
#   ./tsn_tc.sh protect    # video gets a reserved slice       -> video smooth
#   ./tsn_tc.sh clear      # remove all shaping
#
# IMPORTANT: pktgen injects below the qdisc and bypasses tc, so the flood for
# THIS demo must be ordinary socket traffic (iperf3 / a UDP blaster) on
# $FLOOD_PORT. The video is the MPEG-TS stream on $VIDEO_PORT (see stream_video.sh).
set -euo pipefail

IFACE=${IFACE:-eth0}
RATE=${RATE:-100mbit}          # artificial bottleneck so contention exists on a fast link
VIDEO_PORT=${VIDEO_PORT:-5000}
FLOOD_PORT=${FLOOD_PORT:-9999}
GUARANTEE=${GUARANTEE:-15mbit} # reserved video rate in 'protect' mode
MODE=${1:-starve}

TC=$(command -v tc || echo /sbin/tc)
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

$SUDO $TC qdisc del dev "$IFACE" root 2>/dev/null || true
if [ "$MODE" = clear ]; then echo "tc cleared on $IFACE"; exit 0; fi

# htb bottleneck. In htb a class is guaranteed its 'rate' before any class may
# borrow spare up to 'ceil'. So the *reservation* is what protects a flow - which
# is exactly what CBS (802.1Qav) does in hardware. We hand the reservation to the
# flood (starve) or to the video (protect) to flip the outcome.
$SUDO $TC qdisc add dev "$IFACE" root handle 1: htb default 30
$SUDO $TC class add dev "$IFACE" parent 1:  classid 1:1  htb rate "$RATE" ceil "$RATE"
if [ "$MODE" = protect ]; then
  # video: reserved $GUARANTEE (served first) -> smooth even under the flood
  $SUDO $TC class add dev "$IFACE" parent 1:1 classid 1:20 htb rate "$GUARANTEE" ceil "$RATE" prio 0
  # flood: no reservation, only leftovers
  $SUDO $TC class add dev "$IFACE" parent 1:1 classid 1:10 htb rate 8kbit ceil "$RATE" prio 7
  DESC="protected (video reserved $GUARANTEE, flood gets leftovers)"
else
  # flood: reserves the WHOLE bottleneck -> nothing left for the video
  $SUDO $TC class add dev "$IFACE" parent 1:1 classid 1:10 htb rate "$RATE" ceil "$RATE" prio 0
  # video: no reservation, can only use what the flood leaves (nothing) -> starved
  $SUDO $TC class add dev "$IFACE" parent 1:1 classid 1:20 htb rate 8kbit ceil "$RATE" prio 7
  DESC="starved (flood reserves the whole link, video gets nothing)"
fi
# everything else (SSH, control) - small reservation so we never lock ourselves out
$SUDO $TC class add dev "$IFACE" parent 1:1 classid 1:30 htb rate 3mbit ceil "$RATE" prio 1

# classify UDP by destination port
$SUDO $TC filter add dev "$IFACE" protocol ip parent 1: prio 1 u32 \
  match ip protocol 17 0xff match ip dport "$FLOOD_PORT" 0xffff flowid 1:10
$SUDO $TC filter add dev "$IFACE" protocol ip parent 1: prio 1 u32 \
  match ip protocol 17 0xff match ip dport "$VIDEO_PORT" 0xffff flowid 1:20

echo "tc $MODE on $IFACE ($DESC):"
echo "  video  udp:$VIDEO_PORT -> class 1:20"
echo "  flood  udp:$FLOOD_PORT -> class 1:10"
echo "  bottleneck $RATE. inspect: tc -s class show dev $IFACE"
