#!/bin/bash
# Removes the RemoteMic driver and restarts Core Audio. Run with sudo.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo"; exit 1; }
rm -rf /Library/Audio/Plug-Ins/HAL/RemoteMic.driver
killall coreaudiod
echo "Removed RemoteMic driver and restarted coreaudiod"
