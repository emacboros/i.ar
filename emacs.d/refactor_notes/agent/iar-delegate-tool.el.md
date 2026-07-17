# agent/iar-delegate-tool.el -- Annotation

## What It Does

The delegate tool. Allows an agent to spawn a sub-agent with a specific profile to handle a sub-task. Async tool (gptel `:async` convention). Creates a separate gptel buffer for the sub-agent, sets up completion hooks, timeout handling, depth limiting, unknown tool blocking, and text-only turn re-prompting. Returns only the post-`=== DELEGATION RESULT ===` marker text to the parent to keep parent context clean.

## Key Functions

- `iar--delegate-timeout-handler` -- fires when sub-agent doesn't complete in time. Aborts gptel request, captures partial response, cleans up buffer with delayed kill.
- `iar--mygptel--tool-delegate` -- async tool entry point. Validates agent/task strings, loads profile, calls spawn. Handles timeout type coercion (int, string, number, default).
- `iar--delegate-continue-prompt` -- defconst loaded at module load time via `iar--load-prompt "delegate_continue"`. Prompt sent when sub-agent narrates instead of acting.
- `iar--mygptel--delegate-completion-fn` -- factory returning a lambda. 3-case state machine: (1) tools called -> extract result after marker, callback, cleanup. (2) no tools, under max turns -> re-prompt. (3) no tools, max turns -> return whatever we have.
- `iar--spawn-async-delegate` -- creates the delegate buffer, sets system prompt, agent tracking, depth limiting (removes delegate tool at max depth), hooks, timeout timer, inserts prompt, sends.
- Tool registration at bottom via `gptel-make-tool` + `add-to-list`.

## What's Good

- **Result extraction via marker.** Only text after `=== DELEGATION RESULT ===` is returned to the parent. Keeps parent context clean -- no tool call syntax or raw results leak.
- **`make-symbol` for mutable shared state.** Gensyms used as mutable boxes across closures. Correct Emacs pattern for sharing state between completion hook and timeout handler without globals.
- **Depth limiting via tool removal.** At max depth, the delegate tool is removed from `gptel-tools` buffer-locally. Sub-agent simply can't recurse further. Clean approach.
- **Text-only turn re-prompting.** Models that narrate instead of acting get re-prompted with a continue prompt. Prevents premature termination with non-results. Max turns cap prevents infinite loops.
- **Timeout handler with partial response capture.** If the sub-agent hangs, the timeout handler captures whatever was generated and returns it with a notice. No silent loss.
- **`completed-sym` prevents double-callback race.** Using a symbol (not a captured boolean) means the timeout handler and completion hook can both check/update the same flag without a race. Well-designed.

## Issues Found

### 1. `my-gptel--delegate-depth` uses old prefix [ISSUE -- ALREADY TRACKED]
**Problem:** `my-gptel--delegate-depth` still uses the `my-gptel--` prefix. Day 1 finding #6: all `my-gptel--` renamed to `iar--`.
**Action:** Rename during refactor.

### 2. `make-symbol` pattern [NOTE -- ACCEPTABLE]
**Problem:** Gensyms as mutable boxes across closures. Non-obvious for readers unfamiliar with the technique.
**Decision:** User is okay with newer language features that simplify code. The reader is tasked with learning the syntax. Keep as-is.

### 3. `iar--delegate-continue-prompt` loaded at module load time [ISSUE -- UNIFY]
**Problem:** defconst evaluated once at module load. If prompt file changes, need module reload. Contrast with agent-loader which lazy-loads `ox` at call time. Inconsistent module loading strategies.
**Decision:** User prefers unification -- modules should work the same way. User likes the agent-loader design (lazy load). But also fine with the restriction that prompts don't change at runtime. Unify the approach across all modules during refactor.

### 4. Docstring says "streamed live into parent buffer" but no mirroring exists [ISSUE -- DOC]
**Problem:** `iar--spawn-async-delegate` docstring says "The sub-agent's streaming output is mirrored into the parent buffer so the user can watch progress in real time." This is legacy functionality -- no mirroring code exists. Sub-agent streams into its own buffer only.
**Decision:** User confirms this is legacy. Update docstring during refactor.

