#!/bin/bash
# Anonymous data for the project (ANON_STATS, docs/privacy.md says the same, item by item):
#   full    (the default) once a week what the device is, how it is used and how well it runs, and what went wrong
#   errors  only in a week when something went wrong: what went wrong and on what (version, model)
#   off     nothing
# From report.sh: a new device once it has chosen (the first start asks), then once a week.
# Full, the week ("otr_week"): versions of OpenThinRDP and FreeRDP, maker and model, processor, memory in GB,
#   architecture, live or installed, language; the environment (domain or workgroup, broker or one PC, RD Gateway
#   yes/no, VPN kind, where updates come from, transport); what is used (password remembered, Wake-on-LAN, Bluetooth
#   device paired, cable or Wi-Fi, web button and browser, screen count, resolution class and scale, kinds of USB
#   devices plugged: camera, smart card, audio, storage, printer); installed alongside Windows, live with saved
#   settings; how it was used since the last send (sessions, days, hours in session, sessions over UDP or TCP) and how
#   fast (start to the sign-in screen, sign-in by step, latency), as numbers.
# Full and errors, what went wrong ("otr_errors"): counts per kind (sessions frozen or dropped, connections that
#   failed or timed out, failed updates, programs that crashed, graphics hangs, kernel errors, stops without a
#   shutdown, the checks of the hardware test that failed, firmware missing), with the exit code of FreeRDP, the name
#   of the program, of the check or of the firmware file.
# Never: the name of the device, its addresses (IP, MAC), users, domain, servers, settings or anything typed.
# Sent to PostHog in the EU (Frankfurt): each send has a random id made for it alone, no person profile, no place
# from the address; the project keeps no IP address. The project sees totals, never a device over time.
#   stats.sh          send when due (a new device that has not chosen yet: nothing)
#   stats.sh --print  print what would be sent ("event key=value", one per line), send nothing
. /opt/openthinrdp/lib/common.sh
. "$OTR/lib/netif.sh"
URL=${OTR_STATS_URL:-https://eu.i.posthog.com/batch/}
# the project key of PostHog: public, it can only send
KEY=phc_BEG5o8qxzJmJpuRfKbA9EZ6TvTy35NeDUFGWfbQx2cFx
STAMP=$OTR_LIB/stats-sent

# printable, short, no line breaks: a value as it is sent
clean(){ printf '%s' "$1" | tr -c 'A-Za-z0-9 ._()+-' ' ' | tr -s ' ' | sed 's/^ //; s/ $//' | cut -c1-60; }
yn(){ if "$@" >/dev/null 2>&1; then echo yes; else echo no; fi; }
p(){ printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }

# what the device is, in every event
base(){
  local e=$1 v m c f
  v=$(cat "$OTR/VERSION" 2>/dev/null); [ -n "$v" ] || v=unknown
  m=$(clean "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null) $(cat /sys/class/dmi/id/product_name 2>/dev/null)")
  # the vendor names that say nothing more ("To be filled by O.E.M.", "System manufacturer")
  case "$m" in ""|*"O.E.M"*|*"System manufacturer"*|*"Default string"*) m=unknown ;; esac
  c=$(clean "$(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -1)"); [ -n "$c" ] || c=$(clean "$(uname -m)")
  f=$(HOME=/root xfreerdp3 --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  p "$e" version "$v"; p "$e" freerdp "${f:-unknown}"; p "$e" model "$m"; p "$e" cpu "$c"
  p "$e" ram_gb "$(awk '/^MemTotal:/ {printf "%d", ($2 / 1048576) + 0.5}' /proc/meminfo)"
  p "$e" arch "$(otr_arch)"
  if grep -qw 'boot=live' /proc/cmdline; then p "$e" mode live; else p "$e" mode installed; fi
  p "$e" language "$(cfg LANGUAGE)"
}

# the environment and what is used (full)
environment(){
  local e=otr_week w mons=0 maxw=0 c x res dev
  p $e first "$([ -f "$STAMP" ] && echo no || echo yes)"
  p $e wifi_adapter "$(yn test -n "$(wifi_nics | head -1)")"
  p $e tpm "$(yn test -e /dev/tpmrm0 -o -e /dev/tpm0)"
  p $e managed "$(yn test -n "$(cfg MGMT_SHARE)" -o -s "$OTR_LIB/share-from-domain")"
  x=$(setup_kind); p $e setup "${x:-unset}"
  if [ -z "$(cfg BROKER)" ]; then x=none; elif [ -n "$(cfg LOAD_BALANCE_INFO)" ]; then x=broker; else x=pc; fi; p $e target "$x"
  p $e gateway "$(yn test -n "$(cfg RDP_GATEWAY)")"
  p $e vpn "$(cfg VPN)"; p $e update_from "$(cfg UPDATE_FROM)"; p $e transport "$(cfg TRANSPORT)"
  p $e remember_password "$(cfg REMEMBER_PASSWORD)"
  p $e wake_on_lan "$(yn test -n "$(cfg WAKE_MAC)" -o -n "$(ls "$OTR_LIB/wake" 2>/dev/null)")"
  p $e bluetooth_paired "$(yn test -n "$(ls -d /var/lib/bluetooth/*/??:??:??:??:??:?? 2>/dev/null)")"
  dev=$(ip -4 route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
  if [ -z "$dev" ]; then x=none; elif wifi_nics | grep -qx "$dev"; then x=wifi; else x=cable; fi; p $e network "$x"
  w=$(cfg WEB_BUTTON); [ -n "$(cfg KIOSK_URL)" ] && [ "${w:-none}" = none ] && w=kiosk; p $e web "${w:-none}"
  web_used && p $e browser "$(cfg BROWSER)"
  # the screens: how many, the class of the widest (its preferred mode), the resolution and the scale chosen
  for c in /sys/class/drm/card*-*; do
    [ "$(cat "$c/status" 2>/dev/null)" = connected ] || continue
    mons=$((mons + 1)); x=$(head -1 "$c/modes" 2>/dev/null | cut -dx -f1); [ "${x:-0}" -gt "$maxw" ] 2>/dev/null && maxw=$x
  done
  if [ "$maxw" -eq 0 ]; then res=unknown; elif [ "$maxw" -lt 1600 ]; then res=hd; elif [ "$maxw" -lt 2560 ]; then res=full-hd
  elif [ "$maxw" -lt 3840 ]; then res=qhd; else res=4k; fi
  p $e monitors "$mons"; p $e resolution_class "$res"
  if [ "$(cfg DISPLAY_RESOLUTION)" = native ]; then x=native; else x=fixed; fi; p $e resolution_setting "$x"
  p $e scale_setting "$(cfg DISPLAY_SCALE)"
  # the kinds of USB devices plugged now (the class of their interfaces), never which device
  for c in $(cat /sys/bus/usb/devices/*/bInterfaceClass 2>/dev/null | sort -u); do
    case $c in 0e) p $e usb camera ;; 0b) p $e usb smart-card ;; 01) p $e usb audio ;; 08) p $e usb storage ;; 07) p $e usb printer ;; esac
  done
  if grep -qw 'boot=live' /proc/cmdline; then p $e live_saved_settings "$(yn test -n "$(ls /run/live/persistence 2>/dev/null)")"
  else p $e alongside_windows "$(yn grep -qs 'Windows Boot Manager' /boot/grub/grub.cfg)"; fi
}

