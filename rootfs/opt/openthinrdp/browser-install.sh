#!/bin/bash
# The browser chosen (BROWSER, 0.3.0): installed only on the devices that choose it, from its maker's signed repository
# (Firefox ESR from Debian), kept up to date with the security updates (SECURITY_UPDATES: its repository is added to
# the origins of unattended-upgrades). Chromium stays in the image: it is the default, and the fallback while the
# chosen one is not there yet. Runs as root, in the background (browser-policy.sh starts it as a transient unit):
#   browser-install.sh          the browser of the settings installed, the one chosen before removed
#   browser-install.sh status   "<browser>: installed" / "installing" / "failed" / "not available on <architecture>"
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

[ "$1" = status ] && { cat "$ST" 2>/dev/null || echo "chromium: installed"; exit 0; }
exec 9>/run/openthinrdp-browser.lock; flock 9
b=$(cfg BROWSER); [ -n "$b" ] || b=chromium
a=$(otr_arch)
# the browsers of the makers chosen before (not Chromium, not the one chosen now): removed with their repository
for o in firefox brave chrome edge; do
  [ "$o" = "$b" ] && continue
  dpkg -s "$(pkg $o)" >/dev/null 2>&1 && { apt-get purge -y -qq "$(pkg $o)" >/dev/null 2>&1; ev "browser: $o removed"; }
  [ -n "$(list $o)" ] && rm -f "$L/$(list $o).list" "$K/otr-$o".*
done
[ "$b" = chromium ] && { rm -f "$U"; echo "chromium: installed" > "$ST"; exit 0; }
[[ " $(arches "$b") " == *" $a "* ]] || { echo "$b: not available on $a" > "$ST"; ev "browser: $b not available on $a, Chromium used"; exit 1; }
dpkg -s "$(pkg "$b")" >/dev/null 2>&1 && [ -s "$ST" ] && grep -q "^$b: installed" "$ST" && exit 0
echo "$b: installing" > "$ST"; ev "browser: installing $b"
if [ -n "$(repo "$b")" ]; then
  IFS='|' read -r src key ext <<< "$(repo "$b")"
  curl -fsSL --retry 3 "$key" -o "$K/otr-$b.$ext.new" && mv -f "$K/otr-$b.$ext.new" "$K/otr-$b.$ext" || { echo "$b: failed" > "$ST"; ev "browser: the key of $b could not be fetched"; exit 1; }
  echo "deb [arch=$a signed-by=$K/otr-$b.$ext] $src" > "$L/$(list "$b").list"
  # Chrome and Edge rewrite their list from a daily job unless told not to
  printf 'repo_add_once="false"\nrepo_reenable_on_distupgrade="false"\n' > /etc/default/google-chrome
  cp /etc/default/google-chrome /etc/default/microsoft-edge
  printf 'Unattended-Upgrade::Origins-Pattern {\n        "site=%s";\n};\n' "$(echo "$src" | sed -E 's#^https://([^/]+).*#\1#')" > "$U"
else rm -f "$U"; fi
if apt-get update -qq >/dev/null 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$(pkg "$b")" >/dev/null 2>&1; then
  echo "$b: installed" > "$ST"; ev "browser: $b installed"
  "$OTR/browser-policy.sh" nostart
else echo "$b: failed" > "$ST"; ev "browser: installing $b failed, Chromium used"; exit 1; fi
