#!/bin/bash
# The diagnostics of this device in one file, for the administrator (and, if they choose, for the project):
#   diag-bundle.sh REASON     REASON = requested (from the manager), device (the button of the diagnostics screen),
#                             watchdog (a frozen session ended by the kiosk), power-off (switched off in a session)
# Writes $OTR_LIB/diag/<hostname>-<date>-<reason>.tar.gz (the 3 newest are kept) and prints its path; report.sh
# copies it to diag\ of the management folder. Nothing leaves the device by itself otherwise.
# Inside: the events, the log of the last session and of the frozen ones, the status, the journal of this start and
# of the one before, the kernel, the update logs, the network, the hardware, and the settings WITHOUT their secrets
# (passwords, Wi-Fi keys, PIN, private keys are removed; smb.cred, the Wi-Fi and 802.1X files and the keys are never
# taken). User and server names stay: the administrator sees the file before sending it anywhere.
# An automatic one (watchdog, power-off) at most once an hour.
. /opt/openthinrdp/lib/common.sh
R=${1:-requested}; [[ $R =~ ^[a-z-]{1,20}$ ]] || R=requested
D=$OTR_LIB/diag; mkdir -p "$D"; chmod 700 "$D"
if [ "$R" = watchdog ] || [ "$R" = power-off ]; then
  [ -n "$(find "$D" -maxdepth 1 -name "*-$R.tar.gz" -mmin -60 2>/dev/null | head -1)" ] && exit 0
fi
H=$(hostname); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# a setting with a secret in its name: its value removed
redact(){ sed -E 's/^([A-Z0-9_]*(PASSWORD|PSK|PIN|SECRET|PRIVATE|TOKEN)[A-Z0-9_]*)=.*/\1=(removed)/'; }
{
  echo "OpenThinRDP diagnostics: $H, $(date '+%Y-%m-%d %H:%M:%S %Z'), reason: $R"
  echo "OpenThinRDP $(cat "$OTR/VERSION" 2>/dev/null), update installed: $(cat "$OTR_LIB/update-version" 2>/dev/null || echo none)"
  echo "FreeRDP $(xfreerdp3 --version 2>/dev/null | head -1 | grep -oE '[0-9][^ ]*' | head -1)"
  echo "Computer $(cat /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name 2>/dev/null | tr '\n' ' ')"
  echo "Kernel $(uname -r), up $(uptime -p 2>/dev/null)"
  grep -qw 'boot=live' /proc/cmdline && echo "Live system" || echo "Installed"
} > "$T/summary.txt"
for f in "$OTR_EVENTS" "$OTR_LOG/session-hang.log" "$OTR_LOG/last-session.log" "$OTR_LIB/update/status" /run/openthinrdp-status.txt; do
  [ -s "$f" ] && tail -c 3000000 "$f" > "$T/$(basename "$f")"
done
[ -s /tmp/kiosk.log ] && tail -c 3000000 /tmp/kiosk.log > "$T/kiosk-session-now.log"
for f in $(ls -t "$OTR_LOG"/update-*.log 2>/dev/null | head -2); do tail -c 500000 "$f" > "$T/$(basename "$f")"; done
journalctl -b 0 -q --no-pager -o short-iso 2>/dev/null | tail -n 5000 > "$T/journal-this-start.txt"
journalctl -b -1 -q --no-pager -o short-iso 2>/dev/null | tail -n 5000 > "$T/journal-previous-start.txt"
journalctl -k -b 0 -q --no-pager -o short-iso 2>/dev/null | tail -n 2000 > "$T/kernel.txt"
{ echo "== addresses"; ip -br addr 2>/dev/null; echo "== routes"; ip route 2>/dev/null; echo "== DNS"; grep -v '^#' /etc/resolv.conf 2>/dev/null
  echo "== sockets"; ss -tunpH 2>/dev/null | head -50; } > "$T/network.txt"
{ echo "== failed units"; systemctl --failed --no-legend 2>/dev/null; echo "== memory"; free -m; echo "== disks"; df -h 2>/dev/null
  echo "== USB"; lsusb 2>/dev/null; echo "== PCI"; lspci -nn 2>/dev/null; } > "$T/system.txt"
{ for f in "$OTR_CONF" "$OTR_SITE" "$OTR_LIB"/central-*.conf; do [ -f "$f" ] && { echo "== $f"; redact < "$f"; }; done; } > "$T/settings.txt"
N="$H-$(date '+%Y%m%d-%H%M%S')-$R.tar.gz"
tar -czf "$D/$N.part" -C "$T" . && mv -f "$D/$N.part" "$D/$N" || { rm -f "$D/$N.part"; exit 1; }
chmod 600 "$D/$N"
# the 3 newest stay
ls -t "$D"/*.tar.gz 2>/dev/null | tail -n +4 | xargs -r rm -f
ev "diagnostics collected ($R): $N"
echo "$D/$N"
