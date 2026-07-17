# debug/iar-buffer-monitor.el -- Annotation

## What It Does

Logs conversation buffer size before each `gptel-send` via `:before` advice. Writes to both the central audit log and a per-agent `BUFFER.log`. Warns at `iar-buffer-warn-size` (default 5MB). Aborts send at `iar-buffer-hard-cap` (default nil = disabled). Self-installs at load time.

## Key Functions

- `iar--buffer-monitor-log-path` -- resolves per-agent BUFFER.log path.
- `iar--buffer-monitor-log` -- logs buffer size (bytes, chars, approx tokens, model) to both audit log and per-agent log. Returns plist of size info.
- `iar--mygptel--buffer-monitor-pre-send` -- checks thresholds, warns or aborts.
- `iar-buffer-monitor-setup` -- installs `:before` advice on `gptel-send`.

## What's Good

- **`buffer-size` vs `point-max` distinction.** Bytes vs chars. Threshold checks use chars (token correlation). Correct.
- **`save-restriction (widen)` for char count.** Correct fix from Day 1 -- doesn't under-report in narrowed buffers.
- **Best-effort logging.** `condition-case` on both log writes. Observer module never breaks the send.
- **Hard cap abort.** Prevents catastrophic payload to Ollama. Real problem (2026-07-12 crash), correct defense.

## Issues Found

### 1. Anonymous lambda in advice-add [ISSUE -- ALREADY TRACKED]
**Problem:** Can't be removed by name. `reload_os` re-runs setup, adds duplicate advice.
**Action:** Already tracked. Use named function.

### 2. Direct `write-region` bypasses audit-log module [ISSUE -- INCONSISTENT]
**Problem:** Writes log entries directly instead of using `my-gptel--audit-log`. Rest of codebase uses the shared audit logging function.
**Action:** Flag for refactor. Use shared audit logging.

### 3. `gptel-model` resolution is triple-defensive [NOTE -- ACCEPTABLE]
**Problem:** Three layers of defense (boundp, buffer-local, global, fallback). Probably necessary in advice context.
**Action:** No change. Acceptable for observer module running in unpredictable buffer context.

### 4. `my-gptel--` prefix [ISSUE -- ALREADY TRACKED]
**Problem:** Day 1 finding #6: rename to `iar--`.
**Action:** Rename during refactor.

### 5. Self-install at load time with no double-install guard [ISSUE -- ALREADY TRACKED]
**Problem:** Same as anonymous lambda issue. `reload_os` re-runs setup.
**Action:** Already tracked. Guard against double-install.

### 6. Module changes fundamentally after tool call layer refactor [ISSUE -- REWRITE]
**Problem:** `:before` advice on `gptel-send` hooks into gptel's send mechanism. After tool call layer refactor, buffer monitoring moves to the tool call layer.
**Decision:** User says debug modules will change significantly. Don't spend time on detailed analysis. Flag and move on.
**Action:** Rewrite during/after tool call layer refactor. Heavy debugging lives in the tool call layer.

### 7. Per-agent log path uses `iar--get-agent-name` [ISSUE -- ALREADY TRACKED]
**Problem:** If agent name is "unknown", logs go to `audit/unknown/BUFFER.log`. Dual-tracking issue.
**Action:** Already tracked. Resolved by tool call layer refactor.

### 8. Debug parameters should be in configs/debug/ [ISSUE -- ALREADY TRACKED]
**Problem:** `iar-buffer-warn-size`, `iar-buffer-hard-cap` are in parameters.el. Should be in their own `configs/debug/*.el` file.
**Action:** Already tracked as part of parameters.el split.

## Patterns to Watch

- **Debug modules will be rewritten after tool call layer refactor.** Don't over-invest in current structure. Flag issues, move on.
- **Observer modules use `:before` advice only.** Never `:override` (banned after FSM stuck incident). This constraint may change with tool call layer.
- **Best-effort logging pattern.** `condition-case` on all log writes. Observer never breaks the system. Keep this principle.