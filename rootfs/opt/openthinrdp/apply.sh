#!/bin/bash
# Apply the settings to the system: network (DHCP/static/Wi-Fi), DNS, time servers, security updates,
# USB ownership (pcscd), SSH and keyboard. Runs as root.
#   boot = at startup (ifupdown already brought up the known adapters: only new ones are started here)
#   now  = after a change (the adapters whose configuration changed are restarted)
#   hotplug = a network adapter appeared (udev). During boot it first waits for boot.sh, which configures the
#             adapters found at startup (two runs restarting the same adapter left it without an address on the
#             first boot of a new device), then works like "now": an adapter that appeared while boot.sh was
#             running (a USB adapter shows up a few seconds late) or later (plugged in) gets its configuration.
. /opt/openthinrdp/lib/common.sh
. "$OTR/lib/netif.sh"
. "$OTR/lib/secrets.sh"
if [ "$1" = hotplug ]; then
  for _ in $(seq 180); do
    [ "$(systemctl show -p ActiveState --value openthinrdp-boot.service)" != activating ] &&
      [ "$(systemctl show -p InactiveExitTimestampMonotonic --value openthinrdp-boot.service)" != 0 ] && break
    sleep 1
  done
  set -- now
fi
# one apply at a time (boot, settings dialog, central configuration and udev all start it)
exec 9>/run/openthinrdp-apply.lock; flock 9

ALLIF=$(wired_nics); IF=$(main_nic); MODE=$(cfg NETMODE)
DOM=$(cfg DOMAIN | tr 'A-Z' 'a-z'); [[ $DOM == *.* ]] || DOM=""
# Wi-Fi only when enabled, with an adapter and a saved key (written by save-config.sh)
WCF=/etc/wpa_supplicant/openthinrdp-wifi.conf; WL=""   # a link to the copy in memory when kept in the TPM (lib/secrets.sh)
if [ "$(cfg WIFI)" = on ] && [ -s "$WCF" ] && command -v wpa_supplicant >/dev/null; then WL=$(wifi_nics | head -1); fi
[ "$IF" = "$(wifi_nics | head -1)" ] && [ "$MODE" = static ] && IF=$(wired_nics | head -1)   # static only on a cable

# --- interfaces. allow-hotplug = the boot does not wait for the network (the login form does not need it).
# DHCP: every wired adapter (whichever has the cable gets the address). Static: only the main one.
OLD=/etc/network/interfaces
NEW=$(mktemp)
{
  echo "# written by /opt/openthinrdp/apply.sh from the settings: do not edit"
  echo "source /etc/network/interfaces.d/*"; echo
  echo "auto lo"; echo "iface lo inet loopback"
  for i in $ALLIF; do
    if [ "$MODE" = static ]; then
      [ "$i" = "$IF" ] || continue
      printf '\nallow-hotplug %s\niface %s inet static\n    address %s\n    netmask %s\n    gateway %s\n' "$i" "$i" "$(cfg IPADDR)" "$(cfg NETMASK)" "$(cfg GATEWAY)"
    else
      printf '\nallow-hotplug %s\niface %s inet dhcp\n' "$i" "$i"
    fi
  done
  # Wi-Fi: always DHCP; the cable stays preferred (dhcpcd gives wireless a higher metric).
  # Power saving off: with power_save on the remote session stutters.
  [ -n "$WL" ] && printf '\nallow-hotplug %s\niface %s inet dhcp\n    wpa-conf %s\n    post-up /usr/sbin/iw dev %s set power_save off || true\n' "$WL" "$WL" "$WCF" "$WL"
} > "$NEW"
# block of one adapter in the file, to restart ONLY the adapters whose configuration changes
block(){ awk -v i="$2" '$0=="allow-hotplug "i{f=1;next} f&&/^$/{exit} f' "$1" 2>/dev/null; }
CHANGED=""; ADDED=""
for i in $ALLIF $WL $(awk '/^allow-hotplug /{print $2}' $OLD 2>/dev/null); do
  case " $CHANGED " in *" $i "*) continue ;; esac
  a=$(block $OLD "$i"); b=$(block "$NEW" "$i")
  [ "$a" = "$b" ] && continue
  # adapter new in the file but already working with DHCP (e.g. a USB adapter brought up by udev): leave it
  if [ -z "$a" ] && [ "$MODE" != static ] && ip -4 -o addr show dev "$i" 2>/dev/null | grep -q inet; then continue; fi
  CHANGED="$CHANGED $i"; [ -z "$a" ] && [ -n "$b" ] && ADDED="$ADDED $i"
done
cmp -s "$NEW" $OLD || cp "$NEW" $OLD
rm -f "$NEW"

