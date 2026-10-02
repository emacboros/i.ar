#!/bin/bash
# Heartbeat watchdog (relay 0099 HALF 2, ratified 2026-09-22).
# v3 (aria c257, 2026-09-23): the 09-23 05:26-06:11 kill-spiral RCA.
#
# DISEASE (three stacked flaws, all verified against artifacts):
# 1. notok branch: a FAILED heartbeat (status != ok) triggered a restart.
#    But a failed heartbeat is an ALIVE agent reporting honestly --
#    restart cannot help and kills whoever is mid-turn (continuo turn
#    687 killed mid-edit). Law: A-FAILED-HEARTBEAT-IS-NOT-A-DEAD-AGENT.
#    v3: the notok branch is DELETED. A failed heartbeat is DATA for
#    failure-first, never a restart trigger.
# 2. Strike-write ordering: the breaker strike was written AFTER
#    `systemctl try-restart`, which BLOCKS until the cycle unit
#    restarts (up to 300s). systemd TimeoutStartSec killed the script
#    mid-heal 4x during the spiral -- zero strikes written, breaker
#    never opened (watchdog.log 05:26-06:11 + journald timeouts).
#    v3: strike written BEFORE any heal action; restart uses --no-block
#    so the script always survives to complete its own logic.
# 3. Vacuous recheck: after step1 the script required "any heartbeat
#    <= 90m" -- vacuously true at +90s (no cycle finishes in 90s) and
#    masked by the SIBLING's fresh heartbeat. v3: recheck = unit-state
#    only; heartbeat recovery is judged on the NEXT tick (the breaker
#    is the convergence detector, not the recheck).
#
# Heal trigger (v3): unit-failed OR BOTH heartbeats stale. A single
# stale heartbeat with the sibling fresh = rotation alive = DATA.
# Detection order: (1) unit-failed instant check, (2) both-stale.
# Escalation ladder: restart -> restore wrapper from git -> breaker.
# Circuit breaker: 3 failed heals in 1h -> STOP, file to relay + telegram.
# Testability (belt: deploy/tests/watchdog-is-failed.sh): state paths
# and step1 sleep overridable via env; production defaults below.
set -u
PERS=/var/home/nacho/repos/iar-personalization
ARIA_HC="${ARIA_HC:-$PERS/audit/iar/aria/LAST-CYCLE.txt}"
CONT_HC="${CONT_HC:-$PERS/audit/iar/continuo/LAST-CYCLE.txt}"
WRAPPER="${WRAPPER:-/usr/local/bin/aria-cycle-rotate.sh}"
WRAPPER_GIT="${WRAPPER_GIT:-/var/home/nacho/repos/i.ar/deploy/aria-cycle-rotate.sh}"
BREAKER_FILE="${BREAKER_FILE:-/var/lib/aria-heartbeat/breaker-count}"
BREAKER_WINDOW=3600
STALE_MINS=90
LOG="${LOG:-/var/lib/aria-heartbeat/watchdog.log}"
WATCHED_UNIT="${WATCHED_UNIT:-aria-cycle.service}"
STEP1_SLEEP="${STEP1_SLEEP:-90}"
mkdir -p "$(dirname "$LOG")" "$(dirname "$BREAKER_FILE")"

ts() { date -u "+%Y-%m-%dT%H:%MZ"; }  # relay-parseable format (c277: space+seconds broke relay list age math)

# Per-day relay seq (c595 scar: the 20261002 filing had no seq token ->
# short_id returned empty, find_req could never match -> UNADDRESSABLE).
# Seq = 1 + count of today's aria-* filings already in open/ + answered/
# (the watchdog files at most once/day, so a monotone count is enough;
# collisions self-heal: if the target name exists, increment until free).
relay_seq() {
  local day="$1" n=1
  while :; do
    local found=0
    for f in "$PERS"/relay/open/"$day"-aria-* "$PERS"/relay/answered/"$day"-aria-*; do
      [ -f "$f" ] || continue
      case "$(basename "$f")" in
        "$day"-aria-$(printf "%04d" "$n")-*) found=1 ;;
      esac
    done
    [ "$found" = 0 ] && break
    n=$((n+1))
  done
  printf "%04d" "$n"
}
log() { echo "[$(ts)] $*" >> "$LOG"; }

# --- detection 1: the watched unit itself FAILED (instant, c244) ---
unhealthy=""
if [ "$(systemctl is-failed "$WATCHED_UNIT" 2>/dev/null)" = "failed" ]; then
  unhealthy="unit-failed:$WATCHED_UNIT"
fi

