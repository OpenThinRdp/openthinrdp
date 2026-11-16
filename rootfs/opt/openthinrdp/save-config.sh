#!/bin/bash
# Validate and save the device settings, then apply them. Runs as root: from the settings dialog (sudo, kiosk
# user), from central-apply.sh and from the first boot setup.
# $1 = file with KEY=value lines. Keys not in the file keep their current value. Nothing touches the system
# before everything is valid; on error the messages go to stdout (one per line) and the exit code is 1.
# --print: validate and print every setting in its stored (normalized) form, change nothing.
# central-apply.sh uses it to compare like with like.
# --heal: a saved value no longer valid and not changed now goes back to its default instead of refusing the save
# (#201). Only where the person saving has no other way out: the settings dialog and the Wi-Fi page of the kiosk.
# The central settings stay strict (an invalid one is refused and reported to the manager), and so does the first boot.
. /opt/openthinrdp/lib/common.sh
. /opt/openthinrdp/lib/secrets.sh
. /opt/openthinrdp/lib/eap.sh
otr_lang
F="$1"; [ -f "$F" ] || { echo "$V_NODATA"; exit 1; }
PRINT=""; HEALOK=""; for a in "${@:2}"; do case "$a" in --print) PRINT=1 ;; --heal) HEALOK=1 ;; esac; done
has(){ grep -q "^$1=" "$F"; }
# value from the input file if present, else the current setting
get(){ if has "$1"; then sed -n "s/^$1=//p" "$F" | head -1 | tr -d '\r' | sed 's/^ *//; s/ *$//'; else cfg "$1"; fi; }
low(){ echo "$1" | tr 'A-Z' 'a-z'; }
onoff(){ case "$(low "$1")" in on|yes|true|1|si|sì|attivo|acceso) echo on ;; *) echo off ;; esac; }

