#!/bin/bash
# Belt for the nocturne digest gate lineage fix (aria c266).
# Disease (c265 RCA): the gate file held a pre-rewrite hash (ee4f0e50)
# that was NOT an ancestor of HEAD; rev-list LAST..HEAD then spanned the
# entire rewritten band and RANGE-CAP digested rewrite-era history as if
# it were new. v8.5 fixes: ancestor guard (digest NOTHING on lineage
# break), first-parent range semantics, test overrides.
#
# Run: nocturne-gate-lineage.sh [path-to-nocturne-digest.sh] [sandbox-repo]
# Exit 0 = all fixtures pass; nonzero = belt failure.
#
# Fixtures run in DRY-RUN mode (NOC_DRY_RUN=1): the wrapper resolves the
# gate + range, logs, and exits BEFORE launching the one-shot. The
# sandbox repo is a CLONE of the real personalization repo; the gate
# file lives in the sandbox's audit tree, so the real gate is never
# touched. NOC_PERS points the wrapper at the sandbox.
set -u
W="${1:?usage: nocturne-gate-lineage.sh <nocturne-digest.sh> [sandbox-repo]}"
REAL_PERS="${2:-/var/home/nacho/repos/iar-personalization}"
PASS=0; FAIL=0
say() { echo "  $*"; }
check() {
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); say "PASS $1"; else FAIL=$((FAIL+1)); say "FAIL $1 (expect=$2 actual=$3)"; fi
}

SBX=${NOC_BELT_TMP:-/var/home/nacho/repos/i.ar/tmp/nocturne-gate-belt.$$}
mkdir -p "$SBX"
trap 'rm -rf "$SBX"' EXIT
git clone -q --no-hardlinks "$REAL_PERS" "$SBX/repo" 2>/dev/null
cd "$SBX/repo" || exit 1
HEAD=$(git rev-parse HEAD)
GATE_FILE="$SBX/repo/audit/nocturne/nocturne/LAST-DIGESTED-HEAD"
mkdir -p "$(dirname "$GATE_FILE")"

run_wrap() { # run_wrap <tag> -> echoes wrapper log
  NOC_PERS="$SBX/repo" NOC_DRY_RUN=1 timeout 60 bash "$W" 2>/dev/null
}

gate_set() { printf '%s' "$1" > "$GATE_FILE"; }
gate_restore() { printf '%s' "$REAL_GATE" > "$GATE_FILE"; }

# The REAL gate value (from the real tree) -- restored after every fixture
REAL_GATE=$(cat "$REAL_PERS/audit/nocturne/nocturne/LAST-DIGESTED-HEAD" 2>/dev/null || echo "")

# ---- Fixture 1: dead-lineage gate (the 09-22 disease) ----
# A hash that exists in the object store but is NOT an ancestor of HEAD.
# The rewritten July band is reachable (filter-repo keeps objects) but
# dead by graph. Use the merge-base of a known dead hash if present;
# otherwise synthesize: HEAD~1000 may not exist on shallow clones, so
# walk to the merge-base with the pre-rewrite lineage if recorded.
# The REAL dead hash: ee4f0e50 (pre-rewrite lineage, aria c362 09-15).
# The filter-repo rewrite kept the object reachable but off-lineage --
# exactly the 09-22 disease. If the object is absent (fresh clone from
# a rewritten-only remote), synthesize an unknown hash instead.
DEAD="ee4f0e50776fa6b034db049bdfd5f6ff3a382e43"
if ! git cat-file -e "$DEAD^{commit}" 2>/dev/null; then
  DEAD="0000000000000000000000000000000000000001"
fi
if git merge-base --is-ancestor "$DEAD" HEAD 2>/dev/null; then
  say "SKIP f1 (dead hash is an ancestor here -- repo has no dead lineage)"
  DEAD=""
fi
gate_set "$DEAD"
OUT=$(run_wrap f1)
if echo "$OUT" | grep -q "GATE-DEAD-LINEAGE"; then
  if echo "$OUT" | grep -qE "digesting [0-9a-f]{40}\.\.[0-9a-f]{40}"; then
    check "f1a dead-lineage aborts-loud" pass FAIL
  else
    check "f1a dead-lineage aborts-loud" pass pass
  fi
else
  check "f1a dead-lineage aborts-loud" pass FAIL
fi
check "f1b merge-base named in verdict" pass "$(echo "$OUT" | grep -q "merge-base" && echo pass || echo FAIL)"
# gate file must NOT have been advanced
[ -n "$DEAD" ] && check "f1c gate not advanced" "$DEAD" "$(cat "$GATE_FILE")"

# ---- Fixture 2: healthy ancestor gate, small range -> digests, no cap ----
gate_set "$(git rev-parse HEAD~3)"
OUT=$(run_wrap f2)
check "f2a digests range" pass "$(echo "$OUT" | grep -q "would digest" && echo pass || echo FAIL)"
check "f2b no dead-lineage verdict" FAIL "$(echo "$OUT" | grep -q "GATE-DEAD-LINEAGE" && echo pass || echo FAIL)"
check "f2c no range-cap" FAIL "$(echo "$OUT" | grep -q "RANGE-CAP" && echo pass || echo FAIL)"

# ---- Fixture 3: no-change gate -> no-op ----
gate_set "$HEAD"
OUT=$(run_wrap f3)
check "f3a no-op on unchanged gate" pass "$(echo "$OUT" | grep -q "no change since last digest" && echo pass || echo FAIL)"

# ---- Fixture 4: cap arithmetic (first-parent semantics) ----
# Set gate 310 fp-commits back; cap at 100 -> capped head = 100th fp
# commit after gate; deferred = 210.
if git rev-parse HEAD~310 >/dev/null 2>&1; then
  G310=$(git rev-parse HEAD~310)
  C100=$(git rev-list --first-parent --reverse "$G310..HEAD" | sed -n '100p')
  gate_set "$G310"
  OUT=$(NOC_PERS="$SBX/repo" NOC_DRY_RUN=1 NOC_MAX_RANGE=100 timeout 60 bash "$W" 2>/dev/null)
  check "f4a cap fires at MAX_RANGE" pass "$(echo "$OUT" | grep -q "RANGE-CAP" && echo pass || echo FAIL)"
  CAPLINE=$(echo "$OUT" | grep "RANGE-CAP" | grep -o '[0-9a-f]\{40\}' | sed -n 3p)
  check "f4b capped head is 100th fp commit" "$C100" "$CAPLINE"
  check "f4c deferred count = 210 (fp)" "210" "$(echo "$OUT" | grep -o '[0-9]* commits deferred' | grep -o '^[0-9]*')"
else
  say "SKIP f4 (clone shallower than 310 fp commits)"
fi

# ---- Fixture 5: empty gate file -> first-run fallback path ----
printf '' > "$GATE_FILE"
OUT=$(run_wrap f5)
check "f5a first-run fallback fires" pass "$(echo "$OUT" | grep -q "first run\|digesting" && echo pass || echo FAIL)"

gate_restore
echo "belt: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]