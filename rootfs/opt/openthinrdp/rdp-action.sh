#!/bin/bash
# FreeRDP's action script (/action-script, kiosk.sh, only with SESSION_CLOSE_KEY): the key combination chosen for the
# site closes the session, as a disconnect from Windows. Runs as the kiosk user, started by FreeRDP:
#   rdp-action.sh key          the combinations FreeRDP watches, one per line, in its own form (lower case, the
#                              modifiers in the order shift, ctrl, alt, super, then the key: "ctrl+alt+q")
#   rdp-action.sh key COMBO    one of them pressed: "key-local" = the keys are not sent to Windows; the flag tells
#                              kiosk.sh that FreeRDP ended because of it (not a drop: no reconnection)
#   rdp-action.sh xevent       the X events FreeRDP may report: none
. /opt/openthinrdp/lib/common.sh
K=$(cfg SESSION_CLOSE_KEY)
case "$1" in
  key)
    [ -n "$K" ] || exit 0
    if [ -z "${2:-}" ]; then echo "$K"
    elif [ "$2" = "$K" ]; then
      : > /tmp/kiosk.userclose
      echo key-local
      # FreeRDP waits for this script: it ends right after, not under it
      ( sleep 0.3; pkill -TERM -u "$(id -u)" -x xfreerdp3 ) >/dev/null 2>&1 &
    fi ;;
esac
exit 0
