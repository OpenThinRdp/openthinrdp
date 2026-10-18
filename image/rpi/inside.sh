#!/bin/bash
# Runs inside a privileged debian:trixie container (image/build-rpi.sh): the Raspberry Pi SD card image.
# mmdebstrap installs Debian 13 arm64 into a folder (Debian's kernel and raspi-firmware, as Debian's own Raspberry
# Pi images do), customize.sh adds OpenThinRDP, and the two partitions are made from the folder with mkfs.vfat/mtools
# and mke2fs -d: no loop device, no mount, no installer. The image boots as an installed system.
set -euo pipefail
B=/build; S=$B/site; W=/rpi; R=$W/root
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq --no-install-recommends mmdebstrap arch-test debian-archive-keyring \
  ca-certificates dosfstools mtools e2fsprogs fdisk xz-utils >/dev/null
. "$S/build.conf"
V=$(cat $B/VERSION)
OUTN=openthinrdp-$V-rpi-arm64
rm -rf $W; mkdir -p $W

# the packages of the image: image/lb/packages.list as it reads on arm64 (its "#if ARCHITECTURES" blocks, the
# syntax of live-build), the browser and extra firmware of build.conf. FIRMWARE=all/thinclient is about PCs: the
# Raspberry Pi firmware is in the arm64 block of the list.
pkgs_for(){ awk -v a="$1" '/^#if ARCHITECTURES /{s=1; for(i=3;i<=NF;i++) if($i==a) s=0; next}
  /^#nif ARCHITECTURES /{s=0; for(i=3;i<=NF;i++) if($i==a) s=1; next} /^#endif/{s=0; next}
  /^[[:space:]]*(#|$)/{next} !s{print $1}' "$2"; }
PK="$(pkgs_for arm64 $B/image/lb/packages.list)"
[ "${INCLUDE_BROWSER:-yes}" = no ] || PK="$PK chromium fonts-liberation2 fonts-noto-color-emoji"
PK="$PK ${EXTRA_FIRMWARE:-}"

# no documentation, manuals or translations a thin client never shows: the same dpkg filter as image/lb/inside.sh,
# in place before the first package is unpacked
LANGS="en it ${LOCALE%%_*}"
{ echo "# OpenThinRDP: no documentation, manuals or translations on a thin client (licenses kept)"
  printf 'path-exclude=%s\n' '/usr/share/doc/*' '/usr/share/man/*' '/usr/share/info/*' '/usr/share/help/*' \
    '/usr/share/locale/*' '/usr/lib/chromium/locales/*'
  echo "path-include=/usr/share/doc/*/copyright"; echo "path-include=/usr/share/locale/locale.alias"
  for l in $(echo $LANGS | tr ' ' '\n' | sort -u); do echo "path-include=/usr/share/locale/$l/*"; echo "path-include=/usr/lib/chromium/locales/$l*.pak"; done; } \
  > $W/01-openthinrdp-slim

M=http://deb.debian.org/debian; C="main contrib non-free non-free-firmware"
echo "=== mmdebstrap $(date)"
# --variant=important: what debootstrap (and so live-build) installs by default. No recommended packages, as in
# the ISO (lb config --apt-recommends false): whatever a feature needs is in packages.list.
mmdebstrap --arch=arm64 --variant=important --mode=root --format=directory \
  --aptopt='APT::Install-Recommends "false"' \
  --setup-hook="mkdir -p \"\$1/etc/dpkg/dpkg.cfg.d\" && cp $W/01-openthinrdp-slim \"\$1/etc/dpkg/dpkg.cfg.d/\"" \
  --include="$(echo $PK | tr ' ' ',')" \
  --customize-hook="bash $B/image/rpi/customize.sh \"\$1\"" \
  trixie $R "deb $M trixie $C" "deb $M trixie-updates $C" "deb http://security.debian.org/debian-security trixie-security $C" \
  "deb $M trixie-backports $C"

echo "=== partitions $(date)"
# 1) RASPIFIRM, FAT32: what the Raspberry Pi firmware reads (start4.elf, config.txt, cmdline.txt, the device trees,
#    the kernel and the initramfs, copied there by raspi-firmware). 512 MB: room for two kernels during an update.
# 2) RASPIROOT, ext4: the system. Just larger than its content; the first boot grows it to the whole SD card
#    (openthinrdp-growroot). The labels are those of Debian's own Raspberry Pi images.
FW_MB=512
mv $R/boot/firmware $W/firmware; mkdir -m755 $R/boot/firmware
mkfs.vfat -F 32 -n RASPIFIRM -C $W/firmware.img $((FW_MB * 1024)) >/dev/null
mcopy -s -i $W/firmware.img $W/firmware/* ::/
USED=$(du -sm $R | cut -f1); ROOT_MB=$(( USED * 115 / 100 + 400 ))
mke2fs -q -t ext4 -L RASPIROOT -i 8192 -d $R $W/root.img ${ROOT_MB}M
IMG=$W/$OUTN.img
truncate -s $(( 4 + FW_MB + ROOT_MB ))M $IMG
# MBR (what the boot ROM of the Pi 3/4 reads), partitions aligned to 4 MB (SD card erase blocks)
sfdisk -q $IMG <<EOF
label: dos
unit: sectors
start=8192, size=$((FW_MB * 2048)), type=c, bootable
start=$((8192 + FW_MB * 2048)), size=$((ROOT_MB * 2048)), type=83
EOF
dd if=$W/firmware.img of=$IMG bs=1M seek=4 conv=notrunc,sparse status=none
dd if=$W/root.img of=$IMG bs=1M seek=$((4 + FW_MB)) conv=notrunc,sparse status=none
rm -f $W/firmware.img $W/root.img
echo "=== xz $(date)"
xz -T2 -6 -f $IMG
mv $IMG.xz /out/; cd /out && sha256sum $OUTN.img.xz > $OUTN.img.xz.sha256
# the package list of the image, for the release notes and to compare with the ISO
chroot $R dpkg-query -W -f '${Package} ${Version}\n' > /out/$OUTN.packages 2>/dev/null || true
ls -l /out/$OUTN.*
echo "=== done $(date): $(( USED )) MB of system, image $(( 4 + FW_MB + ROOT_MB )) MB before compression"
