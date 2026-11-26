#!/bin/bash
# Installs the RemoteMic driver and restarts Core Audio (no reboot needed).
# Run with sudo. Audio drops for a second or two while coreaudiod restarts.
set -euo pipefail
cd "$(dirname "$0")"

[ -d build/RemoteMic.driver ] || { echo "Run ./build.sh first"; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo"; exit 1; }

DEST=/Library/Audio/Plug-Ins/HAL/RemoteMic.driver
rm -rf "$DEST"
cp -R build/RemoteMic.driver "$DEST"
chown -R root:wheel "$DEST"
killall coreaudiod
echo "Installed $DEST and restarted coreaudiod"
