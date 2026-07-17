# agent/iar-agent-loader.el -- Annotation

## What It Does

The C-c a entry point. Discovers agent profiles under `agents.d/<name>/prompt.org`, reads them, expands `#+INCLUDE` directives via org-export, injects personal files (LOGS.md, SUMMARY.md, MEMORIES.md) from the audit mount, and sets `gptel-system-prompt` buffer-locally. Resets knowledge state on agent switch. Tracks agent name/file both buffer-local and global for debug modules.

## Key Functions

- `iar--read-personal-file` -- reads a file from `audit/<agent>/`, truncates to last N lines if exceeds `iar-personal-file-max-lines`. Returns empty string if file doesn't exist.
- `iar--inject-personal-files` -- assembles profile + personal files. Darwin's MEMORIES.md replaces LOGS.md + SUMMARY.md when MEMORIES.md has content and the other two are empty.
- `iar-read-agent-profile` -- reads the org file, activates org-mode in temp buffer anchored to agent dir, expands `#+INCLUDE`, injects personal files. Always returns a string.
- `iar--load-agent-profile` -- validates agent name, checks path traversal via `file-truename`, calls `iar-read-agent-profile`. Returns nil if file doesn't exist.
- `iar-load-agent` -- interactive entry point. Discovers agents, completing-read, loads profile, sets system prompt, tracks agent name/file, resets knowledge state.

## What's Good

- **Path traversal defense.** `file-truename` check in `iar--load-agent-profile` catches symlink bypass. Correct security posture.
- **Dual tracking (buffer-local + global)** for agent name/file. Well-commented: debug modules run in process buffers, not the gptel buffer, so they need the global default to resolve the agent name.
- **Knowledge state reset on agent switch.** Loading a new agent clears `iar--knowledge-base-prompt`, `iar--knowledge-loaded-labels`, `iar--knowledge-blocks`. Prevents stale knowledge from leaking across agents.
- **Truncation with notice.** Personal files that exceed max-lines are truncated to last N lines with a notice. Full file stays on disk, only the LLM context is affected.
- **`default-directory` anchoring in temp buffer.** `#+INCLUDE` relative paths resolve correctly because the temp buffer is anchored to the agent directory. Subtle but critical.

## Issues Found

### 1. MEMORIES.md content-based switch is intentional but temporary [NOTE -- FEATURE TRACKED]
**Problem:** The logic checks "does MEMORIES.md have content AND are LOGS.md and SUMMARY.md both empty?" -- not "is this agent darwin?" This means any agent with only MEMORIES.md gets the darwin treatment. Currently works because only darwin uses MEMORIES.md.
**Context:** This is intentional. MEMORIES.md is the long-term memory model for ALL agents. The current implementation is a placeholder until a "remember" tool is built. That's a feature, not part of the refactor.
**Action:** Task created: `memories-md-for-all-agents`. No change during refactor.

### 2. `string-match-p "\\S-"` pattern repeated 4 times [NOTE -- MINOR]
**Problem:** Used to check "is this string non-blank?" -- 4 occurrences in `iar--inject-personal-files`.
**Decision:** User says too minor to extract. 5 lines doing the pattern, a helper would increase line count with def + calls. Leave as-is.

### 3. `require 'ox` inside function body [ISSUE -- FLAG FOR REFACTOR]
**Problem:** `require 'ox` is inside `iar-read-agent-profile`, loaded at call time not boot time. Heavy dependency deferred to first use.
**Decision:** User prefers all requires at boot time, not call time. Move to top-level `require` during refactor.

### 4. `_` binding pattern for side effects in let* [ISSUE -- FLAG FOR REFACTOR]
**Problem:** `(let* ((_ (unless (file-directory-p agent-dir) (make-directory agent-dir t))) ...)` -- side effects during binding, discarded result. Unusual style, harder to read.
**Action:** Flag for refactor. Use explicit `unless` form before the `let*` or restructure.

### 5. Forward-declaration comments incomplete [DOC]
**Problem:** Knowledge state variables (`iar--knowledge-base-prompt`, `iar--knowledge-loaded-labels`, `iar--knowledge-blocks`) are defvar'd here with a comment saying "Defined in iar-knowledge-loader.el" -- that's fine. But the comment doesn't explain WHY they're declared here: so this module can reset them on agent switch. The "what" is documented, the "why" is not.
**Fix:** Add: "Declared here so `iar-load-agent' can reset knowledge state when switching agents."

### 6. `iar--load-agent-profile` returns nil on missing file [ISSUE -- CONVENTION]
**Problem:** Returns nil if prompt.org doesn't exist. Callers (interactive `iar-load-agent`, reload_agent tool, delegate) need to handle nil. Currently the interactive path is safe (completing-read with require-match), but delegate/reload call `iar--load-agent-profile` directly and may not handle nil.
**Convention:** User wants GUIDELINES.md rule: functions that can fail return nil, callers must handle nil (propagate or handle). Note this as a convention candidate.

### 7. Dual tracking (buffer-local + global) for debug modules [ISSUE -- FLAG FOR DISCUSSION]
**Problem:** Agent name/file are set both buffer-local and global so debug modules (request logger, FSM tracer, buffer monitor) can resolve the agent name when running in gptel's process buffers.
**Context:** After the tool call layer refactor (Day 1 finding #1), debug modules will hook into i.ar's tool call, not gptel internals. This may eliminate the need for dual tracking.
**Action:** Flag for discussion during refactor. If debug modules no longer run in separate process buffers, the global tracking can be removed.

### 8. Mount awareness `boundp` + `fboundp` check [ISSUE -- FLAG FOR DISCUSSION]
**Problem:** `(if (and (boundp 'iar--extra-mounts-prompt-string) (fboundp 'iar--extra-mounts-prompt-string))` -- defensive check for a function that's always loaded before this module (init.el load order guarantees it).
**Context:** If load order is guaranteed, the check is unnecessary. But if modules become more independent (parameters split, tool call layer), load order guarantees may weaken.
**Action:** Flag for discussion. Decide whether to trust load order or keep defensive checks.

### 9. Public/private API boundary unclear [ISSUE -- FLAG FOR DISCUSSION]
**Problem:** `iar-read-agent-profile` (public, takes filepath) is called by `iar--load-agent-profile` (private, takes agent-name). The public function is the inner one, the private function is the outer wrapper. This is inverted from the usual pattern where the public function is the entry point.
**Question:** Should `iar--load-agent-profile` be renamed to `iar-load-agent-profile` (public) since it's the main entry point? Or should `iar-read-agent-profile` be private since it's an implementation detail?
**Action:** Flag for discussion during refactor. Clarify which functions are the public API.

## Patterns to Watch

- **Forward-declaration pattern:** `defvar` in consuming module, actual `defcustom`/`setq` in config module. Consistent across codebase. Needs standard comment format in GUIDELINES.md.
- **Nil-return convention:** Functions that can fail return nil. Callers must handle. Candidate for GUIDELINES.md.
- **Side-effect-in-binding:** Using `let*` bindings for side effects with `_` as the variable. Unusual, should be flagged as anti-pattern.
- **Lazy require vs boot require:** User prefers boot-time requires. Current code mixes both. Convention needed in GUIDELINES.md.