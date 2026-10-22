#!/bin/bash
# Wi-Fi from the page of the kiosk (ui.py wifi). Runs as root (sudo from the kiosk user, see sudoers).
#   wifi.sh scan      the networks around: "signal_dBm<TAB>security<TAB>ssid" per line, strongest first, one line per
#                     name (security: psk, eap, open, wep). Exit 2 = no Wi-Fi adapter.
#   wifi.sh connect   the name and the password on stdin (two lines). Tried FIRST with a wpa_supplicant of its own, the
#                     settings untouched; only when the password is right they are saved (save-config.sh) and the
#                     Wi-Fi started with them. Otherwise the Wi-Fi of before comes back as it was. Prints "step NAME"
#                     lines while it works and ends with "result CODE [detail]":
#                     ok <address> | noip (connected, no address from the network) | wrongkey | notfound | timeout |
#                     invalid (name or password not acceptable) | nowifi | busy | saveerror <message>
#                     A Wi-Fi also set centrally (central-*.conf) adds "central" to an ok: the manager will put its own
#                     network back at the next check.
. /opt/openthinrdp/lib/common.sh
. "$OTR/lib/netif.sh"
WL=$(wifi_nics | head -1)

# iw scan output -> the lines above (stdin to stdout); a function on its own for the tests
parse_scan(){
  awk '
    function flush() { if (have && ssid != "" && ssid !~ /^(\\x00)+$/) { if (!(ssid in best) || sig > best[ssid]) { best[ssid] = sig; sec[ssid] = s } } }
    /^BSS [0-9a-f:]{17}/ { flush(); have = 1; ssid = ""; sig = -100; s = "open"; priv = 0; next }
    /^[ \t]+SSID: / { sub(/^[ \t]+SSID: /, ""); ssid = $0; next }
    /^[ \t]+signal: / { sig = $2 + 0; next }
    /^[ \t]+capability:.*Privacy/ { priv = 1; if (s == "open") s = "wep"; next }
    /^[ \t]+(RSN|WPA):/ { if (s == "open" || s == "wep") s = "psk"; next }
    /Authentication suites:.*(IEEE 802\.1X|802\.1X)/ { s = "eap"; next }
    END { flush(); for (k in best) printf "%d\t%s\t%s\n", best[k], sec[k], k }
  ' | sort -t "$(printf '\t')" -k1,1nr
}

case "$1" in
  scan)
    [ -n "$WL" ] || exit 2
    ip link set "$WL" up 2>/dev/null
    # busy (-16) while the adapter is joining a network: a few tries
    for i in 1 2 3 4 5; do out=$(iw dev "$WL" scan 2>/dev/null) && break; sleep 1; done
    printf '%s\n' "$out" | parse_scan
    ;;
  connect)
    [ -n "$WL" ] || { echo "result nowifi"; exit 0; }
    IFS= read -r SSID; IFS= read -r PSK
    # the same rules as the settings (save-config.sh): a name of 1-32 characters, a password of 8-63
    if [ -z "$SSID" ] || [ ${#SSID} -gt 32 ] || [ ${#PSK} -lt 8 ] || [ ${#PSK} -gt 63 ]; then echo "result invalid"; exit 0; fi
    exec 9>/run/openthinrdp-wifi.lock; flock -n 9 || { echo "result busy"; exit 0; }
    T=/run/otr-wifi-test; rm -rf "$T"; mkdir -m 700 "$T"
    stop_test(){ [ -s "$T/pid" ] && kill "$(cat "$T/pid")" 2>/dev/null; sleep 0.5; rm -rf "$T"; }
    was_on=$(cfg WIFI)
    echo "step stop"
    ifdown --force "$WL" >/dev/null 2>&1; pkill -f "wpa_supplicant.*-i *$WL( |$)" 2>/dev/null; sleep 1
    ip link set "$WL" up 2>/dev/null
    # the network for the try: its name in hex (any character is safe), the key as wpa_passphrase computes it
    hex=$(printf '%s' "$SSID" | od -An -tx1 | tr -d ' \n')
    key=$(wpa_passphrase "$SSID" "$PSK" 2>/dev/null | sed -n 's/^[[:space:]]*psk=\([0-9a-f]\{64\}\)$/\1/p')
    [ -n "$key" ] || { echo "result invalid"; rm -rf "$T"; [ "$was_on" = on ] && ifup "$WL" >/dev/null 2>&1; exit 0; }
    ( umask 077; printf 'ctrl_interface=%s/ctrl\ncountry=%s\nnetwork={\n  ssid=%s\n  scan_ssid=1\n  psk=%s\n}\n' "$T" "$(cfg WIFI_COUNTRY)" "$hex" "$key" > "$T/conf" )
    [ -n "$(cfg WIFI_COUNTRY)" ] || sed -i '/^country=$/d' "$T/conf"
    echo "step test"
    wpa_supplicant -B -i "$WL" -D nl80211,wext -c "$T/conf" -f "$T/log" -P "$T/pid" >/dev/null 2>&1
    res=timeout; nf=0
    for i in $(seq 1 50); do
      sleep 0.5
      st=$(wpa_cli -p "$T/ctrl" -i "$WL" status 2>/dev/null | sed -n 's/^wpa_state=//p')
      [ "$st" = COMPLETED ] && { res=ok; break; }
      grep -qE 'WRONG_KEY|pre-shared key may be incorrect|4-Way Handshake failed' "$T/log" 2>/dev/null && { res=wrongkey; break; }
      nf=$(grep -c 'CTRL-EVENT-NETWORK-NOT-FOUND' "$T/log" 2>/dev/null)
      [ "${nf:-0}" -ge 3 ] && { res=notfound; break; }
    done
    stop_test
    if [ $res != ok ]; then
      # the Wi-Fi of before, as it was
      [ "$was_on" = on ] && ifup "$WL" >/dev/null 2>&1
      ev "Wi-Fi from the page: $SSID not joined ($res), the settings of before kept"
      echo "result $res"; exit 0
    fi
    echo "step save"
    f=$(mktemp); chmod 600 "$f"
    printf 'WIFI=on\nWIFI_SSID=%s\nWIFI_SECURITY=psk\nWIFI_PSK=%s\n' "$SSID" "$PSK" > "$f"
    msg=$("$OTR/save-config.sh" "$f" 2>&1); r=$?; rm -f "$f"
    if [ $r -ne 0 ]; then [ "$was_on" = on ] && ifup "$WL" >/dev/null 2>&1; echo "result saveerror $(echo "$msg" | head -1)"; exit 0; fi
    # save-config.sh applied it; started again here in case the adapter was not up (a device on cable)
    echo "step dhcp"
    ifup "$WL" >/dev/null 2>&1
    ipa=""
    for i in $(seq 1 40); do ipa=$(ip -4 -o addr show dev "$WL" scope global 2>/dev/null | awk '{print $4}' | head -1); [ -n "$ipa" ] && break; sleep 0.5; done
    central=""; grep -qs '^WIFI_SSID=' "$OTR_LIB"/central-*.conf && ! grep -qsxF "WIFI_SSID=$SSID" "$OTR_LIB"/central-*.conf && central=" central"
    if [ -n "$ipa" ]; then ev "Wi-Fi from the page: connected to $SSID, $ipa"; echo "result ok ${ipa%/*}$central"
    else ev "Wi-Fi from the page: joined $SSID, no address from the network"; echo "result noip$central"; fi
    ;;
  *) echo "usage: $0 scan | connect (name and password on stdin)"; exit 2 ;;
esac
