#!/bin/bash
# Debug a single test: show condition + backtrace
set -u
cd /root/i.ar/emacs.d
# Resolve the installed gptel elpa dir dynamically: the elpa tree is
# gitignored and versioned per environment (container 20260819.446,
# sophon 20260826.2228) -- a hardcoded path breaks whichever host it
# was not written on (the stale-path failure class, 426a985 addendum).
GPTEL_DIR=$(ls -d /root/i.ar/emacs.d/elpa/gptel-* 2>/dev/null | sort | tail -1)
TEST="${1:?test name}"
emacs --batch \
  --eval "(add-to-list 'load-path \"configs\")" \
  --eval '(load "paths")' \
  --eval '(load "delimiters")' \
  --eval '(load "keybindings")' \
  --eval '(setq iar-archetypes-path "/root/i.ar/prompts/archetypes/"
        iar-personalities-path "/root/i.ar/prompts/personalities/")' \
  --eval "(add-to-list 'load-path \"${GPTEL_DIR}\")" \
  --eval "(add-to-list 'load-path \"init.d/agent\")" \
  --eval "(add-to-list 'load-path \"init.d/shared\")" \
  --eval "(add-to-list 'load-path \"init.d/core\")" \
  --eval "(add-to-list 'load-path \"init.d/security\")" \
  --eval "(add-to-list 'load-path \"init.d/tools\")" \
  --eval "(add-to-list 'load-path \"init.d/session\")" \
  --eval "(add-to-list 'load-path \"init.d/dynamic\")" \
  --eval "(add-to-list 'load-path \"init.d/tool-call\")" \
  --eval "(add-to-list 'load-path \"test\")" \
  --eval "(progn (load \"test-prompt-assembly\") (setq debug-on-error t) (ert-run-tests-batch \"$TEST\"))" 2>&1 | grep -B2 -A14 'condition\|backtrace' | head -40