# how the device was used since $1 and how fast it was, from its event log: numbers only (medians)
usage(){
  local from; from=$(date -d "@$1" '+%Y-%m-%d %H:%M:%S')
  awk -v f="$from" 'substr($0, 1, 19) > f' "$OTR_EVENTS" 2>/dev/null | awk '
    function med(a, n,   i, j, t) { for (i = 1; i < n; i++) for (j = i; j > 0 && a[j - 1] > a[j]; j--) { t = a[j]; a[j] = a[j - 1]; a[j - 1] = t }
      return n % 2 ? a[int(n / 2)] : (a[n / 2 - 1] + a[n / 2]) / 2 }
    BEGIN { ns = 0; nl = 0; nb = 0 }
    / session of .* opened \(/ { s++; day[substr($0, 1, 10)] = 1 }
    / session quality of / {
      if (match($0, /latency [0-9.]+ ms/)) lat[nl++] = substr($0, RSTART + 8, RLENGTH - 11) + 0
      if (match($0, /kbit\/s\), [0-9]+ (s|min)/)) { split(substr($0, RSTART + 9, RLENGTH - 9), d, " "); mins += (d[2] == "min") ? d[1] : d[1] / 60 }
      if ($0 ~ /, over UDP$/) udp++; else if ($0 ~ /, over TCP$/) tcp++ }
    / sign-in of .*: [0-9.]+ s \(broker [0-9.]+ s, VM [0-9.]+ s, Windows [0-9.]+ s\)/ {
      match($0, /: [0-9.]+ s \(broker [0-9.]+ s, VM [0-9.]+ s, Windows [0-9.]+ s\)/); x = substr($0, RSTART, RLENGTH)
      gsub(/[^0-9. ]/, " ", x); k = split(x, v, " +"); j = 0
      for (i = 1; i <= k; i++) if (v[i] != "" && v[i] != ".") w[j++] = v[i] + 0
      si[ns] = w[0]; sb[ns] = w[1]; sv[ns] = w[2]; sw[ns++] = w[3] }
    / sign-in screen ready [0-9]+ s after power on/ { match($0, /ready [0-9]+ s/); bt[nb++] = substr($0, RSTART + 6, RLENGTH - 8) + 0 }
    END {
      nd = 0; for (i in day) nd++
      printf "otr_week\tsessions\t%d\notr_week\tdays_used\t%d\n", s, nd
      printf "otr_week\tsession_hours\t%.1f\n", mins / 60
      if (udp + tcp) printf "otr_week\tsessions_udp\t%d\notr_week\tsessions_tcp\t%d\n", udp, tcp
      if (nl) printf "otr_week\tlatency_ms\t%.1f\n", med(lat, nl)
      if (ns) printf "otr_week\tsignin_s\t%.1f\notr_week\tsignin_broker_s\t%.1f\notr_week\tsignin_vm_s\t%.1f\notr_week\tsignin_windows_s\t%.1f\n", med(si, ns), med(sb, ns), med(sv, ns), med(sw, ns)
      if (nb) printf "otr_week\tstart_to_signin_s\t%d\n", med(bt, nb)
    }'
}

