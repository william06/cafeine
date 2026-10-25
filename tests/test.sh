#!/bin/bash
# Tests for cafeine.sh helpers. System commands (pmset, powermetrics, pgrep,
# osascript) are replaced with stubs, so no sudo or real session is needed.
# Usage: bash tests/test.sh
set -euo pipefail
source "$(dirname "$0")/../cafeine.sh"
STATE_DIR=$(mktemp -d); LOG=$STATE_DIR/log
FAILED=0
pass() { echo "ok    $*"; }
fail() { echo "FAIL  $*"; FAILED=1; }
check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1: expected '$3', got '$2'"; fi; }

check "3h"  "$(seconds_of 3h)" 10800
check "90m" "$(seconds_of 90m)" 5400
check "45"  "$(seconds_of 45)" 2700
check "1d"  "$(seconds_of 1d)" 86400
for bad in "" 0 x 3x h -5 3hh; do
  if seconds_of "$bad" >/dev/null 2>&1; then fail "accepts '$bad'"; else pass "rejects '$bad'"; fi
done

journal_set a 1; journal_set b "Sat Oct 24 08:02:11 2026"; journal_set a 2
check "journal overwrites" "$(journal_get a)" 2
check "journal keeps spaces" "$(journal_get b)" "Sat Oct 24 08:02:11 2026"
journal_unset a; check "journal unset" "$(journal_get a)" ""
check "missing key" "$(journal_get zz)" ""
rm -f "$(journal)"

for pair in "Nominal:normal" "Moderate:normal" "Heavy:high" "Trapping:critical" "Sleeping:critical" ":normal"; do
  eval "powermetrics() { printf '**** Thermal pressure ****\nCurrent pressure level: ${pair%%:*}\n'; }"
  check "heat ${pair%%:*}" "$(heat_level)" "${pair#*:}"
done
unset -f powermetrics

# Freeze / thaw with a process of our own
sleep 300 & P=$!
pgrep() { echo $P; }; FREEZE_APPS="Fake"
freeze_apps
check "process frozen" "$(ps -o stat= -p $P | cut -c1)" T
check "listed in frozen" "$(cut -f1 "$(frozen)")" "$P"
thaw_apps
check "process resumed" "$(ps -o stat= -p $P | cut -c1)" S
if [[ ! -f "$(frozen)" ]]; then pass "frozen list removed"; else fail "frozen list still there"; fi
# Reused PID: different start time -> left alone
kill -STOP $P; printf '%s\t%s\n' $P "Mon Jan  1 00:00:00 2001" > "$(frozen)"
thaw_apps >/dev/null
check "reused PID left alone" "$(ps -o stat= -p $P | cut -c1)" T
kill -CONT $P; kill $P; wait $P 2>/dev/null || true; unset -f pgrep

# recover with a dead session
CALLS=$STATE_DIR/calls
need_root() { :; }
pmset() { echo "pmset $*" >> "$CALLS"; }
as_user() { echo "user $*" >> "$CALLS"; }
journal_set pid 999999; journal_set started "x"; journal_set end $(( $(date +%s) + 3600 ))
journal_set low_power_battery 0; journal_set low_power_ac 1; journal_set muted 1
recover >/dev/null
if grep -q "pmset -a disablesleep 0" "$CALLS"; then pass "recover: disablesleep 0"; else fail "recover: no disablesleep 0"; fi
if grep -q "pmset -b lowpowermode 0" "$CALLS" && grep -q "pmset -c lowpowermode 1" "$CALLS"; then
  pass "recover: Low Power Mode"; else fail "recover: Low Power Mode"; fi
if grep -q "without output muted" "$CALLS"; then pass "recover: audio"; else fail "recover: audio"; fi
if [[ ! -f "$(journal)" ]]; then pass "journal removed"; else fail "journal still there"; fi

# recover with a live session before its end: touches nothing
: > "$CALLS"
journal_set pid $$; journal_set started "$(started_at $$)"; journal_set end $(( $(date +%s) + 3600 ))
recover >/dev/null
if [[ ! -s "$CALLS" && -f "$(journal)" ]]; then pass "leaves a live session alone"; else fail "touched a live session"; fi
# ...but alive and hung 10 min past its end: undoes it
journal_set end $(( $(date +%s) - 600 ))
recover >/dev/null
if [[ ! -f "$(journal)" ]]; then pass "undoes a hung session"; else fail "did not undo a hung session"; fi

rm -rf "$STATE_DIR"
exit $FAILED
