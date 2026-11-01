#!/bin/bash
# Bluetooth (0.3.0): headsets, keyboards, mice paired from the device (the Bluetooth page of the settings, ui.py bt;
# sudo from the kiosk). Runs as root:
#   bt.sh scan         the devices around after 8 s of scanning, one per line: MAC<TAB>name<TAB>1 when paired
#   bt.sh pair MAC     paired, trusted (it comes back by itself at every start) and connected
#   bt.sh remove MAC   forgotten
# A device that asks for a code typed on it (some keyboards) cannot be paired from here: no agent shows it.
. /opt/openthinrdp/lib/common.sh
ls /sys/class/bluetooth/hci* >/dev/null 2>&1 || exit 3
# not in the image (0.3.1): installed the first time this page is used; the audio of the session restarted so that it
# sees the Bluetooth part of PipeWire (headsets)
if ! command -v bluetoothctl >/dev/null; then
  "$OTR/need.sh" bluetooth || exit 4
  u=$(id -u "$OTR_KIOSK_USER" 2>/dev/null) && runuser -u "$OTR_KIOSK_USER" -- env XDG_RUNTIME_DIR="/run/user/$u" \
    systemctl --user restart wireplumber >/dev/null 2>&1
fi
# the image keeps the Bluetooth service off (hook.chroot): started when this page is used, and enabled once a device
# is paired, so that at every start the adapter brings it up and the paired devices come back by themselves
systemctl is-active -q bluetooth || { systemctl start bluetooth 2>/dev/null; sleep 1; }
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
      systemctl enable bluetooth >/dev/null 2>&1
      ev "Bluetooth: $n ($m) paired"; exit 0
    fi
    ev "Bluetooth: pairing $n ($m) failed"; exit 1 ;;
  remove)
    macok "$m" || exit 2
    bluetoothctl remove "$m" >/dev/null 2>&1 && ev "Bluetooth: $m removed"
    # the last paired device gone: the service off again at the next starts
    [ -z "$(bluetoothctl devices Paired 2>/dev/null)" ] && systemctl disable bluetooth >/dev/null 2>&1; exit 0 ;;
  *) echo "usage: bt.sh scan | pair MAC | remove MAC" >&2; exit 2 ;;
esac
