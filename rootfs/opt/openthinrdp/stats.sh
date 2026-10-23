#!/bin/bash
# Anonymous usage counts for the project (ANON_STATS=on, the default; off in the settings of the device or centrally).
# From report.sh: at the first report after the device starts the first time (about a minute), then once a week.
# What is sent, and nothing else (docs/privacy.md says the same):
#   the version of OpenThinRDP and of FreeRDP, the maker and model of the computer, its processor, its memory rounded
#   to whole GB, the transport (auto/udp/tcp), the language, live system or installed, Wi-Fi adapter and TPM present
#   (yes/no), managed from a management folder or not.
# Never: the name of the device, its addresses (IP, MAC), users, domain, servers, settings or anything typed.
# Each value is one count (an "event") on GoatCounter, which keeps no IP address and sets no cookie: the project sees
# totals such as "OptiPlex 3000 Thin Client: 12 devices", never a device.
#   stats.sh          send when nothing was ever sent, or the last send is a week old
#   stats.sh --print  print what would be sent, send nothing
. /opt/openthinrdp/lib/common.sh
. "$OTR/lib/netif.sh"
URL=${OTR_STATS_URL:-https://ceschi-ops.goatcounter.com/count}
STAMP=$OTR_LIB/stats-sent

# printable, short, no line breaks: what GoatCounter shows as the name of a count
clean(){ printf '%s' "$1" | tr -c 'A-Za-z0-9 ._()+-' ' ' | tr -s ' ' | sed 's/^ //; s/ $//' | cut -c1-60; }

events(){
  local v m c r f
  v=$(cat "$OTR/VERSION" 2>/dev/null); [ -n "$v" ] || v=unknown
  m=$(clean "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null) $(cat /sys/class/dmi/id/product_name 2>/dev/null)")
  # the vendor names that say nothing more ("To be filled by O.E.M.", "System manufacturer")
  case "$m" in ""|*"O.E.M"*|*"System manufacturer"*|*"Default string"*) m=unknown ;; esac
  c=$(clean "$(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -1)"); [ -n "$c" ] || c=$(clean "$(uname -m)")
  r=$(awk '/^MemTotal:/ {printf "%d GB", ($2 / 1048576) + 0.5}' /proc/meminfo)
  f=$(HOME=/root xfreerdp3 --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  echo "otr/version/$v"
  echo "otr/model/$m"
  echo "otr/cpu/$c"
  echo "otr/ram/$r"
  echo "otr/freerdp/${f:-unknown}"
  echo "otr/transport/$(cfg TRANSPORT)"
  echo "otr/language/$(cfg LANGUAGE)"
  if grep -qw 'boot=live' /proc/cmdline; then echo "otr/mode/live"; else echo "otr/mode/installed"; fi
  if [ -n "$(wifi_nics | head -1)" ]; then echo "otr/wifi/yes"; else echo "otr/wifi/no"; fi
  if [ -e /dev/tpmrm0 ] || [ -e /dev/tpm0 ]; then echo "otr/tpm/yes"; else echo "otr/tpm/no"; fi
  if [ -n "$(cfg MGMT_SHARE)" ] || [ -s "$OTR_LIB/share-from-domain" ]; then echo "otr/managed/yes"; else echo "otr/managed/no"; fi
}

if [ "$1" = --print ]; then events; exit 0; fi
[ "$(cfg ANON_STATS)" = off ] && exit 0
# never sent (a device just switched on: at once), or a week since the last send
[ -f "$STAMP" ] && [ $(( $(date +%s) - $(stat -c %Y "$STAMP") )) -lt 604800 ] && exit 0
ua="Mozilla/5.0 (X11; Linux x86_64) OpenThinRDP/$(cat "$OTR/VERSION" 2>/dev/null)"
ok=0
while IFS= read -r p; do
  curl -fsS -m 10 -G -A "$ua" --data-urlencode "p=$p" --data-urlencode "e=true" --data-urlencode "rnd=$RANDOM$RANDOM" "$URL" -o /dev/null 2>/dev/null && ok=1
done < <(events)
# at least one count arrived: the next in a week. None (no internet, a proxy): tried again at the next report
[ $ok = 1 ] && touch "$STAMP"
exit 0
