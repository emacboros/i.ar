# debug/iar-fsm-tracer.el -- Annotation

## What It Does

Logs every FSM state transition and tool call inspection via `:before` advice on three gptel internal functions. Writes to `audit/<agent>/FSM.log`. Three observation points: FSM transitions, tool call processing, tool use handling. Self-installs at load time.

## Key Functions

- `iar--fsm-trace-log-path` -- resolves per-agent FSM.log path.
- `iar--fsm-trace-write` -- writes timestamped entry to FSM.log. Best-effort.
- `iar--fsm-trace-count-plist` -- counts entries in a plist key. Helper.
- `iar--mygptel--fsm-trace-transition` -- logs old/new state, tool-use/result counts, error status.
- `iar--mygptel--fsm-trace-tool-call-before` -- logs tool name, total/remaining tools.
- `iar--mygptel--fsm-trace-handle-tool-use-before` -- logs backend status, raw/filtered tool-use, buffer alive/dead.
- `iar-fsm-trace-setup` -- installs 3 `:before` advice hooks via compat layer.

## What's Good

- **The `:before` not `:override` lesson is well-documented.** Header comment explains: `:override` silently swallowed errors and left FSM stuck at TOOL state forever. This is the banned pattern. Good documentation of a hard-won lesson.
- **Best-effort logging.** `condition-case` on all writes. Tracing never breaks the FSM.
- **`iar-fsm-trace-enabled` with `:safe`.** Correct for a debug toggle.
- **Three observation points give complete FSM visibility.** Transitions, tool call processing, tool use handling. Good diagnostic coverage.

## Issues Found

### 1. `:before` not `:override` lesson [NOTE -- POSITIVE]
**Problem:** None. This is the correct pattern and well-documented.
**Action:** Document in GUIDELINES.md: observer modules use `:before` advice only. `:override` is banned (silently swallows errors, leaves FSM stuck).

### 2. Anonymous lambdas in advice-add [ISSUE -- ALREADY TRACKED]
**Problem:** 3 more instances via compat wrappers. Can't be removed by name. `reload_os` adds duplicates.
**Action:** Already tracked. Use named functions.

### 3. Direct `append-to-file` bypasses audit-log module [ISSUE -- ALREADY TRACKED]
**Problem:** Same as buffer-monitor and request-logger.
**Action:** Already tracked. Use shared audit logging.

### 4. `my-gptel--` prefix on 3 functions [ISSUE -- ALREADY TRACKED]
**Problem:** Day 1 finding #6: rename to `iar--`.
**Action:** Rename during refactor.

### 5. Compat layer dependency -- most coupled module [ISSUE -- REWRITE]
**Problem:** Directly inspects FSM state, plist structure, tool-use lists, backend status. After tool call layer refactor, none of these gptel internals are directly accessible. Module either becomes irrelevant (tool call layer has own diagnostics) or gets complete rewrite.
**Decision:** User says debug modules change significantly with new architecture. Flag and move on.
**Action:** Rewrite or eliminate after tool call layer refactor.

### 6. `&rest _` signature mismatch with advice lambda [NOTE -- MINOR]
**Problem:** Function accepts `(fsm tool-spec tool-call &rest _)` but advice passes 4 args including `result`. The `&rest _` catches it. Works but could confuse readers.
**Action:** Minor. Clean up during rewrite.

### 7. `cl-loop` and `cl-remove-if` usage [NOTE -- DATA POINT]
**Problem:** More cl-lib usage for the consistency discussion.
**Action:** Already tracked. Decide cl-lib adoption level after reading all files.

### 8. Debug parameters should be in configs/debug/ [ISSUE -- ALREADY TRACKED]
**Problem:** `iar-fsm-trace-enabled` is a defcustom here, should be in `configs/debug/`.
**Action:** Already tracked as part of parameters.el split.

## Patterns to Watch

- **`:before` advice only for observers (banned `:override`):** Document in GUIDELINES.md. The `:override` incident is the cautionary tale.
- **Most gptel-internal-coupled module:** This is the module that most directly touches gptel internals. After tool call layer refactor, it's the most affected. Either eliminated or completely rewritten.
- **Debug modules summary:** All three debug modules (buffer-monitor, request-logger, fsm-tracer) share the same patterns: anonymous lambdas in advice, direct file writes bypassing audit-log, compat layer dependency, `my-gptel--` prefix, self-install at load time. All change fundamentally with tool call layer refactor. Token usage tracking (from request-logger) is the only production-value feature to preserve.