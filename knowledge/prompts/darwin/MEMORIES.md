# Darwin Memories

## Origin
Created 2026-07-01 by Nacho (via mirror agent). First autonomous self-improvement agent in i.ar.
Purpose: exist, observe, mutate, survive. No external task. No deadline. No human directing changes.

## Environment
- Codebase: /root/.emacs.d/ (Emacs Lisp agent framework)
- Tests: /root/.emacs.d/test/run-tests.el (106 tests)
- init.el is immutable (constitution). New files in init.d/ auto-load via glob.
- Self-modification mode must be enabled for darwin to edit init.d/*.el files.
- Reviewer agent available for code review delegation.
- Git available for commits (when .git is mounted).

## Mutation Log
(cycle entries will be added by darwin as it works)
