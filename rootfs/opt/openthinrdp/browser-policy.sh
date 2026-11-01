#!/bin/bash
# Browser policies from the settings (root: from save-config.sh, at build time, and after browser-install.sh).
#   WEB_BUTTON=app      only WEB_URL and the sites in WEB_ALLOW can be opened
#   browser, kiosk      free browsing (a kiosk page may load other sites)
# Always: no sign-in, no sync, no extensions, no downloads, no developer tools, no guest or private windows.
# The same rules for every browser that can be chosen (BROWSER): Chromium, Brave, Chrome and Edge read the same
# JSON, each from its own folder; Firefox ESR has its own format. The URLs are validated by save-config.sh (no quotes
# or backslashes), so they can go into JSON as they are.
#   browser-policy.sh           the policies, and the browser chosen installed in the background (browser-install.sh)
#   browser-policy.sh nostart   the policies only
. /opt/openthinrdp/lib/common.sh
origin(){ echo "$1" | sed -E 's#^(https?://[^/]+).*#\1#'; }
APP=0; [ "$(cfg WEB_BUTTON)" = app ] && [ -n "$(cfg WEB_URL)" ] && APP=1
# put FILE: written only when it changed
put(){ mkdir -p "$(dirname "$1")"
  if cmp -s "$1.new" "$1"; then rm -f "$1.new"; else chmod 644 "$1.new"; mv -f "$1.new" "$1"; fi; }
{
  echo '{'
  if [ $APP = 1 ]; then
    echo '  "URLBlocklist": ["*"],'
    printf '  "URLAllowlist": ["%s"' "$(origin "$(cfg WEB_URL)")"
    for u in $(cfg WEB_ALLOW); do printf ', "%s"' "$u"; done
    echo ', "chrome://print"],'
  fi
  [ -n "$(cfg WEB_URL)" ] && printf '  "HomepageLocation": "%s",\n  "HomepageIsNewTabPage": false,\n' "$(cfg WEB_URL)"
  cat <<'J'
  "BrowserSignin": 0,
  "SyncDisabled": true,
  "BrowserGuestModeEnabled": false,
  "BrowserAddPersonEnabled": false,
  "IncognitoModeAvailability": 1,
  "DeveloperToolsAvailability": 2,
  "DownloadRestrictions": 3,
  "ExtensionInstallBlocklist": ["*"],
  "PasswordManagerEnabled": true,
  "DefaultBrowserSettingEnabled": false,
  "MetricsReportingEnabled": false,
  "PromotionalTabsEnabled": false,
  "TranslateEnabled": false,
  "BackgroundModeEnabled": false,
  "AutoplayAllowed": false,
  "BraveRewardsDisabled": true,
  "BraveWalletDisabled": true,
  "BraveVPNDisabled": true,
  "BraveAIChatEnabled": false,
  "HideFirstRunExperience": true,
  "EdgeCollectionsEnabled": false,
  "ShowRecommendationsEnabled": false
}
J
} > /tmp/otr-policy.json
for d in /etc/chromium/policies/managed /etc/brave/policies/managed /etc/opt/chrome/policies/managed /etc/opt/edge/policies/managed; do
  mkdir -p "$d"; cp /tmp/otr-policy.json "$d/openthinrdp.json.new"; put "$d/openthinrdp.json"
done
rm -f /tmp/otr-policy.json
# Firefox ESR (Debian reads /etc/firefox/policies): the same rules in its words, the certificate authorities of the
# organization too (Chromium takes them from NSS, browser.sh)
F=/etc/firefox/policies/policies.json; mkdir -p "$(dirname "$F")"
{
  echo '{ "policies": {'
  if [ $APP = 1 ]; then
    printf '  "WebsiteFilter": { "Block": ["<all_urls>"], "Exceptions": ["%s/*"' "$(origin "$(cfg WEB_URL)")"
    for u in $(cfg WEB_ALLOW); do printf ', "%s*"' "$u"; done
    echo '] },'
  fi
  [ -n "$(cfg WEB_URL)" ] && printf '  "Homepage": { "URL": "%s", "StartPage": "homepage", "Locked": true },\n' "$(cfg WEB_URL)"
  c=""; for f in "$OTR_ETC"/ca/*.crt; do [ -f "$f" ] && c+="${c:+, }\"$f\""; done
  [ -n "$c" ] && printf '  "Certificates": { "Install": [%s] },\n' "$c"
  cat <<'J'
  "DisableFirefoxAccounts": true,
  "DisableDeveloperTools": true,
  "DisablePrivateBrowsing": true,
  "DisableTelemetry": true,
  "DisableFirefoxStudies": true,
  "DisablePocket": true,
  "DontCheckDefaultBrowser": true,
  "OverrideFirstRunPage": "",
  "OverridePostUpdatePage": "",
  "ExtensionSettings": { "*": { "installation_mode": "blocked" } },
  "PasswordManagerEnabled": true
} }
J
} > "$F.new"; put "$F"
# the browser of this device in the background (it can take minutes): the one chosen, only with a web page in the
# settings; none at all without one (browser-install.sh)
W=none; web_used && { W=$(cfg BROWSER); [ -n "$W" ] || W=chromium; }
S=$(cat "$OTR_LIB/browser-state" 2>/dev/null)
if [ "$1" != nostart ] && [ "$S" != "$W: installed" ] && ! { [ "$W" = none ] && [ "${S%%:*}" = none ]; }; then
  # a device that never had a browser and needs none: nothing to do
  [ "$W" = none ] && [ -z "$S" ] && ! dpkg -s chromium >/dev/null 2>&1 || \
    systemd-run --quiet --collect --unit=openthinrdp-browser-install "$OTR/browser-install.sh" >/dev/null 2>&1
fi
exit 0
