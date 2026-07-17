# agent/iar-prompt-loader.el -- Annotation

## What It Does

Single function `iar--load-prompt` that reads a prompt template from `agents.d/common/<name>.org`. Returns the content as a string with trailing newlines trimmed. Signals error if file not found. Used by delegate-tool, agent-cycle, loop-guard, memory-tools, and tool-guard.

## Key Functions

- `iar--load-prompt` -- reads prompt template by name from common prompts directory. Returns string or signals error.

## What's Good

- **Clean, focused module.** One function, one responsibility. This is the model for what other modules should look like in terms of focus.
- **`string-trim-right` with `"\n"`** -- trims only trailing newlines, not all whitespace. Correct for curated prompt files where only EOF newlines are the concern.
- **Forward-declaration with docstring.** Consistent with the pattern across the codebase.
- **Separates prompt content from code logic.** This is the pattern the entire codebase should follow (Day 1 finding #4).

## Issues Found

### 1. Clean module -- reference model [NOTE -- POSITIVE]
**Problem:** None. This is what other modules should aspire to in terms of focus.
**Action:** Use as reference example in GUIDELINES.md for "one function, one responsibility" modules.

### 2. `string-trim-right` with `"\n"` is correct [NOTE -- ACCEPTABLE]
**Problem:** Different from `string-trim` used in agent-loader, but intentional -- prompts are curated files, only EOF newlines are the concern.
**Decision:** User confirms this is fine. No change.

### 3. No path traversal defense [ISSUE -- UNIFY SECURITY]
**Problem:** Unlike `iar--load-agent-profile` which checks `file-truename`, this function just expands and reads. The `name` parameter comes from code, so risk is low, but there's no defense if a path-like string is ever passed.
**Decision:** User says don't duplicate security measures. Unify where they live and call them as utility functions. Path traversal defense should be a shared utility, not reimplemented per module.
**Action:** Extract path traversal check to shared utils. All file-reading functions call it.

### 4. Signals error vs returns nil -- inconsistent [ISSUE -- ALREADY TRACKED]
**Problem:** `iar--load-prompt` signals on missing file. `iar--load-agent-profile` returns nil. Inconsistent error handling.
**Decision:** User says: always return nil on failure. Somewhere along the chain someone catches the nil and does something -- signals, loads a sane default, etc. The leaf function returns nil, the caller decides how to handle.
**Action:** Change `iar--load-prompt` to return nil instead of signaling. Callers handle nil (delegate-tool, agent-cycle, loop-guard, memory-tools, tool-guard). Already tracked as part of error handling unification.

### 5. No caching [ISSUE -- FLAG FOR DISCUSSION]
**Problem:** Every call reads from disk. Fine for current usage, but if prompt loading becomes hot, there's no cache.
**Decision:** User says this will become more relevant. Discussion needed about what needs caching and when, before refactoring.
**Action:** Flag for discussion during refactor. Consider prompt cache strategy as part of the broader architecture.

### 6. Forward-declaration with docstring [NOTE -- GOOD]
**Problem:** None. Consistent pattern.
**Action:** No change.

### 7. Docstring example references "darwin_cycle" [ISSUE -- DOC]
**Problem:** Example uses `darwin_cycle` but darwin doesn't have a per-agent cycle prompt. The example should stay general and not reference any agent prompt that might be missing in the future.
**Action:** Update example to use a generic name like `"agent_cycle"` or `"delegated_task"`.

## Patterns to Watch

- **One function, one responsibility:** This module is the reference model. GUIDELINES.md should use it as an example.
- **Security as shared utility:** Path traversal defense should not be reimplemented per module. Extract to shared utils, call from all file-reading functions.
- **Nil-return convention (confirmed):** Leaf functions return nil on failure. Callers decide how to handle (signal, default, propagate). `iar--load-prompt` needs to change from signaling to returning nil.
- **Caching strategy:** Needs discussion before refactor. What gets cached, when, how invalidated.