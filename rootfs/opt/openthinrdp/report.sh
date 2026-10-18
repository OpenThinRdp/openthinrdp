#!/bin/bash
# Status of this device in the management folder (MGMT_SHARE), and everything that comes back from it.
# Runs as root every 5 minutes, at boot and at every new event (openthinrdp-report.timer / .path).
#   status\<hostname>.txt          status (KEY=value) + last errors and events
#   status\<hostname>-events.log   event log
#   status\SUMMARY.csv             one line per device, rewritten by whoever reports
#   config\common.conf, config\<hostname>.conf, config\authorized_keys   central settings (central-apply.sh)
#   config\branding\, config\branding\<hostname>\   logo and background picture (branding.sh)
#   updates\                       signed updates (auto-update.sh)
. /opt/openthinrdp/lib/common.sh
. "$OTR/lib/netif.sh"
. "$OTR/lib/secrets.sh"
CRED=$(secret_path smb.cred)
LOG=$OTR_LOG/report.log
OUT=/run/openthinrdp-status.txt
MNT=/run/openthinrdp-share
mkdir -p "$OTR_LOG" "$OTR_LIB"

H=$(hostname)
IF=$(main_nic)
# the VPN first: outside the office the management folder is reached through it
[ "$(cfg VPN)" != off ] && "$OTR/vpn.sh" check
RS=$(cfg MGMT_SHARE); SHARE=$(echo "$RS" | tr '\\' '/')
IPC=$(ip -4 -o addr show dev "$IF" 2>/dev/null | awk '{print $4}' | head -1)
# only an xfreerdp3 with /u: is a session (the kiosk also runs "xfreerdp3 --version")
SU=""; for P in $(pgrep -x xfreerdp3); do
  SU=$(tr '\0' '\n' < "/proc/$P/cmdline" 2>/dev/null | sed -n 's#^/u:##p' | head -1); [ -n "$SU" ] && break; done
CAM=$(udevadm info -q property -n /dev/video0 2>/dev/null | awk -F= '/^ID_VENDOR_ID=/{v=$2} /^ID_MODEL_ID=/{m=$2} END{if(v) print v":"m}')
MON=$(for c in /sys/class/drm/card*-*; do [ "$(cat "$c/status" 2>/dev/null)" = connected ] && printf '%s %s  ' "$(basename "$c" | cut -d- -f2-)" "$(head -1 "$c/modes")"; done)
TEMP=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -n | tail -1)
FAILED=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
NERR=$(journalctl -b -p err --no-pager -q 2>/dev/null | wc -l)
INUSE="no session"; [ -n "$SU" ] && { ss -uanp 2>/dev/null | grep -q xfreerdp3 && INUSE=udp || INUSE=tcp; }
# as a service there is no HOME, and without it xfreerdp3 prints nothing ("KNOWN_PATH_HOME is nullptr")
HOME=${HOME:-/root} xfreerdp3 --buildconfig 2>/dev/null | grep -q 'WITH_RDPEUDP=ON' || INUSE="$INUSE, FreeRDP without UDP"

