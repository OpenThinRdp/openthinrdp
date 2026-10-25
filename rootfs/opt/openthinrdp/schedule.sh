#!/bin/bash
# Scheduled jobs of the manager (config\jobs.conf, copied by report.sh, signed as the settings) and scheduled power on
# and off: POWER_ON_TIME / POWER_OFF_TIME = hh:mm (empty = never), POWER_ON_DAYS = days of
# the power on, 1 = Monday ... 7 = Sunday. Runs as root every minute (openthinrdp-schedule.timer);
# save-config.sh runs it with "alarm" to reprogram only the power on at once.
# Power on: RTC wake alarm. Works only if the firmware lets it through (on Dell: "Deep Sleep Control"
#   disabled); with the device off no network is needed.
# Power off: within 5 minutes after the time, if the device was already on at that time (switched on by hand
#   later = stays on). With an open remote session it waits for the session to end. A 60 s warning with
#   "Cancel" comes first.
. /opt/openthinrdp/lib/common.sh
otr_lang
RTC=/sys/class/rtc/rtc0/wakealarm
STF=/run/openthinrdp-schedule-off      # "<day> due|postponed|cancelled|done"
TIMERE='^([01][0-9]|2[0-3]):[0-5][0-9]$'
ON=$(cfg POWER_ON_TIME); OFFT=$(cfg POWER_OFF_TIME)
DAYS=$(cfg POWER_ON_DAYS | tr -cd '1-7'); [ -z "$DAYS" ] && DAYS=1234567
NOW=$(date +%s); TODAY=$(date +%F)

# --- 1) alarm: next POWER_ON_TIME on one of the chosen days, at least 3 minutes from now
AL=0
if [[ $ON =~ $TIMERE ]]; then
  for d in 0 1 2 3 4 5 6 7; do
    t=$(date -d "$(date -d "today + $d days" +%F) $ON" +%s 2>/dev/null) || continue
    [ "$t" -gt $((NOW + 180)) ] && [[ $DAYS == *$(date -d "@$t" +%u)* ]] && { AL=$t; break; }
  done
