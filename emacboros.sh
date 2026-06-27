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

    # shellcheck disable=SC2086
    podman run \
        --rm -it --name "${CONTAINER_NAME}" \
    	--security-opt no-new-privileges \
        --cap-drop=all \
        --cap-add=NET_RAW \
        --cap-add=NET_BIND_SERVICE \
        --tmpfs /tmp:rw,size=256m \
        --tmpfs /run:rw,size=64m \
        --tmpfs /var/tmp:rw,size=64m \
        -v "${SCRIPT_DIR}/elisp:/root/.emacs.d:Z" \
        -v "${SCRIPT_DIR}/knowledge/prompts:/root/.emacs.d/agents.d:Z" \
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
