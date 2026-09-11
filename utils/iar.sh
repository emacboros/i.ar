#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# i.ar -- Unified entry point for the agent system
#
# Three modes:
#   Interactive (default)  -- Drops you into an Emacs gptel chat buffer.
#   Loop (--loop)          -- Runs an agent autonomously for N cycles.
#   One-shot (--one-shot)  -- Single instruction, single response, exits.
#
# Usage:
#   ./utils/iar.sh --personalization PATH [OPTIONS]
#   ./utils/iar.sh --loop --personalization PATH --agent NAME [OPTIONS]
#
# Container names auto-include the shell PID so multiple instances can run
# in parallel without collisions.
# =============================================================================

# IAR_REPO_DIR override (relay 0041): when executed from a frozen
# /tmp copy, BASH_SOURCE points at the copy -- the override pins the
# real repo for sourcing, mounts, and self-modification.
REPO_DIR="${IAR_REPO_DIR:-$(realpath "$(dirname "${BASH_SOURCE[0]}")/..")}"

source "${REPO_DIR}/metaconfig/header.sh"
[[ -f "${REPO_DIR}/utils/telegram.sh" ]] && source "${REPO_DIR}/utils/telegram.sh"

IMAGE_NAME="iar-emacboros"
LOCAL_OLLAMA_HOST="${EMACBOROS_OLLAMA_HOST:-10.66.0.5:11434}"

