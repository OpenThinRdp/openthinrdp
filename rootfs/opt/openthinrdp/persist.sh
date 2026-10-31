#!/bin/bash
# The live system on a USB stick keeps its settings (LIVE_PERSISTENCE=on, 0.3.0), as other live distributions do:
# at the first start from a stick with free space a partition labelled "persistence" (live-boot, "/ union") is made
# there; from the next start everything written (settings, updates, Wi-Fi, the password remembered) stays on it.
# Never on an installed system, never on another disk than the stick the system started from, never on a stick
# started through Ventoy or from a CD (the medium is then not a partition of a USB disk). Runs as root:
#   persist.sh          at boot (boot.sh): the partition made when it is missing and there is room (1 GiB at least)
#   persist.sh seed     at shutdown, after it was made: the settings of this first start copied onto it
#   persist.sh status   one line: on (in use) / made (in use from the next start) / no room / off / not a live stick
. /opt/openthinrdp/lib/common.sh
ST=/run/openthinrdp-persist
in_use(){ grep -q ' /run/live/persistence/' /proc/mounts; }
part(){ blkid -t LABEL=persistence -o device 2>/dev/null | while read -r p; do [ "/dev/$(lsblk -no PKNAME "$p" 2>/dev/null)" = "$1" ] && echo "$p"; done | head -1; }
case "${1:-}" in
  status) if in_use; then echo on; else cat "$ST" 2>/dev/null || echo "not a live stick"; fi; exit 0 ;;
  seed)
    p=$(cat "$ST.part" 2>/dev/null); [ -b "$p" ] || exit 0
    m=$(mktemp -d); mount "$p" "$m" || exit 0
    mkdir -p "$m/rw"
    for f in /etc/openthinrdp /var/lib/openthinrdp /etc/wpa_supplicant /etc/hostname /etc/hosts /etc/timezone /etc/localtime /etc/ssh/ssh_host_*; do
      [ -e "$f" ] && cp -a --parents "$f" "$m/rw/" 2>/dev/null
    done
    sync; umount "$m"; rmdir "$m"; exit 0 ;;
esac
[ -d /run/live/medium ] && ! otr_installed || exit 0
in_use && { echo on > "$ST"; exit 0; }
[ "$(cfg LIVE_PERSISTENCE)" = off ] && { echo off > "$ST"; exit 0; }
src=$(findmnt -no SOURCE /run/live/medium 2>/dev/null)
case "$src" in /dev/sd*|/dev/nvme*|/dev/mmcblk*) ;; *) echo "not a live stick" > "$ST"; exit 0 ;; esac
disk=/dev/$(lsblk -no PKNAME "$src" 2>/dev/null)
[ "$(lsblk -dno TRAN "$disk" 2>/dev/null)" = usb ] || { echo "not a live stick" > "$ST"; exit 0; }
# made at an earlier start but not used (a boot entry without "persistence"): nothing more to do
[ -n "$(part "$disk")" ] && { echo "made" > "$ST"; exit 0; }
# the free space after the partitions of the image, in sectors of 512 bytes: from the end of the last one to the end
# of the stick (the ISO is GPT, and its table ends where the image ends: "sfdisk -F" sees no free space at all; the
# append below moves the backup table to the end of the stick)
end=$(sfdisk -lq -o End "$disk" 2>/dev/null | awk '$1 ~ /^[0-9]+$/ && $1 > m {m = $1} END {print m + 0}')
free=$(( $(blockdev --getsz "$disk" 2>/dev/null || echo 0) - end - 2048 ))
[ -n "$free" ] && [ "$free" -ge 2097152 ] || { echo "no room" > "$ST"; exit 0; }
n0=$(lsblk -nlo NAME "$disk" | wc -l)
echo ',,L' | sfdisk --append --no-reread --force -q "$disk" >/dev/null 2>&1
partx -u "$disk" 2>/dev/null; partx -a "$disk" 2>/dev/null; udevadm settle 2>/dev/null
p=$(lsblk -nlpo NAME "$disk" | tail -1)
[ "$(lsblk -nlo NAME "$disk" | wc -l)" -gt "$n0" ] && [ -b "$p" ] || { echo "no room" > "$ST"; ev "live persistence: the partition could not be made on $disk"; exit 0; }
mkfs.ext4 -q -F -L persistence "$p" >/dev/null 2>&1 || { echo "no room" > "$ST"; ev "live persistence: $p could not be formatted"; exit 0; }
m=$(mktemp -d); mount "$p" "$m" && { echo "/ union" > "$m/persistence.conf"; umount "$m"; }; rmdir "$m"
echo made > "$ST"; echo "$p" > "$ST.part"
ev "live persistence: partition $p made on the stick ($(( free / 2048 )) MiB), the settings stay from the next start"
# the settings of this first start go onto it at shutdown
systemd-run --quiet --unit=openthinrdp-persist-seed -p RemainAfterExit=yes -p ExecStop="$OTR/persist.sh seed" /bin/true >/dev/null 2>&1
exit 0