ipok(){
  [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local o; for o in "${BASH_REMATCH[@]:1}"; do [ "$o" -le 255 ] || return 1; done
}
ip2int(){ local a b c d; IFS=. read -r a b c d <<< "$1"; echo $(( (10#$a<<24) | (10#$b<<16) | (10#$c<<8) | 10#$d )); }
maskok(){ ipok "$1" || return 1; local m inv; m=$(ip2int "$1"); inv=$(( ~m & 0xFFFFFFFF )); [ "$m" -ne 0 ] && [ $(( inv & (inv + 1) )) -eq 0 ]; }
hostok(){ [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] && ! [[ $1 =~ ^[0-9]+$ ]]; }
nameok(){ [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,252})$ ]]; }
# a name or an address, optionally :port (1-65535): the remote computer or broker, the fallbacks, the other computers
hostportok(){ local h=${1%:*} p=${1##*:}; [ "$h" = "$1" ] && p=3389
  { ipok "$h" || nameok "$h"; } && [[ $p =~ ^[0-9]{1,5}$ ]] && [ $((10#$p)) -ge 1 ] && [ $((10#$p)) -le 65535 ]; }
userok(){ [[ $1 =~ ^[A-Za-z0-9._@\\-]{1,104}$ ]]; }
URLRE='^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~:/?#@!$&()*+,;=%-]*)?$'
urlok(){ [[ $1 =~ $URLRE ]]; }
BADTEXT='[<>&|"`$\\]'
textok(){ ! [[ $1 =~ $BADTEXT ]] && [ ${#1} -le 200 ]; }
SHARERE='^(\\\\|//)[A-Za-z0-9.-]+[\\/][A-Za-z0-9 ._$\\/-]+$'
EXTRARE='^[A-Za-z0-9 /:+,._=#-]*$'
TIMERE='^([01][0-9]|2[0-3]):[0-5][0-9]$'
# err "KEYS" MESSAGE: a value not valid, about the settings KEYS. A value saved earlier and not changed now (#201: a
# rule made stricter by an update, a value written by hand or by another version) blocked every later save, and
# nothing in the dialog could clear it: such keys go to HEAL instead and are saved again with the project default
# (below), with --heal only. An error on a value changed now stays an error. OTR_HEALING: the second run, where
# nothing is healed.
E=""; HEAL=""; WKEYLOST=""
changed(){ has "$1" && [ "$(get "$1")" != "$(cfg "$1" | sed 's/^ *//; s/ *$//')" ]; }
err(){ local k
  if [ -n "$HEALOK" ] && [ -z "${OTR_HEALING+x}" ]; then
    for k in $1; do changed "$k" && { E+="- $2\n"; return; }; done
    HEAL+=" $1"; return
  fi
  E+="- $2\n"; }
declare -A V

# --- remote desktop
V[HOSTNAME]=$(get HOSTNAME); [ -z "${V[HOSTNAME]}" ] && V[HOSTNAME]=$(hostname)
hostok "${V[HOSTNAME]}" || err "HOSTNAME" "$V_HOSTNAME"
V[DEFAULT_USER]=$(get DEFAULT_USER); [ -z "${V[DEFAULT_USER]}" ] || userok "${V[DEFAULT_USER]}" || err "DEFAULT_USER" "$V_USER"
# the environment (empty = guessed, setup_kind in common.sh); the password remembered; waking the PC
case "$(low "$(get SETUP)")" in domain|dominio) V[SETUP]=domain ;; workgroup|gruppo|nodomain) V[SETUP]=workgroup ;; *) V[SETUP]="" ;; esac
# without a domain the field is the remote computer, and the message says so: there is no broker (#182)
V[BROKER]=$(get BROKER)
if [ -n "${V[BROKER]}" ] && ! hostportok "${V[BROKER]}"; then
  if [ "${V[SETUP]:-$(setup_kind)}" = workgroup ]; then err "BROKER" "$V_PC"; else err "BROKER" "$V_BROKER"; fi
fi
V[BROKER_FALLBACK]=$(get BROKER_FALLBACK | tr -s ' ,;' ' ' | sed 's/^ //; s/ $//')
for t in ${V[BROKER_FALLBACK]}; do hostportok "$t" || err "BROKER_FALLBACK" "$V_FALLBACK $t"; done
V[DOMAIN]=$(get DOMAIN); [ -z "${V[DOMAIN]}" ] || nameok "${V[DOMAIN]}" || err "DOMAIN" "$V_DOMAIN"
V[REMEMBER_PASSWORD]=$(onoff "$(get REMEMBER_PASSWORD)")
V[LIVE_PERSISTENCE]=$(onoff "$(get LIVE_PERSISTENCE)")
V[WAKE_MAC]=$(get WAKE_MAC | tr 'A-F-' 'a-f:')
[ -z "${V[WAKE_MAC]}" ] || [[ ${V[WAKE_MAC]} =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || err "WAKE_MAC" "$V_WAKE_MAC"
V[CONNECTIONS]=$(get CONNECTIONS | tr -s " ,;" " " | sed "s/^ //; s/ $//")
for t in ${V[CONNECTIONS]}; do hostportok "$t" || err "CONNECTIONS" "$V_CONNECTIONS $t"; done
V[WAKE_WAIT]=$(get WAKE_WAIT)
{ [[ ${V[WAKE_WAIT]} =~ ^[0-9]{1,3}$ ]] && [ $((10#${V[WAKE_WAIT]})) -ge 10 ] && [ $((10#${V[WAKE_WAIT]})) -le 600 ]; } || err "WAKE_WAIT" "$V_WAKE_WAIT"
# spaces are allowed: a session collection is tsv://MS Terminal Services Plugin.1.<collection> (#76)
RE_LBI='^[A-Za-z0-9._:/#= -]*$'
V[LOAD_BALANCE_INFO]=$(get LOAD_BALANCE_INFO); [[ ${V[LOAD_BALANCE_INFO]} =~ $RE_LBI ]] || err "LOAD_BALANCE_INFO" "$V_COLLECTION"
case "$(low "$(get TRANSPORT)")" in udp) V[TRANSPORT]=udp ;; tcp) V[TRANSPORT]=tcp ;; *) V[TRANSPORT]=auto ;; esac
case "$(low "$(get RDP_AUTH)")" in ntlm) V[RDP_AUTH]=ntlm ;; kerberos) V[RDP_AUTH]=kerberos ;; *) V[RDP_AUTH]=negotiate ;; esac
case "$(low "$(get RDP_CERT)")" in ignore) V[RDP_CERT]=ignore ;; verify) V[RDP_CERT]=verify ;; *) V[RDP_CERT]=tofu ;; esac
# RD Gateway: a name or an address, optionally :port (1-65535)
V[RDP_GATEWAY]=$(get RDP_GATEWAY | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
if [ -n "${V[RDP_GATEWAY]}" ]; then
  gh=${V[RDP_GATEWAY]%:*}; gp=${V[RDP_GATEWAY]##*:}; [ "$gh" = "${V[RDP_GATEWAY]}" ] && gp=443
  { { ipok "$gh" || nameok "$gh"; } && [[ $gp =~ ^[0-9]{1,5}$ ]] && [ "$gp" -ge 1 ] && [ "$gp" -le 65535 ]; } || err "RDP_GATEWAY" "$V_RDP_GATEWAY"
fi
case "$(low "$(get RDP_GATEWAY_USE)")" in detect|rileva|auto) V[RDP_GATEWAY_USE]=detect ;; *) V[RDP_GATEWAY_USE]=always ;; esac
V[RDP_GFX]=$(get RDP_GFX); [[ ${V[RDP_GFX]} =~ ^[A-Za-z0-9:,]*$ ]] || err "RDP_GFX" "$V_GFX"
V[RDP_KEYBOARD]=$(get RDP_KEYBOARD); [[ ${V[RDP_KEYBOARD]} =~ ^(0x[0-9a-fA-F]{8})?$ ]] || err "RDP_KEYBOARD" "$V_RDPKBD"
V[RDP_EXTRA]=$(get RDP_EXTRA); [[ ${V[RDP_EXTRA]} =~ $EXTRARE ]] || err "RDP_EXTRA" "$V_EXTRA"
case "$(low "$(get MULTIMON)")" in off|no|0) V[MULTIMON]=off ;; *) V[MULTIMON]=auto ;; esac
# the screen (#183): native or WIDTHxHEIGHT; a scale of 100-200 in steps of 25, anything else auto
V[DISPLAY_RESOLUTION]=$(low "$(get DISPLAY_RESOLUTION)" | tr -d ' ' | tr '*' 'x')
case "${V[DISPLAY_RESOLUTION]}" in ""|native|nativa|auto) V[DISPLAY_RESOLUTION]=native ;; esac
[ "${V[DISPLAY_RESOLUTION]}" = native ] || [[ ${V[DISPLAY_RESOLUTION]} =~ ^[1-9][0-9]{2,4}x[1-9][0-9]{2,4}$ ]] || err "DISPLAY_RESOLUTION" "$V_RESOLUTION"
case "$(get DISPLAY_SCALE | tr -d ' %')" in 100|125|150|175|200) V[DISPLAY_SCALE]=$(get DISPLAY_SCALE | tr -d ' %') ;; *) V[DISPLAY_SCALE]=auto ;; esac
V[SESSION_THRESHOLD]=$(get SESSION_THRESHOLD)
{ [[ ${V[SESSION_THRESHOLD]} =~ ^[0-9]{1,3}$ ]] && [ $((10#${V[SESSION_THRESHOLD]})) -ge 5 ] && [ $((10#${V[SESSION_THRESHOLD]})) -le 120 ]; } || err "SESSION_THRESHOLD" "$V_THRESHOLD"
# closing the session from the device (0.3.6): FreeRDP's bar, a key combination in FreeRDP's form (lower case, the
# modifiers in the order shift, ctrl, alt, super, then one key: "ctrl+alt+q"); Control, Win, Meta understood
V[SESSION_BAR]=$(onoff "$(get SESSION_BAR)")
ck=$(get SESSION_CLOSE_KEY | tr 'A-Z' 'a-z' | tr -d ' ')
V[SESSION_CLOSE_KEY]=""
if [ -n "$ck" ]; then
  IFS=+ read -ra P <<< "$ck"; key=${P[${#P[@]}-1]}; mods=" "; ok=1
  for x in "${P[@]:0:${#P[@]}-1}"; do
    case "$x" in shift|ctrl|alt|super) mods+="$x " ;; control) mods+="ctrl " ;; win|windows|meta) mods+="super " ;; *) ok="" ;; esac
  done
  # one key that is not itself a modifier, with Ctrl, Alt or Super (Shift alone would catch typing)
  case "$key" in shift|ctrl|control|alt|super|win|windows|meta) ok="" ;; esac
  { [[ $ck != *+ ]] && [[ $key =~ ^[a-z0-9_]+$ ]] && [[ $mods =~ \ (ctrl|alt|super)\  ]]; } || ok=""
  if [ -n "$ok" ]; then
    for x in shift ctrl alt super; do [[ $mods == *" $x "* ]] && V[SESSION_CLOSE_KEY]+="$x+"; done; V[SESSION_CLOSE_KEY]+=$key
  else err "SESSION_CLOSE_KEY" "$V_CLOSEKEY"; fi
fi
V[SHUTDOWN_SECS]=$(get SHUTDOWN_SECS)
{ [[ ${V[SHUTDOWN_SECS]} =~ ^[0-9]{1,4}$ ]] && [ $((10#${V[SHUTDOWN_SECS]})) -le 3600 ]; } || err "SHUTDOWN_SECS" "$V_SHUTDOWN"

# --- USB
case "$(low "$(get USB_MODE)")" in disks|dischi) V[USB_MODE]=disks ;; auto) V[USB_MODE]=auto ;; *) V[USB_MODE]=all ;; esac
V[USB_REDIRECT]=$(get USB_REDIRECT | tr -s ' ,;' ' ' | tr 'A-F' 'a-f' | sed 's/^ //; s/ $//')
[[ ${V[USB_REDIRECT]} =~ ^([0-9a-f]{4}:[0-9a-f]{4}( [0-9a-f]{4}:[0-9a-f]{4})*)?$ ]] || err "USB_REDIRECT" "$V_USBLIST"
V[USB_LOCAL]=$(get USB_LOCAL | tr -s ' ,;' ' ' | tr 'A-F' 'a-f' | sed 's/^ //; s/ $//')
[[ ${V[USB_LOCAL]} =~ ^([0-9a-f]{4}:[0-9a-f]{4}( [0-9a-f]{4}:[0-9a-f]{4})*)?$ ]] || err "USB_LOCAL" "$V_USBLIST"

# --- network
case "$(low "$(get NETMODE)")" in static|statico) V[NETMODE]=static ;; *) V[NETMODE]=dhcp ;; esac
V[IPADDR]=$(get IPADDR); V[NETMASK]=$(get NETMASK); V[GATEWAY]=$(get GATEWAY)
V[DNS1]=$(get DNS1); V[DNS2]=$(get DNS2)
if [ "${V[NETMODE]}" = static ]; then
  ipok "${V[IPADDR]}" || err "NETMODE IPADDR" "$V_IP"
  maskok "${V[NETMASK]}" || err "NETMODE NETMASK" "$V_NETMASK"
  ipok "${V[GATEWAY]}" || err "NETMODE GATEWAY" "$V_GATEWAY"
  if ipok "${V[IPADDR]}" && maskok "${V[NETMASK]}" && ipok "${V[GATEWAY]}"; then
    m=$(ip2int "${V[NETMASK]}")
    [ $(( $(ip2int "${V[IPADDR]}") & m )) -eq $(( $(ip2int "${V[GATEWAY]}") & m )) ] || err "NETMODE IPADDR NETMASK GATEWAY" "$V_SUBNET"
  fi
  ipok "${V[DNS1]}" || err "NETMODE DNS1" "$V_DNS_STATIC"
else
  # with DHCP the address fields stay as a reminder but are not used
  ipok "${V[IPADDR]}" || V[IPADDR]=""; maskok "${V[NETMASK]}" || V[NETMASK]=""; ipok "${V[GATEWAY]}" || V[GATEWAY]=""
  [ -z "${V[DNS1]}" ] || ipok "${V[DNS1]}" || err "DNS1" "$V_DNS1"
fi
[ -z "${V[DNS2]}" ] || ipok "${V[DNS2]}" || err "DNS2" "$V_DNS2"
V[NTP]=$(get NTP | tr -s ' ,;' ' ' | sed 's/^ //; s/ $//')
for t in ${V[NTP]}; do ipok "$t" || nameok "$t" || err "NTP" "$V_NTP $t"; done
# a time zone the image has: Europe/Amsterdam (empty = the one of the image)
V[TIMEZONE]=$(get TIMEZONE | tr -d " ")
[ -z "${V[TIMEZONE]}" ] || { [[ ${V[TIMEZONE]} =~ ^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+){0,2}$ ]] && [ -f "/usr/share/zoneinfo/${V[TIMEZONE]}" ]; } || err "TIMEZONE" "$V_TZ ${V[TIMEZONE]}"
V[REPORT_INTERVAL]=$(get REPORT_INTERVAL | tr -d ' '); [ -z "${V[REPORT_INTERVAL]}" ] && V[REPORT_INTERVAL]=5
{ [[ ${V[REPORT_INTERVAL]} =~ ^[0-9]{1,2}$ ]] && [ $((10#${V[REPORT_INTERVAL]})) -ge 2 ] && [ $((10#${V[REPORT_INTERVAL]})) -le 30 ]; } || err "REPORT_INTERVAL" "$V_INTERVAL"

# --- VPN (vpn.sh). WireGuard needs the server, its key and the address of the device; OpenVPN its profile, which the
# manager sends over SSH (it is not a setting). Missing WireGuard settings are no error: VPN_ADDRESS is set per
# device, and a device without it reports "settings incomplete" instead of refusing the whole central configuration
cidrok(){ local a=${1%/*} p=${1#*/}; [ "$p" != "$1" ] && ipok "$a" && [[ $p =~ ^[0-9]{1,2}$ ]] && [ "$p" -le 32 ]; }
case "$(low "$(get VPN)")" in wireguard|wg) V[VPN]=wireguard ;; openvpn|ovpn) V[VPN]=openvpn ;; tailscale|ts) V[VPN]=tailscale ;; *) V[VPN]=off ;; esac
V[VPN_SERVER]=$(get VPN_SERVER | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
if [ -n "${V[VPN_SERVER]}" ]; then
  vh=${V[VPN_SERVER]%:*}; vp=${V[VPN_SERVER]##*:}; [ "$vh" = "${V[VPN_SERVER]}" ] && vp=51820
  { { ipok "$vh" || nameok "$vh"; } && [[ $vp =~ ^[0-9]{1,5}$ ]] && [ "$vp" -ge 1 ] && [ "$vp" -le 65535 ]; } || err "VPN_SERVER" "$V_VPN_SERVER"
fi
V[VPN_SERVER_KEY]=$(get VPN_SERVER_KEY | tr -d '[:space:]')
[ -z "${V[VPN_SERVER_KEY]}" ] || [[ ${V[VPN_SERVER_KEY]} =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]] || err "VPN_SERVER_KEY" "$V_VPN_KEY"
V[VPN_ADDRESS]=$(get VPN_ADDRESS | tr -d '[:space:]')
[ -z "${V[VPN_ADDRESS]}" ] || cidrok "${V[VPN_ADDRESS]}" || err "VPN_ADDRESS" "$V_VPN_ADDRESS"
V[VPN_ROUTES]=$(get VPN_ROUTES | tr -s ' ,;' ' ' | sed 's/^ //; s/ $//')
for t in ${V[VPN_ROUTES]}; do cidrok "$t" || err "VPN_ROUTES" "$V_VPN_ROUTE $t"; done
V[VPN_DNS]=$(get VPN_DNS | tr -s ' ,;' ' ' | sed 's/^ //; s/ $//')
for t in ${V[VPN_DNS]}; do ipok "$t" || err "VPN_DNS" "$V_VPN_DNS $t"; done

# --- Wi-Fi: the key lives ONLY in the TPM or in a root-only file (lib/secrets.sh); an empty password keeps the saved one
V[WIFI]=$(onoff "$(get WIFI)"); V[WIFI_SSID]=$(get WIFI_SSID)
V[WIFI_COUNTRY]=$(get WIFI_COUNTRY | tr 'a-z' 'A-Z'); [[ ${V[WIFI_COUNTRY]} =~ ^([A-Z]{2})?$ ]] || err "WIFI_COUNTRY" "$V_COUNTRY"
WPIN=$(sed -n 's/^WIFI_PSK=//p' "$F" | head -1 | tr -d '\r'); WHEX=""
if [ -n "$WPIN" ]; then
  if [[ $WPIN =~ ^[0-9a-fA-F]{64}$ ]]; then WHEX=$(low "$WPIN")
  elif [ ${#WPIN} -ge 8 ] && [ ${#WPIN} -le 63 ]; then WHEX=$(wpa_passphrase "${V[WIFI_SSID]}" "$WPIN" 2>/dev/null | sed -n 's/^[[:space:]]*psk=//p')
  else err "WIFI_PSK" "$V_WIFIPSK"; fi
  [ -n "${V[WIFI_SSID]}" ] || err "WIFI_PSK WIFI_SSID" "$V_WIFINOSSID"
fi
BADSSID='["|\\]'
[ -z "${V[WIFI_SSID]}" ] || { [ ${#V[WIFI_SSID]} -le 32 ] && ! [[ ${V[WIFI_SSID]} =~ $BADSSID ]]; } || err "WIFI_SSID" "$V_SSID"
# the key already saved, valid only for the same network (a country change rewrites the file with it)
OLDHEX=$(wifi_saved_psk "${V[WIFI_SSID]}")
case "$(low "$(get WIFI_SECURITY)")" in peap) V[WIFI_SECURITY]=peap ;; tls|eap-tls) V[WIFI_SECURITY]=tls ;; *) V[WIFI_SECURITY]=psk ;; esac
# Wi-Fi on without an adapter is not an error: a common configuration may enable Wi-Fi for every device,
# and apply.sh simply does nothing on the wired-only ones. Enterprise (peap, tls) needs no key: the 802.1X settings below
if [ "${V[WIFI]}" = on ]; then
  [ -n "${V[WIFI_SSID]}" ] || err "WIFI WIFI_SSID" "$V_SSID"
  command -v wpa_supplicant >/dev/null || err "WIFI" "$V_NOWPA"
  # no key for the network: an error when the Wi-Fi is set now. When it was on already (the key kept in the TPM no
  # longer readable, #201) the other settings are saved, the Wi-Fi is left as it is and the dialog says to connect again
  if [ "${V[WIFI_SECURITY]}" = psk ] && [ -z "$WHEX" ] && [ -z "$OLDHEX" ]; then
    if [ -z "$HEALOK" ] || changed WIFI || changed WIFI_SSID || changed WIFI_SECURITY; then E+="- $V_WIFIMISSING ${V[WIFI_SSID]}\n"
    else WKEYLOST=1; fi
  fi
fi
# the other networks of the settings (0.3.6): WIFI_SSID_2..4 with WIFI_PSK_2..4, WPA2-Personal (two buildings, a branch
# office); the keys as the main one's, only in the Wi-Fi file. A network without its key is an error when it is set
# now; one already there whose key is not readable is left out of the file (lib/eap.sh)
declare -A WIFI_NEWKEY
for n in 2 3 4; do
  s=$(get WIFI_SSID_$n); V[WIFI_SSID_$n]=$s
  [ -z "$s" ] || { [ ${#s} -le 32 ] && ! [[ $s =~ $BADSSID ]]; } || err "WIFI_SSID_$n" "$V_SSID $s"
  p=$(sed -n "s/^WIFI_PSK_$n=//p" "$F" | head -1 | tr -d '\r')
  if [ -n "$p" ]; then
    if [[ $p =~ ^[0-9a-fA-F]{64}$ ]]; then WIFI_NEWKEY[$n]=$(low "$p")
    elif [ ${#p} -ge 8 ] && [ ${#p} -le 63 ]; then WIFI_NEWKEY[$n]=$(wpa_passphrase "$s" "$p" 2>/dev/null | sed -n 's/^[[:space:]]*psk=//p')
    else err "WIFI_PSK_$n" "$V_WIFIPSK"; fi
    [ -n "$s" ] || err "WIFI_PSK_$n WIFI_SSID_$n" "$V_WIFINOSSID"
  fi
  if [ -n "$s" ] && [ -z "${WIFI_NEWKEY[$n]:-}" ] && changed "WIFI_SSID_$n" && [ -z "$(wifi_saved_psk "$s")" ]; then
    err "WIFI_SSID_$n" "$V_WIFIMISSING $s"
  fi
done

# --- 802.1X: on the cable (DOT1X, dot1x.sh) and for Wi-Fi Enterprise, one block of settings (lib/eap.sh). The password
# lives ONLY in the TPM or a root-only file, like the Wi-Fi key; an empty one keeps the saved one. A missing password,
# certificate or CA file is no error: the manager sends them later, and the device reports what is missing.
case "$(low "$(get DOT1X)")" in peap) V[DOT1X]=peap ;; tls|eap-tls) V[DOT1X]=tls ;; *) V[DOT1X]=off ;; esac
V[EAP_IDENTITY]=$(get EAP_IDENTITY); [ -z "${V[EAP_IDENTITY]}" ] || [[ ${V[EAP_IDENTITY]} =~ $EAP_IDRE ]] || err "EAP_IDENTITY" "$V_EAP_IDENTITY"
V[EAP_ANONYMOUS]=$(get EAP_ANONYMOUS); [ -z "${V[EAP_ANONYMOUS]}" ] || [[ ${V[EAP_ANONYMOUS]} =~ $EAP_IDRE ]] || err "EAP_ANONYMOUS" "$V_EAP_ANONYMOUS"
V[EAP_CA]=$(get EAP_CA)
case "$(low "${V[EAP_CA]}")" in ''|system) V[EAP_CA]=system ;; *) [[ ${V[EAP_CA]} =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,99}\.crt$ ]] || err "EAP_CA" "$V_EAP_CA" ;; esac
V[EAP_SERVER_NAME]=$(get EAP_SERVER_NAME | tr -s ' ,;' ' ' | sed 's/^ //; s/ $//')
for t in ${V[EAP_SERVER_NAME]}; do nameok "$t" || err "EAP_SERVER_NAME" "$V_EAP_SERVER $t"; done
EPW=$(sed -n 's/^EAP_PASSWORD=//p' "$F" | head -1 | tr -d '\r')
OLDEPW=$(head -1 "$(secret_path eap-password)" 2>/dev/null)
[ ${#EPW} -le 256 ] || err "EAP_PASSWORD" "$V_EAP_PASSWORD"
{ [ "${V[DOT1X]}" != off ] || { [ "${V[WIFI]}" = on ] && [ "${V[WIFI_SECURITY]}" != psk ]; }; } && ! command -v wpa_supplicant >/dev/null && err "DOT1X WIFI WIFI_SECURITY" "$V_NOWPA_8021X"

# --- management
V[DEVICE_GROUP]=$(get DEVICE_GROUP); [ -z "${V[DEVICE_GROUP]}" ] || [[ ${V[DEVICE_GROUP]} =~ ^[A-Za-z0-9._-]{1,64}$ ]] || err "DEVICE_GROUP" "$V_GROUP"
V[MGMT_SHARE]=$(get MGMT_SHARE)
[ -z "${V[MGMT_SHARE]}" ] || [[ ${V[MGMT_SHARE]} =~ $SHARERE ]] || err "MGMT_SHARE" "$V_SHARE"
# account of the management folder: the user in the settings, the password ONLY in the TPM or a root-only file, like the
# Wi-Fi key; an empty password keeps the saved one. DOMAIN\user, user@domain, or user (then the domain is DOMAIN).
# Without MGMT_USER the file is left as it is (e.g. the smb.cred built into the image).
CRED=$(secret_path smb.cred)
V[MGMT_USER]=$(get MGMT_USER); [ -z "${V[MGMT_USER]}" ] || userok "${V[MGMT_USER]}" || err "MGMT_USER" "$V_MGMT_USER"
MPW=$(sed -n 's/^MGMT_PASSWORD=//p' "$F" | head -1 | tr -d '\r')
OLDPW=$(sed -n 's/^password=//p' "$CRED" 2>/dev/null | head -1)
[ ${#MPW} -le 256 ] || err "MGMT_PASSWORD" "$V_MGMT_PASSWORD"
[ -n "$MPW" ] && [ -z "${V[MGMT_USER]}" ] && err "MGMT_PASSWORD MGMT_USER" "$V_MGMT_NOUSER"
[ -n "${V[MGMT_USER]}" ] && [ -z "$MPW" ] && [ -z "$OLDPW" ] && err "MGMT_USER" "$V_MGMT_NOPASSWORD"
V[SECURITY_UPDATES]=$(onoff "$(get SECURITY_UPDATES)")
V[TPM_SECRETS]=$(onoff "$(get TPM_SECRETS)")
case "$(low "$(get UPDATE_FROM)")" in share|cartella|folder) V[UPDATE_FROM]=share ;; off|no|none|nessuno) V[UPDATE_FROM]=off ;; *) V[UPDATE_FROM]=github ;; esac
# (without a folder, one named for the domain account: report.sh; the account may be only in the credentials
# file, as on devices converted from another system, with no MGMT_USER)
[ "${V[UPDATE_FROM]}" = share ] && [ -z "${V[MGMT_SHARE]}" ] && [ -z "${V[MGMT_USER]}" ] && [ ! -s "$CRED" ] && err "UPDATE_FROM MGMT_SHARE MGMT_USER" "$V_UPDATE_SHARE"
V[UPDATE_GITHUB]=$(get UPDATE_GITHUB); [[ ${V[UPDATE_GITHUB]} =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || err "UPDATE_GITHUB" "$V_UPDATE_GITHUB"
case "$(low "$(get UPDATE_KEY)")" in site|sito) V[UPDATE_KEY]=site ;; *) V[UPDATE_KEY]=any ;; esac
case "$(low "$(get CONFIG_SIGNED)")" in required|on|yes|obbligatoria|richiesta) V[CONFIG_SIGNED]=required ;; *) V[CONFIG_SIGNED]=off ;; esac
V[UPDATE_TO]=$(low "$(get UPDATE_TO)")
case "${V[UPDATE_TO]}" in ''|latest|ultima|ultimo) V[UPDATE_TO]=latest ;; *) [[ ${V[UPDATE_TO]} =~ ^[0-9a-z._-]+$ ]] || err "UPDATE_TO" "$V_UPDATE_TO" ;; esac
V[UPDATE_MAJOR]=$(low "$(get UPDATE_MAJOR)"); [ -z "${V[UPDATE_MAJOR]}" ] || [[ ${V[UPDATE_MAJOR]} =~ ^[0-9a-z._-]+$ ]] || err "UPDATE_MAJOR" "$V_UPDATE_TO"
V[UPDATE_HOURS]=$(get UPDATE_HOURS | tr -d ' '); [ -z "${V[UPDATE_HOURS]}" ] || [[ ${V[UPDATE_HOURS]} =~ ^([01]?[0-9]|2[0-3])-([01]?[0-9]|2[0-4])$ ]] || err "UPDATE_HOURS" "$V_UPDATE_HOURS"
V[SSH]=$(onoff "$(get SSH)")
V[REMOTE_SCREEN]=$(onoff "$(get REMOTE_SCREEN)")
case "$(low "$(get REMOTE_CONSENT)")" in ask|chiedi|vraag|on|yes) V[REMOTE_CONSENT]=ask ;; *) V[REMOTE_CONSENT]=off ;; esac
V[ANON_STATS]=$(anon_level "$(get ANON_STATS)")
V[CAMERA_H264]=$(onoff "$(get CAMERA_H264)")
V[CAMERA_HWACCEL]=$(onoff "$(get CAMERA_HWACCEL)")
case "$(low "$(get CAMERA_MAX)")" in 720*|hd) V[CAMERA_MAX]=720p ;; 1080*|fhd|fullhd) V[CAMERA_MAX]=1080p ;; max|massima|maximum) V[CAMERA_MAX]=max ;; *) V[CAMERA_MAX]=auto ;; esac

