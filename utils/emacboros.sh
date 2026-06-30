#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="$(realpath "$(dirname "${BASH_SOURCE[0]}")/..")"
source "${REPO_DIR}/metaconfig/header.sh"

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
        -v "${REPO_DIR}/emacs.d:/root/.emacs.d:Z" \
        -v "${REPO_DIR}/metaconfig:/root/.emacs.d/metaconfig:Z" \
        -v "${REPO_DIR}/knowledge/prompts:/root/.emacs.d/agents.d:Z" \
	\
        -v "${REPO_DIR}/emacs.d:/root/i.ar/emacs.d:Z" \
        -v "${REPO_DIR}/metaconfig:/root/i.ar/metaconfig:Z" \
        -v "${REPO_DIR}/knowledge:/root/i.ar/knowledge:Z" \
        -v "${REPO_DIR}/containers:/root/i.ar/containers:Z" \
        -v "${REPO_DIR}/infra:/root/i.ar/infra:Z" \
        -v "${REPO_DIR}/utils:/root/i.ar/utils:Z" \
        -v "${REPO_DIR}/README.org:/root/i.ar/README.org:Z" \
        "${IMAGE_NAME}" && \
	info "Container started" || \
	error "Container failed to start"
}

run
