#!/bin/bash
# Removes the Telemic driver and restarts Core Audio. Run with sudo.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo"; exit 1; }
rm -rf /Library/Audio/Plug-Ins/HAL/Telemic.driver
killall coreaudiod
echo "Removed Telemic driver and restarted coreaudiod"
