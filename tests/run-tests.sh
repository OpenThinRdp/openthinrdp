#!/bin/bash
# OpenThinRDP tests that need no hardware: settings layers, validation, central configuration, status file.
# Runs as root inside a throw-away Debian 13 container (it installs the rootfs into /):
#   docker run --rm -v "$PWD":/src:ro debian:trixie bash /src/tests/run-tests.sh
set -u
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null && apt-get install -y -qq wpasupplicant iproute2 procps systemd python3 gnupg sqv openssl tzdata >/dev/null 2>&1
# software updates are fetched from local files: no test ever talks to GitHub
export OTR_UPDATE_BASE_URL=file:///tmp/otr-release
# and no test sends anonymous counts (report.sh starts stats.sh): to a closed local port
export OTR_STATS_URL=http://127.0.0.1:9/count
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
ok "Dutch accepted" 'check x "LANGUAGE=nl"'
# the hardware test: a report with its counts, and nothing in it that identifies the device or the network
ST=$($OTR/selftest.sh 2>/dev/null)
ok "selftest.sh: a report with its counts and its sections" 'echo "$ST" | grep -qE "^[0-9]+ OK, [0-9]+ warnings, [0-9]+ problems" && echo "$ST" | grep -q "^### Network" && echo "$ST" | grep -q "^### Remote desktop"'
ok "selftest.sh: no IPv4 or MAC address in the report (and it never prints the host name)" '! echo "$ST" | grep -qE "([0-9]{1,3}\.){3}[0-9]{1,3}|([0-9a-f]{2}:){5}[0-9a-f]{2}" && ! grep -q hostname /src/rootfs/opt/openthinrdp/selftest.sh'
# no folder, updates from the folder: refused without an account, accepted with the account only in the credentials
# file (devices converted from another system have no MGMT_USER), as found on a production device (#97)
ok "no folder and no account: folder updates refused" '! check x "$(printf "UPDATE_FROM=share\nMGMT_SHARE=")"'
CF=$(. $OTR/lib/secrets.sh; secret_path smb.cred); mkdir -p "$(dirname "$CF")"; printf 'username=svc\npassword=x\n' > "$CF"
ok "no folder, account only in the credentials file: folder updates accepted (folder from the domain)" 'check x "$(printf "UPDATE_FROM=share\nMGMT_SHARE=")"'
rm -f "$CF"
# every translation: only plain KEY="text" lines (it is sourced as root), the keys of en.sh, the same %s
LANG_EN=/src/rootfs/opt/openthinrdp/lang/en.sh
lang_plain(){ ! grep -vE '^\s*(#.*)?$|^[A-Z][A-Z0-9_]*="([^"\\`$]|\\.)*"\s*$' "$1" | grep -q .; }
lang_keys(){ grep -oE '^[A-Z][A-Z0-9_]*=' "$1" | sort -u; }
lang_known(){ [ -z "$(comm -13 <(lang_keys "$LANG_EN") <(lang_keys "$1"))" ]; }
# key and number of %s/%d, one line per key
lang_fmt(){ grep -E '^[A-Z]' "$1" | while IFS= read -r l; do printf '%s %s\n' "${l%%=*}" "$(grep -oE '%[sd]' <<< "${l#*=}" | wc -l)"; done | sort; }
lang_same_fmt(){ [ -z "$(join <(lang_fmt "$LANG_EN") <(lang_fmt "$1") | awk '$2 != $3')" ]; }
for L in /src/rootfs/opt/openthinrdp/lang/*.sh; do
  ok "lang/${L##*/}: only KEY=\"text\" lines" 'lang_plain "$L"'
  ok "lang/${L##*/}: no key unknown to en.sh" 'lang_known "$L"'
  ok "lang/${L##*/}: the same %s and %d as en.sh" 'lang_same_fmt "$L"'
done
ok "RDP_EXTRA with shell characters refused" '! check x "RDP_EXTRA=/foo;reboot"'
# the messages follow the language the device is using now
printf 'LANGUAGE=it\n' > /etc/openthinrdp/openthinrdp.conf; printf 'HOSTNAME=12345\n' > "$T"
ok "messages in Italian" '$OTR/save-config.sh "$T" --print 2>&1 | grep -q "Nome macchina non valido"'
: > /etc/openthinrdp/openthinrdp.conf

# --- normalization: the stored form
printf 'USB_MODE=Dischi\nUSB_REDIRECT=1EAF:0009,346d:5678\nNTP=a.example.com;b.example.com\nSECURITY_UPDATES=Yes\nPOWER_ON_DAYS=5,1,3\nSHUTDOWN_SECS=030\n' > "$T"
P=$($OTR/save-config.sh "$T" --print 2>&1)
ok "aliases and separators normalized" 'echo "$P" | grep -qx "USB_MODE=disks" && echo "$P" | grep -qx "USB_REDIRECT=1eaf:0009 346d:5678" && echo "$P" | grep -qx "NTP=a.example.com b.example.com" && echo "$P" | grep -qx "SECURITY_UPDATES=on" && echo "$P" | grep -qx "POWER_ON_DAYS=135" && echo "$P" | grep -qx "SHUTDOWN_SECS=30"'
# time zone: a zone the image has, nothing else; apply.sh sets it (its block run here: apply.sh is a no-op in the tests)
ok "time zone: Europe/Amsterdam and UTC accepted, a made-up zone or a path refused" 'check x "TIMEZONE=Europe/Amsterdam" && check x "TIMEZONE=UTC" && check x "TIMEZONE=" && ! check x "TIMEZONE=Mars/Base" && ! check x "TIMEZONE=../../etc/passwd" && ! check x "TIMEZONE=Europe/../../etc/passwd"'
printf 'TIMEZONE=Europe/Amsterdam\n' > /etc/openthinrdp/openthinrdp.conf; : > $OTR_EVENTS
( set +u; eval "$(sed -n '/^# --- time zone/,/^fi$/p' /src/rootfs/opt/openthinrdp/apply.sh)" )
ok "time zone: applied to the clock, said once in the events" '[ "$(readlink /etc/localtime)" = /usr/share/zoneinfo/Europe/Amsterdam ] && [ "$(cat /etc/timezone)" = Europe/Amsterdam ] && grep -q "time zone: Europe/Amsterdam" $OTR_EVENTS'
: > /etc/openthinrdp/openthinrdp.conf; : > $OTR_EVENTS
# report interval: 2 to 30 minutes, applied as a drop-in of the timer; reports spread at random (a large fleet)
ok "REPORT_INTERVAL: 2 to 30 minutes, 5 when empty" 'check x "REPORT_INTERVAL=10" && check x "REPORT_INTERVAL=" && ! check x "REPORT_INTERVAL=1" && ! check x "REPORT_INTERVAL=31" && ! check x "REPORT_INTERVAL=x"'
printf 'REPORT_INTERVAL=10\n' > /etc/openthinrdp/openthinrdp.conf
( set +u; systemctl(){ :; }; eval "$(sed -n '/^# --- how often the status is sent/,/^else rm -f \$DI\/interval.conf.new; fi$/p' /src/rootfs/opt/openthinrdp/apply.sh)" )
ok "REPORT_INTERVAL: the timer of the reports every 10 minutes, a minute at random on top" 'grep -qx "OnUnitActiveSec=10min" /etc/systemd/system/openthinrdp-report.timer.d/interval.conf && grep -qx "RandomizedDelaySec=60" /etc/systemd/system/openthinrdp-report.timer && grep -q "REPORT_INTERVAL=\$(cfg_num REPORT_INTERVAL 5)" $OTR/report.sh'
: > /etc/openthinrdp/openthinrdp.conf; rm -rf /etc/systemd/system/openthinrdp-report.timer.d
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
# the disk the system runs from (a Raspberry Pi booting from a USB disk): root and boot partition on 1-6, a stick
# mounted in /media on 1-1, the root of a PC on a SATA disk (no USB device above it)
mkd 1-6 08; echo 0006 > $UT/1-6/idProduct; echo 0001 > $UT/1-1/idProduct
mkdir -p $UT/1-6/1-6:1.0/host0/block/sda/sda1 $UT/1-6/1-6:1.0/host0/block/sda/sda2 $UT/1-1/1-1:1.0/host1/block/sdb/sdb1 $UT/ata/block/sdc/sdc2 $UT/devblock
ln -s $UT/1-6/1-6:1.0/host0/block/sda/sda2 $UT/devblock/8:2; ln -s $UT/1-6/1-6:1.0/host0/block/sda/sda1 $UT/devblock/8:1
ln -s $UT/1-1/1-1:1.0/host1/block/sdb/sdb1 $UT/devblock/8:17; ln -s $UT/ata/block/sdc/sdc2 $UT/devblock/8:34
printf '%s\n' '22 1 8:2 / / rw - ext4 /dev/sda2 rw' '23 22 8:1 / /boot/firmware rw - vfat /dev/sda1 rw' '24 22 0:5 / /proc rw - proc proc rw' \
  '25 22 8:17 / /media/STICK rw - vfat /dev/sdb1 rw' > $UT/mountinfo
ok "the USB disk of the system is found, a stick in /media is not" '[ "$(USB_DEVBLOCK=$UT/devblock USB_MOUNTINFO=$UT/mountinfo usb_system_ids)" = 1234:0006 ]'
printf '%s\n' '22 1 8:34 / / rw - ext4 /dev/sdc2 rw' > $UT/mountinfo
ok "a system on a disk that is not USB: no USB device to keep" '[ -z "$(USB_DEVBLOCK=$UT/devblock USB_MOUNTINFO=$UT/mountinfo usb_system_ids)" ]'
ok "the kiosk never passes the disk of the system, also when listed in USB_REDIRECT" '( eval "$(sed -n "/^usb_opt(){/,/^}/p" $OTR/kiosk.sh)"; CAMID=""; USBFILTER=""; usb_all_ids(){ echo "1234:0006 abcd:0001"; }; usb_system_ids(){ echo 1234:0006; }; printf "USB_MODE=all\nUSB_REDIRECT=1234:0006\n" > $OTR_CONF; [ "$(usb_opt)" = "/usb:auto,id:abcd:0001" ] )'
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
# a setting this version does not know yet (written by a newer manager): left out, the rest applied as before
printf 'SOME_FUTURE_SETTING=on\r\n' >> $OTR_LIB/central-common.conf; $OTR/central-apply.sh
ok "a setting unknown to this version (a newer manager) is left out, the central settings still applied" 'grep -qE "^(applied|in line)" $OTR_LIB/central-status && ! grep -q "^SOME_FUTURE_SETTING" $OTR_CONF && grep -qx "USB_MODE=disks" $OTR_CONF'
sed -i '/^SOME_FUTURE_SETTING/d' $OTR_LIB/central-common.conf; $OTR/central-apply.sh
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

# --- the group layer: between common.conf and the file of the device; it may not set what identifies a device
printf 'USB_MODE=all\r\nSHUTDOWN_SECS=45\r\nHOSTNAME=from-group\r\nDEVICE_GROUP=other\r\n' > $OTR_LIB/central-group.conf
printf 'HOSTNAME=kiosk-test\r\nSHUTDOWN_SECS=50\r\n' > $OTR_LIB/central-host.conf
$OTR/central-apply.sh
ok "group: its values win over common.conf" 'grep -qx "USB_MODE=all" $OTR_CONF'
ok "group: the file of the device wins over the group" 'grep -qx "SHUTDOWN_SECS=50" $OTR_CONF'
ok "group: may not set HOSTNAME or DEVICE_GROUP" '[ "$(hostname)" != from-group ] && ! grep -q "^DEVICE_GROUP=other" $OTR_CONF'
rm -f $OTR_LIB/central-group.conf; printf 'HOSTNAME=kiosk-test\r\n' > $OTR_LIB/central-host.conf; $OTR/central-apply.sh
ok "group: removed, its keys go back to common.conf" 'grep -qx "USB_MODE=disks" $OTR_CONF'
ok "DEVICE_GROUP: a name, nothing else" 'check x "DEVICE_GROUP=shop-1" && ! check x "DEVICE_GROUP=a/b"'

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
# release VERSION signed by KEY into DIR [MAJOR: the newest major update, major= of LATEST.txt]
release(){ local v=$1 k=$2 d=$3 s; s=$(mktemp -d); rm -rf "$d"; mkdir -p "$d"
  printf '#!/bin/bash\nexit 0\n' > $s/install.sh
  printf '# Changelog\n\n## %s (2026-01-01)\n\n- **New** in %s\n\n## 0.1.5 (2025-12-01)\n\n- between\n\n## 0.1.0 (2025-11-01)\n\n- the image\n' "$v" "$v" > $s/CHANGELOG.md
  tar -czf "$d/openthinrdp-update-$v.tar.gz" -C $s .
  printf 'version=%s\nfile=openthinrdp-update-%s.tar.gz\nsha256=%s\n' "$v" "$v" "$(sha256sum < "$d/openthinrdp-update-$v.tar.gz" | cut -c1-64)" > "$d/LATEST.txt"
  [ -n "${4:-}" ] && echo "major=$4" >> "$d/LATEST.txt"
  gpg -q --batch --yes --local-user "$k" --armor --detach-sign -o "$d/LATEST.txt.sig" "$d/LATEST.txt"; }
U=$OTR_LIB/update; gh(){ rm -f $U/github-checked; $OTR/auto-update.sh check-github; }
release 0.2.0 x@example.invalid /tmp/otr-release; gh
ok "github: a release signed by another key is ignored" 'grep -q "^IGNORED: invalid signature" $U/status && [ ! -d $U/pkg-0.2.0 ]'
release 0.2.0 s@example.invalid /tmp/otr-release; gh
ok "github: the site key is not enough" 'grep -q "^IGNORED: invalid signature" $U/status'
release 0.0.9 p@example.invalid /tmp/otr-release; gh
ok "github: older than the image (no update installed yet) is ignored" 'grep -q "older: ignored" $U/status'
# no management folder (no central settings): every new version is asked on the device, with its changes
[ -f $OTR_LIB/central-common.conf ] && mv $OTR_LIB/central-common.conf /tmp/cc.keep
release 0.2.0 p@example.invalid /tmp/otr-release; gh
ok "no management folder: a newer release is offered on the device, not installed" 'grep -q "^found 0.2.0 (github): asked on the device at the sign-in$" $U/status && [ "$(cat /run/openthinrdp-update-offer)" = "0.2.0 0.1.0 " ] && [ -f $U/pkg-0.2.0/install.sh ] && [ ! -f $U/attempts-0.2.0 ] && [ -f /run/openthinrdp-update-checked ]'
ok "no management folder: the changes since the installed version, as plain text" 'grep -qx -- "- New in 0.2.0" /run/openthinrdp-update-notes && grep -q between /run/openthinrdp-update-notes && ! grep -q "the image" /run/openthinrdp-update-notes && ! grep -q "\*\*" /run/openthinrdp-update-notes'
touch -d "-11 min" /run/openthinrdp-update-offer; gh
ok "no management folder: nobody answering on the device never installs it by itself" 'grep -q "asked on the device at the sign-in" $U/status && [ ! -f $U/attempts-0.2.0 ]'
touch /tmp/openthinrdp-update-declined; $OTR/auto-update.sh check-github
ok "no management folder: not now on the device, kept until the next start" 'grep -q "^kept 0.1.0 by choice on the device" $U/status && [ ! -f $U/attempts-0.2.0 ] && [ ! -f /run/openthinrdp-update-offer ]'
rm -f /tmp/openthinrdp-update-declined; echo 0.1.9 > /tmp/openthinrdp-update-accepted; gh
ok "no management folder: a yes for another version is not one for this" 'grep -q "asked on the device" $U/status && [ ! -f $U/attempts-0.2.0 ]'
rm -f $U/attempts-0.2.0; echo 0.2.0 > /tmp/openthinrdp-update-accepted; gh
ok "github: a release signed by the project key is taken" 'grep -q "^found 0.2.0 (github): install started" $U/status && [ -f $U/pkg-0.2.0/install.sh ]'
echo x > $U/status; $OTR/auto-update.sh check-github
ok "github: asked again only after 3 hours" '[ "$(cat $U/status)" = x ]'
rm -rf /tmp/otr-release; gh
ok "github: not reachable is retried at the next run" 'grep -q "not reachable" $U/status && [ ! -f $U/github-checked ]'
rm -rf $U/pkg-* $U/attempts-* /tmp/openthinrdp-update-accepted /run/openthinrdp-update-offer
# from here a managed device: central settings from the management folder, no question on the device
printf '# the central settings of the folder\n' > $OTR_LIB/central-common.conf
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
ok "UPDATE_FROM share needs a management folder (or an account to find it in the domain)" 'CF=$(. $OTR/lib/secrets.sh; secret_path smb.cred); [ -f "$CF" ] && mv "$CF" "$CF.k"; ! check x "$(printf "UPDATE_FROM=share
MGMT_SHARE=
")"; r=$?; [ -f "$CF.k" ] && mv "$CF.k" "$CF"; [ $r = 0 ]'
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
# going back on a device of another architecture: only its own .deb (debs/<arch>/), never the other one
dummy 2.0 /tmp/otr-dummy-2.deb; dpkg -i /tmp/otr-dummy-2.deb >/dev/null 2>&1
darch(){ local d; d=$(mktemp -d); mkdir -p $d/DEBIAN; printf 'Package: otr-dummy\nVersion: %s\nArchitecture: %s\nMaintainer: t <t@example.invalid>\nDescription: test\n' "$1" "$2" > $d/DEBIAN/control; dpkg-deb -b $d "$3" >/dev/null; }
rm -rf $U/pkg-0.3.1; mkdir -p $U/pkg-0.3.1/debs/amd64 $U/pkg-0.3.1/debs/arm64; printf '#!/bin/bash\nexit 0\n' > $U/pkg-0.3.1/install.sh
darch 1.5 amd64 $U/pkg-0.3.1/debs/amd64/otr-dummy_1.5_amd64.deb; darch 1.0 arm64 $U/pkg-0.3.1/debs/arm64/otr-dummy_1.0_arm64.deb
$OTR/auto-update.sh install 0.3.1 downgrade
ok "going back: the .deb of this architecture in debs/<arch>/ is put back, the other one ignored" '[ "$(dpkg-query -W -f "\${Version}" otr-dummy)" = 1.5 ] && grep -q "^up to date: 0.3.1" $U/status'
dpkg -r otr-dummy >/dev/null 2>&1; rm -f /tmp/otr-dummy-2.deb; to ""
# the user of the device asked before the remote screen (REMOTE_CONSENT=ask): no yes = nothing starts
ok "REMOTE_CONSENT: ask or off" 'printf "REMOTE_CONSENT=chiedi\n" > "$T"; $OTR/save-config.sh "$T" --print 2>&1 | grep -qx "REMOTE_CONSENT=ask" && printf "REMOTE_CONSENT=x\n" > "$T" && $OTR/save-config.sh "$T" --print 2>&1 | grep -qx "REMOTE_CONSENT=off"'
ok "remote screen: with REMOTE_CONSENT=ask the question comes before x11vnc, and anything but a yes is ERROR=REFUSED" 'a=$(grep -n "cfg REMOTE_CONSENT)\" = ask" $OTR/remote-screen.sh | cut -d: -f1); b=$(grep -n "systemd-run --unit=\$U" $OTR/remote-screen.sh | cut -d: -f1); [ -n "$a" ] && [ "$a" -lt "$b" ] && grep -q "ui.py\" ask " $OTR/remote-screen.sh && grep -q "\[ \$a = 0 \] || {.*ERROR=REFUSED\"; exit 8; }" $OTR/remote-screen.sh'
ok "ui.py: the question at the top (ask) compiles, a popup above the session, no keyboard focus" 'python3 -m py_compile $OTR/ui.py && grep -q "^if MODE == .ask.:" $OTR/ui.py && sed -n "/^if MODE == .ask.:/,/sys.exit(code)/p" $OTR/ui.py | grep -q "WindowType.POPUP" && sed -n "/^if MODE == .ask.:/,/sys.exit(code)/p" $OTR/ui.py | grep -q "set_can_focus(False)"'
for l in en it nl; do ok "lang $l: the question of the remote screen" "grep -q '^L_REMOTE_ASK_T=' $OTR/lang/$l.sh && grep -q '^L_REMOTE_ASK=' $OTR/lang/$l.sh && grep -q '^L_REMOTE_ASK_YES=' $OTR/lang/$l.sh && grep -q '^L_REMOTE_ASK_NO=' $OTR/lang/$l.sh"; done
# signed central configuration (CONFIG_SIGNED=required): a file of the folder only with the signature of the site key
ok "CONFIG_SIGNED: required or off" 'printf "CONFIG_SIGNED=Required\n" > "$T"; $OTR/save-config.sh "$T" --print 2>&1 | grep -qx "CONFIG_SIGNED=required" && printf "CONFIG_SIGNED=x\n" > "$T" && $OTR/save-config.sh "$T" --print 2>&1 | grep -qx "CONFIG_SIGNED=off"'
eval "$(sed -n '/^    SIGNED=0; \[ "\$(cfg CONFIG_SIGNED)" = required \]/,/^      \[ -f "\$m" \] || /p' $OTR/report.sh | sed 's/^    //')"
printf 'TITLE=signed\n' > /tmp/sc.conf; gpg -q --batch --yes --local-user s@example.invalid --armor --detach-sign -o /tmp/sc.conf.sig /tmp/sc.conf
ok "signed configuration: a file signed with the site key taken, a changed one or one without signature not" 'SIGNED=1; signed_ok /tmp/sc.conf && { echo "TITLE=evil" >> /tmp/sc.conf; ! signed_ok /tmp/sc.conf; } && { rm -f /tmp/sc.conf.sig; ! signed_ok /tmp/sc.conf; } && { SIGNED=0; signed_ok /tmp/sc.conf; }'
ok "signed configuration: a missing file keeps its last settings, the keys of the folder are not dropped either" 'grep -q "elif \[ \$SIGNED = 1 \] && \[ -f \"\$OTR_LIB/central-\$n.conf\" \]; then :" $OTR/report.sh && grep -q "authorized_keys.central\" \] && \[ \$SIGNED = 0 \]" $OTR/report.sh'
rm -f /tmp/sc.conf /tmp/sc.conf.sig
# major updates: LATEST.txt names the newest one (major=); crossing it needs UPDATE_MAJOR, written by the manager
ok "UPDATE_MAJOR a version or empty" 'check x "UPDATE_MAJOR=0.4.1" && check x "UPDATE_MAJOR=" && ! check x "UPDATE_MAJOR=0.4 1!"'
echo 0.4.0 > $OTR_LIB/update-version; release 0.4.2 p@example.invalid /tmp/share/updates 0.4.1; $OTR/auto-update.sh check /tmp/share
ok "major update, managed: crossing it without UPDATE_MAJOR from the manager, not installed" 'grep -q "^found 0.4.2 (share): major update (0.4.1), installed once it is released from the manager" $U/status && [ ! -f $U/attempts-0.4.2 ] && [ ! -f /run/openthinrdp-update-offer ]'
echo UPDATE_MAJOR=0.4.0 >> $OTR_CONF; $OTR/auto-update.sh check /tmp/share
ok "major update, managed: an older UPDATE_MAJOR is not enough" 'grep -q "major update (0.4.1), installed once it is released" $U/status && [ ! -f $U/attempts-0.4.2 ]'
sed -i '/^UPDATE_MAJOR=/d' $OTR_CONF; echo UPDATE_MAJOR=0.4.1 >> $OTR_CONF; $OTR/auto-update.sh check /tmp/share
ok "major update, managed: released by the manager (UPDATE_MAJOR), installed" 'grep -q "^found 0.4.2 (share): install started" $U/status'
sed -i '/^UPDATE_MAJOR=/d' $OTR_CONF; rm -rf $U/pkg-* $U/attempts-*; echo 0.4.1 > $OTR_LIB/update-version; $OTR/auto-update.sh check /tmp/share
ok "major update already installed: the next ones install by themselves" 'grep -q "^found 0.4.2 (share): install started" $U/status'
rm -rf $U/pkg-* $U/attempts-*; echo 0.4.0 > $OTR_LIB/update-version; mv $OTR_LIB/central-common.conf /tmp/cc2; $OTR/auto-update.sh check /tmp/share
ok "major update, no management folder: offered on the device as a major one" 'grep -q "asked on the device at the sign-in, major update$" $U/status && [ "$(cat /run/openthinrdp-update-offer)" = "0.4.2 0.4.0 0.4.1" ]'
mv /tmp/cc2 $OTR_LIB/central-common.conf; rm -rf $U/pkg-* $U/attempts-* /run/openthinrdp-update-offer /run/openthinrdp-update-notes /tmp/share/updates
if [ -f /tmp/cc.keep ]; then mv /tmp/cc.keep $OTR_LIB/central-common.conf; else rm -f $OTR_LIB/central-common.conf; fi
ok "kiosk: the update question only without central settings, at every sign-in round; the form redrawn for an offer" 'grep -q "^managed(){ \[ -s \"\$OTR_LIB/central-common.conf\" \]; }" $OTR/kiosk.sh && grep -q "^  managed || \[" $OTR/kiosk.sh && grep -A2 "^while true; do" $OTR/kiosk.sh | grep -q "^  update_question" && grep -q "OTR_CONF\" /run/openthinrdp-update-offer" $OTR/kiosk.sh && ! grep -q first_update $OTR/kiosk.sh'

# --- packages by architecture (lib/common.sh): the package list and the .deb files of an update package
PL=/src/image/lb/packages.list
ok "package list on amd64: GRUB, shim and the Intel driver, nothing of the Raspberry Pi" 'pkg_list amd64 $PL | grep -qx grub-efi-amd64-signed && pkg_list amd64 $PL | grep -qx shim-signed && pkg_list amd64 $PL | grep -qx intel-media-va-driver && ! pkg_list amd64 $PL | grep -qx raspi-firmware && ! pkg_list amd64 $PL | grep -q "^#"'
ok "package list on arm64: the Pi firmware and kernel, nothing of the PC" 'pkg_list arm64 $PL | grep -qx raspi-firmware && pkg_list arm64 $PL | grep -qx linux-image-arm64 && ! pkg_list arm64 $PL | grep -qE "^(grub|shim|intel-|firmware-intel|firmware-sof)"'
ok "package list: what is not tied to an architecture is in both" 'for a in amd64 arm64; do pkg_list $a $PL | grep -qx xserver-xorg && pkg_list $a $PL | grep -qx pcscd && pkg_list $a $PL | grep -qx firmware-realtek || exit 1; done'
ok "package list: #nif, and #if with more architectures" 'printf "a\n#if ARCHITECTURES arm64 armhf\nb\n#endif\n#nif ARCHITECTURES arm64\nc\n#endif\nd\n" > /tmp/pl && [ "$(pkg_list armhf /tmp/pl | tr "\n" " ")" = "a b c d " ] && [ "$(pkg_list arm64 /tmp/pl | tr "\n" " ")" = "a b d " ] && [ "$(pkg_list amd64 /tmp/pl | tr "\n" " ")" = "a c d " ]'
PD=/tmp/pd; rm -rf $PD; mkdir -p $PD/debs/amd64 $PD/debs/arm64
darch 1 all $PD/debs/x_all.deb; darch 1 amd64 $PD/debs/site_amd64.deb; darch 1 amd64 $PD/debs/amd64/f_amd64.deb; darch 1 arm64 $PD/debs/arm64/f_arm64.deb
ok "debs of an update package on amd64: its own and the ones for all" '[ "$(OTR_ARCH=amd64 pkg_debs $PD | xargs -n1 basename | sort | tr "\n" " ")" = "f_amd64.deb site_amd64.deb x_all.deb " ]'
ok "debs of an update package on arm64: never an amd64 one" '[ "$(OTR_ARCH=arm64 pkg_debs $PD | xargs -n1 basename | sort | tr "\n" " ")" = "f_arm64.deb x_all.deb " ]'
ok "install.sh takes the package list and the .deb files by architecture" 'grep -q "pkg_list \"\$ARCH\" packages.list" /src/management/publish/install.sh && grep -q "DEBS=\$(pkg_debs .)" /src/management/publish/install.sh && bash -n /src/management/publish/install.sh'
rm -rf $PD /tmp/pl
ok "UPDATE_GITHUB must be owner/repository" '! check x "UPDATE_GITHUB=not a repo"'
[ -d /src/management/windows ] && ok "the manager carries the same project key as the devices" 'cmp -s /src/management/windows/openthinrdp-release.asc /src/rootfs/opt/openthinrdp/keys/openthinrdp-release.asc'
# make-update.sh without -k: the package and LATEST.txt for the manager to sign (vault), never published unsigned
rm -rf /tmp/mu; cp -a /src /tmp/mu; rm -rf /tmp/mu/out
# the manager as build-release.ps1 leaves it (-m): a stand-in of each part
mgr(){ local d=/tmp/mgr-$1; mkdir -p $d/lang $d/commands; echo core > $d/OpenThinRDP-Manager.core; echo MZ > $d/OpenThinRDP-Manager.exe; cp $d/OpenThinRDP-Manager.exe $d/OpenThinRDP-Manager.launcher; echo stub > $d/OpenThinRDP-Manager.ps1; echo '@{}' > $d/lang/en.psd1; echo x > $d/commands/health-probe.ps1; echo "$1" > $d/VERSION; echo $d; }
ok "make-update without -k: LATEST.txt to sign in the manager, no signature" '/tmp/mu/management/publish/make-update.sh -v 9.0.1 -m $(mgr 9.0.1) >/tmp/mu.log 2>&1 && grep -q "NOT signed yet" /tmp/mu.log && grep -qx "version=9.0.1" /tmp/mu/out/update-9.0.1/LATEST.txt && [ -f /tmp/mu/out/update-9.0.1/openthinrdp-update-9.0.1.tar.gz ] && [ ! -e /tmp/mu/out/update-9.0.1/LATEST.txt.sig ]'
ok "make-update without -k does not publish into a management folder" '! /tmp/mu/management/publish/make-update.sh -v 9.0.2 -m $(mgr 9.0.2) -o /tmp/mu-share >/dev/null 2>&1 && [ ! -e /tmp/mu-share/updates ]'
# with -k and -o: the manager of the same version in the release, the index of the version, pinned packages kept
mkdir -p /tmp/mu-share/updates /tmp/mu-share/config; printf 'UPDATE_TO=9.0.1\n' > /tmp/mu-share/config/thinclient-a.conf
for p in 8.0.0:4 9.0.1:3 9.0.0:2 9.0.2:1; do touch -d "-${p#*:} days" /tmp/mu-share/updates/openthinrdp-update-${p%:*}.tar.gz; done
/tmp/mu/management/publish/make-update.sh -v 9.0.3 -m $(mgr 9.0.3) -k p@example.invalid -o /tmp/mu-share >/tmp/mu.log 2>&1
MZ=/tmp/mu/out/update-9.0.3/openthinrdp-manager-9.0.3.zip
ok "make-update: the manager zip, named and hashed in the signed LATEST.txt" 'grep -qx "manager=openthinrdp-manager-9.0.3.zip" /tmp/mu-share/updates/LATEST.txt && grep -qx "manager_sha256=$(sha256sum < $MZ | cut -c1-64)" /tmp/mu-share/updates/LATEST.txt && sqv --keyring $OTR/keys/openthinrdp-release.asc /tmp/mu-share/updates/LATEST.txt.sig /tmp/mu-share/updates/LATEST.txt >/dev/null 2>&1'
ok "make-update: the zip has the manager as released, MANIFEST.txt signed, the launcher in the zip but not in MANIFEST.txt" 'python3 -c "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1]); n=z.namelist(); m=z.read(\"MANIFEST.txt\").decode(); sys.exit(not (\"OpenThinRDP-Manager.core\" in n and \"OpenThinRDP-Manager.exe\" in n and \"MANIFEST.txt.sig\" in n and \"lang/en.psd1\" in m and \"commands/health-probe.ps1\" in m and \".exe\" not in m and z.read(\"VERSION\").strip()==b\"9.0.3\"))" $MZ'
ok "make-update -o: the index of the version in updates/versions" 'cmp -s /tmp/mu-share/updates/LATEST.txt /tmp/mu-share/updates/versions/9.0.3.txt && cmp -s /tmp/mu-share/updates/LATEST.txt.sig /tmp/mu-share/updates/versions/9.0.3.txt.sig'
ok "make-update -o: the last 3 packages and the ones devices are set to are kept" '[ ! -e /tmp/mu-share/updates/openthinrdp-update-8.0.0.tar.gz ] && [ -e /tmp/mu-share/updates/openthinrdp-update-9.0.1.tar.gz ] && [ -e /tmp/mu-share/updates/openthinrdp-update-9.0.3.tar.gz ]'
# -f: the FreeRDP builds of every architecture, each in debs/<arch>/ (stand-in packages)
FC=$(. /tmp/mu/image/freerdp/freerdp.conf; echo $FREERDP_COMMIT)
mkdir -p /tmp/mu/out/freerdp/$FC; darch 9 amd64 /tmp/mu/out/freerdp/$FC/freerdp3-x11_9_amd64.deb; (cd /tmp/mu/out/freerdp/$FC && sha256sum *.deb > SHA256SUMS)
/tmp/mu/management/publish/make-update.sh -v 9.0.4 -m $(mgr 9.0.4) -f >/tmp/mu.log 2>&1
ok "make-update -f without an arm64 build: amd64 in debs/amd64, arm64 devices keep theirs" 'grep -q "no arm64 FreeRDP packages" /tmp/mu.log && [ "$(tar -tzf /tmp/mu/out/update-9.0.4/openthinrdp-update-9.0.4.tar.gz | grep "\.deb$" | tr "\n" " ")" = "./debs/amd64/freerdp3-x11_9_amd64.deb " ]'
mkdir -p /tmp/mu/out/freerdp/$FC-arm64; darch 9 arm64 /tmp/mu/out/freerdp/$FC-arm64/freerdp3-x11_9_arm64.deb; (cd /tmp/mu/out/freerdp/$FC-arm64 && sha256sum *.deb > SHA256SUMS)
/tmp/mu/management/publish/make-update.sh -v 9.0.5 -m $(mgr 9.0.5) -f >/tmp/mu.log 2>&1
ok "make-update -f with the arm64 build too: both, each in its folder" '[ "$(tar -tzf /tmp/mu/out/update-9.0.5/openthinrdp-update-9.0.5.tar.gz | grep "\.deb$" | sort | tr "\n" " ")" = "./debs/amd64/freerdp3-x11_9_amd64.deb ./debs/arm64/freerdp3-x11_9_arm64.deb " ]'
echo broken >> /tmp/mu/out/freerdp/$FC-arm64/freerdp3-x11_9_arm64.deb
ok "make-update -f refuses an arm64 build that does not match its SHA256SUMS" '! /tmp/mu/management/publish/make-update.sh -v 9.0.6 -m $(mgr 9.0.6) -f >/dev/null 2>&1'
rm -rf /tmp/mu /tmp/mu-share /tmp/mu.log /tmp/mgr-*
ok "make-update refuses to build without the manager as released (-m)" '! /src/management/publish/make-update.sh -v 9.0.7 >/dev/null 2>&1'

# --- RD Gateway: validation, and the options connect() of the kiosk gives FreeRDP (FreeRDP replaced by a stub)
ok "RD Gateway: a name, a name:port and an address are accepted" 'check x "RDP_GATEWAY=rdg.example.com" && check x "RDP_GATEWAY=rdg.example.com:8443" && check x "RDP_GATEWAY=192.0.2.10"'
ok "RD Gateway: a bad name or port is refused" '! check x "RDP_GATEWAY=rdg example" && ! check x "RDP_GATEWAY=rdg.example.com:0" && ! check x "RDP_GATEWAY=rdg.example.com:70000"'
ok "RD Gateway: use always, detect (rileva), anything else always" 'printf "RDP_GATEWAY_USE=Rileva\n" > "$T"; $OTR/save-config.sh "$T" --print 2>&1 | grep -qx "RDP_GATEWAY_USE=detect" && printf "RDP_GATEWAY_USE=x\n" > "$T" && $OTR/save-config.sh "$T" --print 2>&1 | grep -qx "RDP_GATEWAY_USE=always"'
(
  eval "$(sed -n '/^connect(){/,/^}/p; /^vm_alive(){/,/^  sleep 5/p' $OTR/kiosk.sh)"
  usb_reclaim(){ :; }; reset_cam(){ :; }; usb_opt(){ echo /usb:auto; }; touch_ids(){ :; }; usb_sound_card(){ return 1; }
  sleep(){ :; }; xrandr(){ :; }; sudo(){ :; }; xfreerdp3(){ printf '%s\n' "$@" > /tmp/frdp.args; }
  # FreeRDP starts through setsid (no console): here it runs the stub above
  setsid(){ [ "$1" = -w ] && shift; "$@"; }
  HASUDP=1 HASCAM=0 NTLMPKG=n KRBPKG=k
  cp $OTR_CONF /tmp/conf.save
  printf 'RDP_AUTH=ntlm\n' > $OTR_CONF; connect u p rdbroker.example.test; cp /tmp/frdp.args /tmp/frdp.none
  printf 'RDP_AUTH=ntlm\nRDP_GATEWAY=rdg.example.test\n' > $OTR_CONF; connect u p rdbroker.example.test; cp /tmp/frdp.args /tmp/frdp.always
  printf 'RDP_AUTH=ntlm\nRDP_GATEWAY=rdg.example.test:8443\nRDP_GATEWAY_USE=detect\n' > $OTR_CONF; connect u p rdbroker.example.test; cp /tmp/frdp.args /tmp/frdp.detect
  echo 10.9.9.9 > /tmp/kiosk.vm; vm_alive && echo alive > /tmp/frdp.vm || echo "not asked" > /tmp/frdp.vm
  # after the UDP transport stalled (watchdog 3): TCP with auto, still UDP when UDP was asked for
  printf 'RDP_AUTH=ntlm\n' > $OTR_CONF; touch /tmp/kiosk.udpstall; connect u p rdbroker.example.test; cp /tmp/frdp.args /tmp/frdp.stalled
  printf 'RDP_AUTH=ntlm\nTRANSPORT=udp\n' > $OTR_CONF; connect u p rdbroker.example.test; cp /tmp/frdp.args /tmp/frdp.stalledudp
  rm -f /tmp/kiosk.udpstall
  cp /tmp/conf.save $OTR_CONF
)
ok "after a UDP stall: the next connections over TCP (auto), UDP stays when it is required" 'grep -qx -- "-multitransport" /tmp/frdp.stalled && grep -qx "/network:lan" /tmp/frdp.stalled && grep -qx "/network:auto" /tmp/frdp.stalledudp && ! grep -qx -- "-multitransport" /tmp/frdp.stalledudp'
ok "watchdog 3: a UDP stall is FreeRDP sending for 60 s with nothing back, kept in session-hang.log, then TCP" 'grep -q "lut )) -ge 60" $OTR/kiosk.sh && grep -q "uo - luo)) -ge 20" $OTR/kiosk.sh && grep -q "received nothing over UDP" $OTR/kiosk.sh && grep -q "touch /tmp/kiosk.udpstall" $OTR/kiosk.sh && [ -n "$(udp_counts)" ]'
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

# --- 802.1X on the cable (dot1x.sh) and Wi-Fi Enterprise (lib/eap.sh): validation, the configurations wpa_supplicant
# gets (parsed by the real one), the secrets, the certificate from the manager, the wait before DHCP and its fallback.
# The protocol itself is tested against hostapd and FreeRADIUS in a lab (docs/configuration.md#8021x-and-wi-fi-enterprise);
# here wpa_supplicant, wpa_cli and systemd are stand-ins and the adapter a directory with its carrier.
ok "802.1X: peap, tls (eap-tls) and off, anything else off; Wi-Fi psk, peap, tls, anything else psk" 'printf "DOT1X=PEAP\nWIFI_SECURITY=EAP-TLS\n" > "$T"; P=$($OTR/save-config.sh "$T" --print 2>&1); echo "$P" | grep -qx DOT1X=peap && echo "$P" | grep -qx WIFI_SECURITY=tls && printf "DOT1X=yes\nWIFI_SECURITY=wpa3\n" > "$T" && P=$($OTR/save-config.sh "$T" --print 2>&1) && echo "$P" | grep -qx DOT1X=off && echo "$P" | grep -qx WIFI_SECURITY=psk'
ok "802.1X: identities DOMAIN\\user, user@domain, host/name, a computer account; quotes and ; refused" 'check x "EAP_IDENTITY=EXAMPLE\\thin-1" && check x "EAP_IDENTITY=host/pc1.example.com" && check x "EAP_IDENTITY=PC1\$" && check x "EAP_ANONYMOUS=anonymous@example.com" && ! check x "EAP_IDENTITY=a\"b" && ! check x "EAP_ANONYMOUS=a;b"'
ok "802.1X: the CA is system (also when empty) or a .crt name of the site folder, never a path" 'printf "EAP_CA=\n" > "$T"; $OTR/save-config.sh "$T" --print 2>&1 | grep -qx EAP_CA=system && check x "EAP_CA=System" && check x "EAP_CA=corp-root.crt" && ! check x "EAP_CA=../corp.crt" && ! check x "EAP_CA=/etc/ssl/corp.crt" && ! check x "EAP_CA=corp.pem"'
ok "802.1X: server names normalized, a bad one refused" 'printf "EAP_SERVER_NAME=nps1.example.com, nps2.example.com;\n" > "$T"; $OTR/save-config.sh "$T" --print 2>&1 | grep -qx "EAP_SERVER_NAME=nps1.example.com nps2.example.com" && ! check x "EAP_SERVER_NAME=nps_1.example.com"'
ok "802.1X: a missing password or certificate is no error (the device reports it)" 'check x "DOT1X=peap" && check x "DOT1X=tls" && check x "$(printf "WIFI=on\nWIFI_SSID=Corp\nWIFI_SECURITY=peap")" && ! check x "$(printf "WIFI=on\nWIFI_SSID=Corp\nWIFI_SECURITY=psk")"'
ok "802.1X password: 256 characters at most, printed only as a hash" '! check x "EAP_PASSWORD=$(printf "%0257d" 0)" && printf "EAP_PASSWORD=Pw|with=all \$tuff\n" > "$T" && P=$($OTR/save-config.sh "$T" --print 2>&1) && ! echo "$P" | grep -q "tuff" && echo "$P" | grep -qx "EAP_PASSWORD=$(printf "Pw|with=all \$tuff" | sha256sum | cut -c1-64)"'
# a test CA, a client of it, and the CA in the site folder
X=/tmp/x509; mkdir -p $X /etc/openthinrdp/ca
openssl req -x509 -newkey rsa:2048 -nodes -keyout $X/ca.key -subj "/CN=Test CA" -days 30 -out $X/ca.crt 2>/dev/null
cli(){ openssl req -new -newkey rsa:2048 -nodes -keyout $X/$1.key -subj "/CN=$2" -out $X/$1.csr 2>/dev/null
  openssl x509 -req -in $X/$1.csr -CA $X/ca.crt -CAkey $X/ca.key -CAcreateserial ${3:--days 30} -out $X/$1.crt 2>/dev/null; }
cli client 'host\/thin1.example.test'; cli other 'host\/thin2.example.test'; cli old 'old' '-not_before 20200101000000Z -not_after 20200201000000Z'
openssl pkey -in $X/client.key -aes256 -passout pass:Key-Pw1 -out $X/client-enc.key
openssl pkcs12 -export -inkey $X/client.key -in $X/client.crt -certfile $X/ca.crt -passout pass:Pfx-Pw1 -out $X/client.p12
cp $X/ca.crt /etc/openthinrdp/ca/test-ca.crt
# stand-ins: wpa_supplicant keeps its configuration and says the lines of /tmp/wpa.script; wpa_cli writes what it is
# asked (terminate ends the supplicant); systemctl runs the unit of dot1x.sh in the background
mkdir -p /usr/local/sbin
cat > /usr/local/sbin/wpa_supplicant <<'STUB'
#!/bin/bash
rm -f /tmp/wpa.stop; IF=x
while [ $# -gt 0 ]; do case "$1" in -c) cp "$2" /tmp/wpa.conf ;; -i) IF=$2 ;; esac; shift; done
echo start >> /tmp/wpa.starts
[ -f /tmp/wpa.script ] && while IFS= read -r l; do sleep 0.2; echo "$IF: $l"; done < /tmp/wpa.script
while [ ! -f /tmp/wpa.stop ]; do sleep 0.2; done
STUB
cat > /usr/local/sbin/wpa_cli <<'STUB'
#!/bin/bash
echo "$*" >> /tmp/wpa_cli.log; case "$*" in *terminate*) touch /tmp/wpa.stop ;; esac
STUB
cat > /usr/local/sbin/systemctl <<'STUB'
#!/bin/bash
u=""; for a in "$@"; do case "$a" in openthinrdp-dot1x@*) u=${a#openthinrdp-dot1x@}; u=${u%.service} ;; esac; done
run(){ pgrep -f "dot1x.sh run $u\$" >/dev/null; }
case "$1" in
  is-active) [ -n "$u" ] && run ;;
  start) [ -n "$u" ] && { run || { setsid /opt/openthinrdp/dot1x.sh run "$u" >> /tmp/d1x-run.log 2>&1 < /dev/null & }; } ;;
  stop) [ -n "$u" ] && { pkill -f "dot1x.sh run $u\$"; touch /tmp/wpa.stop; sleep 0.5; } ;;
  list-units) pgrep -af "dot1x.sh run" | awk '{print "openthinrdp-dot1x@" $NF ".service"}' | sort -u ;;
  *) exit 1 ;;
