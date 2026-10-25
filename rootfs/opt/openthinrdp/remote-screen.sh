#!/bin/bash
# Remote screen (manager > Remote screen), run as root over SSH by an administrator (otradmin): the screen of the
# device in the administrator's browser, reachable only through the SSH tunnel. Nothing listens on the network.
#   start   x11vnc on the X display (127.0.0.1:5900, one-time password) and the noVNC viewer with its WebSocket
#           bridge (127.0.0.1:6080, vncbridge.py), in the unit otr-remote-screen; prints PORT=6080 and PASSWORD=...
#           Stops by itself after 2 hours. While it is on, the screen says so and the event log records it.
#           REMOTE_CONSENT=ask: first a question on the screen; without a yes within a minute, ERROR=REFUSED.
#   stop    off
#   status  on or off
#   run     what the unit runs; cleanup  what systemd runs after it
. /opt/openthinrdp/lib/common.sh
otr_lang
U=otr-remote-screen
ON=/run/openthinrdp-remote-screen          # exists while on: the notice on the screen stays while it is there
RD=/run/openthinrdp-rs                   # the one-time password, owned by the kiosk account that runs x11vnc
PF=$RD/vnc.pass
case "$1" in
  start)
    [ "$(cfg REMOTE_SCREEN)" = off ] && { echo "ERROR=the remote screen is off on this device (REMOTE_SCREEN=off)"; exit 3; }
    command -v x11vnc >/dev/null || { echo "ERROR=x11vnc is not installed (the next update installs it)"; exit 4; }
    pgrep -x Xorg >/dev/null || { echo "ERROR=no screen running"; exit 5; }
    # the user of the device first: no answer, a refusal or a question that could not be shown = no
    if [ "$(cfg REMOTE_CONSENT)" = ask ]; then
      runuser -u "$OTR_KIOSK_USER" -- env DISPLAY=:0 python3 "$OTR/ui.py" ask --heading="$L_REMOTE_ASK_T" --text="$L_REMOTE_ASK" \
        --button="$L_REMOTE_ASK_NO:11" --button="$L_REMOTE_ASK_YES:0" --primary=0 --timeout=60 >/dev/null 2>&1
      a=$?
      [ $a = 0 ] || { ev "remote screen: not allowed by the user of the device ($([ $a = 70 ] && echo 'no answer' || echo 'refused'))"; echo "ERROR=REFUSED"; exit 8; }
      ev "remote screen: allowed by the user of the device"
    fi
    systemctl stop $U.service >/dev/null 2>&1
    # VNC authentication uses 8 characters at most
    PW=$(tr -dc 'A-HJ-NP-Za-km-z2-9' < /dev/urandom | head -c 8)
    rm -rf "$RD"; install -d -m 700 -o "$OTR_KIOSK_USER" "$RD"
    runuser -u "$OTR_KIOSK_USER" -- x11vnc -storepasswd "$PW" "$PF" >/dev/null 2>&1 || { echo "ERROR=password"; exit 6; }
    # systemd cleans up after the unit whatever ends it (stop, the 2 hours, a crash): notice off, password gone, event
    systemd-run --unit=$U --collect -p RuntimeMaxSec=7200 -p ExecStopPost="$0 cleanup" "$0" run >/dev/null 2>&1
    for i in $(seq 1 40); do
      ss -ltnH 2>/dev/null | grep -q '127.0.0.1:6080 ' && ss -ltnH | grep -q '127.0.0.1:5900 ' && break; sleep 0.25
    done
    ss -ltnH | grep -q '127.0.0.1:6080 ' || { echo "ERROR=did not start (journalctl -u $U)"; systemctl stop $U.service >/dev/null 2>&1; exit 7; }
    echo "PORT=6080"; echo "PASSWORD=$PW" ;;
  stop) systemctl stop $U.service >/dev/null 2>&1; echo "STOPPED" ;;
  cleanup) rm -f "$ON"; rm -rf "$RD"; ev "remote screen: stopped" ;;
  status) if systemctl is-active -q $U.service; then echo on; else echo off; fi ;;
  run)
    touch "$ON"
    ev "remote screen: started by an administrator over SSH (stops by itself after 2 hours)"
    stop_all(){ trap - TERM INT EXIT; kill $(jobs -p) 2>/dev/null; exit 0; }     # cleanup: ExecStopPost
    trap stop_all TERM INT EXIT
    runuser -u "$OTR_KIOSK_USER" -- env DISPLAY=:0 python3 "$OTR/ui.py" toast --text="$L_REMOTE_SCREEN_ON" --while-file="$ON" >/dev/null 2>&1 &
    # as the kiosk account that owns the X session (as root the X server refuses its shared memory: BadAccess on
    # MIT-SHM, seen on the QEMU bench), and without root anyway. -forever: the viewer may reconnect; -shared: the
    # user keeps the mouse and keyboard
    runuser -u "$OTR_KIOSK_USER" -- env DISPLAY=:0 x11vnc -localhost -rfbport 5900 -rfbauth "$PF" -forever -shared -noxdamage -quiet >/dev/null 2>&1 &
    XV=$!
    runuser -u "$OTR_KIOSK_USER" -- python3 "$OTR/vncbridge.py" 6080 5900 "$OTR/novnc" >/dev/null 2>&1 &
    BR=$!
    # either of the two ending ends the remote screen (not the notice: X restarting closes it)
    wait -n $XV $BR
    stop_all ;;
  *) echo "usage: $0 start | stop | status"; exit 2 ;;
esac
