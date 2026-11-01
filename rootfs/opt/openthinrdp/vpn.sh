#!/bin/bash
# The VPN of the device (VPN=wireguard|openvpn|tailscale|off), for devices outside the office: the broker, the management
# folder and the DNS of the office through the tunnel. Runs as root.
#   vpn.sh apply         the tunnel as the settings say (apply.sh, at boot and after every change)
#   vpn.sh check         every 5 minutes (report.sh): WireGuard server name resolved again when the tunnel is silent
#                        (a dynamic address), the DNS of the tunnel back in front when DHCP rewrote resolv.conf
#   vpn.sh status        one line for the report and the diagnostics
#   vpn.sh pubkey        the WireGuard public key of the device (made at the first apply with VPN=wireguard)
#   vpn.sh profile       the OpenVPN profile on standard input (the manager, over SSH: it holds secrets and never goes
#                        through the management folder, which every device can read)
#   vpn.sh auth          user and password of the OpenVPN profile on standard input, two lines (the manager, over SSH)
#   vpn.sh dns           the DNS of the tunnel in front of resolv.conf again (dhcpcd hook)
#   vpn.sh openvpn-run | openvpn-up | openvpn-down   openthinrdp-vpn.service and the scripts openvpn calls
# WireGuard: the private key is made on the device and never leaves it (a secret, in the TPM when there is one); its
# public key goes to the report, to be added as a peer on the server with VPN_ADDRESS. No wg-quick (it needs
# resolvconf): interface, routes and DNS are set here. OpenVPN: the profile (and its user and password) are secrets too.
. /opt/openthinrdp/lib/common.sh
. "$OTR/lib/secrets.sh"
WG=otr-wg; RUN=/run/openthinrdp/vpn; RES=/etc/resolv.conf
mkdir -p "$RUN"; chmod 700 "$RUN"
DOM=$(cfg DOMAIN | tr 'A-Z' 'a-z'); [[ $DOM == *.* ]] || DOM=""

# --- DNS of the tunnel: in front of resolv.conf while the tunnel is up, the earlier file kept in $RUN/resolv.before
OURS='# OpenThinRDP VPN (vpn.sh)'
res_write(){   # FILE: becomes resolv.conf, also when apply.sh made it immutable (static DNS)
  local imm=0
  lsattr -d "$RES" 2>/dev/null | cut -c1-20 | grep -q i && imm=1
  [ $imm = 1 ] && chattr -i "$RES" 2>/dev/null
  # written in place (it can be a mount point); a link (to another resolver's file) is replaced by a file
  [ -L "$RES" ] && rm -f "$RES"
  cat "$1" > "$RES"; chmod 644 "$RES"
  [ $imm = 1 ] && chattr +i "$RES" 2>/dev/null
  return 0
}
dns_on(){   # DNS servers of the tunnel (none = resolv.conf stays as it is)
  local list="$*" t n=0 d s
  [ -n "$list" ] || return 0
  if ! head -1 "$RES" 2>/dev/null | grep -qx "$OURS"; then cp "$RES" "$RUN/resolv.before" 2>/dev/null || : > "$RUN/resolv.before"; fi
  t=$(mktemp)
  # the domain of the office first, the search domains of the local network after
  s=$(echo $DOM $(sed -n 's/^search[[:space:]]\+//p' "$RUN/resolv.before" | head -1) | tr ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ' ')
  { echo "$OURS"; echo "# the DNS of the tunnel first, the earlier ones after; restored when the tunnel goes down"
    [ -n "${s// /}" ] && echo "search ${s% }"
    for d in $list; do [ $n -lt 3 ] && { echo "nameserver $d"; n=$((n+1)); }; done
    grep '^nameserver' "$RUN/resolv.before" | while read -r _ d; do
      case " $list " in *" $d "*) ;; *) [ $n -lt 3 ] && { echo "nameserver $d"; n=$((n+1)); } ;; esac
    done; } > "$t"
  cmp -s "$t" "$RES" || res_write "$t"
  rm -f "$t"
}
dns_off(){
  head -1 "$RES" 2>/dev/null | grep -qx "$OURS" || { rm -f "$RUN/resolv.before"; return 0; }
  if [ -f "$RUN/resolv.before" ]; then res_write "$RUN/resolv.before"; rm -f "$RUN/resolv.before"; fi
}

