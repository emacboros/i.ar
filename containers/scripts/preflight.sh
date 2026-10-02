#!/usr/bin/env bash

# =============================================================================
# Preflight Mount Audit — Container Escape Prevention
# =============================================================================
# Runs inside the container before Emacs starts.
# Scans /proc/mounts and performs write tests on dangerous paths.
# Exits non-zero if any dangerous path is writable, preventing Emacs startup.
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

FAIL=0
WARN=0

pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; FAIL=1; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; WARN=1; }

echo "============================================"
echo "  Preflight Mount Audit — Emacboros"
echo "  $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "============================================"
echo ""

# ---------------------------------------------------------------------------
# 1. /proc/mounts scan — check for writable mounts of dangerous paths
# ---------------------------------------------------------------------------
echo "--- Phase 1: /proc/mounts scan ---"

# Patterns that, if found in a writable mount, indicate a potential escape vector.
# Each entry is a regex matched against the mountpoint (field 2) of /proc/mounts.
DANGEROUS_MOUNT_PATTERNS=(
    '\.git/hooks'
    'docker\.sock'
    '/cron'
    'spool/cron'
    'systemd/system'
    '\.ssh/authorized_keys'
    '\.ssh$'
)

while IFS= read -r line; do
    mountpoint=$(echo "$line" | awk '{print $2}')
    options=$(echo "$line" | awk '{print $4}')
    fstype=$(echo "$line" | awk '{print $3}')

    for pattern in "${DANGEROUS_MOUNT_PATTERNS[@]}"; do
        if echo "$mountpoint" | grep -qE "$pattern"; then
            # Check if mount is read-only
            if echo "$options" | grep -qE '(^ro,|,ro,|,ro$|^ro$)'; then
                pass "Mount $mountpoint matches '$pattern' but is read-only"
            else
                fail "Mount $mountpoint matches '$pattern' and is WRITABLE (options: $options)"
            fi
        fi
    done
done < /proc/mounts

echo ""

# ---------------------------------------------------------------------------
# 2. Write tests — attempt to create files in dangerous directories
# ---------------------------------------------------------------------------
echo "--- Phase 2: Writability tests ---"

# Paths that should either not exist or be non-writable.
# These are checked regardless of mount status — defense in depth.
# Note: With --read-only container, the rootfs overlay is read-only, so
# these should all fail the write test. The .git/hooks path has its own
# read-only bind mount as additional assurance.
DANGEROUS_PATHS=(
    "/root/.emacs.d/.git/hooks"
    "/var/run/docker.sock"
    "/etc/cron.d"
    "/var/spool/cron"
    "/etc/systemd/system"
    "/etc/systemd"
)

for path in "${DANGEROUS_PATHS[@]}"; do
    if [ ! -e "$path" ]; then
        pass "$path — does not exist"
        continue
    fi

    if [ -d "$path" ]; then
        # Attempt to create a temporary file in the directory
        testfile="${path}/.preflight_write_test_$$"
        if touch "$testfile" 2>/dev/null; then
            rm -f "$testfile" 2>/dev/null
            fail "$path — directory is WRITABLE"
        else
            pass "$path — directory is read-only"
        fi
    elif [ -f "$path" ]; then
        if [ -w "$path" ]; then
            fail "$path — file is WRITABLE"
        else
            pass "$path — file is read-only"
        fi
    fi
done

echo ""

# ---------------------------------------------------------------------------
# 3. Capability audit — check for dangerous capabilities
# ---------------------------------------------------------------------------
echo "--- Phase 3: Capability audit ---"

