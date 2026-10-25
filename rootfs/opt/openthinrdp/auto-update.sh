#!/bin/bash
# Signed software updates, from GitHub or from the management folder (UPDATE_FROM=github|share|off).
#   LATEST.txt       version=<version> / file=<package>.tar.gz / sha256=<hash>
#   LATEST.txt.sig   detached OpenPGP signature of LATEST.txt
#   <package>.tar.gz contains install.sh (+ files and .deb packages); management/publish/make-update.sh builds it
# Signatures accepted:
#   github  only the project key, /opt/openthinrdp/keys/openthinrdp-release.asc (in the image and the updates)
#   share   the project key (a release copied into the folder by the manager) or the key of the site,
#           /etc/openthinrdp/update-key.asc (your own packages, built into your image or brought by an update);
#           with UPDATE_KEY=site only the key of the site, once the device has one (the manager re-signs the
#           releases with it), else still the project key: a device is never left without updates
# "check <mounted folder>": run by report.sh every 5 minutes and at boot, with the folder mounted.
# "check-github": run by report.sh too, but asks GitHub at most every 3 hours (UPDATE_GITHUB = owner/repository,
# the latest release that is not a pre-release).
# A new version is downloaded, its hash checked, and installed in the background ("install <version>", unit
# openthinrdp-update). Never an older version than the installed one; at most 3 attempts per version.
# UPDATE_TO=<version> instead of latest: exactly that version, also an older one (going back: "install <version>
# downgrade" puts back the FreeRDP of that package too), and nothing newer until the setting changes. Its index is
# updates\versions\<version>.txt in the folder (the manager writes one for every version it publishes) or
# LATEST.txt of the release v<version> on GitHub, signed as LATEST.txt is.
. /opt/openthinrdp/lib/common.sh
PROJECT_KEY=$OTR/keys/openthinrdp-release.asc
SITE_KEY=$OTR_ETC/update-key.asc
W=$OTR_LIB/update
ST=$W/status
# a device without a management folder asks before installing (kiosk.sh update_question): "<new> <current> [<major>]"
OFFER=/run/openthinrdp-update-offer
mkdir -p $W; chmod 700 $W
# an update job of the manager (schedule.sh) asks now: no 3-hour pause, no UPDATE_HOURS, for one hour
[ -n "$(find /run/openthinrdp-update-now -mmin -60 2>/dev/null)" ] && OTR_UPDATE_NOW=1

