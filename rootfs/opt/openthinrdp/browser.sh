#!/bin/bash
# Web button of the login form and kiosk page, with Chromium. Runs as the kiosk user.
#   browser.sh              WEB_BUTTON=app: WEB_URL as an app window (only the allowed sites, see browser-policy.sh)
#                           WEB_BUTTON=browser: free browsing, WEB_URL as home page
#   browser.sh kiosk <url>  the kiosk page full screen (WEB_BUTTON=kiosk)
# Closing the window goes back to the login form. Fixed profiles: cookies and saved passwords stay.
. /opt/openthinrdp/lib/common.sh
otr_lang
export DISPLAY=${DISPLAY:-:0}
# the browser chosen (BROWSER, browser-install.sh); Chromium while it is not installed (yet)
FF=0
case "$(cfg BROWSER)" in
  firefox) B=$(command -v firefox-esr) && FF=1 ;;
  brave)   B=$(command -v brave-browser) ;;
  chrome)  B=$(command -v google-chrome-stable) ;;
  edge)    B=$(command -v microsoft-edge-stable) ;;
  *)       B="" ;;
esac
[ -n "$B" ] || B=$(command -v chromium || command -v chromium-browser || command -v google-chrome)
[ -z "$B" ] && { yad --error --center --timeout=5 --text="$L_NO_BROWSER" 2>/dev/null; exit 1; }
FLAGS=(--no-first-run --no-default-browser-check --password-store=basic --disable-features=Translate,MediaRouter)
# Firefox: its own profile folder and options; the rules are its policies (browser-policy.sh)
ff(){ local p=$1; shift; mkdir -p "$p"; "$B" --no-remote --profile "$p" "$@" >/dev/null 2>&1; }

# Certificate authorities of the organization ($OTR_ETC/ca/*.crt, built into the image) in the NSS database
# that Chromium uses on Linux: the thin client is not in the domain and would show "connection not private"
if ls "$OTR_ETC"/ca/*.crt >/dev/null 2>&1 && command -v certutil >/dev/null; then
  DB="sql:$HOME/.pki/nssdb"; mkdir -p "$HOME/.pki/nssdb"
  [ -f "$HOME/.pki/nssdb/cert9.db" ] || certutil -d "$DB" -N --empty-password 2>/dev/null
  for c in "$OTR_ETC"/ca/*.crt; do
    n="otr-$(basename "$c" .crt)"
    certutil -d "$DB" -L -n "$n" >/dev/null 2>&1 || certutil -d "$DB" -A -t "C,," -n "$n" -i "$c" 2>/dev/null
  done
fi
# after a hard power off Chromium would offer "Restore pages?": mark the profile as closed cleanly
clean_exit(){ sed -i 's/"exit_type":"Crashed"/"exit_type":"Normal"/; s/"exited_cleanly":false/"exited_cleanly":true/' "$1/Default/Preferences" 2>/dev/null; }
stop_profile(){ pkill -f -- "--user-data-dir=$1|--profile $1" 2>/dev/null; sleep 1; pkill -9 -f -- "--user-data-dir=$1|--profile $1" 2>/dev/null; }

if [ "$1" = kiosk ]; then
  # Every 15 s the settings are read again: if WEB_BUTTON or KIOSK_URL change (dialog, central settings) the
  # page closes and the kiosk reopens it with the new values. Ctrl+Shift+W (or a crash) closes it: back to the
  # login form with its 5 s countdown. Reload every KIOSK_RELOAD_MIN minutes if nobody is using it.
  URL="$2"; PROF="$HOME/.config/otr-kiosk"
  stop_profile "$PROF"; clean_exit "$PROF"
  if [ $FF = 1 ]; then ff "$PROF-ff" --class OtrKiosk --kiosk "$URL" &
  else "$B" --user-data-dir="$PROF" --class=OtrKiosk --kiosk "$URL" "${FLAGS[@]}" --noerrdialogs --disable-infobars \
    --disable-session-crashed-bubble --overscroll-history-navigation=0 >/dev/null 2>&1 & fi
  CH=$!; n=0; last=0; REL=$(cfg_num KIOSK_RELOAD_MIN 10)
  while kill -0 $CH 2>/dev/null; do
    sleep 1; n=$((n + 1))
    # reload (F5) to pick up changes of the site or leave an error page, only after 1 minute without input
    # and only if the page is in front (not a dialog, e.g. the scheduled power off warning)
    if [ "$REL" -gt 0 ] && [ $((n - last)) -ge $((REL * 60)) ] && [ $((n % 60)) -eq 0 ] && command -v xdotool >/dev/null && \
       [ "$(xprintidle 2>/dev/null || echo 0)" -ge 60000 ]; then
      W=$(xdotool getactivewindow 2>/dev/null)
      if [ -n "$W" ] && xprop -id "$W" WM_CLASS 2>/dev/null | grep -q OtrKiosk; then xdotool key --clearmodifiers F5; last=$n; fi
    fi
    [ $((n % 15)) -eq 0 ] || continue
    REL=$(cfg_num KIOSK_RELOAD_MIN 10)
    if [ "$(cfg WEB_BUTTON)" != kiosk ] || [ "$(cfg KIOSK_URL)" != "$URL" ]; then ev "kiosk page: settings changed, closed to reopen it"; break; fi
  done
  stop_profile "$PROF"; stop_profile "$PROF-ff"
  exit 0
fi

URL=$(cfg WEB_URL); PROF="$HOME/.config/otr-web"
stop_profile "$PROF"; clean_exit "$PROF"     # a browser left open would take the request and this launch would end at once
if [ $FF = 1 ]; then
  # Firefox has no app window: the page in a full window; in "app" mode its policies allow only the sites set
  ev "$(cfg WEB_BUTTON) opened with Firefox: $URL"; ff "$PROF-ff" --class OtrWeb "$URL"; stop_profile "$PROF-ff"; exit 0
fi
case "$(cfg WEB_BUTTON)" in
  browser) ev "browser opened"; "$B" --user-data-dir="$PROF" --class=OtrWeb "$URL" --start-maximized "${FLAGS[@]}" >/dev/null 2>&1 ;;
  *)       ev "web app opened: $URL"; "$B" --user-data-dir="$PROF" --class=OtrWeb --app="$URL" --start-maximized "${FLAGS[@]}" >/dev/null 2>&1 ;;
esac
# closed: no browser window may stay behind the login form
stop_profile "$PROF"
exit 0
