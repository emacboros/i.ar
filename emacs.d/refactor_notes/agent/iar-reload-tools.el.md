# agent/iar-reload-tools.el -- Annotation

## What It Does

Two tools: `reload_os` (re-evaluates init.el, rebuilds gptel-tools) and `reload_agent` (re-reads agent prompt.org, updates system prompt in current buffer). Both are sync tools. Both have `condition-case` error handling returning "Success:" or "Error:" strings.

## Key Functions

- `iar--mygptel--tool-reload-os` -- resets global `gptel-tools` to nil, clears buffer-local `gptel-tools`, re-loads init.el. Returns success with tool count.
- `iar--mygptel--tool-reload-agent` -- optional agent-name or current agent. Validates name, path traversal check, loads profile via `iar--load-agent-profile`, sets system prompt, updates agent tracking. Returns success with char count.

## What's Good

- **Two distinct tools, each with clear purpose.** reload_os for .el changes, reload_agent for .org changes. Clean separation of concerns.
- **`condition-case` returns descriptive error strings.** Tools return "Success:"/"Error:" with context. Agents can self-correct based on the error message.
- **`reload_os` clears buffer-local `gptel-tools` before reload.** Prevents stale buffer-local tool lists from persisting after init.el re-evaluation.
- **`reload_agent` falls back to current agent when no name provided.** Convenient for the common case (agent reloads its own profile after editing it).

## Issues Found

### 1. `(load init-path nil t)` + `condition-case` double error suppression [ISSUE -- FLAG FOR DISCUSSION]
**Problem:** `load` is called with `nil t` (no error, no message), but it's inside a `condition-case` anyway. The `nil t` suppresses errors at the `load` level, so the `condition-case` never fires. If `load` fails silently (returns nil), the function reports success with whatever tool count exists. False success.
**Context:** User has seen this work not so well in practice.
**Action:** Flag for discussion. Likely fix: remove `nil t` so `load` signals and `condition-case` catches. Decide during refactor.

### 2. `reload_os` resets `gptel-tools` globally via `set-default` [ISSUE -- FLAG FOR REVIEW]
**Problem:** Affects ALL buffers, not just the current one. If another gptel buffer is active (e.g., a delegate mid-execution), its tool list gets wiped and rebuilt. Could cause issues.
**Action:** Flag for review during refactor. Consider whether global reset is necessary or if buffer-local reset suffices.

### 3. Redundant path traversal check [ISSUE -- ALREADY TRACKED]
**Problem:** `reload_agent` does its own `file-truename` + `string-prefix-p` check, but `iar--load-agent-profile` already does this. Comment acknowledges: "Extra safety."
**Action:** Already tracked. Extract path traversal to shared utils, call once.

### 4. Redundant agent name validation [ISSUE -- ALREADY TRACKED]
**Problem:** `iar--validate-agent-name` called explicitly, then `iar--load-agent-profile` also validates. Comment acknowledges: "defense-in-depth, not the primary check."
**Action:** Already tracked. Unify validation in shared utils, call once.

### 5. Mount awareness `boundp` + `fboundp` check duplicated 4th time [ISSUE -- DUPLICATE]
**Problem:** Same pattern in agent-loader, delegate-tool, agent-cycle, and here.
**Action:** Already tracked. Resolve once for all modules.

### 6. Dual tracking (buffer-local + global) duplicated 4th time [ISSUE -- DUPLICATE]
**Problem:** Same pattern in agent-loader, delegate-tool, agent-cycle, and here.
**Action:** Already tracked. Resolve after tool call layer refactor.

### 7. `string-match-p "\\S-"` appears again [ISSUE -- EXTRACT TO UTILS]
**Problem:** 5th file. Used to check if agent-name is non-blank.
**Action:** Already tracked. Extract to shared utils.

### 8. Two conventions confirmed: tools vs internal functions [NOTE -- CONVENTION]
**Problem:** Tools return "Success:"/"Error:" strings (for LLM consumption). Internal functions return nil on failure (for caller handling).
**Decision:** User confirms: common function errors are handled in code, tool errors are meant to be handled by the LLM. Every tool error should have a descriptive message of what failed and why so the agent can self-correct.
**Action:** Document in GUIDELINES.md as a convention. Two layers, two error strategies.

### 9. `my-gptel--` prefix on both functions [ISSUE -- ALREADY TRACKED]
**Problem:** Day 1 finding #6: rename all `my-gptel--` to `iar--`.
**Action:** Rename during refactor.

### 10. Module location: should be in tools/ [ISSUE -- SPLIT]
**Problem:** Two tools in one file in `agent/`. Should be separated into two files in the `tools/` directory. The functions ARE the tools -- there's no separate agent logic.
**Decision:** User says split into two files in tools folder.
**Action:** Move `reload_os` to `tools/` and `reload_agent` to `tools/` as separate files during refactor.

### 11. `reload_os` is the most powerful tool [NOTE -- SECURITY]
**Problem:** Re-evaluates the entire init.el. If an agent has modified a .el file with bad code, `reload_os` executes it. By design (self-modification), but this is the most powerful tool in the system.
**Action:** Note for security documentation. No code change needed.

### 12. `reload_agent` triggers `require 'ox` lazy load [NOTE -- MINOR]
**Problem:** Calls `iar--load-agent-profile` -> `iar-read-agent-profile` -> `require 'ox`. First reload in a fresh buffer adds latency from org-export lazy load.
**Action:** Already tracked as part of boot-time vs call-time require unification.

## Patterns to Watch

- **Two error conventions (confirmed):** Tools return "Success:"/"Error:" strings for LLM self-correction. Internal functions return nil for caller handling. Document in GUIDELINES.md.
- **Module location:** Tools go in `tools/`, one tool per file. Even when the function IS the tool, it belongs in `tools/`.
- **Double error suppression:** `load` with `nil t` inside `condition-case` can produce false success. Watch for this pattern elsewhere.
- **Redundant security checks:** Path traversal and name validation done in multiple places. Unify in shared utils.