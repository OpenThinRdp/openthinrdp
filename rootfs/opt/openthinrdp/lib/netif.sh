# Network adapters of the thin client. Source it: . /opt/openthinrdp/lib/netif.sh
# Wired: built-in (enp...) and USB adapters (enx...). Wi-Fi: wl... (used only with WIFI=on).
# Main adapter = the first wired one with the cable connected; without cable the Wi-Fi if connected;
# otherwise the first wired one. So a PC with a broken built-in port works with a USB adapter or Wi-Fi.
wired_nics(){ ls /sys/class/net 2>/dev/null | grep -E '^(en|eth)'; }
wifi_nics(){ ls /sys/class/net 2>/dev/null | grep -E '^wl'; }
main_nic(){
  local i
  for i in $(wired_nics); do [ "$(cat "/sys/class/net/$i/carrier" 2>/dev/null)" = 1 ] && { echo "$i"; return; }; done
  for i in $(wifi_nics); do ip -4 -o addr show dev "$i" 2>/dev/null | grep -q inet && { echo "$i"; return; }; done
  { wired_nics; wifi_nics; } | head -1
}
# The adapter the default route goes out of, and its IPv4 with the prefix: when the main adapter has no address
# (a name outside en*/eth*/wl*, a bridge, an adapter that came up after another one), this is where the device
# really is on the network
route_nic(){ ip -4 route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}'; }
nic_ipv4(){ [ -n "$1" ] && ip -4 -o addr show dev "$1" scope global 2>/dev/null | awk '{print $4}' | head -1; }