# --- WireGuard
wg_key(){   # the path of the private key, made the first time
  local p t
  p=$(secret_path vpn-wg.key)
  if [ ! -s "$p" ]; then
    t=$(mktemp); ( umask 077; wg genkey > "$t" ) || { rm -f "$t"; return 1; }
    secret_store vpn-wg.key "$t"; p=$(secret_path vpn-wg.key)
    ev "VPN: WireGuard key of this device made, public key $(wg pubkey < "$p")"
  fi
  echo "$p"
}
wg_endpoint(){   # name:port -> address:port (51820 when no port)
  local s=$1 h p a
  h=${s%:*}; p=${s##*:}; [ "$h" = "$s" ] && p=51820
  a=$(getent ahostsv4 "$h" 2>/dev/null | awk 'NR==1{print $1}')
  [ -n "$a" ] && echo "$a:$p"
}
wg_down(){
  ip link show "$WG" >/dev/null 2>&1 || { rm -f "$RUN/wg.sig"; return 0; }
  ip link del "$WG" 2>/dev/null
  [ -f "$RUN/wg.hostroute" ] && ip route del $(cat "$RUN/wg.hostroute") 2>/dev/null
  rm -f "$RUN/wg.sig" "$RUN/wg.hostroute"; dns_off
  ev "VPN: WireGuard tunnel down"
}
wg_up(){
  local server key addr routes ep sig gw dev r k allowed
  server=$(cfg VPN_SERVER); key=$(cfg VPN_SERVER_KEY); addr=$(cfg VPN_ADDRESS); routes=$(cfg VPN_ROUTES)
  if [ -z "$server" ] || [ -z "$key" ] || [ -z "$addr" ]; then
    echo "wireguard: VPN_SERVER, VPN_SERVER_KEY and VPN_ADDRESS are needed" > "$RUN/state"; wg_down; return 0; fi
  command -v wg >/dev/null || { echo "wireguard: wireguard-tools missing (next update)" > "$RUN/state"; return 0; }
  k=$(wg_key) || { echo "wireguard: key not made" > "$RUN/state"; return 0; }
  ep=$(wg_endpoint "$server")
  [ -n "$ep" ] || { echo "wireguard: $server not resolved (DNS)" > "$RUN/state"; return 0; }
  allowed=$(echo "${routes:-0.0.0.0/0}" | tr -s ' ,;' ',' | sed 's/^,//; s/,$//')
  # anything that changes the peer, the address or the routes: the interface is made again
  sig=$(printf '%s|' "$key" "$addr" "$allowed" "$(wg pubkey < "$k")")
  if [ "$(cat "$RUN/wg.sig" 2>/dev/null)" != "$sig" ] || ! ip link show "$WG" >/dev/null 2>&1; then
    ip link del "$WG" 2>/dev/null
    [ -f "$RUN/wg.hostroute" ] && ip route del $(cat "$RUN/wg.hostroute") 2>/dev/null
    ip link add "$WG" type wireguard || { echo "wireguard: interface not created (kernel module?)" > "$RUN/state"; return 0; }
    ip link set "$WG" mtu 1420
    ip address add "$addr" dev "$WG"
    echo "$sig" > "$RUN/wg.sig"
    ev "VPN: WireGuard tunnel to $server ($ep), address $addr, routes $allowed"
  fi
  wg set "$WG" private-key "$k" peer "$key" endpoint "$ep" allowed-ips "$allowed" persistent-keepalive 25
  ip link set "$WG" up
  if [ -z "$routes" ]; then
    # all the traffic: the server itself stays on the way it has now, the rest through the tunnel (two halves, so
    # the default route of DHCP stays and comes back by itself when the tunnel goes)
    read -r gw dev < <(ip -4 route show default | awk '{for(i=1;i<NF;i++){if($i=="via")g=$(i+1);if($i=="dev")d=$(i+1)}; print g, d; exit}')
    if [ -n "$gw" ]; then r="${ep%:*}/32 via $gw dev $dev"; ip route replace $r; echo "$r" > "$RUN/wg.hostroute"; fi
    ip route replace 0.0.0.0/1 dev "$WG"; ip route replace 128.0.0.0/1 dev "$WG"
  else
    for r in $(echo "$routes" | tr ',;' '  '); do ip route replace "$r" dev "$WG"; done
  fi
  echo "$ep" > "$RUN/wg.endpoint"
  echo "wireguard: up" > "$RUN/state"
  dns_on $(cfg VPN_DNS)
}
wg_status(){
  local hs now
  ip link show "$WG" >/dev/null 2>&1 || { cat "$RUN/state" 2>/dev/null || echo "wireguard: down"; return; }
  hs=$(wg show "$WG" latest-handshakes 2>/dev/null | awk 'NR==1{print $2}'); now=$(date +%s)
  if [ -z "$hs" ] || [ "$hs" = 0 ]; then echo "wireguard: no answer from $(cfg VPN_SERVER) yet (is this device a peer of the server?)"
  else echo "wireguard: up, last handshake $(( now - hs )) s ago"; fi
}

# --- OpenVPN
ovpn_stop(){
  systemctl is-active -q openthinrdp-vpn.service 2>/dev/null || { [ -f "$RUN/openvpn.up" ] && dns_off; rm -f "$RUN/openvpn.up"; return 0; }
  systemctl stop openthinrdp-vpn.service; rm -f "$RUN/openvpn.up"; dns_off
  ev "VPN: OpenVPN stopped"
}
ovpn_start(){
  local sig
  command -v openvpn >/dev/null || { echo "openvpn: openvpn missing (next update)" > "$RUN/state"; return 0; }
  [ -s "$(secret_path vpn-openvpn.conf)" ] || { echo "openvpn: no profile (send it from the manager: VPN profile...)" > "$RUN/state"; return 0; }
  # routes and DNS are options of the openvpn command: changed, the tunnel is made again
  sig="$(cfg VPN_ROUTES)|$(cfg VPN_DNS)"
  if systemctl is-active -q openthinrdp-vpn.service; then
    [ "$(cat "$RUN/openvpn.sig" 2>/dev/null)" = "$sig" ] && return 0
    echo "$sig" > "$RUN/openvpn.sig"; systemctl restart --no-block openthinrdp-vpn.service; return 0
  fi
  echo "$sig" > "$RUN/openvpn.sig"
  [ -f "$RUN/openvpn.authfail" ] || echo "openvpn: connecting" > "$RUN/state"
  systemctl start --no-block openthinrdp-vpn.service
}
# a CIDR network as OpenVPN wants it: address and netmask
cidr_mask(){ local n=${1%/*} p=${1#*/} m=0 i o=""; [ "$p" = "$1" ] && p=32
  m=$(( p == 0 ? 0 : (0xFFFFFFFF << (32 - p)) & 0xFFFFFFFF ))
  for i in 24 16 8 0; do o="$o$(( (m >> i) & 255 ))."; done; echo "$n ${o%.}"; }
ovpn_run(){
  local p a r; local -a o=()
  p=$(secret_path vpn-openvpn.conf); a=$(secret_path vpn-openvpn.auth)
  [ -s "$p" ] || exit 1
  # user or password refused: the next try in an hour, or as soon as the manager sends them again (auth_in). Tried
  # again every 15 s (the service restarts), a wrong password would lock the account on a server that checks a domain.
  if [ -f "$RUN/openvpn.authfail" ]; then
    echo "openvpn: user or password refused by the server, next try $(date -d '+1 hour' +%H:%M) (send them again from the manager: VPN profile...)" > "$RUN/state"
    sleep 3600 & wait $!; rm -f "$RUN/openvpn.authfail"
  fi
  [ -s "$a" ] && o+=(--auth-user-pass "$a")
  for r in $(cfg VPN_ROUTES | tr ',;' '  '); do o+=(--route $(cidr_mask "$r")); done
  openvpn --config "$p" "${o[@]}" --auth-nocache --auth-retry none --script-security 2 \
    --up "$OTR/vpn.sh openvpn-up" --down "$OTR/vpn.sh openvpn-down" --down-pre --status "$RUN/openvpn.status" 30 2>&1 |
  while IFS= read -r l; do
    echo "$l"
    case "$l" in *AUTH_FAILED*)
      touch "$RUN/openvpn.authfail"; ev "VPN: OpenVPN user or password refused by the server: next try in an hour" ;; esac
  done
}
ovpn_updown(){
  local list="" i v
  if [ "$1" = up ]; then
    list=$(cfg VPN_DNS)
    # the DNS servers the server pushes (dhcp-option DNS), when VPN_DNS does not name them
    if [ -z "$list" ]; then
      for i in $(seq 1 30); do v="foreign_option_$i"; [ -n "${!v:-}" ] || break
        case "${!v}" in "dhcp-option DNS "*) list="$list ${!v#dhcp-option DNS }" ;; esac; done
    fi
    dns_on $list; echo "$list" > "$RUN/openvpn.dns"; touch "$RUN/openvpn.up"; echo "openvpn: up" > "$RUN/state"
    ev "VPN: OpenVPN connected ($dev, ${ifconfig_local:-?})"
  else
    dns_off; rm -f "$RUN/openvpn.up" "$RUN/openvpn.dns"; echo "openvpn: down, reconnecting" > "$RUN/state"
    ev "VPN: OpenVPN disconnected"
  fi
  return 0
}

