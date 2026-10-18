#!/bin/bash
# Every scenario of the 802.1X lab with its checks (as root, after lab.sh image; it runs lab.sh up and down itself).
# The thin client runs its real scripts (save-config.sh, apply.sh, ifupdown, dot1x.sh under systemd, dhcpcd,
# wpa_supplicant); the other end is hostapd as a wired authenticator (its own EAP server, or FreeRADIUS), and for
# Wi-Fi hostapd as a WPA2/WPA3-Enterprise access point on mac80211_hwsim radios (skipped without the module: WIFI=0).
set -u
LAB=$(dirname "$(readlink -f "$0")"); O=$LAB/out
A(){ docker exec d1x-auth /lab/auth.sh "$@" >/dev/null; }
DX(){ docker exec d1x-dev "$@"; }
SET(){ docker exec d1x-dev /lab/dev.sh set "$@" >/dev/null 2>&1; }
ST(){ DX /opt/openthinrdp/dot1x.sh status; }
ADDR(){ DX ip -4 -o addr show dev "${1:-eth0}" | awk '{print $4}' | grep -v '^169\.254\.'; }
MARK(){ DX /lab/dev.sh mark "$1"; echo "--- $1"; }
PASS=0; FAIL=0
ok(){ if eval "$2"; then PASS=$((PASS+1)); echo "ok   $1"; else FAIL=$((FAIL+1)); echo "FAIL $1   [state: $(ST)]"; fi; }
upto(){ local i; for i in $(seq 1 "${2:-30}"); do eval "$1" && return 0; sleep 1; done; return 1; }
dropped(){ docker exec d1x-auth nft list chain inet lab in | sed -n 's/.*counter packets \([0-9]*\).*/\1/p' | head -1; }
P=$LAB/pki

"$LAB/lab.sh" up || exit 1
A hostapd server

MARK "1 PEAP: DHCP only after the authentication"
docker exec d1x-auth nft reset counters table inet lab >/dev/null
SET DOT1X=peap EAP_IDENTITY=thinuser EAP_ANONYMOUS=anonymous@lab.example EAP_CA=lab-ca.crt EAP_SERVER_NAME=radius.lab.example EAP_PASSWORD=Secret-Pw1
upto '[ -n "$(ADDR)" ]' 40
ok "PEAP: authenticated, then an address" '[ "$(ST)" = "eth0: authenticated (PEAP, server radius.lab.example)" ] && [ -n "$(ADDR)" ]'
ok "PEAP: not one DHCP packet before the port opened (dropped by the switch: $(dropped))" '[ "$(dropped)" = 0 ]'
ok "PEAP: the event" 'DX grep -q "802.1X: authenticated on eth0 (PEAP, server radius.lab.example)" /var/log/openthinrdp/events.log'

MARK "2 PEAP: a wrong password, tried once"
n0=$(grep -c "CTRL-EVENT-EAP-FAILURE" $O/port.log)
SET EAP_PASSWORD=Wrong-Pw9
upto 'ST | grep -q failed' 20
sleep 30
ok "wrong password: failed, next try in an hour" 'ST | grep -q "^eth0: failed: password refused by the server: next try at"'
ok "wrong password: one attempt in 30 s (the account is not locked)" '[ $(( $(grep -c "CTRL-EVENT-EAP-FAILURE" $O/port.log) - n0 )) = 1 ]'

MARK "3 a new password from the manager"
printf 'Secret-Pw1\n' | docker exec -i d1x-dev /opt/openthinrdp/dot1x.sh password >/dev/null
upto 'ST | grep -q authenticated' 20
ok "new password: authenticated at once, the address asked again" 'ST | grep -q "^eth0: authenticated" && upto "[ -n \"\$(ADDR)\" ]" 20'

MARK "4 no authenticator: a port without 802.1X"
A nohostapd
t0=$(date +%s); DX bash -c 'ifdown eth0; ifup eth0' >/dev/null 2>&1; t1=$(date +%s)
upto '[ -n "$(ADDR)" ]' 20
ok "no authenticator: ifup waited $((t1 - t0)) s, not forever, and the address came" '[ $((t1 - t0)) -ge 15 ] && [ $((t1 - t0)) -le 45 ] && [ -n "$(ADDR)" ]'
ok "no authenticator: said in the state and the events" '[ "$(ST)" = "eth0: no authenticator: DHCP without 802.1X" ] && DX grep -q "802.1X: no authenticator on eth0" /var/log/openthinrdp/events.log'

MARK "5 the authenticator back, cable out and in"
A closeport; A hostapd server; A flap 2
upto 'ST | grep -q authenticated' 25
ok "cable out and in: link down seen, authenticated again, address again" 'DX grep -q "802.1X: link down on eth0" /var/log/openthinrdp/events.log && ST | grep -q "^eth0: authenticated" && upto "[ -n \"\$(ADDR)\" ]" 20'

