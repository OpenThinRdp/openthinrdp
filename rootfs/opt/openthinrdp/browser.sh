#!/bin/bash
# Web button of the login form and kiosk page, with Chromium. Runs as the kiosk user.
#   browser.sh              WEB_BUTTON=app: WEB_URL as an app window (only the allowed sites, see browser-policy.sh)
#                           WEB_BUTTON=browser: free browsing, WEB_URL as home page
#   browser.sh kiosk <url>  the kiosk page full screen (WEB_BUTTON=kiosk)
# Closing the window goes back to the login form. Fixed profiles: cookies and saved passwords stay.
. /opt/openthinrdp/lib/common.sh
otr_lang
export DISPLAY=${DISPLAY:-:0}
# the browser chosen (BROWSER) and only that one: no browser is in the image (0.3.1). Chromium is installed the first
# time a page needs it (need.sh); another browser by browser-install.sh, started as root when the setting is saved or
# at boot: here its install is waited for, with a progress screen, never Chromium instead
b=$(cfg BROWSER); [ -n "$b" ] || b=chromium
bin(){ case "$1" in firefox) command -v firefox-esr ;; brave) command -v brave-browser ;; chrome) command -v google-chrome-stable ;;
  edge) command -v microsoft-edge-stable ;; *) command -v chromium || command -v chromium-browser ;; esac; }
B=$(bin "$b")
if [ -z "$B" ]; then
  { echo 10
    if [ "$b" = chromium ]; then sudo -n "$OTR/need.sh" chromium >/dev/null 2>&1
    else for _ in $(seq 300); do systemctl is-active -q openthinrdp-browser-install || break; sleep 2; done; fi
    echo 100; } |
    python3 "$OTR/ui.py" message --progress --icon=busy --lang="$(cfg LANGUAGE)" --top="$(cfg BG_TOP)" --bottom="$(cfg BG_BOTTOM)" \
      --heading="$L_BROWSER_INSTALL_T" --text="$L_BROWSER_INSTALL" 2>/dev/null
  B=$(bin "$b")
fi
FF=0; [ "$b" = firefox ] && FF=1
[ -z "$B" ] && { python3 "$OTR/ui.py" message --icon=error --lang="$(cfg LANGUAGE)" --heading="$L_NO_BROWSER" --text="$L_BROWSER_INSTALL_FAIL" \
  --timeout=8 2>/dev/null || yad --error --center --timeout=5 --text="$L_NO_BROWSER" 2>/dev/null; exit 1; }
FLAGS=(--no-first-run --no-default-browser-check --password-store=basic --disable-features=Translate,MediaRouter)
# the scale of the screens (DISPLAY_SCALE, from kiosk.sh as OTR_UI_SCALE, #183): Chromium and its kin by option,
# Firefox in its profile (1.0 at 100%: a value once written stays in prefs.js)
S=${OTR_UI_SCALE:-100}; [[ $S =~ ^[0-9]{2,3}$ ]] || S=100
K=$(awk -v s="$S" 'BEGIN { printf "%.2f", s / 100 }')
[ "$S" != 100 ] && FLAGS+=(--force-device-scale-factor="$K")
# the scale of the GTK windows of the kiosk would come on top of it (the text twice as large again)
unset GDK_DPI_SCALE GDK_SCALE
# Firefox: its own profile folder and options; the rules are its policies (browser-policy.sh)
ff(){ local p=$1; shift; mkdir -p "$p"
  { grep -v 'layout.css.devPixelsPerPx' "$p/user.js" 2>/dev/null; printf 'user_pref("layout.css.devPixelsPerPx", "%s");\n' "$([ "$S" = 100 ] && echo -1.0 || echo "$K")"; } > "$p/user.js.new" && mv -f "$p/user.js.new" "$p/user.js"
  "$B" --no-remote --profile "$p" "$@" >/dev/null 2>&1; }

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
