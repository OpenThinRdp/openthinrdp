#!/bin/bash
# Runs inside a debian:trixie container (build.sh): assembles the live-build configuration and builds the ISO.
set -euo pipefail
B=/build; S=$B/site
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq live-build >/dev/null
. "$S/build.conf"
V=$(cat $B/VERSION)
get(){ sed -n "s/^$1=//p" "$S/site.conf" "$B/rootfs/opt/openthinrdp/defaults.conf" 2>/dev/null | grep -v '^$' | head -1; }
# #rrggbb -> "r, g, b" between 0 and 1, as Plymouth wants it
rgb(){ local h=${1#\#}
       awk -v h="$h" 'BEGIN{ for(i=0;i<3;i++){ x=substr(h,i*2+1,2); v=0; for(j=1;j<=2;j++){ c=index("0123456789abcdef", tolower(substr(x,j,1)))-1; v=v*16+c }; printf "%s%.3f", (i?", ":""), v/255 } }'; }
mkdir -p /lb && cd /lb
# an array, not $( ... ): the install options contain spaces and must reach lb config as ONE argument,
# otherwise the installer starts without the preseed and stops at the first question
CFG=(--distribution trixie --architectures amd64
  --archive-areas "main contrib non-free non-free-firmware" --backports true
  --debian-installer live --debian-installer-gui false --memtest none --loadlin false --win32-loader false
  # GRUB for both firmware types: PCs with a legacy BIOS (old thin clients) get the same menu as UEFI ones (our
  # entries, the 10 s timeout), not isolinux with Debian's
  --bootloaders "grub-pc,grub-efi"
  # FIRMWARE=all: every firmware package, so the image runs on any PC (the downloadable ISO);
  # FIRMWARE=thinclient: only the set in packages.list, ~600 MB less. The installer copy of the firmware is
  # never needed: the installation is offline. No recommended packages, fast compression.
  --firmware-chroot "$([ "${FIRMWARE:-all}" = thinclient ] && echo false || echo true)" --firmware-binary false --apt-recommends false
  --apt-indices false
  --chroot-squashfs-compression-type zstd --chroot-squashfs-compression-level 15
  --iso-volume "OpenThinRDP $V" --iso-application OpenThinRDP --image-name openthinrdp
  --bootappend-live "boot=live components quiet splash loglevel=3 systemd.show_status=false username=kiosk hostname=thinclient vt.global_cursor_default=0")
if [ "${AUTO_INSTALL:-yes}" = yes ]; then
  L=${LOCALE%%.*}
  CFG+=(--bootappend-install "auto=true priority=critical preseed/file=/cdrom/install/preseed.cfg language=${L%%_*} country=${L#*_} locale=$LOCALE keymap=$KEYBOARD")
fi
lb config "${CFG[@]}"
C=config/includes.chroot
mkdir -p config/package-lists config/hooks/normal config/packages.chroot config/includes.binary/install \
  $C/etc/openthinrdp/ca $C/opt/openthinrdp/branding $C/usr/share/plymouth/themes/openthinrdp
cp $B/image/lb/packages.list config/package-lists/openthinrdp.list.chroot
# optional parts (build.conf): Chromium for the web button, extra firmware
{ [ "${INCLUDE_BROWSER:-yes}" = no ] || printf 'chromium\nfonts-liberation2\nfonts-noto-color-emoji\n'
  for f in ${EXTRA_FIRMWARE:-}; do echo "$f"; done; } > config/package-lists/openthinrdp-site.list.chroot
# no documentation, manuals or translations a thin client never shows (licenses and the build languages
# kept). In place before the packages are installed, and kept in the system for later updates.
LANGS="en it ${LOCALE%%_*}"
mkdir -p config/includes.chroot_before_packages/etc/dpkg/dpkg.cfg.d $C/etc/dpkg/dpkg.cfg.d
{ echo "# OpenThinRDP: no documentation, manuals or translations on a thin client (licenses kept)"
  # quoted: these are dpkg patterns, the shell must not expand them against the build container
  printf 'path-exclude=%s\n' '/usr/share/doc/*' '/usr/share/man/*' '/usr/share/info/*' '/usr/share/help/*' \
    '/usr/share/locale/*' '/usr/lib/chromium/locales/*'
  echo "path-include=/usr/share/doc/*/copyright"; echo "path-include=/usr/share/locale/locale.alias"
  for l in $(echo $LANGS | tr ' ' '\n' | sort -u); do echo "path-include=/usr/share/locale/$l/*"; echo "path-include=/usr/lib/chromium/locales/$l*.pak"; done; } \
  > config/includes.chroot_before_packages/etc/dpkg/dpkg.cfg.d/01-openthinrdp-slim
cp config/includes.chroot_before_packages/etc/dpkg/dpkg.cfg.d/01-openthinrdp-slim $C/etc/dpkg/dpkg.cfg.d/
cp -a $B/rootfs/. $C/
echo "$V" > $C/opt/openthinrdp/VERSION
# site: settings, branding, certificates, credentials, keys, packages
[ -f $S/site.conf ] && cp $S/site.conf $C/etc/openthinrdp/site.conf
for f in logo splash; do if [ -f $S/$f.png ]; then cp $S/$f.png $C/opt/openthinrdp/branding/; else cp $B/image/branding/$f.png $C/opt/openthinrdp/branding/; fi; done
cp $C/opt/openthinrdp/branding/splash.png $C/usr/share/plymouth/themes/openthinrdp/logo.png
cp $B/image/lb/plymouth/openthinrdp.plymouth $C/usr/share/plymouth/themes/openthinrdp/
sed -e "s/@TOP@/$(rgb "$(get BG_TOP)")/" -e "s/@BOTTOM@/$(rgb "$(get BG_BOTTOM)")/" $B/image/lb/plymouth/openthinrdp.script > $C/usr/share/plymouth/themes/openthinrdp/openthinrdp.script
# boot menu of the ISO: our menu files over live-build's templates (live system first, starting by itself), and a
# background with the splash on the site colors instead of the Debian one (live-build renders config/bootloaders/
# splash.svg for GRUB and isolinux)
mkdir -p config/bootloaders
cp -a $B/image/lb/bootloaders/grub-pc config/bootloaders/
SPL=$C/opt/openthinrdp/branding/splash.png
SW=$(od -An -tu1 -j16 -N4 "$SPL" | awk '{print $1*16777216 + $2*65536 + $3*256 + $4}')
SH=$(od -An -tu1 -j20 -N4 "$SPL" | awk '{print $1*16777216 + $2*65536 + $3*256 + $4}')
IW=440; IH=$(( SH * IW / SW ))
{ printf '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="800" height="600" viewBox="0 0 800 600">\n'
  printf '<defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="%s"/><stop offset="1" stop-color="%s"/></linearGradient></defs>\n' "$(get BG_TOP)" "$(get BG_BOTTOM)"
  printf '<rect width="800" height="600" fill="url(#g)"/>\n'
  printf '<image x="%d" y="%d" width="%d" height="%d" xlink:href="data:image/png;base64,%s"/>\n</svg>\n' $(( (800 - IW) / 2 )) $(( (330 - IH) / 2 )) $IW $IH "$(base64 -w0 "$SPL")"
} > config/bootloaders/splash.svg
cp $S/ca/*.crt $C/etc/openthinrdp/ca/ 2>/dev/null || true
for f in smb.cred update-key.asc authorized_keys; do [ -f $S/$f ] && cp $S/$f $C/etc/openthinrdp/; done
cp $S/debs/*.deb config/packages.chroot/ 2>/dev/null || true
# FreeRDP with UDP (build.sh fetched or built it); the debug symbols in debug/ stay out of the image
if [ "$FREERDP_FROM" = openthinrdp ]; then
  . $B/image/freerdp/freerdp.conf
  cp /out/freerdp/$FREERDP_COMMIT/*.deb config/packages.chroot/
  echo freerdp3-x11 >> config/package-lists/openthinrdp-site.list.chroot
fi
printf 'LOCALE=%s\nTIMEZONE=%s\nKEYBOARD=%s\nFREERDP_FROM=%s\nADMIN_PASSWORD_HASH=%s\n' "$LOCALE" "$TIMEZONE" "$KEYBOARD" "$FREERDP_FROM" "${ADMIN_PASSWORD_HASH:-}" > $C/etc/openthinrdp/build.env
cp $B/image/lb/hook.chroot config/hooks/normal/0100-openthinrdp.hook.chroot
sed -e "s|@LOCALE@|$LOCALE|" -e "s|@KEYBOARD@|$KEYBOARD|" -e "s|@TIMEZONE@|$TIMEZONE|" -e "s|@ADMIN_HASH@|${ADMIN_PASSWORD_HASH:-!}|" \
  $B/image/lb/preseed.cfg.in > config/includes.binary/install/preseed.cfg
chmod +x config/hooks/normal/*.hook.chroot
echo "=== lb build $(date)"
lb build
cp live-image-amd64.hybrid.iso /out/openthinrdp-$V.iso 2>/dev/null || cp openthinrdp*.iso /out/openthinrdp-$V.iso
cd /out && sha256sum openthinrdp-$V.iso > openthinrdp-$V.iso.sha256 && ls -lh