# --- DNS: the configured servers, or the ones from DHCP when DNS1 is empty
D1=$(cfg DNS1); D2=$(cfg DNS2)
if [ -n "$D1" ]; then
  grep -qx 'nohook resolv.conf' /etc/dhcpcd.conf 2>/dev/null || echo 'nohook resolv.conf' >> /etc/dhcpcd.conf
  chattr -i /etc/resolv.conf 2>/dev/null; rm -f /etc/resolv.conf
  { echo "# written by /opt/openthinrdp/apply.sh"; [ -n "$DOM" ] && echo "search $DOM"
    for d in "$D1" "$D2"; do [ -n "$d" ] && echo "nameserver $d"; done; } > /etc/resolv.conf
  chattr +i /etc/resolv.conf 2>/dev/null
elif grep -qx 'nohook resolv.conf' /etc/dhcpcd.conf 2>/dev/null; then
  # back to the DHCP servers: dhcpcd writes resolv.conf again from the next lease
  sed -i '/^nohook resolv.conf$/d' /etc/dhcpcd.conf
  chattr -i /etc/resolv.conf 2>/dev/null
  [ "$1" = now ] && dhcpcd -n >/dev/null 2>&1
fi

# --- time servers (empty = the Debian pool)
mkdir -p /etc/systemd/timesyncd.conf.d
T=/etc/systemd/timesyncd.conf.d/openthinrdp.conf
if [ -n "$(cfg NTP)" ]; then printf '[Time]\nNTP=%s\nFallbackNTP=\n' "$(cfg NTP)" > $T.new; else : > $T.new; fi
if ! cmp -s $T.new $T; then mv -f $T.new $T; [ "$1" = now ] && systemctl restart systemd-timesyncd 2>/dev/null; else rm -f $T.new; fi

# --- Debian security updates (FreeRDP excluded, see security-updates.sh): SECURITY_UPDATES=on|off
if command -v unattended-upgrade >/dev/null; then
  if [ "$(cfg SECURITY_UPDATES)" = off ]; then AU=0; else AU=1; fi
  NEWAU=$(printf 'APT::Periodic::Update-Package-Lists "%s";\nAPT::Periodic::Unattended-Upgrade "%s";' $AU $AU)
  [ "$NEWAU" != "$(cat /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null)" ] && echo "$NEWAU" > /etc/apt/apt.conf.d/20auto-upgrades
  # the timers always follow the key (not only when the file changes): the package already writes "1"
  if [ $AU = 1 ]; then systemctl enable --now --no-block apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1
  else systemctl disable --now --no-block apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1; fi
fi

# --- USB ownership. What goes whole to Windows (USB_MODE=all, USB_REDIRECT) pcscd must not open; SMART CARD
# READERS (interface class 0b) instead always belong to pcscd and go through /smartcard: inside a remote
# session Windows shows programs only the readers redirected that way, a reader passed as a whole USB device
# is invisible to them.
R=/etc/udev/rules.d/71-openthinrdp-usb-whole.rules
NEWR=$(mktemp)
echo "# written by /opt/openthinrdp/apply.sh from USB_MODE/USB_REDIRECT: do not edit" > "$NEWR"
[ "$(cfg USB_MODE)" != disks ] && echo 'SUBSYSTEM=="usb", ENV{PCSCLITE_IGNORE}="1"' >> "$NEWR"
for u in $(cfg USB_REDIRECT); do
  echo "SUBSYSTEM==\"usb\", ATTRS{idVendor}==\"${u%:*}\", ATTRS{idProduct}==\"${u#*:}\", ENV{PCSCLITE_IGNORE}=\"1\"" >> "$NEWR"
done
echo 'SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_interface", ATTR{bInterfaceClass}=="0b", ENV{PCSCLITE_IGNORE}=""' >> "$NEWR"
# pcscd looks at the USB device (the parent), not at the interface: clear it there too when it has a 0b interface
echo 'SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ENV{ID_USB_INTERFACES}=="*:0b*", ENV{PCSCLITE_IGNORE}=""' >> "$NEWR"
if ! cmp -s "$NEWR" "$R"; then
  install -m644 "$NEWR" "$R"
  udevadm control --reload 2>/dev/null
  udevadm trigger --subsystem-match=usb --action=change 2>/dev/null
  systemctl try-restart pcscd.service 2>/dev/null
  # storage already mounted from devices now passed whole: unmount it, Windows will use it
  . "$OTR/lib/usb.sh"
  # only disks on USB: an internal SATA disk is sd* too, and its /boot/efi must never be unmounted here
  awk '$1 ~ "^/dev/sd" {print $1" "$2}' /proc/mounts | while read -r d mp; do
    ub=$(usb_of_block "${d#/dev/}") || continue
    usb_mount_here "$ub" || { systemd-mount --umount "$mp" 2>/dev/null; continue; }
    id=$(udevadm info -q property -n "$d" | awk -F= '/^ID_VENDOR_ID=/{v=$2} /^ID_MODEL_ID=/{m=$2} END{print tolower(v":"m)}')
    for u in $(cfg USB_REDIRECT); do [ "$id" = "$u" ] && systemd-mount --umount "$mp" 2>/dev/null; done
  done
