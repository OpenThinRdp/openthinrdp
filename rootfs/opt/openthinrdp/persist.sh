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
# an ISO written to a stick is mounted whole (/dev/sda, iso9660 on the disk itself), not as one of its partitions
pk=$(lsblk -no PKNAME "$src" 2>/dev/null | head -1); disk=${pk:+/dev/$pk}; disk=${disk:-$src}
[ "$(lsblk -dno TRAN "$disk" 2>/dev/null)" = usb ] || { echo "not a live stick" > "$ST"; exit 0; }
# A stick written with an image before 0.3.0 (GPT around efi.img, mounted whole): while the disk is mounted whole
# no partition of it can be formatted or mounted, now or at the next start. Its table becomes the one of the
# current images instead: an MBR, partition 1 from sector 0 over the whole image (type 0, as in Debian's images:
# mountable, ignored by UEFI), partition 2 the EFI partition where it was. Nothing of the image moves, BIOS (GRUB
# reads its blocks by address) and UEFI (the EFI partition) start the same. The MBR first, in one sector: from then
# on the kernel and the firmware read it, the GPT headers wiped after are only left-overs. From the next start the
# image is mounted from partition 1 and the settings partition is made as on a new stick.
if [ "$src" = "$disk" ]; then
  iso=$(( $(isosize "$disk" 2>/dev/null || echo 0) / 512 ))
  if [ "$iso" -gt 0 ] && python3 - "$disk" "$iso" <<'PY'
import sys, struct, json, subprocess
disk, iso = sys.argv[1], int(sys.argv[2])
t = json.loads(subprocess.run(["sfdisk", "-J", disk], capture_output=True, text=True, check=True).stdout)["partitiontable"]
parts = t.get("partitions", [])
efi = [p for p in parts if p["type"].upper() == "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"]
if t.get("label") != "gpt" or not 1 <= len(parts) <= 3 or len(efi) != 1 or any(p["start"] + p["size"] > iso for p in parts):
    sys.exit(1)
e = efi[0]
def entry(boot, typ, start, size):
    return struct.pack("<B3sB3sII", boot, b"\x00\x01\x00" if start == 0 else b"\xfe\xff\xff", typ, b"\xfe\xff\xff", start, size)
with open(disk, "r+b", buffering=0) as f:
    mbr = bytearray(f.read(512))
    lba1 = f.read(512)
    mbr[446:510] = entry(0x80, 0x00, 0, iso) + entry(0, 0xef, e["start"], e["size"]) + bytes(32)
    mbr[510:512] = b"\x55\xaa"
    f.seek(0); f.write(mbr); f.flush()
    import os; os.fsync(f.fileno())
    # the GPT headers: the primary one (sector 1) and its backup (its address is in the primary)
    if lba1[:8] == b"EFI PART":
        alt = struct.unpack_from("<Q", lba1, 32)[0]
        for s in (1, alt):
            f.seek(s * 512); f.write(bytes(512))
        os.fsync(f.fileno())
PY
  then
    echo made > "$ST"; ev "live persistence: the stick now has the partition table of the current images, the settings partition is made at the next start"
  else echo "not a live stick" > "$ST"; fi
  exit 0
fi
# made at an earlier start but not used (a boot entry without "persistence"): nothing more to do
[ -n "$(part "$disk")" ] && { echo "made" > "$ST"; exit 0; }
# the free space after the partitions of the image, in sectors of 512 bytes: from the end of the last one to the end
# of the stick (the ISO is GPT, and its table ends where the image ends: "sfdisk -F" sees no free space at all; the
# append below moves the backup table to the end of the stick)
end=$(sfdisk -lq -o End "$disk" 2>/dev/null | awk '$1 ~ /^[0-9]+$/ && $1 > m {m = $1} END {print m + 0}')
free=$(( $(blockdev --getsz "$disk" 2>/dev/null || echo 0) - end - 2048 ))
[ -n "$free" ] && [ "$free" -ge 2097152 ] || { echo "no room" > "$ST"; exit 0; }
echo ',,L' | sfdisk --append --no-reread --force -q "$disk" >/dev/null 2>&1
# the new partition (the one starting after the image) handed to the kernel alone: "partx -u" would drop the EFI
# partition of a converted stick (inside partition 1, libblkid leaves it out) and nothing else needs updating
read -r p s < <(sfdisk -lq -o Device,Start "$disk" 2>/dev/null | awk '$2 ~ /^[0-9]+$/ && $2 > m {m = $2; d = $1} END {print d, m + 0}')
n=${p##*[!0-9]}
[ -n "$n" ] && [ "$s" -gt "$end" ] && partx -a -n "$n:$n" "$disk" 2>/dev/null; udevadm settle 2>/dev/null
[ -n "$n" ] && [ "$s" -gt "$end" ] && [ -b "$p" ] || { echo "no room" > "$ST"; ev "live persistence: the partition could not be made on $disk"; exit 0; }
mkfs.ext4 -q -F -L persistence "$p" >/dev/null 2>&1 || { echo "no room" > "$ST"; ev "live persistence: $p could not be formatted"; exit 0; }
m=$(mktemp -d); mount "$p" "$m" && { echo "/ union" > "$m/persistence.conf"; umount "$m"; }; rmdir "$m"
echo made > "$ST"; echo "$p" > "$ST.part"
ev "live persistence: partition $p made on the stick ($(( free / 2048 )) MiB), the settings stay from the next start"
# the settings of this first start go onto it at shutdown
systemd-run --quiet --unit=openthinrdp-persist-seed -p RemainAfterExit=yes -p ExecStop="$OTR/persist.sh seed" /bin/true >/dev/null 2>&1
exit 0
