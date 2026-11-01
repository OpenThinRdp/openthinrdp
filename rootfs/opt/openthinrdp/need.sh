#!/bin/bash
# Parts installed only where they are used (0.3.1): the image stays small, a device gets them from Debian the first
# time a feature needs them (Internet needed then). On a live stick with its settings partition they stay on the
# stick; without one they come back at every start. Runs as root (sudo from the kiosk for chromium and bluetooth):
#   need.sh <part>          installs what is missing; 0 = all there, 1 = could not install (no Internet...)
#   need.sh <part> check    0 when it is all there, nothing installed
# Parts: chromium (web button, kiosk page), bluetooth (bt.sh), smartcard (a reader plugged in, udev),
#        wireguard, openvpn (vpn.sh)
. /opt/openthinrdp/lib/common.sh
case "$1" in
  chromium)  P="chromium fonts-liberation2 fonts-noto-color-emoji" ;;
  bluetooth) P="bluez libspa-0.2-bluetooth" ;;
  smartcard) P="pcscd libccid opensc pcsc-tools" ;;
  wireguard) P="wireguard-tools" ;;
  openvpn)   P="openvpn" ;;
  *) echo "usage: need.sh chromium|bluetooth|smartcard|wireguard|openvpn [check]" >&2; exit 2 ;;
esac
M=$(for p in $P; do dpkg -s "$p" >/dev/null 2>&1 || echo "$p"; done | tr '\n' ' ')
[ -z "${M// }" ] && exit 0
[ "$2" = check ] && exit 1
exec 9>/run/openthinrdp-need.lock; flock -w 900 9 || exit 1
echo "$1: installing" > "/run/openthinrdp-need-$1"; chmod 644 "/run/openthinrdp-need-$1"
ev "installing $1 (first use): $M"
# the package lists: a device installed offline, or a live system, may have none (or old ones)
apt-get -o DPkg::Lock::Timeout=300 update -q >/dev/null 2>&1
if DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y -q --no-install-recommends $M >/dev/null 2>&1; then
  rm -f "/run/openthinrdp-need-$1"; ev "$1 installed"; exit 0
fi
echo "$1: failed" > "/run/openthinrdp-need-$1"; ev "$1 could not be installed (no Internet?): $M"; exit 1
