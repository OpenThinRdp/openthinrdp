#!/bin/bash
# 802.1X on the cable (DOT1X=peap|tls): the switch opens the port only to a device that authenticates, with an account
# (PEAP) or a certificate (EAP-TLS). wpa_supplicant with its wired driver on each wired adapter. Runs as root (status
# also as the kiosk user, for the diagnostics).
#   dot1x.sh wait IF        pre-up of a wired adapter in /etc/network/interfaces (apply.sh): its supplicant started, and
#                           the address (DHCP, or the static one) set only once the port is open: authenticated, refused
#                           (the switch may then put the port in another network), or no authenticator answering within
#                           $NOAUTH s (a switch without 802.1X: a device set up for it works there too). $WAITMAX s at most;
#                           without a cable at once (the supplicant authenticates when it is plugged in).
#   dot1x.sh stop IF        post-down of the adapter
#   dot1x.sh run IF         openthinrdp-dot1x@IF.service: the supplicant, what it says into the state and the event log, the
#                           cable watched (plugged in again = authenticated again, then the address asked again)
#   dot1x.sh apply [IF...]  apply.sh: the supplicants started again when their settings or secrets changed, stopped with
#                           DOT1X=off (the IF given are restarted by apply.sh itself: left alone)
#   dot1x.sh status         one line for the report and the diagnostics
#   dot1x.sh password       the PEAP password on standard input, one line (the manager, over SSH)
#   dot1x.sh client         the client certificate and its key on standard input (the manager, over SSH), see client_in
# The state of each adapter: /run/openthinrdp-dot1x/IF (readable by all, no secret in it). A password the server refuses
# is not tried again for an hour (or until a new one arrives): switches ask again every minute, and a domain account
# would be locked.
. /opt/openthinrdp/lib/common.sh
. "$OTR/lib/secrets.sh"
. "$OTR/lib/eap.sh"
PUB=/run/openthinrdp-dot1x                  # state of each adapter
PRIV=/run/openthinrdp/dot1x                 # configuration (with the password), control socket, markers: root only
CTRL=$PRIV/ctrl
SYS=${OTR_DOT1X_SYS:-/sys/class/net}        # (tests: a tree of their own)
NOAUTH=${OTR_DOT1X_NOAUTH:-15}              # no answer to EAPOL within this = no authenticator on the port
WAITMAX=${OTR_DOT1X_WAIT:-40}               # DHCP waits at most this long for the authentication
HOLD=${OTR_DOT1X_HOLD:-3600}                # a refused PEAP password: next try after this

dirs(){ install -d -m 755 "$PUB"; install -d -m 700 "$PRIV"; }
unit(){ echo "openthinrdp-dot1x@$1.service"; }
carrier(){ [ "$(cat "$SYS/$1/carrier" 2>/dev/null)" = 1 ]; }
st_get(){ cat "$PUB/$1" 2>/dev/null; }
st_set(){ printf '%s\n' "$2" > "$PUB/.$1.new" && chmod 644 "$PUB/.$1.new" && mv -f "$PUB/.$1.new" "$PUB/$1"; }
mode_name(){ case "$1" in tls) echo EAP-TLS ;; *) echo PEAP ;; esac; }
wcli(){ wpa_cli -p "$CTRL" -i "$1" "${@:2}" >/dev/null 2>&1; }

