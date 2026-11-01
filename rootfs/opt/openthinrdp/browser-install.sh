#!/bin/bash
# The browser chosen (BROWSER, 0.3.0): installed only on the devices that choose it, from its maker's signed repository
# (Firefox ESR from Debian), kept up to date with the security updates (SECURITY_UPDATES: its repository is added to
# the origins of unattended-upgrades). Only the browser chosen is on a device: no browser is in the image (0.3.1),
# Chromium (the default) is installed when a page first needs it, and removed once another browser is in. Runs as
# root, in the background (browser-policy.sh starts it as a transient unit):
#   browser-install.sh          the browser of the settings installed, the one chosen before removed
#   browser-install.sh status   "<browser>: installed" / "installing" / "failed" / "not available on <architecture>",
#                               "none: ..." without a web page
. /opt/openthinrdp/lib/common.sh
ST=$OTR_LIB/browser-state
K=/usr/share/keyrings; L=/etc/apt/sources.list.d; U=/etc/apt/apt.conf.d/53openthinrdp-browser
# browser -> package, binary, repository (empty: Debian), key URL, architectures
pkg(){ case "$1" in firefox) echo firefox-esr ;; brave) echo brave-browser ;; chrome) echo google-chrome-stable ;; edge) echo microsoft-edge-stable ;; esac; }
arches(){ case "$1" in chrome|edge) echo amd64 ;; *) echo "amd64 arm64" ;; esac; }
repo(){ case "$1" in
  brave)  echo "https://brave-browser-apt-release.s3.brave.com/ stable main|https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg|gpg" ;;
  chrome) echo "https://dl.google.com/linux/chrome/deb/ stable main|https://dl.google.com/linux/linux_signing_key.pub|asc" ;;
  edge)   echo "https://packages.microsoft.com/repos/edge stable main|https://packages.microsoft.com/keys/microsoft.asc|asc" ;;
esac; }
# the names the makers' own packages use for their list: theirs is not added twice (and their cron jobs that
# rewrite it are switched off below)
list(){ case "$1" in brave) echo brave-browser-release ;; chrome) echo google-chrome ;; edge) echo microsoft-edge ;; esac; }

[ "$1" = status ] && { cat "$ST" 2>/dev/null || echo "none: no browser (no web page in the settings)"; exit 0; }
exec 9>/run/openthinrdp-browser.lock; flock 9
# no web page in the settings (web button, kiosk page): no browser at all on the device
b=$(cfg BROWSER); [ -n "$b" ] || b=chromium; web_used || b=none
purge_chromium(){ local c; c=$(dpkg-query -W -f='${Package} ${Status}\n' 'chromium*' 2>/dev/null | awk '/ installed$/ {print $1}')
  [ -n "$c" ] && DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq $c >/dev/null 2>&1 && ev "browser: Chromium removed ($1)"; }
a=$(otr_arch)
# the browsers of the makers not chosen (all of them without a web page): removed with their repository
for o in firefox brave chrome edge; do
  [ "$o" = "$b" ] && continue
  # Brave brings its key as a package of its own (brave-keyring): it goes with it
  dpkg -s "$(pkg $o)" >/dev/null 2>&1 && { apt-get purge -y -qq "$(pkg $o)" $([ $o = brave ] && dpkg -s brave-keyring >/dev/null 2>&1 && echo brave-keyring) >/dev/null 2>&1; ev "browser: $o removed"; }
  [ -n "$(list $o)" ] && rm -f "$L/$(list $o).list" "$K/otr-$o".*
done
if [ "$b" = none ]; then
  rm -f "$U"; purge_chromium "no web page in the settings"
  echo "none: no browser (no web page in the settings)" > "$ST"; exit 0
fi
if [ "$b" = chromium ]; then
  rm -f "$U"
  "$OTR/need.sh" chromium && echo "chromium: installed" > "$ST" || { echo "chromium: failed" > "$ST"; exit 1; }
  exit 0
fi
[[ " $(arches "$b") " == *" $a "* ]] || { echo "$b: not available on $a" > "$ST"; ev "browser: $b not available on $a"; exit 1; }
dpkg -s "$(pkg "$b")" >/dev/null 2>&1 && [ -s "$ST" ] && grep -q "^$b: installed" "$ST" && exit 0
echo "$b: installing" > "$ST"; ev "browser: installing $b"
if [ -n "$(repo "$b")" ]; then
  IFS='|' read -r src key ext <<< "$(repo "$b")"
  python3 -c "import sys, urllib.request; urllib.request.urlretrieve(sys.argv[1], sys.argv[2])" "$key" "$K/otr-$b.$ext.new" 2>/dev/null && mv -f "$K/otr-$b.$ext.new" "$K/otr-$b.$ext" || { echo "$b: failed" > "$ST"; ev "browser: the key of $b could not be fetched"; exit 1; }
  echo "deb [arch=$a signed-by=$K/otr-$b.$ext] $src" > "$L/$(list "$b").list"
  # Chrome and Edge rewrite their list from a daily job unless told not to
  printf 'repo_add_once="false"\nrepo_reenable_on_distupgrade="false"\n' > /etc/default/google-chrome
  cp /etc/default/google-chrome /etc/default/microsoft-edge
  printf 'Unattended-Upgrade::Origins-Pattern {\n        "site=%s";\n};\n' "$(echo "$src" | sed -E 's#^https://([^/]+).*#\1#')" > "$U"
else rm -f "$U"; fi
if apt-get update -qq >/dev/null 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$(pkg "$b")" >/dev/null 2>&1; then
  echo "$b: installed" > "$ST"; ev "browser: $b installed"
  # Chromium is of no use any more: another browser is the one of this device
  purge_chromium "$b chosen"
  "$OTR/browser-policy.sh" nostart
else echo "$b: failed" > "$ST"; ev "browser: installing $b failed (no Internet?), tried again at the next start"; exit 1; fi
