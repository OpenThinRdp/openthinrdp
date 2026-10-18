#!/bin/bash
# mmdebstrap customize hook of the Raspberry Pi image (image/rpi/inside.sh): OpenThinRDP into the arm64 system in $1,
# the same way image/lb/inside.sh does it for the ISO (rootfs, site, branding, FreeRDP), then the same chroot hook
# (image/lb/hook.chroot: accounts, services, language, boot splash), then what an SD card image needs instead of
# an installer: partitions by label, boot command line, first-boot growth of the root partition.
set -euo pipefail
T=$1; B=/build; S=$B/site
. "$S/build.conf"
V=$(cat $B/VERSION)
get(){ sed -n "s/^$1=//p" "$S/site.conf" "$B/rootfs/opt/openthinrdp/defaults.conf" 2>/dev/null | grep -v '^$' | head -1; }
rgb(){ local h=${1#\#}
       awk -v h="$h" 'BEGIN{ for(i=0;i<3;i++){ x=substr(h,i*2+1,2); v=0; for(j=1;j<=2;j++){ c=index("0123456789abcdef", tolower(substr(x,j,1)))-1; v=v*16+c }; printf "%s%.3f", (i?", ":""), v/255 } }'; }
inch(){ chroot "$T" "$@"; }   # a command inside the new system

# --- OpenThinRDP, site and branding (as image/lb/inside.sh)
# owned by root and with the modes of the system whatever the checkout (as install.sh does on a device; live-build
# copies its includes without the owner): a checkout owned by uid 1000 would give /etc to the kiosk account
R=$(mktemp -d); cp -a $B/rootfs/. "$R/"; chmod -R u=rwX,go=rX "$R"
cp -a --no-preserve=ownership "$R/." "$T/"; rm -rf "$R"
echo "$V" > "$T/opt/openthinrdp/VERSION"
mkdir -p "$T/etc/openthinrdp/ca" "$T/opt/openthinrdp/branding" "$T/usr/share/plymouth/themes/openthinrdp"
[ -f $S/site.conf ] && cp $S/site.conf "$T/etc/openthinrdp/site.conf"
for f in logo splash; do if [ -f $S/$f.png ]; then cp $S/$f.png "$T/opt/openthinrdp/branding/"; else cp $B/image/branding/$f.png "$T/opt/openthinrdp/branding/"; fi; done
cp "$T/opt/openthinrdp/branding/splash.png" "$T/usr/share/plymouth/themes/openthinrdp/logo.png"
cp $B/image/lb/plymouth/openthinrdp.plymouth "$T/usr/share/plymouth/themes/openthinrdp/"
sed -e "s/@TOP@/$(rgb "$(get BG_TOP)")/" -e "s/@BOTTOM@/$(rgb "$(get BG_BOTTOM)")/" $B/image/lb/plymouth/openthinrdp.script > "$T/usr/share/plymouth/themes/openthinrdp/openthinrdp.script"
cp $S/ca/*.crt "$T/etc/openthinrdp/ca/" 2>/dev/null || true
for f in smb.cred update-key.asc authorized_keys; do [ -f $S/$f ] && cp $S/$f "$T/etc/openthinrdp/"; done

# --- packages of the site and FreeRDP: only those built for arm64 or for every architecture
mkdir -p "$T/tmp/otr-debs"
for d in $S/debs/*.deb; do
  [ -f "$d" ] || continue
  case "$(dpkg-deb -f "$d" Architecture)" in arm64|all) cp "$d" "$T/tmp/otr-debs/" ;; *) echo "skipped (not arm64): ${d##*/}" ;; esac
