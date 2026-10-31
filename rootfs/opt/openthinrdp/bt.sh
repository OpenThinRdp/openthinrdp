#!/bin/bash
# Bluetooth (0.3.0): headsets, keyboards, mice paired from the device (the Bluetooth page of the settings, ui.py bt;
# sudo from the kiosk). Runs as root:
#   bt.sh scan         the devices around after 8 s of scanning, one per line: MAC<TAB>name<TAB>1 when paired
#   bt.sh pair MAC     paired, trusted (it comes back by itself at every start) and connected
#   bt.sh remove MAC   forgotten
# A device that asks for a code typed on it (some keyboards) cannot be paired from here: no agent shows it.
. /opt/openthinrdp/lib/common.sh
command -v bluetoothctl >/dev/null && ls /sys/class/bluetooth/hci* >/dev/null 2>&1 || exit 3
macok(){ [[ $1 =~ ^([0-9A-F]{2}:){5}[0-9A-F]{2}$ ]]; }
m=$(echo "${2:-}" | tr 'a-f' 'A-F')
case "$1" in
  scan)
    rfkill unblock bluetooth 2>/dev/null; bluetoothctl power on >/dev/null 2>&1
    bluetoothctl --timeout 8 scan on >/dev/null 2>&1
    p=$(bluetoothctl devices Paired 2>/dev/null | awk '{print $2}')
    bluetoothctl devices 2>/dev/null | while read -r _ d n; do
      # a device without a name shows its address with dashes: nothing anybody recognises
      macok "$d" && [ -n "$n" ] && [ "$n" != "${d//:/-}" ] || continue
      printf '%s\t%s\t%s\n' "$d" "$n" "$(grep -qx "$d" <<< "$p" && echo 1 || echo 0)"
    done ;;
  pair)
    macok "$m" || exit 2
    n=$(bluetoothctl info "$m" 2>/dev/null | sed -n 's/^[[:space:]]*Name: //p')
    if bluetoothctl --agent NoInputNoOutput --timeout 25 pair "$m" 2>&1 | grep -qiE 'Pairing successful|AlreadyExists'; then
      bluetoothctl trust "$m" >/dev/null 2>&1; bluetoothctl --timeout 10 connect "$m" >/dev/null 2>&1
      ev "Bluetooth: $n ($m) paired"; exit 0
    fi
    ev "Bluetooth: pairing $n ($m) failed"; exit 1 ;;
  remove)
    macok "$m" || exit 2
    bluetoothctl remove "$m" >/dev/null 2>&1 && ev "Bluetooth: $m removed" ;;
  *) echo "usage: bt.sh scan | pair MAC | remove MAC" >&2; exit 2 ;;
esac
