#!/bin/bash
# Hardware and system test of this device, as root: what the project needs to know whether OpenThinRDP runs well on
# it. Runs by itself at the first start of the live system, and from Diagnostics on any device.
#   selftest.sh          the report on stdout (Markdown, one line per check: OK, WARN or FAIL)
#   selftest.sh --save   also in /run/openthinrdp-selftest.md (readable by the kiosk) and $OTR_LOG/selftest.md
# Nothing that identifies the device or the network goes into the report: no name, address, MAC, serial number or
# server name, so it can be published as a hardware report.
. /opt/openthinrdp/lib/common.sh
. "$OTR/lib/netif.sh"
OK=0; WARN=0; FAIL=0
r(){ case $1 in OK) OK=$((OK+1)); m='OK  ' ;; WARN) WARN=$((WARN+1)); m='WARN' ;; *) FAIL=$((FAIL+1)); m='FAIL' ;; esac
     printf -- '- `%s` **%s**: %s\n' "$m" "$2" "$3"; }
rd(){ tr -d '\0' < "$1" 2>/dev/null | head -1 | sed 's/[[:space:]]*$//'; }
body(){
  echo "### System"
  r OK "OpenThinRDP" "$(cat "$OTR/VERSION" 2>/dev/null), $(otr_installed && echo installed || echo 'live system')"
  local frv; frv=$(dpkg-query -W -f '${Version}' libfreerdp-client3-3 2>/dev/null)
  if HOME=/root xfreerdp3 --buildconfig 2>/dev/null | grep -q 'WITH_RDPEUDP=ON'; then r OK "FreeRDP" "$frv, with the UDP transport"
  else r WARN "FreeRDP" "${frv:-not found}, without the UDP transport"; fi
  r OK "Kernel" "$(uname -r), $(otr_arch)"
  if [ -d /sys/firmware/efi ]; then
    local sb; sb=$(od -An -t u1 /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c 2>/dev/null | awk '{print $NF}')
    r OK "Firmware" "UEFI, Secure Boot $([ "$sb" = 1 ] && echo on || echo off)"
  else r OK "Firmware" "legacy BIOS"; fi
  echo; echo "### Hardware"
  r OK "Model" "$(rd /sys/class/dmi/id/sys_vendor) $(rd /sys/class/dmi/id/product_name) $(rd /sys/class/dmi/id/product_version)"
  r OK "BIOS" "$(rd /sys/class/dmi/id/bios_version) ($(rd /sys/class/dmi/id/bios_date))"
  r OK "Processor" "$(awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo), $(nproc) threads"
  local mem; mem=$(awk '/^MemTotal/{printf "%.1f", $2/1048576}' /proc/meminfo)
  if awk -v m="$mem" 'BEGIN{exit !(m < 1.8)}'; then r FAIL "Memory" "$mem GB (2 GB needed)"; else r OK "Memory" "$mem GB"; fi
  local disk; disk=$(lsblk -dnbo NAME,SIZE,TRAN,TYPE 2>/dev/null | awk '$4=="disk" && $3!="usb" && $1!~/^(loop|sr|zram)/ && $1!~/(boot[0-9]|rpmb)$/ {printf "%s %.0f GB%s; ", $1, $2/1e9, ($3? " "$3 : "")}')
  if [ -z "$disk" ]; then r WARN "Internal disk" "none found (fine for the live system, 8 GB needed to install)"; else r OK "Internal disk" "${disk%; }"; fi
  if [ -e /dev/tpmrm0 ] || [ -e /dev/tpm0 ]; then r OK "TPM" "$(rd /sys/class/tpm/tpm0/tpm_version_major | sed 's/^2$/2.0/;s/^1$/1.2/') (secrets kept in it)"
  else r OK "TPM" "none (optional: the device works the same)"; fi
  echo; echo "### Graphics and screens"
  local c drv out=""
  for c in /sys/class/drm/card[0-9]; do drv=$(basename "$(readlink "$c/device/driver")" 2>/dev/null); [ -n "$drv" ] && out="$out$drv "; done
  if [ -n "$out" ]; then r OK "Graphics driver" "$out$(lspci -nn 2>/dev/null | grep -iE 'vga|display|3d' | sed 's/^[^ ]* //' | head -2 | tr '\n' ' ')"
  else r WARN "Graphics driver" "no DRM driver: generic framebuffer only"; fi
  out=""; for c in /sys/class/drm/card*-*; do [ "$(cat "$c/status" 2>/dev/null)" = connected ] && out="$out$(basename "$c" | cut -d- -f2-) $(head -1 "$c/modes") "; done
  [ -n "$out" ] && r OK "Screens" "$out" || r WARN "Screens" "none reported as connected"
  echo; echo "### Firmware and drivers"
  local fw; fw=$(journalctl -k -b --no-pager -q 2>/dev/null | grep -iE 'firmware: failed|direct firmware load .* failed' | sed -E 's/.*(firmware[^,]*)/\1/' | sort -u | head -5)
  [ -z "$fw" ] && r OK "Missing firmware" "none" || r WARN "Missing firmware" "$(echo "$fw" | tr '\n' ';')"
  local nerr; nerr=$(journalctl -k -b -p err --no-pager -q 2>/dev/null | wc -l)
  [ "$nerr" -eq 0 ] && r OK "Kernel errors" "none since boot" || r WARN "Kernel errors" "$nerr since boot (journalctl -k -p err)"
  echo; echo "### Network"
  local i sp
  for i in $(wired_nics); do
    sp=$(cat "/sys/class/net/$i/speed" 2>/dev/null); drv=$(basename "$(readlink "/sys/class/net/$i/device/driver")" 2>/dev/null)
    if [ "$(cat "/sys/class/net/$i/carrier" 2>/dev/null)" = 1 ]; then r OK "Wired ($drv)" "link up, ${sp:-?} Mbit/s"
    else r WARN "Wired ($drv)" "no link (cable?)"; fi
  done
  for i in $(wifi_nics); do drv=$(basename "$(readlink "/sys/class/net/$i/device/driver")" 2>/dev/null); r OK "Wi-Fi ($drv)" "adapter found"; done
  [ -z "$(wired_nics)$(wifi_nics)" ] && r FAIL "Network card" "none found: a driver or firmware is missing"
  i=$(main_nic)
  if ip -4 -o addr show dev "$i" 2>/dev/null | grep -q inet; then r OK "IP address" "yes ($(cfg NETMODE))"; else r FAIL "IP address" "none on the main card"; fi
  local gw; gw=$(ip -4 route show default 2>/dev/null | awk '{print $3}' | head -1)
  if [ -n "$gw" ] && ping -c1 -W2 "$gw" >/dev/null 2>&1; then r OK "Gateway" "answers"; elif [ -n "$gw" ]; then r WARN "Gateway" "does not answer to ping"; else r WARN "Gateway" "none"; fi
  if getent ahosts deb.debian.org >/dev/null 2>&1; then r OK "DNS" "names resolve"; else r FAIL "DNS" "names do not resolve"; fi
  if timeout 5 bash -c '</dev/tcp/github.com/443' 2>/dev/null; then r OK "Internet" "GitHub reachable (updates)"; else r WARN "Internet" "GitHub not reachable (fine with updates from your own folder)"; fi
  [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ] && r OK "Clock" "synchronized" || r WARN "Clock" "not synchronized yet (Kerberos needs the right time)"
  echo; echo "### Sound and USB"
  local snd; snd=$(sed -n 's/^ *[0-9]* \[[^]]*\]: //p' /proc/asound/cards 2>/dev/null | cut -d' ' -f1 | sort -u | tr '\n' ' ')
  [ -n "$snd" ] && r OK "Sound" "$snd" || r WARN "Sound" "no sound card"
  r OK "USB controllers" "$(lspci 2>/dev/null | grep -ciE 'usb controller') ($(ls /sys/bus/usb/devices 2>/dev/null | grep -c '^usb') root hubs)"
  out=$(for d in /sys/bus/usb/devices/[0-9]*-[0-9]*; do [ -f "$d/idVendor" ] && [ "$(cat "$d/bDeviceClass")" != 09 ] && printf '%s:%s %s; ' "$(cat "$d/idVendor")" "$(cat "$d/idProduct")" "$(rd "$d/product")"; done)
  r OK "USB devices" "${out:-none}"
  echo; echo "### Remote desktop"
  local b; b=$(cfg BROKER)
  if [ -z "$b" ]; then r WARN "Broker or PC" "not set yet"
  elif timeout 4 bash -c "</dev/tcp/$b/3389" 2>/dev/null; then r OK "Broker or PC" "set, answers on port 3389"
  else r FAIL "Broker or PC" "set, does not answer on port 3389"; fi
  if [ -n "$(cfg MGMT_SHARE)$(cat "$OTR_LIB/share-from-domain" 2>/dev/null)" ]; then
    tail -1 "$OTR_LOG/report.log" 2>/dev/null | grep -q ' sent to ' && r OK "Management folder" "set, the last report was sent" || r WARN "Management folder" "set, the last report was not sent (see Diagnostics)"
  else r OK "Management folder" "not set (optional)"; fi
}
TB=$(mktemp); body > "$TB"; B=$(cat "$TB"); rm -f "$TB"   # in this shell: the counters stay
R="## OpenThinRDP hardware report

$OK OK, $WARN warnings, $FAIL problems ($(date '+%Y-%m-%d'))

$B"
echo "$R"
if [ "${1:-}" = --save ]; then
  mkdir -p "$OTR_LOG"; echo "$R" > "$OTR_LOG/selftest.md"
  T=$(mktemp /run/.selftest.XXXXXX); echo "$R" > "$T"; chmod 644 "$T"; mv -f "$T" /run/openthinrdp-selftest.md
  ev "hardware test: $OK OK, $WARN warnings, $FAIL problems"
fi
exit 0
