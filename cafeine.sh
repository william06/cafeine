#!/bin/bash
# cafeine.sh — keeps the Mac awake (lid closed too) for a set time, then puts
# everything back the way it was: sleep setting, Low Power Mode, audio and
# frozen apps.
#
#   sudo ./cafeine.sh 3h | 90m | 45 | 1d   start a session (no suffix = minutes)
#   sudo ./cafeine.sh recover              undo a session that was left half done
#   sudo ./cafeine.sh install              install the launchd backstop
#   sudo ./cafeine.sh uninstall            remove the launchd backstop
#        ./cafeine.sh status               show the current state
#
# During a session:
#   - Lid closed: turns the display off, freezes the apps in FREEZE_APPS, mutes
#     audio and turns on Low Power Mode. Opening the lid undoes it.
#   - On battery: Low Power Mode below LOW_POWER_BELOW, session ends below
#     END_BELOW.
#   - Heat: Low Power Mode when thermal pressure is heavy, session ends when it
#     is critical.
#
# Every change is written to an on-disk journal BEFORE it is made. If the
# script dies, the launchd backstop (install) reads it and undoes the changes.
#
# The whole thing runs under sudo so the final restore never has to ask for a
# password (with the lid closed you could not type it).

set -euo pipefail

# --- Settings ----------------------------------------------------------------
LOW_POWER_BELOW=40               # % — on battery, Low Power Mode below this
END_BELOW=15                     # % — on battery, end the session below this (0 = never)
WATCH_HEAT=1                     # 1 = watch thermal pressure
FREEZE_APPS="Slack WhatsApp Discord"   # names in /Applications/<name>.app
MUTE=1                           # 1 = mute audio while the lid is closed
SCREEN_OFF_AT_START=1            # 1 = turn the display off when the session starts
INTERVAL=5                       # seconds between checks
HEAT_INTERVAL=30                 # seconds between thermal readings

STATE_DIR=/var/db/cafeine
LOG=/var/log/cafeine.log
LABEL=com.cafeine.recover
INSTALLED=/usr/local/libexec/cafeine.sh
PLIST=/Library/LaunchDaemons/$LABEL.plist
# The app creates this file to ask the session to end. Anyone can create it,
# but all it does is end the session early, which is the safe direction.
STOP_FILE=/tmp/cafeine-stop
# -----------------------------------------------------------------------------

journal() { echo "$STATE_DIR/journal"; }
frozen() { echo "$STATE_DIR/frozen"; }
# What the app reads: rewritten on every pass of the session loop
status_file() { echo "$STATE_DIR/status"; }

log() {
  local line
  line="$(date '+%F %T') $*"
  printf '\n%s\n' "$line"
  echo "$line" >> "$LOG" 2>/dev/null || true
}

usage() {
  sed -n '6,10p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

need_root() {
  [[ $EUID -eq 0 ]] || { echo "This needs sudo."; usage; }
}

# --- Journal: key=value lines ------------------------------------------------

journal_get() {
  [[ -f "$(journal)" ]] || return 0
  awk -v k="$1" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { print v }' "$(journal)"
}

journal_set() {
  local tmp
  tmp="$(journal).tmp"
  { grep -v "^$1=" "$(journal)" 2>/dev/null || true; echo "$1=$2"; } > "$tmp"
  mv -f "$tmp" "$(journal)"
}

journal_unset() {
  [[ -f "$(journal)" ]] || return 0
  local tmp
  tmp="$(journal).tmp"
  { grep -v "^$1=" "$(journal)" || true; } > "$tmp"
  mv -f "$tmp" "$(journal)"
}

# --- System readings ---------------------------------------------------------

seconds_of() {
  local arg="$1" num
  num="${arg%[dhm]}"
  [[ -n "$num" && "$num" =~ ^[0-9]+$ && "$num" -gt 0 ]] || return 1
  case "$arg" in
    *d) echo $(( num * 86400 )) ;;
    *h) echo $(( num * 3600 )) ;;
    *)  echo $(( num * 60 )) ;;
  esac
}

# lowpowermode value of one pmset -g custom profile ("Battery Power" or "AC Power")
low_power_of() {
  pmset -g custom | awk -v profile="$1" '
    /^[A-Za-z].*:$/ { inside = ($0 == profile ":") }
    inside && $1 == "lowpowermode" { print $2 }'
}

lid_closed() {
  ioreg -r -k AppleClamshellState -d 1 | grep -q '"AppleClamshellState" = Yes'
}

thermal_pressure() {
  powermetrics -n 1 -i 200 --samplers thermal 2>/dev/null \
    | awk -F': *' '/pressure level/ { print $2; exit }' || true
}

# normal | high | critical, from the thermal pressure powermetrics reports
heat_level() {
  case "$(thermal_pressure)" in
    Heavy) echo high ;;
    Trapping|Sleeping) echo critical ;;
    *) echo normal ;;
  esac
}

started_at() { ps -o lstart= -p "$1" 2>/dev/null || true; }

