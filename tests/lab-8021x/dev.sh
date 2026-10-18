#!/bin/bash
# Helpers inside the thin client of the lab (d1x-dev)
#   dev.sh set KEY=value...   the settings dialog would: save-config.sh with these lines (then apply.sh now)
#   dev.sh show               802.1X state, address, last events
#   dev.sh mark TEXT          a line in the event log, to find each test
O=/opt/openthinrdp
case "$1" in
  set) shift; printf '%s\n' "$@" > /tmp/set.conf; $O/save-config.sh /tmp/set.conf; echo "save rc=$?"; rm -f /tmp/set.conf ;;
  show)
    echo "DOT1X=$($O/dot1x.sh status)"
    echo "ADDR=$(ip -4 -o addr show dev eth0 | awk '{print $4}')"
    tail -n "${2:-6}" /var/log/openthinrdp/events.log ;;
  mark) echo "$(date '+%Y-%m-%d %H:%M:%S') ===== $2" >> /var/log/openthinrdp/events.log ;;
esac
