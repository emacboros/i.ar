#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# i.ar Status -- Snapshot of running agents, recent activity, and pending tasks
#
# Usage: ./utils/iar.sh --status
#        ./utils/iar.sh --status --lines 10
#        ./utils/iar.sh --status --agent darwin
# =============================================================================

REPO_DIR="$(realpath "$(dirname "${BASH_SOURCE[0]}")/..")"
source "${REPO_DIR}/metaconfig/header.sh" 2>/dev/null || {
    # Fallback if header.sh not available (e.g. running from container)
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'
    NC='\033[0m'
    timestamp() { date +"%Y-%m-%d %H:%M:%S"; }
    info() { echo -e "${BLUE}[INF][$(timestamp)]${NC} $1"; }
    warn() { echo -e "${YELLOW}[WRN][$(timestamp)]${NC} $1"; }
    error() { echo -e "${RED}[ERR][$(timestamp)]${NC} $1"; }
}

# =============================================================================
# Defaults
# =============================================================================
STATUS_LINES=5
STATUS_AGENT=""
PERSONALIZATION_DIR="${EMACBOROS_PERSONALIZATION_DIR:-}"

# =============================================================================
# Parse arguments (only --status-related subset)
# =============================================================================
while [[ $# -gt 0 ]]; do
    case "$1" in
        --status)
            shift  # consume the flag itself
            ;;
        --lines)
            [[ $# -lt 2 ]] && error "--lines requires a value" && exit 1
            STATUS_LINES="$2"
            shift 2
            ;;
        --agent)
            [[ $# -lt 2 ]] && error "--agent requires a value" && exit 1
            STATUS_AGENT="$2"
            shift 2
            ;;
        --personalization)
            [[ $# -lt 2 ]] && error "--personalization requires a path" && exit 1
            PERSONALIZATION_DIR="$(realpath "$2")"
            shift 2
            ;;
        --help|-h)
            cat <<EOF
Usage: iar.sh --status [OPTIONS]

Options:
  --lines N            Number of recent log entries to show per agent (default: 5)
  --agent NAME         Show only one agent's activity
  --personalization PATH
                       Path to personalization directory (default: \$EMACBOROS_PERSONALIZATION_DIR)
EOF
            exit 0
            ;;
        *)
            shift  # ignore unknown flags (could be called from iar.sh dispatcher)
            ;;
    esac
done

# =============================================================================
# Resolve paths
# =============================================================================
if [[ -z "${PERSONALIZATION_DIR}" ]]; then
    # Try common locations
    for candidate in "${HOME}/repos/iar-personalization" "${REPO_DIR}/personalization"; do
        if [[ -d "${candidate}/audit" ]]; then
            PERSONALIZATION_DIR="${candidate}"
            break
        fi
    done
fi

if [[ -z "${PERSONALIZATION_DIR}" ]] || [[ ! -d "${PERSONALIZATION_DIR}/audit" ]]; then
    error "Could not find personalization directory."
    error "Set EMACBOROS_PERSONALIZATION_DIR or use --personalization PATH"
    exit 1
fi

AUDIT_DIR="${PERSONALIZATION_DIR}/audit"
TASKS_DIR="${PERSONALIZATION_DIR}/tasks"

# =============================================================================
# Print header
# =============================================================================
echo "=========================================="
echo " i.ar Agent Status -- $(timestamp)"
echo "=========================================="
echo ""

# =============================================================================
# Running containers
# =============================================================================
echo "--- Running Containers ---"
RUNNING=$(podman ps --format '{{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null | grep -i "iar-emacboros\|emacboros\|cycle\|loop\|interactive" || true)
if [[ -n "${RUNNING}" ]]; then
    echo "${RUNNING}" | while IFS=$'\t' read -r name status image; do
        echo "  ${GREEN}${name}${NC}  ${status}  ${image}"
    done
else
    echo "  (none running)"
fi
echo ""

# =============================================================================
# Recent loop logs
# =============================================================================
echo "--- Recent Loop Runs ---"
TODAY=$(date +%Y-%m-%d)
LOOP_LOGS=$(find "${AUDIT_DIR}" -maxdepth 1 -name "*-loop-${TODAY}.log" 2>/dev/null | sort)
if [[ -n "${LOOP_LOGS}" ]]; then
    for log in ${LOOP_LOGS}; do
        agent_name=$(basename "${log}" | sed "s/-loop-${TODAY}.log//")
        last_line=$(tail -1 "${log}" 2>/dev/null || echo "(empty)")
        echo "  ${agent_name}: ${last_line}"
    done
else
    echo "  (no loop runs today)"
fi
echo ""

# =============================================================================
# Per-agent activity
# =============================================================================
echo "--- Agent Activity (last ${STATUS_LINES} entries) ---"

# Find all agent directories that have audit data
AGENT_DIRS=()
if [[ -n "${STATUS_AGENT}" ]]; then
    if [[ -d "${AUDIT_DIR}/${STATUS_AGENT}" ]]; then
        AGENT_DIRS=("${AUDIT_DIR}/${STATUS_AGENT}")
    else
        warn "Agent '${STATUS_AGENT}' has no audit directory"
    fi
else
    for d in "${AUDIT_DIR}"/*/; do
        [[ -d "${d}" ]] || continue
        name=$(basename "${d}")
        # Skip non-agent dirs (e.g. unknown, testagent, otheragent)
        [[ "${name}" == "unknown" || "${name}" == "testagent" || "${name}" == "otheragent" ]] && continue
        AGENT_DIRS+=("${d}")
    done
fi

for agent_dir in "${AGENT_DIRS[@]:-}"; do
    [[ -z "${agent_dir}" ]] && continue
    agent_name=$(basename "${agent_dir}")
    history_log="${agent_dir}/HISTORY.log"
    logs_md="${agent_dir}/LOGS.md"

    echo ""
    echo "  [${agent_name}]"

    # HISTORY.log -- recent tool calls and actions
    if [[ -f "${history_log}" ]]; then
        tail -n "${STATUS_LINES}" "${history_log}" 2>/dev/null | while IFS= read -r line; do
            # Truncate long lines to 120 chars for readability
            if [[ ${#line} -gt 120 ]]; then
                echo "    ${line:0:117}..."
            else
                echo "    ${line}"
            fi
        done
    else
        echo "    (no history)"
    fi
done

echo ""

# =============================================================================
# Pending tasks
# =============================================================================
echo "--- Pending Tasks ---"
TASK_COUNT=0
if [[ -d "${TASKS_DIR}" ]]; then
    for agent_tasks in "${TASKS_DIR}"/*/; do
        [[ -d "${agent_tasks}" ]] || continue
        agent_name=$(basename "${agent_tasks}")
        task_files=()
        while IFS= read -r f; do
            [[ -f "${f}" ]] && task_files+=("${f}")
        done < <(find "${agent_tasks}" -maxdepth 1 -name "*.md" ! -name "LOGS.md" ! -name "SUMMARY.md" ! -name "MEMORIES.md" ! -name "TODO.md" ! -name "IDEAS.md" 2>/dev/null | sort)

        if [[ ${#task_files[@]} -gt 0 ]]; then
            echo ""
            echo "  [${agent_name}] (${#task_files[@]} task(s))"
            for tf in "${task_files[@]}"; do
                task_name=$(basename "${tf}" .md)
                # Show first non-empty, non-header line as summary
                summary=$(grep -m1 '^[^#[:space:]]' "${tf}" 2>/dev/null || head -1 "${tf}" 2>/dev/null || echo "")
                if [[ -n "${summary}" ]]; then
                    if [[ ${#summary} -gt 100 ]]; then
                        summary="${summary:0:97}..."
                    fi
                    echo "    ${task_name}: ${summary}"
                else
                    echo "    ${task_name}: (no description)"
                fi
                TASK_COUNT=$((TASK_COUNT + 1))
            done
        fi
    done
fi
if [[ ${TASK_COUNT} -eq 0 ]]; then
    echo "  (no pending tasks)"
fi

echo ""

# =============================================================================
# Global audit log (last few entries)
# =============================================================================
echo "--- Global Audit (last ${STATUS_LINES} entries) ---"
GLOBAL_LOG="${AUDIT_DIR}/audit.log"
if [[ -f "${GLOBAL_LOG}" ]]; then
    tail -n "${STATUS_LINES}" "${GLOBAL_LOG}" 2>/dev/null | while IFS= read -r line; do
        if [[ ${#line} -gt 120 ]]; then
            echo "    ${line:0:117}..."
        else
            echo "    ${line}"
        fi
    done
else
    echo "  (no global audit log)"
fi

echo ""
echo "=========================================="
echo " Full logs at: ${AUDIT_DIR}/<agent>/"
echo " Tasks at:     ${TASKS_DIR}/<agent>/"
echo "=========================================="