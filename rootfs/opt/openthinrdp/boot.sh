#!/bin/bash
# Boot service (openthinrdp-boot.service): bring the system to a known state from the settings.
# Runs in parallel with the automatic login: nothing here may be needed before the login form.
. /opt/openthinrdp/lib/common.sh
mkdir -p "$OTR_LIB" "$OTR_LOG"; touch "$OTR_EVENTS" "$OTR_LOG/session-hang.log"; chown "$OTR_KIOSK_USER:" "$OTR_EVENTS" "$OTR_LOG/session-hang.log" 2>/dev/null

# A new device (installer, live system) is called "thinclient": it gets a name of its own from the MAC address of
# its network card, so devices installed from the same image do not report over each other in the management
# folder. Only while the name is still the default one: a name set later (dialog, central settings) stays.
# First thing: the settings dialog of a new device waits for it (kiosk.sh).
if [ "$(hostname)" = thinclient ]; then
  . "$OTR/lib/netif.sh"
  MAC=$(tr -d ':' < "/sys/class/net/$(main_nic)/address" 2>/dev/null)
  if [[ $MAC =~ ^[0-9a-f]{12}$ ]]; then
    N=thinclient-${MAC:6}; T=$(mktemp); echo "HOSTNAME=$N" > "$T"
    if R=$("$OTR/save-config.sh" "$T" 2>&1); then ev "name of this device: $N (from its MAC address)"
    else
      # save-config.sh refuses everything when another setting of the device is not valid (a hand-written
      # openthinrdp.conf, an image built with settings of its own): the device kept the shared name and nobody
      # knew why. The name alone does not depend on them; the reason goes to the log.
      hostnamectl set-hostname "$N" 2>/dev/null || hostname "$N"
      if grep -q '^127\.0\.1\.1' /etc/hosts; then sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$N/" /etc/hosts
      else printf '127.0.1.1\t%s\n' "$N" >> /etc/hosts; fi
      ev "name of this device: $N (from its MAC address); settings not valid, fix them in the settings dialog: $(echo "$R" | sed 's/^- //' | paste -sd ';' -)"
    fi
    rm -f "$T"
  fi
fi
# the automatic login starts X only after this (/etc/skel/.bash_profile): X started under the old name keeps a
# cookie for it, and after the rename no program can open the screen (the first start of a new device stayed black)
touch /run/openthinrdp-name-ready

# network, DNS, time servers, updates, USB, SSH, keyboard
"$OTR/apply.sh" boot

# NTLM only (RDP_AUTH=ntlm): without a Kerberos configuration FreeRDP cannot try Kerberos at all
if [ "$(cfg RDP_AUTH)" = ntlm ]; then grep -q '^KRB5_CONFIG=' /etc/environment || echo 'KRB5_CONFIG=/dev/null' >> /etc/environment
else sed -i '/^KRB5_CONFIG=\/dev\/null$/d' /etc/environment; fi

# APT sources: a system installed offline from the ISO only knows the cdrom
if ! grep -qhsE '^(deb|URIs:) *https?://' /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources 2>/dev/null; then
  cat > /etc/apt/sources.list.d/debian.sources <<'SRC'
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie trixie-updates trixie-backports
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: trixie-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
SRC
  sed -i 's/^deb cdrom/# deb cdrom/' /etc/apt/sources.list 2>/dev/null
fi
# package lists never downloaded (offline install): fetch them once, in the background
[ -z "$(ls /var/lib/apt/lists/ 2>/dev/null | grep -v -e lock -e partial -e auxfiles)" ] && { (sleep 60; apt-get update -q >/dev/null 2>&1) & }

# --- once, on a PC installed from the ISO only (not on the live image). A Raspberry Pi has no GRUB: its image is
# built with the silent command line (/etc/default/raspi-extra-cmdline) and keeps Debian's initramfs (MODULES=most:
# the SD card, USB disk and display drivers are all there, whatever the board boots from)
if [ -f /etc/default/grub ] && [ -d /boot/grub ]; then
  # direct and silent boot: no GRUB menu, no kernel or systemd messages, the splash until the login form
  if [ ! -f "$OTR_LIB/.grub-silent" ]; then
    sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=0/' /etc/default/grub
    grep -q '^GRUB_TIMEOUT_STYLE' /etc/default/grub || echo 'GRUB_TIMEOUT_STYLE=hidden' >> /etc/default/grub
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash loglevel=3 rd.udev.log_level=3 systemd.show_status=false vt.global_cursor_default=0"/' /etc/default/grub
    update-grub 2>/dev/null && touch "$OTR_LIB/.grub-silent"
  fi
  # initramfs with the drivers of THIS machine only (on a thin client 137 MB -> 18 MB, a few seconds less of
  # boot from eMMC). It has to happen on the device, not in the image. The graphics and wired network drivers in
  # use go in explicitly so the splash and an early network keep working. Never a Wi-Fi driver: nothing uses it
  # before the disk, and loaded there it misses the half it asks for later (iwlwifi without iwlmvm), so after a
  # kernel update the device had no Wi-Fi adapter at all.
  wifi_mod(){ modinfo -F depends "$1" 2>/dev/null | tr ',' '\n' | grep -qx -E 'cfg80211|mac80211'; }
  if [ ! -f "$OTR_LIB/.initramfs-dep" ]; then
    sed -i 's/^MODULES=.*/MODULES=dep/' /etc/initramfs-tools/initramfs.conf
    for d in /sys/class/drm/card[0-9]/device/driver /sys/class/net/*/device/driver; do
      m=$(basename "$(readlink -f "$d")" 2>/dev/null); [ -n "$m" ] && modinfo "$m" >/dev/null 2>&1 || continue
      wifi_mod "$m" && continue
      grep -qx "$m" /etc/initramfs-tools/modules || echo "$m" >> /etc/initramfs-tools/modules
    done
    flock -w 900 /run/openthinrdp-initramfs.lock update-initramfs -u >/dev/null 2>&1 && touch "$OTR_LIB/.initramfs-dep" "$OTR_LIB/.initramfs-nowifi"
  fi
  # devices set up before 0.1.8: take the Wi-Fi drivers out again (the next boot has the adapter back)
  if [ ! -f "$OTR_LIB/.initramfs-nowifi" ]; then
    W=$(grep -vE '^\s*(#|$)' /etc/initramfs-tools/modules 2>/dev/null | while read -r m; do wifi_mod "$m" && echo "$m"; done)
    for m in $W; do sed -i "/^$m\$/d" /etc/initramfs-tools/modules; done
    if [ -z "$W" ] || flock -w 900 /run/openthinrdp-initramfs.lock update-initramfs -u >/dev/null 2>&1; then
      touch "$OTR_LIB/.initramfs-nowifi"; [ -n "$W" ] && ev "Wi-Fi driver taken out of the initramfs: $W"
    fi
  fi
fi
exit 0
