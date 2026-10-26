#!/bin/bash
# Anonymous usage counts for the project (ANON_STATS=on, the default; off in the settings of the device or centrally).
# From report.sh: at the first report after the device starts the first time (about a minute), then once a week.
# What is sent, and nothing else (docs/privacy.md says the same):
#   the version of OpenThinRDP and of FreeRDP, the maker and model of the computer, its processor, its memory rounded
#   to whole GB, the transport (auto/udp/tcp), the language, live system or installed, Wi-Fi adapter and TPM present
#   (yes/no), managed from a management folder or not;
#   and what went wrong since the last send, as counts per kind (sessions frozen or dropped, connections that failed
#   or timed out, failed updates, programs that crashed, graphics hangs, kernel errors, stops without a shutdown),
#   with the exit code of FreeRDP or the name of the program that crashed, by version and by model.
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

bucket(){ if [ "$1" -le 1 ]; then echo 1; elif [ "$1" -le 5 ]; then echo 2-5; elif [ "$1" -le 20 ]; then echo 6-20; else echo "more than 20"; fi; }

# what went wrong since the last send, one line per occurrence: a fixed kind, for FreeRDP the number of its exit
# code, for a crash the name of the program. Never the text of a message (it holds users and servers)
problems(){
  local from i last
  from=$(date -d "@$1" '+%Y-%m-%d %H:%M:%S')
  # the events of the device
  awk -v f="$from" 'substr($0, 1, 19) > f' "$OTR_EVENTS" 2>/dev/null | sed -nE \
    -e 's/.*watchdog: FreeRDP received nothing over UDP.*/udp-stalled/p' \
    -e 's/.*power off with a session still open.*/switched-off-in-session/p' \
    -e 's/.*watchdog: FreeRDP .*/session-frozen/p' \
    -e 's/.*no desktop after [0-9]+ s, stopped.*/connect-timeout/p' \
    -e 's/.*attempt [0-9]+ for .* failed after .*\(code ([0-9]+), .*/connect-failed \1/p' \
    -e 's/.*session of .* DROPPED after .*, code ([0-9]+)\): .*/session-dropped \1/p' \
    -e 's/.*session of .* dropped after .* before the desktop was ready \(code ([0-9]+)\).*/dropped-before-desktop \1/p' \
    -e 's/.*software update .* FAILED.*/update-failed/p' \
    -e 's/.*the settings screen failed.*/screen-failed/p' \
    -e 's/.*hardware test: .*, [1-9][0-9]* problems$/hardware-test-problems/p'
  # the kernel: a program that crashed, the graphics stuck, errors of the kernel itself
  journalctl -k -q --no-pager -o cat --since "@$1" 2>/dev/null | sed -nE \
    -e 's/^([A-Za-z0-9_.-]+)\[[0-9]+\]: segfault at .*/crash \1/p' \
    -e 's/.*(GPU HANG|gpu hang|ring [a-z0-9]+ timeout).*/graphics-hang/p' \
    -e 's/.*(Oops|BUG: |Kernel panic|general protection fault).*/kernel-error/p'
  # a start after a stop that was no shutdown: a power cut, or frozen and switched off by hand
  for i in $(journalctl --list-boots -q --no-pager 2>/dev/null | awk '$1 < 0 {print $1}' | tail -n 30); do
    last=$(journalctl -b "$i" -n 1 -q --no-pager -o short-unix 2>/dev/null)
    [ "${last%%.*}" -ge "$1" ] 2>/dev/null && [[ $last != *"Journal stopped"* ]] && echo "stopped-without-shutdown"
  done
}

# the problems as counts: how many of each kind, and each kind by version and by model (GoatCounter counts paths, it
# cannot cross them: these are the crossings worth having). A device with none says so, for the share of clean weeks
errors(){
  local v=$2 m=$3 k c n
  problems "$1" | awk '{k[$1]++; if ($2 != "") c[$1 " " $2]++} END {for (i in k) print "K", k[i], i; for (i in c) print "C", c[i], i}' |
  while read -r t n k c; do
    if [ "$t" = K ]; then echo "otr/error/$k/$(bucket "$n")"; echo "otr/error-version/$k/$v"; echo "otr/error-model/$k/$m"
    else echo "otr/error-detail/$k/$c"; fi
  done | sort | grep . || echo "otr/error/none"
}

all(){
  local since e
  # since the last send; the first time, the week before
  if [ -f "$STAMP" ]; then since=$(stat -c %Y "$STAMP"); else since=$(( $(date +%s) - 604800 )); fi
  e=$(events); printf '%s\n' "$e"
  errors "$since" "$(printf '%s\n' "$e" | sed -n 's#^otr/version/##p')" "$(printf '%s\n' "$e" | sed -n 's#^otr/model/##p')"
}

if [ "$1" = --print ]; then all; exit 0; fi
[ "$(cfg ANON_STATS)" = off ] && exit 0
# never sent (a device just switched on: at once), or a week since the last send
[ -f "$STAMP" ] && [ $(( $(date +%s) - $(stat -c %Y "$STAMP") )) -lt 604800 ] && exit 0
ua="Mozilla/5.0 (X11; Linux x86_64) OpenThinRDP/$(cat "$OTR/VERSION" 2>/dev/null)"
# python3 is in the image, curl is not: up to 0.2.23 the counts were sent with curl and no device ever sent one.
# One python3 for all the counts; it stops at the first that gets no answer at all (no internet, a proxy).
# At least one count arrived: the next in a week. None: tried again at the next report
all | python3 -c '
import sys, random, urllib.error, urllib.parse, urllib.request
url, ua, ok = sys.argv[1], sys.argv[2], False
for p in sys.stdin.read().splitlines():
    q = urllib.parse.urlencode({"p": p, "e": "true", "rnd": random.randrange(10 ** 9)})
    try:
        with urllib.request.urlopen(urllib.request.Request(url + "?" + q, headers={"User-Agent": ua}), timeout=10) as r:
            ok = ok or r.status < 300
    except urllib.error.HTTPError:
        pass
    except Exception:
        break
sys.exit(0 if ok else 1)' "$URL" "$ua" 2>/dev/null && touch "$STAMP"
exit 0
