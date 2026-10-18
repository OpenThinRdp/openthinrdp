#!/bin/bash
# OpenThinRDP tests that need no hardware: settings layers, validation, central configuration, status file.
# Runs as root inside a throw-away Debian 13 container (it installs the rootfs into /):
#   docker run --rm -v "$PWD":/src:ro debian:trixie bash /src/tests/run-tests.sh
set -u
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null && apt-get install -y -qq wpasupplicant iproute2 procps systemd python3 gnupg sqv >/dev/null 2>&1
# software updates are fetched from local files: no test ever talks to GitHub
export OTR_UPDATE_BASE_URL=file:///tmp/otr-release
cp -a /src/rootfs/. /
OTR=/opt/openthinrdp
chmod 755 $OTR/*.sh
# the system side is not under test here: apply, browser policy and schedule become no-ops
for s in apply.sh browser-policy.sh schedule.sh; do printf '#!/bin/bash\nexit 0\n' > $OTR/$s; done
mkdir -p /etc/openthinrdp /var/lib/openthinrdp /var/log/openthinrdp; touch /var/log/openthinrdp/events.log
. $OTR/lib/common.sh
PASS=0; FAIL=0
ok(){ if eval "$2"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1"; fi; }
T=$(mktemp)

# --- layers: device > site > defaults
ok "default when nothing set" '[ "$(cfg TRANSPORT)" = auto ]'
printf 'TRANSPORT=udp\nTITLE=Site title\n' > /etc/openthinrdp/site.conf
ok "site overrides default" '[ "$(cfg TRANSPORT)" = udp ]'
printf 'TRANSPORT=tcp\n' > /etc/openthinrdp/openthinrdp.conf
ok "device overrides site" '[ "$(cfg TRANSPORT)" = tcp ]'
printf 'TITLE=\n' >> /etc/openthinrdp/openthinrdp.conf
ok "empty device value clears the site value" '[ -z "$(cfg TITLE)" ]'
: > /etc/openthinrdp/openthinrdp.conf; : > /etc/openthinrdp/site.conf
ok "cfg_num falls back on garbage" '[ "$(printf "SHUTDOWN_SECS=abc\n" > /etc/openthinrdp/openthinrdp.conf; cfg_num SHUTDOWN_SECS 10)" = 10 ]'
: > /etc/openthinrdp/openthinrdp.conf

# --- validation (save-config.sh --print changes nothing)
check(){ printf '%s\n' "$2" > "$T"; $OTR/save-config.sh "$T" --print >/dev/null 2>&1; }
ok "empty input is valid with defaults" 'check x ""'
ok "hostname only digits refused" '! check x "HOSTNAME=12345"'
ok "good hostname" 'check x "HOSTNAME=reception-1"'
ok "static without DNS refused" '! check x "$(printf "NETMODE=static\nIPADDR=192.0.2.10\nNETMASK=255.255.255.0\nGATEWAY=192.0.2.1")"'
ok "static gateway in another network refused" '! check x "$(printf "NETMODE=static\nIPADDR=192.0.2.10\nNETMASK=255.255.255.0\nGATEWAY=198.51.100.1\nDNS1=192.0.2.53")"'
ok "good static" 'check x "$(printf "NETMODE=static\nIPADDR=192.0.2.10\nNETMASK=255.255.255.0\nGATEWAY=192.0.2.1\nDNS1=192.0.2.53")"'
ok "bad netmask refused" '! check x "$(printf "NETMODE=static\nIPADDR=192.0.2.10\nNETMASK=255.0.255.0\nGATEWAY=192.0.2.1\nDNS1=192.0.2.53")"'
ok "share with one backslash refused" '! check x "MGMT_SHARE=\\fileserver\\thinclients"'
ok "salted PIN hash accepted" 'check x "SETTINGS_PIN_SHA256=pbkdf2-sha256:600000:$(printf %032d 0):$(printf 1234 | sha256sum | cut -c1-64)"'
ok "PIN hash of 0.1.4 still accepted" 'check x "SETTINGS_PIN_SHA256=$(printf 1234 | sha256sum | cut -c1-64)"'
ok "malformed PIN hash refused" '! check x "SETTINGS_PIN_SHA256=pbkdf2-sha256:600000:short:$(printf 1234 | sha256sum | cut -c1-64)"'
ok "good share" 'check x "MGMT_SHARE=\\\\fileserver\\thinclients"'
ok "app button without URL refused" '! check x "WEB_BUTTON=app"'
ok "kiosk without page refused" '! check x "WEB_BUTTON=kiosk"'
ok "URL with a quote refused" '! check x "WEB_URL=https://example.com/a\"b"'
ok "title with markup refused" '! check x "TITLE=<b>x</b>"'
ok "SSID with a quote refused" '! check x "$(printf "WIFI_SSID=a\"b")"'
ok "SSID with a pipe refused" '! check x "$(printf "WIFI_SSID=a|b")"'
ok "Wi-Fi password without SSID refused" '! check x "WIFI_PSK=password123"'
ok "Wi-Fi on with SSID and password accepted (no adapter needed)" 'check x "$(printf "WIFI=on\nWIFI_SSID=Office\nWIFI_PSK=password123")"'
ok "Wi-Fi on without a key refused" '! check x "$(printf "WIFI=on\nWIFI_SSID=Office")"'
ok "threshold out of range refused" '! check x "SESSION_THRESHOLD=200"'
ok "bad days refused" '! check x "POWER_ON_DAYS=1289"'
ok "bad time refused" '! check x "POWER_ON_TIME=25:00"'
ok "bad USB id refused" '! check x "USB_REDIRECT=1eaf:00x9"'
ok "unknown language refused" '! check x "LANGUAGE=xx"'
ok "RDP_EXTRA with shell characters refused" '! check x "RDP_EXTRA=/foo;reboot"'
# the messages follow the language the device is using now
printf 'LANGUAGE=it\n' > /etc/openthinrdp/openthinrdp.conf; printf 'HOSTNAME=12345\n' > "$T"
ok "messages in Italian" '$OTR/save-config.sh "$T" --print 2>&1 | grep -q "Nome macchina non valido"'
: > /etc/openthinrdp/openthinrdp.conf

# --- normalization: the stored form
printf 'USB_MODE=Dischi\nUSB_REDIRECT=1EAF:0009,346d:5678\nNTP=a.example.com;b.example.com\nSECURITY_UPDATES=Yes\nPOWER_ON_DAYS=5,1,3\nSHUTDOWN_SECS=030\n' > "$T"
P=$($OTR/save-config.sh "$T" --print 2>&1)
ok "aliases and separators normalized" 'echo "$P" | grep -qx "USB_MODE=disks" && echo "$P" | grep -qx "USB_REDIRECT=1eaf:0009 346d:5678" && echo "$P" | grep -qx "NTP=a.example.com b.example.com" && echo "$P" | grep -qx "SECURITY_UPDATES=on" && echo "$P" | grep -qx "POWER_ON_DAYS=135" && echo "$P" | grep -qx "SHUTDOWN_SECS=30"'
um_of(){ printf 'USB_MODE=%s\n' "$1" > "$T"; $OTR/save-config.sh "$T" --print 2>&1 | sed -n 's/^USB_MODE=//p'; }
ok "USB_MODE auto, all and disks kept, anything else is all" '[ "$(um_of Auto)" = auto ] && [ "$(um_of disks)" = disks ] && [ "$(um_of all)" = all ] && [ "$(um_of garbage)" = all ]'

# --- USB devices by their interfaces (lib/usb.sh), on a tree of its own: a stick (08), a card reader with two
# storage interfaces, an instrument with storage and a serial port (08 + 02 0a), a smart card reader with storage
# (0b + 08), a keyboard (03)
UT=$(mktemp -d)
mkd(){ local name=$1 d=$UT/$1 n=0 c; shift; mkdir -p "$d"; echo 1234 > "$d/idVendor"
  for c in "$@"; do mkdir -p "$d/$name:1.$n"; echo "$c" > "$d/$name:1.$n/bInterfaceClass"; n=$((n+1)); done; }
mkd 1-1 08; mkd 1-2 08 08; mkd 1-3 08 02 0a; mkd 1-4 0b 08; mkd 1-5 03
. $OTR/lib/usb.sh
ok "storage only: a stick and a card reader" 'usb_storage_only $UT/1-1 && usb_storage_only $UT/1-2'
ok "not storage only: an instrument with a serial port, a smart card reader, a keyboard" '! usb_storage_only $UT/1-3 && ! usb_storage_only $UT/1-4 && ! usb_storage_only $UT/1-5'
printf 'USB_MODE=auto\n' > /etc/openthinrdp/openthinrdp.conf
ok "auto mounts a stick and the storage of a smart card reader, not an instrument" 'usb_mount_here $UT/1-1 && usb_mount_here $UT/1-4 && ! usb_mount_here $UT/1-3 && ! usb_mount_here ""'
printf 'USB_MODE=disks\n' > /etc/openthinrdp/openthinrdp.conf
ok "disks mounts every storage" 'usb_mount_here $UT/1-3 && usb_mount_here $UT/1-1'
printf 'USB_MODE=all\n' > /etc/openthinrdp/openthinrdp.conf
ok "all mounts nothing" '! usb_mount_here $UT/1-1 && ! usb_mount_here $UT/1-4'
: > /etc/openthinrdp/openthinrdp.conf; rm -rf "$UT"
printf 'NETMODE=Statico\nIPADDR=192.0.2.10\nNETMASK=255.255.255.0\nGATEWAY=192.0.2.1\nDNS1=192.0.2.53\n' > "$T"
ok "static alias normalized" '$OTR/save-config.sh "$T" --print 2>&1 | grep -qx "NETMODE=static"'
printf 'IPADDR=garbage\n' > "$T"
ok "invalid address cleared in DHCP mode" '$OTR/save-config.sh "$T" --print 2>&1 | grep -qx "IPADDR="'
tr_of(){ printf 'TRANSPORT=%s\n' "$1" > "$T"; $OTR/save-config.sh "$T" --print 2>&1 | sed -n 's/^TRANSPORT=//p'; }
ok "transport modes kept, anything else is auto" '[ "$(tr_of UDP)" = udp ] && [ "$(tr_of tcp)" = tcp ] && [ "$(tr_of auto)" = auto ] && [ "$(tr_of garbage)" = auto ]'
au_of(){ printf 'RDP_AUTH=%s\n' "$1" > "$T"; $OTR/save-config.sh "$T" --print 2>&1 | sed -n 's/^RDP_AUTH=//p'; }
ok "authentication kerberos and ntlm kept, anything else is negotiate" '[ "$(au_of Kerberos)" = kerberos ] && [ "$(au_of ntlm)" = ntlm ] && [ "$(au_of garbage)" = negotiate ]'
mm_of(){ printf 'MULTIMON=%s\n' "$1" > "$T"; $OTR/save-config.sh "$T" --print 2>&1 | sed -n 's/^MULTIMON=//p'; }
ok "MULTIMON auto or off" '[ "$(mm_of off)" = off ] && [ "$(mm_of AUTO)" = auto ] && [ "$(mm_of garbage)" = auto ]'
ok "secrets printed only as a hash" 'printf "WIFI=on\nWIFI_SSID=Office\nWIFI_PSK=password123\nMGMT_USER=svc\nMGMT_PASSWORD=Secret|1\n" > "$T"; P=$($OTR/save-config.sh "$T" --print 2>&1); ! echo "$P" | grep -q "Secret|1" && ! echo "$P" | grep -q "$(wpa_passphrase Office password123 | sed -n "s/^[[:space:]]*psk=//p")" && echo "$P" | grep -Eq "^MGMT_PASSWORD=[0-9a-f]{64}$"'
ok "management user without any password refused" '! check x "MGMT_USER=svc"'
ok "management password without user refused" '! check x "MGMT_PASSWORD=x"'

# --- real save: only given keys end in the device file
: > /etc/openthinrdp/openthinrdp.conf
printf 'BROKER=rdbroker.example.com\nDEFAULT_USER=alice\n' > "$T"
ok "save works" '$OTR/save-config.sh "$T" >/dev/null 2>&1'
ok "device file has the given keys" 'grep -qx "BROKER=rdbroker.example.com" $OTR_CONF && grep -qx "DEFAULT_USER=alice" $OTR_CONF'
ok "device file has no other keys" '[ "$(grep -c "^[A-Z]" $OTR_CONF)" = 2 ]'

# --- account of the management folder: the password only in smb.cred (600), never in the settings
CRED=/etc/openthinrdp/smb.cred
printf 'MGMT_USER=EXAMPLE\\svc-tc\nMGMT_PASSWORD=p|w=x y\n' > "$T"; $OTR/save-config.sh "$T" >/dev/null 2>&1
ok "smb.cred written with user, domain and password" 'grep -qx "username=svc-tc" $CRED && grep -qx "password=p|w=x y" $CRED && grep -qx "domain=EXAMPLE" $CRED'
ok "smb.cred root only" '[ "$(stat -c %a $CRED)" = 600 ]'
ok "user in the settings, password not" 'grep -qx "MGMT_USER=EXAMPLE\\\\svc-tc" $OTR_CONF && ! grep -q "p|w" $OTR_CONF'
printf 'MGMT_USER=other@corp.example\n' > "$T"; $OTR/save-config.sh "$T" >/dev/null 2>&1
ok "user@domain, an empty password keeps the saved one" 'grep -qx "username=other" $CRED && grep -qx "domain=corp.example" $CRED && grep -qx "password=p|w=x y" $CRED'
sed -i '/^MGMT_USER=/d' $OTR_CONF

# --- central configuration: a file written on Windows (BOM, CRLF, spaces, case, commas)
printf '\xEF\xBB\xBF; common settings\r\nUSB_MODE = Dischi\r\nUSB_REDIRECT=1EAF:0009, 346D:5678\r\nHOSTNAME=not-allowed-here\r\nNTP=a.example.com,b.example.com\r\n' > $OTR_LIB/central-common.conf
$OTR/central-apply.sh
ok "central applied" 'grep -q "^applied" $OTR_LIB/central-status'
ok "values stored normalized" 'grep -qx "USB_MODE=disks" $OTR_CONF && grep -qx "USB_REDIRECT=1eaf:0009 346d:5678" $OTR_CONF'
ok "HOSTNAME ignored in common.conf" '! grep -q "^HOSTNAME" $OTR_CONF && [ "$(hostname)" != not-allowed-here ]'
printf 'VPN_ADDRESS=10.8.0.99/24\r\n' >> $OTR_LIB/central-common.conf; $OTR/central-apply.sh
ok "VPN_ADDRESS ignored in common.conf (one per device)" '! grep -q "^VPN_ADDRESS" $OTR_CONF'
sed -i '/^VPN_ADDRESS/d' $OTR_LIB/central-common.conf; $OTR/central-apply.sh
$OTR/central-apply.sh
ok "second run: in line, no loop" 'grep -q "^in line" $OTR_LIB/central-status'
N=$(grep -c "central configuration applied" $OTR_EVENTS)
$OTR/central-apply.sh; $OTR/central-apply.sh
ok "no event on repeated runs" '[ "$(grep -c "central configuration applied" $OTR_EVENTS)" = "$N" ]'
printf 'SHUTDOWN_SECS=99999\r\n' > $OTR_LIB/central-host.conf
$OTR/central-apply.sh; $OTR/central-apply.sh
ok "invalid central refused once" 'grep -q "^REJECTED" $OTR_LIB/central-status && [ "$(grep -c "REJECTED" $OTR_EVENTS)" = 1 ]'
ok "previous configuration kept" 'grep -qx "USB_MODE=disks" $OTR_CONF'
printf 'HOSTNAME=kiosk-test\r\n' > $OTR_LIB/central-host.conf
$OTR/central-apply.sh
ok "host file may set HOSTNAME" 'grep -q "^applied" $OTR_LIB/central-status'

# --- central values win over local changes; keys removed centrally go back to the defaults
: > $OTR_LIB/central-host.conf
printf 'USB_MODE=disks\nNTP=a.example.com\n' > $OTR_LIB/central-common.conf
$OTR/central-apply.sh
sed -i 's/^USB_MODE=.*/USB_MODE=all/' $OTR_CONF            # someone changes it in the settings dialog
$OTR/central-apply.sh
ok "a local change of a central key is overwritten" 'grep -qx "USB_MODE=disks" $OTR_CONF'
printf 'NTP=a.example.com\n' > $OTR_LIB/central-common.conf # USB_MODE removed from common.conf
$OTR/central-apply.sh
ok "a key removed centrally leaves the device settings" '! grep -q "^USB_MODE=" $OTR_CONF && [ "$(cfg USB_MODE)" = all ]'
ok "the release is logged" 'grep -q "back to the defaults: USB_MODE" $OTR_EVENTS'
ok "the other central key stays" 'grep -qx "NTP=a.example.com" $OTR_CONF'
printf 'WEB_BUTTON=app\nWEB_URL=https://intranet.example.com/\n' > $OTR_LIB/central-common.conf
$OTR/central-apply.sh
printf 'WEB_BUTTON=app\n' > $OTR_LIB/central-common.conf   # URL removed, button kept: not valid
$OTR/central-apply.sh
ok "an invalid release is refused and the key kept" 'grep -q "^WEB_URL=https://intranet.example.com/" $OTR_CONF && grep -q "NOT released" $OTR_EVENTS'
ok "the refused key stays managed for the next run" 'grep -qx WEB_URL $OTR_LIB/central-managed'
: > $OTR_LIB/central-common.conf; $OTR/central-apply.sh
ok "everything released when the central files are empty" '! grep -qE "^(WEB_BUTTON|WEB_URL|NTP)=" $OTR_CONF'
# secrets from the central files: compared by hash, applied with their real value (not the hash)
printf 'WIFI=on\nWIFI_SSID=Office\nWIFI_PSK=password123\nMGMT_USER=svc\nMGMT_PASSWORD=Central-Pw\n' > $OTR_LIB/central-common.conf
$OTR/central-apply.sh
ok "central Wi-Fi key applied with its real value" 'grep -q "psk=$(wpa_passphrase Office password123 | sed -n "s/^[[:space:]]*psk=//p")" /etc/wpa_supplicant/openthinrdp-wifi.conf'
ok "central management password applied, hidden in the events" 'grep -qx "password=Central-Pw" /etc/openthinrdp/smb.cred && grep -q "MGMT_PASSWORD(hidden)" $OTR_EVENTS && ! grep -q "Central-Pw" $OTR_EVENTS'
N=$(grep -c "central configuration applied" $OTR_EVENTS); $OTR/central-apply.sh
ok "secrets in line: no loop" '[ "$(grep -c "central configuration applied" $OTR_EVENTS)" = "$N" ]'
: > $OTR_LIB/central-common.conf; $OTR/central-apply.sh; sed -i '/^WIFI/d; /^MGMT_USER/d' $OTR_CONF

