;; -*- lexical-binding: t; -*-

;;; Agent Cycle -- Headless batch entry point for autonomous agent loops
;;
;; This module provides `iar-run-cycle', a generic function that:
;; 1. Creates a gptel buffer with the assembled prompt (archetype + personality + project)
;; 2. Sends the cycle prompt ("Wake up. Do your thing. Stop.")
;; 3. Waits for the full delegation chain to complete
;; 4. Exits Emacs when done (or on timeout)
;;
;; The --agent flag specifies a personality name. The archetype is determined
;; by the personality-to-archetype map (e.g., darwin -> autonomous).
;; The project is determined by the personality name (e.g., darwin -> darwin project).
;;
;; Usage (batch mode):
;;   emacs --batch -l /root/.emacs.d/init.el \
;;         --eval '(iar-run-cycle :agent "darwin" :timeout 7200)'

(require 'gptel)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-utils)  ; iar--read-file-string, iar--current-project-name
(require 'iar-prompt-loader)
(require 'iar-tool-guard)
(require 'iar-tool-call)
(require 'iar-request-log)  ; iar--reqlog-last-stop, iar--reqlog-reset-last

;; Forward declarations -- owned by iar-request-log.el (loaded via
;; `load' in init.el, not `require', so the byte-compiler cannot see
;; its defvars when compiling this file). Declared here so the
;; truncated-output guard compiles clean.
(defvar iar--reqlog-last-stop nil)
(defvar iar--reqlog-last-tokens-out nil)
(defvar iar--reqlog-last-tool-specs nil)
(declare-function iar--reqlog-reset-last "iar-request-log.el")
;; (iar--cycle-empty-response-p reads the same shared state; defined
;; below alongside the truncated-output guard it sits next to.)
(require 'iar-agent-loader)  ; iar--archetype-for-personality, iar--project-for-personality, iar--setup-assembled-buffer
(require 'iar-prompt-assembly)  ; iar--assemble-prompt

(defvar iar-guard-allow-self-modification)

;; Forward-declared: owned by configs/cycle.el.
(defvar iar-cycle-timeout nil
  "Default timeout for an agent cycle in seconds.")
(defvar iar-cycle-max-turns nil
  "Maximum number of LLM response turns before forcing cycle end.")

(defconst iar-personality-cycle-map
  ;; darwin/gardener/librarian had autonomous cycle prompts
  ;; (self_modification/monitoring/documentation_sync) -- removed in
  ;; the 2026-09-07 cleanup: the trio's loops were never deployed on
  ;; this infra. The personalities remain for interactive use; a
  ;; --loop invocation without :cycle now fails loud (prompt not
  ;; found), which is the honest behavior.
  '(("aria" . "aria_daily")
    ("continuo" . "continuo_daily"))
  "Mapping from personality names to default cycle files.
Used when :cycle is not explicitly provided to iar-run-cycle.")

;; Forward-declared: owned by configs/paths.el.
(defvar iar-cycles-path nil
  "Relative path to cycle definition files.")
;; Forward-declared: owned by configs/paths.el.
(defvar iar-personalization-path nil
  "Absolute path to the personalization mount point.")
(defvar iar-audit-path nil
  "Relative path to audit log directory.")

;; Forward-declared: defined in the one-shot section below. The
;; fences (cap, breaker, tombstone) dispatch on it so one-shot runs
;; get the same protection as cycles.
(defvar iar--one-shot-state nil)

;;; ---------------------------------------------------------
;;; Token usage summary
;;; ---------------------------------------------------------

(defun iar--cycle-token-summary ()
  "Return a token usage summary string for cycle result messages.
Returns empty string if usage tracking is not available."
  (let ((totals (iar--usage-totals)))
    (format "\nTokens: %d in / %d out / %d total\nRequests: %d"
            (plist-get totals :input-tokens)
            (plist-get totals :output-tokens)
            (plist-get totals :total-tokens)
            (plist-get totals :requests))))

;;; ---------------------------------------------------------
;;; Cycle logging
;;; ---------------------------------------------------------

(defun iar--cycle-log-append (agent-name start end)
  "Append the latest LLM response to audit/<agent-name>/cycle.log.
START and END are buffer positions delimiting the new response text.
Creates the log file if it does not exist.  Prepends a timestamp."
  (when (and (integerp start) (integerp end) (< start end))
    (let* ((project (iar--current-project-name))
           (log-path (expand-file-name
                      (format "%s/%s/cycle.log" project agent-name)
                      (expand-file-name iar-audit-path iar-personalization-path)))
           (timestamp (format-time-string "[%Y-%m-%d %H:%M:%S]"))
           ;; buffer-substring-no-properties is DELIBERATE here: cycle.log is
           ;; a record surface, not a judgment surface -- it stores what the
           ;; model said, verbatim, without overlay/property metadata that
           ;; would leak tool-call scaffolding into the transcript. (aria
           ;; c55 finding applied: properties are provenance, but THIS log's
           ;; purpose is the plain text of the response.)
           (response (with-current-buffer (current-buffer)
                       (save-restriction
                         (widen)
                         (buffer-substring-no-properties
                          (min (max start (point-min)) (point-max))
                          (min (max end (point-min)) (point-max)))))))
      (make-directory (file-name-directory log-path) t)
      (with-temp-buffer
        (insert timestamp "\n" response "\n\n")
        (let ((coding-system-for-write 'utf-8))
          (append-to-file (point-min) (point-max) log-path))))))

;;; ---------------------------------------------------------
;;; Cycle prompt loading
;;; ---------------------------------------------------------

(defun iar--cycle-load-cycle-prompt (cycle-name)
  "Load a cycle prompt from agents.d/cycles/<cycle-name>.org.
CYCLE-NAME is the cycle file name without extension (e.g., self_modification).
Signals an error if the cycle file is not found."
  (let* ((cycles-dir (expand-file-name iar-cycles-path user-emacs-directory))
         (cycle-path (expand-file-name (format "%s.org" cycle-name) cycles-dir)))
    (or (iar--read-file-string cycle-path)
        (error "Cycle '%s' not found at %s" cycle-name cycle-path))))

(defun iar--cycle-for-personality (personality-name)
  "Return the default cycle name for PERSONALITY-NAME.
Looks up `iar-personality-cycle-map'. Returns nil if not in the map."
  (cdr (assoc personality-name iar-personality-cycle-map)))

(defun iar--cycle-load-continue-prompt ()
  "Load the shared continue prompt from agents.d/common/agent_cycle_continue.org.
Signals an error if the file is missing: a cycle without a continue
prompt is a misconfigured house. Before 2026-09-03 this wrapped the
load in ignore-errors and returned nil silently; a nil :continue
made the post-response handler complete the cycle on the first
response with the default exit-code 0 -- the grace-loop expiry
branch (honest exit 1) became dead code, and a timed-out cycle
exited 0 with no tombstone (iar/timeout-exit0-no-continue)."
  (iar--load-prompt "agent_cycle_continue"))


;;; ---------------------------------------------------------
;;; Completion detection utility
;;; ---------------------------------------------------------

(defun iar--cycle-complete-p (&optional buffer start end)
  "Check if BUFFER contains a completion sentinel on its own line.
Returns `loop' if LOOP_COMPLETE is found, `cycle' if CYCLE_COMPLETE is found.
Returns nil if neither is found. Search is case-sensitive.
Sentinel must appear on its own line (surrounded by line boundaries).
If START > END, swaps them. Positions clamped to buffer boundaries.
BUFFER defaults to the current buffer.

c132 (2026-09-09): the search runs over MODEL-TEXT ONLY -- gptel
`ignore' spans (reasoning/thinking blocks) and tool-call spans are
excluded, the same discipline as `iar--cycle-response-text' (c54/c55).
Live-fire evidence: continuo turn 557 (req 260909165458-70) ended
exit 0 with ZERO durable output -- nemotron streamed ~29k chars of
THINKING (which rehearses \"...signal CYCLE_COMPLETE\" as it plans
the ending), emitted empty content, and the sentinel matched inside
the thinking block. A sentinel inside thinking is a REHEARSAL, not
an ENDING. The fences already ignore thinking; the exit detector
must speak the same language."
  (let ((buf (or buffer (current-buffer))))
    (with-current-buffer buf
      (save-restriction
        (widen)
        (let* ((buf-min (point-min))
               (buf-max (point-max))
               (search-start
                (if (and start end (> start end))
                    buf-min  ; start > end: search entire buffer
                  (min (max (or start buf-min) buf-min) buf-max)))
               (search-end
                (if (and start end (> start end))
                    buf-max
                  (max (min (or end buf-max) buf-max) buf-min)))
               (case-fold-search nil))
          (save-excursion
            (catch 'sentinel
              (let ((pos search-start))
                (while (< pos search-end)
                  (let* ((prop (get-text-property pos 'gptel))
                         (next (or (next-single-property-change
                                    pos 'gptel (current-buffer) search-end)
                                   search-end)))
                    (unless (or (eq prop 'ignore)
                                (and (consp prop) (eq (car prop) 'tool)))
                      ;; Model span only: c59 terminator regex (leading
                      ;; prose allowed, trailing anchor preserved).
                      (goto-char pos)
                      (cond
                       ((re-search-forward
                         "^.*\\(?:LOOP_COMPLETE\\)+\\s-*[.!]?\\s-*$" next t)
                        (throw 'sentinel 'loop))
                       ((re-search-forward
                         "^.*\\(?:CYCLE_COMPLETE\\)+\\s-*[.!]?\\s-*$" next t)
                        (throw 'sentinel 'cycle))))
                    (setq pos next)))
                nil))))))))

(defun iar--cycle-load-profile (agent-name)
  "Load a personality profile for AGENT-NAME using the assembly engine.
Returns the assembled prompt string.
Signals an error if the personality is not found."
  (let* ((archetype (iar--archetype-for-personality agent-name))
         (project (iar--project-for-personality agent-name))
         (result (iar--assemble-prompt archetype agent-name project)))
    (plist-get result :prompt)))

;;; ---------------------------------------------------------
;;; Cycle state and hooks
;;; ---------------------------------------------------------

(defvar iar--cycle-state nil
  "Current cycle state as a plist:
:agent       -- agent name string
:buffer      -- cycle buffer
:continue    -- continue prompt string or nil
:max-turns   -- max LLM turns
:turn-count  -- current turn count
:tool-call-count -- total tool calls made
:completed   -- t when cycle is done
:exit-code   -- 0 for CYCLE_COMPLETE, 1 for timeout/error,
;;               2 for LOOP_COMPLETE (task done, iar.sh stops the loop)
:cap-blocks  -- tool calls blocked at the soft cap (hard-cap counter)
:runaway-recovery-given -- t once a text-only output runaway has been
;;               given its one recovery round-trip (second fire ends the run)")

(defun iar--cycle-make-state (agent buf continue max-turns &optional wall-timeout)
  "Create a fresh cycle state plist.
WALL-TIMEOUT (optional, seconds) is the run's wall-clock budget.
:start-time is captured HERE, once -- the shared clock source: the
event loop's deadline and the tool-result budget trailer both read
this value, so the two instruments cannot drift apart (the
instruments-lying class: two clocks that disagree are a fence that
lies about the time it enforces)."
  (list :agent agent :buffer buf :continue continue :max-turns max-turns
        :start-time (current-time) :wall-timeout wall-timeout
        :turn-count 0 :tool-call-count 0 :request-count 0
        :completed nil :exit-code 0
        :cap-blocks 0 :cap-warned nil :same-tool-warned nil
        :tool-totals nil :runaway-recovery-given nil
        :cross-rep-window nil))

(defun iar--cycle-tool-call-tracker (_tool-name _tool-result)
  "Track tool calls in the cycle. Increments tool-call-count.
GLOBAL hook (registered on the default value of
`iar-post-tool-call-functions' at cycle start): the advice that
fires this runs from async sentinels where current-buffer is NOT
the cycle buffer -- a buffer-local hook never fires there (the
2026-09-02 invisible-cycles finding: 360 calls counted as 13).
Guarded: no active state -> silent no-op."
  (when iar--cycle-state
    (cl-incf (plist-get iar--cycle-state :tool-call-count))))

(defvar iar-cycle-same-tool-warn 100
  "Same-tool TOTAL warning threshold (c39 fix B): block ONE call with
a notice when a single tool has been called this many times in the
current run. The c38 finding: 132 execute_code_local calls (a
meter-reading burst) never tripped the chain guard -- varying commands
reset the Jaccard counter faster than it accumulated. A per-tool TOTAL
is immune to variation. Fires once per run (:same-tool-warned); the
warned call is retried, nothing is lost. Raised 40 -> 100
(2026-09-09, Nacho: cycle limits raised across the board; 40 was
calibrated against the old 120-call cap -- with the cap at 300 the
same-tool warn stays at a third of it, and legitimate batched
investigation via execute_code_local can honestly exceed 40 calls
in one deep cycle).")
(defvar iar-cycle-tool-call-warn 150
  "Early-warning threshold for the tool-call cap (census option c,
aria cycle 137 / continuo cycle 3). At this count the NEXT tool
call is blocked ONCE with a budget notice -- the call is not lost,
the model retries it -- and after that warning, calls pass through
until the soft cap. The warning is the only message the model can
see in-cycle; without it a cycle discovers the cap only by hitting
it, and a healthy long cycle dies at the fence it never saw.
Numbers: healthy cycles ran 51-61 calls under the cap-60 era
(census); the warn originally sat AT that edge and killed healthy
cycles. Raised 60 -> 150 alongside the soft cap 120 -> 300
(2026-09-09, Nacho: cycle performance degraded vs interactive;
headroom available) so the warn sits at half the soft cap again.")

(defvar iar-cycle-tool-call-cap 300
  "SOFT cap: tool calls per cycle before tools are blocked.
At the soft cap the cycle does NOT die: further tool calls are
blocked with a message telling the model to write its summary
(CYCLE_COMPLETE) and memory writes are still allowed. The model
gets its landing. Hard kill happens only at
`iar-cycle-tool-call-hard-cap' ignored blocks.
History: 60 was calibrated when the cap killed instantly (53
cycles died Sep 2 with zero record), but a legitimate full cycle
(pulse + agora + sync + thread + memory pass) runs 51-61 calls,
so 60 sat AT the edge of real work and killed healthy cycles
(26 tool-cap exits in 3 days, aria cycle 137 census). Raised to
120 (tool-cap-overcorrection fix, continuo cycle 3), then to 300
(2026-09-09, Nacho: cycles still degraded vs interactive; token
headroom available). Pathology is owned by the chain guard
(shape, 10 same-tool calls) and the context breaker (burn, 800k
chars); this cap is the last-resort absolute bound only.")

(defvar iar-cycle-tool-call-hard-cap 5
  "Ignored soft-cap blocks before the cycle is force-ended.
Each tool call attempted past the soft cap returns a block message
demanding CYCLE_COMPLETE. After this many ignored blocks, the cycle
is ended with exit 1 (runaway confirmed: the model is not
responding to the landing instruction).")

(defun iar--fence-summary-instruction ()
  "Mode-correct instruction for writing the final summary at a fence.
Cycles end with CYCLE_COMPLETE; one-shots wrap the final response in
the delimiter pair. One fence, mode-correct vocabulary: a one-shot
agent must never be told to write a CYCLE_COMPLETE it does not have."
  (if iar--cycle-state
      "Write your final summary now as plain text -- what you did, what landed, what is next -- and end with CYCLE_COMPLETE."
    (format "Write your final summary now as plain text and wrap it in %s and %s."
            iar-one-shot-response-open iar-one-shot-response-close)))

(defun iar--cycle-tool-call-cap (info)
  "Pre-tool-call hook: SOFT tool-call cap with a landing.
INFO is the gptel pre-tool-call plist (:name :args :buffer ...).
At the soft cap the run is NOT killed: the call is blocked with a
message demanding the mode-correct landing (CYCLE_COMPLETE for
cycles, final-response delimiters for one-shots), and MEMORY TOOLS
(append_file, write_file, write_subtask, write_roadmap,
git_commit, send_telegram) are still allowed so the model can
finish its record. After `iar-cycle-tool-call-hard-cap' ignored
blocks, the run is force-ended (exit 1).
Before the soft cap, `iar-cycle-tool-call-warn' (default 60) blocks
ONE non-memory call with a budget notice -- warn-once, the call is
retried. The warn and cap branches are or-wrapped: the block plist
must BE the return. (2026-09-03 inert-warn bug: as a when-sequence,
the warn's :block was discarded by the following cap `when' and the
warning never reached the model -- a fence that fires into the void
never fired. `>=' not `=' on the warn count: a memory tool landing
exactly at the warn count must not skip the warning forever. The
warn window is [warn, cap]: past the cap the urgent landing message
wins -- a cycle past 120 must never be told to retry it.)
Dispatches on the active state: cycle first, then one-shot -- the
fences are mode-generic; one-shot runs were previously UNPROTECTED
(2026-09-03 parity fix). No active state -> nil (interactive
sessions are not capped)."
  (let ((state (or iar--cycle-state iar--one-shot-state)))
    (when state
      (let* ((count (1+ (plist-get state :tool-call-count)))
             (agent (plist-get state :agent))
             (tool-name (plist-get info :name))
             ;; c39 fix B: same-tool TOTAL counter. The c38 finding:
             ;; 132 execute_code_local calls (meter-reading burst)
             ;; never tripped the chain guard because varying commands
             ;; reset the Jaccard counter faster than it accumulated.
             ;; A TOTAL per-tool counter is immune to variation: 40
             ;; calls of the SAME tool is a census, not a workflow.
             ;; The count lives in the state (:tool-totals alist) so
             ;; it survives across calls like the other fence state.
             (prev-same (cdr (assoc tool-name
                                    (plist-get state :tool-totals))))
             (same-count (1+ (or prev-same 0)))
             (tool-totals (if prev-same
                              (plist-get state :tool-totals)
                            (append (plist-get state :tool-totals)
                                    (list (cons tool-name 0))))))
        ;; Record the increment in the state (every call, memory tools
        ;; included -- the census is total).
        (setcdr (assoc tool-name tool-totals) same-count)
        (setq state (plist-put state :tool-totals tool-totals))
        (or (when (and (not (member tool-name '("append_file" "write_file" "write_subtask"
                                                "write_roadmap" "git_commit" "send_telegram")))
                       (>= count iar-cycle-tool-call-warn)
                       (<= count iar-cycle-tool-call-cap)
                       (not (plist-get state :cap-warned)))
          ;; Budget warning: block ONE call with the notice, then pass
          ;; through until the soft cap. The call is not lost -- the
          ;; model retries it after reading the warning.
          (setf (plist-get state :cap-warned) t)
          (iar--fence-state-writeback state)
          (message "[%s] Tool-call budget warning (%d/%d) -- one call blocked with notice"
                   agent count iar-cycle-tool-call-cap)
          (list :block
                (format "Tool-call budget warning: %d of %d tool calls used. You are at the edge of the cap. Batch your remaining work (one command carrying many operations), avoid enumeration walks, and converge this cycle. This call was NOT lost -- retry it. This warning fires once."
                        count iar-cycle-tool-call-cap)))
        (when (and (not (member tool-name '("append_file" "write_file" "write_subtask"
                                            "write_roadmap" "git_commit" "send_telegram")))
                   (>= same-count iar-cycle-same-tool-warn)
                   (< count iar-cycle-tool-call-warn)
                   (not (plist-get state :same-tool-warned)))
          ;; Same-tool total warning: block ONE call with the notice.
          (setf (plist-get state :same-tool-warned) t)
          (iar--fence-state-writeback state)
          (message "[%s] Same-tool warning: %d calls to %s this cycle -- one call blocked with notice"
                   agent same-count tool-name)
          (list :block
                (format "Same-tool warning: %d calls to %s this cycle. You are repeating one tool far past what a workflow needs -- batch (one command carrying many operations) or switch approach. This call was NOT lost -- retry it. This warning fires once."
                        same-count tool-name)))
        (when (> count iar-cycle-tool-call-cap)
          (if (member tool-name '("append_file" "write_file" "write_subtask"
                                  "write_roadmap" "git_commit" "send_telegram"))
              ;; Memory/record tools always allowed past the soft cap:
              ;; the landing IS the memory pass. Counted normally.
              nil
            (let ((blocks (1+ (or (plist-get state :cap-blocks) 0))))
              (setf (plist-get state :cap-blocks) blocks)
              (if (>= blocks iar-cycle-tool-call-hard-cap)
                  ;; Runaway confirmed: model ignoring the landing
                  ;; instruction. c39 fix C (2026-09-07): the FIRST
                  ;; hard-cap fire grants ONE grace round-trip -- the
                  ;; landing prompt is inserted into the buffer and
                  ;; re-sent, so the model can write its record as
                  ;; text (memory tools still allowed). Port of the
                  ;; truncated-output grace pattern (ee2da67) and the
                  ;; timeout grace (iar-run-cycle). Shares
                  ;; :runaway-recovery-given: one snap-out OR one
                  ;; landing per cycle. The SECOND hard-cap fire ends
                  ;; the cycle -- re-sending after two ignored
                  ;; landings would burn another full context.
                  (if (plist-get state :runaway-recovery-given)
                      (progn
                        (message "[%s] Tool-call hard cap: %d ignored soft-cap blocks (2nd fire) -- ending cycle"
                                 agent blocks)
                        (setf (plist-get state :completed) t)
                        (setf (plist-get state :exit-code) 1)
                        (iar--fence-state-writeback state)
                        (list :block
                              (format "Tool-call hard cap reached (%d ignored blocks). The run is ending NOW. Do not call more tools."
                                      blocks)))
                    ;; c39 fix C: FIRST hard-cap fire grants ONE grace
                    ;; round-trip via the block message itself (the
                    ;; model reads the block text as the tool result
                    ;; and its next response is the landing -- no
                    ;; gptel-send from inside a pre-tool-call hook,
                    ;; which would fight the in-flight request
                    ;; machinery). Shares :runaway-recovery-given with
                    ;; the truncated-output and runaway guards: one
                    ;; snap-out OR one landing per cycle. SECOND fire
                    ;; ends the cycle.
                    (progn
                      (setf (plist-get state :runaway-recovery-given) t)
                      (iar--fence-state-writeback state)
                      (message "[%s] Tool-call hard cap: %d ignored soft-cap blocks -- requesting landing (grace round-trip)"
                               agent blocks)
                      (list :block
                            (format "TOOL-CALL LIMIT REACHED (%d ignored soft-cap blocks). This blocked call is your LAST non-memory tool call. Stop all tool calls immediately (memory/record tools excepted: append_file, write_file, write_subtask, write_roadmap, git_commit, send_telegram). Write your summary NOW: what you did, what landed, what is next. Update your memory files. End with CYCLE_COMPLETE on its own line. If you call another non-memory tool, the run ENDS."
                                    blocks))))
                ;; Soft block: demand the landing, allow memory tools.
                (message "[%s] Tool-call soft cap (%d) -- blocking tool, demanding summary (block %d/%d)"
                         agent iar-cycle-tool-call-cap blocks iar-cycle-tool-call-hard-cap)
                (list :block
                      (format "Tool-call soft cap (%d) reached. STOP calling tools (except memory/record tools: append_file, write_file, write_subtask, write_roadmap, git_commit, send_telegram -- those still work). %s"
                              iar-cycle-tool-call-cap
                              (iar--fence-summary-instruction))))))))))))

(defvar iar-cycle-context-limit-chars 800000
  "Cycle buffer size (chars) at which the context circuit breaker fires.
~4 chars per token, so 800k chars is roughly a 200k-token context.
Past this size every round-trip re-sends the whole accumulated
context -- the 2026-09-02 runaway re-sent a ~254k-token context
100+ times (68M prompt tokens from one session). The breaker gives
the model ONE grace round-trip to write a final text summary; any
further tool call ends the cycle.")
(defvar iar-cycle-output-runaway-min-repeats 20
  "Minimum identical trimmed lines in ONE response to flag a text-only
output runaway. A runaway is a single response of repeated text with no
tool call -- the deepseek-v4-flash degradation shape (c-fail REQ-51:
4612 identical \"Let me check the caller.\" lines, 65536 output tokens,
stop=length, cycle burned to timeout). Neither the loop guard (counts
tool calls; zero here) nor the context breaker (measures input buffer,
not output) catches this. 20 identical lines in one response is
essentially impossible in legitimate use; false positives are cheap
(a cycle ends early), false negatives are the silent burn we guard.")

(defvar iar-cycle-truncated-output-threshold 20000
  "Output tokens above which a stop=length (truncated) response is
treated as a runaway. Legitimate complete responses (stop=stop) never
exceed ~14k tokens on continuo (max 13739) or ~31k on aria (one
outlier 31670); a truncated generation at the 32768 num_predict cap
burns ~590k output tokens/day on continuo alone, all mostly lost (the
invisible-turn stub makes the loss survivable, not free). The guard
keys on stop=length + tokens_out > threshold, NOT on raw tokens_out
alone -- a complete 30k-token response is legitimate (c100 data,
knowledge/iar/output-token-burn-2026-09-07.md). 20k sits 1.5x above
the continuo max and 0.6x below the aria outlier; conservative enough
to never false-positive on a complete response while capping the
  truncated burn (the 32768 num_predict cap halves the worst case).")


(defvar iar-cycle-cross-response-window 5
  "Number of recent responses over which the cross-response repetition
guard tracks repeated lines. The deepseek-v4-flash text-only loop
repeats the SAME paragraph ACROSS responses (5-10 reps each, under the
per-response 20-line threshold), so the per-response output-runaway
guard never fires until the final 65536-capped response. This guard
tracks the most-repeated line across the last N responses and fires
when its cumulative count crosses
`iar-cycle-cross-response-threshold' (c111 finding).")

(defvar iar-cycle-cross-response-threshold 30
  "Cumulative count of a single trimmed line across the last
`iar-cycle-cross-response-window' responses at which the cross-response
repetition guard fires. The c111 loop's early responses each carried
5-10 reps of the same line; a window of 5 responses x 10 reps = 50
cumulative would fire around response 5-6. 30 is conservative: it
catches the loop well before the final 65536-token response while
staying far above legitimate use (a line repeated 30 times across 5
responses is essentially impossible in honest work).")

(defun iar--cycle-thinking-only-response-p (start end)
  "Return non-nil if the response region START..END is THINKING-ONLY:
the model produced reasoning (gptel `ignore' spans) but no visible
response text outside them. Measured as: the region is non-trivial
(>500 chars of raw span) while `iar--cycle-response-text' (which
excludes ignore + tool spans) yields under 20 chars of model text
(separators only -- the real fires streamed content:"" throughout).

Evidence (2026-09-10 night fires, continuo/nemotron): all six
truncated-output fires (stop=length, 32768 tokens at the num_predict
cap) were thinking-only -- 1.2-1.4M chars of streamed reasoning,
content empty. A thinking-only truncated response can never land:
the grace round-trip re-sends and the model loops again (fire 2
burns another 32768 tokens + ~10 min wall). The deepseek-era fires
were text loops (the per-response runaway guard's shape); the
nemotron-era fires are the same pathology in the thinking channel.
This predicate is the discriminator: thinking-only truncation ends
the cycle immediately, no grace."
  (when (and (integerp start) (integerp end) (< start end))
    (let ((raw-size (- end start))
          (text (iar--cycle-response-text start end)))
      (and (> raw-size 500)
           (< (length (string-trim text)) 20)))))

(defun iar--cycle-truncated-output-p ()
  "Return non-nil if the most recently completed request was a
truncated generation (stop=length) with output tokens above
`iar-cycle-truncated-output-threshold'. Reads the shared last-request
state published by the request log (:before gptel-curl--stream-cleanup,
which runs before this post-response handler). A truncated response at
the cap is the deepseek-v4-flash degradation shape: the model burns
65536 output tokens mid-thought and the stub survives the loss. The
guard ends the cycle (exit 1) rather than re-send -- re-sending would
burn another num_predict-capped output budget on the same loop."
  (and (equal iar--reqlog-last-stop "length")
       (integerp iar--reqlog-last-tokens-out)
       (> iar--reqlog-last-tokens-out iar-cycle-truncated-output-threshold)))

(defun iar--cycle-empty-response-p ()
  "Return non-nil if the most recently completed request was an
EMPTY text-only end: stop=stop with tokens_out=0 (the 0/0 shape).
Reads the shared last-request state published by the request log
(:before gptel-curl--stream-cleanup, which runs before this
post-response handler). Never fires on missing data (nil stop or
nil tokens-out): no data is not an anomaly, it is absence of
evidence.

aria-0026 ruling (session XI, 2026-09-10): a 0/0 text-only end is
TOMBSTONE-WORTHY, never a clean end. Live-fire: continuo turn 557
(req 260909165458-70) ended exit 0 with zero durable output -- the
cycle evaporated (no memory pass, no record) and LAST-CYCLE.txt
said ok. At the response layer a 0/0 end is indistinguishable from
a clean text-only end; the token counts are the only witness that
distinguishes them. The nemotron streaming anomaly rate is ~1/900
(1 occurrence in continuo's whole current log)."
  (and (equal iar--reqlog-last-stop "stop")
       (integerp iar--reqlog-last-tokens-out)
       (= iar--reqlog-last-tokens-out 0)))

(defun iar--cycle-echo-command (args)
  "Return the COMMAND STRING carried by tool-call ARGS, or nil.
Shape-tolerant (aria-0030 second correction, 2026-09-10 c168):
the Ollama parser (gptel-ollama--sanitize-call-spec) delivers :args
as a PLIST -- (:command \"echo ...\") -- while some backends/tests
deliver a raw string. The c167 hook and predicate matched only the
string shape, so the echo close NEVER fired on the production
Ollama path (live evidence: continuo 22:19Z cycle, REQ -85 echo
executed, no block, one more 2.8k-token round-trip). Accepts:
- plist with :command -> its value (string)
- string -> itself
Anything else -> nil."
  (cond
   ((plistp args) (let ((cmd (plist-get args :command)))
                    (and (stringp cmd) cmd)))
   ((stringp args) args)
   (t nil)))

(defun iar--cycle-terminal-echo-p (start end)
  "Return the close symbol if the response region START..END is a
TERMINAL-SENTINEL ECHO: the model's ONLY act in this response was a
tool call whose command echoes the close sentinel, with no model
text around it. Returns \='loop for a LOOP_COMPLETE echo, \='cycle
for a CYCLE_COMPLETE echo, nil otherwise.

aria-0030 (2026-09-10): nemotron reads \"signal CYCLE_COMPLETE\" as
an ACTION -- it calls execute_code_local with `echo
\"CYCLE_COMPLETE\"' as its closing move. The sentinel detector
(iar--cycle-complete-p) searches MODEL TEXT ONLY (c132 discipline:
a sentinel inside a tool span is a rehearsal, not an ending), so
the echo never registered and the cycle granted more turns -- 12
echo turns, ~31% of one continuo cycle's burn, pure ceremony
between \"done working\" and \"close registered\". The echo's tool
result IS the sentinel in the tool channel; this predicate makes
the listener speak the speaker's language (law 38).

Two conditions, BOTH required:
- The response region's model text (iar--cycle-response-text,
  which excludes ignore + tool spans) is empty or separators-only
  (< 20 chars trimmed, the same threshold as
  iar--cycle-thinking-only-response-p). A response with real text
  plus an echo is mid-work, not a close.
- The JUST-COMPLETED request's LAST tool-use spec (published by
  iar-request-log as iar--reqlog-last-tool-specs) is
  execute_code_local with CYCLE_COMPLETE/LOOP_COMPLETE in its
  args. Last-spec, not any-spec: the close is the final act.

False-close risk is accepted on census evidence: zero echo-only
responses mid-work in any REQUESTS.log census (echoes appear only
at cycle end, reqs 38-58 of 60 in the worst batch). A mid-work
echo-only response closes the cycle early -- never yet observed.
Reads iar--reqlog-last-tool-specs, which the dump publishes :before
the post-response handler runs, so it always describes THIS
response's request, never a stale one."
  (when (and (integerp start) (integerp end) (<= start end))
    (let ((text (and (< start end)
                     (iar--cycle-response-text start end))))
      (when (and text (< (length (string-trim text)) 20)
                 (listp iar--reqlog-last-tool-specs)
                 iar--reqlog-last-tool-specs)
        (let* ((last-spec (car (last iar--reqlog-last-tool-specs)))
               (name (and (plistp last-spec) (plist-get last-spec :name)))
               (args (and (plistp last-spec) (plist-get last-spec :args))))
          (when-let* ((cmd (and (equal name "execute_code_local")
                                (iar--cycle-echo-command args)))
                      (_ (string-match-p "CYCLE_COMPLETE\\|LOOP_COMPLETE" cmd)))
            (if (and (string-match-p "LOOP_COMPLETE" cmd)
                     (not (string-match-p "CYCLE_COMPLETE" cmd)))
                'loop 'cycle)))))))

(defun iar--cycle-terminal-echo-close (info)
  "Pre-tool-call hook: terminal-echo close, TOOL-PATH edition
(aria-0030 correction, 2026-09-10 c167).

The c166 post-response branch below is UNREACHABLE for the exact
case it was built for: an echo-only response carries a tool call,
so the FSM transitions WAIT -> TOOL -> TRET -> WAIT and NEVER
reaches DONE -- `gptel-post-response-functions' fire only on
DONE/ERRS/ABRT (gptel--handle-post-insert/-error/-abort).
Live evidence (continuo cycle 21:36Z 2026-09-10, first run under
the c166 fix): 7 echo requests, zero \"Terminal sentinel echo\"
messages in the service log, cycle ended only via the
thinking-only truncation guard on the NEXT request. The close
must live in the channel that actually runs: the pre-tool-call
hook, which fires for every pending tool call BEFORE execution.

Discriminator (ALL required):
- The call being executed is execute_code_local whose args match
  the ECHO COMMAND SHAPE (echo + sentinel as the whole command) --
  not a census grep that merely mentions the token.
- iar--cycle-terminal-echo-p over the CURRENT response region
  (the FSM's :position..:tracking-marker): last published spec is
  the sentinel echo AND the response's model text is < 20 chars.
  Same predicate as c166, reached through the tool path.

On match: set :completed + :exit-code (CYCLE echo -> 0, LOOP
echo -> 2), writeback, and block the call. The echo itself has
nothing to run; the event loop sees :completed and exits before
the next request is sent. Returns nil otherwise."
  (let ((state (or iar--cycle-state iar--one-shot-state)))
    (when state
      (let* ((name (plist-get info :name))
             (args (plist-get info :args)))
        (when (and (equal name "execute_code_local")
                   (let ((cmd (iar--cycle-echo-command args)))
                     (and cmd
                          (string-match-p
                           "\\`\\s-*echo\\s-+\"?\\(CYCLE\\|LOOP\\)_COMPLETE"
                           cmd))))
          (let* ((buf (plist-get state :buffer))
                 (closep
                  (when (buffer-live-p buf)
                    (with-current-buffer buf
                      (let* ((finfo (and (gptel-fsm-p gptel--fsm-last)
                                         (gptel-fsm-info gptel--fsm-last)))
                             (start (plist-get finfo :position))
                             (end (or (plist-get finfo :tracking-marker)
                                      (plist-get finfo :position))))
                        (when (and start end
                                   (markerp start) (markerp end)
                                   (marker-buffer start)
                                   (eq (marker-buffer start) (marker-buffer end)))
                          (iar--cycle-terminal-echo-p
                           (marker-position start)
                           (marker-position end))))))))
            (when closep
              (let ((agent (plist-get state :agent)))
                (message "[%s] Terminal sentinel echo (pre-tool-call, %s) -- closing cycle"
                         agent (if (eq closep 'loop) "LOOP" "CYCLE"))
                (setq state (plist-put state :completed t))
                (setq state (plist-put state :exit-code
                                       (if (eq closep 'loop) 2 0)))
                (iar--fence-state-writeback state)
                (list :block
                      "Terminal echo close registered -- cycle ending now.")))))))))

(defun iar--fence-state-writeback (state)
  "Write the mutated fence STATE back to its owning global.
The fences alias the active state as (or iar--cycle-state
iar--one-shot-state); setf/plist-put through the alias loses the
write when the key is absent from the state plist: the lossy op is
setf-on-absent-key-through-alias (verified empirically on Emacs
30.2: the alias rebinds to a fresh list, the owning global keeps
the old one; present-key writes DO propagate). The breaker tests caught this 2026-09-03: :breaker-fired was
never pre-initialized, so the armed flag vanished between calls and
the breaker re-armed forever, never ending the run."
  (cond (iar--cycle-state (setq iar--cycle-state state))
        (iar--one-shot-state (setq iar--one-shot-state state)))
  state)

(defun iar--cycle-sendable-context-size (buf)
  "Return the size of BUF in chars EXCLUDING 'ignore (reasoning) regions.
The context circuit breaker measures the buffer that would be SENT to
the model. Reasoning blocks are propertized 'gptel 'ignore and are
excluded from the messages array by gptel--parse-buffer, so they are
NOT part of the sendable context. Measuring (buffer-size buf) instead
over-counts on thinking-heavy runs and false-trips the breaker at
~1/3 real context (roadmap OPEN #2). Walks the buffer summing the
lengths of regions whose 'gptel property is not 'ignore."
  (with-current-buffer buf
    (let ((size 0) (pos (point-min)))
      (while (< pos (point-max))
        (let* ((prop (get-text-property pos 'gptel))
               (next (or (next-single-property-change pos 'gptel buf)
                         (point-max))))
          (unless (eq prop 'ignore)
            (setq size (+ size (- next pos))))
          (setq pos next)))
      size)))

(defun iar--cycle-context-breaker (info)
  "Pre-tool-call hook: context circuit breaker (fix D).
INFO is the gptel pre-tool-call plist (:name :args :buffer ...).

When the active run's buffer exceeds `iar-cycle-context-limit-chars':
first fire blocks the call and arms the breaker (:breaker-fired) --
the model gets one grace round-trip to write its summary as text.
Any further tool call ends the run (completed, exit 1). Under the
limit, or with no active state, returns nil. Dispatches on cycle
state first, then one-shot (one-shot runs were previously
UNPROTECTED). Unlike the tool-call cap (pure pathology stop), the
breaker's grace round-trip exists because the timeout-kill loses
the work: a summary written at 200k tokens is cheaper than
re-deriving it next cycle."
  (let ((state (or iar--cycle-state iar--one-shot-state)))
    (when state
      (let* ((buf (plist-get state :buffer))
             (size (if (buffer-live-p buf)
                       (iar--cycle-sendable-context-size buf) 0)))
        (when (> size iar-cycle-context-limit-chars)
          (if (plist-get state :breaker-fired)
              (let ((agent (plist-get state :agent)))
                (message "[%s] Context circuit breaker: ending run (buffer %d chars)"
                         agent size)
                (setq state (plist-put state :completed t))
                (setq state (plist-put state :exit-code 1))
                (iar--fence-state-writeback state)
                (list :block
                      (format "Context circuit breaker: the summary round-trip already elapsed with the context over the limit (%d chars). The run is ending now."
                              iar-cycle-context-limit-chars)))
            (setq state (plist-put state :breaker-fired t))
            (iar--fence-state-writeback state)
            (message "[cycle] Context circuit breaker armed: %d chars (limit %d)"
                     size iar-cycle-context-limit-chars)
            (list :block
                  (format "Context circuit breaker: this run's context exceeds %d chars (~%d tokens). Every further round-trip re-sends the entire context. Do NOT call any more tools. %s"
                          iar-cycle-context-limit-chars
                          (/ iar-cycle-context-limit-chars 4)
                          (iar--fence-summary-instruction)))))))))

(defun iar--cycle-tombstone (agent-name timeout-secs)
  "Write a [TIMED OUT] tombstone to AGENT-NAME's cycle.log.
Called from the timeout and idle-stall paths of `iar-run-cycle' and
`iar-run-one-shot' BEFORE kill-emacs: the state that exists at kill
time was previously never written -- four cycles on 2026-09-02
burned ~150M tokens with zero record, and a timed-out one-shot
exited 0 with nothing written (same lie, one-shot edition, fixed
2026-09-03). Dispatches on the active state (cycle first, then
one-shot). Records turns, tool calls, token totals, and the last
200 chars of the run buffer (the last model activity). Never
signals: this runs at kill time, an error would mask the exit code."
  (condition-case err
      (let ((state (or iar--cycle-state iar--one-shot-state)))
        (when state
          (let* ((turns (plist-get state :turn-count))
                 (tools (plist-get state :tool-call-count))
                 (buf (plist-get state :buffer))
                 (last-activity
                  (when (buffer-live-p buf)
                    (with-current-buffer buf
                      (buffer-substring-no-properties
                       (max (point-min) (- (point-max) 200))
                       (point-max)))))
                 (totals (iar--usage-totals))
                 (project (iar--current-project-name))
                 (log-path (expand-file-name
                            (format "%s/%s/cycle.log" project agent-name)
                            (expand-file-name iar-audit-path iar-personalization-path))))
            (make-directory (file-name-directory log-path) t)
            (with-temp-buffer
              (insert (format-time-string "[%Y-%m-%d %H:%M:%S] ") "[TIMED OUT]"
                      (format " after %ds. Turns: %d, Tool calls: %d" timeout-secs turns tools)
                      (format "\nTokens: %d in / %d out / %d total / %d requests"
                              (plist-get totals :input-tokens)
                              (plist-get totals :output-tokens)
                              (plist-get totals :total-tokens)
                              (plist-get totals :requests))
                      (when last-activity
                        (format "\nLast activity: %.200s" last-activity))
                      "\n\n")
              (let ((coding-system-for-write 'utf-8))
                (append-to-file (point-min) (point-max) log-path))))))
    (error
     (message "[cycle] Tombstone write failed: %s" (error-message-string err)))))

(defvar iar--cycle-error-strikes 0
  "Consecutive failed-request strikes in the current cycle.
gptel signals a failed request by passing equal start/end positions
to post-response functions (per gptel.el docs: \"this hook runs even
if the request fails. In this case the response beginning and end
positions are both the cursor position at the time of the
request\"). Three strikes -> abort the cycle. Reset on any
successful response.")

(defun iar--cycle-context-over-limit-p (state)
  "Return the cycle buffer size if STATE's buffer exceeds the
context limit, nil otherwise. Shared by the pre-tool-call breaker
and the post-response breaker check: one limit, one contract,
two gates. Nil when there is no state, the buffer is dead, or the
size is under `iar-cycle-context-limit-chars'."
  (when state
    (let ((buf (plist-get state :buffer)))
      (when (buffer-live-p buf)
        (let ((size (iar--cycle-sendable-context-size buf)))
          (when (> size iar-cycle-context-limit-chars)
            size))))))


(defun iar--cycle-response-text (start end)
  "Return the model-response text in region START..END, excluding
gptel machine-inserted regions: tool-call display blocks (propertized
`gptel' `(tool . id)') and their fences (`gptel' `ignore'), and reasoning
blocks (`gptel' `ignore'). The runaway census must not count gptel's
own scaffolding -- aria c54/c55 found the fence firing on ~95 tool-call
display blocks (5211 lines, 131 ``` + 66 identical truncated previews)
with zero model repetition. `buffer-substring-no-properties' strips the
very text-properties that mark machine-inserted regions, so the fence
could not tell scaffolding from speech. Walks the region by `gptel'
property change, including only spans whose property is nil or
`response' (model text + separators), excluding `ignore' (reasoning,
tool fences) and (tool . id) (tool call/result content)."
  (with-current-buffer (current-buffer)
    (save-restriction
      (widen)
      (let ((result "")
            (pos start))
        (while (< pos end)
          (let* ((prop (get-text-property pos 'gptel))
                 (next (or (next-single-property-change pos 'gptel
                                                        (current-buffer) end)
                           end)))
            (unless (or (eq prop 'ignore)
                        (and (consp prop) (eq (car prop) 'tool)))
              (setq result (concat result (buffer-substring pos next))))
            (setq pos next)))
        result))))

(defun iar--cycle-output-runaway-p (start end)
  "Return non-nil if the response region START..END is a text-only
output runaway: many identical trimmed lines in a single response.
A runaway is the model degrading into a repetition loop (repeated
text, no tool call) -- the shape that burned c-fail REQ-51 to timeout
(4612 identical lines, 65536 output tokens, stop=length). The loop
guard counts tool calls (zero here) and the context breaker measures
input buffer (not output), so neither catches it. This is the output
half of the runaway fence. Threshold: `iar-cycle-output-runaway-min-repeats'
identical trimmed lines in one response."
  (when (and (integerp start) (integerp end) (< start end))
    (let ((text (iar--cycle-response-text start end)))
      (let ((counts (make-hash-table :test 'equal))
            (max-count 0))
        (dolist (line (split-string text "\n"))
          (let ((trimmed (string-trim line)))
            (when (> (length trimmed) 0)
              (let ((c (1+ (gethash trimmed counts 0))))
                (puthash trimmed c counts)
                (setq max-count (max max-count c))))))
        (>= max-count iar-cycle-output-runaway-min-repeats)))))

(defun iar--cycle-cross-response-repetition-p (start end)
  "Return non-nil if a single trimmed line has been repeated across the
last `iar-cycle-cross-response-window' responses with a cumulative count
at or above `iar-cycle-cross-response-threshold'. The deepseek-v4-flash
text-only loop repeats the SAME paragraph ACROSS responses (5-10 reps
each, under the per-response 20-line threshold), so the per-response
output-runaway guard never fires until the final 65536-capped response
(c111 finding). This guard catches the loop at response ~5-6, saving
~17 requests of burn per occurrence.

Maintains a sliding window of per-response line-count hashes in the
state's :cross-rep-window (a list of (hash . count) entries, oldest
first, capped at `iar-cycle-cross-response-window'). On each call the
new response's lines are added to the window and the global count; the
oldest response is evicted when the window exceeds the cap. The
window is stored in the active state (cycle or one-shot) so it
survives across responses within a run."
  (when (and (integerp start) (integerp end) (< start end))
    (let* ((state (or iar--cycle-state iar--one-shot-state))
           (window (plist-get state :cross-rep-window))
           (counts (make-hash-table :test 'equal))
           (max-count 0))
      ;; Rebuild the global count from the existing window (the window
      ;; is small -- N hashes -- so rebuilding is cheap and avoids
      ;; drift from eviction bookkeeping).
      (dolist (entry window)
        (maphash (lambda (line c)
                   (puthash line (+ (gethash line counts 0) c) counts))
                 (car entry)))
      ;; Add this response's lines.
      (let ((resp-counts (make-hash-table :test 'equal)))
        (with-current-buffer (current-buffer)
          (save-restriction
            (widen)
            (dolist (line (split-string
                           (iar--cycle-response-text start end) "\n"))
              (let ((trimmed (string-trim line)))
                (when (> (length trimmed) 0)
                  (let ((c (1+ (gethash trimmed resp-counts 0))))
                    (puthash trimmed c resp-counts)
                    ;; Cumulative count = window contribution + 1 per
                    ;; occurrence in THIS response. Adding c (the running
                    ;; per-response count) instead of 1 made counts
                    ;; accumulate triangularly within a single response
                    ;; (1,3,6,10...) -- 10 identical lines hit 55, not 10.
                    (puthash trimmed (1+ (gethash trimmed counts 0)) counts)
                    (setq max-count (max max-count
                                         (gethash trimmed counts)))))))))
        (setq window (append window (list (cons resp-counts
                                                (hash-table-count resp-counts)))))
        ;; Evict the oldest entry when the window exceeds the cap.
        (while (> (length window) iar-cycle-cross-response-window)
          (setq window (cdr window)))
        ;; Persist the window back to the active state.
        (cond (iar--cycle-state
               (setq iar--cycle-state (plist-put iar--cycle-state :cross-rep-window window)))
              (iar--one-shot-state
               (setq iar--one-shot-state (plist-put iar--one-shot-state :cross-rep-window window)))))
      (>= max-count iar-cycle-cross-response-threshold))))

(defun iar--cycle-breaker-text-check (state)
  "Post-response half of the context circuit breaker.
The pre-tool-call breaker only sees TOOL calls; a text-only
runaway (prose responses, no tools, no sentinel) re-sends the full
over-limit context every round-trip and was bounded only by
max-turns -- the exact burn shape the breaker was built to kill.
Called from the handler's continue branch BEFORE the re-send.
Same contract as the tool-call breaker: first over-limit continue
arms the breaker (:breaker-fired) and ALLOWS the re-send -- the
model gets its grace round-trip to write the summary as text; any
further continue at over-limit ends the run (completed, exit 1).
The flag is shared with the tool-call breaker: armed by either
hook, the next over-limit action of either kind ends the run.
Returns non-nil when the re-send is blocked (second fire only).
The arm branch returns nil so the continue re-send goes through:
before 2026-09-06 the arm returned a :block, which the handler
treated as 'blocked, don't re-send' -- suppressing the very
response that would carry the summary and leaving the run idle
until timeout (c67 zombie: 13m48s dead air after the arm)."
  (let ((size (iar--cycle-context-over-limit-p state)))
    (when size
      (let ((agent (plist-get state :agent)))
        (if (plist-get state :breaker-fired)
            (progn
              (message "[%s] Context circuit breaker: ending run (text-only continue at %d chars)"
                       agent size)
              (setq state (plist-put state :completed t))
              (setq state (plist-put state :exit-code 1))
              (iar--fence-state-writeback state)
              t)
          (setq state (plist-put state :breaker-fired t))
          (iar--fence-state-writeback state)
          (message "[%s] Context circuit breaker armed (text-only continue): %d chars (limit %d)"
                   agent size iar-cycle-context-limit-chars)
          ;; Return nil: ALLOW the continue re-send. The model gets
          ;; its grace round-trip to write the summary. (Before
          ;; 2026-09-06 this returned a :block, which the handler
          ;; read as 'don't re-send' -- the summary was never written
          ;; and the run idled until timeout: the c67 zombie.)
          nil)))))

(defun iar--cycle-post-response-handler (start end)
  "Post-response handler for cycle. START and END are buffer positions
delimiting the new response (gptel convention). START == END means the
request FAILED -- count a strike, never resend blindly (the 2026-08-30
storm: 2537 retries of a 404ing model, 1GB of log, because errors were
invisible to this handler and the lenient sentinel match hit the
prompt's own vocabulary every turn).
Wrapped in condition-case to prevent errors from hanging the event loop."
  (condition-case err
      (let* ((state iar--cycle-state)
             (agent (plist-get state :agent))
             (max-turns (plist-get state :max-turns))
             (turn-count (plist-get state :turn-count)))
        (if (and (number-or-marker-p start) (number-or-marker-p end)
                 (= start end))
            ;; ---- FAILED REQUEST PATH ----
            (progn
              (cl-incf iar--cycle-error-strikes)
              (message "[%s] Cycle request FAILED (strike %d/3)"
                       agent iar--cycle-error-strikes)
              (when (>= iar--cycle-error-strikes 3)
                (message "[%s] Three failed requests in a row -- ending cycle" agent)
                (setf (plist-get iar--cycle-state :completed) t)
                (setf (plist-get iar--cycle-state :exit-code) 1)))
          ;; ---- SUCCESS PATH ----
          (setq iar--cycle-error-strikes 0)
          (cl-incf (plist-get iar--cycle-state :turn-count))
          ;; c39 fix (2026-09-07): the turn guard counted only
          ;; final-responses -- the increment lives in the
          ;; post-response handler, which gptel's FSM runs only on
          ;; DONE/ERRS/ABRT. The tool loop never reaches DONE, so
          ;; every tool-heavy cycle reported Turns: 1 and the guard
          ;; could never catch a tool-call burn (17:03 corpse: 126
          ;; requests, Turns: 1, zero record). The REQUEST counter
          ;; (incremented at the curl layer, iar-tool-call.el) is the
          ;; honest burn unit; :turn-count remains the
          ;; final-response count for the tombstone.
          ;; Log ONLY the new response region (not the whole buffer --
          ;; whole-buffer logging grows quadratically with turns)
          (ignore-errors
            (iar--cycle-log-append agent start end))
          ;; Completion signals: search ONLY the new response region
          ;; (iar--cycle-complete-p takes start/end and clamps them)
          (cond
             ((iar--cycle-complete-p (current-buffer) start end)
              ;; Sentinel on its own line in the NEW response only.
              ;; LOOP_COMPLETE = task done -> exit 2 (iar.sh stops the
              ;; loop: "TASK COMPLETE", human review gate).
              ;; CYCLE_COMPLETE = more work next cycle -> exit 0.
              ;; afcbc27 (2026-08-05) collapsed both to 0, silently
              ;; disabling the loop-stop contract; restored 2026-08-31.
              (setf (plist-get iar--cycle-state :completed) t)
              (setf (plist-get iar--cycle-state :exit-code)
                    (if (eq (iar--cycle-complete-p (current-buffer) start end)
                            'loop)
                        2 0)))
             ((iar--cycle-terminal-echo-p start end)
              ;; aria-0030 terminal-echo close, DONE-path belt
              ;; (2026-09-10). DEAD CODE in production as built
              ;; (c166): an echo-only response carries a tool call,
              ;; the FSM never reaches DONE, and this handler never
              ;; runs for it. The LIVE close is the pre-tool-call
              ;; hook iar--cycle-terminal-echo-close. This branch
              ;; stays as a belt for a future gptel change that runs
              ;; post-response hooks on tool-call responses; it is
              ;; exercised by tests but cannot fire on today's FSM.
              ;; Placed BEFORE max-turns: a close is a close, even a
              ;; turn that exhausted the budget trying to close.
              ;; LOOP echo -> exit 2 (task done), CYCLE echo -> exit 0.
              (let ((close-kind (iar--cycle-terminal-echo-p start end)))
                (message "[%s] Terminal sentinel echo (tool channel, %s) -- closing cycle"
                         agent (if (eq close-kind 'loop) "LOOP" "CYCLE"))
                (setf (plist-get iar--cycle-state :completed) t)
                (setf (plist-get iar--cycle-state :exit-code)
                      (if (eq close-kind 'loop) 2 0))))
             ((>= turn-count max-turns)
              ;; Max turns checked BEFORE any lenient match -- the old
              ;; lenient string-match against the whole buffer matched
              ;; the prompt's own CYCLE_COMPLETE vocabulary every turn,
              ;; making this branch dead code (storm root cause #2)
              (message "[%s] Max turns (%d) reached, ending cycle" agent max-turns)
              (setf (plist-get iar--cycle-state :completed) t)
              (setf (plist-get iar--cycle-state :exit-code) 1))
             (t
              ;; No completion signal, under turn limit -- continue.
              ;; Breaker check FIRST: a text-only runaway at over-limit
              ;; context must not re-send (the pre-tool-call breaker
              ;; never sees prose turns). Same contract: arm once and
              ;; ALLOW the re-send (grace round-trip for the summary),
              ;; then end the run on the next over-limit continue. The
              ;; text-check returns nil on arm (re-send proceeds) and
              ;; non-nil on second fire (blocked).
              (cond
               ((and (iar--cycle-empty-response-p)
                     (not (iar--cycle-complete-p (current-buffer) start end)))
                ;; aria-0026 (session XI, 2026-09-10): a 0/0 text-only
                ;; end (stop=stop, tokens_out=0) is TOMBSTONE-WORTHY,
                ;; never a clean end. Live-fire: continuo turn 557
                ;; (req 260909165458-70) ended exit 0 with zero durable
                ;; output -- no memory pass, no record, LAST-CYCLE.txt
                ;; said ok. The cycle evaporated. Placed BEFORE the
                ;; continue branch: a 0/0 end is already empty, so
                ;; re-prompting cannot fix it -- re-prompting is the
                ;; tombstone's job to record, not the cycle's to do.
                ;; The sentinel branch above already claimed any
                ;; response region that (impossibly, at 0 tokens)
                ;; carries a sentinel; the (not complete-p) clause
                ;; keeps the sentinel branch authoritative.
                (message "[%s] Empty 0/0 text-only end (stop=stop, tokens_out=0) -- tombstone, exit 1" agent)
                (iar--cycle-tombstone agent 0)
                (setf (plist-get iar--cycle-state :completed) t)
                (setf (plist-get iar--cycle-state :exit-code) 1))
               ((iar--cycle-truncated-output-p)
                ;; Truncated generation at the output cap (stop=length,
                ;; tokens_out > threshold): the model burned 65536 output
                ;; tokens mid-thought. The truncated-output guard used to
                ;; end the cycle HERE with exit 1 -- correct burn-stop,
                ;; but the cycle lost its landing: c42 (2026-09-07) died
                ;; mid-consolidation with the full record unwritten, and
                ;; the next cycle re-derived everything. Port of the
                ;; timeout grace pattern (iar-run-cycle ~line 943): ONE
                ;; grace round-trip -- insert the landing prompt, re-send,
                ;; and let the model write its record as text (append_file
                ;; still allowed). A second truncated fire (still looping
                ;; after the grace) ends the cycle exit 1. Shared budget
                ;; with the runaway recovery (:runaway-recovery-given) --
                ;; one snap-out OR one landing per cycle, whichever the
                ;; degradation shape calls for.
                ;; Thinking-only truncation (nemotron-era fire class,
                ;; 2026-09-10): the response is 1M+ chars of reasoning
                ;; with no model text. The grace round-trip cannot land
                ;; -- the model is looping in reasoning, not stuck before
                ;; it. End immediately; the grace contract (one landing
                ;; per cycle) applies only to truncations with real
                ;; text, which CAN land.
                (if (iar--cycle-thinking-only-response-p start end)
                    (progn
                      (message "[%s] Thinking-loop truncation (stop=length, %d tokens, thinking-only response) -- ending cycle, no grace"
                               agent iar--reqlog-last-tokens-out)
                      (setf (plist-get iar--cycle-state :completed) t)
                      (setf (plist-get iar--cycle-state :exit-code) 1))
                (if (plist-get iar--cycle-state :runaway-recovery-given)
                    (progn
                      (message "[%s] Truncated output (2nd fire, stop=length, %d tokens > %d) -- ending cycle"
                               agent iar--reqlog-last-tokens-out
                               iar-cycle-truncated-output-threshold)
                      (setf (plist-get iar--cycle-state :completed) t)
                      (setf (plist-get iar--cycle-state :exit-code) 1))
                  (progn
                    (setf (plist-get iar--cycle-state :runaway-recovery-given) t)
                    (message "[%s] Truncated output (stop=length, %d tokens > %d) -- requesting landing (grace round-trip)"
                             agent iar--reqlog-last-tokens-out
                             iar-cycle-truncated-output-threshold)
                    (goto-char (point-max))
                    (insert "\nYour previous response was truncated mid-thought (output token cap). Do NOT continue the thought. Land what you have NOW: write your journal entry, HISTORY.log line, and lab-notes post via append_file/tool calls, then end with CYCLE_COMPLETE on its own line. Keep it short.\n")
                    (gptel-send)))))
               ((iar--cycle-output-runaway-p start end)
                ;; Text-only output runaway: the model degraded into a
                ;; repetition loop (repeated text, no tool call). Give it
                ;; ONE recovery round-trip -- a specific snap-out prompt
                ;; (the model is usually stuck in decision paralysis, not
                ;; truly degraded). If it repeats again (second fire),
                ;; end the run -- re-sending would burn another 65536-token
                ;; output budget on the same loop. exit 1 (failed): the
                ;; cycle did not complete its work.
                (if (plist-get iar--cycle-state :runaway-recovery-given)
                    (progn
                      (message "[%s] Text-only output runaway (2nd fire) -- ending cycle" agent)
                      (setf (plist-get iar--cycle-state :completed) t)
                      (setf (plist-get iar--cycle-state :exit-code) 1))
                  (progn
                    (setf (plist-get iar--cycle-state :runaway-recovery-given) t)
                    (message "[%s] Text-only output runaway detected -- requesting recovery" agent)
                    (goto-char (point-max))
                    (insert "\nYou are repeating yourself -- a text-only loop. Break it NOW with a tool call. Call append_file to write ONE line to your journal (JOURNAL.org): what you are stuck on. Then write CYCLE_COMPLETE on its own line. Do not analyze, do not plan, do not repeat. Make the append_file call immediately.\n")
                    (gptel-send))))
               ((iar--cycle-cross-response-repetition-p start end)
                ;; Cross-response repetition: the SAME line repeated
                ;; across the last N responses (each under the
                ;; per-response threshold). The deepseek-v4-flash
                ;; text-only loop repeats a paragraph ACROSS responses
                ;; (5-10 reps each), so the per-response guard never
                ;; fires until the final 65536-capped response (c111).
                ;; Same recovery contract as the per-response runaway:
                ;; ONE recovery round-trip, then end on second fire.
                ;; Shares :runaway-recovery-given so a cross-response
                ;; fire and a per-response fire share the budget.
                (if (plist-get iar--cycle-state :runaway-recovery-given)
                    (progn
                      (message "[%s] Cross-response repetition (2nd fire) -- ending cycle" agent)
                      (setf (plist-get iar--cycle-state :completed) t)
                      (setf (plist-get iar--cycle-state :exit-code) 1))
                  (progn
                    (setf (plist-get iar--cycle-state :runaway-recovery-given) t)
                    (message "[%s] Cross-response repetition detected -- requesting recovery" agent)
                    (goto-char (point-max))
                    (insert "\nYou are repeating yourself -- a text-only loop. Break it NOW with a tool call. Call append_file to write ONE line to your journal (JOURNAL.org): what you are stuck on. Then write CYCLE_COMPLETE on its own line. Do not analyze, do not plan, do not repeat. Make the append_file call immediately.\n")
                    (gptel-send))))
               ((iar--cycle-breaker-text-check iar--cycle-state)
                (message "[%s] Context breaker blocked the continue re-send" agent))
               (t
                (let ((cont-prompt (plist-get state :continue)))
                  (if cont-prompt
                      (progn
                        (goto-char (point-max))
                        (insert cont-prompt)
                        (gptel-send))
                    ;; No continue prompt -- end cycle
                    (message "[%s] No continue prompt, ending cycle" agent)
                    (setf (plist-get iar--cycle-state :completed) t)))))))))
    (error
     (message "[%s] Cycle post-response error: %s"
              (or (plist-get iar--cycle-state :agent) "unknown")
              (error-message-string err))
     (setf (plist-get iar--cycle-state :completed) t)
     (setf (plist-get iar--cycle-state :exit-code) 1))))

;;; ---------------------------------------------------------
;;; Main entry point
;;; ---------------------------------------------------------

(defun iar--normalize-self-mod (value)
  "Normalize a :self-modification argument VALUE to a boolean.
The shell always passes 0 or 1 (never omits the keyword), and Elisp
truthiness treats 0 as non-nil -- so a bare `(if (null sm) nil sm)'
ENABLED self-modification when the shell said 0.  Privilege
inversion: the safe default was unreachable via iar.sh.  Only nil,
0, and \"0\" mean disabled."
  (not (member value '(nil 0 "0"))))

(defun iar-run-cycle (&rest args)
  "Run one agent cycle in batch mode.
Keywords args:
  :agent NAME       -- personality name (default: \"darwin\")
  :timeout SECONDS  -- override iar-cycle-timeout
  :prompt STRING    -- override the cycle prompt (inline string)
  :cycle NAME       -- cycle name (loads agents.d/cycles/<NAME>.org).
                       Defaults to the personality's mapped cycle
                       (e.g., darwin -> self_modification).
  :self-modification BOOL -- enable self-modification (default: nil)
  :knowledge LABELS -- extra knowledge labels (list of strings),
                       appended to the project's #+KNOWLEDGE.
                       (iar.sh --knowledge passes this; before 2026-08-31
                       the keyword was accepted and silently ignored.)

The archetype is determined by the personality-to-archetype map.
The project is determined by the personality name (matching project file
or \"default\" if no matching project exists).
Knowledge is auto-loaded from the project's #+KNOWLEDGE metadata.
Tools are gated by the project's #+TOOLS metadata."
  (interactive)
  (let* ((agent-name (or (plist-get args :agent) "darwin"))
         (raw-timeout (or (plist-get args :timeout) iar-cycle-timeout))
         (timeout (if (and (integerp raw-timeout) (> raw-timeout 0))
                      raw-timeout
                    7200))
         (cycle-name (or (plist-get args :cycle)
                         (iar--cycle-for-personality agent-name)))
         (prompt (or (plist-get args :prompt)
                     (iar--cycle-load-cycle-prompt cycle-name)))
         (continue-prompt (iar--cycle-load-continue-prompt))
         ;; Fail loud BEFORE any state or request: a cycle without a
         ;; continue prompt cannot land honestly (the handler's
         ;; no-continue branch completes with default exit 0, making
         ;; the timeout path's exit-1 branch unreachable). Belt after
         ;; the loader's own signal -- covers a nil return from any
         ;; future refactor of the loader.
         (_ (unless continue-prompt
              (error "Continue prompt missing for %s -- cycle cannot land honestly" agent-name)))
         (archetype (iar--archetype-for-personality agent-name))
         (project (iar--project-for-personality agent-name))
         (extra-knowledge (plist-get args :knowledge))
         (self-mod (iar--normalize-self-mod
                    (plist-get args :self-modification)))
         (cycle-buf (get-buffer-create (format "*%s-cycle*" agent-name)))
         (max-turns (if (and (integerp iar-cycle-max-turns)
                             (> iar-cycle-max-turns 0))
                        iar-cycle-max-turns
                      40)))
    (message "[%s] Starting cycle with %ds timeout (archetype: %s, project: %s, cycle: %s)"
             agent-name timeout archetype project cycle-name)
    (iar--usage-reset)
    (setq iar--cycle-state (iar--cycle-make-state agent-name cycle-buf continue-prompt max-turns timeout)
          iar--cycle-error-strikes 0)
    ;; Reset the shared last-request state so a stale value from a
    ;; previous cycle (or a delegate's request) is never read as this
    ;; cycle's first response by the truncated-output guard.
    (iar--reqlog-reset-last)
    (with-current-buffer cycle-buf
      (text-mode)
      (gptel-mode 1)
      ;; Assemble prompt from archetype + personality + project
      (let ((result (iar--setup-assembled-buffer archetype agent-name project extra-knowledge)))
        (message "[%s] Assembled prompt: %d chars (~%d tokens), %d tools"
                 agent-name
                 (length (plist-get result :prompt))
                 (/ (length (plist-get result :prompt)) 4)
                 (length (plist-get result :tools))))
      (setq-local gptel-stream t)
      ;; Self-modification: buffer-local so delegates inherit global nil
      (setq-local iar-guard-allow-self-modification self-mod)

      ;; Install hooks (named functions, idempotent per rule 57).
      ;; Tracker + cap are registered GLOBALLY at module load (bottom of
      ;; this file): state-guarded no-ops outside cycles, and global
      ;; registration is what makes them fire from async sentinels where
      ;; current-buffer is NOT cycle-buf (the 2026-09-02 invisible-cycles
      ;; finding: buffer-local registration counted 360 calls as 13).
      ;; Unknown-tools + post-response handler stay buffer-local: they
      ;; are only meaningful for this cycle's buffer.
      (remove-hook 'iar-pre-tool-call-functions #'iar--block-unknown-tools t)
      (add-hook 'iar-pre-tool-call-functions #'iar--block-unknown-tools nil t)
      (remove-hook 'iar-post-response-functions #'iar--cycle-post-response-handler t)
      (add-hook 'iar-post-response-functions #'iar--cycle-post-response-handler nil t)

      ;; Insert prompt and send
      (insert prompt)
      (message "[%s] Sending cycle prompt to %s agent..." agent-name agent-name)
      (gptel-send))

    ;; Batch mode event loop: wait until completed or timeout.
    ;; The deadline is computed from the state's :start-time -- the
    ;; SAME clock the budget trailer reads (one t0, two readers).
    (when noninteractive
      (let ((idle-since nil)
            (deadline (time-add (plist-get iar--cycle-state :start-time)
                                (seconds-to-time timeout))))
        (while (and (not (plist-get iar--cycle-state :completed))
                   (time-less-p nil deadline))
          (accept-process-output nil 1)
          (if (or (get-buffer-process cycle-buf)
                  ;; gptel curl processes live in their own proc
                  ;; buffers, not the gptel buffer -- check the
                  ;; request alist for active requests instead.
                  (and (boundp 'gptel--request-alist)
                       gptel--request-alist))
              ;; Active request -- reset idle timer
              (setq idle-since nil)
            ;; No active request -- check for idle timeout (real time,
            ;; not loop iterations: accept-process-output returns early
            ;; on any event, so iteration counts are not seconds)
            (unless (plist-get iar--cycle-state :completed)
              (unless idle-since (setq idle-since (current-time)))
              (when (> (time-convert (time-subtract nil idle-since) 'integer) 1800)
                (message "[%s] No active requests for 1800s -- stalled, exit 1" agent-name)
                (iar--cycle-tombstone agent-name 1800)
                (setf (plist-get iar--cycle-state :completed) t)
                (setf (plist-get iar--cycle-state :exit-code) 1)))))
        ;; Timeout path: graceful landing, not a cliff.
        ;; The model gets one final round-trip to write its summary
        ;; and memory (the one-shot pattern, ported 2026-09-03).
        ;; Before this, a timed-out cycle exited 0 via iar.sh's
        ;; success path with NOTHING written -- "timeout-as-success",
        ;; the record lied (2026-09-02 00:12: "timed out" then
        ;; "succeeded exit 0" ten seconds later).
        (unless (plist-get iar--cycle-state :completed)
          (message "[%s] Cycle timed out after %ds -- requesting summary (grace 120s)"
                   agent-name timeout)
          (condition-case err
              (with-current-buffer cycle-buf
                (goto-char (point-max))
                (insert (format "\n%s\n"
                                (or (plist-get iar--cycle-state :continue)
                                    "Continue.")))
                (insert "TIME LIMIT REACHED. Stop all tool calls immediately. Write your summary NOW: what you did, what landed, what is next. Update your memory files (append_file still allowed). End with CYCLE_COMPLETE on its own line.\n")
                (gptel-send))
            (error
             (message "[%s] Summary request failed: %s" agent-name
                      (error-message-string err))))
          ;; Grace window: wait up to 120s for the summary round-trip.
          ;; The post-response handler sees CYCLE_COMPLETE -> completed,
          ;; exit 0. Anything else -> exit 1 (honest failure).
          (let ((grace-deadline (time-add nil (seconds-to-time 120))))
            (while (and (not (plist-get iar--cycle-state :completed))
                        (time-less-p nil grace-deadline))
              (accept-process-output nil 1)))
          ;; Still not done after grace: mark failed honestly.
          (unless (plist-get iar--cycle-state :completed)
            (setf (plist-get iar--cycle-state :completed) t)
            (setf (plist-get iar--cycle-state :exit-code) 1)
            (message "[%s] Grace window expired without CYCLE_COMPLETE -- exit 1"
                     agent-name)))
        ;; Cycle ended -- log results and exit
        (let ((exit-code (plist-get iar--cycle-state :exit-code))
              (turn-count (plist-get iar--cycle-state :turn-count))
              (tool-call-count (plist-get iar--cycle-state :tool-call-count)))
          (if (plist-get iar--cycle-state :completed)
              (message "[%s] Cycle complete. Turns: %d, Tool calls: %d, Exit: %d%s"
                       agent-name turn-count tool-call-count exit-code
                       (iar--cycle-token-summary))
            ;; Unreachable in practice (all paths set completed), kept
            ;; as belt-and-suspenders: tombstone before state clears.
            (iar--cycle-tombstone agent-name timeout)
            (message "[%s] Cycle timed out after %ds. Turns: %d, Tool calls: %d%s"
                     agent-name timeout turn-count tool-call-count
                     (iar--cycle-token-summary)))
          ;; USAGE orphan-write race (c45/c46): write the usage line
          ;; BEFORE kill-emacs so the cycle's own final commit (or the
          ;; next waking's pull) captures it in the tracked file. The
          ;; kill-emacs-hook write remains as the abnormal-exit net.
          ;; Bound to cycle-buf: the write resolves the agent from the
          ;; current buffer, and after a delegate ran, the current
          ;; buffer at exit can be the delegate's (c57: aria c3's
          ;; USAGE line landed in the reviewer's log).
          (with-current-buffer cycle-buf
            (iar--usage-write-log-now))
          (setq iar--cycle-state nil)
          (kill-emacs exit-code))))))

;;; --- Global fence registration ---
;; The tracker and cap hooks are STATE-GUARDED (no-ops when
;; iar--cycle-state is nil), so they are safe to register globally at
;; load time. Registering here (not per-cycle in iar-run-cycle) means
;; the hooks fire from async sentinels regardless of current-buffer --
;; the 2026-09-02 invisible-cycles finding showed buffer-local
;; registration made the counter context-blind (360 calls counted as 13).
(remove-hook 'iar-post-tool-call-functions #'iar--cycle-tool-call-tracker)
(add-hook 'iar-post-tool-call-functions #'iar--cycle-tool-call-tracker)
;; One-shot tracker: GLOBAL for the same reason -- the buffer-local
;; registration in iar-run-one-shot never fired from async sentinels
;; (the 360-as-13 class, one-shot edition) and would double-count on
;; top of this one.
(remove-hook 'iar-post-tool-call-functions #'iar--one-shot-tool-call-tracker)
(add-hook 'iar-post-tool-call-functions #'iar--one-shot-tool-call-tracker)
(remove-hook 'iar-pre-tool-call-functions #'iar--cycle-tool-call-cap)
(add-hook 'iar-pre-tool-call-functions #'iar--cycle-tool-call-cap)
(remove-hook 'iar-pre-tool-call-functions #'iar--cycle-context-breaker)
(add-hook 'iar-pre-tool-call-functions #'iar--cycle-context-breaker)
;; Terminal-echo close, TOOL path (aria-0030 correction): the c166
;; post-response branch never runs for tool-call responses (the FSM
;; reaches DONE only on text-only responses). This hook fires in the
;; pre-tool-call channel, which DOES run for every pending call.
(remove-hook 'iar-pre-tool-call-functions #'iar--cycle-terminal-echo-close)
(add-hook 'iar-pre-tool-call-functions #'iar--cycle-terminal-echo-close)
;; Interactive fences (aria-0006): global post-response hook, no-op
;; unless iar-interactive-fences is on AND no cycle/one-shot state
;; owns the run. Default off -- ratification pending.
(remove-hook 'iar-post-response-functions #'iar--interactive-fence-handler)
(add-hook 'iar-post-response-functions #'iar--interactive-fence-handler)


;;; ---------------------------------------------------------
;;; Interactive fences (aria-0006, cycle c107 proposal)
;;; ---------------------------------------------------------
;; The cycle and one-shot paths arm their fences via state plists
;; created in iar-run-cycle / iar-run-one-shot. Interactive gptel
;; sessions have NO state, so every fence that dispatches on
;; (or iar--cycle-state iar--one-shot-state) is a silent no-op there
;; -- the aria-0006 finding: the first INTERACTIVE text-loop
;; degeneration (2026-09-08, glm-5.3-flash:cloud, witnessed by
;; Nacho) had no instrument watching. The human was the only
;; detector. Again.
;;
;; This section adds an OPTIONAL lightweight interactive state so
;; the two text-degeneration fences (per-response output runaway +
;; cross-response repetition) can arm in interactive sessions.
;; DEFAULT OFF (iar-interactive-fences nil): enabling changes what
;; plumbing may interrupt a human's session -- nacho-test class,
;; ratification required before anyone flips it on.
;;
;; Contract differences from the cycle path:
;; - No exit code, no tombstone: the human IS the loop. On second
;;   fire the fence disarms itself for that buffer and says so --
;;   re-arming requires a fresh M-x iar-interactive-fences-reset
;;   (or reopening the buffer). A fence that silently re-arms is a
;;   fence that can be ignored.
;; - The tool-call cap and context breaker stay cycle/one-shot
;;   only: interactive sessions are human-paced, and the cap's
;;   landing contract (CYCLE_COMPLETE) has no interactive meaning.
;; - A cycle or one-shot state in the same Emacs takes precedence:
;;   their handlers own their buffers, this hook must not
;;   double-fire into them.

(defvar iar-interactive-fences nil
  "When non-nil, arm the text-degeneration fences (output runaway +
cross-response repetition) in INTERACTIVE gptel buffers.
Default nil: ratification pending (aria-0006, nacho-test class --
changes what plumbing may interrupt). Cycle and one-shot runs are
unaffected either way; their own handlers own their buffers.")

(defvar-local iar--interactive-state nil
  "Per-buffer fence state for interactive gptel sessions.
Same shape as the cycle state's fence-relevant keys:
:cross-rep-window, :runaway-recovery-given, :disarmed.
Created lazily by `iar--interactive-fence-handler' when
`iar-interactive-fences' is on.")

(defun iar--interactive-fences-reset ()
  "Re-arm the interactive fences in the current buffer.
Clears the per-buffer state (a disarmed fence re-arms)."
  (interactive)
  (setq iar--interactive-state nil)
  (message "iar: interactive fences re-armed for this buffer"))

(defun iar--interactive-fence-handler (start end)
  "Post-response fence for INTERACTIVE gptel sessions.
Global hook (registered at load): fires for every completed
response in every buffer. No-ops unless `iar-interactive-fences'
is on and no cycle/one-shot state owns the run. Checks the same
two text-degeneration fences the cycle path uses; ONE recovery
round-trip (snap-out prompt), then the fence disarms itself for
the buffer -- the human is the loop, so the second fire says so
instead of ending a run."
  (when (and iar-interactive-fences
             (null iar--cycle-state)
             (null iar--one-shot-state)
             (integerp start) (integerp end) (< start end))
    ;; Lazy per-buffer state: created on first response, kept in the
    ;; buffer so the cross-response window survives across turns.
    (unless iar--interactive-state
      (setq iar--interactive-state
            (list :cross-rep-window nil
                  :runaway-recovery-given nil
                  :disarmed nil)))
    (unless (plist-get iar--interactive-state :disarmed)
      (let ((runaway (iar--cycle-output-runaway-p start end))
            (saved-one-shot iar--one-shot-state)
            cross)
        ;; The cross-response check reads the active state via
        ;; (or iar--cycle-state iar--one-shot-state) -- both nil in
        ;; interactive use, so bind the buffer-local state into the
        ;; alias slot it reads, then read the window back.
        (setq iar--one-shot-state iar--interactive-state)
        (setq cross (iar--cycle-cross-response-repetition-p start end))
        (setq iar--interactive-state iar--one-shot-state)
        (setq iar--one-shot-state saved-one-shot)
        (when (or runaway cross)
          (if (plist-get iar--interactive-state :runaway-recovery-given)
              ;; Second fire: disarm, tell the human. No exit code --
              ;; the human is the loop; a fence that silently re-arms
              ;; is a fence that can be ignored.
              (progn
                (setq iar--interactive-state
                      (plist-put iar--interactive-state :disarmed t))
                (message "iar: text-loop fence fired AGAIN -- DISARMED in this buffer (M-x iar--interactive-fences-reset re-arms)")
                (goto-char (point-max))
                (insert "\n[iar fence] Text-loop fence fired twice -- disarmed in this buffer. Delete the looped text or M-x iar--interactive-fences-reset to re-arm.\n"))
            ;; First fire: one recovery round-trip (same shape as the
            ;; cycle path's snap-out).
            (setq iar--interactive-state
                  (plist-put iar--interactive-state
                             :runaway-recovery-given t))
            (message "iar: text-loop fence fired (interactive) -- requesting recovery")
            (goto-char (point-max))
            (insert "\nYou are repeating yourself -- a text-only loop. Break it NOW with a tool call or a short, fresh response. Do not analyze, do not repeat. If you were mid-task, state the next single step in one line.\n")
            (gptel-send)))))))

(provide 'iar-agent-cycle)
;;; ---------------------------------------------------------
;;; One-shot mode
;;; ---------------------------------------------------------

;; Forward-declared: owned by configs/delimiters.el.
(defvar iar-one-shot-response-open nil
  "Opening delimiter for one-shot final response.")
(defvar iar-one-shot-response-close nil
  "Closing delimiter for one-shot final response.")

(defconst iar--one-shot-nudge-prompt
  (format "Continue working on your task. When you are finished, wrap your final response in %s and %s markers."
          iar-one-shot-response-open iar-one-shot-response-close)
  "Nudge prompt sent when a one-shot agent produces a response without delimiters.
Built from the delimiter defcustoms (single source: configs/delimiters.el);
a hardcoded copy here drifted from them the moment either changed.")

(defvar iar--one-shot-state nil
  "Current one-shot state as a plist:
:agent           -- agent name string
:buffer          -- one-shot buffer
:max-turns       -- max LLM turns
:turn-count      -- current turn count
:tool-call-count -- total tool calls made
:cap-blocks      -- tool calls blocked at the soft cap (hard-cap counter)
:completed       -- t when one-shot is done
:exit-code       -- 0 for success, 1 for timeout/error
:final-response  -- extracted response string or nil")

(defun iar--one-shot-make-state (agent buf max-turns &optional wall-timeout)
  "Create a fresh one-shot state plist.
WALL-TIMEOUT and :start-time: the shared clock source (see
`iar--cycle-make-state' -- one t0 for the fence and the trailer)."
  ;; :request-count 0: the c39 burn mirror (iar--usage-parse-from-curl)
  ;; does (cl-incf (plist-get iar--one-shot-state :request-count)) on
  ;; every request. Without the key, plist-get returns nil and cl-incf
  ;; signals wrong-type-argument number-or-marker-p nil -- demoted to
  ;; "Warning: token parse from curl failed" by the advice's
  ;; condition-case. One warning PER REQUEST (nocturne first runs:
  ;; 164 in one log), and the mirror never incremented. Cycle state
  ;; always had the key (iar--cycle-make-state) -- which is why the
  ;; storm was one-shot-only and misread as a deepseek chunk-shape
  ;; problem in the gptel fork (c218 forensics, corrected c219).
  (list :agent agent :buffer buf :max-turns max-turns
        :start-time (current-time) :wall-timeout wall-timeout
        :turn-count 0 :tool-call-count 0 :request-count 0 :cap-blocks 0
        :cap-warned nil
        :completed nil :exit-code 0 :final-response nil))

(defun iar--one-shot-tool-call-tracker (_tool-name _tool-result)
  "Track tool calls in one-shot mode. Increments tool-call-count.
GLOBAL hook (registered at module load, same reasoning as the
cycle tracker): the post-tool-call advice fires from async
sentinels where current-buffer is NOT the one-shot buffer -- the
buffer-local registration this replaces undercounted one-shot tool
calls exactly the way cycles were undercounted (2026-09-02
invisible-cycles finding). State-guarded: no active one-shot ->
silent no-op (safe to fire during cycle runs and interactive use)."
  (when iar--one-shot-state
    (cl-incf (plist-get iar--one-shot-state :tool-call-count))))

(defun iar--one-shot-extract-response (text)
  "Extract content between one-shot delimiters in TEXT.
Returns the extracted string if delimiters are found, nil otherwise.
Finds the first opening delimiter and the last closing delimiter
to handle content that mentions the delimiter text."
  (let ((open-del (or iar-one-shot-response-open "=== BEGIN FINAL RESPONSE ==="))
        (close-del (or iar-one-shot-response-close "=== END FINAL RESPONSE ===")))
    (with-temp-buffer
      (insert text)
      (goto-char (point-min))
      (when (search-forward open-del nil t)
        (let ((start (point)))
          ;; Search for the last occurrence of close-del after start
          (goto-char (point-max))
          (when (search-backward close-del start t)
            (let ((end (point)))
              (string-trim (buffer-substring-no-properties start end)))))))))


(defvar iar--one-shot-error-strikes 0
  "Consecutive failed-request strikes in the current one-shot run.
See `iar--cycle-error-strikes' for the failed-request convention.")

(defun iar--one-shot-post-response-handler (start end)
  "Post-response handler for one-shot mode. START and END are buffer
positions delimiting the new response (gptel convention). START == END
means the request FAILED -- count a strike, three strikes -> abort.
Scans the NEW RESPONSE for one-shot delimiters. If found, extracts
the final response and marks the one-shot as completed. If not found
and under max turns, sends a nudge prompt. If max turns reached,
marks as completed with exit code 1."
  (let* ((state iar--one-shot-state)
         (agent (plist-get state :agent))
         (turn-count (plist-get state :turn-count))
         (max-turns (plist-get state :max-turns)))
    (if (and (number-or-marker-p start) (number-or-marker-p end)
             (= start end))
        ;; ---- FAILED REQUEST PATH ----
        (progn
          (cl-incf iar--one-shot-error-strikes)
          (message "[%s] One-shot request FAILED (strike %d/3)"
                   agent iar--one-shot-error-strikes)
          (when (>= iar--one-shot-error-strikes 3)
            (message "[%s] Three failed requests in a row -- ending one-shot" agent)
            (setf (plist-get iar--one-shot-state :completed) t)
            (setf (plist-get iar--one-shot-state :exit-code) 1)))
      ;; ---- SUCCESS PATH ----
      (setq iar--one-shot-error-strikes 0)
      (cl-incf (plist-get iar--one-shot-state :turn-count))
      ;; Log only the new response region
      (iar--cycle-log-append agent start end)
      ;; Check for delimiters in the NEW RESPONSE only
      (let* ((response (buffer-substring-no-properties
                         (max (point-min) (min start (point-max)))
                         (max (point-min) (min end (point-max)))))
             (extracted (iar--one-shot-extract-response response)))
        (cond
         (extracted
          (setf (plist-get iar--one-shot-state :final-response) extracted)
          (setf (plist-get iar--one-shot-state :completed) t)
          (setf (plist-get iar--one-shot-state :exit-code) 0)
          (message "[%s] One-shot: final response detected (%d chars)"
                   agent (length extracted)))
         ((>= turn-count max-turns)
          (message "[%s] One-shot: max turns (%d) reached without final response"
                   agent max-turns)
          (setf (plist-get iar--one-shot-state :completed) t)
          (setf (plist-get iar--one-shot-state :exit-code) 1))
         (t
          ;; No delimiters, under turn limit -- send nudge
          (goto-char (point-max))
          (insert iar--one-shot-nudge-prompt)
          (gptel-send)))))))

(defun iar-run-one-shot (&rest args)
  "Run a one-shot agent in batch mode.
Sends a single instruction to an agent, waits for it to produce a
final response (between delimiters), extracts it, and prints to stdout.

Keywords args:
  :agent NAME       -- personality name (default: \"mirror\")
  :timeout SECONDS  -- timeout in seconds (default: 7200)
  :self-modification BOOL -- enable self-modification (default: nil)

The prompt text is read from the IAR_ONE_SHOT_PROMPT environment variable.
The archetype is forced to \"one-shot\" (not from the personality map).
The project is determined by the personality name.
Knowledge is auto-loaded from the project's #+KNOWLEDGE metadata.
Tools are gated by the project's #+TOOLS metadata."
  (interactive)
  (let* ((agent-name (or (plist-get args :agent) "mirror"))
         (raw-timeout (or (plist-get args :timeout) 7200))
         (timeout (if (and (integerp raw-timeout) (> raw-timeout 0))
                      raw-timeout
                    7200))
         (prompt (getenv "IAR_ONE_SHOT_PROMPT"))
         (archetype "one-shot")
         (project (iar--project-for-personality agent-name))
         (self-mod (iar--normalize-self-mod
                    (plist-get args :self-modification)))
         (os-buf (get-buffer-create (format "*%s-oneshot*" agent-name)))
         (max-turns (if (and (integerp iar-cycle-max-turns)
                             (> iar-cycle-max-turns 0))
                        iar-cycle-max-turns
                      40)))
    (unless (and prompt (not (string-empty-p (string-trim prompt))))
      (message "[%s] One-shot: no prompt provided (IAR_ONE_SHOT_PROMPT env var is empty)"
               agent-name)
      (kill-emacs 1))
    (message "[%s] Starting one-shot with %ds timeout (archetype: %s, project: %s)"
             agent-name timeout archetype project)
    (iar--usage-reset)
    (setq iar--one-shot-state (iar--one-shot-make-state agent-name os-buf max-turns timeout))
    (with-current-buffer os-buf
      (text-mode)
      (gptel-mode 1)
      ;; Assemble prompt from one-shot archetype + personality + project
      (let ((result (iar--setup-assembled-buffer archetype agent-name project)))
        (message "[%s] Assembled prompt: %d chars (~%d tokens), %d tools"
                 agent-name
                 (length (plist-get result :prompt))
                 (/ (length (plist-get result :prompt)) 4)
                 (length (plist-get result :tools))))
      (setq-local gptel-stream t)
      ;; Self-modification: buffer-local so delegates inherit global nil
      (setq-local iar-guard-allow-self-modification self-mod)

      ;; Install hooks (named functions, idempotent per rule 57).
      ;; The one-shot tool-call tracker is NOT registered here: it is
      ;; registered GLOBALLY at module load (state-guarded). A
      ;; buffer-local registration on top of the global one would
      ;; double-count, and buffer-local alone never fires from async
      ;; sentinels (the 360-as-13 class).
      (remove-hook 'iar-pre-tool-call-functions #'iar--block-unknown-tools t)
      (add-hook 'iar-pre-tool-call-functions #'iar--block-unknown-tools nil t)
      (remove-hook 'iar-post-response-functions #'iar--one-shot-post-response-handler t)
      (add-hook 'iar-post-response-functions #'iar--one-shot-post-response-handler nil t)

      ;; Insert prompt and send
      (insert prompt)
      (message "[%s] Sending one-shot prompt to %s..." agent-name agent-name)
      (gptel-send))

    ;; Batch mode event loop: deadline from the state's :start-time
    ;; (the shared clock -- same source the budget trailer reads).
    (when noninteractive
      (let ((idle-since nil)
            (deadline (time-add (plist-get iar--one-shot-state :start-time)
                                (seconds-to-time timeout))))
        (while (and (not (plist-get iar--one-shot-state :completed))
                   (time-less-p nil deadline))
          (accept-process-output nil 1)
          (if (or (plist-get iar--one-shot-state :completed)
                  (get-buffer-process os-buf)
                  (and (boundp 'gptel--request-alist)
                       gptel--request-alist))
              ;; Active request -- reset idle timer
              (setq idle-since nil)
            ;; No active process -- check for idle timeout (real time,
            ;; not loop iterations: accept-process-output returns early
            ;; on any event, so iteration counts are not seconds)
            (progn
              (unless idle-since (setq idle-since (current-time)))
              (when (> (time-convert (time-subtract nil idle-since) 'integer) 1800)
                (message "[%s] One-shot: no active requests for 1800s -- stalled, exit 1"
                         agent-name)
                (iar--cycle-tombstone agent-name 1800)
                (setf (plist-get iar--one-shot-state :completed) t)
                (setf (plist-get iar--one-shot-state :exit-code) 1)))))
        ;; Timeout check: if deadline passed and not completed, ask for summary
        (when (and (not (plist-get iar--one-shot-state :completed))
                   (not (time-less-p nil deadline)))
          (message "[%s] One-shot: timeout reached, requesting summary..." agent-name)
          (let ((summary-prompt
                 (format "Time limit reached. Stop all tool calls immediately. Summarize all findings so far and wrap your summary in %s and %s markers. Include all vulnerabilities discovered, even partial ones."
                         iar-one-shot-response-open iar-one-shot-response-close)))
            (condition-case err
                (with-current-buffer os-buf
                  (goto-char (point-max))
                  (insert summary-prompt)
                  (gptel-send))
              (error
               (message "[%s] One-shot summary request failed: %s" agent-name
                        (error-message-string err)))))
          ;; Wait up to 120s for the summary response
          (let ((summary-deadline (time-add nil (seconds-to-time 120))))
            (while (and (not (plist-get iar--one-shot-state :completed))
                        (time-less-p nil summary-deadline))
              (accept-process-output nil 1))))
        ;; Still not done after the summary grace: tombstone + honest
        ;; exit. Before this fix the one-shot timeout path fell through
        ;; with exit-code 0 -- timeout-as-success, the same lie the
        ;; cycle path killed on 2026-09-02 ("timed out" then "succeeded
        ;; exit 0" ten seconds later, nothing written).
        (unless (plist-get iar--one-shot-state :completed)
          (message "[%s] One-shot summary grace expired without final response -- exit 1"
                   agent-name)
          (iar--cycle-tombstone agent-name timeout)
          (setf (plist-get iar--one-shot-state :exit-code) 1))
        ;; One-shot ended -- print result and exit
        (let ((exit-code (plist-get iar--one-shot-state :exit-code))
              (turn-count (plist-get iar--one-shot-state :turn-count))
              (tool-call-count (plist-get iar--one-shot-state :tool-call-count))
              (final-response (plist-get iar--one-shot-state :final-response)))
          (if (plist-get iar--one-shot-state :completed)
              (message "[%s] One-shot complete. Turns: %d, Tool calls: %d, Exit: %d%s"
                       agent-name turn-count tool-call-count exit-code
                       (iar--cycle-token-summary))
            (message "[%s] One-shot timed out after %ds. Turns: %d, Tool calls: %d%s"
                     agent-name timeout turn-count tool-call-count
                     (iar--cycle-token-summary)))
          ;; Print final response to stdout (clean output)
          ;; On timeout with no final-response, extract whatever is in the buffer
          (if final-response
              (princ (format "=== BEGIN FINAL RESPONSE ===\n%s\n=== END FINAL RESPONSE ===" final-response))
            (let ((buf-content (with-current-buffer os-buf
                                 (buffer-substring-no-properties (point-min) (point-max)))))
              (when (and buf-content (> (length buf-content) 0))
                (princ buf-content))))
          ;; USAGE orphan-write race (c45/c46): pre-exit write, same
          ;; rationale as the cycle exit path. Bound to os-buf for the
          ;; same c57 reason (agent resolution from current buffer).
          (with-current-buffer os-buf
            (iar--usage-write-log-now))
          (setq iar--one-shot-state nil)
          (kill-emacs exit-code))))))
