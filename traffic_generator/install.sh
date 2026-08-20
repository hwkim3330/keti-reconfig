#!/usr/bin/env bash
# Install pi-trafgen on a Raspberry Pi (Pi 4B recommended). Run as root on the Pi:
#   sudo ./install.sh            # server only
#   sudo ./install.sh --kiosk    # also enable the 7" LCD kiosk browser
set -euo pipefail

KIOSK=0
BLE=0
for a in "$@"; do
  [[ "$a" == "--kiosk" ]] && KIOSK=1
  [[ "$a" == "--ble" ]] && BLE=1
done

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
cp "$SRC/kiosk/launch-kiosk.sh" "$DEST/"
chmod +x "$DEST/launch-kiosk.sh"
python3 -m venv "$DEST/venv"
"$DEST/venv/bin/pip" install --quiet --upgrade pip
"$DEST/venv/bin/pip" install --quiet -r "$SRC/requirements.txt"

# 4. config dir
mkdir -p /etc/pi-trafgen

# 5. server service (always) - starts on boot as root
cp "$SRC/systemd/pi-trafgen.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now pi-trafgen.service

# 5b. BLE peripheral (optional) - lets the tablet start/stop over Bluetooth.
#     Uses the SYSTEM python + bluezero (needs the apt dbus/gi bindings), so it
#     is installed outside the venv.
if [[ $BLE -eq 1 ]]; then
  apt-get install -y python3-dbus python3-gi >/dev/null 2>&1 || true
  # bluezero isn't packaged on bookworm; pip into the system env.
  python3 -c "import bluezero" 2>/dev/null || \
    pip3 install --break-system-packages --quiet bluezero 2>/dev/null || \
    pip3 install --quiet bluezero || true
  # the peripheral imports server.ble_gatt, so ship the code where WorkingDirectory points
  cp -r "$SRC/server" "$DEST/"
  cp "$SRC/systemd/pi-trafgen-ble.service" /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable --now pi-trafgen-ble.service
  echo "BLE peripheral enabled - advertises as KETI-TRAFGEN"
fi

# 6. kiosk (optional) - the Pi's own panel.
#    Raspberry Pi OS bookworm runs a Wayland desktop, so the browser is launched
#    from the user's graphical session via XDG autostart, NOT a root systemd unit.
if [[ $KIOSK -eq 1 ]]; then
  apt-get install -y chromium-browser >/dev/null 2>&1 || apt-get install -y chromium >/dev/null 2>&1 || true
  # install for the user who owns the desktop session (the one who ran sudo)
  DESK_USER="${SUDO_USER:-$(logname 2>/dev/null || echo pi)}"
  DESK_HOME=$(getent passwd "$DESK_USER" | cut -d: -f6)
  install -d -o "$DESK_USER" -g "$DESK_USER" "$DESK_HOME/.config/autostart" "$DESK_HOME/Desktop"
  install -m 644 -o "$DESK_USER" -g "$DESK_USER" \
    "$SRC/kiosk/pi-trafgen-kiosk.desktop" "$DESK_HOME/.config/autostart/pi-trafgen-kiosk.desktop"
  install -m 755 -o "$DESK_USER" -g "$DESK_USER" \
    "$SRC/kiosk/pi-trafgen.desktop" "$DESK_HOME/Desktop/pi-trafgen.desktop"
  # newer file managers want the launcher marked trusted before double-click works
  sudo -u "$DESK_USER" gio set "$DESK_HOME/Desktop/pi-trafgen.desktop" \
    metadata::trusted true 2>/dev/null || true
  echo "kiosk enabled for user '$DESK_USER' - opens on next boot/login,"
  echo "and there is a 'Traffic Generator' icon on the desktop to reopen it."
fi

IP=$(hostname -I | awk '{print $1}')
echo
echo "==> done. UI at http://${IP}:8080/  (also http://$(hostname).local:8080/)"
echo "    tablet app: point it at ${IP}:8080"
systemctl --no-pager status pi-trafgen.service | head -5 || true
