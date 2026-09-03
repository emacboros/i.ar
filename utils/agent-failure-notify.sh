#!/usr/bin/env bash
# agent-failure-notify.sh -- OnFailure hook for i.ar agent systemd units.
#
# Triggered by OnFailure=agent-failure@%n.service from agent units
# (aria-cycle.service, iar-<agent>.service, ...). %i (the instance
# name) is the failed unit name.
#
# 2026-09-03 REDESIGN (Nacho): hourly DIGEST instead of
# rate-limited per-fire messages. Sep 2 sent ~100 messages -- spam
# that gets skimmed, not read. New contract:
#   - Every fire APPENDS the failure to a digest queue file.
#   - A send happens only if the last send was >= 1 hour ago.
#   - The send contains the FULL hour of failures (count + last 3
#     journal tails), so one message tells the whole story.
#   - First failure after a quiet period sends immediately (the
#     human should know within minutes, not an hour).
#   - Loop-stop telegrams (iar.sh hard stops) are separate and
#     unaffected.
#
# Design decisions kept from 2026-08-31:
#   - Rate-limit state written ONLY after confirmed Telegram send.
#   - All attempts logged to syslog (journalctl -t agent-failure).

set -u

UNIT="${1:-unknown-unit}"
HOST="$(hostname -s)"
DIGEST_INTERVAL=3600  # seconds between digest sends
STATE_DIR="/var/tmp/agent-failure-notify"
TELEGRAM_SH="/var/home/nacho/repos/i.ar/utils/telegram.sh"

log() { logger -t agent-failure "$1"; }

# --- Gather failure details from systemd ---
RESULT="$(systemctl show "$UNIT" -p Result --value 2>/dev/null)"
STATUS="$(systemctl show "$UNIT" -p ExecMainStatus --value 2>/dev/null)"
SINCE="$(systemctl show "$UNIT" -p ExecMainExitTimestamp --value 2>/dev/null)"

JOURNAL="$(journalctl -u "$UNIT" -n 4 --no-pager 2>/dev/null | sed 's/^/  /' | tail -4)"

# --- Append to digest queue (every fire, always) ---
mkdir -p "$STATE_DIR"
QUEUE_FILE="${STATE_DIR}/${UNIT}.queue"
NOW=$(date +%s)
{
    echo "--- ${SINCE:-unknown} exit ${STATUS:-?} (${RESULT:-unknown})"
    echo "$JOURNAL"
} >> "$QUEUE_FILE" 2>/dev/null || log "ERROR: cannot append queue for ${UNIT}"

QUEUE_COUNT=$(grep -c '^--- ' "$QUEUE_FILE" 2>/dev/null || echo 1)

# --- Send decision: first failure sends now; else hourly digest ---
STATE_FILE="${STATE_DIR}/${UNIT}.last"
LAST=0
[[ -f "$STATE_FILE" ]] && LAST=$(cat "$STATE_FILE" 2>/dev/null || echo 0)

if (( NOW - LAST < DIGEST_INTERVAL )); then
    log "queued failure #${QUEUE_COUNT} for ${UNIT} (digest in $(( DIGEST_INTERVAL - (NOW - LAST) ))s)"
    exit 0
fi

# --- Telegram credentials ---
if [[ -f "$TELEGRAM_SH" ]]; then
    # shellcheck disable=SC1090
    source "$TELEGRAM_SH"
else
    log "ERROR: telegram credentials not found at ${TELEGRAM_SH}"
    exit 1
fi

if [[ -z "${AGENT_TELEGRAM_BOT_TOKEN:-}" || -z "${AGENT_TELEGRAM_CHAT_ID:-}" ]]; then
    log "ERROR: telegram credentials empty after sourcing ${TELEGRAM_SH}"
    exit 1
fi

# --- Compose digest message ---
LAST3="$(grep -A5 '^--- ' "$QUEUE_FILE" 2>/dev/null | tail -18)"
MSG="[iar-failure] ${UNIT} on ${HOST}: ${QUEUE_COUNT} failure(s) since last digest
result of latest: ${RESULT:-unknown} (exit ${STATUS:-?}) at ${SINCE:-unknown}
last failures:
${LAST3:-  (no detail)}

Next cycle runs the failure-first protocol (LAST-CYCLE.txt)."

# --- Send ---
RESPONSE="$(curl -s -m 15 --connect-timeout 5 -X POST \
    "https://api.telegram.org/bot${AGENT_TELEGRAM_BOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg chat_id "$AGENT_TELEGRAM_CHAT_ID" \
               --arg text "$MSG" \
               '{chat_id: $chat_id, text: $text}')" 2>/dev/null)"
CURL_RC=$?

if [[ $CURL_RC -ne 0 ]]; then
    log "ERROR: curl failed (rc=${CURL_RC}) for ${UNIT} -- queue kept, retry next fire"
    exit 1
fi

if echo "$RESPONSE" | jq -e '.ok == true' > /dev/null 2>&1; then
    echo "$NOW" > "$STATE_FILE"
    : > "$QUEUE_FILE"   # digest sent -- reset queue
    log "digest sent for ${UNIT} (${QUEUE_COUNT} failures)"
    exit 0
else
    log "ERROR: telegram API rejected send for ${UNIT}: ${RESPONSE:0:200}"
    exit 1
fi
