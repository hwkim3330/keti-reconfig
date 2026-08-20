#!/usr/bin/env bash
# Install pi-trafgen on a Raspberry Pi (Pi 4B recommended). Run as root on the Pi:
#   sudo ./install.sh            # server only
#   sudo ./install.sh --kiosk    # also enable the 7" LCD kiosk browser
set -euo pipefail

KIOSK=0
[[ "${1:-}" == "--kiosk" ]] && KIOSK=1

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST=/opt/pi-trafgen

echo "==> pi-trafgen install (kiosk=$KIOSK)"

if [[ $EUID -ne 0 ]]; then
  echo "run as root (sudo ./install.sh)"; exit 1
fi

# 1. pktgen availability - the whole thing is pointless without it.
if ! modprobe pktgen 2>/dev/null; then
  echo "!! this kernel has no pktgen module."
  echo "   Raspberry Pi OS often ships without CONFIG_NET_PKTGEN."
  echo "   Ubuntu Server 24.04 arm64 has it - reflash to that, or rebuild the kernel."
  exit 1
fi
echo "pktgen: $([ -d /proc/net/pktgen ] && echo present || echo MISSING)"
# make it persist across reboots
echo pktgen > /etc/modules-load.d/pktgen.conf

# 2. deps
apt-get update -qq
apt-get install -y python3-venv python3-pip curl >/dev/null
[[ $KIOSK -eq 1 ]] && apt-get install -y chromium-browser >/dev/null || true

# 3. copy code
mkdir -p "$DEST"
cp -r "$SRC/server" "$SRC/web" "$DEST/"
python3 -m venv "$DEST/venv"
"$DEST/venv/bin/pip" install --quiet --upgrade pip
"$DEST/venv/bin/pip" install --quiet -r "$SRC/requirements.txt"

# 4. config dir
mkdir -p /etc/pi-trafgen

# 5. services
cp "$SRC/systemd/pi-trafgen.service" /etc/systemd/system/
[[ $KIOSK -eq 1 ]] && cp "$SRC/systemd/pi-trafgen-kiosk.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now pi-trafgen.service
if [[ $KIOSK -eq 1 ]]; then
  systemctl enable pi-trafgen-kiosk.service
  echo "kiosk enabled - starts with the graphical session"
fi

IP=$(hostname -I | awk '{print $1}')
echo
echo "==> done. UI at http://${IP}:8080/  (also http://$(hostname).local:8080/)"
echo "    tablet app: point it at ${IP}:8080"
systemctl --no-pager status pi-trafgen.service | head -5 || true