fi
if [ -w $RTC ]; then
  # the RTC normally keeps UTC on Linux; if it keeps local time the alarm moves by the UTC offset
  ALR=$AL
  if [ $AL -gt 0 ] && [ "$(timedatectl show -p LocalRTC --value 2>/dev/null)" = yes ]; then
    Z=$(date -d "@$AL" +%z); ALR=$(( AL + ${Z:0:1}1 * (10#${Z:1:2} * 3600 + 10#${Z:3:2} * 60) ))
  fi
  CUR=$(cat $RTC 2>/dev/null)
  if [ "${CUR:-0}" != "$ALR" ]; then
    echo 0 > $RTC 2>/dev/null
    if [ $AL -gt 0 ]; then
      echo $ALR > $RTC 2>/dev/null
      if [ "$(cat $RTC 2>/dev/null)" = "$ALR" ]; then ev "power on scheduled: $(date -d "@$AL" '+%a %d/%m %H:%M')"
      # alarm refused by the clock: reported once
      elif [ "$(cat /run/openthinrdp-schedule-err 2>/dev/null)" != "$AL" ]; then
        ev "ERROR: the RTC does not accept the alarm for $(date -d "@$AL" '+%d/%m %H:%M')"; echo $AL > /run/openthinrdp-schedule-err
      fi
    elif [ -n "$CUR" ]; then ev "scheduled power on removed"; fi
  fi
elif [ $AL -gt 0 ] && [ ! -f /run/openthinrdp-schedule-err ]; then
  ev "ERROR: scheduled power on impossible, this device has no RTC alarm (rtc0)"; touch /run/openthinrdp-schedule-err
fi
[ "$1" = alarm ] && exit 0
BOOTED=$(( NOW - $(cut -d. -f1 /proc/uptime) ))
in_session(){ local p; for p in $(pgrep -x xfreerdp3); do tr '\0' '\n' < "/proc/$p/cmdline" 2>/dev/null | grep -q '^/u:' && return 0; done; return 1; }
# a question over everything, the session too (ui.py ask): 0 = the first button, 70 = no answer in time
ask(){ pgrep -x Xorg >/dev/null && id "$OTR_KIOSK_USER" >/dev/null 2>&1 || return 70
  runuser -u "$OTR_KIOSK_USER" -- env DISPLAY=:0 python3 "$OTR/ui.py" ask "$@" >/dev/null 2>&1 < /dev/null; }

# --- 2) scheduled jobs: <id>|<when>|once/daily/weekly|<days 1-7>|restart/poweroff/message/update|<targets>|<force>|<text>
# Targets: * (all), names of devices, g:<group>, separated by commas. The time passed (a job runs within 3 hours of
# it): restart and power off wait while a remote session is open, unless forced (then after the 60 s warning, which
# the user can cancel). A device switched on after the time does not run a restart, a power off or a message. The
# result of each run: jobs-state (one line per run) and jobs-last (the last of each job, in the report).
JF=$OTR_LIB/jobs.conf; JS=$OTR_LIB/jobs-state; JL=$OTR_LIB/jobs-last
job_last(){ { grep -v "^$1=" "$JL" 2>/dev/null; echo "$1=$3@$(date -d "@$2" '+%Y-%m-%dT%H:%M')"; } > "$JL.new"; mv -f "$JL.new" "$JL"; }
job_result(){ echo "$1@$2 $3" >> "$JS"; ev "job $1 ($4): $3${5:+, $5}"; job_last "$1" "$2" "$3"; }
if [ -f "$JF" ]; then
  touch "$JS"; ME=$(hostname | tr 'A-Z' 'a-z'); G=$(tr 'A-Z' 'a-z' < "$OTR_LIB/central-group-name" 2>/dev/null)
  IDS=" "
  while IFS='|' read -r id when rep days act tgt force text; do
    id=$(printf '%s' "$id" | tr -d ' \r'); [[ $id =~ ^[A-Za-z0-9_-]{1,40}$ ]] || continue; IDS="$IDS$id "
    text=${text%$'\r'}; act=$(printf '%s' "$act" | tr -d ' '); force=$(printf '%s' "$force" | tr -d ' ')
    # the targets as words, never as file names (* = all devices)
    hit=0; IFS=, read -ra TS <<< "$(printf '%s' "$tgt" | tr 'A-Z' 'a-z' | tr -d ' ')"; for x in "${TS[@]}"; do
      { [ "$x" = '*' ] || [ "$x" = "$ME" ] || { [ -n "$G" ] && [ "$x" = "g:$G" ]; }; } && hit=1; done
    [ $hit = 1 ] || continue
    case "$rep" in
      once) t=$(date -d "$when" +%s 2>/dev/null) || continue ;;
      daily|weekly) [[ $when =~ $TIMERE ]] || continue
        t=$(date -d "today $when" +%s); [ "$t" -gt "$NOW" ] && t=$(date -d "yesterday $when" +%s)
        [ "$rep" = weekly ] && [[ ${days:-1234567} != *$(date -d "@$t" +%u)* ]] && continue ;;
      *) continue ;;
    esac
    [ "$NOW" -ge "$t" ] || continue
    res=$(sed -n "s/^$id@$t //p" "$JS" | tail -1)
    [ -z "$res" ] || [ "$res" = waiting ] || continue
    if [ "$NOW" -ge $((t + 10800)) ]; then [ "$res" = waiting ] && job_result "$id" "$t" skipped "$act" "remote session open for 3 hours"; continue; fi
    if [ "$act" != update ] && [ "$BOOTED" -gt "$t" ]; then job_result "$id" "$t" off "$act" "switched on after the time"; continue; fi
    case "$act" in
      message)
        setsid runuser -u "$OTR_KIOSK_USER" -- env DISPLAY=:0 python3 "$OTR/ui.py" ask --heading="$(cfg TITLE)" --text="$text" \
          --button="OK:0" --primary=0 --timeout=900 >/dev/null 2>&1 < /dev/null &
        job_result "$id" "$t" done "$act" ;;
      update)
        rm -f "$OTR_LIB/update/github-checked"; touch /run/openthinrdp-update-now
        systemctl start --no-block openthinrdp-report.service; job_result "$id" "$t" done "$act" ;;
      restart|poweroff)
        if in_session && [ "$force" != 1 ]; then [ -z "$res" ] && { echo "$id@$t waiting" >> "$JS"; job_last "$id" "$t" waiting; ev "job $id ($act): waiting, remote session open"; }; continue; fi
        if [ "$act" = restart ]; then H=$L_JOB_RESTART; else H=$L_JOB_POWEROFF; fi
        ask --heading="$H" --text="${text:-$L_JOB_IN60}" --button="$L_CANCEL:1" --timeout=60; RC=$?
        [ $RC -eq 1 ] && { job_result "$id" "$t" cancelled "$act" "by the user of the device"; continue; }
        [ "$force" != 1 ] && in_session && continue
        job_result "$id" "$t" done "$act"; wait_update; sleep 2
        if [ "$act" = restart ]; then systemctl reboot; else systemctl poweroff; fi; exit 0 ;;
    esac
  done < <(sed '1s/^\xEF\xBB\xBF//' "$JF" | grep -v '^[[:space:]]*[#;]')
  # the results of jobs no longer in the file go; the runs of the last 40 days stay
  if [ -s "$JL" ]; then grep -E "^(${IDS// /|}x)=" "$JL" > "$JL.new" 2>/dev/null; mv -f "$JL.new" "$JL"; fi
  [ "$(wc -l < "$JS")" -gt 2000 ] && { tail -n 1000 "$JS" > "$JS.new"; mv -f "$JS.new" "$JS"; }