# --- the OpenVPN profile from the manager. Refused: what would run commands (the scripts are this file's), or a file
# that is no OpenVPN client profile.
profile_in(){
  local t; t=$(mktemp); head -c 262144 > "$t"
  # Windows line ends, and the UTF-8 mark a file saved by Notepad (or a .NET program's input) starts with
  sed -i 's/\r$//; 1s/^\xEF\xBB\xBF//' "$t"
  if ! grep -Eq '^[[:space:]]*(remote|client)([[:space:]]|$)' "$t"; then rm -f "$t"; echo "ERROR=not an OpenVPN client profile (no remote or client line)"; exit 1; fi
  if grep -Eiq '^[[:space:]]*(script-security|up|down|route-up|route-pre-down|ipchange|tls-verify|auth-user-pass-verify|client-connect|client-disconnect|learn-address|plugin|management|daemon|log|log-append|writepid|cd|chroot|status)([[:space:]]|$)' "$t"; then
    rm -f "$t"; echo "ERROR=the profile runs commands or writes files (script-security, up/down, plugin...): remove those lines"; exit 1; fi
  secret_store vpn-openvpn.conf "$t"; rm -f "$RUN/openvpn.authfail"
  ev "VPN: OpenVPN profile received from the manager ($(grep -E '^[[:space:]]*remote[[:space:]]' "$(secret_path vpn-openvpn.conf)" | head -1 | awk '{print $2":"$3}'))"
  [ "$(cfg VPN)" = openvpn ] && { systemctl restart --no-block openthinrdp-vpn.service 2>/dev/null; ovpn_start; }
  echo "OK=profile"
}
auth_in(){
  local t; t=$(mktemp); head -c 4096 | sed 's/\r$//; 1s/^\xEF\xBB\xBF//' | head -2 > "$t"
  if [ "$(wc -l < "$t")" -lt 2 ] || [ -z "$(head -1 "$t")" ]; then rm -f "$t"; echo "ERROR=two lines are needed: user and password"; exit 1; fi
  secret_store vpn-openvpn.auth "$t"; rm -f "$RUN/openvpn.authfail"
  ev "VPN: OpenVPN user and password received from the manager"
  [ "$(cfg VPN)" = openvpn ] && systemctl restart --no-block openthinrdp-vpn.service 2>/dev/null
  echo "OK=auth"
}