# Runs a command as the user who owns the graphical session (needed for audio)
as_user() {
  local user
  user=$(stat -f%Su /dev/console)
  [[ -n "$user" && "$user" != root ]] || return 1
  launchctl asuser "$(id -u "$user")" sudo -u "$user" "$@"
}

# --- Changes (each one is journaled before it is made) -----------------------

set_low_power() {
  if [[ "$1" == 1 ]]; then
    pmset -a lowpowermode 1
  else
    restore_low_power
  fi
}

restore_low_power() {
  local b c
  b=$(journal_get low_power_battery)
  c=$(journal_get low_power_ac)
  [[ -z "$b" ]] || pmset -b lowpowermode "$b"
  [[ -z "$c" ]] || pmset -c lowpowermode "$c"
}

freeze_apps() {
  local app pid started
  for app in $FREEZE_APPS; do
    for pid in $(pgrep -f "^/Applications/$app\\.app/" || true); do
      started=$(started_at "$pid")
      [[ -n "$started" ]] || continue
      printf '%s\t%s\n' "$pid" "$started" >> "$(frozen)"
      kill -STOP "$pid" 2>/dev/null || true
    done
  done
}

# Only resumes a process that is still the one that was frozen (same PID and
# same start time). Returns 1 if any could not be resumed.
thaw_apps() {
  [[ -f "$(frozen)" ]] || return 0
  local pid started current failed=0
  while IFS=$'\t' read -r pid started; do
    current=$(started_at "$pid")
    if [[ -z "$current" ]]; then
      continue
    elif [[ "$current" == "$started" ]]; then
      kill -CONT "$pid" 2>/dev/null || failed=1
    else
      log "PID $pid is now a different process; leaving it alone."
    fi
  done < "$(frozen)"
  if [[ $failed == 0 ]]; then
    rm -f "$(frozen)"
  else
    log "Some frozen processes could not be resumed; they are listed in $(frozen)."
    return 1
  fi
}

mute() {
  [[ $MUTE == 1 ]] || return 0
  local already
  already=$(as_user osascript -e 'output muted of (get volume settings)' 2>/dev/null || true)
  [[ "$already" == false ]] || return 0
  journal_set muted 1
  as_user osascript -e 'set volume with output muted' >/dev/null 2>&1 \
    || log "Could not mute audio."
}

unmute() {
  [[ "$(journal_get muted)" == 1 ]] || return 0
  if as_user osascript -e 'set volume without output muted' >/dev/null 2>&1; then
    journal_unset muted
  else
    log "Could not unmute audio (is anyone logged in?)."
    return 1
  fi
}

on_lid_close() {
  log "Lid closed: display off, apps frozen, audio muted."
  pmset displaysleepnow || true
  freeze_apps
  mute
}

on_lid_open() {
  log "Lid opened: apps resumed, audio unmuted."
  thaw_apps || true
  unmute || true
}

# Undoes everything in the journal. If it all works, deletes the journal.
undo() {
  rm -f "$(status_file)"
  [[ -f "$(journal)" ]] || return 0
  local ok=1
  thaw_apps || ok=0
  unmute || ok=0
  restore_low_power || ok=0
  pmset -a disablesleep 0 || ok=0
  if [[ $ok == 1 ]]; then
    rm -f "$(journal)"
    log "Everything restored."
  else
    log "Restore incomplete; the journal stays in $(journal) for another try."
  fi
}

# --- Commands ----------------------------------------------------------------