# a folder that moves the device to another one: the new folder need not name itself, the device stays there
printf 'MGMT_SHARE=//fs/new-folder\n' > $OTR_LIB/central-common.conf; $OTR/central-apply.sh
: > $OTR_LIB/central-common.conf; $OTR/central-apply.sh
ok "a management folder set centrally is never released" 'grep -qx "MGMT_SHARE=//fs/new-folder" $OTR_CONF'
sed -i '/^MGMT_SHARE=/d' $OTR_CONF; : > $OTR_LIB/central-managed
# --- status file: no Wi-Fi key, PIN only as (set)
printf 'SETTINGS_PIN_SHA256=%s\n' "$(printf 1234 | sha256sum | cut -c1-64)" >> $OTR_CONF
$OTR/report.sh >/dev/null 2>&1
ok "status written" '[ -s /run/openthinrdp-status.txt ]'
ok "PIN hash not in the status" '! grep -q "$(printf 1234 | sha256sum | cut -c1-64)" /run/openthinrdp-status.txt && grep -qx "CFG_SETTINGS_PIN_SHA256=(set)" /run/openthinrdp-status.txt'
# (the names of the secret keys may appear in the events, "WIFI_PSK(hidden)": never their values)
ok "no Wi-Fi key in the status" '! grep -qE "password123|$(wpa_passphrase Office password123 | sed -n "s/^[[:space:]]*psk=//p")" /run/openthinrdp-status.txt && ! grep -q "^CFG_WIFI_PSK" /run/openthinrdp-status.txt'
ok "no management password in the status" '! grep -qE "Central-Pw|p\|w=x" /run/openthinrdp-status.txt && ! grep -q "^CFG_MGMT_PASSWORD" /run/openthinrdp-status.txt'

