#!/bin/bash
# Heartbeat watchdog (relay 0099 HALF 2, ratified 2026-09-22).
# c244 upgrade: is-failed check FIRST. The 09-22 outage (102 min,
# SELinux label user_tmp_t) was visible instantly as
# `systemctl is-failed aria-cycle.service` = failed, while the
# staleness invariant fired 86 min late -- the sibling agent's fresh
# heartbeat masked the dead service (c243 scar 1: DETECTION LAG).
# Detection order: (1) unit-failed instant check, (2) heartbeat
# staleness + status. Escalation ladder: restart -> restore wrapper
# from git -> breaker. Circuit breaker: 3 failed heals in 1h -> STOP,
# file to relay + telegram.
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

ts() { date -u "+%Y-%m-%d %H:%M:%SZ"; }
log() { echo "[$(ts)] $*" >> "$LOG"; }

# --- detection 1: the watched unit itself FAILED (instant, c244) ---
# `systemctl is-failed` prints "failed" only when the unit is in a
# failed state. A dead service is visible here with zero lag; the
# staleness invariant can lag up to 90 min behind it.
unhealthy=""
if [ "$(systemctl is-failed "$WATCHED_UNIT" 2>/dev/null)" = "failed" ]; then
  unhealthy="unit-failed:$WATCHED_UNIT"
fi

# --- detection 2: heartbeat staleness + status (original invariant) ---
now=$(date +%s)
for hc in "$ARIA_HC" "$CONT_HC"; do
  if [ ! -f "$hc" ]; then unhealthy="$unhealthy missing:$hc"; continue; fi
  mtime=$(stat -c %Y "$hc")
  age=$(( (now - mtime) / 60 ))
  if [ "$age" -gt "$STALE_MINS" ]; then
    unhealthy="$unhealthy stale:${hc##*/audit/iar/}:${age}m"
  elif ! grep -q "^status: ok" "$hc"; then
    unhealthy="$unhealthy notok:${hc##*/audit/iar/}"
  fi
done

if [ -z "$unhealthy" ]; then
  # Healthy: decay the breaker count (one healthy pass per 15min tick;
  # full reset only when the window has passed with no new strikes)
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
  F="$RELAY/$(date +%Y%m%d)-aria-watchdog-breaker-trip.md"
  if [ ! -f "$F" ]; then
    cat > "$F" << EOR
# REQ $(date +%Y%m%d)-aria-watchdog-breaker
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
# Step 1: restart the cycle service (hung/dead service class)
log "step1: restart $WATCHED_UNIT"
systemctl try-restart "$WATCHED_UNIT" >> "$LOG" 2>&1
echo "$now" >> "$BREAKER_FILE"
sleep "$STEP1_SLEEP"
# Re-check after restart grace: the unit must no longer be failed AND
# at least one heartbeat must be within the staleness window. (The
# unit-state gate is the c244 fix: in the 09-22 disease a FAILED unit
# plus the sibling's fresh heartbeat produced a false "restored" --
# the old recheck matched on heartbeat age alone and exited without
# ever reaching step2.)
unit_now=$(systemctl is-failed "$WATCHED_UNIT" 2>/dev/null || true)
if [ "$unit_now" != "failed" ]; then
  for hc in "$ARIA_HC" "$CONT_HC"; do
    [ -f "$hc" ] || continue
    mtime=$(stat -c %Y "$hc")
    age=$(( (now - mtime) / 60 ))
    if [ "$age" -le "$STALE_MINS" ]; then
      log "heartbeat restored after restart ($hc)"; exit 0
    fi
  done
fi
# Step 2: restore wrapper from git copy + restart
log "step2: restore wrapper from git + restart"
if [ -f "$WRAPPER_GIT" ]; then
  cp "$WRAPPER_GIT" "$WRAPPER.new"
  chmod 755 "$WRAPPER.new"; chown root:root "$WRAPPER.new"
  mv "$WRAPPER.new" "$WRAPPER"
  # Label law (c243): a cp from a bind-mounted repo can inherit a
  # wrong SELinux label; restorecon pins it back to bin_t.
  restorecon "$WRAPPER" 2>/dev/null || true
  systemctl restart "$WATCHED_UNIT" >> "$LOG" 2>&1
fi
exit 0