session() {
  need_root
  local seconds
  seconds=$(seconds_of "${1:-}") || usage

  mkdir -p "$STATE_DIR"
  if [[ -f "$(journal)" ]]; then
    local previous_pid
    previous_pid=$(journal_get pid)
    if [[ -n "$previous_pid" && "$(started_at "$previous_pid")" == "$(journal_get started)" ]]; then
      echo "A session is already running (PID $previous_pid)."
      exit 1
    fi
    log "A previous session was left half done; undoing it first."
    undo
    [[ ! -f "$(journal)" ]] || exit 1
  fi

  local end
  end=$(( $(date +%s) + seconds ))
  journal_set pid $$
  journal_set started "$(started_at $$)"
  journal_set end "$end"
  journal_set low_power_battery "$(low_power_of "Battery Power")"
  journal_set low_power_ac "$(low_power_of "AC Power")"
  journal_set disablesleep 1

  trap undo EXIT
  trap 'exit 130' INT TERM HUP

  rm -f "$STOP_FILE"
  pmset -a disablesleep 1
  log "Mac awake until $(date -r "$end" '+%b %d %H:%M'). Ctrl+C to end early."
  if [[ $WATCH_HEAT == 1 ]]; then
    local pressure
    pressure=$(thermal_pressure)
    log "Thermal pressure: ${pressure:-no reading (heat will not be watched)}"
  fi
  if [[ $SCREEN_OFF_AT_START == 1 ]]; then
    echo "Display turns off in 10 s (move the mouse to wake it)."
    sleep 10
    pmset displaysleepnow || true
  fi

  local was_closed=0 closed battery on_battery pct heat=normal
  local last_heat=0 low_power=0 want remaining now
  while :; do
    now=$(date +%s)
    (( now < end )) || { log "Time is up."; break; }
    if [[ -e "$STOP_FILE" ]]; then
      rm -f "$STOP_FILE"
      log "Ended from the app."
      break
    fi

    battery=$(pmset -g batt)
    pct=$(grep -Eo '[0-9]+%' <<<"$battery" | head -1 | tr -d '%' || true)
    on_battery=0
    if grep -q "Battery Power" <<<"$battery"; then on_battery=1; fi
    if [[ $on_battery == 1 && -n "$pct" && $END_BELOW -gt 0 && $pct -lt $END_BELOW ]]; then
      log "Battery at ${pct}%: ending the session."
      break
    fi

    if [[ $WATCH_HEAT == 1 ]] && (( now - last_heat >= HEAT_INTERVAL )); then
      heat=$(heat_level)
      last_heat=$now
      if [[ $heat == critical ]]; then
        log "Critical temperature: ending the session."
        break
      fi
    fi

    closed=0
    if lid_closed; then closed=1; fi
    if [[ $closed == 1 && $was_closed == 0 ]]; then on_lid_close; fi
    if [[ $closed == 0 && $was_closed == 1 ]]; then on_lid_open; fi
    was_closed=$closed

    want=0
    if [[ $closed == 1 || $heat == high ]]; then want=1; fi
    if [[ $on_battery == 1 && -n "$pct" && $pct -lt $LOW_POWER_BELOW ]]; then want=1; fi
    if [[ $want != "$low_power" ]]; then
      set_low_power "$want"
      low_power=$want
    fi

    printf 'updated=%s\nend=%s\nbattery=%s\non_battery=%s\nheat=%s\nlow_power=%s\nlid_closed=%s\n' \
      "$now" "$end" "${pct:-}" "$on_battery" "$heat" "$low_power" "$closed" \
      > "$(status_file).tmp"
    mv -f "$(status_file).tmp" "$(status_file)"

    remaining=$(( end - now ))
    printf '\r%02d:%02d left  battery %s%%  heat %s  low power %s ' \
      $(( remaining / 3600 )) $(( remaining % 3600 / 60 )) "${pct:-?}" "$heat" \
      "$([[ $low_power == 1 ]] && echo on || echo off)"
    sleep "$INTERVAL"
  done
}

# launchd runs this every minute. If there is a journal and the session is no
# longer alive (the script died, or hung well past its end time), undo it.
recover() {
  need_root
  [[ -f "$(journal)" ]] || return 0
  local pid started end
  pid=$(journal_get pid)
  started=$(journal_get started)
  end=$(journal_get end)
  if [[ -n "$pid" && "$(started_at "$pid")" == "$started" ]]; then
    (( $(date +%s) > ${end:-0} + 300 )) || return 0
    log "Session (PID $pid) is still alive 5 min after its end; undoing it."
    kill -CONT "$pid" 2>/dev/null || true
  else
    log "Session is no longer running and left changes behind; undoing them."
  fi
  undo
}

install() {
  need_root
  mkdir -p "$(dirname "$INSTALLED")"
  # Copy then rename instead of overwriting: a running session keeps reading
  # the old file instead of finding a half-written one
  cp "$0" "$INSTALLED.new"
  chmod 755 "$INSTALLED.new"
  mv -f "$INSTALLED.new" "$INSTALLED"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$INSTALLED</string><string>recover</string></array>
  <key>StartInterval</key><integer>60</integer>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
  chmod 644 "$PLIST"
  launchctl bootout system "$PLIST" 2>/dev/null || true
  launchctl bootstrap system "$PLIST"
  echo "Backstop installed: every minute it checks whether anything needs undoing."
  echo "If you change the script, run this again: sudo $0 install"
}

uninstall() {
  need_root
  launchctl bootout system "$PLIST" 2>/dev/null || true
  rm -f "$PLIST" "$INSTALLED"
  echo "Backstop removed."
}

status() {
  local sleep_disabled
  sleep_disabled=$(pmset -g | awk '/SleepDisabled/ { print $2 }')
  echo "SleepDisabled:  ${sleep_disabled:-0}"
  echo "Low Power Mode: battery $(low_power_of "Battery Power"), AC $(low_power_of "AC Power")"
  echo "Lid:            $(lid_closed && echo closed || echo open)"
  if launchctl print "system/$LABEL" >/dev/null 2>&1; then
    echo "Backstop:       installed"
  else
    echo "Backstop:       not installed"
  fi
  if [[ -f "$(journal)" ]]; then
    echo "Journal ($(journal)):"
    sed 's/^/  /' "$(journal)"
    [[ ! -f "$(frozen)" ]] || { echo "Frozen processes:"; sed 's/^/  /' "$(frozen)"; }
  else
    echo "No pending session."
  fi
}

main() {
  case "${1:-}" in
    recover)   recover ;;
    install)   install ;;
    uninstall) uninstall ;;
    status)    status ;;
    ''|-h|--help) usage ;;
    *)         session "$1" ;;
  esac
}

# Lets tests load the functions with `source` without running anything
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