# =============================================================================
# Usage
# =============================================================================
usage() {
    cat <<EOF
Usage: iar.sh --personalization PATH [OPTIONS]
       iar.sh --loop --personalization PATH --agent NAME [OPTIONS]
       iar.sh --one-shot --personalization PATH --agent NAME --prompt "TEXT" [OPTIONS]

Required:
  --personalization PATH
                       Mount a personalization directory into the container.
                       The directory must contain four subdirectories:
                         docs/      -- injectable project documentation
                         knowledge/  -- concept knowledge bases (agent-queryable)
                         tasks/      -- task trees (tasks/<project>/<task>/)
                         audit/      -- per-agent logs (audit/<project>/<personality>/)
                       Mounted at /root/personalization/ (single mount).
                       Agents access subdirs at /root/personalization/{docs,knowledge,tasks,audit}.

Mode:
  --one-shot            Run in one-shot mode (requires --agent and --prompt).
                       Sends a single instruction, agent produces a final
                       response, and exits. Clean stdout (final response only).
                       Diagnostics go to stderr.
  --loop               Run in autonomous loop mode (requires --agent).
                       Default: interactive mode (Emacs gptel chat buffer).

Options (both modes):
  --self-modification  Enable self-modification mode. Allows agents to modify
                       Emacs Lisp source files (init.el, init.d/**/*.el), container
                       configuration, and git hooks. Agent prompt files and
                       base_context.org remain protected regardless.
                       Default: disabled (all guards active).
  --ollama-host HOST    Ollama API host:port (default: ${LOCAL_OLLAMA_HOST}).
  --local              Shortcut for --ollama-host localhost:11434 with host networking.
  --model NAME          Ollama model name (default: glm-5.3:cloud).
                       Must be in the model list in emacs.d/configs/gptel.el.
  --ctx N               Max context window in tokens (default: 1048576 = 1M).
                       Critical for local models -- KV cache scales linearly.
                       Use 131072 (128K) or 262144 (256K) for local models.
  --no-think           Disable model thinking (send think:false to Ollama).
                       Only affects models that honor the toggle (e.g.
                       nemotron-3-super:120b). gpt-oss models ignore it and
                       glm-5.3:cloud leaks thinking into content -- startup
                       warns about both. No-op for non-thinking models.
  --mount PATH          Mount a host directory read-write inside the container
                       at the same absolute path. Can be specified multiple times.
  --mount-ro PATH       Mount a host directory read-only inside the container
                       at the same absolute path. Can be specified multiple times.
  --gptel-fork PATH    Mount a local gptel fork directory (writable) into the
                       container and use it instead of the ELPA package.
  --ssh-key-dir PATH    Directory containing SSH keys (default: ~/.ssh).
  --ssh-key NAME        SSH key name to use (default: emacboros_ed25519).
                       Looks for <name> and <name>.pub in --ssh-key-dir.
                       If the key does not exist, SSH mounts are skipped
                       (agent has no git push capability, but pull still works
                       via HTTPS).
  --memory LIMIT       Podman memory limit (default: 8g). Caps container
                       memory to prevent host OOM kills on long sessions.
  --rate-limit SECONDS Sleep SECONDS before each execute_code_local/remote call.
                       Crude rate limiting for autonomous pentesting against real targets.
                       Default: no rate limiting.
  --no-containers      Disable all sidecar containers (overrides #+CONTAINERS).
                       Useful for debugging the Emacs container in isolation.
  --container-image T:I Override container image for target T with image I.
                       Example: --container-image pentest:my-pentest:latest
                       Can be specified multiple times for different targets.
  --knowledge LABEL    Documentation directory label to load (default: iar/).
                       Can be specified multiple times to load multiple bases.
  --cycle-prompt NAME  Override cycle prompt file (e.g. aria_daily).
                       Loads from agents.d/common/<NAME>.org instead of
                       the default agent cycle prompt.
  --help, -h            Show this message and exit.


Options (loop and one-shot mode):
  --agent NAME          Agent personality name (required in --loop and --one-shot mode).
                       Must exist as agents.d/personalities/<name>.org.
  --prompt TEXT         Instruction for one-shot mode (required with --one-shot).
                       Passed to the agent as the initial message.
                       Only valid with --one-shot.

Options (loop mode only):
  --max-cycles N        Maximum number of cycles (default: 1).
  --cooldown SECONDS   Seconds to wait between cycles (default: 60).
  --max-failures N     Max consecutive failures before stopping (default: 5).
  --timeout SECONDS    Per-cycle timeout (default: 7200 = 120 min).

Environment:
  EMACBOROS_OLLAMA_HOST     Ollama API host (overridden by --ollama-host)
  AGENT_TELEGRAM_BOT_TOKEN  Telegram bot token for notifications (loop mode)
  AGENT_TELEGRAM_CHAT_ID    Telegram chat ID for notifications (loop mode)

Examples:
  # Interactive session with self-modification
  iar.sh --project iar --personalization ~/repos/iar-personalization --gptel-fork ~/repos/gptel

  # Interactive session (no self-modification)
  iar.sh --project iar --personalization ~/repos/iar-personalization --gptel-fork ~/repos/gptel

  # Darwin autonomous loop
  iar.sh --loop --project iar --self-modification --personalization ~/repos/iar-personalization \\
    --agent darwin --gptel-fork ~/repos/gptel --max-cycles 50

  # Gardener autonomous loop
  iar.sh --loop --project iar --personalization ~/repos/iar-personalization \\
    --agent gardener --gptel-fork ~/repos/gptel --max-cycles 10

  # Playground loop on GPU model (sophon)
  iar.sh --loop --project iar --personalization ~/repos/iar-personalization \\
    --agent playground --model nemotron-3-super:120b --ctx 131072 \\
    --ollama-host 10.66.0.5:11434 --max-cycles 999 --cooldown 300

  # Playground loop on CPU model (daftpunk)
  iar.sh --loop --project iar --personalization ~/repos/iar-personalization \\
    --agent playground --model granite4.1:30b --ctx 131072 \\
    --ollama-host 10.66.0.3:11434 --max-cycles 999 --cooldown 300

  # One-shot: single instruction, clean stdout
  iar.sh --one-shot --project iar --personalization ~/repos/iar-personalization \\
    --agent mirror --prompt "Review init.el and report any issues" \\
    --model granite4.1:8b-q8_0 --ctx 131072
EOF
}

# =============================================================================
# Parse arguments
# =============================================================================
MODE="interactive"
AGENT_NAME=""
MAX_CYCLES=1
COOLDOWN=60
TIMEOUT=7200
MAX_CONSECUTIVE_FAILURES=5
OLLAMA_HOST="${LOCAL_OLLAMA_HOST}"
OLLAMA_MODEL=""
OLLAMA_CTX=""
OLLAMA_NO_THINK=0
USE_LOCAL=false
PERSONALIZATION_DIR=""
PROJECT_NAME=""
SSH_KEY_DIR="${HOME}/.ssh"
SSH_KEY_NAME=""
GPTEL_FORK_PATH=""
SELF_MODIFICATION=0
MEMORY_LIMIT="8g"
NO_CONTAINERS=0
CONTAINER_IMAGE_OVERRIDES=()
RATE_LIMIT=""
MOUNT_ARGS=()
MOUNT_RO_ARGS=()
KNOWLEDGE_LABELS=()
CYCLE_PROMPT=""
ONE_SHOT_PROMPT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --one-shot)
            MODE="one-shot"
            shift
            ;;
        --loop)
            MODE="loop"
            shift
            ;;
        --personalization)
            [[ $# -lt 2 ]] && error "--personalization requires a path argument" && exit 1
            PERSONALIZATION_DIR="$(realpath "$2")"
            [[ ! -d "${PERSONALIZATION_DIR}" ]] && error "--personalization: directory does not exist: ${PERSONALIZATION_DIR}" && exit 1
            for subdir in docs knowledge tasks audit; do
                [[ ! -d "${PERSONALIZATION_DIR}/${subdir}" ]] && \
                    warn "--personalization: missing subdirectory: ${PERSONALIZATION_DIR}/${subdir} (will be empty)"
            done
            shift 2
            ;;
        --project)
            [[ $# -lt 2 ]] && error "--project requires a name argument" && exit 1
            PROJECT_NAME="$2"
            shift 2
            ;;
        --agent)
            [[ $# -lt 2 ]] && error "--agent requires a name argument" && exit 1
            AGENT_NAME="$2"
            shift 2
            ;;
        --max-cycles)
            [[ $# -lt 2 ]] && error "--max-cycles requires a value" && exit 1
            MAX_CYCLES="$2"
            shift 2
            ;;
        --cooldown)
            [[ $# -lt 2 ]] && error "--cooldown requires a value" && exit 1
            COOLDOWN="$2"
            shift 2
            ;;
        --timeout)
            [[ $# -lt 2 ]] && error "--timeout requires a value" && exit 1
            TIMEOUT="$2"
            shift 2
            ;;
        --max-failures)
            [[ $# -lt 2 ]] && error "--max-failures requires a value" && exit 1
            MAX_CONSECUTIVE_FAILURES="$2"
            shift 2
            ;;
        --ollama-host)
            [[ $# -lt 2 ]] && error "--ollama-host requires a value" && exit 1
            OLLAMA_HOST="$2"
            shift 2
            ;;
        --local)
            USE_LOCAL=true
            shift
            ;;
        --model)
            [[ $# -lt 2 ]] && error "--model requires a value" && exit 1
            OLLAMA_MODEL="$2"
            shift 2
            ;;
        --ctx)
            [[ $# -lt 2 ]] && error "--ctx requires a value" && exit 1
            OLLAMA_CTX="$2"
            shift 2
            ;;
        --no-think)
            OLLAMA_NO_THINK=1
            shift
            ;;
        --knowledge)
            [[ $# -lt 2 ]] && error "--knowledge requires a label argument" && exit 1
            KNOWLEDGE_LABELS+=("$2")
            shift 2
            ;;
        --prompt)
            [[ $# -lt 2 ]] && error "--prompt requires a text argument" && exit 1
            ONE_SHOT_PROMPT="$2"
            shift 2
            ;;
        --cycle-prompt)
            [[ $# -lt 2 ]] && error "--cycle-prompt requires a name argument" && exit 1
            CYCLE_PROMPT="$2"
            shift 2
            ;;
        --mount)
            [[ $# -lt 2 ]] && error "--mount requires a path argument" && exit 1
            MOUNT_PATH="$(realpath "$2")"
            [[ ! -d "${MOUNT_PATH}" ]] && error "--mount: directory does not exist: ${MOUNT_PATH}" && exit 1
            MOUNT_ARGS+=("${MOUNT_PATH}")
            shift 2
            ;;
        --mount-ro)
            [[ $# -lt 2 ]] && error "--mount-ro requires a path argument" && exit 1
            MOUNT_PATH="$(realpath "$2")"
            [[ ! -d "${MOUNT_PATH}" ]] && error "--mount-ro: directory does not exist: ${MOUNT_PATH}" && exit 1
            MOUNT_RO_ARGS+=("${MOUNT_PATH}")
            shift 2
            ;;
        --ssh-key-dir)
            [[ $# -lt 2 ]] && error "--ssh-key-dir requires a value" && exit 1
            SSH_KEY_DIR="$(realpath "$2")"
            [[ ! -d "${SSH_KEY_DIR}" ]] && error "--ssh-key-dir: directory does not exist: ${SSH_KEY_DIR}" && exit 1
            shift 2
            ;;
        --ssh-key)
            [[ $# -lt 2 ]] && error "--ssh-key requires a value" && exit 1
            SSH_KEY_NAME="$2"
            shift 2
            ;;
        --gptel-fork)
            [[ $# -lt 2 ]] && error "--gptel-fork requires a path argument" && exit 1
            GPTEL_FORK_PATH="$(realpath "$2")"
            [[ ! -d "${GPTEL_FORK_PATH}" ]] && error "--gptel-fork: directory does not exist: ${GPTEL_FORK_PATH}" && exit 1
            [[ ! -f "${GPTEL_FORK_PATH}/gptel.el" ]] && error "--gptel-fork: gptel.el not found in: ${GPTEL_FORK_PATH}" && exit 1
            shift 2
            ;;
        --self-modification)
            SELF_MODIFICATION=1
            shift
            ;;
        --memory)
            [[ $# -lt 2 ]] && error "--memory requires a value (e.g. 8g, 4g)" && exit 1
            MEMORY_LIMIT="$2"
            shift 2
            ;;
        --no-containers)
            NO_CONTAINERS=1
            shift
            ;;
        --container-image)
            [[ $# -lt 2 ]] && error "--container-image requires a value (target:image)" && exit 1
            CONTAINER_IMAGE_OVERRIDES+=("$2")
            shift 2
            ;;
        --rate-limit)
            [[ $# -lt 2 ]] && error "--rate-limit requires a value (seconds)" && exit 1
            RATE_LIMIT="$2"
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

# Validate required arguments
if [[ -z "${PERSONALIZATION_DIR}" ]]; then
    error "--personalization is required. Specify the path to your personalization directory."
    echo ""
    usage
    exit 1
fi

# One-shot mode validation
if [[ "${MODE}" == "one-shot" ]]; then
    if [[ -z "${AGENT_NAME}" ]]; then
        error "--agent is required in --one-shot mode."
        echo ""
        usage
        exit 1
    fi
    if [[ -z "${ONE_SHOT_PROMPT}" ]]; then
        error "--prompt is required in --one-shot mode."
        echo ""
        usage
        exit 1
    fi
fi

# --prompt is only valid in one-shot mode
if [[ -n "${ONE_SHOT_PROMPT}" && "${MODE}" != "one-shot" ]]; then
    error "--prompt is only valid with --one-shot mode."
    echo ""
    usage
    exit 1
fi

if [[ -z "${PROJECT_NAME}" ]]; then
    error "--project is required. Specify a project name (e.g., iar, pentest, moto)."
    echo ""
    usage
    exit 1
fi

# Mode-specific validation
if [[ "${MODE}" == "loop" && -z "${AGENT_NAME}" ]]; then
    error "--agent is required in --loop mode."
    echo ""
    usage
    exit 1
fi

# =============================================================================
# Parse project config for mounts
# =============================================================================
PROJECT_FILE="${PERSONALIZATION_DIR}/projects/${PROJECT_NAME}.org"
PROJECT_MOUNT_ARGS=()
PROJECT_MOUNT_RO_ARGS=()

if [[ ! -f "${PROJECT_FILE}" ]]; then
    info "Project file not found: ${PROJECT_FILE}"
    info "Creating new project file for '${PROJECT_NAME}'..."
    mkdir -p "$(dirname "${PROJECT_FILE}")"
    cat > "${PROJECT_FILE}" <<EOF
#+KNOWLEDGE: iar/
#+TOOLS: list_directory read_file write_file append_file execute_code_local check_elisp read_task create_task write_subtask remove_task read_history send_telegram git_commit delegate reload_os reload_agent read_knowledge read_roadmap write_roadmap
#+OBJECTIVE: New project '${PROJECT_NAME}'. Edit this file to configure.
EOF
    info "Created: ${PROJECT_FILE}"
fi

# Parse #+MOUNTS from project file
# Format: space-separated list of path:mode pairs (e.g., /path/to/dir:rw /other:ro)
# :rw is default if no mode specified
if [[ -f "${PROJECT_FILE}" ]]; then
    while IFS= read -r line; do
        if [[ "${line}" =~ ^#\+MOUNTS:\ *(.*) ]]; then
            for entry in ${BASH_REMATCH[1]}; do
                # Split on : to get path and mode
                mount_path="${entry%%:*}"
                mount_mode="${entry##*:}"
                # Default to rw if no mode specified
                [[ "${mount_mode}" == "${mount_path}" ]] && mount_mode="rw"
                if [[ -n "${mount_path}" && -d "${mount_path}" ]]; then
                    real_path="$(realpath "${mount_path}")"
                    if [[ "${mount_mode}" == "ro" ]]; then
                        PROJECT_MOUNT_RO_ARGS+=("${real_path}")
                    else
                        PROJECT_MOUNT_ARGS+=("${real_path}")
                    fi
                    info "  Project mount: ${real_path} (${mount_mode})"
                elif [[ -n "${mount_path}" ]]; then
                    warn "  Project mount path does not exist: ${mount_path} (skipping)"
                fi
            done
        fi
    done < "${PROJECT_FILE}"
fi

# Parse #+CONTAINERS from project file
# Format: space-separated list of target names (e.g., pentest concepts life-org)
CONTAINER_TARGETS=()
if [[ -f "${PROJECT_FILE}" && "${NO_CONTAINERS}" -eq 0 ]]; then
    while IFS= read -r line; do
        if [[ "${line}" =~ ^#\+CONTAINERS:\ *(.*) ]]; then
            for target in ${BASH_REMATCH[1]}; do
                CONTAINER_TARGETS+=("${target}")
                info "  Container target: ${target}"
            done
        fi
    done < "${PROJECT_FILE}"
fi

# Apply container image overrides
declare -A CONTAINER_IMAGE_MAP
for override in "${CONTAINER_IMAGE_OVERRIDES[@]:-}"; do
    [[ -z "${override}" ]] && continue
    target_name="${override%%:*}"
    image_name="${override##*:}"
    CONTAINER_IMAGE_MAP["${target_name}"]="${image_name}"
    info "  Image override: ${target_name} -> ${image_name}"
done

# Warn about loop-only flags in interactive mode
if [[ "${MODE}" == "interactive" ]]; then
    [[ -n "${AGENT_NAME}" ]] && warn "--agent is ignored in interactive mode (load agents via C-c a inside Emacs)"
    [[ "${MAX_CYCLES}" -ne 1 ]] && warn "--max-cycles is ignored in interactive mode"
    [[ "${COOLDOWN}" -ne 60 ]] && warn "--cooldown is ignored in interactive mode"
    [[ "${TIMEOUT}" -ne 7200 ]] && warn "--timeout is ignored in interactive mode"
fi

# =============================================================================
# Derived values
# =============================================================================
SSH_KEY_NAME="${SSH_KEY_NAME:-emacboros_ed25519}"

if [[ "${MODE}" == "loop" ]]; then
    CONTAINER_NAME="${AGENT_NAME}-loop-$$"
    GIT_AUTHOR_NAME="${AGENT_NAME}-agent"
    GIT_AUTHOR_EMAIL="${AGENT_NAME}@emacboros.local"
elif [[ "${MODE}" == "one-shot" ]]; then
    CONTAINER_NAME="${AGENT_NAME}-oneshot-$$"
    GIT_AUTHOR_NAME="${AGENT_NAME}-agent"
    GIT_AUTHOR_EMAIL="${AGENT_NAME}@emacboros.local"
else
    CONTAINER_NAME="iar-interactive-$$"
    GIT_AUTHOR_NAME="emacboros"
    GIT_AUTHOR_EMAIL="emacboros@proton.me"
fi

# =============================================================================
# Ollama host resolution
# =============================================================================
if [[ "${USE_LOCAL}" == "true" ]]; then
    OLLAMA_HOST="localhost:11434"
    NET_OPTS="--network=host"
    info "Local mode: using Ollama at ${OLLAMA_HOST} with host networking"
else
    NET_OPTS="--network=host"
    info "Using Ollama at ${OLLAMA_HOST} with host networking"
fi

# =============================================================================
# Logging (loop and one-shot mode)
# =============================================================================
if [[ "${MODE}" == "loop" || "${MODE}" == "one-shot" ]]; then
    # Nested layout (matches LAST-CYCLE.txt home): audit/iar/<agent>/
    if [[ "${MODE}" == "loop" ]]; then
        LOG_FILE="${PERSONALIZATION_DIR}/audit/iar/${AGENT_NAME}/cycle-$(date +%Y-%m-%d).log"
    else
        LOG_FILE="${PERSONALIZATION_DIR}/audit/iar/${AGENT_NAME}/oneshot-$(date +%Y-%m-%d).log"
    fi
    mkdir -p "$(dirname "${LOG_FILE}")"
else
    LOG_FILE="/dev/null"
fi

log() {
    if [[ "${MODE}" == "one-shot" ]]; then
        echo -e "$@" >> "${LOG_FILE}"
    elif [[ "${MODE}" == "loop" ]]; then
        echo -e "$@" | tee -a "${LOG_FILE}"
    else
        echo -e "$@"
    fi
}

# --- Telegram helpers (loop mode only) ---

tg_send() {
    [[ "${MODE}" != "loop" ]] && return
    local message="$1"
    if [[ -n "${AGENT_TELEGRAM_BOT_TOKEN:-}" && -n "${AGENT_TELEGRAM_CHAT_ID:-}" ]]; then
        curl -s -m 10 -X POST \
            "https://api.telegram.org/bot${AGENT_TELEGRAM_BOT_TOKEN}/sendMessage" \
            -H "Content-Type: application/json" \
            -d "$(jq -n --arg chat_id "$AGENT_TELEGRAM_CHAT_ID" \
                       --arg text "$message" \
                       '{chat_id: $chat_id, text: $text}')" \
            > /dev/null 2>&1 || true
    fi
}

# --- Pre-flight: check Ollama is reachable ---
check_ollama() {
    local host="$1"
    local out
    # Command substitution, NOT a /dev/null redirect: if the host's
    # /dev/null is broken (2026-09-01 incident), the redirect fails
    # before curl runs and the check reports "unreachable" -- the
    # error message lies about the layer.
    out="$(curl -fsS -m 5 "http://${host}/api/tags" 2>&1)" || return 1
    return 0
}

# --- Clean up stale container ---
cleanup_container() {
    if podman ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
        warn "Removing stale container: ${CONTAINER_NAME}"
        podman rm -f "${CONTAINER_NAME}" > /dev/null 2>&1 || true
    fi
}

# --- Reset working tree on failure (loop mode only) ---
reset_worktree() {
    # c137 correction (aria, 2026-09-09): c136 misattributed the
    # root-owned-file writer. iar.sh in loop mode runs as NACHO
    # (aria-cycle.service User=nacho, rootless podman: container root
    # == host nacho), NOT as host root. runuser fails for non-root
    # ("may not be used by non-root users"), so c136's runuser branch
    # silently no-op'd (|| true) and reset_worktree did NOTHING after
    # failed cycles. The pre-c136 code was correct for this path.
    # The real root-owned-file writer remains unidentified (heal log
    # is the only witness; see aria c137 journal). If we ever DO run
    # as root here, run as the repo owner via runuser; otherwise run
    # git directly and WARN LOUDLY if the reset fails (law 3: silent
    # error swallowing is the enemy).
    [[ "${MODE}" != "loop" ]] && return
    info "Resetting working tree to clean state"
    local me rc
    me="$(id -un 2>/dev/null || echo root)"
    if [ "${me}" = "root" ]; then
        local owner
        owner=$(stat -c %U "${REPO_DIR}" 2>/dev/null || echo "")
        if [ -n "$owner" ] && [ "$owner" != "root" ] && command -v runuser >/dev/null 2>&1; then
            runuser -u "$owner" -- git -C "${REPO_DIR}" checkout . 2>&1 || warn "reset_worktree: checkout as $owner failed"
            runuser -u "$owner" -- git -C "${REPO_DIR}" clean -fd emacs.d/ 2>&1 || warn "reset_worktree: clean as $owner failed"
            return
        fi
    fi
    git -C "${REPO_DIR}" checkout . 2>&1 || { rc=$?; warn "reset_worktree: git checkout failed rc=$rc (user $me) -- tree stays dirty"; }
    git -C "${REPO_DIR}" clean -fd emacs.d/ 2>&1 || { rc=$?; warn "reset_worktree: git clean failed rc=$rc (user $me)"; }
}

# =============================================================================
# Last-cycle status (failure-first protocol)
# =============================================================================
# Written after EVERY cycle run (success or failure). The cycle
# prompt's step 0 reads this file: if the last cycle failed,
# root-causing and fixing that IS the next cycle's work -- before
# any self-improvement thread. Priority #1 (Nacho, 2026-09-03):
# cycles must run without failures; a failure left unfixed is the
# next failure's cause.
LAST_CYCLE_FILE="${PERSONALIZATION_DIR}/audit/iar/${AGENT_NAME}/LAST-CYCLE.txt"

write_last_cycle() {
    local status="$1"   # ok | failed
    local exit_code="$2"
    local detail="$3"
    mkdir -p "$(dirname "${LAST_CYCLE_FILE}")" 2>/dev/null || true
    {
        echo "status: ${status}"
        echo "exit: ${exit_code}"
        echo "agent: ${AGENT_NAME}"
        echo "ended: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo "detail: ${detail}"
    } > "${LAST_CYCLE_FILE}" 2>/dev/null || true
}

# =============================================================================
# Multi-container orchestration
# =============================================================================
# Starts purpose-specific containers alongside the Emacs container.
# Each container gets a shared workspace at /workspace.
# Containers are named iar-<target>-<PID> to avoid collisions.
# Cleanup happens via trap on exit.

SESSION_ID=$$
SIDECAR_CONTAINERS=()
SHARED_WORKSPACE=""

# Network policy per container type
container_network_opts() {
    local target="$1"
    case "${target}" in
        pentest)
            # Outbound internet access
            echo "--network=bridge"
            ;;
        concepts|life-org)
            # No outbound internet
            echo "--network=none"
            ;;
        *)
            # Default: bridge (outbound allowed)
            echo "--network=bridge"
            ;;
    esac
}

# Resolve image name for a target
container_image_name() {
    local target="$1"
    # Check for override
    if [[ -n "${CONTAINER_IMAGE_MAP[${target}]:-}" ]]; then
        echo "${CONTAINER_IMAGE_MAP[${target}]}"
    else
        echo "iar-${target}"
    fi
}

# Start a single sidecar container
start_sidecar() {
    local target="$1"
    local image
    image=$(container_image_name "${target}")
    local cname="iar-${target}-${SESSION_ID}"
    local net_opts
    net_opts=$(container_network_opts "${target}")

    # Check if image exists
    if ! podman image exists "${image}" 2>/dev/null; then
        warn "Container image '${image}' not found -- skipping ${target} container"
        warn "Build it with: podman build -t ${image} -f containers/images/${target}/Containerfile"
        return 1
    fi

    # Start the container with shared workspace
    podman run -d \
        --name "${cname}" \
        --read-only \
        --memory="${MEMORY_LIMIT}" \
        --security-opt no-new-privileges \
        --cap-drop=all \
        ${net_opts} \
        --tmpfs /tmp:rw,size=256m \
        --tmpfs /run:rw,size=64m \
        -v "${SHARED_WORKSPACE}:/workspace:z" \
        "${image}" 2>&1 || {
            error "Failed to start ${target} container (${cname})"
            return 1
        }

    SIDECAR_CONTAINERS+=("${cname}")
    info "  Started: ${cname} (image: ${image}, network: ${net_opts})"
    return 0
}

# Start all sidecar containers for the session
start_containers() {
    if [[ "${NO_CONTAINERS}" -eq 1 ]]; then
        info "Containers: disabled (--no-containers)"
        return 0
    fi
    if [[ ${#CONTAINER_TARGETS[@]} -eq 0 ]]; then
        return 0
    fi

    info "Starting ${#CONTAINER_TARGETS[@]} sidecar container(s)..."

    # Create shared workspace directory
    SHARED_WORKSPACE=$(mktemp -d "/tmp/iar-workspace-XXXXXX")
    info "  Shared workspace: ${SHARED_WORKSPACE}"

    # Start each container
    for target in "${CONTAINER_TARGETS[@]}"; do
        start_sidecar "${target}"
    done
}

# Stop and remove all sidecar containers
stop_containers() {
    for cname in "${SIDECAR_CONTAINERS[@]:-}"; do
        [[ -z "${cname}" ]] && continue
        info "  Stopping: ${cname}"
        podman rm -f "${cname}" > /dev/null 2>&1 || true
    done
    SIDECAR_CONTAINERS=()

    # Clean up shared workspace
    if [[ -n "${SHARED_WORKSPACE}" && -d "${SHARED_WORKSPACE}" ]]; then
        rm -rf "${SHARED_WORKSPACE}" 2>/dev/null || true
        SHARED_WORKSPACE=""
    fi
}

# Build container env vars for build_podman_args
container_env_vars() {
    if [[ ${#SIDECAR_CONTAINERS[@]} -eq 0 ]]; then
        return
    fi

    for cname in "${SIDECAR_CONTAINERS[@]}"; do
        # Extract target from container name: iar-<target>-<PID>
        local target
        target=$(echo "${cname}" | sed "s/^iar-//; s/-${SESSION_ID}$//")
        local env_var="IAR_CONTAINER_$(echo "${target}" | tr '[:lower:]' '[:upper:]')"
        echo "-e ${env_var}=${cname}"
    done

    # Shared workspace path
    if [[ -n "${SHARED_WORKSPACE}" ]]; then
        echo "-e IAR_SHARED_WORKSPACE=/workspace"
        echo "-v ${SHARED_WORKSPACE}:/workspace:z"
    fi
}

# =============================================================================
# Build dynamic mount arguments
# =============================================================================
DYNAMIC_MOUNT_OPTS=()

for path in "${MOUNT_ARGS[@]:-}"; do
    [[ -z "${path}" ]] && continue
    DYNAMIC_MOUNT_OPTS+=("-v" "${path}:${path}:z")
    info "Mounting read-write: ${path}"
done

for path in "${MOUNT_RO_ARGS[@]:-}"; do
    [[ -z "${path}" ]] && continue
    DYNAMIC_MOUNT_OPTS+=("-v" "${path}:${path}:ro,z")
    info "Mounting read-only:  ${path}"
done

# Build IAR_EXTRA_MOUNTS env var for mount awareness.
# Format: "path:rw,path:ro" -- comma-separated, passed to container so
# agents know what extra directories are available without being told.
EXTRA_MOUNTS_ENV=""
if [[ ${#MOUNT_ARGS[@]} -gt 0 || ${#MOUNT_RO_ARGS[@]} -gt 0 ]]; then
    MOUNT_PAIRS=()
    for path in "${MOUNT_ARGS[@]:-}"; do
        [[ -z "${path}" ]] && continue
        MOUNT_PAIRS+=("${path}:rw")
    done
    for path in "${MOUNT_RO_ARGS[@]:-}"; do
        [[ -z "${path}" ]] && continue
        MOUNT_PAIRS+=("${path}:ro")
    done
    EXTRA_MOUNTS_ENV=$(IFS=','; echo "${MOUNT_PAIRS[*]}")
fi

# =============================================================================
# SSH key availability
# =============================================================================
SSH_MOUNT_OPTS=()
if [[ -f "${SSH_KEY_DIR}/${SSH_KEY_NAME}" ]]; then
    SSH_MOUNT_OPTS+=(
        "-v" "${SSH_KEY_DIR}/${SSH_KEY_NAME}:/root/.ssh/id_ed25519:ro,z"
        "-v" "${SSH_KEY_DIR}/${SSH_KEY_NAME}.pub:/root/.ssh/id_ed25519.pub:ro,z"
        "-v" "${SSH_KEY_DIR}/known_hosts:/root/.ssh/known_hosts:ro,z"
    )
    info "SSH key: ${SSH_KEY_DIR}/${SSH_KEY_NAME}"
else
    warn "SSH key not found: ${SSH_KEY_DIR}/${SSH_KEY_NAME} -- git push disabled (pull still works)"
fi

# =============================================================================
# Knowledge labels for Emacs eval (loop mode)
# =============================================================================
KNOWLEDGE_EVAL=""
if [[ ${#KNOWLEDGE_LABELS[@]} -gt 0 ]]; then
    LABELS_LISP=""
    for label in "${KNOWLEDGE_LABELS[@]}"; do
        LABELS_LISP+="\"${label}\" "
    done
    KNOWLEDGE_EVAL=":knowledge (list ${LABELS_LISP})"
fi


# =============================================================================
# Cycle prompt override for Emacs eval (loop mode)
# =============================================================================
CYCLE_PROMPT_EVAL=""
if [[ -n "${CYCLE_PROMPT}" ]]; then
    CYCLE_PROMPT_EVAL=":cycle \"${CYCLE_PROMPT}\""
fi
# =============================================================================
# Gptel fork mount
# =============================================================================
GPTEL_FORK_OPTS=""
if [[ -n "${GPTEL_FORK_PATH}" ]]; then
    GPTEL_FORK_OPTS="-v ${GPTEL_FORK_PATH}:/root/.emacs.d/gptel-fork:z -e EMACBOROS_GPTEL_FORK_PATH=/root/.emacs.d/gptel-fork"
    info "Gptel fork: ${GPTEL_FORK_PATH} -> /root/.emacs.d/gptel-fork (writable)"
else
    info "Gptel fork: not specified (using ELPA package)"
fi

# =============================================================================
# Personalization repo mount
# =============================================================================
# Mount the entire personalization dir at /root/personalization.
# This is the single mount point for docs/, knowledge/, tasks/, audit/.
# Agents access these at /root/personalization/docs, /root/personalization/knowledge, etc.
# Git operations (git_commit) use /root/personalization as the repo root.
PERSONALIZATION_MOUNT_OPTS=("-v" "${PERSONALIZATION_DIR}:/root/personalization:z")
info "Personalization repo: ${PERSONALIZATION_DIR} -> /root/personalization (writable)"

# =============================================================================
# Self-modification i.ar mount
# =============================================================================
# In self-modification mode, mount the repo at /root/i.ar/ so agents can
# edit code. Without self-modification, mount it read-only for reference.
if [[ "${SELF_MODIFICATION}" -eq 1 ]]; then
    IAR_MOUNT_OPTS=("-v" "${REPO_DIR}/:/root/i.ar/:z")
    info "i.ar repo: ${REPO_DIR} -> /root/i.ar/ (writable, self-modification)"
else
    IAR_MOUNT_OPTS=("-v" "${REPO_DIR}/:/root/i.ar/:ro,z")
    info "i.ar repo: ${REPO_DIR} -> /root/i.ar/ (read-only)"
fi

# =============================================================================
# Build common Podman arguments
# =============================================================================
build_podman_args() {
    # Echoes common Podman arguments shared by interactive and loop modes.
    # Callers add: -it (interactive only), --entrypoint + command (loop only),
    # TERM=dumb (loop only), and the image name.

    echo \
        --rm \
        --read-only \
        --name "${CONTAINER_NAME}" \
        --memory="${MEMORY_LIMIT}" \
        --security-opt no-new-privileges \
        --cap-drop=all \
        --cap-add=NET_RAW \
        --cap-add=NET_BIND_SERVICE \
        ${NET_OPTS} \
        -e "EMACBOROS_OLLAMA_HOST=${OLLAMA_HOST}" \
        $([[ -n "${OLLAMA_MODEL}" ]] && echo "-e EMACBOROS_OLLAMA_MODEL=${OLLAMA_MODEL}") \
        $([[ -n "${OLLAMA_CTX}" ]] && echo "-e EMACBOROS_OLLAMA_CTX=${OLLAMA_CTX}") \
        $([[ "${OLLAMA_NO_THINK:-0}" -eq 1 ]] && echo "-e EMACBOROS_OLLAMA_NO_THINK=1") \
        -e "AGENT_TELEGRAM_BOT_TOKEN=${AGENT_TELEGRAM_BOT_TOKEN:-}" \
        -e "AGENT_TELEGRAM_CHAT_ID=${AGENT_TELEGRAM_CHAT_ID:-}" \
        $([[ -n "${GPTEL_FORK_PATH}" ]] && echo "-v ${GPTEL_FORK_PATH}:/root/.emacs.d/gptel-fork:z -e EMACBOROS_GPTEL_FORK_PATH=/root/.emacs.d/gptel-fork") \
        $([[ "${SELF_MODIFICATION:-0}" -eq 1 ]] && echo "-e EMACBOROS_SELF_MODIFICATION=1") \
        $([[ -n "${RATE_LIMIT}" ]] && echo "-e IAR_RATE_LIMIT=${RATE_LIMIT}") \
        -e "IAR_PROJECT=${PROJECT_NAME}" \
        $([[ -n "${EXTRA_MOUNTS_ENV}" ]] && echo "-e IAR_EXTRA_MOUNTS=${EXTRA_MOUNTS_ENV}") \
        -e "LANG=C.utf8" \
        --tmpfs /tmp:rw,size=256m \
        --tmpfs /run:rw,size=64m \
        --tmpfs /var/tmp:rw,size=64m \
        -v "${REPO_DIR}/emacs.d:/root/.emacs.d:z" \
        -v "${REPO_DIR}/metaconfig:/root/.emacs.d/metaconfig:z" \
        -v "${REPO_DIR}/prompts:/root/.emacs.d/agents.d:z" \
        "${IAR_MOUNT_OPTS[@]}" \
        "${SSH_MOUNT_OPTS[@]}" \
        "${DYNAMIC_MOUNT_OPTS[@]}" \
        "${PERSONALIZATION_MOUNT_OPTS[@]}" \
        $([[ ${#PROJECT_MOUNT_ARGS[@]} -gt 0 ]] && for p in "${PROJECT_MOUNT_ARGS[@]}"; do echo "-v ${p}:${p}:z"; done) \
        $([[ ${#PROJECT_MOUNT_RO_ARGS[@]} -gt 0 ]] && for p in "${PROJECT_MOUNT_RO_ARGS[@]}"; do echo "-v ${p}:${p}:ro,z"; done) \
        -e "GIT_AUTHOR_NAME=${GIT_AUTHOR_NAME}" \
        -e "GIT_AUTHOR_EMAIL=${GIT_AUTHOR_EMAIL}" \
        -e "GIT_COMMITTER_NAME=${GIT_AUTHOR_NAME}" \
        -e "GIT_COMMITTER_EMAIL=${GIT_AUTHOR_EMAIL}" \
        -e "GIT_PAGER=cat" \
        $(container_env_vars)
}

# =============================================================================
# Interactive mode
# =============================================================================
run_interactive() {
    info "=========================================="
    info "i.ar Interactive Session"
    info "  Personalization: ${PERSONALIZATION_DIR}"
    info "  Ollama: ${OLLAMA_HOST}"
    info "  Model: ${OLLAMA_MODEL:-glm-5.3:cloud (default)}"
    info "  Context: ${OLLAMA_CTX:-1048576 (default)}"
    if [[ "${OLLAMA_NO_THINK:-0}" -eq 1 ]]; then
        info "  Thinking: disabled (think:false)"
    fi
    if [[ "${SELF_MODIFICATION}" -eq 1 ]]; then
        info "  Self-modification: ENABLED"
    else
        info "  Self-modification: disabled"
    fi
    info "  Container: ${CONTAINER_NAME}"
    if [[ ${#CONTAINER_TARGETS[@]} -gt 0 ]]; then
        info "  Containers: ${CONTAINER_TARGETS[*]}"
    fi
    info "=========================================="

    # Start sidecar containers
    start_containers
    trap stop_containers EXIT

    # shellcheck disable=SC2086
    podman run -it \
        $(build_podman_args) \
        "${IMAGE_NAME}" && \
        info "Session ended" || \
        error "Container failed to start"

    # Cleanup sidecar containers
    stop_containers
    trap - EXIT
}

# =============================================================================
# Loop mode -- run one cycle
# =============================================================================
run_cycle() {
    info "Starting ${AGENT_NAME} cycle ${CYCLE}/${MAX_CYCLES} (timeout: ${TIMEOUT}s)"

    # Start sidecar containers for this cycle
    start_containers

    # shellcheck disable=SC2086
    podman run \
        $(build_podman_args) \
        -e "TERM=dumb" \
        --entrypoint /bin/bash \
        "${IMAGE_NAME}" \
        -c "preflight.sh && emacs --batch -l /root/.emacs.d/init.el --eval '(iar-run-cycle :agent \"${AGENT_NAME}\" :timeout ${TIMEOUT} :self-modification ${SELF_MODIFICATION:-0} ${KNOWLEDGE_EVAL} ${CYCLE_PROMPT_EVAL})'" 2>&1 | tee -a "${LOG_FILE}"

    local rc=${PIPESTATUS[0]}

    # Cleanup sidecar containers after each cycle
    stop_containers

    return ${rc}
}
# =============================================================================
# One-shot mode
# =============================================================================
run_one_shot() {
    info "=========================================="
    info "i.ar One-Shot"
    info "  Agent: ${AGENT_NAME}"
    info "  Personalization: ${PERSONALIZATION_DIR}"
    info "  Timeout: ${TIMEOUT}s"
    info "  Ollama: ${OLLAMA_HOST}"
    info "  Model: ${OLLAMA_MODEL:-glm-5.3:cloud (default)}"
    info "  Context: ${OLLAMA_CTX:-1048576 (default)}"
    if [[ "${OLLAMA_NO_THINK:-0}" -eq 1 ]]; then
        info "  Thinking: disabled (think:false)"
    fi
    if [[ "${SELF_MODIFICATION}" -eq 1 ]]; then
        info "  Self-modification: ENABLED"
    else
        info "  Self-modification: disabled"
    fi
    info "  Container: ${CONTAINER_NAME}"
    if [[ ${#CONTAINER_TARGETS[@]} -gt 0 ]]; then
        info "  Containers: ${CONTAINER_TARGETS[*]}"
    fi
    info "  Log: ${LOG_FILE}"
    info "=========================================="

    if ! check_ollama "${OLLAMA_HOST}"; then
        error "Ollama unreachable at ${OLLAMA_HOST}"
        exit 1
    fi

    cleanup_container

    # Start sidecar containers
    start_containers
    trap stop_containers EXIT

    info "Starting one-shot execution (timeout: ${TIMEOUT}s)"

    # shellcheck disable=SC2086
    podman run \
        $(build_podman_args) \
        -e "TERM=dumb" \
        -e "IAR_ONE_SHOT_PROMPT=${ONE_SHOT_PROMPT}" \
        --entrypoint /bin/bash \
        "${IMAGE_NAME}" \
        -c "preflight.sh && emacs --batch -l /root/.emacs.d/init.el --eval '(iar-run-one-shot :agent \"${AGENT_NAME}\" :timeout ${TIMEOUT} :self-modification ${SELF_MODIFICATION:-0})'" 2>>"${LOG_FILE}"

    local exit_code=$?

    # Cleanup sidecar containers
    stop_containers
    trap - EXIT

    info "One-shot exited with code ${exit_code}"
    return ${exit_code}
}
# =============================================================================
# Main

# =============================================================================
if [[ "${MODE}" == "interactive" ]]; then
    run_interactive
    exit $?
fi

if [[ "${MODE}" == "one-shot" ]]; then
    run_one_shot
    exit $?
fi

# =============================================================================

# =============================================================================
# Loop mode -- cycle management
# =============================================================================
CYCLE=0
SUCCESSES=0
FAILURES=0
CONSECUTIVE_FAILURES=0
LOOP_START=$(date +%s)
LOOP_REASON=""

info "=========================================="
info "i.ar Agent Loop"
info "  Agent: ${AGENT_NAME}"
info "  Personalization: ${PERSONALIZATION_DIR}"
info "  Max cycles: ${MAX_CYCLES}"
info "  Cooldown: ${COOLDOWN}s"
info "  Per-cycle timeout: ${TIMEOUT}s"
info "  Max consecutive failures: ${MAX_CONSECUTIVE_FAILURES}"
info "  Ollama: ${OLLAMA_HOST}"
info "  Model: ${OLLAMA_MODEL:-glm-5.3:cloud (default)}"
info "  Context: ${OLLAMA_CTX:-1048576 (default)}"
if [[ "${OLLAMA_NO_THINK:-0}" -eq 1 ]]; then
    info "  Thinking: disabled (think:false)"
fi
if [[ -f "${SSH_KEY_DIR}/${SSH_KEY_NAME}" ]]; then
    info "  SSH key: ${SSH_KEY_DIR}/${SSH_KEY_NAME}"
else
    info "  SSH key: (none -- git push disabled)"
fi
info "  Log: ${LOG_FILE}"
if [[ ${#KNOWLEDGE_LABELS[@]} -gt 0 ]]; then
    info "  Docs: ${KNOWLEDGE_LABELS[*]}"
else
    info "  Docs: iar/ (default)"
fi
info "=========================================="

tg_send "*${AGENT_NAME^} Loop Started*
Max cycles: ${MAX_CYCLES}
Cooldown: ${COOLDOWN}s
Timeout: ${TIMEOUT}s per cycle
Ollama: ${OLLAMA_HOST}
Model: ${OLLAMA_MODEL:-glm-5.3:cloud}
Thinking: $( [[ "${OLLAMA_NO_THINK:-0}" -eq 1 ]] && echo "disabled" || echo "enabled (default)" )"

while [[ ${CYCLE} -lt ${MAX_CYCLES} ]]; do
    CYCLE=$((CYCLE + 1))
    CYCLE_START=$(date +%s)

    log ""
    log "${BLUE}[INF][$(timestamp)]${NC} --- Cycle ${CYCLE}/${MAX_CYCLES} ---"

    # Pre-flight: Ollama check
    if ! check_ollama "${OLLAMA_HOST}"; then
        error "Ollama unreachable at ${OLLAMA_HOST} -- skipping cycle ${CYCLE}"
        log "${RED}[ERR][$(timestamp)]${NC} Ollama unreachable, skipping cycle ${CYCLE}"
        FAILURES=$((FAILURES + 1))
        CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))

        if [[ ${CONSECUTIVE_FAILURES} -ge ${MAX_CONSECUTIVE_FAILURES} ]]; then
            error "Reached ${MAX_CONSECUTIVE_FAILURES} consecutive failures -- stopping loop"
            log "${RED}[ERR][$(timestamp)]${NC} Stopping loop: ${MAX_CONSECUTIVE_FAILURES} consecutive failures"
            tg_send "*${AGENT_NAME^} Loop: STOPPED*
Reason: ${MAX_CONSECUTIVE_FAILURES} consecutive failures (Ollama unreachable)
Cycles: ${CYCLE}/${MAX_CYCLES}
Successes: ${SUCCESSES}
Failures: ${FAILURES}"
            exit 1
        fi

        warn "Waiting ${COOLDOWN}s before retry..."
        sleep ${COOLDOWN}
        continue
    fi

    # Reset consecutive failures -- Ollama is back
    CONSECUTIVE_FAILURES=0

    # Clean up any stale container from previous cycle
    cleanup_container

    # Pull BEFORE assembly (relay 0034, session XV ratified):
    # prompt assembly reads this checkout at cycle start -- a stale
    # checkout injects one-cycle-old memory (the 09-10 continuo
    # stale-premise loop, ~13.4M tokens). The pull must precede
    # assembly, not ride inside the cycle.
    # runuser needs root; the service normally runs AS the owner
    # (nacho, rootless podman) -- only escalate when actually root.
    if [ "$(id -u)" = "0" ]; then
        powner=$(stat -c %U "${PERSONALIZATION_DIR}" 2>/dev/null || echo "")
        if [ -n "$powner" ] && [ "$powner" != "root" ] && command -v runuser >/dev/null 2>&1; then
            if ! runuser -u "$powner" -- git -C "${PERSONALIZATION_DIR}" pull --ff-only >> "${LOG_FILE}" 2>&1; then
                warn "pull-before-assembly: ff-only pull failed (diverged or offline) -- cycle proceeds on local state"
            fi
        elif ! git -C "${PERSONALIZATION_DIR}" pull --ff-only >> "${LOG_FILE}" 2>&1; then
            warn "pull-before-assembly: ff-only pull failed (diverged or offline) -- cycle proceeds on local state"
        fi
    elif ! git -C "${PERSONALIZATION_DIR}" pull --ff-only >> "${LOG_FILE}" 2>&1; then
        warn "pull-before-assembly: ff-only pull failed (diverged or offline) -- cycle proceeds on local state"
    fi

    # Reset working tree BEFORE the cycle (relay 0040, aria c190):
    # two agents share one checkout; either agent's uncommitted edits
    # are the other's floor. The failure-branch reset (below) only
    # heals after a death -- the corruption can also sit in the tree
    # from a SIBLING's cycle that parked believing DONE (c190: nested
    # defvar passed grep, killed the next cycle at init load). A
    # clean floor before every start is the structural fix.
    reset_worktree

    # Run one cycle
    set +e
    run_cycle
    CYCLE_EXIT=$?
    set -e

    CYCLE_END=$(date +%s)
    CYCLE_ELAPSED=$((CYCLE_END - CYCLE_START))

    if [[ ${CYCLE_EXIT} -eq 0 ]]; then
        SUCCESSES=$((SUCCESSES + 1))
        log "${GREEN}[INF][$(timestamp)]${NC} Cycle ${CYCLE} succeeded in ${CYCLE_ELAPSED}s (exit 0)"
        write_last_cycle ok 0 "cycle ${CYCLE} ok in ${CYCLE_ELAPSED}s"
        tg_send "Cycle ${CYCLE}/${MAX_CYCLES}: *SUCCESS* (${CYCLE_ELAPSED}s)
Successes: ${SUCCESSES} | Failures: ${FAILURES}"
    elif [[ ${CYCLE_EXIT} -eq 2 ]]; then
        SUCCESSES=$((SUCCESSES + 1))
        log "${GREEN}[INF][$(timestamp)]${NC} Cycle ${CYCLE} completed task in ${CYCLE_ELAPSED}s (exit 2 -- loop stop)"
        write_last_cycle ok 2 "cycle ${CYCLE} task complete in ${CYCLE_ELAPSED}s"
        tg_send "Cycle ${CYCLE}/${MAX_CYCLES}: *TASK COMPLETE* (${CYCLE_ELAPSED}s)
Successes: ${SUCCESSES} | Failures: ${FAILURES}
Loop stopping -- task finished."
        log "${BLUE}[INF][$(timestamp)]${NC} Task complete, stopping loop."
        LOOP_REASON="task complete"
        break
    else
        FAILURES=$((FAILURES + 1))
        CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
        log "${RED}[ERR][$(timestamp)]${NC} Cycle ${CYCLE} failed in ${CYCLE_ELAPSED}s (exit ${CYCLE_EXIT})"
        write_last_cycle failed "${CYCLE_EXIT}" "cycle ${CYCLE} failed in ${CYCLE_ELAPSED}s, exit ${CYCLE_EXIT}; next cycle: fix this first (failure-first protocol)"
        # Per-failure telegram REMOVED (2026-09-03, Nacho): 100
        # messages on Sep 2 was spam. The hourly failure digest
        # (agent-failure-notify.sh) carries the signal; the
        # loop-stop telegram below still fires on hard stops.

        # Reset working tree to clean state so next cycle starts fresh
        reset_worktree

        if [[ ${CONSECUTIVE_FAILURES} -ge ${MAX_CONSECUTIVE_FAILURES} ]]; then
            error "Reached ${MAX_CONSECUTIVE_FAILURES} consecutive failures -- stopping loop"
            log "${RED}[ERR][$(timestamp)]${NC} Stopping loop: ${MAX_CONSECUTIVE_FAILURES} consecutive failures"
            tg_send "*${AGENT_NAME^} Loop: STOPPED*
Reason: ${MAX_CONSECUTIVE_FAILURES} consecutive cycle failures
Cycles: ${CYCLE}/${MAX_CYCLES}
Successes: ${SUCCESSES}
Failures: ${FAILURES}"
            exit 1
        fi
    fi

    # Cooldown between cycles (skip on last cycle)
    if [[ ${CYCLE} -lt ${MAX_CYCLES} ]]; then
        info "Cooldown: ${COOLDOWN}s before next cycle"
        sleep ${COOLDOWN}
    fi
done

# =============================================================================
# Loop complete
# =============================================================================
LOOP_END=$(date +%s)
LOOP_ELAPSED=$((LOOP_END - LOOP_START))
HOURS=$((LOOP_ELAPSED / 3600))
MINS=$(((LOOP_ELAPSED % 3600) / 60))

info "=========================================="
info "Agent Loop complete"
info "  Agent: ${AGENT_NAME}"
info "  Total cycles: ${CYCLE}"
info "  Successes: ${SUCCESSES}"
info "  Failures: ${FAILURES}"
info "  Elapsed: ${HOURS}h ${MINS}m"
info "=========================================="

tg_send "*${AGENT_NAME^} Loop Complete*
Cycles: ${CYCLE}/${MAX_CYCLES}
Successes: ${SUCCESSES}
Failures: ${FAILURES}
Elapsed: ${HOURS}h ${MINS}m
Reason: ${LOOP_REASON:-max cycles reached}"

# A heartbeat that did nothing but fail must not report success to
# systemd: OnFailure only fires on non-zero exit (2026-09-01: 12
# skipped cycles exited 0, hook never fired). Conservative: partial
# success still exits 0 to avoid noise.
if [[ ${SUCCESSES} -eq 0 && ${FAILURES} -gt 0 ]]; then
    error "Loop finished with 0 successes / ${FAILURES} failures -- exiting non-zero"
    exit 1
fi

exit 0