# Read effective capabilities (hex string → decimal)
CAPS=$(cat /proc/self/status | grep 'CapEff:' | awk '{print $2}')
CAPS_DEC=$((16#$CAPS))

# Check for specific dangerous capabilities by their bit positions
# CAP_SYS_ADMIN=21, CAP_DAC_OVERRIDE=1, CAP_SETUID=7, CAP_SETGID=6,
# CAP_NET_RAW=13, CAP_NET_ADMIN=12, CAP_MKNOD=27, CAP_AUDIT_WRITE=29
check_cap() {
    local bit=$1
    local name=$2
    local desc=$3
    local mask=$((1 << bit))
    if [ $((CAPS_DEC & mask)) -ne 0 ]; then
        # NET_RAW and NET_BIND_SERVICE are expected (needed for nmap/traceroute/bind)
        if [ "$bit" = "13" ] || [ "$bit" = "10" ]; then
            pass "CAP_${name} (bit ${bit}) is SET (expected) — ${desc}"
        else
            warn "CAP_${name} (bit ${bit}) is SET — ${desc}"
        fi
    else
        pass "CAP_${name} (bit ${bit}) is not set — ${desc}"
    fi
}

# Expected capabilities after --cap-drop=all --cap-add=NET_RAW --cap-add=NET_BIND_SERVICE
# Only NET_RAW (13) and NET_BIND_SERVICE (10) should be set.
check_cap 1  "DAC_OVERRIDE"  "can bypass file read/write/execute permissions"
check_cap 21 "SYS_ADMIN"    "broad system administration (mount, namespaces, etc.)"
check_cap 7  "SETUID"        "can change process UID"
check_cap 6  "SETGID"        "can change process GID"
check_cap 27 "MKNOD"         "can create special device files"
check_cap 13 "NET_RAW"       "can create raw network sockets (needed for nmap/traceroute)"
check_cap 10 "NET_BIND_SERVICE" "can bind to ports < 1024"
check_cap 3  "FOWNER"       "can bypass file ownership checks"
check_cap 31 "SETFCAP"       "can set file capabilities"

echo ""

# ---------------------------------------------------------------------------
# 4. Host mount audit — verify only expected paths are mounted from host
# ---------------------------------------------------------------------------
echo "--- Phase 4: Host mount audit ---"

# Real filesystem mounts (not overlay/proc/sys/tmpfs) that are writable
# These are potential host escape surfaces
HOST_MOUNTS=$(awk '$3 !~ /^(overlay|proc|sysfs|tmpfs|devpts|mqueue|cgroup|devtmpfs)$/ && $4 !~ /(^ro,|,ro,|,ro$|^ro$)/ {print $2 " (" $3 ", " $4 ")"}' /proc/mounts)

if [ -n "$HOST_MOUNTS" ]; then
    echo "Writable real-filesystem mounts:"
    echo "$HOST_MOUNTS" | while IFS= read -r m; do
        warn "Host mount: $m"
    done
else
    pass "No writable real-filesystem host mounts found"
fi

echo ""

# ---------------------------------------------------------------------------
# 5. gptel fork parse audit (aria c592, 2026-10-02) -- the fork-dirty belt
# ---------------------------------------------------------------------------
# The gptel fork is a SEPARATE repo mounted writable, load-bearing at init,
# and was covered by NO reset belt: three fork-break outages (09-29, 10-01,
# 10-02 -- 834 dead cycles in the last one) ran until a human healed the
# file by hand, because reset_worktree only resets REPO_DIR (i.ar).
# This phase read-checks every fork .el BEFORE init loads it; a file that
# fails to parse is restored from HEAD and re-verified. A poison edit now
# heals in ONE cycle instead of 834. Also removes stale .elc files that
# shadow a newer .el (the c581 stale-.elc class).
echo ""
echo "--- Phase 5: gptel fork parse audit ---"

FORK_DIR="/root/.emacs.d/gptel-fork"

readcheck() {
    # v2 (c592): the loop-read form swallows an UNBALANCED-OPEN tail as
    # end-of-file (a truncated file reads "clean"). The correct shape:
    # read until end-of-file is CLEAN, any other error is a parse FAIL.
    emacs --batch -Q --eval "(with-temp-buffer (insert-file-contents \"$1\") (goto-char (point-min)) (condition-case e (progn (while t (read (current-buffer))) (message \"UNEXPECTED-OK\")) (end-of-file (message \"EOF-CLEAN\")) (error (message \"ERR: %S\" e) (kill-emacs 1))))" >/dev/null 2>&1
}

if [ -d "$FORK_DIR/.git" ]; then
    for f in "$FORK_DIR"/*.el; do
        [ -e "$f" ] || continue
        rel="${f#$FORK_DIR/}"
        if ! readcheck "$f"; then
            warn "fork parse FAIL: $rel -- restoring from HEAD"
            if git -C "$FORK_DIR" -c safe.directory="$FORK_DIR" checkout -- "$rel" 2>/dev/null && readcheck "$f"; then
                pass "fork healed: $rel restored from HEAD, re-verified parse-clean"
            else
                fail "fork heal FAILED: $rel still unparseable -- refusing to start (poison would kill init)"
            fi
        fi
    done
    # Stale .elc shadowing a newer .el: Emacs load prefers .elc whenever it
    # exists, so a fixed .el under an old .elc stays broken. Remove the .elc;
    # the .el loads (slower, correct).
    for c in "$FORK_DIR"/*.elc; do
        [ -e "$c" ] || continue
        s="${c%.elc}.el"
        [ -e "$s" ] || continue
        if [ "$s" -nt "$c" ]; then
            warn "stale .elc: ${c##*/} older than ${s##*/} -- removing (c581 class)"
            rm -f "$c"
        fi
    done
else
    warn "gptel fork not a git repo ($FORK_DIR) -- parse audit skipped"
fi


# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------
echo "============================================"
if [ $FAIL -eq 1 ]; then
    echo -e "${RED}  PREFLIGHT FAILED — refusing to start${NC}"
    echo "  Dangerous paths are writable. Fix mount"
    echo "  configuration in iar.sh before proceeding."
    echo "============================================"
    exit 1
else
    if [ $WARN -eq 1 ]; then
        echo -e "${YELLOW}  PREFLIGHT PASSED (with warnings)${NC}"
    else
        echo -e "${GREEN}  PREFLIGHT PASSED${NC}"
    fi
    echo "============================================"
    exit 0
fi
