#!/usr/bin/env bash
# Open the pi-trafgen UI full-screen on the Pi's own panel.
#
# Works under the Raspberry Pi OS bookworm desktop whether the session is
# Wayland (labwc / wayfire, the default) or X11 - Chromium picks the platform
# with --ozone-platform-hint=auto. The panel here is 720x1280 portrait; the UI
# is laid out portrait-first, so no rotation is needed.
set -u

# Role of this panel, if any: /etc/pi-trafgen/view = "tx" (sender: transmit graph)
# or "video" (receiver: protected video). Empty -> full tabbed UI.
VIEW="$(cat /etc/pi-trafgen/view 2>/dev/null | tr -dc 'a-z')"

# The video role does NOT use the browser: high-bitrate video is played by a
# native hardware-decoding player (mpv/GStreamer) so it isn't capped by the
# ~20 Mbps Python-relay + MSE path. Hand off and never launch Chromium here.
if [ "$VIEW" = "video" ]; then
  HERE="$(dirname "$(readlink -f "$0")")"
  exec "$HERE/video-player.sh"
fi

URL="http://localhost:8080/"
[ -n "$VIEW" ] && URL="http://localhost:8080/?view=$VIEW"

# The systemd service may still be coming up when the desktop autostarts us.
for _ in $(seq 1 60); do
  curl -sf "http://localhost:8080/api/system" >/dev/null 2>&1 && break
  sleep 1
done

# Don't stack a second window if this launcher fires twice.
pkill -f "pi-trafgen-kiosk-profile" 2>/dev/null
sleep 1

# Drop any cached HTML/JS/CSS so a UI update is always picked up on boot.
rm -rf "$HOME/.config/pi-trafgen-kiosk-profile/Default/Cache" \
       "$HOME/.config/pi-trafgen-kiosk-profile/Default/Code Cache" \
       "$HOME/.config/pi-trafgen-kiosk-profile/GrShaderCache" 2>/dev/null

BIN=chromium-browser
command -v "$BIN" >/dev/null 2>&1 || BIN=chromium

# Prefer the Wayland backend when we're in a Wayland session (labwc/wayfire on
# bookworm); otherwise let Chromium auto-detect (X11).
PLATFORM=(--ozone-platform-hint=auto)
[ -n "${WAYLAND_DISPLAY:-}" ] && PLATFORM=(--ozone-platform=wayland)

exec "$BIN" \
  --kiosk \
  --app="$URL" \
  --user-data-dir="$HOME/.config/pi-trafgen-kiosk-profile" \
  "${PLATFORM[@]}" \
  --password-store=basic \
  --disk-cache-size=1 \
  --noerrdialogs \
  --disable-infobars \
  --disable-session-crashed-bubble \
  --disable-features=TranslateUI,Translate \
  --check-for-update-interval=31536000 \
  --overscroll-history-navigation=0
