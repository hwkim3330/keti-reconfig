#!/usr/bin/env bash
# Deploy the whole traffic_generator to a Pi in one shot, so a partial/flaky copy
# can never leave the service importing a file that isn't there (that crash-looped
# Pi1 when video.py was missing). Copies the ENTIRE server/ and web/ trees, the
# kiosk launcher and systemd units, then restarts.
#
#   ./deploy.sh <host> [password]
#   ./deploy.sh 192.168.6.2 keti
#   ./deploy.sh 172.31.51.228            # password from $SSHPASS or prompt
set -euo pipefail

HOST="${1:?usage: deploy.sh <host> [password]}"
PASS="${2:-${SSHPASS:-keti}}"
USER="${DEPLOY_USER:-keti}"
SRC="$(cd -- "$(dirname -- "$0")" && pwd)"
DST="/home/${USER}/keti-reconfig/traffic_generator"

export SSHPASS="$PASS"
SSH="sshpass -e ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no ${USER}@${HOST}"
SCP="sshpass -e scp -o StrictHostKeyChecking=no -o PreferredAuthentications=password -o PubkeyAuthentication=no -r"

echo "==> staging whole tree to ${HOST}"
$SSH "mkdir -p ${DST}"
# -r whole dirs: all-or-nothing per dir, no per-file omissions
$SCP "$SRC/server" "$SRC/web" "$SRC/kiosk" "$SRC/systemd" "${USER}@${HOST}:${DST}/"

echo "==> installing to /opt/pi-trafgen and restarting (sudo)"
# -S so it works whether or not sudo is NOPASSWD on this Pi
$SSH "echo '${PASS}' | sudo -S bash -c '
  cp -r ${DST}/server/* /opt/pi-trafgen/server/ &&
  cp -r ${DST}/web/*    /opt/pi-trafgen/web/ &&
  cp ${DST}/kiosk/launch-kiosk.sh /opt/pi-trafgen/launch-kiosk.sh &&
  chmod +x /opt/pi-trafgen/launch-kiosk.sh &&
  systemctl restart pi-trafgen &&
  sleep 3 &&
  systemctl is-active pi-trafgen'"

echo "==> verify"
$SSH "curl -sf -m4 localhost:8080/api/system >/dev/null && echo '  API OK' || echo '  API DOWN'"
echo "done. Reboot the Pi if you changed the kiosk UI (clears the browser cache)."