# the configuration of the wired supplicant (ap_scan=0: no scanning, EAPOL only)
wired_conf(){
  printf '# written by /opt/openthinrdp/dot1x.sh from the settings: 802.1X on the cable, do not edit\n'
  printf 'ctrl_interface=%s\nap_scan=0\nnetwork={\n\tkey_mgmt=IEEE8021X\n\teapol_flags=0\n' "$CTRL"
  eap_block "$1"
  printf '}\n'
}
# what the supplicant of every adapter should run with now: the configuration, or why it cannot start
wanted(){
  local m; m=$(cfg DOT1X)
  [ "$m" = off ] && { echo off; return; }
  command -v wpa_supplicant >/dev/null || { echo "incomplete: wpasupplicant missing"; return; }
  local miss; miss=$(eap_missing "$m")
  if [ -n "$miss" ]; then echo "incomplete: $miss"; else wired_conf "$m"; fi
}
signature(){ wanted | sha256sum | cut -c1-64; }
# the adapters set up for 802.1X (apply.sh wrote their pre-up) that exist
adapters(){ awk -v s="$OTR/dot1x.sh wait" 'index($0, s) {print $NF}' /etc/network/interfaces 2>/dev/null | while read -r i; do [ -d "$SYS/$i" ] && echo "$i"; done; }

# the address again after the port opened: the switch may put an authenticated device in another network (VLAN) than
# the one it gave before, or nothing at all before. Only where dhcpcd already runs for the adapter (during wait it
# starts afterwards by itself; dhcpcd -n would start a second one) and never with a static address.
dhcp_again(){
  [ "$(cfg NETMODE)" = static ] && return 0
  pgrep -f "^dhcpcd: $1 " >/dev/null 2>&1 || return 0
  setsid dhcpcd -n "$1" >/dev/null 2>&1 < /dev/null &
}

# --- what the supplicant says (wpa_supplicant 2.10/2.11, level info), adapter by adapter
handle(){
  local i=$1 m=$2 l why="" kind="" srv="" r end
  while IFS= read -r l; do
    echo "$l"     # the journal of the unit (journalctl -u openthinrdp-dot1x@IF): no secret at this level
    case "$l" in
      *CTRL-EVENT-EAP-STARTED*) touch "$PRIV/$i.started"; why=""; kind="" ;;
      *CTRL-EVENT-EAP-PEER-CERT*depth=0*) srv=$(echo "$l" | sed -n "s/.*subject='\([^']*\)'.*/\1/p" | sed 's/.*CN=//; s/\/.*//') ;;
      *CTRL-EVENT-EAP-TLS-CERT-ERROR*)
        kind=cert
        why="certificate of the server not accepted: $(echo "$l" | sed -n "s/.*err='\([^']*\)'.*/\1/p") ($(echo "$l" | sed -n "s/.*subject='\([^']*\)'.*/\1/p"))" ;;
      # refused inside PEAP: an MSCHAPv2 failure (Windows NPS, E=691), or a failure result of the tunnel (FreeRADIUS)
      *MSCHAPV2*ailure*|*MSCHAPV2*E=691*) [ -n "$kind" ] || { kind=password; why="password refused by the server"; } ;;
      *EAP-TLV:*Result*Failure*) [ -n "$kind" ] || { kind=password; why="user or password refused by the server"; } ;;
      *CTRL-EVENT-EAP-SUCCESS*)
        touch "$PRIV/$i.started"
        if [ ! -f "$PRIV/$i.authed" ]; then
          touch "$PRIV/$i.authed"
          st_set "$i" "authenticated ($(mode_name "$m")${srv:+, server $srv})"
          ev "802.1X: authenticated on $i ($(mode_name "$m")${srv:+, server $srv})"
          dhcp_again "$i"
        fi ;;
      *CTRL-EVENT-EAP-FAILURE*)
        # refused after being in: the switch may move the port to another network (a guest VLAN), so the address too
        [ -f "$PRIV/$i.authed" ] && { rm -f "$PRIV/$i.authed"; dhcp_again "$i"; }
        if [ -z "$why" ]; then
          if [ "$m" = tls ]; then why="refused by the server (certificate, account or network policy)"
          else why="refused by the server (user, password or network policy)"; fi
        fi
        # PEAP refused after the server was trusted: the credentials went, the account counts the failure
        if [ "$m" = peap ] && [ "$kind" != cert ]; then
          end=$(( $(date +%s) + HOLD ))
          r="$why: next try at $(date -d "@$end" +%H:%M), or as soon as a new password arrives"
          printf '%s\nfailed: %s\n' "$end" "$r" > "$PRIV/$i.hold"
          st_set "$i" "failed: $r"; ev "802.1X: failed on $i: $r"
          wcli "$i" terminate
        else
          r="failed: $why"
          [ "$(st_get "$i")" = "$r" ] || ev "802.1X: failed on $i: $why"
          st_set "$i" "$r"
        fi
        why=""; kind="" ;;
    esac
  done
}

