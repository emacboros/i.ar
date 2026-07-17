# test/ -- Annotation (21 test files, 553 tests)

## Overview

21 test files, 553 total tests. Coverage report at `test/coverage.txt`. Tests use ERT framework with `cl-letf` for mocking. Temp directories via `make-temp-file` with `:dir-flag`. Cleanup via `unwind-protect` + `delete-directory`. Integration tests tagged `:integration` (30 tests across 3 files). Smoke tests tagged `:smoke` (5 tests in test-smoke.el).

## Test File Inventory

| File | Tests | Module Under Test | Coverage |
|------|-------|-------------------|----------|
| test-agent.el | 15 | iar-agent-loader | 84% |
| test-audit.el | 35 | iar-audit-log | 100% |
| test-buffer-monitor.el | 8 | iar-buffer-monitor | N/A* |
| test-check.el | 12 | check_elisp | 97% |
| test-code.el | 14 | execute_code_local | 100% |
| test-darwin-cycle.el | 75 | iar-agent-cycle | 19% |
| test-debug-modules.el | 10 | request-logger + fsm-tracer | N/A* |
| test-delegate.el | 38 | iar-delegate-tool | 75% |
| test-file-guard.el | 62 | iar-file-guard | 94% |
| test-fs.el | 72 | filesystem tools | 93-100% |
| test-gptel.el | 4 | iar-gptel-setup | N/A* |
| test-loop.el | 36 | iar-loop-guard | 100% |
| test-memory.el | 45 | iar-memory-tools | 88% |
| test-reload.el | 19 | iar-reload-tools | 78% |
| test-replace.el | 18 | replace_in_file | 97% |
| test-sanitizer.el | 42 | iar-output-sanitizer | 100% |
| test-smoke.el | 5 | end-to-end load | N/A* |
| test-task.el | 27 | task tools | 90-100% |
| test-tool-result-truncation.el | 11 | iar-tool-result-truncation | 100% |
| test-unknown-tool.el | 5 | iar-tool-guard | 100% |

*N/A = not in coverage report (module loaded differently or not instrumented)

## Coverage Gaps

| Module | Coverage | Why |
|--------|----------|-----|
| iar-agent-cycle | 19% | Only pure helper functions tested (completion detection, profile loading). Main `iar-run-cycle` involves FSM, timers, batch event loop -- too complex to unit test without heavy mocking. |
| iar-knowledge-loader | 0% | No tests at all. Knowledge loading, prompt info, buffer info, prompt viewer all untested. |
| git_commit | 0% | No tests. Git operations require a real repo. |
| telegram | 0% | No tests. Network operation. |
| iar-quit | 0% | No tests. Session-aware quit involves summarization + kill. |
| iar-mount-awareness | 4% | Almost no tests. Mount parsing untested. |

## What's Good

- **Temp directory pattern is consistent.** `make-temp-file` with `:dir-flag`, cleanup via `unwind-protect` + `delete-directory`. Used across most test files.
- **`cl-letf` for mocking.** Standard Emacs mocking pattern. Mocks `completing-read`, `call-process`, `message`, internal functions. No external mocking framework needed.
- **Integration test tagging.** `:tags '(integration)` on tests that spawn real processes or re-evaluate init.el. Can be excluded from coverage runs (reload_os tests wipe coverage data).
- **Security-focused tests.** test-file-guard.el has 62 tests -- the most of any file. Path traversal, symlink defense, tier enforcement, append exceptions all tested. Good security coverage.
- **test-task.el has 13 should-error tests.** Validates name rejection, path traversal, multi-line injection. Good input validation coverage.
- **Coverage reporting via undercover.** Text report at coverage.txt. Shows gaps clearly.

## Issues Found

### 1. No tests for knowledge-loader [ISSUE -- GAP]
**Problem:** 0% coverage. Knowledge loading, prompt info, buffer info, prompt viewer all untested. This is a user-facing module (C-c k, C-c p, C-c b).
**Action:** Write tests during refactor. At minimum: knowledge stacking, idempotency, prompt rebuild, delimiter wrapping.

