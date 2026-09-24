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
;; Threshold: 400 < msgs-fence soft 600 -- this fires FIRST and ends
;; the run with a record instead of letting the fence warn at 600 and
;; hard-cap at 900. One fire per run (:context-circuit-breaker-fired
;; in the run state, not a global -- a global survives across runs
;; and would silently disarm the breaker forever).

(require 'iar-utils)

;; Forward-declared: owned by iar-request-log.el (loads via `load' in
;; init.el; runtime reads are safe, standalone loads need the default).
(defvar iar--reqlog-last-msgs nil
  "Message count of the most recently dumped request (integer).
Published by iar-request-log.el's dump. nil until the first request
completes (or when the count was unavailable).")

;; Owned by this module (defvar, not defcustom: the threshold is a
;; design constant of the token-budget ruling, not a tuning knob).
(defvar iar-context-circuit-breaker-threshold 400
  "Message count at which the context circuit breaker ends the run
gracefully: state written, continuation task filed, :completed set.
Fires once per run. 400 < iar-msgs-soft-cap (600): this is the
early-exit lane, the fence is the backstop.")

(declare-function iar--fs-append-file "append_file.el" (filepath content))
(declare-function iar--tool-create-task "create_task.el" (path description))
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
               (task-path "token-budget/context-circuit-breaker-continuation"))
          (when (and state (not (plist-get state :completed))
                     (not (plist-get state :context-circuit-breaker-fired)))
            ;; 1. State write (best-effort; the run ends either way).
            (when record-dir
              (condition-case werr
                  (iar--fs-append-file
                   (expand-file-name "STATE.md" record-dir)
                   (format "\n** Context circuit breaker fired %s\nmsgs=%d (threshold %d), agent=%s. State written for continuation; continuation task filed at tasks/%s.\n"
                           ts msgs iar-context-circuit-breaker-threshold
                           (or agent "unknown") task-path))
                (error
                 (message "[context-circuit-breaker] state write failed: %s"
                          (error-message-string werr)))))
            ;; 2. Continuation task (best-effort).
            (condition-case terr
                (iar--tool-create-task
                 task-path
                 (format "Continuation after context circuit breaker fired at %s. Message count was %d (threshold %d), agent %s. Read STATE.md (last entry) and the previous cycle's journal to resume."
                         ts msgs iar-context-circuit-breaker-threshold
                         (or agent "unknown")))
              (error
               (message "[context-circuit-breaker] continuation task failed: %s"
                        (error-message-string terr))))
            ;; 3. Graceful end: mark completed, writeback, block.
            (setq state (plist-put state :context-circuit-breaker-fired t))
            (setq state (plist-put state :completed t))
            (setq state (plist-put state :exit-code 0))
            (iar--fence-state-writeback state)
            (message "[%s] Context circuit breaker: msgs=%d >= %d -- state written, continuation filed, ending run"
                     (or agent "unknown") msgs
                     iar-context-circuit-breaker-threshold)
            (list :block
                  (format "Context circuit breaker: message count %d >= threshold %d. The run is ending gracefully. State was written and a continuation task was filed. Write nothing more except your final summary as text."
                          msgs iar-context-circuit-breaker-threshold)))))
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