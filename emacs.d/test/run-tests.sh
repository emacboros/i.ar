#!/bin/bash
# Run iar test suite in batch mode with full environment.
# Usage: run-tests.sh [test-name-filter]
set -u
cd /root/i.ar/emacs.d
# Resolve the installed gptel elpa dir dynamically: the elpa tree is
# gitignored and versioned per environment (container 20260819.446,
# sophon 20260826.2228) -- a hardcoded path breaks whichever host it
# was not written on (the stale-path failure class, 426a985 addendum).
GPTEL_DIR=$(ls -d /root/i.ar/emacs.d/elpa/gptel-* 2>/dev/null | sort | tail -1)
EMACS_ARGS=(
  --eval "(add-to-list 'load-path \"configs\")" \
  --eval '(load "paths")' \
  --eval '(load "delimiters")' \
  --eval '(load "keybindings")' \
  --eval '(setq iar-archetypes-path "/root/i.ar/prompts/archetypes/"
        iar-personalities-path "/root/i.ar/prompts/personalities/")' \
  --eval "(add-to-list 'load-path \"${GPTEL_DIR}\")"
  --eval "(add-to-list 'load-path \"init.d/agent\")"
  --eval "(add-to-list 'load-path \"init.d/shared\")"
  --eval "(add-to-list 'load-path \"init.d/core\")"
  --eval "(add-to-list 'load-path \"init.d/security\")"
  --eval "(add-to-list 'load-path \"init.d/tools\")"
  --eval "(add-to-list 'load-path \"init.d/session\")"
  --eval "(add-to-list 'load-path \"init.d/dynamic\")"
  --eval "(add-to-list 'load-path \"init.d/tool-call\")"
  --eval "(add-to-list 'load-path \"test\")"
)
if [ $# -gt 0 ]; then
  emacs --batch "${EMACS_ARGS[@]}" --eval "(progn (load \"test-prompt-assembly\") (ert-run-tests-batch \"$1\"))"
else
  emacs --batch "${EMACS_ARGS[@]}" --eval "(progn (load \"test-prompt-assembly\") (ert-run-tests-batch-and-exit))"
fi