# --- Tailscale (VPN=tailscale, 0.3.0): the PC at home reached from outside. No server to set: the device signs in
# to the Tailscale account once, with the link it shows in the settings (opened on a phone). The state for the
# settings screen in /run/openthinrdp-tailscale (one line, readable by the kiosk: no secret in it)
TSF=/run/openthinrdp-tailscale
ts_state(){ tailscale status --json 2>/dev/null | sed -n "s/^[[:space:]]*\"$1\":[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1; }
ts_status(){
  command -v tailscale >/dev/null || { echo "tailscale: not installed (no Internet when it was turned on: it installs at the next try)"; return; }
  case "$(ts_state BackendState)" in
    Running) echo "tailscale: up $(tailscale ip -4 2>/dev/null | head -1)" ;;
    NeedsLogin) u=$(ts_state AuthURL); echo "tailscale: sign in at ${u:-(link not ready yet)}" ;;
    "") echo "tailscale: down" ;;
    *) echo "tailscale: $(ts_state BackendState)" ;;
  esac; }
# Tailscale is not in the image (it would weigh on every device for the few that use it): installed here when it is
# turned on, from its signed repository (python3 fetches the key and the list: no curl), and kept up to date with the
# security updates; removed with its repository when it is turned off (signing in again is then needed)
ts_install(){ command -v tailscale >/dev/null && return 0
  echo "tailscale: installing" > "$TSF"; chmod 644 "$TSF"
  python3 -c "import sys, urllib.request; urllib.request.urlretrieve(sys.argv[1], sys.argv[2])" https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg /usr/share/keyrings/tailscale-archive-keyring.gpg &&
  python3 -c "import sys, urllib.request; urllib.request.urlretrieve(sys.argv[1], sys.argv[2])" https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list /etc/apt/sources.list.d/tailscale.list &&
  apt-get -o DPkg::Lock::Timeout=300 update -q >/dev/null 2>&1 &&
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y -q --no-install-recommends tailscale >/dev/null 2>&1 &&
  printf 'Unattended-Upgrade::Origins-Pattern {\n        "site=pkgs.tailscale.com";\n};\n' > /etc/apt/apt.conf.d/54openthinrdp-tailscale &&
  { ev "Tailscale installed"; return 0; }
  ev "Tailscale could not be installed (no Internet, or no package for $(dpkg --print-architecture))"; return 1; }
