# OpenThinRDP: paths, settings and event log shared by every script. Source it: . /opt/openthinrdp/lib/common.sh
OTR=/opt/openthinrdp
OTR_ETC=/etc/openthinrdp
OTR_CONF=$OTR_ETC/openthinrdp.conf
OTR_SITE=$OTR_ETC/site.conf
OTR_DEFAULTS=$OTR/defaults.conf
OTR_LIB=/var/lib/openthinrdp
OTR_LOG=/var/log/openthinrdp
OTR_EVENTS=$OTR_LOG/events.log
# the account that runs the X session and the kiosk (no password, no shell login over the network)
OTR_KIOSK_USER=kiosk

# cfg KEY: value of a setting. The first file that defines the key wins (device, then site, then defaults),
# so an empty value in the device file deliberately clears a site default.
cfg(){
  local f
  for f in "$OTR_CONF" "$OTR_SITE" "$OTR_DEFAULTS"; do
    [ -f "$f" ] && grep -q "^$1=" "$f" && { sed -n "s/^$1=//p" "$f" | head -1 | tr -d '\r'; return; }
  done
}
# cfg_num KEY DEFAULT: a number, or DEFAULT when the value is missing or not a number
cfg_num(){ local v; v=$(cfg "$1"); [[ $v =~ ^[0-9]{1,6}$ ]] && echo $((10#$v)) || echo "$2"; }
# every key that a configuration file may contain (the ones documented in defaults.conf + HOSTNAME)
cfg_keys(){ echo HOSTNAME; grep -oE '^[A-Z][A-Z0-9_]*=' "$OTR_DEFAULTS" | tr -d '='; }

# logo and background picture in use: the ones of the management folder (branding.sh) when there, otherwise LOGO and
# the image's own
otr_logo(){ if [ -f "$OTR_LIB/branding/logo.png" ]; then echo "$OTR_LIB/branding/logo.png"; else cfg LOGO; fi; }
otr_splash(){ if [ -f "$OTR_LIB/branding/splash.png" ]; then echo "$OTR_LIB/branding/splash.png"; else echo "$OTR/branding/splash.png"; fi; }

# event log: one line per event, English, sent to the management folder by report.sh
ev(){ echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$OTR_EVENTS" 2>/dev/null; }
# a software update installing now (auto-update.sh install, started as the transient unit openthinrdp-update). Not
# "systemctl is-active": once that unit is collected, every query makes systemd log "Failed to open
# /run/systemd/transient/openthinrdp-update.service" (the kiosk asks every 5 s: 10000 lines a day)
updating(){ pgrep -f -- "$OTR/auto-update.sh install" >/dev/null 2>&1; }

# The name to connect to with Kerberos. The ticket is for TERMSRV/<server name>, and a name shared by several servers
# (a round-robin alias for the brokers) or an IP address is nobody's: the Kerberos library then looks the address up
# by itself and may pick another broker than the one connected to, which cannot open the ticket (KRB_ERROR,
# SEC_E_INTERNAL_ERROR). So the device picks one of the addresses and uses that server's own name, when its address
# leads back to it; otherwise the name stays as it is.
krb_host(){
  local ip n
  ip=$(getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u | shuf -n 1)
  [ -n "$ip" ] || { echo "$1"; return; }
  n=$(getent hosts "$ip" 2>/dev/null | awk '{print $2; exit}')
  if [[ $n == *.* ]] && getent ahostsv4 "$n" 2>/dev/null | awk '{print $1}' | grep -qx "$ip"; then echo "$n"; else echo "$1"; fi
}

# interface language: English first, so a string missing from a translation stays readable
otr_lang(){
  . "$OTR/lang/en.sh"
  local l; l=$(cfg LANGUAGE)
  [[ $l =~ ^[a-z]{2}$ ]] && [ "$l" != en ] && [ -f "$OTR/lang/$l.sh" ] && . "$OTR/lang/$l.sh"
  return 0
}

# never switch off in the middle of a software update (an interrupted install is only retried 10 minutes later):
# wait for it, 15 minutes at most
wait_update(){ local i; for i in $(seq 1 180); do systemctl is-active -q openthinrdp-update.service || return 0; sleep 5; done; }

# an installed system that boots its own initramfs (not the live system of the ISO): GRUB on a PC, the firmware
# partition of the Raspberry Pi image (raspi-firmware copies every new initramfs there)
otr_installed(){ { [ -f /etc/default/grub ] && [ -d /boot/grub ]; } || [ -f /boot/firmware/config.txt ]; }
# architecture of this device: amd64 on a PC, arm64 on a Raspberry Pi (OTR_ARCH: the tests)
otr_arch(){ echo "${OTR_ARCH:-$(dpkg --print-architecture 2>/dev/null)}"; }
# the packages of a package list (image/lb/packages.list) for one architecture: what is between "#if ARCHITECTURES
# <arch>..." (or "#nif") and "#endif" only when it applies (live-build's syntax), no comments, no empty lines
pkg_list(){ awk -v a="$1" '/^#if ARCHITECTURES /{s=1; for(i=3;i<=NF;i++) if($i==a) s=0; next}
  /^#nif ARCHITECTURES /{s=0; for(i=3;i<=NF;i++) if($i==a) s=1; next} /^#endif/{s=0; next}
  /^[[:space:]]*(#|$)/{next} !s{print $1}' "$2"; }
# the .deb files of an unpacked update package ($1) for this device: debs/*.deb and debs/<architecture>/*.deb, and of
# those only the ones built for its architecture or for all: an arm64 device never gets the amd64 FreeRDP
pkg_debs(){ local a d x; a=$(otr_arch)
  for d in "$1"/debs/*.deb "$1/debs/$a"/*.deb; do
    [ -f "$d" ] || continue; x=$(dpkg-deb -f "$d" Architecture 2>/dev/null)
    if [ "$x" = all ] || [ "$x" = "$a" ]; then echo "$d"; fi
  done; }

# the fingerprint of the first key in an OpenPGP public key file (armored or binary), upper case, as the manager
# shows it; fails when the file is missing or holds no version 4 key
key_fingerprint(){
  [ -s "$1" ] || return 1
  python3 - "$1" <<'PY'
import sys, base64, hashlib
d = open(sys.argv[1], 'rb').read()
if b'-----BEGIN PGP' in d:
    t = d.decode('ascii', 'replace').replace('\r', '').split('\n')
    i = next(n for n, l in enumerate(t) if l.startswith('-----BEGIN PGP'))
    while t[i].strip(): i += 1
    b = ''
    for l in t[i + 1:]:
        if l.startswith('-----END') or (l.startswith('=') and len(l.strip()) == 5): break
        b += l.strip()
    d = base64.b64decode(b)
c = d[0]
if c & 0x40:
    tag, o = c & 0x3f, d[1]
    if o < 192: n, s = o, 2
    elif o < 224: n, s = ((o - 192) << 8) + d[2] + 192, 3
    else: n, s = int.from_bytes(d[2:6], 'big'), 6
else:
    tag, lt = (c >> 2) & 0xf, c & 3
    w = [1, 2, 4][lt]; n, s = int.from_bytes(d[1:1 + w], 'big'), 1 + w
body = d[s:s + n]
if tag != 6 or body[0] != 4: sys.exit(1)
print(hashlib.sha1(b'\x99' + len(body).to_bytes(2, 'big') + body).hexdigest().upper())
PY
}

# bytes waiting, unread, in the sockets of a process (TCP and UDP)
recvq(){ ss -tunpH 2>/dev/null | grep "pid=$1," | awk '{s += $3} END {print s + 0}'; }
# What a stuck FreeRDP was doing, before it is killed: its threads (state, where they sleep, the system call they
# wait in), with eu-stack their stacks when it is installed, and the end of its log. Kept across a restart in
# session-hang.log (prepared by boot.sh, at most 1 MB), read over SSH. The whole log of the session is in /tmp, and
# kept at shutdown as last-session.log (keep-session-log.sh). From the kiosk watchdog, and at shutdown.
hang_report(){ local f=$OTR_LOG/session-hang.log t
  {
    echo "=== $(date '+%Y-%m-%d %H:%M:%S') FreeRDP $1 ($(xfreerdp3 --version 2>/dev/null | head -1)), sockets:"
    ss -tunpH 2>/dev/null | grep "pid=$1," | awk '{print "  " $1, $2, "unread", $3, "unsent", $4}'
    for t in /proc/"$1"/task/*; do
      printf '  %-16s %s wchan=%s syscall=%s\n' "$(cat "$t/comm" 2>/dev/null)" "$(awk '{print $3}' "$t/stat" 2>/dev/null)" \
        "$(cat "$t/wchan" 2>/dev/null)" "$(cut -d' ' -f1 "$t/syscall" 2>/dev/null)"
    done
    command -v eu-stack >/dev/null && timeout 20 eu-stack -p "$1" 2>&1 | head -400
    echo "--- end of the FreeRDP log"; tail -80 /tmp/kiosk.log 2>/dev/null
  } >> "$f" 2>/dev/null
  if [ "$(stat -c %s "$f" 2>/dev/null || echo 0)" -gt 1000000 ]; then tail -c 500000 "$f" > "$f.tmp" 2>/dev/null && cat "$f.tmp" > "$f"; rm -f "$f.tmp"; fi
  # and the whole diagnostics for the administrator, a few seconds later (FreeRDP gone, its log complete); not at
  # shutdown (keep-session-log.sh collects them itself, OTR_NO_DIAG)
  [ -n "${OTR_NO_DIAG:-}" ] || { ( sleep 5; sudo -n "$OTR/diag-bundle.sh" watchdog ) >/dev/null 2>&1 < /dev/null & }
}
# UDP datagrams this device received and sent so far ("in out"), all sockets: on a thin client nearly all are the
# UDP transport of FreeRDP; the rest (DNS, time) is a few datagrams now and then
udp_counts(){ awk '/^Udp:/ {n++} n == 2 && /^Udp:/ {print $2, $5; exit}' /proc/net/snmp; }
