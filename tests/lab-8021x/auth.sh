#!/bin/bash
# The "switch" of the 802.1X lab (container d1x-auth): hostapd with its wired driver and internal EAP server as the
# authenticator, dnsmasq as the DHCP server of the port, and nftables keeping DHCP closed until the port is authorized
# (as a switch does: nothing but EAPOL before the authentication).
#   auth.sh setup                 address, DHCP server, the port closed
#   auth.sh hostapd SERVER [RAD]  (re)start hostapd with the certificate SERVER (server, rogue-server, other-server);
#                                 RAD=radius: hostapd as a plain authenticator, the EAP server is FreeRADIUS
#   auth.sh nohostapd             no authenticator at all (a port without 802.1X): the port open
#   auth.sh flap                  link down and up (cable out and in), the port closed again
#   auth.sh wlan SERVER KEYMGMT PMF   hostapd as a Wi-Fi access point on wlan0 (mac80211_hwsim), WPA-Enterprise
L=/lab; O=/lab/out; mkdir -p $O
ts(){ date '+%H:%M:%S.%3N'; }
close_port(){ nft flush set inet lab ok 2>/dev/null; echo "$(ts) port closed" >> $O/port.log; }
case "$1" in
  setup)
    ip addr add 10.77.0.1/24 dev eth0 2>/dev/null; ip link set eth0 up
    nft -f - <<'NFT'
table inet lab {
  set ok { type ether_addr; }
  chain in { type filter hook input priority 0; policy accept;
    iifname "eth0" udp dport 67 ether saddr != @ok counter drop
  }
}
NFT
    : > $O/dnsmasq.log
    dnsmasq --interface=eth0 --bind-interfaces --port=0 --dhcp-range=10.77.0.100,10.77.0.150,255.255.255.0,10m \
      --dhcp-leasefile=/tmp/leases --log-dhcp --log-facility=$O/dnsmasq.log --pid-file=/run/lab-dnsmasq.pid
    echo setup ;;
  hostapd)
    pkill -x hostapd; pkill -f 'hostapd_cli -i eth0'; sleep 0.5; close_port
    S=${2:-server}
    {
      echo "interface=eth0"; echo "driver=wired"; echo "ctrl_interface=/run/hostapd"
      echo "logger_stdout=-1"; echo "logger_stdout_level=1"
      echo "ieee8021x=1"; echo "eapol_version=2"; echo "use_pae_group_addr=1"; echo "eap_reauth_period=0"
      if [ "${3:-}" = radius ]; then
        echo "own_ip_addr=127.0.0.1"; echo "auth_server_addr=127.0.0.1"; echo "auth_server_port=1812"; echo "auth_server_shared_secret=testing123"
      else
        echo "eap_server=1"; echo "eap_user_file=$L/eap_users"
        echo "ca_cert=$L/pki/ca.crt"; echo "server_cert=$L/pki/$S.crt"; echo "private_key=$L/pki/$S.key"
      fi
    } > /tmp/hostapd-wired.conf
    echo "$(ts) ----- hostapd $S ${3:-internal}" >> $O/hostapd.log
    hostapd -t /tmp/hostapd-wired.conf >> $O/hostapd.log 2>&1 &
    sleep 1
    hostapd_cli -i eth0 -p /run/hostapd -a $L/hostapd-action.sh -B >/dev/null
    echo "hostapd $S" ;;
  nohostapd)
    pkill -x hostapd; pkill -f 'hostapd_cli -i eth0'; sleep 0.5
    nft flush chain inet lab in; echo "$(ts) no authenticator, port open" >> $O/port.log; echo nohostapd ;;
  closeport)
    nft flush chain inet lab in; nft add rule inet lab in iifname eth0 udp dport 67 ether saddr != @ok counter drop; close_port ;;
  flap)
    close_port; ip link set eth0 down; sleep "${2:-2}"; ip link set eth0 up; echo "$(ts) link flapped" >> $O/port.log ;;
  wlan)
    pkill -f 'hostapd -t /tmp/hostapd-wlan'; sleep 0.5
    S=${2:-server}; K=${3:-WPA-EAP WPA-EAP-SHA256}; P=${4:-1}
    ip addr add 10.78.0.1/24 dev wlan0 2>/dev/null
    cat > /tmp/hostapd-wlan.conf <<EOF
interface=wlan0
driver=nl80211
ctrl_interface=/run/hostapd-wlan
logger_stdout=-1
logger_stdout_level=1
ssid=Lab-Enterprise
hw_mode=g
channel=6
country_code=IT
ieee80211d=1
wpa=2
wpa_key_mgmt=$K
rsn_pairwise=CCMP
ieee80211w=$P
ieee8021x=1
eap_server=1
eap_user_file=$L/eap_users
ca_cert=$L/pki/ca.crt
server_cert=$L/pki/$S.crt
private_key=$L/pki/$S.key
EOF
    echo "$(ts) ----- hostapd wlan $S key_mgmt=$K ieee80211w=$P" >> $O/hostapd-wlan.log
    hostapd -t /tmp/hostapd-wlan.conf >> $O/hostapd-wlan.log 2>&1 &
    pgrep -f 'dnsmasq --interface=wlan0' >/dev/null || dnsmasq --interface=wlan0 --bind-interfaces --port=0 \
      --dhcp-range=10.78.0.100,10.78.0.150,255.255.255.0,10m --dhcp-leasefile=/tmp/leases-wlan --log-dhcp \
      --log-facility=$O/dnsmasq-wlan.log --pid-file=/run/lab-dnsmasq-wlan.pid
    sleep 2; echo "wlan $S $K $P" ;;
esac