ts_up(){
  ts_install
  if command -v tailscale >/dev/null; then
    systemctl enable --now tailscaled.service >/dev/null 2>&1
    # not signed in yet: "up" asks the service for a sign-in link and waits; 10 s are enough for the link
    [ "$(ts_state BackendState)" = Running ] || timeout 15 tailscale up --hostname="$(hostname)" --timeout=10s >/dev/null 2>&1
  fi
  ts_status > "$TSF"; chmod 644 "$TSF"; }
ts_down(){ command -v tailscale >/dev/null || { rm -f "$TSF"; return 0; }
  systemctl is-active -q tailscaled.service && { tailscale down >/dev/null 2>&1; systemctl disable --now tailscaled.service >/dev/null 2>&1; }
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 purge -y -q tailscale >/dev/null 2>&1 &&
    { rm -f /etc/apt/sources.list.d/tailscale.list /usr/share/keyrings/tailscale-archive-keyring.gpg /etc/apt/apt.conf.d/54openthinrdp-tailscale; ev "Tailscale removed (turned off)"; }
  rm -f "$TSF"; }

case "$1" in
  apply)
    exec 8>"$RUN/lock"; flock 8
    case "$(cfg VPN)" in
      wireguard) ts_down; ovpn_stop; wg_up ;;
      openvpn) ts_down; wg_down; ovpn_start ;;
      tailscale) wg_down; ovpn_stop; ts_up ;;
      *) wg_down; ovpn_stop; ts_down; rm -f "$RUN/state" ;;
    esac ;;
  check)
    exec 8>"$RUN/lock"; flock -n 8 || exit 0
    case "$(cfg VPN)" in
      wireguard)
        if ip link show "$WG" >/dev/null 2>&1; then
          hs=$(wg show "$WG" latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')
          # silent for 3 minutes: the server's address may have changed (dynamic DNS)
          if [ -z "$hs" ] || [ $(( $(date +%s) - ${hs:-0} )) -gt 180 ]; then
            ep=$(wg_endpoint "$(cfg VPN_SERVER)")
            [ -n "$ep" ] && [ "$ep" != "$(cat "$RUN/wg.endpoint" 2>/dev/null)" ] && { wg_up; ev "VPN: WireGuard server now at $ep"; }
          fi
          dns_on $(cfg VPN_DNS)
        else wg_up; fi ;;
      openvpn) [ -f "$RUN/openvpn.up" ] && dns_on $(cat "$RUN/openvpn.dns" 2>/dev/null) ;;
      tailscale) ts_up ;;
    esac ;;
  dns)
    case "$(cfg VPN)" in
      wireguard) ip link show "$WG" >/dev/null 2>&1 && dns_on $(cfg VPN_DNS) ;;
      openvpn) [ -f "$RUN/openvpn.up" ] && dns_on $(cat "$RUN/openvpn.dns" 2>/dev/null) ;;
    esac; exit 0 ;;
  status)
    case "$(cfg VPN)" in
      wireguard) wg_status ;;
      openvpn) if [ -f "$RUN/openvpn.up" ]; then echo "openvpn: up"; else cat "$RUN/state" 2>/dev/null || echo "openvpn: down"; fi ;;
      tailscale) ts_status ;;
      *) echo off ;;
    esac ;;
  pubkey) p=$(secret_path vpn-wg.key); [ -s "$p" ] && command -v wg >/dev/null && wg pubkey < "$p" ;;
  profile) profile_in ;;
  auth) auth_in ;;
  openvpn-run) ovpn_run ;;
  openvpn-up) ovpn_updown up ;;
  openvpn-down) ovpn_updown down ;;
  *) echo "usage: $0 apply | check | status | pubkey | profile | auth | dns"; exit 2 ;;
esac