# what went wrong since $1, one line per occurrence: a fixed kind, for FreeRDP the number of its exit code, for a crash
# the name of the program. Never the text of a message (it holds users and servers)
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
  # the hardware test run since (selftest.sh --save, by itself at the first start of a live system): which of its
  # checks failed and, among its warnings, the graphics driver and the sound card missing, by the fixed name of the
  # check; the missing firmware by the name of its file (what the image lacks). Never the details of a check
  if awk -v f="$from" 'substr($0, 1, 19) > f' "$OTR_EVENTS" 2>/dev/null | grep -q 'hardware test: '; then
    sed -nE -e 's/^- `FAIL` \*\*([^*]+)\*\*.*/hardware-test-fail \1/p' \
      -e 's/^- `WARN` \*\*(Graphics driver|Sound)\*\*.*/hardware-test-warn \1/p' "$OTR_LOG/selftest.md" 2>/dev/null |
      awk '{k = $1; $1 = ""; sub(/^ /, ""); gsub(/ /, "-"); print k, tolower($0)}'
    # "firmware: failed to load X (-2)" and "firmware load for X failed with error -2", as the kernel writes them
    sed -n 's/^- `WARN` \*\*Missing firmware\*\*: //p' "$OTR_LOG/selftest.md" 2>/dev/null | tr ';' '\n' |
      sed -nE -e 's/.*failed to load ([^ ]+).*/\1/p' -e 's/.*load for ([^ ]+).*/\1/p' | tr '/' '_' |
      tr -c 'A-Za-z0-9._+\n-' '_' | cut -c1-60 | awk 'NF {print "missing-firmware", $1}'
  fi
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