MARK "6 the client certificate from the manager"
I(){ docker exec -i d1x-dev /opt/openthinrdp/dot1x.sh client; }
ok "certificate: another key, an encrypted key without password, a wrong .pfx password: refused" 'cat $P/client.crt $P/client2.key | I | grep -q "^ERROR=the private key does not belong" && cat $P/client.crt $P/client-enc.key | I | grep -q "^ERROR=the private key cannot be read" && { echo PASSWORD=nope; echo "PKCS12=$(base64 -w0 $P/client.p12)"; } | I | grep -q "^ERROR=the PKCS#12 file cannot be opened"'
ok "certificate: .pfx (also legacy algorithms) and PEM with an encrypted key accepted" '{ echo PASSWORD=Pfx-Pw1; echo "PKCS12=$(base64 -w0 $P/client-legacy.p12)"; } | I | grep -q "^OK=client" && { echo PASSWORD=Key-Pw1; cat $P/client.crt $P/client-enc.key; } | I | grep -q "^OK=client" && { echo PASSWORD=Pfx-Pw1; echo "PKCS12=$(base64 -w0 $P/client.p12)"; } | I | grep -q "^OK=client CN=host/thin1.lab.example"'

MARK "7 EAP-TLS"
SET DOT1X=tls EAP_IDENTITY= EAP_ANONYMOUS=
upto 'ST | grep -q "authenticated (EAP-TLS"' 20
ok "EAP-TLS: authenticated with the certificate, identity from its name" 'ST | grep -q "^eth0: authenticated (EAP-TLS, server radius.lab.example)" && DX grep -q "identity=\"host/thin1.lab.example\"" /run/openthinrdp/dot1x/eth0.conf'

MARK "8 EAP-TLS: a server of another CA with the same name"
A hostapd rogue-server; A flap 1
upto 'ST | grep -q failed' 20
ok "rogue server: refused, its certificate not accepted" 'ST | grep -q "^eth0: failed: certificate of the server not accepted: unable to get local issuer certificate"'

MARK "9 EAP-TLS: a server of the right CA with another name"
A hostapd other-server; A flap 1
upto 'ST | grep -q "Domain suffix"' 20
ok "other name: refused (domain_suffix_match)" 'ST | grep -q "^eth0: failed: certificate of the server not accepted: Domain suffix mismatch"'

MARK "10 PEAP with that server: the password does not leave, no wait"
SET DOT1X=peap EAP_IDENTITY=thinuser EAP_ANONYMOUS=anonymous@lab.example
upto 'ST | grep -q "Domain suffix"' 20
ok "PEAP, other name: refused before the password, no hour of wait" 'ST | grep -q "Domain suffix mismatch" && ! DX ls /run/openthinrdp/dot1x/eth0.hold >/dev/null 2>&1'

MARK "11-13 through FreeRADIUS"
docker exec d1x-auth /lab/radius.sh >/dev/null && A hostapd server radius && A flap 1
upto 'ST | grep -q authenticated' 25
ok "FreeRADIUS PEAP: authenticated" 'ST | grep -q "^eth0: authenticated (PEAP, server radius.lab.example)" && grep -q "Sent Access-Accept" $O/freeradius.log'
SET DOT1X=tls EAP_IDENTITY= EAP_ANONYMOUS=
upto 'ST | grep -q "authenticated (EAP-TLS"' 25
ok "FreeRADIUS EAP-TLS: authenticated" 'ST | grep -q "^eth0: authenticated (EAP-TLS"'
r0=$(grep -c "Sent Access-Reject" $O/freeradius.log)
SET DOT1X=peap EAP_IDENTITY=thinuser EAP_ANONYMOUS=anonymous@lab.example EAP_PASSWORD=Wrong-Pw9
upto 'ST | grep -q failed' 20; sleep 30
ok "FreeRADIUS wrong password: refused once in 30 s, then the wait" 'ST | grep -q "^eth0: failed: user or password refused by the server: next try at" && [ $(( $(grep -c "Sent Access-Reject" $O/freeradius.log) - r0 )) = 1 ]'

