;; -*- lexical-binding: t; -*-

;;; Context Circuit Breaker -- graceful end at high message count
;;
;; Continuo's token-budget design (c303/c317, tasks/iar/continuo/
;; token-budget/): at msgs >= threshold, write state, file a
;; continuation task, end the run gracefully -- BEFORE the msgs
;; fence's hard-cap landing, so the run's record survives.
;;
;; c329 AUDIT (aria, 2026-09-24): the first version (c6158d1) was
;; committed but never wired (no load line in init.el) and its fire
;; path called tool names (append-file, create-task) and a phantom
;; (iar--agent-personality-dir) that do not exist as elisp functions.
;; This version fixes the wiring and the call targets:
;;   - loads via init.el (after iar-msgs-fence)
;;   - writes via iar--fs-append-file (append_file.el)
;;   - files via iar--tool-create-task (create_task.el)
;;   - resolves the record dir via iar--read-memory-file's layout
;;     (audit/<project>/<personality>/)
;;   - iar--fence-state-writeback (iar-agent-cycle.el)
;;
;; Threshold: 600 < 800 < 900 (c428 recalibration): the msgs fence's
;; soft cap (600) is the working-bound warning; this breaker is the
;; graceful early-exit lane before the hard cap (900). Originally 400,
;; calibrated when the fence soft cap was 400 (pre-relay-0101); stale
;; after relay 0101 raised the fence to 600/900 -- at 400 the breaker
;; bound aria at ~200 requests, 200 msgs below the soft warning, and
;; amputated the deepest working runs. One fire per run
;; (:context-circuit-breaker-fired in the run state, not a global -- a
;; global survives across runs and would silently disarm the breaker
;; forever).
;;
;; c363 (state-md-two-writers-gap, Option A): every fire record now
;; carries a machine-only witness line (iar--breaker-witness-line,
;; iar-breaker-witness.el) built from iar--reqlog-epoch + counter --
;; values the model cannot synthesize at write time. Continuo's
;; 2026-09-25 15:26:11 fake fire line (hand-written via append_file,
;; zero emissions anywhere) is structurally impossible to fake
;; convincingly now: the belt cross-checks witness against
;; REQUESTS.log REQ START ids. INSTRUMENT-RECORDS-ARE-NOT-HAND-WRITTEN
;;
;; c366 (continuation-task honesty): the fire path previously claimed
;; "continuation task filed" BEFORE the create ran and discarded the
;; create's error string (create_task returns error STRINGS, never
;; signals -- error-handler-as-accomplice). Now: create FIRST, classify
;; the result, fires 2..N append to the existing description.org, and
;; STATE.md records only what actually happened.
;; moves from convention to structure.