# --- the cable, every second: plugged in = a new authentication (an EAPOL-Start after 2 and 8 s when the switch has
# not started one by itself: the supplicant does not follow the link), unplugged = no link; nothing heard from the
# switch within $NOAUTH s = no authenticator
watch_link(){
  local i=$1 c prev=x t0=0 e s n=0
  while [ -d "$SYS/$i" ]; do
    c=0; carrier "$i" && c=1
    if [ "$c" != "$prev" ]; then
      if [ $c = 1 ]; then
        t0=$(date +%s); n=0
        [ -f "$PRIV/$i.authed" ] || { s=$(st_get "$i"); [[ $s == failed* ]] || st_set "$i" authenticating; }
      else
        rm -f "$PRIV/$i.authed" "$PRIV/$i.started"
        [ "$prev" = x ] || ev "802.1X: link down on $i"
        st_set "$i" "no link"
      fi
      prev=$c
    fi
    if [ $c = 1 ] && [ ! -f "$PRIV/$i.started" ]; then
      e=$(( $(date +%s) - t0 ))
      # (reassociate: a new EAPOL-Start, without the EAPOL-Logoff that would close a port already open)
      if { [ $n = 0 ] && [ $e -ge 2 ]; } || { [ $n = 1 ] && [ $e -ge 8 ]; }; then
        n=$((n + 1)); wcli "$i" reassociate
      fi
      if [ $e -ge "$NOAUTH" ] && [ "$(st_get "$i")" = authenticating ]; then
        st_set "$i" "no authenticator: DHCP without 802.1X"
        ev "802.1X: no authenticator on $i (no answer in $NOAUTH s: a port without 802.1X), the network without it"
      fi
    fi
    sleep 1
  done
  # the adapter is gone (a USB adapter unplugged): its supplicant too
  wcli "$i" terminate
}

run(){
  local i=$1 m w miss end
  dirs
  [ -d "$SYS/$i" ] || exit 0
  rm -f "$PRIV/$i.started" "$PRIV/$i.authed"
  while :; do
    m=$(cfg DOT1X); w=$(wanted)
    case "$w" in
      off) rm -f "$PUB/$i"; exit 0 ;;
      incomplete:*)
        miss=${w#incomplete: }
        [ "$(st_get "$i")" = "$w" ] || ev "802.1X: settings incomplete on $i: $miss (the network without 802.1X)"
        st_set "$i" "$w"; echo "$w" | sha256sum | cut -c1-64 > "$PRIV/$i.sig"; exit 0 ;;
    esac
    # a refused password: nothing sent before the time (the state says when, also after the adapter was restarted)
    end=$(head -1 "$PRIV/$i.hold" 2>/dev/null)
    [ -n "$end" ] && st_set "$i" "$(sed -n 2p "$PRIV/$i.hold")"
    while [ -n "$end" ] && [ -f "$PRIV/$i.hold" ] && [ "$(date +%s)" -lt "$end" ]; do sleep 5; done
    rm -f "$PRIV/$i.hold" "$PRIV/$i.started" "$PRIV/$i.authed"
    ( umask 077; echo "$w" > "$PRIV/$i.conf" )
    echo "$w" | sha256sum | cut -c1-64 > "$PRIV/$i.sig"
    if carrier "$i"; then st_set "$i" authenticating; else st_set "$i" "no link"; fi
    watch_link "$i" & local wl=$!
    wpa_supplicant -D wired -i "$i" -c "$PRIV/$i.conf" 2>&1 | handle "$i" "$m"
    kill $wl 2>/dev/null; wait $wl 2>/dev/null
    [ -d "$SYS/$i" ] || { rm -f "$PUB/$i"; exit 0; }
    # stopped for a refused password (the loop waits), or ended by itself: again in a few seconds
    [ -f "$PRIV/$i.hold" ] || sleep 5
  done
}