if [ "$1" = install ]; then
  V=$2; P=$W/pkg-$V; L=$OTR_LOG/update-$V.log
  [ -f "$P/install.sh" ] || { echo "ERROR $V: package not found" > $ST; exit 1; }
  echo "installing: $V (since $(date '+%d/%m %H:%M'))" > $ST
  ev "software update $V: installing"
  echo "2 $V" > /run/openthinrdp-update-progress   # percent and version, for the screens (ui.py)
  : > "$L"
  # Going back: install.sh installs a .deb only when it is newer than the installed one, and the install.sh of an
  # older package knows nothing of going back. So the FreeRDP of that version is put back here first (the reason to go
  # back is often FreeRDP itself), unless FreeRDP is pinned on this device.
  # (the packages of this device's architecture only: lib/common.sh pkg_debs)
  if [ "$3" = downgrade ] && [ -n "$(pkg_debs "$P")" ]; then
    DG=()
    for d in $(pkg_debs "$P"); do
      n=$(dpkg-deb -f "$d" Package); v=$(dpkg-deb -f "$d" Version)
      [[ $n == *freerdp* || $n == *winpr* ]] && [ -f $OTR_ETC/freerdp-pinned ] && continue
      [ "$(dpkg-query -W -f '${Version}' "$n" 2>/dev/null)" = "$v" ] || DG+=("$d")
    done
    if [ ${#DG[@]} -gt 0 ]; then
      echo "going back: ${DG[*]##*/}" >> "$L"
      DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y -q --allow-downgrades "${DG[@]}" >> "$L" 2>&1 \
        || { echo "ERROR $V: putting back its packages failed (log $L)" > $ST; ev "software update $V FAILED: putting back its packages"; rm -f /run/openthinrdp-update-progress; exit 1; }
    fi
  fi
  ( cd "$P" && timeout 1800 bash ./install.sh ) >> "$L" 2>&1; rc=$?
  rm -f /run/openthinrdp-update-progress
  if [ $rc = 0 ]; then
    echo "$V" > "$OTR_LIB/update-version"
    echo "up to date: $V ($(date '+%d/%m %H:%M'))" > $ST
    ev "software update $V installed"
    rm -rf "$P" "$W"/*.tar.gz "$W"/attempts-*
  else
    echo "ERROR $V: install failed (code $rc, attempt $(cat "$W/attempts-$V" 2>/dev/null)/3, log $L)" > $ST
    ev "software update $V FAILED (code $rc): $(grep -v '^$' "$L" | tail -1 | cut -c1-150)"
  fi
  # Shut down was pressed during the install (kiosk.sh waits for it): switch off now that it is recorded
  # (the file says poweroff or reboot)
  if [ -f /tmp/openthinrdp-poweroff-pending ]; then
    a=$(cat /tmp/openthinrdp-poweroff-pending); [ "$a" = reboot ] || a=poweroff
    ev "$a after the software update"; systemctl --no-block "$a"
  fi
  exit $rc
fi

# get NAME DEST: one file of the update source (management folder or GitHub release)
get(){
  if [ "$SRC" = share ]; then cp "$D/$1" "$2" 2>/dev/null
  else
    # python3 is in the image, curl is not; GitHub answers with a redirect, which urllib follows.
    # Exit 3 = the server answered with an error (e.g. 404, no release yet), 1 = no answer at all
    python3 - "$BASE/$1" "$2" <<'PY' 2>/dev/null
import sys, urllib.request, urllib.error
try:
    with urllib.request.urlopen(sys.argv[1], timeout=60) as r, open(sys.argv[2], "wb") as f:
        while True:
            b = r.read(1 << 16)
            if not b: break
            f.write(b)
except urllib.error.HTTPError:
    sys.exit(3)
except Exception:
    sys.exit(1)
PY
  fi
}
# verify SIG FILE: sqv ships with Debian 13 (apt uses it); gpgv only if sqv is missing
verify(){
  local k a=()
  for k in "${KEYS[@]}"; do [ -s "$k" ] && a+=(--keyring "$k"); done
  [ ${#a[@]} -gt 0 ] || return 1
  if command -v sqv >/dev/null; then sqv "${a[@]}" "$1" "$2" >/dev/null 2>&1
  elif command -v gpgv >/dev/null; then gpgv "${a[@]}" "$1" "$2" >/dev/null 2>&1; else return 1; fi
}

# vle A B: version A is not newer than B (sort -V)
vle(){ [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]; }
# notes FROM TO: the changes of the versions after FROM up to TO, from the CHANGELOG.md of the package, as plain text
# (the update question shows them)
notes(){
  local l v keep=0
  while IFS= read -r l; do
    if [[ $l == "## "* ]]; then v=${l#\#\# }; v=${v%% *}; keep=0; ! vle "$v" "$1" && vle "$v" "$2" && keep=1; fi
    [ $keep = 1 ] && printf '%s\n' "$l"
  done < "$W/pkg-$V/CHANGELOG.md" | sed 's/\*\*//g; s/`//g; s/^## //'
}
# UPDATE_TO: latest, or the one version to have. Going back below the first version that knows this setting would
# bring back an updater that ignores it and goes straight up again: refused.
MIN_TO=0.2.0
TO=$(cfg UPDATE_TO); [ -z "$TO" ] && TO=latest
IDX=LATEST.txt
if [ "$TO" != latest ]; then
  [[ $TO =~ ^[0-9A-Za-z._-]+$ ]] || { echo "IGNORED: UPDATE_TO=$TO is not a version" > $ST; exit 0; }
  [ "$(printf '%s\n%s\n' "$TO" "$MIN_TO" | sort -V | head -1)" = "$MIN_TO" ] || {
    echo "IGNORED: UPDATE_TO=$TO, going back is possible to $MIN_TO or later" > $ST; exit 0; }
fi
case "$1" in
  check)
    SRC=share; D="$2/updates"; KEYS=("$PROJECT_KEY" "$SITE_KEY")
    [ "$(cfg UPDATE_KEY)" = site ] && [ -s "$SITE_KEY" ] && KEYS=("$SITE_KEY")
    [ "$TO" != latest ] && IDX=versions/$TO.txt
    [ -f "$D/$IDX" ] || { if [ "$TO" = latest ]; then echo "no update published in the management folder" > $ST
      else echo "UPDATE_TO=$TO: this version is not in the management folder (updates\\versions)" > $ST; fi; exit 0; } ;;
  check-github)
    SRC=github; KEYS=("$PROJECT_KEY")
    REPO=$(cfg UPDATE_GITHUB)
    if [ "$TO" = latest ]; then BASE=${OTR_UPDATE_BASE_URL:-https://github.com/$REPO/releases/latest/download}
    else BASE=$(printf "${OTR_UPDATE_TAG_URL:-https://github.com/$REPO/releases/download/v%s}" "$TO"); fi
    # at most every 3 hours once GitHub answered (report.sh runs every 5 minutes: without network, e.g. right
    # after boot, it simply tries again at the next run); a changed UPDATE_TO is asked at once
    # (an open offer is not held back: the answer from the device is waited for)
    # (OTR_UPDATE_NOW: a scheduled job of the manager asks now)
    [ -z "$OTR_UPDATE_NOW" ] && [ -f $W/github-checked ] && [ "$(cat $W/github-checked)" = "$TO" ] && [ ! -f $OFFER ] && [ $(( $(date +%s) - $(stat -c %Y $W/github-checked) )) -lt 10800 ] && exit 0 ;;
  *) echo "usage: $0 check <mounted folder> | check-github | install <version> [downgrade]"; exit 2 ;;
esac
[ -s "${KEYS[0]}" ] || [ -s "${KEYS[1]:-}" ] || { echo "updates disabled: no signing key" > $ST; exit 0; }
systemctl is-active -q openthinrdp-update.service 2>/dev/null && exit 0      # an install is already running
rm -f $W/LATEST.txt $W/LATEST.txt.sig
get "$IDX" $W/LATEST.txt; rc=$?
# GitHub answered (also "no release yet"): next question in 3 hours. No answer: at the next run
[ $SRC = github ] && { [ $rc = 0 ] || [ $rc = 3 ]; } && echo "$TO" > $W/github-checked
# the kiosk waits for this at the first start (an answer, whatever it is)
{ [ $rc = 0 ] || [ $rc = 3 ]; } && touch /run/openthinrdp-update-checked
if [ $rc != 0 ]; then
  echo "no update found ($SRC$([ $SRC = github ] && echo " $REPO$([ $rc = 1 ] && echo ', not reachable')"), $(date '+%d/%m %H:%M'))" > $ST; exit 0; fi
get "$IDX.sig" $W/LATEST.txt.sig || : > $W/LATEST.txt.sig
if ! verify $W/LATEST.txt.sig $W/LATEST.txt; then
  S=$(md5sum < $W/LATEST.txt | cut -c1-32)
  [ "$(cat $W/bad-signature 2>/dev/null)" = "$S" ] || { ev "update from $SRC with an INVALID signature: ignored"; echo "$S" > $W/bad-signature; }
  echo "IGNORED: invalid signature on LATEST.txt ($SRC)" > $ST; exit 0
fi
V=$(sed -n 's/^version=//p' $W/LATEST.txt | tr -d '\r' | head -1)
F=$(sed -n 's/^file=//p' $W/LATEST.txt | tr -d '\r' | head -1)
H=$(sed -n 's/^sha256=//p' $W/LATEST.txt | tr -d '\r' | head -1)
{ [[ $V =~ ^[0-9A-Za-z._-]+$ ]] && [[ $F =~ ^[0-9A-Za-z._-]+\.tar\.gz$ ]] && [[ $H =~ ^[0-9a-f]{64}$ ]]; } || { echo "IGNORED: LATEST.txt not valid" > $ST; exit 0; }
[ "$TO" != latest ] && [ "$V" != "$TO" ] && { echo "IGNORED: UPDATE_TO=$TO but the index found is for $V ($SRC)" > $ST; exit 0; }
PIN=""; [ "$TO" != latest ] && PIN=", UPDATE_TO=$TO"
# the version installed: the last update, or the image itself when no update was ever installed
CUR=$(cat "$OTR_LIB/update-version" 2>/dev/null || cat "$OTR/VERSION" 2>/dev/null)
[ "$V" = "$CUR" ] && { rm -f $OFFER; echo "up to date: $V ($SRC$PIN, $(date '+%d/%m %H:%M'))" > $ST; exit 0; }
DOWN=""
if [ -n "$CUR" ] && [ "$(printf '%s\n%s\n' "$CUR" "$V" | sort -V | tail -1)" = "$CUR" ]; then
  # older than the installed one: only when asked for by UPDATE_TO
  [ "$TO" = latest ] && { rm -f $OFFER; echo "up to date: $CUR ($SRC has $V, older: ignored)" > $ST; exit 0; }
  DOWN=downgrade
fi
N=$(cat "$W/attempts-$V" 2>/dev/null || echo 0)
[ "$N" -ge 3 ] && { echo "ERROR $V: 3 failed attempts, not retrying (log $OTR_LOG/update-$V.log)" > $ST; exit 0; }
# at least 10 minutes between attempts: every event line starts report.sh, and without this pause the 3
# attempts burned out in seconds (e.g. on a freshly installed device with apt busy)
if [ "$N" -ge 1 ] && [ $(( $(date +%s) - $(stat -c %Y "$W/attempts-$V" 2>/dev/null || echo 0) )) -lt 600 ]; then exit 0; fi
# already here and whole (downloaded while waiting for the choice on the device): not again
if [ ! -f "$W/$F" ] || [ "$(sha256sum < "$W/$F" | cut -c1-64)" != "$H" ]; then
  get "$F" "$W/$F.part" || { rm -f "$W/$F.part"; echo "ERROR $V: download of $F failed ($SRC)" > $ST; exit 0; }
  if [ "$(sha256sum < "$W/$F.part" | cut -c1-64)" != "$H" ]; then
    rm -f "$W/$F.part"; echo "ERROR $V: package hash differs from LATEST.txt (incomplete copy?)" > $ST; exit 0; fi
  mv -f "$W/$F.part" "$W/$F"
fi
rm -rf "$W/pkg-$V"; mkdir -p "$W/pkg-$V"
tar -xzf "$W/$F" -C "$W/pkg-$V" || { echo "ERROR $V: package cannot be extracted" > $ST; exit 0; }
# Major updates (a change to how a session connects or runs): LATEST.txt, signed, names the newest one in major=.
# Going from below it to it or past it crosses it. Never by itself: through the manager, or asked on the device.
MAJ=$(sed -n 's/^major=//p' $W/LATEST.txt | tr -d '\r' | head -1); [[ $MAJ =~ ^[0-9A-Za-z._-]+$ ]] || MAJ=""
CROSS=""; [ -n "$MAJ" ] && [ -z "$DOWN" ] && ! vle "$MAJ" "$CUR" && vle "$MAJ" "$V" && CROSS=$MAJ
if [ -s "$OTR_LIB/central-common.conf" ]; then
  # Managed (central settings from a management folder): updates as the site says, no question on the device. A
  # major one only once the manager released it to this device: UPDATE_MAJOR (written by the manager after its
  # second confirmation, in common.conf or in the file of a group) at that major version or later.
  if [ -n "$CROSS" ] && ! { [ -n "$(cfg UPDATE_MAJOR)" ] && vle "$CROSS" "$(cfg UPDATE_MAJOR)"; }; then
    rm -f $OFFER; echo "found $V ($SRC): major update ($CROSS), installed once it is released from the manager" > $ST; exit 0
  fi
else
  # No management folder (the live system from the USB stick, an image of its own with site.conf only): nobody
  # else decides, so every new version is asked on the device, at the sign-in screen, with its changes
  # (kiosk.sh update_question). A normal update installs after 30 s without an answer, a major one only with a yes;
  # "not now" lasts until the next start.
  if [ "$(cat /tmp/openthinrdp-update-accepted 2>/dev/null)" != "$V" ]; then
    [ -f /tmp/openthinrdp-update-declined ] && { rm -f $OFFER; echo "kept $CUR by choice on the device ($V available, $SRC), asked again at the next start" > $ST; exit 0; }
    notes "$CUR" "$V" > /run/openthinrdp-update-notes 2>/dev/null; chmod 644 /run/openthinrdp-update-notes
    printf '%s %s %s\n' "$V" "$CUR" "$CROSS" > $OFFER.new; chmod 644 $OFFER.new
    cmp -s $OFFER.new $OFFER && rm -f $OFFER.new || mv -f $OFFER.new $OFFER
    echo "found $V ($SRC): asked on the device at the sign-in$([ -n "$CROSS" ] && echo ", major update")" > $ST; exit 0
  fi
fi
# UPDATE_HOURS = the hours an update may install in (02-05, also across midnight: 22-06), managed devices only; the
# package is already here, it installs at the first report inside them (or at once with a scheduled update job)
UH=$(cfg UPDATE_HOURS)
if [ -s "$OTR_LIB/central-common.conf" ] && [ -z "$OTR_UPDATE_NOW" ] && [[ $UH =~ ^([0-9]{1,2})-([0-9]{1,2})$ ]]; then
  a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]})); h=$((10#$(date +%H)))
  if { [ $a -le $b ] && { [ $h -lt $a ] || [ $h -ge $b ]; }; } || { [ $a -gt $b ] && [ $h -lt $a ] && [ $h -ge $b ]; }; then
    echo "found $V ($SRC$PIN): installs between $a:00 and $b:00 (UPDATE_HOURS)" > $ST; exit 0
  fi
fi
rm -f $OFFER /run/openthinrdp-update-now
echo $((N + 1)) > "$W/attempts-$V"
if [ -n "$DOWN" ]; then echo "found $V ($SRC$PIN): going back from $CUR, install started" > $ST; ev "software update: going back from $CUR to $V (UPDATE_TO)"
else echo "found $V ($SRC$PIN): install started" > $ST; fi
systemd-run --unit=openthinrdp-update --collect --no-block --property=Nice=10 "$OTR/auto-update.sh" install "$V" $DOWN >/dev/null 2>&1
exit 0