(require 'iar-utils)
(require 'iar-breaker-witness)

;; Forward-declared: owned by iar-request-log.el (loads via `load' in
;; init.el; runtime reads are safe, standalone loads need the default).
(defvar iar--reqlog-last-msgs nil
  "Message count of the most recently dumped request (integer).
Published by iar-request-log.el's dump. nil until the first request
completes (or when the count was unavailable).")

;; Owned by this module (defvar, not defcustom: the threshold is a
;; design constant of the token-budget ruling, not a tuning knob).
(defvar iar-context-circuit-breaker-threshold 800
  "Message count at which the context circuit breaker ends the run
gracefully: state written, continuation task filed, :completed set.
Fires once per run. 600 < 800 < 900: the msgs fence's soft cap (600)
warns at the working bound, this breaker is the graceful early-exit
lane before the hard cap (900). c428 (2026-09-26): was 400 -- the
pre-0101 calibration, stale after relay 0101 raised the fence to
600/900. At 400 the breaker bound aria at ~200 requests (msgs grows
+2/request), 200 msgs BELOW the soft warning it precedes, killing
the deepest working runs (9 witnessed fires in 2 days, each a
legitimate deep run amputated mid-work). See
knowledge/iar/breaker-threshold-stale-2026-09-26.md.")

(declare-function iar--fs-append-file "append_file.el" (filepath content))
(declare-function iar--tool-create-task "create_task.el" (path description))
(declare-function iar--resolve-task-dir "iar-agent-utils.el" (task-path))
(declare-function iar--fence-state-writeback "iar-agent-cycle.el" (state))

(defun iar--context-circuit-breaker-active-state ()
  "Return the active run state (cycle first, then one-shot), or nil."
  (let ((state (or (and (boundp 'iar--cycle-state) iar--cycle-state)
                   (and (boundp 'iar--one-shot-state) iar--one-shot-state))))
    (when (plistp state) state)))

(defun iar--context-circuit-breaker-record-dir ()
  "Return the active agent's record directory
(audit/<project>/<personality>/), or nil when unresolvable."
  (let ((project (and (boundp 'iar--current-project) iar--current-project))
        (personality (and (boundp 'iar--current-personality)
                          iar--current-personality)))
    (when (and (stringp project) (> (length project) 0)
               (stringp personality) (> (length personality) 0))
      (expand-file-name (format "%s/%s" project personality)
                        (expand-file-name
                         (or (and (boundp 'iar-audit-path) iar-audit-path) "audit")
                         iar-personalization-path)))))

(defun iar--context-circuit-breaker-pre-call (_info)
  "Pre-tool-call hook: end the run gracefully at the msgs threshold.
The INFO arg is unused but kept for the hook contract. Returns nil
(allow) or (:block MSG) to block the call. The block message is the
model's landing instruction; the event loop sees :completed and exits
before the next request (the proven terminal-echo-close pattern,
c348). Never signals: a broken breaker must not take the tool path
down (fail-open)."
  (condition-case err
      (when (and (integerp iar--reqlog-last-msgs)
                 (> iar--reqlog-last-msgs 0)
                 (>= iar--reqlog-last-msgs iar-context-circuit-breaker-threshold))
        (let* ((state (iar--context-circuit-breaker-active-state))
               (agent (and state (plist-get state :agent)))
               (msgs iar--reqlog-last-msgs)
               (record-dir (iar--context-circuit-breaker-record-dir))
               (ts (format-time-string "%Y-%m-%d %H:%M:%S"))
               (task-path "token-budget/context-circuit-breaker-continuation")
               (task-desc-file (and task-path
                                    (condition-case nil
                                        (expand-file-name
                                         "description.org"
                                         (iar--resolve-task-dir task-path))
                                      (error nil)))))
          (when (and state (not (plist-get state :completed))
                     (not (plist-get state :context-circuit-breaker-fired)))
            ;; 1. Continuation task FIRST (c366 honesty): create_task
            ;; RETURNS "Error creating task: ..." as a STRING, never
            ;; signals (error-handler-as-accomplice). The old order
            ;; claimed "task filed" in STATE.md before the create ran,
            ;; and fires 2..N silently no-op'd on "Task already exists".
            (let* ((create-result
                    (condition-case cerr
                        (iar--tool-create-task
                         task-path
                         (format "Continuation after context circuit breaker fired at %s. Message count was %d (threshold %d), agent %s. Read STATE.md (last entry) and the previous cycle's journal to resume."
                                 ts msgs iar-context-circuit-breaker-threshold
                                 (or agent "unknown")))
                      (error (format "Error creating task: %s"
                                     (error-message-string cerr)))))
                   (task-outcome
                    (cond
                     ((and (stringp create-result)
                           (string-prefix-p "Task created" create-result))
                      "continuation task filed")
                     ((and (stringp create-result)
                           (string-match-p "Task already exists" create-result))
                      ;; Fires 2..N: append this fire's line to the
                      ;; existing description.org so the record of THIS
                      ;; fire is not lost.
                      (when (and task-desc-file
                                 (file-exists-p task-desc-file))
                        (condition-case aerr
                            (iar--fs-append-file
                             task-desc-file
                             (format "\n** Additional fire %s: msgs=%d (threshold %d), agent %s. State written for continuation; see STATE.md.\n"
                                     ts msgs iar-context-circuit-breaker-threshold
                                     (or agent "unknown")))
                          (error
                           (message "[context-circuit-breaker] description append failed: %s"
                                    (error-message-string aerr)))))
                      "continuation task already existed (fire line appended)")
                     (t (format "continuation task FAILED: %s" create-result)))))
              ;; 2. STATE.md fire record SECOND, with the honest outcome.
              (when record-dir
                (condition-case werr
                    (iar--fs-append-file
                     (expand-file-name "STATE.md" record-dir)
                     (format "\n** Context circuit breaker fired %s\nmsgs=%d (threshold %d), agent=%s. State written for continuation; %s (tasks/%s).\n%s\n"
                             ts msgs iar-context-circuit-breaker-threshold
                             (or agent "unknown") task-outcome task-path
                             (iar--breaker-witness-line)))
                  (error
                   (message "[context-circuit-breaker] state write failed: %s"
                            (error-message-string werr)))))
            ;; 3. Graceful end: mark completed, writeback, block.
            (setq state (plist-put state :context-circuit-breaker-fired t))
            (setq state (plist-put state :completed t))
            (setq state (plist-put state :exit-code 0))
            (iar--fence-state-writeback state)
            (message "[%s] Context circuit breaker: msgs=%d >= %d -- state written, %s, ending run"
                     (or agent "unknown") msgs
                     iar-context-circuit-breaker-threshold task-outcome)
            (list :block
                  (format "Context circuit breaker: message count %d >= threshold %d. The run is ending gracefully. %s. Write nothing more except your final summary as text."
                          msgs iar-context-circuit-breaker-threshold
                          (capitalize (substring task-outcome 0 1))))))))
    (error
     (message "[context-circuit-breaker] internal error (ignored): %s"
              (error-message-string err))
     nil)))

(defun iar--context-circuit-breaker-setup ()
  "Install the context circuit breaker on the pre-tool-call hook.
Idempotent."
  (remove-hook 'iar-pre-tool-call-functions
               #'iar--context-circuit-breaker-pre-call)
  (add-hook 'iar-pre-tool-call-functions
            #'iar--context-circuit-breaker-pre-call))

(iar--context-circuit-breaker-setup)

(provide 'iar-context-circuit-breaker)