esac
STUB
chmod 755 /usr/local/sbin/wpa_supplicant /usr/local/sbin/wpa_cli /usr/local/sbin/systemctl
export OTR_DOT1X_SYS=/tmp/sys OTR_DOT1X_NOAUTH=2 OTR_DOT1X_WAIT=10 OTR_DOT1X_HOLD=600
mkdir -p /tmp/sys/eth9; echo 1 > /tmp/sys/eth9/carrier
# one scenario: the lines the "switch" makes the supplicant say, dot1x.sh wait as ifupdown runs it, its duration
scen(){ $OTR/dot1x.sh stop eth9; rm -f /tmp/wpa.* /tmp/wpa_cli.log /run/openthinrdp/dot1x/eth9.*; printf '%s\n' "$@" > /tmp/wpa.script
  [ $# = 0 ] && rm -f /tmp/wpa.script; : > $OTR_EVENTS; S0=$(date +%s); $OTR/dot1x.sh wait eth9; WAITED=$(( $(date +%s) - S0 )); }
st(){ cat /run/openthinrdp-dot1x/eth9 2>/dev/null; }
: > $OTR_CONF
printf 'DOT1X=peap\nEAP_IDENTITY=EXAMPLE\\thin\nEAP_ANONYMOUS=anonymous@example.test\nEAP_CA=test-ca.crt\nEAP_SERVER_NAME=nps1.example.test nps2.example.test\nEAP_PASSWORD=Pw "x" \\ y\n' > "$T"
$OTR/save-config.sh "$T" >/dev/null 2>&1
ok "802.1X password: stored root-only, never in the settings" '[ "$(cat $OTR_ETC/dot1x/password)" = "Pw \"x\" \\ y" ] && [ "$(stat -c %a $OTR_ETC/dot1x/password)" = 600 ] && ! grep -q "Pw " $OTR_CONF && grep -qx "EAP_IDENTITY=EXAMPLE\\\\thin" $OTR_CONF'
printf 'EAP_PASSWORD=\n' > "$T"; $OTR/save-config.sh "$T" >/dev/null 2>&1
ok "802.1X password: an empty one keeps the saved one" '[ "$(cat $OTR_ETC/dot1x/password)" = "Pw \"x\" \\ y" ]'
scen "CTRL-EVENT-EAP-STARTED EAP authentication started" "CTRL-EVENT-EAP-PEER-CERT depth=0 subject='/O=Test/CN=nps1.example.test' hash=00" \
  "CTRL-EVENT-EAP-SUCCESS EAP authentication completed successfully"
ok "802.1X PEAP: DHCP waits for the authentication, state and event" '[ "$(st)" = "authenticated (PEAP, server nps1.example.test)" ] && [ $WAITED -le 3 ] && grep -q "802.1X: authenticated on eth9 (PEAP, server nps1.example.test)" $OTR_EVENTS'
ok "802.1X PEAP: the configuration of the wired supplicant" 'grep -qx "ap_scan=0" /tmp/wpa.conf && grep -qx "	key_mgmt=IEEE8021X" /tmp/wpa.conf && grep -qx "	eap=PEAP" /tmp/wpa.conf && grep -qx "	identity=\"EXAMPLE\\\\thin\"" /tmp/wpa.conf && grep -qx "	anonymous_identity=\"anonymous@example.test\"" /tmp/wpa.conf && grep -qx "	ca_cert=\"/etc/openthinrdp/ca/test-ca.crt\"" /tmp/wpa.conf && grep -qx "	domain_suffix_match=\"nps1.example.test;nps2.example.test\"" /tmp/wpa.conf && grep -qx "	phase2=\"auth=MSCHAPV2\"" /tmp/wpa.conf'
ok "802.1X PEAP: the password as hex, exactly (quotes, backslash, spaces)" '[ "$(sed -n "s/^	password=//p" /tmp/wpa.conf)" = "$(printf "Pw \"x\" \\\\ y" | od -An -v -tx1 | tr -d " \n")" ] && [ "$(stat -c %a /run/openthinrdp/dot1x/eth9.conf)" = 600 ]'
ok "802.1X: the real wpa_supplicant reads the wired configuration (and refuses a broken one)" '! timeout 3 /usr/sbin/wpa_supplicant -D wired -i lo -c /tmp/wpa.conf 2>&1 | grep -qE "Failed to read or parse|^Line [0-9]+:" && sed "s/eap=PEAP/eap=PEAPX/" /tmp/wpa.conf > /tmp/wpa.bad && timeout 3 /usr/sbin/wpa_supplicant -D wired -i lo -c /tmp/wpa.bad 2>&1 | grep -qE "^Line [0-9]+:"'
ok "802.1X: the state readable by all, without secrets" '[ "$(stat -c %a /run/openthinrdp-dot1x/eth9)" = 644 ] && [ "$($OTR/dot1x.sh status)" = "eth9: authenticated (PEAP, server nps1.example.test)" ]'
scen
ok "802.1X: no authenticator, DHCP after the timeout (with EAPOL-Start again meanwhile)" '[ "$(st)" = "no authenticator: DHCP without 802.1X" ] && [ $WAITED -ge 2 ] && [ $WAITED -le 5 ] && grep -q "802.1X: no authenticator on eth9" $OTR_EVENTS && grep -q "reassociate" /tmp/wpa_cli.log'
echo 0 > /tmp/sys/eth9/carrier; scen
ok "802.1X: no cable, ifup is not held (the supplicant authenticates when it comes)" '[ "$(st)" = "no link" ] && [ $WAITED -le 7 ]'
echo 1 > /tmp/sys/eth9/carrier; sleep 1.5
ok "802.1X: the cable plugged in, authenticating again" '[ "$(st)" = authenticating ] || [ "$(st)" = "no authenticator: DHCP without 802.1X" ]'
scen "CTRL-EVENT-EAP-STARTED EAP authentication started" "EAP-MSCHAPV2: failure message: 'FAILED' (retry not allowed, error 691)" "CTRL-EVENT-EAP-FAILURE EAP authentication failed"
sleep 2
ok "802.1X PEAP: a refused password stops the supplicant, not tried again for an hour (account lockout)" 'st | grep -q "^failed: password refused by the server: next try at [0-9][0-9]:[0-9][0-9], or as soon as a new password arrives$" && grep -q terminate /tmp/wpa_cli.log && [ -f /run/openthinrdp/dot1x/eth9.hold ] && [ "$(wc -l < /tmp/wpa.starts)" = 1 ] && [ $WAITED -le 3 ]'
$OTR/dot1x.sh stop eth9; S0=$(date +%s); $OTR/dot1x.sh wait eth9; WAITED=$(( $(date +%s) - S0 ))
ok "802.1X PEAP: the adapter restarted meanwhile: still waiting, said at once, nothing sent" 'st | grep -q "^failed: password refused by the server: next try at" && [ $WAITED -le 3 ] && [ "$(wc -l < /tmp/wpa.starts)" = 1 ]'
ok "802.1X: a new password from the manager clears the wait, stored as a secret" 'printf "\xef\xbb\xbfNew-Pw2\r\n" | $OTR/dot1x.sh password | grep -qx OK=password && [ "$(cat $OTR_ETC/dot1x/password)" = New-Pw2 ] && [ ! -f /run/openthinrdp/dot1x/eth9.hold ] && ! echo | $OTR/dot1x.sh password | grep -q OK'
scen "CTRL-EVENT-EAP-STARTED EAP authentication started" "CTRL-EVENT-EAP-TLS-CERT-ERROR reason=9 depth=0 subject='/CN=rogue.example.test' err='Domain suffix mismatch'" "CTRL-EVENT-EAP-FAILURE EAP authentication failed"
ok "802.1X: a server certificate refused is said, the password was not sent (no wait)" '[ "$(st)" = "failed: certificate of the server not accepted: Domain suffix mismatch (/CN=rogue.example.test)" ] && [ ! -f /run/openthinrdp/dot1x/eth9.hold ] && grep -q "802.1X: failed on eth9: certificate of the server not accepted" $OTR_EVENTS'
# the client certificate from the manager
I(){ $OTR/dot1x.sh client; }
ok "802.1X certificate: a key of another certificate, a wrong password, expired, garbage: refused, nothing stored" 'cat $X/client.crt $X/other.key | I | grep -qx "ERROR=the private key does not belong to the certificate" && { echo PASSWORD=nope; cat $X/client.crt $X/client-enc.key; } | I | grep -q "^ERROR=the private key cannot be read" && cat $X/old.crt $X/old.key | I | grep -q "^ERROR=the certificate expired" && echo hello | I | grep -qx "ERROR=no certificate" && { echo PASSWORD=nope; echo "PKCS12=$(base64 -w0 $X/client.p12)"; } | I | grep -q "^ERROR=the PKCS#12 file cannot be opened" && [ ! -e $OTR_ETC/dot1x/client.crt ] && [ ! -e $OTR_ETC/dot1x/client.key ]'
ok "802.1X certificate: PEM with an encrypted key (Windows line ends), stored decrypted as a secret" '{ echo PASSWORD=Key-Pw1; cat $X/client.crt $X/client-enc.key; } | sed "s/\$/\r/" | I | grep -q "^OK=client CN=host/thin1.example.test" && [ "$(stat -c %a $OTR_ETC/dot1x/client.key)" = 600 ] && [ "$(stat -c %a $OTR_ETC/dot1x/client.crt)" = 644 ] && head -1 $OTR_ETC/dot1x/client.key | grep -qx -- "-----BEGIN PRIVATE KEY-----" && grep -q "802.1X: client certificate received from the manager (CN=host/thin1.example.test" $OTR_EVENTS'
ok "802.1X certificate: a PKCS#12 file (.pfx) with its chain" '{ echo PASSWORD=Pfx-Pw1; echo "PKCS12=$(base64 -w0 $X/client.p12)"; } | I | grep -q "^OK=client" && [ "$(grep -c "BEGIN CERTIFICATE" $OTR_ETC/dot1x/client.crt)" = 2 ] && openssl x509 -in $OTR_ETC/dot1x/client.crt -noout -subject | grep -q thin1'
printf 'DOT1X=tls\nEAP_IDENTITY=\nEAP_ANONYMOUS=\n' > "$T"; $OTR/save-config.sh "$T" >/dev/null 2>&1
scen "CTRL-EVENT-EAP-STARTED EAP authentication started" "CTRL-EVENT-EAP-SUCCESS EAP authentication completed successfully"
ok "802.1X EAP-TLS: the certificate and key, the identity from the certificate" '[ "$(st)" = "authenticated (EAP-TLS)" ] && grep -qx "	eap=TLS" /tmp/wpa.conf && grep -qx "	identity=\"host/thin1.example.test\"" /tmp/wpa.conf && grep -qx "	client_cert=\"/etc/openthinrdp/dot1x/client.crt\"" /tmp/wpa.conf && grep -qx "	private_key=\"/etc/openthinrdp/dot1x/client.key\"" /tmp/wpa.conf && ! grep -q "password=" /tmp/wpa.conf && ! timeout 3 /usr/sbin/wpa_supplicant -D wired -i lo -c /tmp/wpa.conf 2>&1 | grep -qE "Failed to read or parse|^Line [0-9]+:"'
mv $OTR_ETC/dot1x/client.crt /tmp/client.crt.save; scen
ok "802.1X EAP-TLS without a certificate: says what is missing, DHCP at once" 'st | grep -q "^incomplete: no client certificate" && [ $WAITED -le 2 ] && grep -q "802.1X: settings incomplete on eth9: no client certificate" $OTR_EVENTS'
mv /tmp/client.crt.save $OTR_ETC/dot1x/client.crt
printf 'EAP_SERVER_NAME=\n' > "$T"; $OTR/save-config.sh "$T" >/dev/null 2>&1
ok "802.1X: without a server name the status warns" '$OTR/dot1x.sh status | grep -q "WARNING: EAP_SERVER_NAME empty"'
printf 'EAP_SERVER_NAME=nps1.example.test\n' > "$T"; $OTR/save-config.sh "$T" >/dev/null 2>&1
# Wi-Fi: the same EAP block, WPA2/WPA3-Enterprise; the personal network as before
W=/etc/wpa_supplicant/openthinrdp-wifi.conf
printf 'WIFI=on\nWIFI_SSID=Corp\nWIFI_SECURITY=tls\nWIFI_COUNTRY=it\n' > "$T"; $OTR/save-config.sh "$T" >/dev/null 2>&1
ok "Wi-Fi Enterprise EAP-TLS: WPA2/WPA3 (WPA-EAP and SHA256, PMF when offered), the 802.1X certificate" 'grep -qx "country=IT" $W && grep -qx "	ssid=\"Corp\"" $W && grep -qx "	key_mgmt=WPA-EAP WPA-EAP-SHA256" $W && grep -qx "	ieee80211w=1" $W && grep -qx "	eap=TLS" $W && grep -qx "	private_key=\"/etc/openthinrdp/dot1x/client.key\"" $W && [ "$(stat -c %a $W)" = 600 ]'
printf 'WIFI_SECURITY=peap\nEAP_IDENTITY=EXAMPLE\\thin\n' > "$T"; $OTR/save-config.sh "$T" >/dev/null 2>&1
ok "Wi-Fi Enterprise PEAP: the 802.1X password, read by the real wpa_supplicant" 'grep -qx "	eap=PEAP" $W && grep -q "^	password=$(printf New-Pw2 | od -An -v -tx1 | tr -d " \n")$" $W && ! timeout 3 /usr/sbin/wpa_supplicant -D nl80211 -i lo -c $W 2>&1 | grep -qE "Failed to read or parse|^Line [0-9]+:"'
printf 'WIFI_SECURITY=psk\n' > "$T"
ok "Wi-Fi back to a password: it must be given again" '! $OTR/save-config.sh "$T" >/dev/null 2>&1'
printf 'WIFI_SECURITY=psk\nWIFI_PSK=password123\n' > "$T"; $OTR/save-config.sh "$T" >/dev/null 2>&1
ok "Wi-Fi personal: the file exactly as before" '[ "$(cat $W)" = "$(printf "ctrl_interface=/run/wpa_supplicant\ncountry=IT\nnetwork={\n\tssid=\"Corp\"\n\tpsk=%s\n\tkey_mgmt=WPA-PSK\n\tieee80211w=1\n}" "$(wpa_passphrase Corp password123 | sed -n "s/^[[:space:]]*psk=//p")")" ]'
# central settings: the password applied once, compared by hash; a Wi-Fi key left there does not loop on enterprise
printf 'EAP_PASSWORD=Central-Eap1\r\nWIFI_SECURITY=peap\r\nWIFI_PSK=password123\r\n' > $OTR_LIB/central-common.conf; : > $OTR_EVENTS
$OTR/central-apply.sh; $OTR/central-apply.sh
ok "802.1X: the central password applied once (hidden in the events), then in line" '[ "$(cat $OTR_ETC/dot1x/password)" = Central-Eap1 ] && [ "$(grep -c "central configuration applied" $OTR_EVENTS)" = 1 ] && grep -q "EAP_PASSWORD(hidden)" $OTR_EVENTS && grep -q "^in line" $OTR_LIB/central-status'
rm -f $OTR_LIB/central-common.conf; : > $OTR_LIB/central-managed
$OTR/report.sh >/dev/null 2>&1
ok "802.1X: the report has the state, never the password or the key" 'grep -q "^DOT1X=eth9: " /run/openthinrdp-status.txt && grep -qx "CFG_DOT1X=tls" /run/openthinrdp-status.txt && ! grep -qE "Central-Eap1|New-Pw2|PRIVATE KEY|$(printf Central-Eap1 | od -An -v -tx1 | tr -d " \n")" /run/openthinrdp-status.txt $OTR_CONF $OTR_EVENTS && ! grep -q "^CFG_EAP_PASSWORD" /run/openthinrdp-status.txt'
printf 'DOT1X=off\n' > "$T"; $OTR/save-config.sh "$T" >/dev/null 2>&1; $OTR/dot1x.sh apply
ok "802.1X off: the supplicants stopped, the status says off" '! pgrep -f "dot1x.sh run" >/dev/null && [ "$($OTR/dot1x.sh status)" = off ] && [ -z "$(ls /run/openthinrdp-dot1x/)" ]'
# the settings screen of the device (kiosk.sh: the spec ui.py shows, and what comes back from it)
(
  eval "$(sed -n '/^settings_spec(){/,/^}/p; /^settings_read(){/,/^}/p' $OTR/kiosk.sh)"; otr_lang
  NETV=(dhcp static) NETL=(a b) USBV=(all) USBL=(a) ONV=(on off) ONL=(a b) TRV=(auto) TRL=(a) WEBV=(none) WEBL=(a) LNV=(en) LNL=(a)
  WSECV=(psk peap tls) WSECL=(a b c) D1XV=(off peap tls) D1XL=("$L_OFF" "$L_D1X_PEAP" "$L_D1X_TLS")
  h= u= br= brf= dom= lbi= tr=auto thr= off= nm=dhcp ip= mask= gw= d1= d2= ntp= wf=on ws= wp= um=all ur= wb=none wu= ku= kr=
  pon= poff= pdays= share= mu= mp= su=on an=on tz= ln=en ean= epw=
  wsec=peap d1x=tls d1xs="eth0: authenticated (EAP-TLS)" eid='EXAMPLE\thin' eca=system esn=nps.example.test
  settings_spec > /tmp/spec
  settings_read "$(printf 'DOT1X=peap\nEAP_PASSWORD=p w=x\nEAP_IDENTITY=EX\\u\nWIFI_SECURITY=tls\nEAP_SERVER_NAME=a.example b.example\n')"
  echo "$d1x|$epw|$eid|$wsec|$esn" > /tmp/spec.read
)
ok "settings screen: an 802.1X section with the state, the method, the identity, an empty password field" 'grep -qP "^S\t802.1X$" /tmp/spec && grep -qP "^F\tDOT1X_STATE\tro\t[^\t]+\teth0: authenticated \(EAP-TLS\)\t" /tmp/spec && grep -qP "^F\tDOT1X\tchoice\t[^\t]+\ttls\toff=Off\|peap=PEAP \(user and password\)\|tls=EAP-TLS \(certificate\)\t" /tmp/spec && grep -qP "^F\tEAP_IDENTITY\ttext\tIdentity\tEXAMPLE\\\\thin\t" /tmp/spec && grep -qP "^F\tEAP_PASSWORD\tpassword\t[^\t]+\t\t" /tmp/spec && grep -qP "^F\tWIFI_SECURITY\tchoice\t[^\t]+\tpeap\t" /tmp/spec'
ok "settings screen: what it gives back" '[ "$(cat /tmp/spec.read)" = "peap|p w=x|EX\\u|tls|a.example b.example" ]'
rm -rf /usr/local/sbin/wpa_supplicant /usr/local/sbin/wpa_cli /usr/local/sbin/systemctl /tmp/sys /tmp/wpa.* /tmp/wpa_cli.log /tmp/spec* $X $OTR_ETC/dot1x /etc/openthinrdp/ca
sed -i '/^WIFI/d; /^DOT1X/d; /^EAP_/d' $OTR_CONF; rm -f $W; unset OTR_DOT1X_SYS OTR_DOT1X_NOAUTH OTR_DOT1X_WAIT OTR_DOT1X_HOLD

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
ok "apply.sh unmounts only what usb-mount.sh mounted in /media (a Pi booting from USB: /boot/firmware)" 'grep -A1 "only disks on USB" /src/rootfs/opt/openthinrdp/apply.sh | grep -qF "\$2 ~ \"^/media/\""'
ok "a new device gets its name even when another setting is not valid, and the log says why (#80)" 'grep -qF "if R=\$(\"\$OTR/save-config.sh\" \"\$T\" 2>&1)" /src/rootfs/opt/openthinrdp/boot.sh && grep -qF "hostnamectl set-hostname \"\$N\"" /src/rootfs/opt/openthinrdp/boot.sh && grep -q "settings not valid" /src/rootfs/opt/openthinrdp/boot.sh'
# the fallback really renames: an invalid setting in the device file, save-config.sh refuses, the name is set anyway
ok "save-config.sh refuses a rename while another stored setting is invalid (the case the fallback covers)" 'printf "SESSION_THRESHOLD=200\n" > /etc/openthinrdp/openthinrdp.conf; printf "HOSTNAME=thinclient-3af1d7\n" > "$T"; R=$($OTR/save-config.sh "$T" --print 2>&1); rc=$?; : > /etc/openthinrdp/openthinrdp.conf; [ $rc -ne 0 ] && [ -n "$R" ]'
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
mkdir -p $OTR_ETC/dot1x; printf 'KEY\n' > /tmp/k; secret_store eap-client.key /tmp/k
ok "secrets: the 802.1X key in the TPM keeps its path (the Wi-Fi configuration names it), a link to memory" '[ -L $OTR_ETC/dot1x/client.key ] && [ "$(readlink $OTR_ETC/dot1x/client.key)" = $R/eap-client.key ] && grep -qx KEY $OTR_ETC/dot1x/client.key && ! grep -q KEY $OTR_SEALED/eap-client.key.cred'
rm -rf $OTR_SEALED/eap-client.key.cred $R/eap-client.key $OTR_ETC/dot1x
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

# #80: the address of the device comes from the default route when its main adapter has none
. /opt/openthinrdp/lib/netif.sh
RN=$(route_nic)
ok "netif: route_nic names the adapter of the default route" '[ -z "$(ip -4 route show default)" ] || [ -n "$RN" ]'
ok "netif: nic_ipv4 of that adapter is an IPv4 with prefix" '[ -z "$RN" ] || [[ $(nic_ipv4 "$RN") =~ ^[0-9]+(\.[0-9]+){3}/[0-9]+$ ]]'
ok "netif: nic_ipv4 of a missing adapter is empty" '[ -z "$(nic_ipv4 nosuchnic0)" ]'
ok "report: falls back to the route when the main adapter has no address" 'grep -q "IPC=\$(nic_ipv4 \"\$R\")" /opt/openthinrdp/report.sh'

# a FreeRDP that no longer reads: data waits in its socket (kiosk.sh recvq), and what it was doing is kept (hang_report)
: # recvq and hang_report come from lib/common.sh
python3 -c 'import socket,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", 47123)); s.listen(2)
for i in range(2):
    c,_=s.accept(); c.sendall(b"x" * 60000)
time.sleep(30)' & SRV=$!
sleep 1
python3 -c 'import socket,time; s=socket.create_connection(("127.0.0.1", 47123)); time.sleep(30)' & DEAF=$!
python3 -c 'import socket,time
s=socket.create_connection(("127.0.0.1", 47123))
while s.recv(65536): pass' & READER=$!
sleep 2
ok "watchdog: recvq sees the bytes a process does not read" '[ "$(recvq $DEAF)" -gt 0 ]'
ok "watchdog: recvq is 0 for a process that reads" '[ "$(recvq $READER)" -eq 0 ]'
OTR_LOG=$(mktemp -d); touch /tmp/kiosk.log; hang_report $DEAF
ok "watchdog: hang_report keeps its sockets and threads in session-hang.log" 'grep -q "^=== .* FreeRDP $DEAF" $OTR_LOG/session-hang.log && grep -q "unread [1-9]" $OTR_LOG/session-hang.log && grep -q "wchan=" $OTR_LOG/session-hang.log'
kill $SRV $DEAF $READER 2>/dev/null; rm -rf "${OTR_LOG:?}"; OTR_LOG=/var/log/openthinrdp
ok "kiosk: no systemctl is-active on the collected update unit (journal noise every 5 s)" '! grep -q "is-active -q openthinrdp-update" $OTR/kiosk.sh && grep -q "^updating()" $OTR/lib/common.sh'

# a connection can always be left: Cancel while it connects, a time limit, a stopped FreeRDP, never an empty user
ok "kiosk: Cancel on the connecting screen kills the attempt and goes back to the sign-in" 'grep -q -- "--button=\"\$L_CANCEL:30\"" $OTR/kiosk.sh && grep -q "touch /tmp/kiosk.cancel" $OTR/kiosk.sh && grep -q "\[ \$res -eq 5 \] && break" $OTR/kiosk.sh'
ok "kiosk: no desktop after the time limit, or FreeRDP stopped (state T): killed, said, not retried" 'grep -q "touch /tmp/kiosk.timeout" $OTR/kiosk.sh && grep -q "touch /tmp/kiosk.stopped" $OTR/kiosk.sh && grep -q "return 6" $OTR/kiosk.sh'
ok "kiosk: FreeRDP without a console (setsid, stdin /dev/null): it can never wait for an answer on tty1" 'grep -q "setsid -w xfreerdp3" $OTR/kiosk.sh && grep -q "< /dev/null > /tmp/kiosk.log" $OTR/kiosk.sh'
ok "kiosk: an empty user is the default one read again, else the name is asked" 'grep -q "U=\$(cfg DEFAULT_USER)" $OTR/kiosk.sh && grep -q "L_E_NOUSER" $OTR/kiosk.sh'
# setsid really leaves no console: a program that opens /dev/tty fails at once instead of waiting
ok "setsid: no controlling terminal for the child" '! setsid -w sh -c "exec 3</dev/tty" 2>/dev/null'

# the file of a device gone from the folder: its last settings stay (21/10: a default user and a kiosk lost)
ok "report: no file of this device = its last central settings kept, said once" 'grep -q "central-host.missing" $OTR/report.sh && grep -q "its last settings kept" $OTR/report.sh'

ok "ui: the buttons of a progress screen take no keyboard (an Enter after the password never presses Cancel)" 'grep -q "if A.progress: bt.set_can_focus(False)" $OTR/ui.py'

ok "kiosk: a session disconnected from the manager goes back to the sign-in, never reconnects" 'grep -q "if \[ -f /tmp/kiosk.disconnect \]; then rm -f /tmp/kiosk.disconnect" $OTR/kiosk.sh'

# the Wi-Fi page: what iw scan says, read right (strongest first, one line per name, security, hidden names out)
SCAN='BSS 11:22:33:44:55:66(on wlp2s0)
	capability: ESS Privacy ShortSlotTime (0x0411)
	signal: -71.00 dBm
	SSID: Finco Work
	RSN:	 * Version: 1
		 * Authentication suites: PSK
BSS 11:22:33:44:55:77(on wlp2s0)
	capability: ESS Privacy (0x0411)
	signal: -52.00 dBm
	SSID: Finco Work
	RSN:	 * Version: 1
		 * Authentication suites: PSK
BSS aa:bb:cc:dd:ee:01(on wlp2s0)
	capability: ESS Privacy (0x0411)
	signal: -60.00 dBm
	SSID: Finco Corp
	RSN:	 * Version: 1
		 * Authentication suites: IEEE 802.1X
BSS aa:bb:cc:dd:ee:02(on wlp2s0)
	capability: ESS Privacy (0x0411)
	signal: -80.00 dBm
	SSID: Old Router
BSS aa:bb:cc:dd:ee:03(on wlp2s0)
	capability: ESS (0x0401)
	signal: -66.00 dBm
	SSID: Guest
BSS aa:bb:cc:dd:ee:04(on wlp2s0)
	capability: ESS Privacy (0x0411)
	signal: -40.00 dBm
	SSID: 
	RSN:	 * Version: 1'
WS=$(eval "$(sed -n '/^parse_scan(){/,/^}/p' $OTR/wifi.sh)"; printf '%s\n' "$SCAN" | parse_scan)
ok "wifi.sh: scan read right: strongest first, one line per name, psk/eap/open/wep, hidden names out" '[ "$(printf "%s\n" "$WS" | head -1)" = "$(printf "%s\t%s\t%s" -52 psk "Finco Work")" ] && [ $(printf "%s\n" "$WS" | grep -c "Finco Work") -eq 1 ] && printf "%s\n" "$WS" | grep -q "eap	Finco Corp" && printf "%s\n" "$WS" | grep -q "open	Guest" && printf "%s\n" "$WS" | grep -q "wep	Old Router" && [ $(printf "%s\n" "$WS" | grep -c .) -eq 4 ]'
ok "wifi.sh: the kiosk may run it through sudo; a wrong password changes nothing (tried before save-config)" 'grep -q "/opt/openthinrdp/wifi.sh" /etc/sudoers.d/openthinrdp && [ $(grep -n "step test" $OTR/wifi.sh | cut -d: -f1) -lt $(grep -n "save-config.sh\" \"\$f\"" $OTR/wifi.sh | cut -d: -f1) ]'
ok "ui.py: compiles, with the Wi-Fi page and the network on the sign-in screen" 'python3 -m py_compile $OTR/ui.py && grep -q "^if MODE == .wifi.:" $OTR/ui.py && grep -q "leave(8)" $OTR/ui.py'
# the time zones of the settings dialog: tz_list() of ui.py run alone (UTC and every zone of tzdata, sorted)
TZN=$(python3 - "$OTR/ui.py" <<'PY'
import ast, os, sys
t = ast.parse(open(sys.argv[1]).read())
f = [n for n in t.body if isinstance(n, ast.FunctionDef) and n.name == 'tz_list'][0]
ns = {}; exec(compile(ast.Module([f], []), sys.argv[1], 'exec'), ns)
z = ns['tz_list']()
need = 300 if os.path.exists('/usr/share/zoneinfo/zone1970.tab') else 1
print('ok' if 'UTC' in z and len(z) >= need and z == sorted(z) else 'bad %d' % len(z))
PY
)
ok "settings dialog: the time zone chosen from the list of tzdata, with a search" '[ "$TZN" = ok ] && grep -q "fld TIMEZONE tz " $OTR/kiosk.sh && grep -q "elif typ == .tz.:" $OTR/ui.py'

# --- anonymous counts: on by default, what is sent, nothing when off (curl replaced: no test talks to GoatCounter)
ok "anonymous counts: on by default, the setting kept by save-config" '[ "$(cfg ANON_STATS)" = on ] && printf "ANON_STATS=No\n" > "$T" && $OTR/save-config.sh "$T" --print 2>/dev/null | grep -qx "ANON_STATS=off"'
cp $OTR_EVENTS /tmp/events.keep; : > $OTR_EVENTS
SP=$($OTR/stats.sh --print)
ok "anonymous counts: only the listed counts, no name of the device, no address; a week with no problem says none" '[ $(printf "%s\n" "$SP" | grep -c .) -eq 12 ] && ! printf "%s\n" "$SP" | grep -v "^otr/\(version\|model\|cpu\|ram\|freerdp\|transport\|language\|mode\|wifi\|tpm\|managed\)/" | grep -qvx "otr/error/none" && ! printf "%s\n" "$SP" | grep -qiF "$(hostname)" && ! printf "%s\n" "$SP" | grep -qE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+|([0-9a-f]{2}:){5}"'
# problems: counted by kind, with the exit code; older than the last send left out; users and servers never leave
n=$(date '+%Y-%m-%d %H:%M:%S')
{ echo "2000-01-01 00:00:00 software update 0.0.1 FAILED (code 1): old"
  echo "$n watchdog: FreeRDP connected but no longer reading for 60 s (5 bytes waiting), killed (session-hang.log)"
  echo "$n session of mario.rossi DROPPED after 2 min (error 145, code 145): reconnecting - [x]: srv-secret.example"
  echo "$n session of mario.rossi DROPPED after 5 min (network lost, code 147): reconnecting"
  echo "$n attempt 1 for mario.rossi on srv-secret.example failed after 3s (code 131, ERRCONNECT_X): refused"
  echo "$n connection of mario.rossi: no desktop after 150 s, stopped"; } > $OTR_EVENTS
SP=$($OTR/stats.sh --print | grep "^otr/error")
ok "anonymous counts: problems by kind, code, version and model; nothing of the messages" 'printf "%s\n" "$SP" | grep -qx "otr/error/session-frozen/1" && printf "%s\n" "$SP" | grep -qx "otr/error/session-dropped/2-5" && printf "%s\n" "$SP" | grep -qx "otr/error-detail/session-dropped/145" && printf "%s\n" "$SP" | grep -qx "otr/error-detail/session-dropped/147" && printf "%s\n" "$SP" | grep -qx "otr/error-detail/connect-failed/131" && printf "%s\n" "$SP" | grep -qx "otr/error/connect-timeout/1" && printf "%s\n" "$SP" | grep -qx "otr/error-version/session-frozen/$(cat $OTR/VERSION)" && printf "%s\n" "$SP" | grep -q "^otr/error-model/session-frozen/" && ! printf "%s\n" "$SP" | grep -q "update-failed\|otr/error/none" && ! printf "%s\n" "$SP" | grep -qi "mario\|srv-secret\|ERRCONNECT\|refused"'
: > $OTR_EVENTS
# a local server in place of GoatCounter records what really arrives (a fake curl hid that the image has no curl)
SB=$(mktemp -d); rm -f /var/lib/openthinrdp/stats-sent; GU=http://127.0.0.1:18099/count
python3 -c '
import http.server, sys, urllib.parse
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(s):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(s.path).query)
        open(sys.argv[1], "a").write(q["p"][0] + " | " + q["e"][0] + " | " + s.headers.get("User-Agent", "") + "\n")
        s.send_response(200); s.end_headers()
    def log_message(s, *a): pass
http.server.HTTPServer(("127.0.0.1", 18099), H).serve_forever()' "$SB/sent" & GS=$!
for i in $(seq 20); do python3 -c 'import socket; socket.create_connection(("127.0.0.1", 18099), 1)' 2>/dev/null && break; sleep 0.5; done
printf 'ANON_STATS=off\n' > /etc/openthinrdp/openthinrdp.conf; OTR_STATS_URL=$GU $OTR/stats.sh
ok "anonymous counts: off = nothing sent" '[ ! -e "$SB/sent" ] && [ ! -e /var/lib/openthinrdp/stats-sent ]'
: > /etc/openthinrdp/openthinrdp.conf; OTR_STATS_URL=$GU $OTR/stats.sh; n1=$(grep -c . "$SB/sent" 2>/dev/null); OTR_STATS_URL=$GU $OTR/stats.sh
ok "anonymous counts: on = sent at once the first time, as events with the OpenThinRDP agent, then not again within the week" '[ "$n1" = 12 ] && [ $(grep -c . "$SB/sent") -eq 12 ] && grep -q "^otr/version/$(cat $OTR/VERSION) | true | Mozilla/5.0 (X11; Linux x86_64) OpenThinRDP/" "$SB/sent" && [ -e /var/lib/openthinrdp/stats-sent ]'
kill $GS 2>/dev/null; wait $GS 2>/dev/null; rm -f /var/lib/openthinrdp/stats-sent; $OTR/stats.sh
ok "anonymous counts: no answer = not marked as sent, tried again at the next report" '[ ! -e /var/lib/openthinrdp/stats-sent ]'
ok "no client script calls curl (not in the image)" '! grep -nE "^[^#]*\bcurl " $OTR/*.sh $OTR/lib/*.sh'
rm -rf "$SB" /var/lib/openthinrdp/stats-sent; mv /tmp/events.keep $OTR_EVENTS
n=$(date '+%Y-%m-%d %H:%M:%S'); cp $OTR_EVENTS /tmp/events.keep
{ echo "$n watchdog: FreeRDP received nothing over UDP for 75 s while it sent 40 datagrams, killed: TCP until the device restarts (session-hang.log)"
  echo "$n power off with a session still open (FreeRDP 123): its threads in session-hang.log, its log in last-session.log"; } > $OTR_EVENTS
SP=$($OTR/stats.sh --print | grep "^otr/error/")
ok "anonymous counts: a UDP stall and a power off in a session are kinds of their own" 'printf "%s\n" "$SP" | grep -qx "otr/error/udp-stalled/1" && printf "%s\n" "$SP" | grep -qx "otr/error/switched-off-in-session/1" && ! printf "%s\n" "$SP" | grep -q session-frozen'
# at shutdown (openthinrdp-keep-log.service): the FreeRDP log kept, a FreeRDP still running said and its threads kept
: > $OTR_EVENTS; rm -f /tmp/kiosk.log.prev; cp /bin/sleep /tmp/xfreerdp3; /tmp/xfreerdp3 30 & XF=$!; echo "session log line" > /tmp/kiosk.log
$OTR/keep-session-log.sh
ok "at shutdown: the FreeRDP log kept as last-session.log; a session still open is said, its threads kept" 'grep -q "session log line" /var/log/openthinrdp/last-session.log && grep -q "power off with a session still open (FreeRDP $XF)" $OTR_EVENTS && grep -q "^=== .* FreeRDP $XF" /var/log/openthinrdp/session-hang.log'
kill $XF 2>/dev/null; rm -f /tmp/xfreerdp3 /tmp/kiosk.log /tmp/kiosk.log.prev; : > $OTR_EVENTS; $OTR/keep-session-log.sh
ok "at shutdown with no session since the start: the last kept log stays, nothing said" 'grep -q "session log line" /var/log/openthinrdp/last-session.log && ! grep -q "power off" $OTR_EVENTS && grep -q "openthinrdp-keep-log.service" /src/management/publish/install.sh'
rm -f /var/log/openthinrdp/last-session.log; mv /tmp/events.keep $OTR_EVENTS


# --- diagnostics (diag-bundle.sh): one file for the administrator, without the secrets; asked by the manager
printf 'WIFI_PSK=supersecretpsk\nEAP_PASSWORD=hunter2pw\nSETTINGS_PIN_SHA256=abcabc\nDEFAULT_USER=mario\n' >> $OTR_CONF; echo "$(date '+%F %T') an event" >> $OTR_EVENTS
rm -rf $OTR_LIB/diag /tmp/db; DB=$($OTR/diag-bundle.sh requested); mkdir -p /tmp/db; tar -xzf "$DB" -C /tmp/db 2>/dev/null
ok "diagnostics: one file with summary, events, journal and settings; passwords, keys and PIN removed, names kept" '[ -f /tmp/db/summary.txt ] && grep -q "an event" /tmp/db/events.log && [ -f /tmp/db/journal-this-start.txt ] && grep -qx "WIFI_PSK=(removed)" /tmp/db/settings.txt && grep -qx "EAP_PASSWORD=(removed)" /tmp/db/settings.txt && grep -qx "SETTINGS_PIN_SHA256=(removed)" /tmp/db/settings.txt && ! grep -rqE "supersecretpsk|hunter2pw|abcabc" /tmp/db && grep -qx "DEFAULT_USER=mario" /tmp/db/settings.txt && [ "$(stat -c %a "$DB")" = 600 ]'
$OTR/diag-bundle.sh watchdog >/dev/null; $OTR/diag-bundle.sh watchdog >/dev/null
ok "diagnostics: an automatic one (a frozen session) at most once an hour" '[ $(ls $OTR_LIB/diag/*-watchdog.tar.gz | wc -l) -eq 1 ] && grep -q "diagnostics collected (watchdog)" $OTR_EVENTS'
ok "diagnostics: asked by the manager (diag\<hostname>.request), sent to diag\ of the folder; automatic after a watchdog and at a power off in a session" 'grep -q "MNT/diag/\$H.request\" -nt \"\$OTR_LIB/diag-request-done\"" $OTR/report.sh && grep -q "cp \"\$f\" \"\$MNT/diag/\"" $OTR/report.sh && grep -q "diag-bundle.sh\" watchdog" $OTR/lib/common.sh && grep -q "diag-bundle.sh\" power-off" $OTR/keep-session-log.sh && grep -q "/opt/openthinrdp/diag-bundle.sh" /etc/sudoers.d/openthinrdp'
sed -i '/^WIFI_PSK=supersecretpsk/d; /^EAP_PASSWORD=hunter2pw/d; /^SETTINGS_PIN_SHA256=abcabc/d; /^DEFAULT_USER=mario/d' $OTR_CONF; rm -rf $OTR_LIB/diag /tmp/db


# --- 0.2.23: the scheduled jobs of the manager (schedule.sh, section 2), run by the device with the manager closed
S=/tmp/sched; rm -rf $S; mkdir -p $S/bin; cp /src/rootfs/opt/openthinrdp/schedule.sh $S/schedule.sh
# systemctl: what it was asked; is-active = nothing running (no update to wait for)
printf '#!/bin/bash\ncase "$1" in is-active) exit 3 ;; esac\necho "$*" >> /tmp/sched/systemctl.log\n' > $S/bin/systemctl; chmod +x $S/bin/systemctl
# a remote session: a process called xfreerdp3 with /u: on its command line
printf '#!/bin/bash\nsleep 300\n' > $S/xfreerdp3; chmod +x $S/xfreerdp3
ME=$(hostname); PAST=$(date -d '-1 min' '+%Y-%m-%d %H:%M'); PASTHM=$(date -d '-1 min' '+%H:%M'); JF=$OTR_LIB/jobs.conf
sched(){ rm -f $S/systemctl.log; PATH=$S/bin:$PATH bash $S/schedule.sh >/dev/null 2>&1; }
rm -f $OTR_LIB/jobs-state $OTR_LIB/jobs-last; : > $OTR_EVENTS
printf '#@j1 Riavvio\nj1|%s|once||restart|*|0|\nj2|%s|once||poweroff|other-device|0|\n' "$PAST" "$PAST" > $JF; sched
ok "jobs: a restart for all runs at its time (after the 60 s warning, nobody there to see it); one for another device does not" 'grep -qx "reboot" $S/systemctl.log && ! grep -q poweroff $S/systemctl.log && grep -q "^j1=done@" $OTR_LIB/jobs-last && grep -q "job j1 (restart): done" $OTR_EVENTS'
sched
ok "jobs: a job done is not done again" '[ ! -s $S/systemctl.log ]'
$S/xfreerdp3 /u:alice & XP=$!; sleep 0.3
printf 'j3|%s|daily||restart|%s|0|\n' "$PASTHM" "$ME" > $JF; sched
ok "jobs: with a remote session open a restart waits for it to end, said in the report" '[ ! -s $S/systemctl.log ] && grep -q "^j3=waiting@" $OTR_LIB/jobs-last && grep -q "job j3 (restart): waiting, remote session open" $OTR_EVENTS'
printf 'j4|%s|daily||restart|%s|1|\n' "$PASTHM" "$ME" > $JF; sched
ok "jobs: forced, a restart goes also with a session open (after the warning the user can cancel)" 'grep -qx "reboot" $S/systemctl.log && grep -q "^j4=done@" $OTR_LIB/jobs-last'
pkill -P $XP; kill $XP 2>/dev/null; wait $XP 2>/dev/null
printf 'j3|%s|daily||restart|%s|0|\n' "$PASTHM" "$ME" > $JF; sched
ok "jobs: the session ended, the restart that waited runs" 'grep -qx "reboot" $S/systemctl.log && grep -q "^j3=done@" $OTR_LIB/jobs-last'
echo cassa > $OTR_LIB/central-group-name
printf 'j5|%s|weekly|%s|update|g:CASSA|0|\nj6|%s|weekly|%s|poweroff|g:cassa|0|\n' "$PASTHM" "$(date -d '-1 min' +%u)" "$PASTHM" "$(date -d '+1 day' +%u)" > $JF; sched
ok "jobs: a group by its name (any case), on its days only; an update job asks now, past the window and the 3 hours; the results of jobs gone from the file dropped" 'grep -q "start --no-block openthinrdp-report.service" $S/systemctl.log && ! grep -q poweroff $S/systemctl.log && [ -f /run/openthinrdp-update-now ] && grep -q "^j5=done@" $OTR_LIB/jobs-last && ! grep -q "^j[34]=" $OTR_LIB/jobs-last'
rm -f $OTR_LIB/central-group-name /run/openthinrdp-update-now
printf 'j7|%s|once||restart|*|0|\n' "$(date -d '-4 hours' '+%Y-%m-%d %H:%M')" > $JF; sched
ok "jobs: past the 3 hours a job that never started is not run" '[ ! -s $S/systemctl.log ] && ! grep -q "^j7=" $OTR_LIB/jobs-last'
printf 'bad;id|%s|once||restart|*|0|\nj8|%s|once||format-disk|*|0|\n' "$PAST" "$PAST" > $JF; sched
ok "jobs: a line with a wrong name or an action it does not know is ignored" '[ ! -s $S/systemctl.log ] || { cat $S/systemctl.log; false; }'
rm -f $JF $OTR_LIB/jobs-state $OTR_LIB/jobs-last; rm -rf $S
ok "jobs: copied from the folder only signed as the settings, removed with the file only when signing is off" 'grep -q "if \[ -f \"\$JF\" \] && ! signed_ok \"\$JF\"; then unsigned config/jobs.conf" $OTR/report.sh && grep -q "elif \[ \$SIGNED = 0 \]; then rm -f \"\$OTR_LIB/jobs.conf\"; fi" $OTR/report.sh'
# --- the hours of the updates (UPDATE_HOURS), the report for the inventory and the peripherals, the sign-in times
ok "UPDATE_HOURS: from-to hours or empty" 'printf "UPDATE_HOURS=2-5\n" > "$T"; $OTR/save-config.sh "$T" --print 2>&1 | grep -qx "UPDATE_HOURS=2-5" && printf "UPDATE_HOURS=02:00\n" > "$T" && ! $OTR/save-config.sh "$T" --print >/dev/null 2>&1'
ok "UPDATE_HOURS: outside the hours a managed device keeps the update downloaded for later; an update job installs at once" 'grep -q "installs between \$a:00 and \$b:00 (UPDATE_HOURS)" $OTR/auto-update.sh && grep -q "find /run/openthinrdp-update-now -mmin -60" $OTR/auto-update.sh'
$OTR/report.sh >/dev/null 2>&1
ok "report: model, serial number and BIOS for the inventory, the peripherals by kind, the jobs" 'grep -q "^HW_MODEL=" /run/openthinrdp-status.txt && grep -q "^HW_SERIAL=" /run/openthinrdp-status.txt && grep -q "^BIOS=" /run/openthinrdp-status.txt && grep -q "^PERIPHERALS=" /run/openthinrdp-status.txt && grep -q "^JOBS=" /run/openthinrdp-status.txt'
ok "kiosk: the sign-in in its phases and the quality of the session, in events the manager reads" 'grep -q "ev \"sign-in of \$U: \$(tenths \$((t3 - t0))) s (broker \$(tenths \$((t1 - t0))) s, VM \$(tenths \$((t2 - t1))) s, Windows \$(tenths \$((t3 - t2))) s)" $OTR/kiosk.sh && grep -q "^    quality_event \"\$U\"" $OTR/kiosk.sh'
ok "kiosk: the quality event from the samples (latency in tenths of a ms, kbit/s over the session), none for a short session" '( eval "$(sed -n "/^duration(){/p; /^tenths(){/p; /^quality_event(){/,/kbit\/s average/p" $OTR/kiosk.sh)"; : > $OTR_EVENTS; echo "8 200 90 1000 3001000 9000 400" > /tmp/kiosk.quality; quality_event alice; echo "2 20 10 0 0 0 10" > /tmp/kiosk.quality; quality_event bob; [ "$(grep -c "session quality" $OTR_EVENTS)" = 1 ] && grep -q "session quality of alice: latency 2.5 ms (max 9.0 ms), 60 kbit/s average (peak 9000 kbit/s), 6 min" $OTR_EVENTS && [ ! -f /tmp/kiosk.quality ] )'
echo "passed $PASS, failed $FAIL"
[ $FAIL = 0 ]
