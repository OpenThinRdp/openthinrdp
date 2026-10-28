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
RS=$(cfg MGMT_SHARE)
# No folder in the settings, only the domain account (#82): the folder named for that account in the domain. The
# manager writes \\<domain>\NETLOGON\OpenThinRDP\folders.conf (lines <account>=<folder>): NETLOGON is on every DC and
# every domain account reads it, over the SMB the device uses anyway (no LDAP, which signing or a missing LDAPS
# certificate would refuse). The last folder found is kept for when no DC answers; a moved folder is followed.
FROMDOM=$OTR_LIB/share-from-domain
share_from_domain(){
  local dom acc m s
  dom=$(cfg DOMAIN); [[ $dom == *.* ]] || dom=$(sed -n 's/^domain=//p' "$CRED" 2>/dev/null | head -1)
  acc=$(sed -n 's/^username=//p' "$CRED" 2>/dev/null | head -1 | tr 'A-Z' 'a-z')
  [[ $dom =~ ^[A-Za-z0-9.-]+\.[A-Za-z0-9-]+$ ]] && [ -n "$acc" ] || return 0
  m=$(mktemp -d)
  if timeout 20 mount -t cifs "//$dom/NETLOGON" "$m" -o "ro,credentials=$CRED,vers=3.0,sec=ntlmssp,iocharset=utf8" 2>>"$LOG"; then
    s=$(tr -d '\r' < "$m/OpenThinRDP/folders.conf" 2>/dev/null | awk -v a="$acc" '
      /^[ \t]*[#;]/ || index($0, "=") == 0 { next }
      { k = tolower(substr($0, 1, index($0, "=") - 1)); v = substr($0, index($0, "=") + 1)
        gsub(/^[ \t]+|[ \t]+$/, "", k); gsub(/^[ \t]+|[ \t]+$/, "", v); if (k == a) f = v }
      END { print f }')
    umount "$m"
    if [[ $s =~ ^(\\\\|//)[A-Za-z0-9.-]+[\\/][A-Za-z0-9\ ._\$\\/-]+$ ]] && [ "$s" != "$(cat "$FROMDOM" 2>/dev/null)" ]; then
      echo "$s" > "$FROMDOM"; ev "management folder from the domain ($acc): $s"
    fi
  fi
  rmdir "$m" 2>/dev/null
}
if [ -z "$RS" ] && [ -f "$CRED" ]; then share_from_domain; RS=$(cat "$FROMDOM" 2>/dev/null); fi
SHARE=$(echo "$RS" | tr '\\' '/')
IPC=$(nic_ipv4 "$IF")
# no address on the main adapter: the one of the default route (the device is reachable there)
if [ -z "$IPC" ]; then R=$(route_nic); [ -n "$R" ] && IPC=$(nic_ipv4 "$R") && [ -n "$IPC" ] && IF=$R; fi
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
  # the same moment in UTC: the manager may be in another time zone than the device (the ISO is built with Etc/UTC)
  echo "UPDATED_UTC=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
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
  # the peripherals by kind, for the manager (the device page, and the notice when a required one is gone):
  # <kind> <vendor:product> <name>; kind from the class of the device or of its first interface
  echo "PERIPHERALS=$(for d in /sys/bus/usb/devices/[0-9]*-[0-9]*; do [ -f "$d/idVendor" ] || continue
    c=$(cat "$d/bDeviceClass"); [ "$c" = 09 ] && continue; [ "$c" = 00 ] || [ "$c" = ef ] && c=$(cat "$d"/*:1.0/bInterfaceClass 2>/dev/null | head -1)
    case "$c" in 07) k=printer ;; 0e) k=camera ;; 01) k=audio ;; 08) k=storage ;; 0b) k=smartcard ;; 02|0a) k=serial ;; 03) k=input ;; e0) k=wireless ;; ff) k=serial ;; *) k=other ;; esac
    [ "$c" = ff ] && ! ls -d "$d"/*:1.0/ttyUSB* >/dev/null 2>&1 && k=other
    printf '%s %s:%s %s; ' "$k" "$(cat "$d/idVendor")" "$(cat "$d/idProduct")" "$(cat "$d/product" 2>/dev/null | tr -d ';')"; done)"
  # the hardware, for the inventory of the manager (the serial number only root reads)
  echo "HW_MODEL=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null) $(cat /sys/class/dmi/id/product_name 2>/dev/null)"
  echo "HW_SERIAL=$(cat /sys/class/dmi/id/product_serial 2>/dev/null)"
  echo "BIOS=$(cat /sys/class/dmi/id/bios_version 2>/dev/null) $(cat /sys/class/dmi/id/bios_date 2>/dev/null)"
  # the session now (kiosk.sh writes it every ~5 s): latency and what comes in
  Q=($(cat /tmp/kiosk.quality 2>/dev/null)); [ -n "$SU" ] && [ "${Q[0]:-0}" -gt 0 ] && echo "SESSION_QUALITY=$(( Q[1] / Q[0] / 10 )).$(( Q[1] / Q[0] % 10 )) ms $(( (Q[4] - Q[3]) * 8 / 1000 / (Q[6] > 0 ? Q[6] : 1) )) kbit/s"
  # the scheduled jobs (schedule.sh): <id>=<result> <when>, the last of each
  echo "JOBS=$(tr '\n' ' ' < "$OTR_LIB/jobs-last" 2>/dev/null)"
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
  echo "GROUP=$(cat "$OTR_LIB/central-group-name" 2>/dev/null)"
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
  echo "ANON_STATS=$(cfg ANON_STATS)"
  echo "REPORT_INTERVAL=$(cfg_num REPORT_INTERVAL 5)"
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
    # diagnostics (diag-bundle.sh): asked by the manager (diag\<hostname>.request newer than the last one answered),
    # then every file waiting here goes to diag\ of the folder (the 3 last sent stay on the device)
    if [ -f "$MNT/diag/$H.request" ] && [ "$MNT/diag/$H.request" -nt "$OTR_LIB/diag-request-done" ]; then
      touch "$OTR_LIB/diag-request-done"; "$OTR/diag-bundle.sh" requested >/dev/null 2>&1
    fi
    for f in "$OTR_LIB"/diag/*.tar.gz; do
      [ -f "$f" ] || continue
      mkdir -p "$MNT/diag" "$OTR_LIB/diag/sent" 2>/dev/null
      if cp "$f" "$MNT/diag/" 2>/dev/null; then
        mv -f "$f" "$OTR_LIB/diag/sent/"; ls -t "$OTR_LIB"/diag/sent/*.tar.gz 2>/dev/null | tail -n +4 | xargs -r rm -f
        ev "diagnostics in the management folder: diag\\$(basename "$f")"
      fi
    done
    # central settings -> local copies (= last good ones). If the folder answers and a file is gone, those keys are no
    # longer managed centrally. Groups are folders: config\groups\<group>\_group.conf (the settings of the group) and
    # the files of its devices, config\groups\<group>\<hostname>.conf; moving the file of a device to another folder
    # moves it to that group. A device whose file is not in a group folder: its DEVICE_GROUP, else the group named as
    # the account of the management folder, when that folder exists; its own file then in config\<hostname>.conf.
    # Signed central configuration (CONFIG_SIGNED=required, from a signed common.conf): every file needs its .sig, made
    # by the manager with the key of the site this device has (update-key.asc). One without, or with a wrong one, is
    # not taken: its last good copy stays, said once. A missing file does not release its settings either, so deleting
    # a file is no way around the signature: only a signed file changes the settings.
    SIGNED=0; [ "$(cfg CONFIG_SIGNED)" = required ] && SIGNED=1; SK=$OTR_ETC/update-key.asc
    signed_ok(){ [ $SIGNED = 0 ] && return 0; [ -s "$SK" ] && [ -f "$1.sig" ] || return 1
      if command -v sqv >/dev/null; then sqv --keyring "$SK" "$1.sig" "$1" >/dev/null 2>&1; else gpgv --keyring "$SK" "$1.sig" "$1" >/dev/null 2>&1; fi; }
    unsigned(){ local m; m=$OTR_LIB/unsigned-$(printf '%s' "$1" | md5sum | cut -c1-8)
      if [ "$2" = ok ]; then rm -f "$m"; return 0; fi
      [ -f "$m" ] || { ev "central configuration: $1 is not signed with the site key: not taken, the last good settings stay"; touch "$m"; }; }
    HF=$(ls "$MNT"/config/groups/*/"$H.conf" 2>/dev/null | head -1)
    if [ -n "$HF" ]; then G=$(basename "$(dirname "$HF")")
    else HF=$MNT/config/$H.conf; G=$(cfg DEVICE_GROUP)
      [ -n "$G" ] || G=$(sed -n 's/^username=//p' "$CRED" 2>/dev/null | head -1 | tr 'A-Z' 'a-z'); fi
    GF=""; [[ $G =~ ^[A-Za-z0-9._-]{1,64}$ ]] && [ -f "$MNT/config/groups/$G/_group.conf" ] && GF=$MNT/config/groups/$G/_group.conf
    for p in "common:$MNT/config/common.conf" "group:$GF" "host:$HF"; do
      n=${p%%:*}; f=${p#*:}
      if [ -n "$f" ] && [ -f "$f" ] && ! signed_ok "$f"; then unsigned "${f#$MNT/}"
      elif [ -n "$f" ] && [ -f "$f" ]; then
        unsigned "${f#$MNT/}" ok
        # 600: they may contain the Wi-Fi key
        ( umask 077; cp "$f" "$OTR_LIB/central-$n.conf.new" ) && mv -f "$OTR_LIB/central-$n.conf.new" "$OTR_LIB/central-$n.conf"
        [ $n = host ] && rm -f "$OTR_LIB/central-host.missing"
      elif [ $SIGNED = 1 ] && [ -f "$OTR_LIB/central-$n.conf" ]; then :
      elif [ $n = host ] && [ -f "$OTR_LIB/central-host.conf" ]; then
        # The file of this device was there and is not any more (moved by hand, a folder copied in part, a group
        # this version did not know): its last settings stay, said once. No exceptions any more = an EMPTY file
        # (the manager writes one): never a missing one, which lost a default user and a kiosk on 21/10.
        [ -f "$OTR_LIB/central-host.missing" ] || { ev "central configuration: no file of this device in the folder ($H.conf), its last settings kept"; touch "$OTR_LIB/central-host.missing"; }
      else rm -f "$OTR_LIB/central-$n.conf"; fi
    done
    # scheduled jobs (config\jobs.conf, schedule.sh runs them): signed as the settings are; gone from the folder = none
    JF=$MNT/config/jobs.conf
    if [ -f "$JF" ] && ! signed_ok "$JF"; then unsigned config/jobs.conf
    elif [ -f "$JF" ]; then unsigned config/jobs.conf ok; cp "$JF" "$OTR_LIB/jobs.conf.new" && mv -f "$OTR_LIB/jobs.conf.new" "$OTR_LIB/jobs.conf"
    elif [ $SIGNED = 0 ]; then rm -f "$OTR_LIB/jobs.conf"; fi
    # the certificates of the CAs the manager sends (config\ca\*.crt, Security > Enterprise CA; signed as the
    # settings): into the trust store of the system next to the ones of the image, as $OTR_ETC/ca/mgmt-*.crt, for
    # RDP_CERT=verify, 802.1X and the kiosk browser; gone from the folder = gone from the device
    CANEW=""; for c in "$MNT"/config/ca/*.crt; do [ -f "$c" ] || continue
      if ! signed_ok "$c"; then unsigned "config/ca/${c##*/}"; continue; fi; unsigned "config/ca/${c##*/}" ok
      openssl x509 -in "$c" -noout 2>/dev/null && CANEW="$CANEW $c"; done
    CAH=$(for c in $CANEW; do sha256sum < "$c"; done | sha256sum | cut -c1-64)
    if [ "$CAH" != "$(cat "$OTR_LIB/central-ca.hash" 2>/dev/null)" ]; then
      mkdir -p "$OTR_ETC/ca"; rm -f "$OTR_ETC"/ca/mgmt-*.crt
      for c in $CANEW; do cp "$c" "$OTR_ETC/ca/mgmt-${c##*/}"; done
      CAD=/usr/local/share/ca-certificates/openthinrdp; mkdir -p $CAD; rm -f $CAD/*.crt; cp "$OTR_ETC"/ca/*.crt $CAD/ 2>/dev/null
      update-ca-certificates --fresh >/dev/null 2>&1 && ev "certificate authorities of the site: $(ls $CAD/*.crt 2>/dev/null | wc -l) in the system trust store ($(echo $CANEW | wc -w) from the manager)"
      echo "$CAH" > "$OTR_LIB/central-ca.hash"
    fi
    if [ -n "$GF" ] || [[ $HF == */groups/* ]]; then echo "$G" > "$OTR_LIB/central-group-name"; else rm -f "$OTR_LIB/central-group-name"; fi
    # SSH keys of the administrators: config\authorized_keys, only well-formed public key lines.
    # Removed from the folder after being used = keys revoked: back to the keys built into the image,
    # kept aside the first time.
    [ -f "$OTR_LIB/authorized_keys.image" ] || { cp "$OTR_ETC/authorized_keys" "$OTR_LIB/authorized_keys.image" 2>/dev/null || : > "$OTR_LIB/authorized_keys.image"; }
    if [ ! -f "$MNT/config/authorized_keys" ] && [ -f "$OTR_LIB/authorized_keys.central" ] && [ $SIGNED = 0 ]; then
      install -m644 "$OTR_LIB/authorized_keys.image" "$OTR_ETC/authorized_keys"
      mv -f "$OTR_LIB/authorized_keys.central" "$OTR_LIB/authorized_keys.central.old"
      ev "SSH keys of the management folder removed: back to the keys of the image"; "$OTR/apply.sh" now
    fi
    if [ -f "$MNT/config/authorized_keys" ] && ! signed_ok "$MNT/config/authorized_keys"; then unsigned config/authorized_keys
    elif [ -f "$MNT/config/authorized_keys" ]; then
      unsigned config/authorized_keys ok
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
# The anonymous counts in a unit of their own: this script runs as a oneshot service, and when it ends systemd stops
# every process it started (KillMode=control-group), so counts started in the background never got out, on any
# device (28/10/2026). Without systemd (tests, a container) in the background as before. $1: the setting decided now
stats_start(){
  if [ -d /run/systemd/system ] && command -v systemd-run >/dev/null 2>&1 &&
     systemd-run --no-block --quiet --collect --unit="openthinrdp-stats-$$-$RANDOM" ${1:+--setenv=OTR_STATS_ANON=$1} "$OTR/stats.sh" >/dev/null 2>&1; then
    return 0
  fi
  OTR_STATS_ANON=$1 setsid "$OTR/stats.sh" < /dev/null > /dev/null 2>&1 &
}
# a new device (it never sent its counts and never took the central settings): its first anonymous counts with its own
# settings, before those of the site arrive; a device that already has the central settings follows them, also after
# an update (docs/privacy.md says so)
[ -f "$OTR_LIB/stats-sent" ] || [ -f "$OTR_LIB/central-common.conf" ] || stats_start "$(cfg ANON_STATS)"
# apply the central settings (also when the folder does not answer: the last good copy is used). Not while an
# update is installing: with half the files new and half old, a valid setting was rejected (13/10/2026, "colour
# not valid: BG_BOTTOM" three seconds into 0.1.6); the next run, at most 5 minutes later, applies it.
systemctl is-active -q openthinrdp-update.service 2>/dev/null || "$OTR/central-apply.sh"
# boot splash: always the image's own (a device that took the folder's picture there with 0.1.1 gets it back)
"$OTR/branding.sh" splash
# anonymous usage counts, once a week (ANON_STATS=on): apart, a slow internet never holds the report
stats_start ""
exit 0