{
  echo "UPDATED=$(date '+%Y-%m-%d %H:%M:%S')"
  echo "HOSTNAME=$H"
  echo "IP=${IPC:-none}"
  echo "MAC=$(cat "/sys/class/net/$IF/address" 2>/dev/null)"
  echo "NIC=$IF"
  echo "NETWORK=$(cfg NETMODE)"
  echo "GATEWAY=$(ip -4 route show default 2>/dev/null | awk '{print $3}' | head -1)"
  echo "DNS=$(awk '/^nameserver/{printf "%s ", $2}' /etc/resolv.conf)"
  echo "DEFAULT_USER=$(cfg DEFAULT_USER)"
  echo "SESSION=$([ -n "$SU" ] && echo "active ($SU)" || echo none)"
  echo "TRANSPORT=$(cfg TRANSPORT) (in use: $INUSE)"
  echo "TIME_SYNC=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)"
  echo "UPTIME=$(uptime -p | sed 's/^up //')"
  echo "BOOT_TIME=$(systemd-analyze 2>/dev/null | head -1 | sed 's/.*= //')"
  echo "MONITORS=${MON:-none}"
  echo "WEBCAM=${CAM:-none}"
  echo "USB=$(for d in /sys/bus/usb/devices/[0-9]*-[0-9]*; do [ -f "$d/idVendor" ] && [ "$(cat "$d/bDeviceClass")" != 09 ] && printf '%s:%s %s; ' "$(cat "$d/idVendor")" "$(cat "$d/idProduct")" "$(cat "$d/product" 2>/dev/null)"; done)"
  echo "TEMPERATURE=$(( ${TEMP:-0} / 1000 )) C"
  echo "DISK_FREE=$(df -h / | awk 'NR==2{print $4}')"
  echo "RAM=$(free -m | awk '/^Mem/{print $3" / "$2" MB"}')"
  echo "FAILED_UNITS=${FAILED:-none}"
  echo "SYSTEM_ERRORS=$NERR"
  echo "FREERDP=$(dpkg-query -W -f '${Version}' libfreerdp-client3-3 2>/dev/null)"
  echo "SOFTWARE=$(cat "$OTR/VERSION" 2>/dev/null)"
  echo "UPDATE_VERSION=$(cat "$OTR_LIB/update-version" 2>/dev/null || echo none)"
  echo "CENTRAL_CONFIG=$(cat "$OTR_LIB/central-status" 2>/dev/null || echo 'never read')"
  echo "UPDATE_FROM=$(cfg UPDATE_FROM)"
  # which signatures the updates from the folder need, and the site key this device has (its fingerprint): the
  # manager shows which devices have not got the site key yet
  echo "UPDATE_KEY=$(cfg UPDATE_KEY)"
  echo "UPDATE_TO=$(cfg UPDATE_TO)"
  echo "SITE_KEY=$(key_fingerprint "$OTR_ETC/update-key.asc" 2>/dev/null || echo none)"
  # the VPN: its state, and the WireGuard public key to add as a peer on the server (never the private one)
  echo "VPN=$("$OTR/vpn.sh" status 2>/dev/null)"
  [ "$(cfg VPN)" = wireguard ] && echo "VPN_PUBLIC_KEY=$("$OTR/vpn.sh" pubkey 2>/dev/null)"
  # 802.1X on the cable, adapter by adapter: authenticated, failed (why), no authenticator, incomplete, or off
  echo "DOT1X=$("$OTR/dot1x.sh" status 2>/dev/null)"
  # the account of the management folder (never the password): the manager checks what it may write there
  MA=$(sed -n 's/^username=//p' "$CRED" 2>/dev/null | head -1); MD=$(sed -n 's/^domain=//p' "$CRED" 2>/dev/null | head -1)
  case "$MA" in *\\*|*@*) MD="" ;; esac
  echo "MGMT_ACCOUNT=${MD:+$MD\\}${MA:-none}"
  # logo and background picture: image = the image's own, common = config\branding\, device = config\branding\<hostname>\
  BRS=$(tr '\n' ' ' < "$OTR_LIB/branding/source" 2>/dev/null); BRS=${BRS% }
  echo "BRANDING=${BRS:-logo=image splash=image}"
  # status of the software updates, whatever the source (the name is kept for the manager)
  echo "SHARE_UPDATE=$(cat "$OTR_LIB/update/status" 2>/dev/null || echo 'never checked')"
  # last real unattended-upgrade run (dry runs discarded) and last run that installed something
  UL=/var/log/unattended-upgrades/unattended-upgrades.log; UU=""
  [ -f $UL ] && UU=$(awk 'function close_run(){ if(t!=""&&v){c=t; if(n)a=t" ("n" packages)"} }
              /Starting unattended upgrades script/{close_run(); t=$1" "substr($2,1,8); v=1; n=0; next}
              /dry-run/{v=0}
              /Packages that will be upgraded:/{n=NF-8}
              END{close_run(); print (c?c:"never") "|" (a?a:"never")}' $UL)
  echo "SECURITY_UPDATES=$(cfg SECURITY_UPDATES)"
  # where the folder password, the Wi-Fi key and the SSH host keys are kept: tpm, or file (no TPM)
  echo "SECRETS=$(secret_mode)"
  echo "LAST_UPDATE_CHECK=${UU%%|*}" | sed 's/=$/=never/'
  echo "LAST_UPDATE=${UU#*|}" | sed 's/=$/=never/'
  echo "REBOOT_REQUIRED=$([ -f /run/reboot-required ] && echo yes || echo no)"
  # Wi-Fi (the key never leaves the device: only network, signal, address)
  # (Enterprise: the method, and what is missing while it cannot connect)
  WLI=$(wifi_nics | head -1); WSEC=$(cfg WIFI_SECURITY); WE=""
  case "$WSEC" in peap|tls) . "$OTR/lib/eap.sh"; WE=" (802.1X $(echo "$WSEC" | tr a-z A-Z)$(eap_warning | sed 's/^/, /'))" ;; esac
  if [ -z "$WLI" ]; then echo "WIFI_STATUS=no adapter"
  elif iw dev "$WLI" link 2>/dev/null | grep -q Connected; then
    L=$(iw dev "$WLI" link)
    echo "WIFI_STATUS=connected to $(echo "$L" | sed -n 's/^[[:space:]]*SSID: //p')$WE, signal $(echo "$L" | sed -n 's/^[[:space:]]*signal: //p'), IP $(ip -4 -o addr show dev "$WLI" | awk '{print $4}')"
  elif [ "$(cfg WIFI)" = on ]; then
    WM=""; [ -n "$WE" ] && WM=$(eap_missing "$WSEC")
    echo "WIFI_STATUS=on but NOT connected ($(cfg WIFI_SSID))$WE${WM:+: 802.1X settings incomplete, $WM}"
  else echo "WIFI_STATUS=off"; fi
  SVA=$(cat /sys/class/rtc/rtc0/wakealarm 2>/dev/null)
  echo "NEXT_POWER_ON=$([ -n "$SVA" ] && date -d "@$SVA" '+%a %d/%m %H:%M' || echo none)"
  # effective settings, for the management tool: CFG_<KEY>=value. Never the Wi-Fi key; the PIN only as
  # "(set)": the folder is readable by many and the hash of a short PIN is reversed in no time
  for k in $(cfg_keys); do
    case $k in
      HOSTNAME) ;;
      SETTINGS_PIN_SHA256) echo "CFG_$k=$([ -n "$(cfg $k)" ] && echo '(set)')" ;;
      *) echo "CFG_$k=$(cfg "$k")" ;;
    esac
  done
  echo
  echo "--- last system errors (current boot)"
  journalctl -b -p err --no-pager -q -o short 2>/dev/null | tail -5
  echo
  echo "--- last events"
  tail -n 15 "$OTR_EVENTS" 2>/dev/null
} > "$OUT"