# --- logo and boot image of the management folder (branding.sh), and the boot splash that follows
# png FILE WIDTH HEIGHT: a valid RGBA PNG of that size
png(){ python3 -c 'import sys,zlib,struct
w,h=int(sys.argv[2]),int(sys.argv[3])
def c(t,d): return struct.pack(">I",len(d))+t+d+struct.pack(">I",zlib.crc32(t+d)&0xffffffff)
raw=b"".join(b"\0"+b"\0\0\x80\xff"*w for _ in range(h))
open(sys.argv[1],"wb").write(b"\x89PNG\r\n\x1a\n"+c(b"IHDR",struct.pack(">IIBBBBB",w,h,8,6,0,0,0))+c(b"IDAT",zlib.compress(raw))+c(b"IEND",b""))' "$@"; }
M=/tmp/mgmt; H=$(hostname); B=$OTR_LIB/branding; mkdir -p $M/config/branding/$H $OTR/branding
cp /src/image/branding/logo.png /src/image/branding/splash.png $OTR/branding/
png $M/config/branding/logo.png 200 80; $OTR/branding.sh sync $M
ok "common logo copied" 'cmp -s $M/config/branding/logo.png $B/logo.png && grep -qx logo=common $B/source'
ok "the kiosk uses it" '[ "$(otr_logo)" = $B/logo.png ]'
ok "no boot image in the folder: the image's own" '[ "$(otr_splash)" = $OTR/branding/splash.png ] && grep -qx splash=image $B/source'
png $M/config/branding/$H/logo.png 100 40; $OTR/branding.sh sync $M
ok "the logo of the device wins" 'cmp -s $M/config/branding/$H/logo.png $B/logo.png && grep -qx logo=device $B/source'
cp $B/logo.png /tmp/prev-logo.png
png $M/config/branding/splash.png 2000 300; $OTR/branding.sh sync $M; $OTR/branding.sh sync $M
ok "a background picture over the size limit is refused, reported once" '[ ! -f $B/splash.png ] && [ "$(grep -c "background picture of the management folder REJECTED" $OTR_EVENTS)" = 1 ]'
echo "not a picture" > $M/config/branding/$H/logo.png; $OTR/branding.sh sync $M
ok "a broken logo keeps the previous one" 'cmp -s /tmp/prev-logo.png $B/logo.png && grep -qx logo=device $B/source && grep -q "logo of the management folder REJECTED (device)" $OTR_EVENTS'
# boot splash: an installed system (grub, theme), update-initramfs and systemd-run as stand-ins
TH=/usr/share/plymouth/themes/openthinrdp; mkdir -p /boot/grub $TH; touch /etc/default/grub
cp $OTR/branding/splash.png $TH/logo.png
sed -e 's/@TOP@/0.106, 0.153, 0.200/' -e 's/@BOTTOM@/0.000, 0.000, 0.000/' /src/image/lb/plymouth/openthinrdp.script > $TH/openthinrdp.script
printf '#!/bin/bash\necho "$@" > /tmp/systemd-run.args\n' > /usr/local/bin/systemd-run
printf '#!/bin/bash\necho run >> /tmp/initramfs.runs\n' > /usr/local/bin/update-initramfs; chmod 755 /usr/local/bin/systemd-run /usr/local/bin/update-initramfs
printf 'BG_TOP=#1b2733\nBG_BOTTOM=#000000\n' >> $OTR_CONF
$OTR/branding.sh splash
ok "first run: what the theme shows counts as applied, nothing rebuilt" '[ -s $B/splash-applied ] && [ ! -f /tmp/systemd-run.args ]'
png $M/config/branding/splash.png 640 360; $OTR/branding.sh sync $M
sed -i 's/^BG_TOP=.*/BG_TOP=#336699/' $OTR_CONF; $OTR/branding.sh splash
ok "background picture and colors of the site never touch the boot splash" '[ "$(otr_splash)" = $B/splash.png ] && [ ! -f /tmp/systemd-run.args ] && cmp -s $OTR/branding/splash.png $TH/logo.png'
# a device that put the folder's picture on the boot splash with 0.1.1
cp $M/config/branding/splash.png $TH/logo.png; rm -f $B/splash-applied; $OTR/branding.sh splash
ok "a boot splash changed by 0.1.1 is rebuilt in the background" 'grep -q "branding.sh splash-now" /tmp/systemd-run.args'
$OTR/branding.sh splash-now; rm -f /tmp/systemd-run.args; $OTR/branding.sh splash
ok "the image's own picture and colors again, initramfs rebuilt once, then in line" 'cmp -s $OTR/branding/splash.png $TH/logo.png && grep -q "^Window.SetBackgroundTopColor(0.106, 0.153, 0.200);" $TH/openthinrdp.script && [ "$(wc -l < /tmp/initramfs.runs)" = 1 ] && grep -q "boot splash: the image.s own again" $OTR_EVENTS && [ ! -f /tmp/systemd-run.args ]'
sed -i '/^BG_/d' $OTR_CONF; rm -rf /boot/grub /etc/default/grub /usr/local/bin/systemd-run /usr/local/bin/update-initramfs
rm -rf $M/config/branding/$H $M/config/branding/*.png; $OTR/branding.sh sync $M
ok "removed from the folder: back to the image's own" '[ ! -f $B/logo.png ] && [ ! -f $B/splash.png ] && [ "$(otr_logo)" = "$(cfg LOGO)" ] && grep -q "logo removed from the management folder" $OTR_EVENTS'
$OTR/report.sh >/dev/null 2>&1
ok "the status says where they come from" 'grep -qx "BRANDING=logo=image splash=image" /run/openthinrdp-status.txt'

# --- signed software updates: throw-away keys, a "release" in local files
export GNUPGHOME=$(mktemp -d)
gpg -q --batch --passphrase '' --quick-gen-key "project <p@example.invalid>" ed25519 sign never 2>/dev/null
gpg -q --batch --passphrase '' --quick-gen-key "site <s@example.invalid>" ed25519 sign never 2>/dev/null
gpg -q --batch --passphrase '' --quick-gen-key "stranger <x@example.invalid>" ed25519 sign never 2>/dev/null
mkdir -p $OTR/keys; gpg -q --armor --export p@example.invalid > $OTR/keys/openthinrdp-release.asc
gpg -q --armor --export s@example.invalid > /etc/openthinrdp/update-key.asc
echo 0.1.0 > $OTR/VERSION
# release VERSION signed by KEY into DIR
release(){ local v=$1 k=$2 d=$3 s; s=$(mktemp -d); rm -rf "$d"; mkdir -p "$d"
  printf '#!/bin/bash\nexit 0\n' > $s/install.sh; tar -czf "$d/openthinrdp-update-$v.tar.gz" -C $s .
  printf 'version=%s\nfile=openthinrdp-update-%s.tar.gz\nsha256=%s\n' "$v" "$v" "$(sha256sum < "$d/openthinrdp-update-$v.tar.gz" | cut -c1-64)" > "$d/LATEST.txt"
  gpg -q --batch --yes --local-user "$k" --armor --detach-sign -o "$d/LATEST.txt.sig" "$d/LATEST.txt"; }
U=$OTR_LIB/update; gh(){ rm -f $U/github-checked; $OTR/auto-update.sh check-github; }
release 0.2.0 x@example.invalid /tmp/otr-release; gh
ok "github: a release signed by another key is ignored" 'grep -q "^IGNORED: invalid signature" $U/status && [ ! -d $U/pkg-0.2.0 ]'
release 0.2.0 s@example.invalid /tmp/otr-release; gh
ok "github: the site key is not enough" 'grep -q "^IGNORED: invalid signature" $U/status'
release 0.0.9 p@example.invalid /tmp/otr-release; gh
ok "github: older than the image (no update installed yet) is ignored" 'grep -q "older: ignored" $U/status'
release 0.2.0 p@example.invalid /tmp/otr-release; gh
# still on the version of the image (no update-version): prepared, then the choice on the device first
ok "first start: a newer release is offered, not installed" 'grep -q "^found 0.2.0 (github): waiting for the choice" $U/status && [ "$(cat /run/openthinrdp-update-offer)" = "0.2.0 0.1.0" ] && [ -f $U/pkg-0.2.0/install.sh ] && [ ! -f $U/attempts-0.2.0 ] && [ -f /run/openthinrdp-update-checked ]'
touch /tmp/openthinrdp-update-declined; $OTR/auto-update.sh check-github
ok "first start: declined on the device, the image's version stays" 'grep -q "^kept 0.1.0 by choice" $U/status && [ ! -f $U/attempts-0.2.0 ]'
rm -f /tmp/openthinrdp-update-declined; touch -d "-11 min" /run/openthinrdp-update-offer; $OTR/auto-update.sh check-github
ok "first start: nobody answers in 10 minutes, installed" 'grep -q "^found 0.2.0 (github): install started" $U/status && [ ! -f /run/openthinrdp-update-offer ]'
rm -f $U/attempts-0.2.0; touch /tmp/openthinrdp-update-accepted; gh
ok "github: a release signed by the project key is taken" 'grep -q "^found 0.2.0 (github): install started" $U/status && [ -f $U/pkg-0.2.0/install.sh ]'
echo x > $U/status; $OTR/auto-update.sh check-github
ok "github: asked again only after 3 hours" '[ "$(cat $U/status)" = x ]'
rm -rf /tmp/otr-release; gh
ok "github: not reachable is retried at the next run" 'grep -q "not reachable" $U/status && [ ! -f $U/github-checked ]'
rm -rf $U/pkg-* $U/attempts-*
mkdir -p /tmp/share; release 0.3.0 s@example.invalid /tmp/share/updates; $OTR/auto-update.sh check /tmp/share
ok "share: the site key is accepted" 'grep -q "^found 0.3.0 (share)" $U/status'
rm -rf $U/pkg-* $U/attempts-*
release 0.3.1 p@example.invalid /tmp/share/updates; $OTR/auto-update.sh check /tmp/share
ok "share: a release copied by the manager (project key) is accepted" 'grep -q "^found 0.3.1 (share)" $U/status'
# UPDATE_KEY=site: the manager re-signs the releases with the site key, the project key alone is not enough
rm -rf $U/pkg-* $U/attempts-*; printf 'UPDATE_KEY=site\n' >> $OTR_CONF
release 0.3.2 p@example.invalid /tmp/share/updates; $OTR/auto-update.sh check /tmp/share
ok "share, UPDATE_KEY=site: a package signed by the project key only is ignored" 'grep -q "^IGNORED: invalid signature" $U/status && [ ! -d $U/pkg-0.3.2 ]'
release 0.3.2 s@example.invalid /tmp/share/updates; $OTR/auto-update.sh check /tmp/share
ok "share, UPDATE_KEY=site: the same release re-signed with the site key is taken" 'grep -q "^found 0.3.2 (share)" $U/status'
rm -rf $U/pkg-* $U/attempts-*; mv /etc/openthinrdp/update-key.asc /tmp/site-key.asc
release 0.3.3 p@example.invalid /tmp/share/updates; $OTR/auto-update.sh check /tmp/share
ok "share, UPDATE_KEY=site on a device without a site key: the project key still counts" 'grep -q "^found 0.3.3 (share)" $U/status'
mv /tmp/site-key.asc /etc/openthinrdp/update-key.asc; sed -i '/^UPDATE_KEY=/d' $OTR_CONF; rm -rf $U/pkg-* $U/attempts-*
ok "the device reports the fingerprint of its site key" '[ "$(key_fingerprint /etc/openthinrdp/update-key.asc)" = "$(gpg --with-colons --fingerprint s@example.invalid | awk -F: "/^fpr/{print \$10; exit}")" ] && ! key_fingerprint /nonexistent'
gpg -q --armor --export x@example.invalid > /tmp/x-pub.asc; cp /etc/openthinrdp/update-key.asc /tmp/s-pub.asc; : > $OTR_EVENTS
ok "site-key.sh: a public key sent by the manager is installed and logged" '$OTR/site-key.sh install < /tmp/x-pub.asc | grep -q "^OK=" && [ "$($OTR/site-key.sh show)" = "$(key_fingerprint /tmp/x-pub.asc)" ] && grep -q "site key of the updates: $(key_fingerprint /tmp/x-pub.asc)" $OTR_EVENTS'
ok "site-key.sh: a secret key or anything else is refused, the key in place stays" 'gpg -q --batch --pinentry-mode loopback --passphrase "" --armor --export-secret-keys x@example.invalid > /tmp/x-sec.asc; ! $OTR/site-key.sh install < /tmp/x-sec.asc >/dev/null && ! echo garbage | $OTR/site-key.sh install >/dev/null && [ "$($OTR/site-key.sh show)" = "$(key_fingerprint /tmp/x-pub.asc)" ]'
$OTR/site-key.sh install < /tmp/s-pub.asc >/dev/null; rm -f /tmp/x-pub.asc /tmp/x-sec.asc /tmp/s-pub.asc
ok "UPDATE_KEY site or any" '$OTR/save-config.sh "$T" --print >/dev/null 2>&1; printf "UPDATE_KEY=Sito\n" > "$T"; $OTR/save-config.sh "$T" --print 2>&1 | grep -qx "UPDATE_KEY=site" && printf "UPDATE_KEY=garbage\n" > "$T" && $OTR/save-config.sh "$T" --print 2>&1 | grep -qx "UPDATE_KEY=any"'
ok "UPDATE_FROM share needs a management folder" '! check x "$(printf "UPDATE_FROM=share\nMGMT_SHARE=\n")"'
# UPDATE_TO: one version, also an older one (pilot groups, going back)
ok "UPDATE_TO latest or a version" 'printf "UPDATE_TO=Ultima\n" > "$T"; $OTR/save-config.sh "$T" --print 2>&1 | grep -qx "UPDATE_TO=latest" && printf "UPDATE_TO=0.1.20\n" > "$T" && $OTR/save-config.sh "$T" --print 2>&1 | grep -qx "UPDATE_TO=0.1.20" && ! check x "UPDATE_TO=0.1 20!"'
to(){ sed -i '/^UPDATE_TO=/d' $OTR_CONF; [ -n "$1" ] && echo "UPDATE_TO=$1" >> $OTR_CONF; rm -rf $U/pkg-* $U/attempts-*; }
version_index(){ mkdir -p /tmp/share/updates/versions; cp /tmp/r/LATEST.txt /tmp/share/updates/versions/$1.txt; cp /tmp/r/LATEST.txt.sig /tmp/share/updates/versions/$1.txt.sig; cp /tmp/r/*.tar.gz /tmp/share/updates/; }
release 0.3.1 p@example.invalid /tmp/r; version_index 0.3.1; echo 0.3.3 > $OTR_LIB/update-version
to 0.3.1; $OTR/auto-update.sh check /tmp/share
ok "share, UPDATE_TO older than the installed version: going back" 'grep -q "^found 0.3.1 (share, UPDATE_TO=0.3.1): going back from 0.3.3, install started" $U/status && [ -f $U/pkg-0.3.1/install.sh ] && grep -q "going back from 0.3.3 to 0.3.1" $OTR_EVENTS'
to 0.3.0; $OTR/auto-update.sh check /tmp/share
ok "share, UPDATE_TO a version not in the folder: said, nothing installed" 'grep -q "^UPDATE_TO=0.3.0: this version is not in the management folder" $U/status && [ ! -d $U/pkg-0.3.0 ]'
cp /tmp/share/updates/versions/0.3.1.txt /tmp/share/updates/versions/0.3.0.txt; cp /tmp/share/updates/versions/0.3.1.txt.sig /tmp/share/updates/versions/0.3.0.txt.sig; $OTR/auto-update.sh check /tmp/share
ok "share, an index under the name of another version is ignored" 'grep -q "^IGNORED: UPDATE_TO=0.3.0 but the index found is for 0.3.1" $U/status && [ ! -d $U/pkg-0.3.1 ]'
release 0.3.3 p@example.invalid /tmp/r; version_index 0.3.3; to 0.3.3; $OTR/auto-update.sh check /tmp/share
ok "UPDATE_TO the installed version: up to date, nothing newer" 'grep -q "^up to date: 0.3.3 (share, UPDATE_TO=0.3.3" $U/status'
to 0.1.5; $OTR/auto-update.sh check /tmp/share
ok "UPDATE_TO below the first version that knows it: refused" 'grep -q "^IGNORED: UPDATE_TO=0.1.5, going back is possible to 0.2.0 or later" $U/status'
export OTR_UPDATE_TAG_URL=file:///tmp/otr-tags/v%s
release 0.3.1 p@example.invalid /tmp/otr-tags/v0.3.1; release 0.4.0 p@example.invalid /tmp/otr-release
to ""; gh; rm -rf $U/pkg-* $U/attempts-*
to 0.3.1; $OTR/auto-update.sh check-github
ok "github: a changed UPDATE_TO is asked at once, the release v<version> is taken" 'grep -q "^found 0.3.1 (github, UPDATE_TO=0.3.1): going back from 0.3.3" $U/status && [ -f $U/pkg-0.3.1/install.sh ]'
release 0.3.1 s@example.invalid /tmp/otr-tags/v0.3.1; to 0.3.1; gh
ok "github: the release of one version needs the project signature too" 'grep -q "^IGNORED: invalid signature" $U/status'
unset OTR_UPDATE_TAG_URL; rm -rf /tmp/otr-tags /tmp/r
# going back puts back the .deb of that version (install.sh alone installs only newer ones)
dummy(){ local d; d=$(mktemp -d); mkdir -p $d/DEBIAN; printf 'Package: otr-dummy\nVersion: %s\nArchitecture: all\nMaintainer: t <t@example.invalid>\nDescription: test\n' "$1" > $d/DEBIAN/control; dpkg-deb -b $d "$2" >/dev/null; }
dummy 2.0 /tmp/otr-dummy-2.deb; dpkg -i /tmp/otr-dummy-2.deb >/dev/null 2>&1
rm -rf $U/pkg-0.3.1; mkdir -p $U/pkg-0.3.1/debs; printf '#!/bin/bash\nexit 0\n' > $U/pkg-0.3.1/install.sh; dummy 1.0 $U/pkg-0.3.1/debs/otr-dummy_1.0_all.deb
$OTR/auto-update.sh install 0.3.1 downgrade
ok "going back: the older .deb of the package is put back, the version recorded" '[ "$(dpkg-query -W -f "\${Version}" otr-dummy)" = 1.0 ] && [ "$(cat $OTR_LIB/update-version)" = 0.3.1 ] && grep -q "^up to date: 0.3.1" $U/status'
dpkg -r otr-dummy >/dev/null 2>&1; rm -f /tmp/otr-dummy-2.deb; to ""
ok "UPDATE_GITHUB must be owner/repository" '! check x "UPDATE_GITHUB=not a repo"'
ok "the manager carries the same project key as the devices" 'cmp -s /src/management/windows/openthinrdp-release.asc /src/rootfs/opt/openthinrdp/keys/openthinrdp-release.asc'
# make-update.sh without -k: the package and LATEST.txt for the manager to sign (vault), never published unsigned
rm -rf /tmp/mu; cp -a /src /tmp/mu; rm -rf /tmp/mu/out
ok "make-update without -k: LATEST.txt to sign in the manager, no signature" '/tmp/mu/management/publish/make-update.sh -v 9.0.1 >/tmp/mu.log 2>&1 && grep -q "NOT signed yet" /tmp/mu.log && grep -qx "version=9.0.1" /tmp/mu/out/update-9.0.1/LATEST.txt && [ -f /tmp/mu/out/update-9.0.1/openthinrdp-update-9.0.1.tar.gz ] && [ ! -e /tmp/mu/out/update-9.0.1/LATEST.txt.sig ]'
ok "make-update without -k does not publish into a management folder" '! /tmp/mu/management/publish/make-update.sh -v 9.0.2 -o /tmp/mu-share >/dev/null 2>&1 && [ ! -e /tmp/mu-share/updates ]'
# with -k and -o: the manager of the same version in the release, the index of the version, pinned packages kept
mkdir -p /tmp/mu-share/updates /tmp/mu-share/config; printf 'UPDATE_TO=9.0.1\n' > /tmp/mu-share/config/thinclient-a.conf
for p in 8.0.0:4 9.0.1:3 9.0.0:2 9.0.2:1; do touch -d "-${p#*:} days" /tmp/mu-share/updates/openthinrdp-update-${p%:*}.tar.gz; done
/tmp/mu/management/publish/make-update.sh -v 9.0.3 -k p@example.invalid -o /tmp/mu-share >/tmp/mu.log 2>&1
MZ=/tmp/mu/out/update-9.0.3/openthinrdp-manager-9.0.3.zip
ok "make-update: the manager zip, named and hashed in the signed LATEST.txt" 'grep -qx "manager=openthinrdp-manager-9.0.3.zip" /tmp/mu-share/updates/LATEST.txt && grep -qx "manager_sha256=$(sha256sum < $MZ | cut -c1-64)" /tmp/mu-share/updates/LATEST.txt && sqv --keyring $OTR/keys/openthinrdp-release.asc /tmp/mu-share/updates/LATEST.txt.sig /tmp/mu-share/updates/LATEST.txt >/dev/null 2>&1'
ok "make-update: the zip has the manager and its VERSION, no .exe" 'python3 -c "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1]); n=z.namelist(); sys.exit(not (\"OpenThinRDP-Manager.ps1\" in n and \"lang/en.psd1\" in n and z.read(\"VERSION\").strip()==b\"9.0.3\" and not any(x.endswith(\".exe\") for x in n)))" $MZ'
ok "make-update -o: the index of the version in updates/versions" 'cmp -s /tmp/mu-share/updates/LATEST.txt /tmp/mu-share/updates/versions/9.0.3.txt && cmp -s /tmp/mu-share/updates/LATEST.txt.sig /tmp/mu-share/updates/versions/9.0.3.txt.sig'
ok "make-update -o: the last 3 packages and the ones devices are set to are kept" '[ ! -e /tmp/mu-share/updates/openthinrdp-update-8.0.0.tar.gz ] && [ -e /tmp/mu-share/updates/openthinrdp-update-9.0.1.tar.gz ] && [ -e /tmp/mu-share/updates/openthinrdp-update-9.0.3.tar.gz ]'
rm -rf /tmp/mu /tmp/mu-share /tmp/mu.log

# --- RD Gateway: validation, and the options connect() of the kiosk gives FreeRDP (FreeRDP replaced by a stub)
ok "RD Gateway: a name, a name:port and an address are accepted" 'check x "RDP_GATEWAY=rdg.example.com" && check x "RDP_GATEWAY=rdg.example.com:8443" && check x "RDP_GATEWAY=192.0.2.10"'
ok "RD Gateway: a bad name or port is refused" '! check x "RDP_GATEWAY=rdg example" && ! check x "RDP_GATEWAY=rdg.example.com:0" && ! check x "RDP_GATEWAY=rdg.example.com:70000"'
ok "RD Gateway: use always, detect (rileva), anything else always" 'printf "RDP_GATEWAY_USE=Rileva\n" > "$T"; $OTR/save-config.sh "$T" --print 2>&1 | grep -qx "RDP_GATEWAY_USE=detect" && printf "RDP_GATEWAY_USE=x\n" > "$T" && $OTR/save-config.sh "$T" --print 2>&1 | grep -qx "RDP_GATEWAY_USE=always"'
(
  eval "$(sed -n '/^connect(){/,/^}/p; /^vm_alive(){/,/^  sleep 5/p' $OTR/kiosk.sh)"
  usb_reclaim(){ :; }; reset_cam(){ :; }; usb_opt(){ echo /usb:auto; }; touch_ids(){ :; }; usb_sound_card(){ return 1; }
  sleep(){ :; }; xrandr(){ :; }; sudo(){ :; }; xfreerdp3(){ printf '%s\n' "$@" > /tmp/frdp.args; }
  HASUDP=1 HASCAM=0 NTLMPKG=n KRBPKG=k
  cp $OTR_CONF /tmp/conf.save
  printf 'RDP_AUTH=ntlm\n' > $OTR_CONF; connect u p rdbroker.example.test; cp /tmp/frdp.args /tmp/frdp.none
  printf 'RDP_AUTH=ntlm\nRDP_GATEWAY=rdg.example.test\n' > $OTR_CONF; connect u p rdbroker.example.test; cp /tmp/frdp.args /tmp/frdp.always
  printf 'RDP_AUTH=ntlm\nRDP_GATEWAY=rdg.example.test:8443\nRDP_GATEWAY_USE=detect\n' > $OTR_CONF; connect u p rdbroker.example.test; cp /tmp/frdp.args /tmp/frdp.detect
  echo 10.9.9.9 > /tmp/kiosk.vm; vm_alive && echo alive > /tmp/frdp.vm || echo "not asked" > /tmp/frdp.vm
  cp /tmp/conf.save $OTR_CONF
)
ok "connect without a gateway: no /gateway, /network:auto (UDP)" '! grep -q "^/gateway" /tmp/frdp.none && grep -qx "/network:auto" /tmp/frdp.none && ! grep -qx -- "-multitransport" /tmp/frdp.none'
ok "connect with RDP_GATEWAY: through it, same credentials, no UDP offered" 'grep -qx "/gateway:g:rdg.example.test,type:auto,usage-method:direct" /tmp/frdp.always && grep -qx -- "-multitransport" /tmp/frdp.always && [ "$(grep -cx "/network:auto" /tmp/frdp.always)" = 1 ] && grep -qx "/v:rdbroker.example.test" /tmp/frdp.always'
ok "connect with RDP_GATEWAY_USE=detect: the gateway only when needed" 'grep -qx "/gateway:g:rdg.example.test:8443,type:auto,usage-method:detect" /tmp/frdp.detect && ! grep -qx -- "-multitransport" /tmp/frdp.detect && grep -qx "/network:auto" /tmp/frdp.detect'
ok "through a gateway the VM is not probed after a drop" 'grep -qx "not asked" /tmp/frdp.vm'
rm -f /tmp/frdp.* /tmp/conf.save /tmp/kiosk.vm

# --- VPN (vpn.sh): validation, the DNS of the tunnel in front of resolv.conf and back, the OpenVPN profile and password
WGK=xZdCoEDtS1ifk4PSADylZOMj2EMm3Ik7bFRPoRxrxAo=
ok "VPN: WireGuard settings accepted, wg and ovpn as aliases" 'check x "$(printf "VPN=WG\nVPN_SERVER=vpn.example.com\nVPN_SERVER_KEY=%s\nVPN_ADDRESS=10.8.0.15/24\nVPN_ROUTES=192.168.0.0/23, 10.1.0.0/16\nVPN_DNS=192.168.1.10" $WGK)" && printf "VPN=WG\nVPN_ROUTES=192.168.0.0/23, 10.1.0.0/16\n" > "$T" && $OTR/save-config.sh "$T" --print 2>&1 | grep -qx "VPN=wireguard" && $OTR/save-config.sh "$T" --print 2>&1 | grep -qx "VPN_ROUTES=192.168.0.0/23 10.1.0.0/16" && printf "VPN=ovpn\n" > "$T" && $OTR/save-config.sh "$T" --print 2>&1 | grep -qx "VPN=openvpn"'
ok "VPN: anything else is off" 'printf "VPN=yes\n" > "$T"; $OTR/save-config.sh "$T" --print 2>&1 | grep -qx "VPN=off"'
ok "VPN: a bad server, key, address, route or DNS is refused" '! check x "VPN_SERVER=vpn example" && ! check x "VPN_SERVER=vpn.example.com:0" && ! check x "VPN_SERVER_KEY=abc=" && ! check x "VPN_SERVER_KEY=${WGK%??}B=" && ! check x "VPN_ADDRESS=10.8.0.15" && ! check x "VPN_ADDRESS=10.8.0.15/33" && ! check x "VPN_ROUTES=192.168.0.0" && ! check x "VPN_DNS=dc1"'
ok "VPN: WireGuard without its settings is no error (the address comes per device)" 'check x "VPN=wireguard"'
(
  RUN=/tmp/vpnrun; RES=/tmp/vpnres; OURS='# OpenThinRDP VPN (vpn.sh)'; DOM=example.test; mkdir -p $RUN
  eval "$(sed -n '/^res_write(){/,/^}/p; /^dns_on(){/,/^}/p; /^dns_off(){/,/^}/p' $OTR/vpn.sh)"
  printf 'search lan\nnameserver 192.0.2.1\nnameserver 192.0.2.2\n' > $RES; cp $RES /tmp/vpnres.orig
  dns_on 10.8.0.1 192.0.2.2; cp $RES /tmp/vpnres.on; cp $RUN/resolv.before /tmp/vpnres.before1
  dns_on 10.8.0.1 192.0.2.2; cmp -s $RES /tmp/vpnres.on && cmp -s $RUN/resolv.before /tmp/vpnres.before1 && echo same > /tmp/vpnres.again
  dns_off; cp $RES /tmp/vpnres.off
  printf 'nameserver 192.0.2.1\n' > $RES; dns_on 10.8.0.1; printf 'nameserver 198.51.100.1\n' > $RES; dns_on 10.8.0.1; cp $RES /tmp/vpnres.dhcp; dns_off; cp $RES /tmp/vpnres.dhcpoff
  dns_on; cp $RES /tmp/vpnres.none
)
ok "VPN DNS: the tunnel's first, the earlier ones after (no duplicate), the domain before the local search" '[ "$(grep ^nameserver /tmp/vpnres.on | tr "\n" " ")" = "nameserver 10.8.0.1 nameserver 192.0.2.2 nameserver 192.0.2.1 " ] && grep -qx "search example.test lan" /tmp/vpnres.on && head -1 /tmp/vpnres.on | grep -qx "# OpenThinRDP VPN (vpn.sh)"'
ok "VPN DNS: applied again, nothing changes and the saved file stays the original" '[ -f /tmp/vpnres.again ]'
ok "VPN DNS: the tunnel down, resolv.conf exactly as before" 'cmp -s /tmp/vpnres.off /tmp/vpnres.orig'
ok "VPN DNS: DHCP rewrote it: the new servers after the tunnel's, and back to them at the end" 'grep -qx "nameserver 198.51.100.1" /tmp/vpnres.dhcp && [ "$(grep -m1 ^nameserver /tmp/vpnres.dhcp)" = "nameserver 10.8.0.1" ] && [ "$(cat /tmp/vpnres.dhcpoff)" = "nameserver 198.51.100.1" ]'
ok "VPN DNS: no DNS of the tunnel, resolv.conf untouched" '[ "$(cat /tmp/vpnres.none)" = "nameserver 198.51.100.1" ]'
rm -rf /tmp/vpnrun /tmp/vpnres*
P='client\r\ndev tun\r\nremote vpn.example.com 1194\r\nauth-user-pass\r\n<key>\r\nKEY\r\n</key>\r\n'
ok "VPN profile: one that runs a command is refused, nothing stored" 'printf "${P}up /tmp/x.sh\r\n" | $OTR/vpn.sh profile | grep -q "^ERROR=" && printf "${P}  Script-Security 2\n" | $OTR/vpn.sh profile | grep -q "^ERROR=" && [ ! -e $OTR_ETC/vpn/openvpn.conf ]'
ok "VPN profile: a file that is no client profile is refused" 'echo hello | $OTR/vpn.sh profile | grep -q "^ERROR=not an OpenVPN"'
ok "VPN profile: stored root-only, without the Windows line ends and the UTF-8 mark" 'printf "\xef\xbb\xbf$P" | $OTR/vpn.sh profile | grep -qx OK=profile && [ "$(stat -c %a $OTR_ETC/vpn/openvpn.conf)" = 600 ] && head -1 $OTR_ETC/vpn/openvpn.conf | grep -qx client && ! grep -q $'"'"'\r'"'"' $OTR_ETC/vpn/openvpn.conf'
ok "VPN password: two lines needed, stored root-only without the UTF-8 mark" '! printf "user\n" | $OTR/vpn.sh auth >/dev/null && printf "\xef\xbb\xbfmario\r\npass word\r\n" | $OTR/vpn.sh auth | grep -qx OK=auth && [ "$(head -1 $OTR_ETC/vpn/openvpn.auth)" = mario ] && [ "$(sed -n 2p $OTR_ETC/vpn/openvpn.auth)" = "pass word" ] && [ "$(stat -c %a $OTR_ETC/vpn/openvpn.auth)" = 600 ]'
mkdir -p /usr/local/bin; printf '#!/bin/bash\necho "$*" > /tmp/ovpn.args\necho "AUTH: Received control message: AUTH_FAILED"\n' > /usr/local/bin/openvpn; chmod 755 /usr/local/bin/openvpn
echo VPN_ROUTES=192.168.0.0/23 >> $OTR_CONF; : > $OTR_EVENTS
ok "VPN OpenVPN: profile, password, routes and the scripts of vpn.sh on the command line" '$OTR/vpn.sh openvpn-run >/dev/null; grep -q -- "--config $OTR_ETC/vpn/openvpn.conf --auth-user-pass $OTR_ETC/vpn/openvpn.auth --route 192.168.0.0 255.255.254.0" /tmp/ovpn.args && grep -q -- "--auth-retry none" /tmp/ovpn.args && grep -q -- "--up /opt/openthinrdp/vpn.sh openvpn-up" /tmp/ovpn.args'
ok "VPN OpenVPN: a refused password is not tried again at once (account lockout)" '[ -f /run/openthinrdp/vpn/openvpn.authfail ] && grep -q "refused by the server: next try in an hour" $OTR_EVENTS'
ok "VPN OpenVPN: new credentials from the manager clear the wait" 'printf "mario\nnew\n" | $OTR/vpn.sh auth >/dev/null && [ ! -e /run/openthinrdp/vpn/openvpn.authfail ]'
sed -i '/^VPN_ROUTES=/d' $OTR_CONF; rm -rf /usr/local/bin/openvpn /tmp/ovpn.args $OTR_ETC/vpn /run/openthinrdp/vpn
ok "VPN: status off when off; WireGuard without its settings says what is missing" '[ "$($OTR/vpn.sh status)" = off ] && echo VPN=wireguard >> $OTR_CONF && $OTR/vpn.sh apply && $OTR/vpn.sh status | grep -q "VPN_SERVER, VPN_SERVER_KEY and VPN_ADDRESS are needed"'
sed -i '/^VPN=/d' $OTR_CONF; $OTR/vpn.sh apply; rm -rf /run/openthinrdp/vpn

# --- Kerberos: a server's own name instead of an alias shared by two brokers, or an address
printf '%s\n' '10.9.9.1 broker1.example.test broker1' '10.9.9.2 broker2.example.test broker2' \
  '10.9.9.1 rdbroker.example.test' '10.9.9.2 rdbroker.example.test' >> /etc/hosts
ok "Kerberos: shared alias becomes one broker's own name" '[[ $(krb_host rdbroker.example.test) =~ ^broker[12]\.example\.test$ ]]'
ok "Kerberos: both brokers get picked" 'for i in $(seq 1 40); do krb_host rdbroker.example.test; done | sort -u | [ $(wc -l) = 2 ]'
ok "Kerberos: an address becomes its server's name" '[ "$(krb_host 10.9.9.2)" = broker2.example.test ]'
ok "Kerberos: an address with no name stays" '[ "$(krb_host 10.9.9.9)" = 10.9.9.9 ]'
ok "Kerberos: an unknown name stays" '[ "$(krb_host nowhere.example.test)" = nowhere.example.test ]'

ok "the secrets unit never pulls tpm2.target (on Debian it waits 90 s for a TPM a device may not have)" '! grep -q "^Wants=.*tpm2.target" /src/rootfs/etc/systemd/system/openthinrdp-secrets.service && grep -q "acpi/tables/TPM2" $OTR/secrets.sh'
ok "apply.sh unmounts only disks on USB when the USB rules change (an internal SATA disk is sd* too: /boot/efi)" 'grep -A2 "only disks on USB" /src/rootfs/opt/openthinrdp/apply.sh | grep -q "usb_of_block.*|| continue"'
ok "X starts after the device has its name (a rename under a running X leaves the screen black)" 'grep -q "touch /run/openthinrdp-name-ready" /src/rootfs/opt/openthinrdp/boot.sh && grep -q "openthinrdp-name-ready" /src/rootfs/etc/skel/.bash_profile && [ "$(grep -n "name-ready" /src/rootfs/opt/openthinrdp/boot.sh | cut -d: -f1)" -lt "$(grep -n "apply.sh. boot" /src/rootfs/opt/openthinrdp/boot.sh | cut -d: -f1)" ]'
# --- secrets in the TPM (lib/secrets.sh, secrets.sh). A fake TPM: systemd-creds "seals" with base64 while
# /tmp/faketpm exists (and gives back something else while /tmp/fakebad exists); systemd-analyze has-tpm2 answers
# like a full TPM then, like "partial" (16) otherwise
mkdir -p /usr/local/bin
printf '#!/bin/bash\n[ "$1" = has-tpm2 ] || exit 1\n[ -f /tmp/faketpm ] && exit 0 || exit 16\n' > /usr/local/bin/systemd-analyze
printf '#!/bin/bash\nin="${@: -2:1}"; out="${@: -1}"; [ -f /tmp/faketpm ] || exit 1\ncase "$1" in\n  encrypt) { echo SEALED; base64 -w0 "$in"; } > "$out" ;;\n  decrypt) [ "$(head -1 "$in")" = SEALED ] || exit 1; if [ -f /tmp/fakebad ]; then echo garbage > "$out"; else tail -n +2 "$in" | base64 -d > "$out"; fi ;;\n  *) exit 1 ;;\nesac\n' > /usr/local/bin/systemd-creds
chmod 755 /usr/local/bin/systemd-analyze /usr/local/bin/systemd-creds
. $OTR/lib/secrets.sh
C=$OTR_ETC/smb.cred; R=/run/openthinrdp/secrets
rm -rf $OTR_SEALED /run/openthinrdp; printf 'username=svc\npassword=Secret1\n' > $C; chmod 600 $C
ok "secrets: without a TPM the plain file stays" '$OTR/secrets.sh && [ -f $C ] && [ ! -L $C ] && [ "$(secret_path smb.cred)" = $C ] && [ "$(secret_mode)" = "file (no TPM)" ]'
touch /tmp/faketpm; : > $OTR_EVENTS
ok "secrets: with a TPM the plain file moves into it, its path a link to memory" '$OTR/secrets.sh && [ -L $C ] && [ "$(readlink $C)" = $R/smb.cred ] && grep -qx password=Secret1 $C && [ -s $OTR_SEALED/smb.cred.cred ] && ! grep -q Secret1 $OTR_SEALED/smb.cred.cred && grep -q "secrets moved into the TPM: smb.cred" $OTR_EVENTS'
ok "secrets: read back from memory, root only" '[ "$(secret_path smb.cred)" = $R/smb.cred ] && [ "$(stat -c %a $R/smb.cred)" = 600 ] && [ "$(secret_mode)" = tpm ]'
rm -rf /run/openthinrdp
ok "secrets: at the next start out of the TPM again, through the same path" '$OTR/secrets.sh && grep -qx password=Secret1 $C'
rm -f $C; printf 'username=x\npassword=stray\n' > $C
ok "secrets: a stray plain copy is replaced by the link" '$OTR/secrets.sh && [ -L $C ] && grep -qx password=Secret1 $C'
printf 'username=svc\npassword=Secret2\n' > /tmp/new.cred; secret_store smb.cred /tmp/new.cred
ok "secrets: a new value goes into the TPM, never to the plain file" '[ ! -e /tmp/new.cred ] && [ -L $C ] && grep -qx password=Secret2 $C && ! grep -q Secret2 $OTR_SEALED/smb.cred.cred'
touch /tmp/fakebad; printf 'ctrl_interface=/run/wpa_supplicant\n' > /tmp/w.conf; : > $OTR_EVENTS; secret_store wifi.conf /tmp/w.conf; rm -f /tmp/fakebad
ok "secrets: a TPM that does not give it back correctly leaves the plain file" '[ -f /etc/wpa_supplicant/openthinrdp-wifi.conf ] && [ ! -L /etc/wpa_supplicant/openthinrdp-wifi.conf ] && [ ! -e $OTR_SEALED/wifi.conf.cred ] && grep -q "did not give it back correctly" $OTR_EVENTS'
rm -f /etc/wpa_supplicant/openthinrdp-wifi.conf
mkdir -p /etc/ssh/sshd_config.d; printf 'fake host key\n' > /tmp/hk; secret_store ssh_host_ed25519_key /tmp/hk
ok "secrets: sshd is pointed at the host key in memory before it starts" '$OTR/secrets.sh && grep -qx "HostKey $R/ssh_host_ed25519_key" /etc/ssh/sshd_config.d/00-openthinrdp-hostkeys.conf && [ -s $R/ssh_host_ed25519_key ] && [ ! -e /etc/ssh/ssh_host_ed25519_key ]'
echo TPM_SECRETS=off >> $OTR_CONF; : > $OTR_EVENTS
ok "secrets: TPM_SECRETS=off puts them back in root-only files" '$OTR/secrets.sh && [ -f $C ] && [ ! -L $C ] && grep -qx password=Secret2 $C && [ "$(stat -c %a $C)" = 600 ] && [ -f /etc/ssh/ssh_host_ed25519_key ] && [ ! -e $OTR_SEALED/smb.cred.cred ] && [ ! -e /etc/ssh/sshd_config.d/00-openthinrdp-hostkeys.conf ] && grep -q "back to root-only files" $OTR_EVENTS && [ "$(secret_mode)" = "file (TPM_SECRETS=off)" ]'
ok "secrets: TPM_SECRETS=off moves nothing in" '$OTR/secrets.sh && [ -f $C ] && [ ! -L $C ] && [ ! -e $OTR_SEALED/smb.cred.cred ]'
sed -i '/^TPM_SECRETS=/d' $OTR_CONF; rm -f /etc/ssh/ssh_host_ed25519_key
printf '\xef\xbb\xbfTPM_SECRETS = off\r\n' > $OTR_LIB/central-common.conf
ok "secrets: off in the central settings counts before they are applied" '[ "$(secret_setting)" = off ] && $OTR/secrets.sh && [ -f $C ] && [ ! -L $C ] && [ ! -e $OTR_SEALED/smb.cred.cred ]'
printf 'TPM_SECRETS=on\n' > $OTR_LIB/central-host.conf
ok "secrets: on for this device in the central settings wins over the common off" '[ "$(secret_setting)" = on ] && $OTR/secrets.sh && [ -L $C ] && [ -s $OTR_SEALED/smb.cred.cred ]'
rm -f $OTR_LIB/central-common.conf $OTR_LIB/central-host.conf
rm -f /tmp/faketpm; rm -rf /run/openthinrdp; : > $OTR_EVENTS
ok "secrets: a TPM that does not give them back (cleared, replaced) is reported once" '$OTR/secrets.sh && [ -f $OTR_SEALED/smb.cred.cred.unreadable ] && [ ! -f $OTR_SEALED/smb.cred.cred ] && [ ! -e $C ] && grep -q "NOT readable from the TPM: smb.cred" $OTR_EVENTS && $OTR/secrets.sh && [ "$(grep -c "NOT readable" $OTR_EVENTS)" = 1 ]'
rm -rf $OTR_SEALED /run/openthinrdp /usr/local/bin/systemd-analyze /usr/local/bin/systemd-creds /etc/ssh/sshd_config.d/00-openthinrdp-hostkeys.conf

# --- USB devices held until the desktop is up (usb-hold.sh runs as root through sudo from the kiosk)
ok "usb-hold: only VID:PID ids are accepted" '! $OTR/usb-hold.sh hold "abcd:1234" "1-1;reboot" 2>/dev/null && ! $OTR/usb-hold.sh hold ../x 2>/dev/null'
ok "usb-hold: a held entry that is not a hub port is never written" 'mkdir -p /tmp/x-port1; echo 1 > /tmp/x-port1/disable; printf "%s\n" /sys/devices/../../tmp/x-port1 /tmp/x-port1 > /run/openthinrdp-usb-held; $OTR/usb-hold.sh release && [ "$(cat /tmp/x-port1/disable)" = 1 ] && [ ! -e /run/openthinrdp-usb-held ]'
ok "usb-hold: the kiosk may run it through sudo" 'grep -q "/opt/openthinrdp/usb-hold.sh" /etc/sudoers.d/openthinrdp'

echo "passed $PASS, failed $FAIL"
[ $FAIL = 0 ]
