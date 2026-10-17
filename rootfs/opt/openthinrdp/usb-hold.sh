#!/bin/bash
# The USB devices that go to Windows whole wait until the remote desktop is up (kiosk.sh, as root through sudo).
#   hold VID:PID...   the hub port of every connected USB device with one of these ids is switched off (the device
#                     is gone, as if unplugged) until "release", or by itself after 2 minutes whatever happens
#   release           those ports back on: the devices are found again as just plugged in, with the desktop
#                     running, and FreeRDP (/usb:auto) passes them to Windows
# Why: Windows starts the redirected devices and the display of the session together. A device that hangs while
# Windows starts it holds Plug and Play for 60 s, the display driver of the session cannot report ready, and
# Windows closes the session (reason 15, "driver not ready"; FreeRDP #13719). Arriving after the desktop, a
# device that hangs fails on its own, as on a physical PC.
# The port, not the device: a device only deauthorized (authorized=0) is still listed by libusb, FreeRDP takes it
# without a configuration and Windows gets a broken device; given back it raises no "plugged in" event.
. /opt/openthinrdp/lib/common.sh
H=/run/openthinrdp-usb-held
release(){ local p
  for p in $(sort -u "$H" 2>/dev/null); do
    [[ $p =~ ^/sys/devices/[A-Za-z0-9:./_-]+-port[0-9]+$ ]] && [[ $p != *..* ]] && [ -f "$p/disable" ] && echo 0 > "$p/disable"
  done
  rm -f "$H"; }
case "$1" in
  hold)
    shift
    for id in "$@"; do [[ $id =~ ^[0-9a-f]{4}:[0-9a-f]{4}$ ]] || { echo "not a VID:PID: $id" >&2; exit 2; }; done
    release   # anything still held from a previous connection
    systemctl stop openthinrdp-usb-release.timer >/dev/null 2>&1
    . "$OTR/lib/usb.sh"; SYS=" $(usb_system_ids | tr '\n' ' ') "
    for d in /sys/bus/usb/devices/[0-9]*-[0-9]*; do
      n=${d##*/}; [[ $n =~ ^[0-9]+-[0-9.]+$ ]] && [ -f "$d/idVendor" ] || continue
      [ "$(cat "$d/bDeviceClass" 2>/dev/null)" = 09 ] && continue          # never a hub
      [[ $SYS == *" $(cat "$d/idVendor"):$(cat "$d/idProduct") "* ]] && continue   # never the disk of the system
      [[ " $* " == *" $(cat "$d/idVendor"):$(cat "$d/idProduct") "* ]] || continue
      p=$(readlink -f "$d/port") && [ -f "$p/disable" ] || continue
      echo 1 > "$p/disable" && echo "$p" >> "$H"
    done
    [ -s "$H" ] && systemd-run --on-active=120 --unit=openthinrdp-usb-release --collect "$0" release >/dev/null 2>&1
    exit 0 ;;
  release)
    release; systemctl stop openthinrdp-usb-release.timer >/dev/null 2>&1; exit 0 ;;
  *) echo "usage: $0 hold VID:PID... | release" >&2; exit 2 ;;
esac