fi

# --- 3) power off
[[ $OFFT =~ $TIMERE ]] || exit 0
T=$(date -d "today $OFFT" +%s)
STATE=$(cat $STF 2>/dev/null)
# the time has just passed (5 minutes of margin if the timer is late) and the device was already on then
if [ "$NOW" -ge "$T" ] && [ "$NOW" -lt $((T + 300)) ] && [ "$BOOTED" -lt "$T" ] && [[ $STATE != "$TODAY "* ]]; then
  echo "$TODAY due" > $STF; STATE="$TODAY due"
fi
# power off pending (also from last night, if the session ended after midnight)
case "$STATE" in *" due"|*" postponed") ;; *) exit 0 ;; esac
if in_session; then
  [[ $STATE == *" due" ]] && { ev "power off at $OFFT postponed: remote session open, switching off when it ends"; echo "${STATE%% *} postponed" > $STF; }
  exit 0
fi
# warning with Cancel (whoever is using the device keeps it on; without keyboard and mouse it switches off)
RC=70
if pgrep -x Xorg >/dev/null && id "$OTR_KIOSK_USER" >/dev/null 2>&1; then
  runuser -u "$OTR_KIOSK_USER" -- env DISPLAY=:0 yad --title="$(cfg TITLE)" --center --on-top --sticky --width=420 \
    --timeout=60 --timeout-indicator=bottom --text="<b>$(printf "$L_SCHED_TITLE" "$OFFT")</b>\n$L_SCHED_TEXT" \
    --button="$L_CANCEL:1" >/dev/null 2>&1
  RC=$?
fi
# 70 = expired; 1 = Cancel; anything else (X not reachable, dialog closed by the kiosk) = switch off anyway
if [ $RC -eq 1 ]; then ev "power off at $OFFT cancelled by the user"; echo "$TODAY cancelled" > $STF; exit 0; fi
# a session may have started during the warning
in_session && { ev "power off at $OFFT postponed: session opened during the warning"; echo "${STATE%% *} postponed" > $STF; exit 0; }
echo "$TODAY done" > $STF
ev "scheduled power off ($OFFT)"
wait_update; sleep 2; systemctl poweroff
exit 0
