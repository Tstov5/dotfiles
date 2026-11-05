#!/usr/bin/env bash
set -euo pipefail

if bluetoothctl show 2>/dev/null | grep -q "Powered: yes"; then
    bluetoothctl power off
    msg="Bluetooth off"
else
    bluetoothctl power on
    msg="Bluetooth on"
fi

command -v notify-send &>/dev/null && notify-send -t 2000 "$msg" || true