wait_auth(){
  local i=$1 n s
  [ "$(cfg DOT1X)" = off ] && return 0
  dirs
  if ! systemctl is-active -q "$(unit "$i")" 2>/dev/null; then
    rm -f "$PUB/$i"; systemctl start --no-block "$(unit "$i")" 2>/dev/null
  fi
  ip link set "$i" up 2>/dev/null
  for n in $(seq 1 10); do carrier "$i" && break; sleep 0.5; done
  carrier "$i" || return 0
  for n in $(seq 1 $(( WAITMAX * 2 ))); do
    s=$(st_get "$i")
    case "$s" in authenticated*|failed*|"no authenticator"*|incomplete*) return 0 ;; esac
    sleep 0.5
  done
  return 0
}

apply_all(){
  local skip=" $* " i sig u
  dirs
  if [ "$(cfg DOT1X)" = off ]; then
    for u in $(systemctl list-units --all --plain --no-legend 'openthinrdp-dot1x@*' 2>/dev/null | awk '{print $1}'); do systemctl stop --no-block "$u"; done
    rm -f "$PUB"/* "$PRIV"/*.hold; return 0
  fi
  sig=$(signature)
  for i in $(adapters); do
    case "$skip" in *" $i "*) continue ;; esac
    # only an adapter ifupdown brought up (the others start it in their pre-up)
    ifquery --state "$i" >/dev/null 2>&1 || continue
    [ "$(cat "$PRIV/$i.sig" 2>/dev/null)" = "$sig" ] && { systemctl is-active -q "$(unit "$i")" || [[ $(st_get "$i") == incomplete* ]]; } && continue
    rm -f "$PRIV/$i.hold"; systemctl restart --no-block "$(unit "$i")"
  done
}

status(){
  local o="" f
  [ "$(cfg DOT1X)" = off ] && { echo off; return; }
  for f in "$PUB"/*; do [ -f "$f" ] && o="$o${o:+; }$(basename "$f"): $(cat "$f")"; done
  o=${o:-$(cfg DOT1X), not started (no wired adapter configured yet)}
  f=$(eap_warning); echo "$o${f:+ - $f}"
}

# --- secrets from the manager (over SSH, never through the management folder, which every device can read)
# after a new password or certificate: the Wi-Fi configuration and the wired supplicants with it
secrets_changed(){
  rm -f "$PRIV"/*.hold
  case "$(cfg WIFI_SECURITY)" in peap|tls) wifi_conf_update ;; esac
  apply_all
}
password_in(){
  local t; dirs; t=$(mktemp); chmod 600 "$t"
  head -c 4096 | sed 's/\r$//; 1s/^\xEF\xBB\xBF//' | head -1 > "$t"
  if [ -z "$(head -1 "$t")" ] || [ "$(head -1 "$t" | wc -c)" -gt 257 ]; then rm -f "$t"; echo "ERROR=one line of 1 to 256 characters is needed"; exit 1; fi
  mkdir -p "$EAP_DIR"; secret_store eap-password "$t"
  ev "802.1X: password received from the manager"
  secrets_changed
  echo "OK=password"
}
# Standard input, from the manager:
#   PASSWORD=<password of the key, or of the PKCS#12 file>   (optional)
#   PKCS12=<the .pfx/.p12 file in base64, one line>
# or, instead of PKCS12=, PEM blocks: the certificate of the device first (then its chain, if any) and the private key.
# The key is kept DECRYPTED, as a secret (in the TPM when there is one): its password is not kept anywhere.
client_in(){
  local d pw s na
  dirs; d=$(mktemp -d); chmod 700 "$d"
  fail(){ rm -rf "$d"; echo "ERROR=$*"; exit 1; }
  head -c 262144 | sed 's/\r$//; 1s/^\xEF\xBB\xBF//' > "$d/in"
  pw=$(sed -n 's/^PASSWORD=//p' "$d/in" | head -1)
  # the passwords to openssl through a descriptor, never on its command line (ps shows it to every account)
  if grep -q '^PKCS12=' "$d/in"; then
    sed -n 's/^PKCS12=//p' "$d/in" | head -1 | base64 -d > "$d/p12" 2>/dev/null || fail "the PKCS#12 file is not valid base64"
    p12(){ openssl pkcs12 -in "$d/p12" -passin fd:3 "$@" 3<<< "$pw" >/dev/null 2>&1 ||
           openssl pkcs12 -legacy -in "$d/p12" -passin fd:3 "$@" 3<<< "$pw" >/dev/null 2>&1; }
    p12 -nokeys -clcerts -out "$d/c0" || fail "the PKCS#12 file cannot be opened (wrong password?)"
    p12 -nocerts -nodes -out "$d/k0" || fail "the PKCS#12 file has no private key"
    p12 -nokeys -cacerts -out "$d/ch0" || : > "$d/ch0"
  else
    sed -n '/^-----BEGIN CERTIFICATE-----$/,/^-----END CERTIFICATE-----$/p' "$d/in" > "$d/c0"
    sed -n '/^-----BEGIN [A-Z ]*PRIVATE KEY-----$/,/^-----END [A-Z ]*PRIVATE KEY-----$/p' "$d/in" > "$d/k0"
    : > "$d/ch0"
  fi
  # the first certificate is the device's own, the others its chain
  openssl x509 -in "$d/c0" -out "$d/crt" 2>/dev/null || fail "no certificate"
  awk '/^-----BEGIN CERTIFICATE-----$/{n++} n>1' "$d/c0" > "$d/chain"
  sed -n '/^-----BEGIN CERTIFICATE-----$/,/^-----END CERTIFICATE-----$/p' "$d/ch0" >> "$d/chain"
  [ -s "$d/k0" ] || fail "no private key"
  ( umask 077; openssl pkey -in "$d/k0" -passin fd:3 -out "$d/key" 3<<< "$pw" >/dev/null 2>&1 ) || fail "the private key cannot be read (a wrong or missing password?)"
  [ "$(openssl x509 -in "$d/crt" -noout -pubkey 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum)" = \
    "$(openssl pkey -in "$d/key" -pubout -outform DER 2>/dev/null | sha256sum)" ] || fail "the private key does not belong to the certificate"
  na=$(openssl x509 -in "$d/crt" -noout -enddate | sed 's/^notAfter=//')
  openssl x509 -in "$d/crt" -noout -checkend 0 >/dev/null 2>&1 || fail "the certificate expired on $na"
  s=$(openssl x509 -in "$d/crt" -noout -subject -nameopt RFC2253 | sed 's/^subject=//')
  mkdir -p "$EAP_DIR"
  cat "$d/crt" "$d/chain" > "$d/all"; install -m 644 "$d/all" "$EAP_CERT"
  secret_store eap-client.key "$d/key"
  rm -rf "$d"
  ev "802.1X: client certificate received from the manager ($s, valid until $na)"
  secrets_changed
  echo "OK=client $s, valid until $na"
}

case "$1" in
  wait) wait_auth "$2" ;;
  stop) systemctl stop --no-block "$(unit "$2")" 2>/dev/null; rm -f "$PUB/$2" ;;
  run) run "$2" ;;
  apply) shift; apply_all "$@" ;;
  status) status ;;
  password) password_in ;;
  client) client_in ;;
  *) echo "usage: $0 wait IF | stop IF | run IF | apply [IF...] | status | password | client"; exit 2 ;;
esac
exit 0