### 2. No tests for git_commit and telegram [ISSUE -- GAP]
**Problem:** 0% coverage. Both are tools that agents use in production.
**Context:** Git requires a real repo, telegram requires network. But `call-process` can be mocked (as test-darwin-cycle does), and curl can be mocked.
**Action:** Write tests during or after refactor. Mock `call-process` for git, mock `make-process` for telegram.

### 3. No tests for iar-quit [ISSUE -- GAP]
**Problem:** 0% coverage. Session-aware quit involves summarization + kill.
**Action:** Write tests. Mock `iar-summarize-session` and verify quit behavior.

### 4. No tests for mount-awareness [ISSUE -- GAP]
**Problem:** 4% coverage. Mount parsing untested.
**Action:** Write tests for `iar--parse-extra-mounts` and `iar--extra-mounts-prompt-string`.

### 5. iar-agent-cycle at 19% coverage [ISSUE -- KNOWN LIMITATION]
**Problem:** Only pure helpers tested. Main `iar-run-cycle` involves FSM, timers, batch event loop.
**Context:** After tool call layer refactor, the cycle runner changes fundamentally. Writing tests now is wasted effort.
**Action:** Write tests after refactor. The new architecture should be more testable.

### 6. Test runner load order duplicates init.el [NOTE -- FRAGILE]
**Problem:** `run-tests.el` manually lists subdirectories in dependency order, mirroring init.el. If init.el load order changes, run-tests.el must be updated too. Two sources of truth for load order.
**Action:** Flag for refactor. Consider a shared load-order definition or auto-discovery.

### 7. Coverage excludes reload_os tests [NOTE -- WORKAROUND]
**Problem:** `reload_os` re-evaluates init.el which re-instruments source files through undercover, wiping coverage data. Tests tagged `:reload` are excluded when coverage is active.
**Action:** Acceptable workaround. Document in GUIDELINES.md if coverage is used during refactor.

### 8. No test for the summarizer return value bug [ISSUE -- GAP]
**Problem:** The confirmed bug (reload-agent failure contaminates success path) has no test. test-memory.el mocks the Ollama call but doesn't test the full `iar-summarize-session` return value path.
**Action:** Write a test that verifies `iar-summarize-session` returns `t` on success even when reload-agent fails. Or just fix the bug during the rewrite.

### 9. Test naming convention is consistent [NOTE -- POSITIVE]
**Problem:** `test-<module-name>.el` naming. Test names: `test-<module>-<behavior>`. Consistent across all files.
**Action:** Document in GUIDELINES.md as the test naming convention.

### 10. `should` assertions heavily favor string matching [NOTE -- DATA]
**Problem:** 351 `should (string-match-p ...)`, 164 `should (stringp ...)`, 114 `should (string= ...)`. Tests verify string content more than structural properties. This is appropriate for tools that return strings, but could miss structural regressions.
**Action:** Note for GUIDELINES.md: prefer structural assertions (equal, length, plist-get) over string matching where possible. String matching is fine for tool return values.

## Patterns to Watch

- **Test module template:** `test-<module>.el`, `require ert`, temp dir setup, `unwind-protect` cleanup, `ert-deftest test-<module>-<behavior>`. Document in GUIDELINES.md.
- **Mocking via `cl-letf`:** No external framework. Standard Emacs pattern. Document as the mocking convention.
- **Integration test tagging:** `:tags '(integration)` for tests that spawn processes or re-evaluate code. Document as the convention.
- **Coverage gaps map to refactor priorities:** Modules with 0% coverage (knowledge-loader, git_commit, telegram, iar-quit, mount-awareness) need tests. Write during or after refactor.
- **Two sources of truth for load order:** init.el and run-tests.el both list module subdirectories in order. Fragile. Consider unifying.