# event log: keep the last 2000 lines
if [ -f "$OTR_EVENTS" ] && [ "$(wc -l < "$OTR_EVENTS")" -gt 3000 ]; then
  tail -n 2000 "$OTR_EVENTS" > "$OTR_EVENTS.tmp" && cat "$OTR_EVENTS.tmp" > "$OTR_EVENTS" && rm -f "$OTR_EVENTS.tmp"
fi

if [ -z "$RS" ]; then echo "$(date '+%F %T') no management folder: status only in $OUT" > "$LOG"
elif [ ! -f "$CRED" ]; then echo "$(date '+%F %T') no credentials in $CRED: status only in $OUT" > "$LOG"
else
  mkdir -p "$MNT"
  mountpoint -q "$MNT" || timeout 20 mount -t cifs "$SHARE" "$MNT" \
    -o "credentials=$CRED,vers=3.0,sec=ntlmssp,noperm,file_mode=0644,dir_mode=0755,iocharset=utf8" 2>>"$LOG"
  if mountpoint -q "$MNT"; then
    mkdir -p "$MNT/status" 2>/dev/null
    # renamed from the settings: remove the files with the old name
    OLD=$(cat "$OTR_LIB/share-name" 2>/dev/null)
    [ -n "$OLD" ] && [ "$OLD" != "$H" ] && rm -f "$MNT/status/$OLD.txt" "$MNT/status/$OLD-events.log"
    cp "$OUT" "$MNT/status/$H.txt" && { [ -f "$OTR_EVENTS" ] && cp "$OTR_EVENTS" "$MNT/status/$H-events.log"; echo "$H" > "$OTR_LIB/share-name"
      echo "$(date '+%F %T') sent to $RS" > "$LOG"; }
    # central settings: config\common.conf and config\<hostname>.conf -> local copy (= last good one).
    # If the folder answers and a file is gone, those keys are no longer managed centrally.
    for p in "common:common.conf" "host:$H.conf"; do
      n=${p%%:*}; f=${p#*:}
      if [ -f "$MNT/config/$f" ]; then
        # 600: they may contain the Wi-Fi key
        ( umask 077; cp "$MNT/config/$f" "$OTR_LIB/central-$n.conf.new" ) && mv -f "$OTR_LIB/central-$n.conf.new" "$OTR_LIB/central-$n.conf"
      else rm -f "$OTR_LIB/central-$n.conf"; fi
    done
    # SSH keys of the administrators: config\authorized_keys, only well-formed public key lines.
    # Removed from the folder after being used = keys revoked: back to the keys built into the image,
    # kept aside the first time.
    [ -f "$OTR_LIB/authorized_keys.image" ] || { cp "$OTR_ETC/authorized_keys" "$OTR_LIB/authorized_keys.image" 2>/dev/null || : > "$OTR_LIB/authorized_keys.image"; }
    if [ ! -f "$MNT/config/authorized_keys" ] && [ -f "$OTR_LIB/authorized_keys.central" ]; then
      install -m644 "$OTR_LIB/authorized_keys.image" "$OTR_ETC/authorized_keys"
      mv -f "$OTR_LIB/authorized_keys.central" "$OTR_LIB/authorized_keys.central.old"
      ev "SSH keys of the management folder removed: back to the keys of the image"; "$OTR/apply.sh" now
    fi
    if [ -f "$MNT/config/authorized_keys" ]; then
      touch "$OTR_LIB/authorized_keys.central"
      sed '1s/^\xEF\xBB\xBF//' "$MNT/config/authorized_keys" | tr -d '\r' | grep -E '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com) [A-Za-z0-9+/=]+( .*)?$' > "$OTR_LIB/authorized_keys.new"
      if ! cmp -s "$OTR_LIB/authorized_keys.new" "$OTR_ETC/authorized_keys"; then
        install -m644 "$OTR_LIB/authorized_keys.new" "$OTR_ETC/authorized_keys"; ev "SSH keys updated from the management folder ($(wc -l < "$OTR_ETC/authorized_keys"))"
        "$OTR/apply.sh" now
      fi
      rm -f "$OTR_LIB/authorized_keys.new"
    fi
    "$OTR/branding.sh" sync "$MNT"
    # status\SUMMARY.csv: one line per device, rewritten by whoever reports (atomic write). In status\ because
    # that is the only folder the devices need to write to (docs/management.md#account)
    NOW=$(date +%s)
    {
      printf '\xEF\xBB\xBF'
      echo "STATE;HOSTNAME;IP;MAC;NETWORK;DEFAULT_USER;SESSION;UPDATED;TIME_SYNC;MONITORS;FAILED_UNITS;SOFTWARE;FREERDP;CENTRAL_CONFIG"
      for f in "$MNT"/status/*.txt; do
        [ -f "$f" ] || continue
        g(){ sed -n "s/^$1=//p" "$f" | head -1 | tr -d '\r;'; }
        A=$(g UPDATED); T=$(date -d "$A" +%s 2>/dev/null || echo 0); MIN=$(( (NOW - T) / 60 ))
        FS=$(g FAILED_UNITS)
        if [ $MIN -gt 15 ]; then S="NOT UPDATED for $MIN min (off or offline)"
        elif [ -n "$FS" ] && [ "$FS" != none ]; then S="FAILED units"
        else S="ok"; fi
        echo "$S;$(g HOSTNAME);$(g IP);$(g MAC);$(g NETWORK);$(g DEFAULT_USER);$(g SESSION);$A;$(g TIME_SYNC);$(g MONITORS);$FS;$(g SOFTWARE);$(g FREERDP);$(g CENTRAL_CONFIG)"
      done
    } > "$MNT/status/.SUMMARY.$H.tmp" && mv -f "$MNT/status/.SUMMARY.$H.tmp" "$MNT/status/SUMMARY.csv"
    # sessions open on the OTHER devices, for the "already active" warning of the kiosk:
    # user (lowercase, no domain)|hostname|IP, only from reports sent in the last 10 minutes (a device
    # switched off abruptly does not block anybody). The kiosk reads it locally: no wait for the share.
    for f in "$MNT"/status/*.txt; do
      [ -f "$f" ] || continue
      g(){ sed -n "s/^$1=//p" "$f" | head -1 | tr -d '\r'; }
      [ "$(g HOSTNAME)" = "$H" ] && continue
      T=$(date -d "$(g UPDATED)" +%s 2>/dev/null || echo 0); [ $(( (NOW - T) / 60 )) -le 10 ] || continue
      u=$(g SESSION | sed -n 's/^active (\(.*\))$/\1/p' | tr 'A-Z' 'a-z' | sed 's/^.*\\//; s/@.*//')
      [ -n "$u" ] && echo "$u|$(g HOSTNAME)|$(g IP | cut -d/ -f1)"
    done > "$OTR_LIB/sessions-elsewhere.new" && chmod 644 "$OTR_LIB/sessions-elsewhere.new" &&
      mv -f "$OTR_LIB/sessions-elsewhere.new" "$OTR_LIB/sessions-elsewhere"
    # signed updates in updates\ (copied now, while the folder is mounted; the install runs in the background)
    [ "$(cfg UPDATE_FROM)" = share ] && "$OTR/auto-update.sh" check "$MNT"
    umount "$MNT"
  else
    echo "$(date '+%F %T') ERROR: management folder $SHARE not reachable" >> "$LOG"
  fi
fi
# software updates from GitHub (asked at most every 3 hours), or none
case "$(cfg UPDATE_FROM)" in
  github) "$OTR/auto-update.sh" check-github ;;
  off)    mkdir -p "$OTR_LIB/update"; echo "software updates off (UPDATE_FROM=off)" > "$OTR_LIB/update/status" ;;
esac
# apply the central settings (also when the folder does not answer: the last good copy is used). Not while an
# update is installing: with half the files new and half old, a valid setting was rejected (13/10/2026, "colour
# not valid: BG_BOTTOM" three seconds into 0.1.6); the next run, at most 5 minutes later, applies it.
systemctl is-active -q openthinrdp-update.service 2>/dev/null || "$OTR/central-apply.sh"
# boot splash: always the image's own (a device that took the folder's picture there with 0.1.1 gets it back)
"$OTR/branding.sh" splash
exit 0