# what went wrong since $1: counts per kind, and each kind with its code or name (nothing when nothing went wrong)
errors(){
  local t a b
  problems "$1" | awk '{k[$1]++; if ($2 != "") c[$1 " " $2] = 1} END {for (i in k) print "K", k[i], i; for (i in c) print "C", i}' |
  while read -r t a b; do
    if [ "$t" = K ]; then p otr_errors "e_${b//-/_}" "$a"; else p otr_errors detail "$a $b"; fi
  done | sort
}

# everything due now at level $1: the week (full), and what went wrong (full and errors, only when something did)
all(){
  local since e
  # since the last send; the first time, the week before
  if [ -f "$STAMP" ]; then since=$(stat -c %Y "$STAMP"); else since=$(( $(date +%s) - 604800 )); fi
  e=$(errors "$since")
  if [ "$1" = full ]; then base otr_week; environment; usage "$since"; p otr_week problems "$(printf '%s\n' "$e" | grep -c "$(printf '\te_')")"; fi
  if [ -n "$e" ] && [ "$1" != off ]; then base otr_errors; printf '%s\n' "$e"; fi
}

LEVEL=$(anon_level "${OTR_STATS_ANON:-}")
if [ "${1:-}" = --print ]; then all "$LEVEL" | awk -F'\t' '{print $1 " " $2 "=" $3}'; exit 0; fi
[ "$LEVEL" = off ] && exit 0
# a new device that has not chosen yet: the first start asks (kiosk.sh), nothing leaves before the answer
[ -z "$(cfg BROKER)" ] && ! anon_decided && exit 0
# one send at a time (report.sh may start a second before the first is done), once a week
exec 9> "$OTR_LIB/stats.lock"; flock -n 9 || exit 0
[ -f "$STAMP" ] && [ $(( $(date +%s) - $(stat -c %Y "$STAMP") )) -lt 604800 ] && exit 0
D=$(all "$LEVEL")
# errors only and nothing went wrong: nothing to send, the week is checked
[ -z "$D" ] && { touch "$STAMP"; exit 0; }
# python3 is in the image, curl is not. One request with every event: sent when PostHog answers 200, else tried again
# at the next report
printf '%s\n' "$D" | python3 -c '
import json, sys, uuid, datetime, urllib.request
url, key = sys.argv[1], sys.argv[2]
sid = str(uuid.uuid4())   # this send only: never kept, taken from nothing of the device
now = datetime.datetime.now(datetime.timezone.utc).isoformat()
ev = {}
for line in sys.stdin.read().splitlines():
    e, k, v = (line.split("\t") + ["", ""])[:3]
    props = ev.setdefault(e, {"$process_person_profile": False, "$geoip_disable": True, "$lib": "openthinrdp"})
    if v.lstrip("-").isdigit():
        v = int(v)
    elif v.replace(".", "", 1).lstrip("-").isdigit():
        v = float(v)
    if k in ("usb", "detail"):
        props.setdefault(k, []).append(v)
    else:
        props[k] = v
batch = [{"event": e, "distinct_id": sid, "timestamp": now, "properties": pr} for e, pr in ev.items()]
req = urllib.request.Request(url, data=json.dumps({"api_key": key, "batch": batch}).encode(),
                             headers={"Content-Type": "application/json", "User-Agent": "OpenThinRDP"})
try:
    with urllib.request.urlopen(req, timeout=15) as r:
        sys.exit(0 if r.status == 200 else 1)
except Exception:
    sys.exit(1)' "$URL" "$KEY" 2>/dev/null && touch "$STAMP"
exit 0
