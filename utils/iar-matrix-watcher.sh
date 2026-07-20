#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# iar-matrix-watcher -- Matrix event-driven agent dispatcher
#
# Polls Matrix /sync for new human messages. When a human message is detected
# in any room, finds all *-bot members in that room and launches each agent
# in parallel with a Matrix turn cycle prompt.
#
# The watcher uses the HUMAN_MATRIX_TOKEN to sync (sees all rooms the human
# is in). Agent bot tokens are passed to each container via iar.sh.
#
# State: a single file stores the /sync "since" token for incremental sync.
# On first run (no state file), does an initial sync to get a baseline token
# without processing any messages.
#
# Usage:
#   ./utils/iar-matrix-watcher.sh --personalization PATH [IAR.SH OPTIONS]
#
# The watcher passes through most iar.sh options (ollama-host, model, ctx,
# gptel-fork, etc.) by constructing an iar.sh command line. It only adds
# --loop --max-cycles 1 --cycle-prompt matrix_turn --agent <name>.
#
# Environment:
#   HUMAN_MATRIX_TOKEN    Required. Matrix token for the human account.
#   AGENT_MATRIX_URL      Matrix server URL (default: http://10.66.0.3:8008).
#   IAR_WATCHER_STATE     Path to state file (default: /tmp/iar-matrix-watcher.state)
#   IAR_WATCHER_INTERVAL  Poll interval in seconds (default: 5)
# =============================================================================

REPO_DIR="$(realpath "$(dirname "${BASH_SOURCE[0]}")/..")"
WATCHER_DIR="$(realpath "$(dirname "${BASH_SOURCE[0]}")")"

source "${REPO_DIR}/metaconfig/header.sh"
source "${REPO_DIR}/utils/matrix.sh"

MATRIX_SERVER="${AGENT_MATRIX_URL:-http://10.66.0.3:8008}"
STATE_FILE="${IAR_WATCHER_STATE:-/tmp/iar-matrix-watcher.state}"
POLL_INTERVAL="${IAR_WATCHER_INTERVAL:-5}"
HUMAN_USER_ID="@human:matrix.i.ar"

# iar.sh passthrough options
IAR_ARGS=()
PERSONALIZATION_DIR=""

usage() {
    cat <<EOF
Usage: $0 --personalization PATH [OPTIONS]

Required:
  --personalization PATH   Path to personalization directory (passed to iar.sh)

Passthrough options (forwarded to iar.sh):
  --ollama-host HOST       Ollama API host:port
  --model NAME             Ollama model name
  --ctx N                  Max context window in tokens
  --gptel-fork PATH        Path to gptel fork directory
  --self-modification      Enable self-modification mode
  --knowledge LABEL        Knowledge directory label (can repeat)

Watcher options:
  --state-file PATH        Path to state file (default: ${STATE_FILE})
  --interval SECONDS       Poll interval (default: ${POLL_INTERVAL})
  --help, -h               Show this message and exit

Environment:
  HUMAN_MATRIX_TOKEN       Required. Matrix token for human account.
  AGENT_MATRIX_URL         Matrix server URL (default: ${MATRIX_SERVER})
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --personalization)
            PERSONALIZATION_DIR="$2"
            shift 2
            ;;
        --ollama-host|--model|--ctx|--gptel-fork|--knowledge)
            IAR_ARGS+=("$1" "$2")
            shift 2
            ;;
        --self-modification)
            IAR_ARGS+=("$1")
            shift
            ;;
        --state-file)
            STATE_FILE="$2"
            shift 2
            ;;
        --interval)
            POLL_INTERVAL="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

if [[ -z "${PERSONALIZATION_DIR}" ]]; then
    error "--personalization is required."
    usage
    exit 1
fi

if [[ -z "${HUMAN_MATRIX_TOKEN}" ]]; then
    error "HUMAN_MATRIX_TOKEN is required. Source utils/matrix.sh first."
    exit 1
fi

# =============================================================================
# Matrix API helpers
# =============================================================================

# Initial sync to get a baseline since token. No messages processed.
initial_sync() {
    info "Performing initial sync to establish baseline..."
    local response
    response=$(curl -s -m 30 \
        -H "Authorization: Bearer ${HUMAN_MATRIX_TOKEN}" \
        "${MATRIX_SERVER}/_matrix/client/r0/sync?timeout=0&full_state=false")

    local since_token
    since_token=$(echo "${response}" | jq -r '.next_batch // empty')

    if [[ -z "${since_token}" ]]; then
        error "Initial sync failed: no next_batch token in response"
        echo "${response}" | jq . 2>/dev/null || echo "${response}"
        exit 1
    fi

    echo "${since_token}" > "${STATE_FILE}"
    info "Baseline established. Since token: ${since_token}"
}

