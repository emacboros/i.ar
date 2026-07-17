# agent/iar-agent-cycle.el -- Annotation

## What It Does

The biggest module (547 lines). Headless batch entry point for autonomous agent loops. Creates a gptel buffer with an agent profile, sends a cycle prompt, waits for completion via a batch-mode event loop (`accept-process-output`), sends Telegram notifications, and exits Emacs. Any orchestrator agent can run autonomously. Handles: profile loading, cycle prompt loading (per-agent fallback), knowledge loading, self-modification mode, continuation (re-prompting on text-only responses), completion detection (LOOP_COMPLETE / CYCLE_COMPLETE / natural language), timeout, FSM state monitoring, token usage tracking, and cycle logging.

## Key Functions

- `iar--cycle-token-summary` -- returns token usage string from request-logger accumulators.
- `iar--cycle-notify-telegram` -- sends Telegram notification via curl. Duplicates telegram.el.
- `iar--cycle-notify-on-exit` -- `kill-emacs-hook` handler. Sends result message on exit.
- `iar--cycle-log-append` -- appends LLM response to `audit/<agent>/cycle.log` with timestamp.
- `iar--cycle-load-profile` -- loads agent profile via `iar--load-agent-profile`. Errors if not found.
- `iar--cycle-load-cycle-prompt` -- tries `<agent>_cycle.org`, falls back to `agent_cycle.org`.
- `iar--cycle-load-continue-prompt` -- loads `agent_cycle_continue.org`, falls back to defconst. Takes unused `_agent-name`.
- `iar--cycle-complete-p` -- scans buffer for completion markers. Returns nil/'cycle/'loop. 3 detection methods: exact sentinels, natural language phrases requiring HISTORY reference.
- `iar-run-cycle` -- the main function. ~150 lines. `&rest args` with keyword plist. Sets up buffer, hooks, timers, sends prompt, enters batch event loop.

## What's Good

- **Self-modification isolation.** `setq-local iar-guard-allow-self-modification` -- delegate buffers inherit global nil. Correct isolation. Well-commented.
- **`:safe` omission on Telegram credentials.** Same security pattern as file guard. Prevents silent credential redirect via file-local variables. Well-documented in docstrings.
- **Per-agent cycle prompt fallback.** `<agent>_cycle.org` -> `agent_cycle.org`. Clean pattern for customization with shared default.
- **Cycle logging.** Every LLM response appended to `audit/<agent>/cycle.log` with timestamp. Enables `tail -f` monitoring during autonomous runs.
- **Token usage tracking integration.** Resets accumulators at cycle start, includes token counts in result messages. Clean integration with request-logger.
- **Knowledge loading in cycle buffer.** Multiple knowledge labels supported (single string or list). Correct default (`iar/`).

## Issues Found

### 1. `iar--cycle-notify-telegram` duplicates telegram.el [ISSUE -- REWRITE]
**Problem:** Reimplements Telegram send logic (curl, JSON, response parsing) instead of calling the `send_telegram` tool or a shared function. This file predates telegram.el but needs updating to use it.
**Action:** Replace with call to telegram.el's function (or the send_telegram tool). Eliminates ~50 lines of duplicate code.

### 2. `iar-cycle-default-continue-prompt` is hardcoded prompt text in elisp [ISSUE -- ALREADY TRACKED]
**Problem:** Day 1 finding #4: prompt text goes in prompt files. This defconst should be in `agent_cycle_continue.org` (which already exists as the primary; this is just the fallback).
**Action:** Move to prompt file. Remove defconst.

### 3. Batch event loop is complex and fragile [ISSUE -- ELIMINATED BY TOOL CALL REFACTOR]
**Problem:** `while (not completed)` loop with `accept-process-output` monitors FSM states, idle counts, active requests, and continuation-pending. Uses `iar-gptel-fsm-*` wrappers from compat layer. Fragile -- depends on gptel internals.
**Action:** Eliminated by tool call layer refactor. The FSM monitoring was added during a debugging session and won't be needed after the abstraction is in place.

### 4. Completion detection should use marker pattern, not hardcoded strings [ISSUE -- REWRITE]
**Problem:** `iar--cycle-complete-p` has 3 detection methods: exact sentinels (LOOP_COMPLETE/CYCLE_COMPLETE), natural language phrases requiring HISTORY reference. The sentinels and regex patterns are hardcoded in elisp.
**Decision:** User wants this to follow the "=== DELEGATION_RESULT ===" pattern -- the marker string lives in a separate org file, the code matches exactly that pattern, and the LLM is instructed in its prompt to output it. Nowhere in code should the pattern be hardcoded. The natural language detection goes away entirely.
**Action:** Rewrite completion detection. Marker pattern loaded from prompt file. Exact match only. No natural language heuristics.

