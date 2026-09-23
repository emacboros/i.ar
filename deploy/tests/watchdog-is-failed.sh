#!/bin/bash
# Belt for the watchdog is-failed upgrade (c244, roadmap item 1).
# Disease: aria-cycle.service FAILED + continuo heartbeat FRESH.
# Old watchdog: staleness invariant only -> continuo's fresh heartbeat
# masks the dead service -> 86-min detection lag (c243 scar 1).
# Fixed watchdog: is-failed check FIRST -> step1 fires immediately.
# Run: watchdog-is-failed.sh [path-to-watchdog-script]
# Exit 0 = all fixtures pass; nonzero = belt failure.
set -u
W="${1:?usage: watchdog-is-failed.sh <watchdog-script>}"
PASS=0; FAIL=0
say() { echo "  $*"; }
check() { # check <name> <expect> <actual>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); say "PASS $1"; else FAIL=$((FAIL+1)); say "FAIL $1 (expect=$2 actual=$3)"; fi
}

SBX=$(mktemp -d)
mkdir -p "$SBX/bin" "$SBX/state" "$SBX/logdir" "$SBX/brk"
cat > "$SBX/bin/systemctl" << 'STUB'
#!/bin/bash
case "$1 $2" in
  "is-failed aria-cycle.service") cat "$FAKE_SYSTEMCTL_STATE" 2>/dev/null || echo "active" ;;
  "try-restart aria-cycle.service") echo "try-restart called" >> "$FAKE_SYSTEMCTL_CALLS"; exit 0 ;;
  "restart aria-cycle.service") echo "restart called" >> "$FAKE_SYSTEMCTL_CALLS"; exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$SBX/bin/systemctl"
export FAKE_SYSTEMCTL_STATE="$SBX/state/unit-state"
export FAKE_SYSTEMCTL_CALLS="$SBX/state/calls"

run_watchdog() { # run_watchdog <aria_age_min> <aria_status> <unit_state> <tag>
  local age=$1 st=$2 us=$3 tag=$4
  rm -f "$FAKE_SYSTEMCTL_CALLS"
  echo "$us" > "$FAKE_SYSTEMCTL_STATE"
  local hc="$SBX/state/aria-LAST-CYCLE-$tag.txt"
  printf 'status: %s\nexit: 0\nended: now\n' "$st" > "$hc"
  touch -d "$age minutes ago" "$hc"
  ARIA_HC="$hc" CONT_HC="$hc" LOG="$SBX/logdir/log" BREAKER_FILE="$SBX/brk/breaker" \
    STEP1_SLEEP=1 PATH="$SBX/bin:$PATH" timeout 30 bash "$W" 2>/dev/null
}

# DISEASE A: unit FAILED, heartbeat FRESH+ok -> must heal (step1 call logged)
run_watchdog 5 ok failed diseaseA
calls=$(cat "$FAKE_SYSTEMCTL_CALLS" 2>/dev/null | wc -l)
check "diseaseA: failed-unit+fresh-hc triggers heal" "1" "$calls"

# HEALTHY: unit active, heartbeat fresh+ok -> NO heal calls
run_watchdog 5 ok active healthy
calls=$(cat "$FAKE_SYSTEMCTL_CALLS" 2>/dev/null | wc -l)
check "healthy: no heal" "0" "$calls"

# DISEASE B: unit active, heartbeat STALE -> must heal (old invariant still works)
run_watchdog 120 ok active diseaseB
calls=$(cat "$FAKE_SYSTEMCTL_CALLS" 2>/dev/null | wc -l)
check "diseaseB: stale-hc+active-unit triggers heal" "1" "$calls"

# DISEASE C: unit FAILED, heartbeat STALE -> must heal once (no double-fire)
run_watchdog 120 ok failed diseaseC
calls=$(cat "$FAKE_SYSTEMCTL_CALLS" 2>/dev/null | wc -l)
check "diseaseC: failed+stale triggers heal (single)" "1" "$calls"

echo "== watchdog-is-failed belt: PASS=$PASS FAIL=$FAIL =="
rm -rf "$SBX"
[ "$FAIL" = 0 ]