fi
rm -f "$NEWR"

# --- SSH: only key login, keys in /etc/openthinrdp/authorized_keys (management folder or image), no root
S=/etc/ssh/sshd_config.d/openthinrdp.conf
if [ "$(cfg SSH)" = on ] && [ -s "$OTR_ETC/authorized_keys" ]; then
  # the image is built without host keys (every device must have its own): created on first use, and kept in the
  # TPM when there is one (lib/secrets.sh; sshd then reads them from memory)
  # (two separate checks: one ls on both fails as soon as either is missing, and new keys replaced the ones just
  # moved into the TPM, seen on the QEMU bench)
  if ! ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1 && ! ls "$OTR_SEALED"/ssh_host_*_key.cred >/dev/null 2>&1; then
    ssh-keygen -A >/dev/null 2>&1
    if secret_enabled; then
      for k in ed25519 ecdsa rsa; do [ -s /etc/ssh/ssh_host_${k}_key ] && { t=$(mktemp); cp /etc/ssh/ssh_host_${k}_key "$t"; secret_store ssh_host_${k}_key "$t"; }; done
    fi
  fi
fi
printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\nAuthorizedKeysFile %s\nAllowUsers otradmin\n' "$OTR_ETC/authorized_keys" > $S.new
SC=0; cmp -s $S.new $S || { mv -f $S.new $S; SC=1; }; rm -f $S.new
secret_sshd_hostkeys && SC=1
if [ "$(cfg SSH)" = on ] && [ -s "$OTR_ETC/authorized_keys" ]; then
  systemctl enable --now --no-block ssh >/dev/null 2>&1; [ $SC = 1 ] && systemctl try-reload-or-restart ssh >/dev/null 2>&1
else systemctl disable --now --no-block ssh >/dev/null 2>&1; fi

# --- the kiosk account: locked, never an empty password (0.1.0 images had one: anybody could log in on a console)
[ "$(passwd -S "$OTR_KIOSK_USER" 2>/dev/null | awk '{print $2}')" = NP ] && passwd -l "$OTR_KIOSK_USER" >/dev/null 2>&1

# --- certificate authorities of the site (/etc/openthinrdp/ca/*.crt, image or update): in the system trust
# store too, not only in Chromium, so FreeRDP (RDP_CERT=verify), curl and Python trust them
CAD=/usr/local/share/ca-certificates/openthinrdp
mkdir -p $CAD
CANEW=$(cat "$OTR_ETC"/ca/*.crt 2>/dev/null | sha256sum | cut -c1-64); CAOLD=$(cat $CAD/*.crt 2>/dev/null | sha256sum | cut -c1-64)
if [ "$CANEW" != "$CAOLD" ]; then
  rm -f $CAD/*.crt; cp "$OTR_ETC"/ca/*.crt $CAD/ 2>/dev/null
  update-ca-certificates --fresh >/dev/null 2>&1 && ev "certificate authorities of the site: $(ls $CAD/*.crt 2>/dev/null | wc -l) in the system trust store"
fi

# --- keyboard (console + X; X takes it at the next start of the session)
K=$(cfg KEYBOARD)
if [ -n "$K" ] && ! grep -qx "XKBLAYOUT=\"$K\"" /etc/default/keyboard 2>/dev/null; then
  printf 'XKBMODEL="pc105"\nXKBLAYOUT="%s"\nXKBVARIANT=""\nXKBOPTIONS=""\n' "$K" > /etc/default/keyboard
  setupcon -k --force >/dev/null 2>&1 || true
fi

# --- network: restart ONLY the adapters whose configuration changed (a new adapter does not drop the one
# in use). 9>&- = the lock does NOT pass to background commands (a stuck ifdown held it forever); an ifup
# still waiting on an adapter without cable has to go, otherwise ifdown waits for it.
if [ "$1" = now ]; then
  for i in $CHANGED; do
    setsid bash -c "pkill -9 -f '^/usr/sbin/ifup .*[ =]$i\$'; timeout -s KILL 20 ifdown --force $i; dhcpcd -x $i; ip addr flush dev $i; grep -qx 'allow-hotplug $i' $OLD && ifup $i" 9>&- >/dev/null 2>&1 < /dev/null &
  done
elif [ "$1" = boot ]; then
  for i in $ADDED; do setsid ifup "$i" 9>&- >/dev/null 2>&1 < /dev/null & done
fi

# --- VPN (VPN=wireguard|openvpn|off): in the background, the server's name may need the network just restarted;
# report.sh (vpn.sh check) tries again every 5 minutes
setsid "$OTR/vpn.sh" apply 9>&- >/dev/null 2>&1 < /dev/null &
exit 0
