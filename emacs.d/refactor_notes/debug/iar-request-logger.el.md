# debug/iar-request-logger.el -- Annotation

## What It Does

Captures full JSON payloads sent to and received from the LLM. Outgoing: `:around` advice on `gptel-curl--get-config` extracts JSON from curl config string. Incoming: `:before` advice on `gptel-curl--stream-cleanup` and `gptel-curl--sentinel` snapshots raw process buffer. Also tracks token usage (parses `prompt_eval_count` and `eval_count` from Ollama responses, accumulates in globals, writes to `USAGE.log` on `kill-emacs-hook`).

## Key Functions

- `iar--usage-reset` / `iar--usage-totals` -- global token accumulator management. Called by agent-cycle.
- `iar--usage-parse-tokens` -- regex-parses Ollama JSON for token counts. Accumulates into globals.
- `iar--usage-write-log` -- writes usage summary to `audit/<agent>/USAGE.log` on `kill-emacs-hook`.
- `iar--request-log-write` -- writes labeled block (request/response) to log file.
- `iar--mygptel--request-log-outgoing` -- extracts JSON from curl config string, logs it.
- `iar--mygptel--request-log-incoming` -- snapshots raw process buffer, strips HTTP headers, parses tokens, truncates at 100KB, logs it.
- `iar-request-log-setup` -- installs 3 advice hooks via compat layer wrappers.

## What's Good

- **Token usage tracking is the most valuable part.** Used by agent-cycle for result messages and by USAGE.log for cost monitoring. This functionality should survive the refactor.
- **Best-effort logging.** `condition-case` on all writes. Observer never breaks the system.
- **`iar-request-log-enabled` defcustom with `:safe`.** Correct for a debug toggle (not security-sensitive).

## Issues Found

### 1. Token parsing is regex-based on raw JSON [ISSUE -- FRAGILE]
**Problem:** `string-match "\"prompt_eval_count\":\\([0-9]+\\)"` -- fragile. If Ollama changes field names, silently fails (no match, no accumulation, no error).
**Action:** Flag for refactor. Use proper JSON parsing, not regex.

### 2. Token parsing doesn't verify `done:true` before accumulating [ISSUE -- POTENTIAL DOUBLE-COUNT]
**Problem:** Called on every incoming response, not just final chunk. Currently safe because Ollama only includes these fields in final chunk, but code doesn't verify.
**Action:** Flag for refactor. Verify `done:true` before accumulating.

### 3. Anonymous lambdas in advice-add [ISSUE -- ALREADY TRACKED]
**Problem:** Can't be removed by name. `reload_os` re-runs setup, adds duplicates.
**Action:** Already tracked. Use named functions.

### 4. Direct `append-to-file` bypasses audit-log module [ISSUE -- ALREADY TRACKED]
**Problem:** Same as buffer-monitor. Inconsistent with shared audit logging.
**Action:** Already tracked. Use shared audit logging.

### 5. `my-gptel--` prefix on 3 functions [ISSUE -- ALREADY TRACKED]
**Problem:** Day 1 finding #6: rename to `iar--`.
**Action:** Rename during refactor.

### 6. 100KB truncation hardcoded [ISSUE -- CONFIG]
**Problem:** Should be a parameter in `configs/debug/`.
**Action:** Already tracked as part of parameters.el split.

### 7. Compat layer dependency [ISSUE -- ALREADY TRACKED]
**Problem:** Uses `iar-gptel-advise-curl-*` wrappers. After tool call layer refactor, these go away.
**Action:** Already tracked.

### 8. JSON extraction from curl config string is fragile [ISSUE -- REWRITE]
**Problem:** `(string-match "{\"" config-str)` -- finds first `{`, assumes rest is JSON. Heuristic, not a parser.
**Decision:** User identifies two issues: (a) bypassing gptel functionality again -- gptel already tracks this in the menu bar, should reuse their implementation. (b) The custom status mode task will include these statistics, so this module needs reimagining with the new architecture in mind.
**Action:** Rewrite. Use gptel's existing token tracking, not regex on raw JSON. Integrate with the planned custom status mode (task: `custom-status-mode-ui`).

### 9. Token usage tracking should survive refactor [NOTE -- KEEP]
**Problem:** The request/response logging is debug-only and changes with tool call layer. But token usage tracking is used by agent-cycle and USAGE.log.
**Action:** Preserve token usage tracking through the refactor. Move to appropriate location (tool call layer or status mode module).

### 10. `kill-emacs-hook` for usage log -- crash loses data [NOTE -- MINOR]
**Problem:** If Emacs crashes, usage log never written. Accumulators are in-memory globals.
**Action:** Minor. Acceptable for a debug feature.

## Patterns to Watch

- **Don't reimplement framework capabilities (again):** gptel already tracks token usage in the menu bar. Reuse their implementation instead of regex-parsing raw JSON. Same GUIDELINES.md rule as memory-tools.
- **Debug modules reimagined with new architecture:** Request logger, buffer monitor, and FSM tracer all change fundamentally with tool call layer + custom status mode. Don't over-invest in current structure.
- **Token usage tracking is production value, not just debug:** Used by agent-cycle for result messages. Preserve through refactor.