### 5. `iar--cycle-load-continue-prompt` takes unused `_agent-name` [ISSUE -- SIMPLIFY]
**Problem:** Parameter explicitly unused. Was intended for per-agent continue prompts, but prompts are now structured to be reusable by all agents.
**Decision:** User says per-agent continue prompts are not necessary. Remove the parameter. Simplify the function.
**Action:** Remove `_agent-name` parameter during refactor.

### 6. `gptel-confirm-tool-calls` set to nil [ISSUE -- ALREADY TRACKED]
**Problem:** Same as delegate-tool. Goes away with framework-level restrictions.
**Action:** Already tracked. Remove.

### 7. Mount awareness `boundp` + `fboundp` check duplicated 3rd time [ISSUE -- DUPLICATE]
**Problem:** Same pattern in agent-loader, delegate-tool, and here.
**Action:** Already tracked. Resolve once for all modules.

### 8. Dual tracking (buffer-local + global) duplicated 3rd time [ISSUE -- DUPLICATE]
**Problem:** Same pattern in agent-loader, delegate-tool, and here.
**Action:** Already tracked. Resolve after tool call layer refactor.

### 9. 60-line continuation hook lambda + 3-case cond [ISSUE -- ALREADY TRACKED]
**Problem:** Same 3-case pattern as delegate-tool completion function (max turns / completion / re-prompt). Deep nesting. Shared abstraction candidate.
**Action:** Already tracked. Flag for discussion during refactor.

### 10. Stale comment: "from iar-delegate-tool.el" [ISSUE -- DOC]
**Problem:** `iar--cycle-load-profile` comment says function is from `iar-delegate-tool.el` but it's actually in `iar-agent-loader.el` (was moved).
**Action:** Fix comment during refactor.

### 11. `iar-darwin-run-cycle` backward compat alias [ISSUE -- ALREADY TRACKED]
**Problem:** Day 1 finding #6: remove all aliases.
**Action:** Remove during refactor.

### 12. Telegram defcustoms `:safe` omission [NOTE -- ELIMINATED BY REWRITE]
**Problem:** `iar-telegram-bot-token` and `iar-telegram-chat-id` lack `:safe`. Good security practice, but these defcustoms go away when the module uses telegram.el instead.
**Action:** Eliminated by rewrite (issue 1). Credentials move to telegram.el's configuration.

### 13. Debug logging baked into batch event loop [ISSUE -- REMOVE]
**Problem:** `debug-counter`, FSM state change messages, "Still waiting..." every 50 iterations. Debugging code that should not be in production.
**Decision:** User says this was meant to debug gptel's FSM internals. Goes away with tool call refactor (no more direct FSM monitoring).
**Action:** Remove entirely. The batch event loop itself goes away or is radically simplified.

### 14. `condition-case nil` swallows all errors in prompt loading [ISSUE -- ALREADY TRACKED]
**Problem:** `iar--cycle-load-cycle-prompt` and `iar--cycle-load-continue-prompt` use `condition-case nil` to catch all errors and fall back. Silently swallows non-"file not found" errors too.
**Action:** Already tracked as part of error handling unification. Narrow the condition-case or use a more specific error type.

### 15. `iar-run-cycle` is ~150 lines [ISSUE -- SPLIT]
**Problem:** Buffer setup, hook installation, timer setup, and batch event loop are distinct responsibilities in one function. Too long.
**Action:** Split during refactor. Separate setup, execution, and monitoring.

### 16. Self-modification buffer-local isolation [NOTE -- GOOD]
**Problem:** `setq-local iar-guard-allow-self-modification` -- delegate buffers inherit global nil.
**Decision:** Correct. Keep this pattern. No change needed.

## Patterns to Watch

- **Don't reimplement framework capabilities (again):** Telegram send logic duplicated from telegram.el. Same as memory-tools reimplementing gptel's request mechanism. GUIDELINES.md rule already crystallized.
- **Hardcoded prompt strings in code:** LOOP_COMPLETE, CYCLE_COMPLETE, natural language phrases, default continue prompt. All should be in prompt files. The marker pattern (like DELEGATION_RESULT) should be loaded from a prompt file, matched exactly, and the LLM instructed to output it.
- **Completion detection via markers, not heuristics:** Natural language detection is fragile (worked in practice but architecturally wrong). Use exact marker matching. The marker string lives in a prompt file, not in code.
- **Debug code in production:** FSM state logging, idle counters, "still waiting" messages. Remove or gate behind a flag.
- **Function length:** 150-line function is too long. GUIDELINES.md should enforce a max function length (companion to the max file length rule from knowledge-loader).
- **Stale comments after code moves:** "from iar-delegate-tool.el" when function moved to iar-agent-loader.el. Comments need updating when code moves.