# --- detection 2: BOTH heartbeats stale (v3: rotation-dead invariant) ---
# One stale heartbeat while the sibling is fresh = the rotation is alive
# (the other agent is mid-cycle or just finished); that is DATA, not a
# disease. Both stale > STALE_MINS = nobody is writing anything = dead.
now=$(date +%s)
stale_count=0; stale_detail=""
for hc in "$ARIA_HC" "$CONT_HC"; do
  if [ ! -f "$hc" ]; then stale_count=$((stale_count+1)); stale_detail="$stale_detail missing:$hc"; continue; fi
  mtime=$(stat -c %Y "$hc")
  age=$(( (now - mtime) / 60 ))
  if [ "$age" -gt "$STALE_MINS" ]; then
    stale_count=$((stale_count+1)); stale_detail="$stale_detail stale:${hc##*/audit/iar/}:${age}m"
  fi
done
if [ "$stale_count" -ge 2 ]; then
  unhealthy="$unhealthy both-stale:$stale_detail"
fi

if [ -z "$unhealthy" ]; then
  # Healthy: decay the breaker count (window expiry only)
  if [ -f "$BREAKER_FILE" ]; then
    first=$(head -1 "$BREAKER_FILE" 2>/dev/null)
    if [ -n "$first" ] && [ $(( now - first )) -gt "$BREAKER_WINDOW" ]; then
      rm -f "$BREAKER_FILE"; log "breaker window expired, reset"
    fi
  fi
  exit 0
fi

log "UNHEALTHY:$unhealthy"

# --- breaker check BEFORE any heal ---
if [ -f "$BREAKER_FILE" ]; then
  strikes=$(wc -l < "$BREAKER_FILE")
  first=$(head -1 "$BREAKER_FILE")
  if [ $(( now - first )) -gt "$BREAKER_WINDOW" ]; then
    rm -f "$BREAKER_FILE"; strikes=0
  fi
else
  strikes=0
fi
if [ "$strikes" -ge 3 ]; then
  log "CIRCUIT BREAKER OPEN ($strikes strikes in window) -- escalating to relay + telegram, healing STOPPED"
  RELAY="$PERS/relay/open"
  DAY=$(date +%Y%m%d)
  SEQ=$(relay_seq "$DAY")
  F="$RELAY/$DAY-aria-$SEQ-watchdog-breaker-trip.md"
  if [ ! -f "$F" ]; then
    cat > "$F" << EOR
# REQ $DAY-aria-$SEQ-watchdog-breaker
filed: $(ts)
filer: aria-heartbeat-watchdog
class: nacho-arch
state: open
urgent: yes
title: Watchdog circuit breaker OPEN -- 3 failed heals in 1h
body: |
  Escalation ladder exhausted 3x within the breaker window without
  restoring the heartbeat. Last unhealthy: $unhealthy
  Watchdog log: $LOG
  Healing is STOPPED until human review (a healer that restarts
  forever is a restart loop; the breaker is the loop guard).
answer: (none)
EOR
  fi
  /var/home/nacho/repos/i.ar/utils/telegram.sh "WATCHDOG BREAKER OPEN: 3 failed heals in 1h, last: $unhealthy. Healing stopped, relay filed." 2>/dev/null || true
  exit 0
fi

# --- escalation ladder ---
# v3: strike FIRST (before any blocking action -- the 09-23 spiral had
# 4 timeouts at TimeoutStartSec with zero strikes written), then heal
# with --no-block so this script always survives to finish.
log "step1: restart $WATCHED_UNIT"
echo "$now" >> "$BREAKER_FILE"
systemctl restart --no-block "$WATCHED_UNIT" >> "$LOG" 2>&1
sleep "$STEP1_SLEEP"
# v3 recheck: unit-state only. Heartbeat recovery is judged next tick;
# the breaker is the convergence detector (3 failed heals in 1h).
unit_now=$(systemctl is-failed "$WATCHED_UNIT" 2>/dev/null || true)
if [ "$unit_now" != "failed" ]; then
  log "unit recovered after restart ($WATCHED_UNIT)"; exit 0
fi
# Step 2: restore wrapper from git copy + restart (no-block)
log "step2: restore wrapper from git + restart"
if [ -f "$WRAPPER_GIT" ]; then
  cp "$WRAPPER_GIT" "$WRAPPER.new"
  chmod 755 "$WRAPPER.new"; chown root:root "$WRAPPER.new"
  mv "$WRAPPER.new" "$WRAPPER"
  # Label law (c243): a cp from a bind-mounted repo can inherit a
  # wrong SELinux label; restorecon pins it back to bin_t.
  restorecon "$WRAPPER" 2>/dev/null || true
  systemctl restart --no-block "$WATCHED_UNIT" >> "$LOG" 2>&1
fi
exit 0