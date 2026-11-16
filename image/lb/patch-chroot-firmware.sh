#!/bin/bash
# live-build puts every package matching "firmware-*" of the archive into the chroot, and two of them are not firmware
# at all: firmware-b43-installer and firmware-b43legacy-installer download the Broadcom blob from the internet in their
# postinst (github.com, downloads.openwrt.org). A build then depends on those sites: it hangs for as long as wget keeps
# retrying where they are slow or blocked, and the same source tree produces a different image a week later. They are
# taken off the list here. The b43 driver is for Broadcom Wi-Fi cards of roughly 2003-2009; without the blob the kernel
# says the firmware is missing, the rest of the device works, and FIRMWARE=thinclient never had them either.
# Usage: patch-chroot-firmware.sh      (inside the build container, as image/lb/inside.sh does)
set -eu
F=/usr/lib/live/build/chroot_firmware
grep -q '^# Some known licenses required to be accepted$' "$F" || {
  echo "live-build: chroot_firmware changed, check the firmware list"; exit 1; }
grep -q 'OpenThinRDP: no b43 installer' "$F" && exit 0
sed -i 's|^# Some known licenses required to be accepted$|# OpenThinRDP: no b43 installer, they download the firmware in their postinst (image/lb/patch-chroot-firmware.sh)\nsed -i "/^firmware-b43.*installer$/d" chroot/root/packages.chroot\n\n# Some known licenses required to be accepted|' "$F"
grep -q 'OpenThinRDP: no b43 installer' "$F" || { echo "live-build: the b43 patch did not apply"; exit 1; }
echo "live-build: the b43 installers are off the firmware list"
