# agent/iar-knowledge-loader.el -- Annotation

## What It Does

The C-c k entry point. Loads knowledge bases (directories of .md/.org files) from `knowledge/<folder>/` and injects them into the system prompt with delimiters. Supports stacking multiple knowledge bases. Also provides C-c p (prompt info), C-c b (buffer info), and a prompt viewer. Used non-interactively by `agent_cycle.el` via `iar-load-knowledge-dir` for batch mode.

## Key Functions

- `iar--knowledge-dir` -- resolves the knowledge directory path.
- `iar--knowledge-candidates` -- lists subdirectories as `(DISPLAY . PATH)` cons cells.
- `iar--read-knowledge-files` -- reads all .md/.org from a directory (non-recursive, sorted), joins with file separators. Returns nil if no content.
- `iar--knowledge-label` -- returns its first argument. Identity function, dead code.
- `iar--knowledge-rebuild-prompt` -- rebuilds system prompt from personality + all knowledge blocks with delimiters.
- `iar-load-knowledge-dir` -- non-interactive loader. Takes label, looks up path, checks idempotency, reads files, stores in blocks alist, rebuilds prompt. Returns t/nil. Uses `cl-return-from` for early exits.
- `iar-load-knowledge` -- interactive C-c k. completing-read, delegates to `iar-load-knowledge-dir`.
- `iar-prompt-info` -- C-c p. Personality vs knowledge breakdown.
- `iar-buffer-info` -- C-c b. Conversation buffer + prompt size + total.
- `iar-view-prompt` -- view full system prompt in read-only buffer.
- `iar--format-size` -- formats chars + approx tokens for display.

## What's Good

- **Stacking model is clean.** `iar--knowledge-blocks` alist + `iar--knowledge-rebuild-prompt` makes adding/removing knowledge bases straightforward. Each load adds an entry, rebuild is deterministic.
- **Idempotency check.** Already-loaded knowledge is a no-op with a message. Prevents duplicate injection.
- **Non-interactive path for batch mode.** `iar-load-knowledge-dir` is separate from the interactive `iar-load-knowledge`, safe for `agent_cycle.el` to call. No completing-read, no user-error.
- **`save-restriction (widen)` in `iar-buffer-info`.** Correct fix from Day 1 -- uses `buffer-size` after widening, not `point-max` in a narrowed buffer.
- **Prompt viewer.** `iar-view-prompt` shows exactly what the LLM receives. Useful for debugging prompt construction and token cost.

## Issues Found

### 1. `cl-return-from` without explicit `cl-block` [ISSUE -- FLAG FOR REFACTOR]
**Problem:** `cl-return-from` used 3 times in `iar-load-knowledge-dir`. Creates an implicit `cl-block` around the function body. Non-obvious control flow for readers unfamiliar with cl-lib's block mechanism.
**Decision:** User wants explicit control flow. Either add explicit `cl-block`, restructure with `cond`/`if`, or use `catch`/`throw`. Decide during refactor.

### 2. `iar--knowledge-label` is dead code [ISSUE -- REMOVE]
**Problem:** Takes `(display _path)`, returns `display`. Identity function with an unused parameter. Called by `iar-load-knowledge` but adds an indirection that does nothing.
**Decision:** User confirms it should go. Inline the call -- `iar-load-knowledge` already has the display string, use it directly as the label.

### 3. `iar-buffer-info` doesn't belong in this module [ISSUE -- SPLIT]
**Problem:** `iar-buffer-info` reports conversation buffer size, which has nothing to do with knowledge loading. It's here as a "prompt/buffer info" UI function, but the module is named "knowledge-loader."
**Decision:** User agrees. This module does too many things. Split needed. GUIDELINES.md should have a file-size/line-count limit. Prefer 3 coupled files in a folder over one large file.

### 4. Prompt delimiters in parameters.el [ISSUE -- ALREADY TRACKED]
**Problem:** `iar-knowledge-open-delimiter`, `iar-knowledge-close-delimiter`, `iar-knowledge-file-separator` are prompt text strings in parameters.el. Day 1 finding #4: prompt text goes in prompt files, not elisp.
**Action:** Move to prompt files during refactor.

### 5. `iar--knowledge-candidates` called twice in interactive path [ISSUE -- FLAG FOR REFACTOR]
**Problem:** `iar-load-knowledge` calls `iar--knowledge-candidates` to build the completing-read list, gets the path from the selection, then passes only the label to `iar-load-knowledge-dir` which calls `iar--knowledge-candidates` again to look up the path. The interactive function already has the path but throws it away.
**Action:** Flag for refactor. Either pass the path directly or restructure the API.

### 6. `setf` + `alist-get` usage [ISSUE -- FLAG FOR DISCUSSION]
**Problem:** `(setf (alist-get label iar--knowledge-blocks nil nil #'equal) content)` -- modern cl-lib pattern. Need to check if this is used consistently across the codebase or if this is the only instance.
**Decision:** User says decide after reading all files. Either full cl-lib adoption or none, not mix-and-match. Flag for group discussion.

### 7. `iar--knowledge-rebuild-prompt` fallback logic [ISSUE -- CONVENTION]
**Problem:** `(or iar--knowledge-base-prompt gptel-system-prompt)` -- the `or` fallback should never trigger because `iar--knowledge-base-prompt` is set before this function is called. Defensive but potentially confusing.
**Decision:** User wants unified strategy for failure cases. This is a case of defensive code that suggests a code path that doesn't exist. Note as part of the nil-handling convention discussion.

### 8. `string-match-p "\\S-"` pattern [ISSUE -- EXTRACT TO UTILS]
**Problem:** Appears in both `iar-agent-loader.el` and here (`iar--read-knowledge-files`). Same "is this string non-blank?" check.
**Decision:** User says it has appeared enough times to justify going into a utils file. Extract as a helper function during refactor.

### 9. `iar-view-prompt` read-only-mode dance [ISSUE -- FLAG FOR REVIEW]
**Problem:** `(read-only-mode -1)` to erase, then `(read-only-mode 1)` + `(view-mode 1)`. Necessary because `erase-buffer` requires a writable buffer.
**Decision:** User wants to see how it looks with `let`-binding `inhibit-read-only` before deciding. Flag for review during refactor.

### 10. `iar-key-buffer-info` declared here [ISSUE -- MOVES WITH SPLIT]
**Problem:** Keybinding defvar for `iar-buffer-info` is declared in this module. If `iar-buffer-info` moves to a separate UI/reporting module, this declaration moves with it.
**Decision:** User agrees. Resolved by the split (issue 3).

## Patterns to Watch

- **File size limit:** User prefers multiple small coupled files over one large file. Candidate for GUIDELINES.md -- maximum line count per file.
- **`string-match-p "\\S-"` as non-blank check:** Now seen in 2 files. Extract to shared utils.
- **cl-lib adoption level:** `setf`/`alist-get`, `cl-return-from`, `cl-remove-if-not` all appear. Need consistent decision on cl-lib usage level.
- **Defensive fallbacks that suggest nonexistent code paths:** `or` fallbacks to values that should always be set. Part of the nil-handling convention discussion.