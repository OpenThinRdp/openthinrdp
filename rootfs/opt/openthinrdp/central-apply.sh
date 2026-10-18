#!/bin/bash
# Central settings: config\common.conf (every device) and config\<hostname>.conf (one device) in the
# management folder. report.sh copies them to $OTR_LIB; here they are merged over the current settings,
# validated by save-config.sh and applied ONLY when something changes. Folder unreachable = the last
# copies are used (last good configuration).
# The comparison uses save-config.sh --print on both sides: the values are compared in the form they are
# stored in, so "Static" and "static", or "1EAF:0009,x" and "1eaf:0009 x", are not seen as changes (a false
# difference would re-apply everything every 5 minutes).
. /opt/openthinrdp/lib/common.sh
ST=$OTR_LIB/central-status
COMMON=$OTR_LIB/central-common.conf
HOSTF=$OTR_LIB/central-host.conf
# Central values win: a key set centrally is written into the device settings again every time, so a change made
# in the settings dialog lasts only until the next run. A key REMOVED from the central files is removed from the
# device settings too (it goes back to site.conf or the defaults), otherwise devices would keep the last central
# value and quietly differ from the ones installed later.
MANAGED=$OTR_LIB/central-managed
# keys that only the file of a single device may set (they identify the device)
HOST_ONLY="HOSTNAME DEFAULT_USER NETMODE IPADDR VPN_ADDRESS"
KEYS="$(cfg_keys | tr '\n' ' ')WIFI_PSK MGMT_PASSWORD EAP_PASSWORD"
# secrets: compared through their hash (save-config.sh --print), applied with the value of the central file
SECRETS="WIFI_PSK MGMT_PASSWORD EAP_PASSWORD"

[ -f "$COMMON" ] || [ -f "$HOSTF" ] || [ -s "$MANAGED" ] || { echo "no central configuration" > "$ST"; exit 0; }

# files written on Windows: CRLF, BOM, spaces around "=", comments with # or ;
read_conf(){ sed '1s/^\xEF\xBB\xBF//' "$1" | tr -d '\r' | sed -E 's/^[[:space:]]+//; s/[[:space:]]*=[[:space:]]*/=/; s/[[:space:]]+$//' | grep -E '^[A-Z][A-Z0-9_]*='; }
declare -A GIVEN
merge(){ local f=$1 scope=$2 line k
  [ -f "$f" ] || return
  while IFS= read -r line; do k=${line%%=*}
    [[ " $KEYS " == *" $k "* ]] || continue
    [ "$scope" = common ] && [[ " $HOST_ONLY " == *" $k "* ]] && continue
    GIVEN[$k]=${line#*=}
  done < <(read_conf "$f"); }
merge "$COMMON" common
merge "$HOSTF" host

T=$(mktemp); E=$(mktemp); chmod 600 "$T" "$E"; trap 'rm -f "$T" "$E"' EXIT
: > "$E"
# keys that were managed centrally and are no longer in the central files: back to site.conf / the defaults.
# HOSTNAME and the secrets are not stored in the settings file and stay as they are. MGMT_SHARE stays too: a folder
# that moved the device to another folder is not read any more, and the new one need not name itself; released,
# the device would go back to the folder of its image and bounce between the two at every report.
RELEASED=""
for k in $(cat "$MANAGED" 2>/dev/null); do
  [ -z "${GIVEN[$k]+x}" ] && [ "$k" != HOSTNAME ] && [ "$k" != MGMT_SHARE ] && [[ " $SECRETS " != *" $k "* ]] && grep -q "^$k=" "$OTR_CONF" && RELEASED="$RELEASED $k"
done
if [ -n "$RELEASED" ]; then
  cp -p "$OTR_CONF" "$OTR_CONF.central-backup"
  for k in $RELEASED; do sed -i "/^$k=/d" "$OTR_CONF"; done
  # the settings without those keys must still be valid (e.g. no WEB_BUTTON=app left without its WEB_URL)
  if MSG=$("$OTR/save-config.sh" "$E" 2>&1); then
    ev "central configuration: keys no longer managed centrally, back to the defaults:$RELEASED"
  else
    mv -f "$OTR_CONF.central-backup" "$OTR_CONF"
    # reported once per set of keys; they stay managed and are retried at the next run
    if [ "$(cat "$OTR_LIB/central-release-failed" 2>/dev/null)" != "$RELEASED" ]; then
      ev "central configuration: keys removed centrally NOT released, the result would be invalid:$RELEASED ($(echo "$MSG" | tr '\n' ' '))"
      echo "$RELEASED" > "$OTR_LIB/central-release-failed"
    fi
    KEEP=$RELEASED
  fi
  rm -f "$OTR_CONF.central-backup"
fi
# from now on the keys of the central files (plus any that could not be released yet) are the managed ones
{ for k in "${!GIVEN[@]}" ${KEEP:-}; do echo "$k"; done; } | sort -u > "$MANAGED"
[ -f "$COMMON" ] || [ -f "$HOSTF" ] || { echo "no central configuration${RELEASED:+ (released:$RELEASED)}" > "$ST"; exit 0; }
# current settings, stored form
: > "$E"
declare -A CUR NEW
while IFS= read -r line; do CUR[${line%%=*}]=${line#*=}; done < <("$OTR/save-config.sh" "$E" --print 2>/dev/null)
# central values over the current ones, stored form (a rejection stops here)
for k in "${!GIVEN[@]}"; do echo "$k=${GIVEN[$k]}"; done > "$T"
if ! OUTN=$("$OTR/save-config.sh" "$T" --print 2>&1); then MSG=$OUTN; DIFF="(invalid)"
else
  while IFS= read -r line; do NEW[${line%%=*}]=${line#*=}; done <<< "$OUTN"
  DIFF=""
  for k in $KEYS; do [ "${NEW[$k]}" != "${CUR[$k]}" ] && DIFF="$DIFF $k"; done
  if [ -z "$DIFF" ]; then echo "in line $(date '+%Y-%m-%d %H:%M')" > "$ST"; rm -f "$OTR_LIB/central-rejected"; exit 0; fi
  # only the keys that differ go to save-config: the others keep following site.conf and the defaults
  # (a secret goes as written in the central file: its stored form here is only a hash)
  for k in $DIFF; do if [[ " $SECRETS " == *" $k "* ]]; then echo "$k=${GIVEN[$k]}"; else echo "$k=${NEW[$k]}"; fi; done > "$T"
  MSG=$("$OTR/save-config.sh" "$T" 2>&1) && {
    SHOWN=$DIFF; for s in $SECRETS; do SHOWN=${SHOWN/ $s/ $s(hidden)}; done
    ev "central configuration applied:$SHOWN"
    echo "applied $(date '+%Y-%m-%d %H:%M'):$DIFF" > "$ST"
    rm -f "$OTR_LIB/central-rejected"
    exit 0; }
fi
# the same wrong configuration is reported once, not every 5 minutes
SIG=$(cat "$COMMON" "$HOSTF" 2>/dev/null | md5sum | cut -c1-32)
if [ "$(cat "$OTR_LIB/central-rejected" 2>/dev/null)" != "$SIG" ]; then
  ev "central configuration REJECTED (the previous one stays): $(echo "$MSG" | tr '\n' ' ')"
  echo "$SIG" > "$OTR_LIB/central-rejected"
fi
echo "REJECTED $(date '+%Y-%m-%d %H:%M'): $(echo "$MSG" | tr '\n' ' ' | cut -c1-120)" > "$ST"
exit 0