MARK "14 EAP-TLS before the certificate arrives"
A hostapd server; DX rm -f /etc/openthinrdp/dot1x/client.crt /etc/openthinrdp/dot1x/client.key
SET DOT1X=tls EAP_IDENTITY= EAP_ANONYMOUS= EAP_PASSWORD=Secret-Pw1
upto 'ST | grep -q incomplete' 20
ok "no certificate yet: incomplete, said" 'ST | grep -q "^eth0: incomplete: no client certificate"'
{ echo PASSWORD=Pfx-Pw1; echo "PKCS12=$(base64 -w0 $P/client.p12)"; } | docker exec -i d1x-dev /opt/openthinrdp/dot1x.sh client >/dev/null
upto 'ST | grep -q authenticated' 20
ok "the certificate arrives: authenticated without touching anything else" 'ST | grep -q "^eth0: authenticated (EAP-TLS"'

MARK "15 off"
SET DOT1X=off; sleep 5
ok "off: no supplicant, the adapter without pre-up" '[ "$(ST)" = off ] && ! DX pgrep -f "wpa_supplicant -D wired" >/dev/null && ! DX grep -q dot1x /etc/network/interfaces'
ok "secrets: never in the settings, the status or the events" 'DX /opt/openthinrdp/report.sh >/dev/null 2>&1; ! DX grep -rqE "Secret-Pw1|Wrong-Pw9|PRIVATE KEY" /etc/openthinrdp/openthinrdp.conf /run/openthinrdp-status.txt /var/log/openthinrdp/events.log'

if [ "${WIFI:-1}" = 1 ] && modprobe -n mac80211_hwsim 2>/dev/null; then
  "$LAB/lab.sh" wifi-up >/dev/null
  W(){ DX wpa_cli -p /run/wpa_supplicant -i wlan0 status 2>/dev/null; }
  MARK "W1 Wi-Fi WPA2-Enterprise (WPA-EAP and SHA256 offered, PMF optional), PEAP"
  A wlan server "WPA-EAP WPA-EAP-SHA256" 1
  SET WIFI=on WIFI_SSID=Lab-Enterprise WIFI_COUNTRY=IT WIFI_SECURITY=peap EAP_IDENTITY=thinuser EAP_ANONYMOUS=anonymous@lab.example
  upto 'W | grep -q "^wpa_state=COMPLETED"' 40
  ok "Wi-Fi WPA2-Enterprise PEAP: connected, address" 'W | grep -q "^EAP state=SUCCESS" && W | grep -q "^selectedMethod=25" && upto "[ -n \"\$(ADDR wlan0)\" ]" 20'
  MARK "W2 WPA3-Enterprise only (SHA256, PMF required), PEAP"
  A wlan server "WPA-EAP-SHA256" 2
  upto 'W | grep -q "^pmf=2" && W | grep -q "^wpa_state=COMPLETED"' 40
  ok "Wi-Fi WPA3-Enterprise PEAP: connected with SHA256 and PMF" 'W | grep -q "^key_mgmt=WPA2-EAP-SHA256" && W | grep -q "^pmf=2"'
  MARK "W3 WPA3-Enterprise, EAP-TLS"
  SET WIFI_SECURITY=tls EAP_IDENTITY= EAP_ANONYMOUS=
  upto 'W | grep -q "^selectedMethod=13" && W | grep -q "^wpa_state=COMPLETED"' 40
  ok "Wi-Fi WPA3-Enterprise EAP-TLS: connected" 'W | grep -q "^selectedMethod=13 (EAP-TLS)" && W | grep -q "^EAP state=SUCCESS"'
  MARK "W4 an older WPA2-Enterprise access point (WPA-EAP only, no PMF), PEAP"
  SET WIFI_SECURITY=peap EAP_IDENTITY=thinuser EAP_ANONYMOUS=anonymous@lab.example
  A wlan server "WPA-EAP" 0
  upto 'W | grep -q "^key_mgmt=WPA2/IEEE 802.1X/EAP" && W | grep -q "^wpa_state=COMPLETED"' 40
  ok "Wi-Fi WPA2-Enterprise without PMF: connected" 'W | grep -q "^key_mgmt=WPA2/IEEE 802.1X/EAP" && W | grep -q "^selectedMethod=25"'
  MARK "W5 an access point with a server of another name"
  A wlan other-server "WPA-EAP WPA-EAP-SHA256" 1; sleep 20
  ok "Wi-Fi, server of another name: not connected, the certificate refused" '! W | grep -q "^wpa_state=COMPLETED" && DX journalctl -q --no-pager -t wpa_supplicant | grep -q "Domain suffix mismatch"'
  DX /opt/openthinrdp/report.sh >/dev/null 2>&1
  ok "Wi-Fi: the report says the network is enterprise" 'DX grep -q "^WIFI_STATUS=.*(802.1X PEAP)" /run/openthinrdp-status.txt'
fi

[ "${KEEP:-0}" = 1 ] || "$LAB/lab.sh" down >/dev/null
echo "lab: passed $PASS, failed $FAIL"
[ $FAIL = 0 ]