# Incremental sync. Returns JSON response.
incremental_sync() {
    local since_token
    since_token=$(cat "${STATE_FILE}" 2>/dev/null || echo "")

    if [[ -z "${since_token}" ]]; then
        initial_sync
        since_token=$(cat "${STATE_FILE}")
    fi

    local response
    response=$(curl -s -m 30 \
        -H "Authorization: Bearer ${HUMAN_MATRIX_TOKEN}" \
        "${MATRIX_SERVER}/_matrix/client/r0/sync?since=${since_token}&timeout=0&full_state=false")

    echo "${response}"
}

# Save the since token from a sync response
save_since_token() {
    local response="$1"
    local since_token
    since_token=$(echo "${response}" | jq -r '.next_batch // empty')
    if [[ -n "${since_token}" ]]; then
        echo "${since_token}" > "${STATE_FILE}"
    fi
}

# Get joined members of a room. Returns list of user IDs.
get_room_members() {
    local room_id="$1"
    curl -s -m 10 \
        -H "Authorization: Bearer ${HUMAN_MATRIX_TOKEN}" \
        "${MATRIX_SERVER}/_matrix/client/r0/rooms/${room_id}/joined_members" \
        | jq -r '.joined | keys[]' 2>/dev/null
}

# Map a Matrix user ID to an agent name.
# @mirror-bot:matrix.i.ar -> mirror
# @darwin-bot:matrix.i.ar -> darwin
# Returns empty string if not a bot account.
matrix_user_to_agent() {
    local user_id="$1"
    # Extract the localpart (between @ and :)
    local localpart
    localpart=$(echo "${user_id}" | sed -n 's/^@\([^:]*\):.*/\1/p')

    # Strip -bot suffix
    if [[ "${localpart}" == *-bot ]]; then
        echo "${localpart%-bot}"
    fi
}

# =============================================================================
# Agent dispatch
# =============================================================================

# Launch a single agent for a Matrix turn.
# Runs iar.sh in a background process. Returns immediately.
launch_agent() {
    local agent_name="$1"
    local room_id="$2"
    local log_file="/tmp/iar-watcher-${agent_name}-$(date +%s).log"

    info "Launching agent: ${agent_name} for room ${room_id}"

    # Build the iar.sh command
    local cmd=(
        "${WATCHER_DIR}/iar.sh"
        --loop
        --personalization "${PERSONALIZATION_DIR}"
        --agent "${agent_name}"
        --max-cycles 1
        --cycle-prompt matrix_turn
        --timeout 300
    )
    cmd+=("${IAR_ARGS[@]}")

    # Run in background, log to file
    "${cmd[@]}" > "${log_file}" 2>&1 &
    local pid=$!
    info "  Agent ${agent_name} launched (PID ${pid}, log: ${log_file})"
}

# =============================================================================
# Main loop
# =============================================================================

info "=========================================="
info "i.ar Matrix Watcher"
info "  Server: ${MATRIX_SERVER}"
info "  State: ${STATE_FILE}"
info "  Interval: ${POLL_INTERVAL}s"
info "  Human: ${HUMAN_USER_ID}"
info "=========================================="

# Ensure state file exists
if [[ ! -f "${STATE_FILE}" ]]; then
    initial_sync
fi

while true; do
    # Sync and get new events
    sync_response=$(incremental_sync)
    save_since_token "${sync_response}"

    # Extract rooms with new messages from human
    # The /sync response has: rooms.join.{roomId}.timeline.events[]
    # We filter for: type=m.room.message, sender=human, msgtype=m.text
    human_rooms=$(echo "${sync_response}" \
        | jq -r '
            .rooms?.join // {} | to_entries[]
            | select(.value.timeline?.events // [] | any(
                  .type == "m.room.message"
                  and .sender == "'${HUMAN_USER_ID}'"
                  and .content.msgtype == "m.text"
              ))
            | .key
        ' 2>/dev/null)

    if [[ -n "${human_rooms}" ]]; then
        while IFS= read -r room_id; do
            [[ -z "${room_id}" ]] && continue
            info "New human message in room: ${room_id}"

            # Get bot members
            members=$(get_room_members "${room_id}")

            # Launch each bot agent in parallel
            pids=()
            while IFS= read -r member_id; do
                [[ -z "${member_id}" ]] && continue
                agent_name=$(matrix_user_to_agent "${member_id}")
                if [[ -n "${agent_name}" ]]; then
                    launch_agent "${agent_name}" "${room_id}"
                    pids+=($!)
                fi
            done <<< "${members}"

            # Wait for all agents to finish
            if [[ ${#pids[@]} -gt 0 ]]; then
                info "Waiting for ${#pids[@]} agent(s) to finish..."
                for pid in "${pids[@]}"; do
                    wait "${pid}" 2>/dev/null || true
                    info "  Agent PID ${pid} exited with status $?"
                done
                info "All agents finished for room ${room_id}"
            fi
        done <<< "${human_rooms}"
    fi

    sleep "${POLL_INTERVAL}"
done