#!/bin/bash
# hostapd_cli action of the lab "switch": the port opens (DHCP allowed) for an authenticated station, closes again on a
# failure. (A station authenticated again after a link flap gets no second AP-STA-CONNECTED: EAP-SUCCESS counts too.)
case "$2" in
  AP-STA-CONNECTED|CTRL-EVENT-EAP-SUCCESS) nft add element inet lab ok "{ $3 }" ;;
  AP-STA-DISCONNECTED|CTRL-EVENT-EAP-FAILURE) nft delete element inet lab ok "{ $3 }" 2>/dev/null ;;
esac
echo "$(date '+%H:%M:%S.%3N') $2 $3" >> /lab/out/port.log
