#!/bin/bash
# At shutdown, before the kiosk stops (openthinrdp-keep-log.service): the log of FreeRDP is in /tmp and would be gone
# at the next start. Its end is kept as last-session.log, with the one of the attempt before.
# A FreeRDP still running here was switched off in a session instead of signing out: often because the session was
# frozen (23/10/2026: the switch was the only way out, and what FreeRDP was doing was lost). Its threads and sockets
# go to session-hang.log first, and the event says so.
. /opt/openthinrdp/lib/common.sh
fp=$(pgrep -x xfreerdp3 | head -1)
if [ -n "$fp" ]; then
  OTR_NO_DIAG=1 hang_report "$fp"
  ev "power off with a session still open (FreeRDP $fp): its threads in session-hang.log, its log in last-session.log"
fi
{
  if [ -s /tmp/kiosk.log.prev ]; then echo "=== the attempt before"; tail -c 300000 /tmp/kiosk.log.prev; fi
  if [ -s /tmp/kiosk.log ]; then echo "=== the last session, until $(date '+%Y-%m-%d %H:%M:%S')"; tail -c 2000000 /tmp/kiosk.log; fi
} > "$OTR_LOG/last-session.log.new" 2>/dev/null
# nothing to keep (no session since the start): the one of before stays
if [ -s "$OTR_LOG/last-session.log.new" ]; then mv -f "$OTR_LOG/last-session.log.new" "$OTR_LOG/last-session.log"
else rm -f "$OTR_LOG/last-session.log.new"; fi
# a session still open at power off: the whole diagnostics, sent to the management folder at the next start
[ -n "$fp" ] && "$OTR/diag-bundle.sh" power-off >/dev/null 2>&1
exit 0
