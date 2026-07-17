# tools/git/git_commit.el -- Annotation

## What It Does

Sync tool. Stages all changes (`git add -A`) and commits in a git repository. Uses `call-process` directly -- no shell, no injection surface. Validates repo directory and `.git` presence. Auto-configures git identity from `iar-git-author-name`/`iar-git-author-email` (falls back to "i.ar Agent" / `<agent>@i.ar.local`). Checks for staged changes before committing. Audit-logged.

## Key Functions

- `iar--git-run` -- runs git with args via `call-process` in repo dir. Returns `(exit-code . output)`.
- `iar--git-ensure-identity` -- checks/sets user.name and user.email from config. Returns t if identity is set.
- `iar--mygptel--tool-git-commit` -- main tool function. Validates, ensures identity, stages, checks for changes, commits, audit-logs.

## What's Good

- **`call-process` directly, no shell.** No injection surface. The `iar--git-run` helper is clean and reusable.
- **Identity fallback chain.** Config values -> "i.ar Agent" defaults. Never fails on missing identity.
- **Checks for staged changes before committing.** Returns "No changes to commit" if clean. Prevents empty commits.
- **Audit logging with truncated message.** 100-char truncation on commit message in audit log. Prevents log bloat.
- **Sync tool, justified.** Local git operations are fast. No need for async.

## Issues Found

### 1. `my-gptel--` prefix [ISSUE -- ALREADY TRACKED]
**Action:** Rename during refactor.

### 2. `my-gptel--audit-log` called directly (old prefix) [ISSUE -- ALREADY TRACKED]
**Problem:** Uses `my-gptel--audit-log` instead of `iar--audit-log` (or whatever the renamed version is).
**Action:** Already tracked as part of `my-gptel--` rename.

### 3. `iar--git-run` is a private helper that could be shared [NOTE -- REVIEW]
**Problem:** `call-process` wrapper for git is useful. Could be extracted to a shared utils if other git operations are needed later.
**Action:** Minor. Keep for now. Extract if more git tools are added.

### 4. No path traversal defense on repo_path [ISSUE -- ALREADY TRACKED]
**Problem:** `repo_path` is expanded but not checked for traversal. Agent could commit to any directory with a `.git` folder.
**Context:** Path traversal defense should be a shared utility (per prompt-loader annotation). All file-reading/writing functions call it.
**Action:** Already tracked. Apply shared path traversal utility.

### 5. `repo_path` parameter uses snake_case [NOTE -- CONVENTION]
**Problem:** Parameter is `repo_path` (snake_case) while elisp convention is `repo-path` (kebab-case). The gptel tool arg is also `repo_path`. This is because the LLM sends JSON with snake_case keys and gptel passes them through.
**Action:** Note for GUIDELINES.md: tool function parameters that come from gptel use snake_case (matching JSON API). Internal functions use kebab-case. Document the distinction.

### 6. Identity check runs 4 git commands [NOTE -- MINOR]
**Problem:** `iar--git-ensure-identity` runs `config user.name`, `config user.email`, then if missing, sets them, then re-checks. 4-6 `call-process` calls. Could be optimized but git config is fast.
**Action:** Minor. Acceptable for sync tool.

## Patterns to Watch

- **`call-process` for no-shell command execution.** No injection surface. Correct pattern for tools that run external commands. Document in GUIDELINES.md.
- **Tool function parameters use snake_case (from JSON/gptel).** Internal functions use kebab-case. Two naming conventions for two contexts.
- **Sync justified for fast local operations.** Same as task tools. Document the rule.

---

# tools/notify/telegram.el -- Annotation

## What It Does

Async tool. Sends a Telegram notification via Bot API. Uses `make-process` with curl. Credentials from `AGENT_TELEGRAM_BOT_TOKEN` and `AGENT_TELEGRAM_CHAT_ID` env vars. Message prefixed with `[AgentName]`. 10s curl timeout, 15s Emacs-level timeout. Audit-logged with 100-char message truncation.

## Key Functions

- `iar--mygptel--tool-telegram` -- async tool function. Validates credentials and message, builds JSON payload, sends via curl, parses response, calls callback with result.

## What's Good

- **Async tool, justified.** Network operation. Correct use of async pattern.
- **Credential validation with descriptive error.** Missing credentials returns clear error message for LLM self-correction.
- **Message prefix with agent name.** Human can identify which agent sent the notification.
- **Double timeout.** 10s curl timeout (`-m 10`) + 15s Emacs-level timeout. Belt and suspenders.
- **Buffer cleanup in sentinel.** Kills process buffer after reading output.
- **JSON response parsing.** Checks `:ok` field from Telegram API response. Distinguishes between API error and parse error.

## Issues Found

### 1. `my-gptel--` prefix [ISSUE -- ALREADY TRACKED]
**Action:** Rename during refactor.

### 2. `my-gptel--audit-log` called directly (old prefix) [ISSUE -- ALREADY TRACKED]
**Action:** Already tracked as part of `my-gptel--` rename.

### 3. Duplicates `iar--cycle-notify-telegram` in agent-cycle.el [ISSUE -- ALREADY TRACKED]
**Problem:** agent-cycle.el reimplements Telegram send logic. This module is the canonical implementation.
**Action:** Already tracked. agent-cycle.el should call this module's function instead.

### 4. Credentials from env vars, not defcustoms [NOTE -- DESIGN]
**Problem:** Reads `AGENT_TELEGRAM_BOT_TOKEN` and `AGENT_TELEGRAM_CHAT_ID` from env vars. agent-cycle.el has defcustoms for the same. Two different credential sources.
**Decision:** This is the tool -- it reads env vars (set by emacboros.sh). agent-cycle.el's defcustoms go away when it uses this module instead. Env vars are the single source of truth.
**Action:** Already tracked. Unify credential source to env vars only.

### 5. JSON payload built inline [NOTE -- ACCEPTABLE]
**Problem:** `json-serialize` with backtick plist. Simple, no need for a helper.
**Action:** Acceptable. Keep.

### 6. No retry on failure [NOTE -- MINOR]
**Problem:** If Telegram API is temporarily unavailable, the tool returns an error. No retry logic.
**Action:** Minor. Notifications are best-effort. Acceptable.

### 7. Timeout lambda captures `proc` and `buf` [NOTE -- ACCEPTABLE]
**Problem:** The 15s timeout lambda closes over `proc` and `buf`. If the process completes before the timer fires, the lambda checks `process-live-p` and does nothing. Correct.
**Action:** Acceptable. Same closure pattern as delegate-tool.

## Patterns to Watch

- **Async tool pattern for network operations.** `make-process` + sentinel + callback. Correct. Document in GUIDELINES.md alongside the sync-for-local-ops rule.
- **Env vars for credentials, not defcustoms.** Credentials set by container launch script. Single source of truth. Document in GUIDELINES.md.
- **Double timeout for network ops.** External timeout (curl `-m`) + internal timeout (Emacs `run-with-timer`). Belt and suspenders for network operations.