done
if [ "$FREERDP_FROM" = openthinrdp ]; then
  . $B/image/freerdp/freerdp.conf
  cp /out/freerdp/$FREERDP_COMMIT-arm64/*.deb "$T/tmp/otr-debs/"
fi
if ls "$T"/tmp/otr-debs/*.deb >/dev/null 2>&1; then
  inch apt-get install -y -q $(cd "$T" && ls tmp/otr-debs/*.deb | sed 's|^|/|')
fi
rm -rf "$T/tmp/otr-debs"

# --- the Raspberry Pi side, before the chroot hook (its update-initramfs and the raspi-firmware run below read it)
# root and boot partitions by label: the same image boots from an SD card or a USB disk
cat > "$T/etc/fstab" <<'EOF'
# OpenThinRDP on a Raspberry Pi: partitions by label (image/build-rpi.sh)
LABEL=RASPIROOT  /               ext4  rw,noatime,errors=remount-ro  0 1
LABEL=RASPIFIRM  /boot/firmware  vfat  rw,noatime,umask=0022         0 2
EOF
# raspi-firmware writes config.txt and cmdline.txt from these files at every kernel update.
# CMA 256 MB: the display buffers of the Pi 4 come from it (64 MB, the default, is short for a 4K monitor or two
# monitors). Consoles: the serial port first, the screen last (the screen gets the boot messages and the splash).
cat > "$T/etc/default/raspi-firmware" <<'EOF'
# OpenThinRDP (image/rpi/customize.sh); see the comments of the Debian file in raspi-firmware
ROOTPART=LABEL=RASPIROOT
CMA=256M
CONSOLES="ttyS1,115200 tty1"
EOF
# silent boot, as boot.sh makes the GRUB command line of a PC
echo "quiet splash loglevel=3 rd.udev.log_level=3 systemd.show_status=false vt.global_cursor_default=0" > "$T/etc/default/raspi-extra-cmdline"
# config.txt: no rainbow square of the firmware before the kernel starts
printf 'disable_splash=1\n' > "$T/etc/default/raspi-firmware-custom"
echo thinclient > "$T/etc/hostname"
printf '127.0.0.1\tlocalhost\n127.0.1.1\tthinclient\n::1\t\tlocalhost ip6-localhost ip6-loopback\n' > "$T/etc/hosts"
# network: apply.sh writes the adapters at the first boot (as on a PC installed from the ISO)
printf 'source /etc/network/interfaces.d/*\n\nauto lo\niface lo inet loopback\n' > "$T/etc/network/interfaces"
install -m755 $B/image/rpi/openthinrdp-growroot "$T/usr/local/sbin/openthinrdp-growroot"
install -m644 $B/image/rpi/openthinrdp-growroot.service "$T/etc/systemd/system/openthinrdp-growroot.service"
inch systemctl enable openthinrdp-growroot.service

# --- build settings for the chroot hook, then the hook of the ISO (accounts, services, language, splash, initramfs)
# (%q: the password hash is full of "$", and the hook sources this file)
printf 'LOCALE=%q\nTIMEZONE=%q\nKEYBOARD=%q\nFREERDP_FROM=%q\nADMIN_PASSWORD_HASH=%q\n' "$LOCALE" "$TIMEZONE" "$KEYBOARD" "$FREERDP_FROM" "${ADMIN_PASSWORD_HASH:-}" > "$T/etc/openthinrdp/build.env"
cp $B/image/lb/hook.chroot "$T/tmp/openthinrdp.hook"
inch bash /tmp/openthinrdp.hook
rm -f "$T/tmp/openthinrdp.hook" "$T/etc/openthinrdp/build.env"
# (on a PC the Debian installer creates otradmin with the password of build.conf too; here the hook alone does it)
# kernel, initramfs, device trees, config.txt and cmdline.txt into /boot/firmware, from the settings above
inch env DEB_MAINT_PARAMS=configure /etc/kernel/postinst.d/z50-raspi-firmware
grep -q 'root=LABEL=RASPIROOT' "$T/boot/firmware/cmdline.txt" || { echo "cmdline.txt without the root partition"; exit 1; }
ls "$T"/boot/firmware/bcm2711-rpi-4-b.dtb "$T"/boot/firmware/start4.elf "$T"/boot/firmware/vmlinuz-* "$T"/boot/firmware/initrd.img-* >/dev/null

# --- what every device must have of its own: made at the first boot
rm -f "$T"/etc/ssh/ssh_host_*                     # apply.sh creates them when SSH is turned on
: > "$T/etc/machine-id"; rm -f "$T/var/lib/dbus/machine-id"   # systemd: a new one, and the first-boot units
rm -f "$T/var/lib/systemd/random-seed" "$T/etc/apt/apt.conf.d/99mmdebstrap"
echo "=== customize done: $(inch dpkg-query -W -f '${Version}' freerdp3-x11) FreeRDP, kernel $(ls "$T"/boot/vmlinuz-* | sed 's|.*/vmlinuz-||' | tr '\n' ' ')"