### 5. `string-match-p "\\S-"` appears 3 more times [ISSUE -- EXTRACT TO UTILS]
**Problem:** Third file with this pattern. Confirmed cross-file.
**Action:** Extract to shared utils during refactor.

### 6. Mount awareness `boundp` + `fboundp` check duplicated [ISSUE -- DUPLICATE]
**Problem:** Same defensive pattern as agent-loader, same code, different module.
**Action:** Flag for discussion (same as agent-loader issue #8). Resolve once for both modules.

### 7. Dual tracking (buffer-local + global) duplicated [ISSUE -- DUPLICATE]
**Problem:** Same agent name/file tracking code as agent-loader, same comment, different module.
**Action:** Flag for discussion (same as agent-loader issue #7). After tool call layer refactor, debug modules change and this may not be needed.

### 8. `resp-start` closure capture [NOTE -- ACCEPTABLE]
**Problem:** `resp-start` bound as nil in `let*`, then `setq` after insert. Timeout handler closes over the variable (not value), sees updated value. Correct but requires understanding Elisp closure semantics.
**Decision:** Same as point 2 -- acceptable, reader learns the syntax.

### 9. Inconsistent buffer kill delays (3s vs 5s) [ISSUE -- FLAG FOR REFACTOR]
**Problem:** Timeout handler kills buffer with 3-second delay. Completion function kills with 5-second delay. Same purpose, different values.
**Action:** Unify during refactor. Pick one delay value.

### 10. Compat layer dependency [ISSUE -- ALREADY TRACKED]
**Problem:** `require 'iar-gptel-compat` for hook defvaraliases. After tool call layer refactor (Day 1 finding #1), these become i.ar's own hooks. Dependency disappears.
**Action:** Resolved by tool call layer refactor.

### 11. Depth limiting via tool removal [ISSUE -- FLAG FOR DISCUSSION]
**Problem:** Removes delegate tool from `gptel-tools` at max depth using `cl-remove-if` on `copy-sequence`. Works, but after tool gating architecture is in place, this might be handled differently.
**Decision:** User says needs further discussion after new architecture is in place. Flag for post-refactor discussion.

### 12. `gptel-confirm-tool-calls` set to nil [ISSUE -- REMOVE]
**Problem:** Delegates don't ask for human confirmation. User sees this as adding friction that won't be needed once rate-limiting and network-level restrictions are in place. Restrictions should be framework-level, not per-tool-call.
**Decision:** User says `gptel-confirm-tool-calls` won't be necessary after rate-limiting and network restrictions. Flag for removal during refactor (or when those features land).

### 13. 3-case completion state machine duplicated with agent-cycle [ISSUE -- FLAG FOR DISCUSSION]
**Problem:** The completion function implements a mini-FSM (tools called -> done, no tools under max -> re-prompt, no tools max reached -> done). Same pattern in `iar-agent-cycle.el` for continuation. Potential for shared abstraction.
**Decision:** User agrees. Flag for discussion during refactor. Consider shared continuation/re-prompt abstraction.

### 14. Module location: agent/ vs tools/ [ISSUE -- MOVE]
**Problem:** This module is in `agent/` but registers a tool via `gptel-make-tool`. It's a hybrid -- agent system module that also registers a tool. The tool registration and the agent spawning logic are coupled in one file.
**Decision:** User says this should be in the tools dir. Separate what is the tool's job from the agent functions' job. Split during refactor -- tool registration goes to `tools/`, agent spawning logic stays in `agent/` (or appropriate subfolder).

## Patterns to Watch

- **`make-symbol` for mutable shared state:** Acceptable pattern. Reader learns it. No change needed.
- **Module loading strategy inconsistency:** Some modules load dependencies at boot, some at call time. Some load prompts as defconst at module load, some load at call time. Unify in GUIDELINES.md.
- **Completion/re-prompt state machine:** Same 3-case pattern appears in delegate and agent-cycle. Candidate for shared abstraction. Discuss during refactor.
- **Buffer kill delay inconsistency:** Different delay values for the same purpose. Unify.
- **Tool registration location:** Tools that are also agent system modules need to be split. Tool registration in `tools/`, logic in `agent/`.
- **Duplicated patterns across agent modules:** Mount awareness check, dual tracking, `string-match-p "\\S-"` -- all duplicated across agent-loader, knowledge-loader, and delegate-tool. Extract shared code.