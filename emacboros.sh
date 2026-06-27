#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(realpath "$(dirname "${BASH_SOURCE[0]}")")"
source "${SCRIPT_DIR}/metaconfig/header.sh"

# =============================================================================
# Agentic Emacs -- Container Management Script
# =============================================================================

IMAGE_NAME="iar-emacboros"
CONTAINER_NAME="iar-emacboros"

# =============================================================================
# Run the container with .emacs.d mounted
# =============================================================================
run() {
    info "Starting ${CONTAINER_NAME}"

    # Generate read-only bind mounts for all agent prompt files and shared context.
    # This prevents shell-level tampering with agent prompts, which
    # file_guard.el cannot stop (it only intercepts Emacs tools, not
    # arbitrary shell commands via execute_code_local).
    local ro_mounts=""
    for prompt in "${SCRIPT_DIR}"/agents.d/*/prompt.org; do
        [ -f "$prompt" ] || continue
        local agent_name
        agent_name=$(basename "$(dirname "$prompt")")
        ro_mounts="${ro_mounts} -v ${prompt}:/root/.emacs.d/agents.d/${agent_name}/prompt.org:ro,Z"
    done

    # Read-only mount for base_context.org if it exists.
    if [ -f "${SCRIPT_DIR}/agents.d/base_context.org" ]; then
        ro_mounts="${ro_mounts} -v ${SCRIPT_DIR}/agents.d/base_context.org:/root/.emacs.d/agents.d/base_context.org:ro,Z"
    fi

    # Read-only mounts for critical infrastructure files.
    # These are the same paths protected by file_guard.el, but enforced
    # at the mount level so shell commands cannot bypass them.

    # shellcheck disable=SC2086
    podman run \
        --rm -it --name "${CONTAINER_NAME}" \
        --read-only \
        --security-opt no-new-privileges \
        --cap-drop=all \
        --cap-add=NET_RAW \
        --cap-add=NET_BIND_SERVICE \
        --tmpfs /tmp:rw,size=256m \
        --tmpfs /run:rw,size=64m \
        --tmpfs /var/tmp:rw,size=64m \
        -v "${SCRIPT_DIR}/elisp:/root/.emacs.d:Z" \
        -v "${SCRIPT_DIR}/elisp:/root/i.ar/elisp:Z" \
        -v "${SCRIPT_DIR}/containers:/root/i.ar/containers:Z" \
        -v "${SCRIPT_DIR}/infra:/root/i.ar/infra:Z" \
        -v "${SCRIPT_DIR}/knowledge:/root/i.ar/knowledge:Z" \
        -v "${SCRIPT_DIR}/metaconfig:/root/i.ar/metaconfig:Z" \
        "${IMAGE_NAME}" && \
	info "Container started" || \
	error "Container failed to start"
}

run
