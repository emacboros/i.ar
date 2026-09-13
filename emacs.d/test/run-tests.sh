#!/bin/bash
# Run iar test suite in batch mode with full environment.
# Usage: run-tests.sh [test-name-filter]
#
# c274: delegates to run-tests.el (the full suite, 1250+ tests) instead
# of loading only test-prompt-assembly.el. The old behavior was a
# lying instrument: "suite green" from this script covered a 57-test
# subset while the real suite grew to 1250 tests (c273 scar). The
# cheap invocation is now the true one.
#
# c274 mechanism note: the gptel elpa dir is added with -L, NOT
# --eval add-to-list. The repo lives under /root/i.ar -- and "ar" is
# a tramp-archive suffix, so any path ending in .ar gets the
# tramp-archive file-name handler. A --eval that touches load-path
# while such a path is present recurses through the handler during
# startup (excessive-lisp-nesting). -L is processed before tramp
# autoloads register and is immune.
#
# Optional filter arg: a test-name regexp, passed to run-tests.el via
# IAR_TEST_FILTER. All test files still LOAD (the stowaway guard
# stays active); the filter only restricts which tests RUN.
#   run-tests.sh                -- full suite
#   run-tests.sh "git-commit"   -- tests matching the regexp
#
# Note: run-tests.el installs gptel/undercover from MELPA if missing
# (network needed on first run in a fresh container).
set -u
cd /root/i.ar/emacs.d

# Resolve the installed gptel elpa dir dynamically: the elpa tree is
# gitignored and versioned per environment (container 20260819.446,
# sophon 20260826.2228) -- a hardcoded path breaks whichever host it
# was not written on (the stale-path failure class, 426a985 addendum).
GPTEL_DIR=$(ls -d /root/i.ar/emacs.d/elpa/gptel-* 2>/dev/null | sort | tail -1)

if [ $# -gt 0 ]; then
  IAR_TEST_FILTER="$1" exec emacs --batch -L "${GPTEL_DIR}" -L test \
    -l test/run-tests.el
else
  exec emacs --batch -L "${GPTEL_DIR}" -L test \
    -l test/run-tests.el
fi
