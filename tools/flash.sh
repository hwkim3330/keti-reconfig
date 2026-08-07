#!/bin/sh
# Build and flash one board.
#
#   tools/flash.sh switch /dev/ttyACM3
#   tools/flash.sh path   /dev/ttyACM1
#
# The two roles need different board options -- the controller carries 16MB flash with octal
# PSRAM, the SuperMini 4MB with quad -- and getting them crossed produces a board that flashes
# and then behaves strangely rather than one that fails loudly. Hence a script rather than a
# line in the README to copy.
set -eu

ROLE=${1:-}
PORT=${2:-}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

SWITCH_FQBN='esp32:esp32:esp32s3:FlashSize=16M,PSRAM=opi,CDCOnBoot=cdc'
PATH_FQBN='esp32:esp32:esp32s3:FlashSize=4M,PSRAM=enabled,CDCOnBoot=cdc'

case "$ROLE" in
  switch) FQBN=$SWITCH_FQBN; SKETCH=$ROOT/firmware/switch_controller ;;
  path)   FQBN=$PATH_FQBN;   SKETCH=$ROOT/firmware/path_module ;;
  *) echo "usage: $0 <switch|path> [port]" >&2; exit 2 ;;
esac

if [ -z "$PORT" ]; then
  echo "ports that look like an ESP32-S3:"
  for p in /dev/ttyACM*; do
    [ -e "$p" ] || continue
    id=$(udevadm info -q property -n "$p" 2>/dev/null | grep -E '^ID_SERIAL_SHORT=' || true)
    model=$(udevadm info -q property -n "$p" 2>/dev/null | grep -E '^ID_MODEL=' || true)
    case "$model" in *JTAG*) echo "  $p  ${id#ID_SERIAL_SHORT=}" ;; esac
  done
  echo "re-run with the port you want"
  exit 1
fi

echo "building $ROLE for $PORT"
arduino-cli compile --fqbn "$FQBN" "$SKETCH"
arduino-cli upload -p "$PORT" --fqbn "$FQBN" "$SKETCH"
echo "done. the board announces itself over serial and by its BLE name."