# --- web button and kiosk page
case "$(low "$(get WEB_BUTTON)")" in app|portale|portal) V[WEB_BUTTON]=app ;; browser|chrome|chromium) V[WEB_BUTTON]=browser ;; kiosk) V[WEB_BUTTON]=kiosk ;; *) V[WEB_BUTTON]=none ;; esac
V[WEB_LABEL]=$(get WEB_LABEL); textok "${V[WEB_LABEL]}" || err "WEB_LABEL" "$V_WEBLABEL"
V[WEB_URL]=$(get WEB_URL); [ -z "${V[WEB_URL]}" ] || urlok "${V[WEB_URL]}" || err "WEB_URL" "$V_WEBURL"
case "${V[WEB_BUTTON]}" in app|browser) [ -n "${V[WEB_URL]}" ] || err "WEB_BUTTON WEB_URL" "$V_WEBURL_NEEDED" ;; esac
V[WEB_ALLOW]=$(get WEB_ALLOW | tr -s ' ,;' ' ' | sed 's/^ //; s/ $//')
for t in ${V[WEB_ALLOW]}; do urlok "$t" || err "WEB_ALLOW" "$V_WEBALLOW $t"; done
V[KIOSK_URL]=$(get KIOSK_URL); [ -z "${V[KIOSK_URL]}" ] || urlok "${V[KIOSK_URL]}" || err "KIOSK_URL" "$V_KIOSKURL"
[ "${V[WEB_BUTTON]}" = kiosk ] && [ -z "${V[KIOSK_URL]}" ] && err "WEB_BUTTON KIOSK_URL" "$V_KIOSKURL_NEEDED"
case "$(low "$(get BROWSER)")" in firefox|firefox-esr) V[BROWSER]=firefox ;; brave) V[BROWSER]=brave ;; chrome|google-chrome) V[BROWSER]=chrome ;; edge|microsoft-edge) V[BROWSER]=edge ;; *) V[BROWSER]=chromium ;; esac
case "${V[BROWSER]}" in chrome|edge) [ "$(otr_arch)" = amd64 ] || err "BROWSER" "$V_BROWSER_ARCH" ;; esac
V[KIOSK_RELOAD_MIN]=$(get KIOSK_RELOAD_MIN)
{ [[ ${V[KIOSK_RELOAD_MIN]} =~ ^[0-9]{1,4}$ ]] && [ $((10#${V[KIOSK_RELOAD_MIN]})) -le 1440 ]; } || err "KIOSK_RELOAD_MIN" "$V_RELOAD"

# --- power schedule
V[POWER_ON_TIME]=$(get POWER_ON_TIME); [ -z "${V[POWER_ON_TIME]}" ] || [[ ${V[POWER_ON_TIME]} =~ $TIMERE ]] || err "POWER_ON_TIME" "$V_POWERON"
V[POWER_OFF_TIME]=$(get POWER_OFF_TIME); [ -z "${V[POWER_OFF_TIME]}" ] || [[ ${V[POWER_OFF_TIME]} =~ $TIMERE ]] || err "POWER_OFF_TIME" "$V_POWEROFF"
d=$(get POWER_ON_DAYS); [ -z "$(echo "$d" | tr -d '1-7 ,;')" ] || err "POWER_ON_DAYS" "$V_DAYS"
V[POWER_ON_DAYS]=$(echo "$d" | tr -cd '1-7' | fold -w1 | sort -u | tr -d '\n'); [ -z "${V[POWER_ON_DAYS]}" ] && V[POWER_ON_DAYS]=1234567

# --- look and language
V[LANGUAGE]=$(low "$(get LANGUAGE)"); { [[ ${V[LANGUAGE]} =~ ^[a-z]{2}$ ]] && [ -f "$OTR/lang/${V[LANGUAGE]}.sh" ]; } || err "LANGUAGE" "$V_LANGUAGE"
V[KEYBOARD]=$(get KEYBOARD); [[ ${V[KEYBOARD]} =~ ^[a-z][a-z0-9_-]{1,15}$ ]] || err "KEYBOARD" "$V_KEYBOARD"
V[TITLE]=$(get TITLE); textok "${V[TITLE]}" || err "TITLE" "$V_TITLE"
V[SUPPORT_TEXT]=$(get SUPPORT_TEXT); textok "${V[SUPPORT_TEXT]}" || err "SUPPORT_TEXT" "$V_SUPPORT"
V[LOGO]=$(get LOGO); [[ ${V[LOGO]} =~ ^(/[A-Za-z0-9._/-]+\.png)?$ ]] || err "LOGO" "$V_LOGO"
for k in BG_TOP BG_BOTTOM; do V[$k]=$(get $k); [[ ${V[$k]} =~ ^#[0-9a-fA-F]{6}$ ]] || err "$k" "$V_COLOR $k"; done
V[SETTINGS_PIN_SHA256]=$(low "$(get SETTINGS_PIN_SHA256)"); [[ ${V[SETTINGS_PIN_SHA256]} =~ ^([0-9a-f]{64}|pbkdf2-sha256:[0-9]{4,7}:[0-9a-f]{32}:[0-9a-f]{64})?$ ]] || err "SETTINGS_PIN_SHA256" "$V_PIN"

if [ -n "$E" ]; then printf '%b' "$E"; exit 1; fi
# saved values no longer valid: once more with the project default in their place (a default that is not valid
# either is then an error, as any other)
if [ -n "$HEAL" ]; then
  H=$(mktemp); grep -vE "^($(printf '%s\n' $HEAL | sort -u | paste -sd '|'))=" "$F" > "$H"
  for k in $(printf '%s\n' $HEAL | sort -u); do echo "$k=$(sed -n "s/^$k=//p" "$OTR_DEFAULTS" | head -1 | tr -d '\r')" >> "$H"; done
  OTR_HEALING="$(printf '%s\n' $HEAL | sort -u | paste -sd ' ')" "$BASH" "$0" "$H" ${PRINT:+--print}; r=$?; rm -f "$H"; exit $r
fi
for k in SESSION_THRESHOLD SHUTDOWN_SECS KIOSK_RELOAD_MIN WAKE_WAIT; do V[$k]=$((10#${V[$k]})); done
if [ -n "$PRINT" ]; then
  for k in $(cfg_keys); do echo "$k=${V[$k]}"; done
  # secrets as a hash: central-apply.sh compares them, nobody can read them back (the kiosk user may run this)
  hs(){ [ -n "$1" ] && printf '%s' "$1" | sha256sum | cut -c1-64; }
  # (an enterprise network has no key: a WIFI_PSK left in the central files must not look like a change at every run)
  if [ "${V[WIFI_SECURITY]}" = psk ]; then echo "WIFI_PSK=$(hs "${WHEX:-$OLDHEX}")"; else echo "WIFI_PSK="; fi
  for n in 2 3 4; do s=${V[WIFI_SSID_$n]}; echo "WIFI_PSK_$n=$( [ -n "$s" ] && hs "${WIFI_NEWKEY[$n]:-$(wifi_saved_psk "$s")}")"; done
  echo "MGMT_PASSWORD=$(hs "${MPW:-$OLDPW}")"
  echo "EAP_PASSWORD=$(hs "${EPW:-$OLDEPW}")"
  exit 0
fi

# --- save: the device file keeps the keys it already had, plus the ones given now that differ from what the device
# inherits; the others keep following site.conf and the project defaults. The settings screen sends every field: all
# of them written froze site.conf and the defaults on the device at its first Save, for good (0.3.6, found by soso192
# in #201). ANON_STATS always: its presence says the question of the first start was answered.
mkdir -p "$OTR_ETC"
declare -A OUT
[ -f "$OTR_CONF" ] && while IFS='=' read -r k v; do [ -n "$k" ] && OUT[$k]=$v; done < <(grep -E '^[A-Z][A-Z0-9_]*=' "$OTR_CONF")
inherited(){ local f; for f in "$OTR_SITE" "$OTR_DEFAULTS"; do [ -f "$f" ] && grep -q "^$1=" "$f" && { sed -n "s/^$1=//p" "$f" | head -1 | tr -d '\r'; return; }; done; }
for k in $(cfg_keys); do
  [ "$k" = HOSTNAME ] && continue
  if [ -n "${OUT[$k]+x}" ]; then OUT[$k]=${V[$k]}
  elif has "$k" && { [ "$k" = ANON_STATS ] || [ "${V[$k]}" != "$(inherited "$k")" ]; }; then OUT[$k]=${V[$k]}; fi
done
T=$(mktemp "$OTR_ETC/.conf.XXXXXX")
{ echo "# Settings of this device, written by save-config.sh. See /opt/openthinrdp/defaults.conf."
  for k in $(cfg_keys); do [ -n "${OUT[$k]+x}" ] && echo "$k=${OUT[$k]}"; done; } > "$T"
chmod 644 "$T"; mv -f "$T" "$OTR_CONF"

# the 802.1X password (before the Wi-Fi file, which holds it for an enterprise network)
if [ -n "$EPW" ] && [ "$EPW" != "$OLDEPW" ]; then
  mkdir -p "$EAP_DIR"; NP=$(mktemp); chmod 600 "$NP"; printf '%s\n' "$EPW" > "$NP"; secret_store eap-password "$NP"
fi
# Wi-Fi (lib/eap.sh): the file is written with the new key, or with the saved one of the same network (country
# changed); for an enterprise network with the 802.1X settings
wifi_conf_update "$WHEX"
# account of the management folder (only with MGMT_USER: otherwise the file of the image stays)
if [ -n "${V[MGMT_USER]}" ]; then
  MU=${V[MGMT_USER]}; MD=${V[DOMAIN]}
  case "$MU" in *\\*) MD=${MU%%\\*}; MU=${MU#*\\} ;; *@*) MD=${MU#*@}; MU=${MU%%@*} ;; esac
  NC=$(mktemp "$OTR_ETC/.cred.XXXXXX"); chmod 600 "$NC"
  { echo "username=$MU"; echo "password=${MPW:-$OLDPW}"; [ -n "$MD" ] && echo "domain=$MD"; } > "$NC"
  if cmp -s "$NC" "$CRED"; then rm -f "$NC"; else secret_store smb.cred "$NC"; fi
fi
# hostname, and /etc/hosts always matching it (otherwise sudo and X look the name up on the network)
H=${V[HOSTNAME]}
[ "$(hostname)" != "$H" ] && { hostnamectl set-hostname "$H" 2>/dev/null || hostname "$H"; }
DOM=$(low "${V[DOMAIN]}")
if [[ $DOM == *.* ]]; then L=$(printf '127.0.1.1\t%s.%s\t%s' "$H" "$DOM" "$H"); else L=$(printf '127.0.1.1\t%s' "$H"); fi
if grep -q '^127\.0\.1\.1' /etc/hosts; then sed -i "s/^127\.0\.1\.1.*/$L/" /etc/hosts; else echo "$L" >> /etc/hosts; fi
"$OTR/browser-policy.sh"
"$OTR/schedule.sh" alarm         # power-on alarm reprogrammed at once with the new times
"$OTR/apply.sh" now
# what the person saving should know (the dialog shows the lines starting with "NOTE: ")
if [ -n "${OTR_HEALING:-}" ]; then
  ev "settings: saved values not valid any more, back to the project default: $OTR_HEALING"
  printf "NOTE: $V_HEALED\n" "$OTR_HEALING"
fi
if [ -n "$WKEYLOST" ]; then
  ev "settings: the Wi-Fi key of ${V[WIFI_SSID]} is not readable on this device (TPM: $(secret_mode)), other settings saved"
  printf "NOTE: $V_WIFIKEYLOST\n" "${V[WIFI_SSID]}"
fi
exit 0
