#!/bin/bash
# Run iar test suite in batch mode with full environment.
# Usage: run-tests.sh [test-name-filter]
set -u
cd /root/i.ar/emacs.d
EMACS_ARGS=(
  --eval "(add-to-list 'load-path \"configs\")" \
  --eval '(load "paths")' \
  --eval '(load "delimiters")' \
  --eval '(load "keybindings")' \
  --eval '(setq iar-archetypes-path "/root/i.ar/prompts/archetypes/"
        iar-personalities-path "/root/i.ar/prompts/personalities/")' \
  --eval "(add-to-list 'load-path \"/root/i.ar/emacs.d/elpa/gptel-20260826.2228\")"
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