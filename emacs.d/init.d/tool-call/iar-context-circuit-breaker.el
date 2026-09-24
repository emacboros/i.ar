;; -*- lexical-binding: t; -*-

;;; Context Circuit Breaker -- prevent token burn from excessive tool calls
;;
;; This module implements a context circuit breaker that monitors the
;; message count (from iar--reqlog-last-msgs) and when it exceeds a
;; threshold (400), it:
;; 1. Writes state to STATE.md
;; 2. Files a continuation task in token-budget/context-circuit-breaker-continuation/
;; 3. Requests graceful cycle end via fence state mechanisms
;; 4. Only fires once per run to prevent multiple interruptions
;;
;; This is a structural implementation of the behavioral rule: stop if
;; msgs >= 400, write state, file continuation task.

(require 'iar-utils)
(require 'iar-agent-utils)

;; Forward-declared: owned by iar-request-log.el
(defvar iar--reqlog-last-msgs nil
  "Message count of the most recently dumped request (integer).
Published by iar-request-log.el's dump alongside
iar--reqlog-last-tokens-in. nil until the first request completes
(or when the count was unavailable).")

;; Forward declarations for functions defined elsewhere
(declare-function append-file "iar-tool-call.el" (filepath content))
(declare-function create-task "tasks.el" (path description))
(declare-function iar--agent-personality-dir "iar-agent-utils.el" ()
  "Return the agent's personalization directory.")
(declare-function iar--fence-state-writeback "iar-fence.el" (state)
  "Write state back to the active cycle/one-shot state.")

;; Configuration - threshold for triggering the circuit breaker
(defvar iar-context-circuit-breaker-threshold 400
  "Message count threshold at which the context circuit breaker triggers.
When iar--reqlog-last-msgs >= this value, the breaker fires.")

(defvar iar-context-circuit-breaker-fired nil
  "Whether the circuit breaker has fired in this run.
Prevents multiple firings.")

(defun iar--context-circuit-breaker-active-state ()
  "Return the active run state (cycle first, then one-shot), or nil."
  (let ((state (or (and (boundp 'iar--cycle-state) iar--cycle-state)
                   (and (boundp 'iar--one-shot-state) iar--one-shot-state))))
    (when (plistp state) state)))

(defun iar--context-circuit-breaker-write-state (state)
  "Write current state to STATE.md for continuation."
  (when state
    (let* ((agent (plist-get state :agent))
           (cycle-seq (plist-get state :cycle-seq))
           (timestamp (format-time-string "%Y-%m-%d %H:%M:%S"))
           (content (format "* Context circuit breaker fired at %s\nTriggered by message count: %d (threshold: %d)\nAgent: %s\nCycle: %d\nThis state was written to allow continuation in next cycle.\n"
                            timestamp
                            (or iar--reqlog-last-msgs 0)
                            iar-context-circuit-breaker-threshold
                            (or agent "unknown")
                            (or cycle-seq 0))))
      (append-file
       (expand-file-name "STATE.md" (iar--agent-personality-dir))
       content))))

(defun iar--context-circuit-breaker-file-continuation-task (state)
  "File a continuation task for the next cycle."
  (when state
    (let* ((agent (plist-get state :agent))
           (cycle-seq (plist-get state :cycle-seq))
           (timestamp (format-time-string "%Y-%m-%d %H:%M:%S"))
           (task-dir "token-budget/context-circuit-breaker-continuation")
           (task-description (format "Continuation after context circuit breaker fired at %s\nMessage count was %d (threshold: %d)\nAgent: %s\nCycle: %d\nThis task was filed to continue work after breaker interruption.\n"
                                     timestamp
                                     (or iar--reqlog-last-msgs 0)
                                     iar-context-circuit-breaker-threshold
                                     (or agent "unknown")
                                     (or cycle-seq 0))))
      (create-task
       task-dir
       task-description))))

(defun iar--context-circuit-breaker-request-graceful-end (state)
  "Request graceful cycle end via fence state mechanisms."
  (when state
    (setf (plist-get state :context-circuit-breaker-fired) t)
    (setf (plist-get state :completed) t)
    (setf (plist-get state :exit-code) 0)  ; Normal completion, not failure
    (iar--fence-state-writeback state)))

(defun iar--context-circuit-breaker-pre-call (info)
  "Pre-tool-call hook: check message count and trigger circuit breaker if needed.
INFO is the gptel pre-tool-call plist (:name :args :buffer ...).
Returns nil (allow) or (:block MSG) to block the call."
  (when (and iar--reqlog-last-msgs
             (integerp iar--reqlog-last-msgs)
             (>= iar--reqlog-last-msgs iar-context-circuit-breaker-threshold)
             (not iar-context-circuit-breaker-fired))
    (let* ((state (iar--context-circuit-breaker-active-state))
           (agent (plist-get state :agent))
           (msgs iar--reqlog-last-msgs))
      (when state
        (setq iar-context-circuit-breaker-fired t)
        (iar--context-circuit-breaker-write-state state)
        (iar--context-circuit-breaker-file-continuation-task state)
        (iar--context-circuit-breaker-request-graceful-end state)
        (message "[%s] Context circuit breaker triggered: msgs=%d >= threshold=%d"
                 agent msgs iar-context-circuit-breaker-threshold)
        ;; Return a block message that explains why we're stopping
        (list :block
              (format "Context circuit breaker triggered: message count %d >= threshold %d. State written, continuation filed, cycle ending gracefully."
                      msgs iar-context-circuit-breaker-threshold))))))

(defun iar--context-circuit-breaker-setup ()
  "Install the context circuit breaker on the pre-tool-call hook. Idempotent."
  (remove-hook 'iar-pre-tool-call-functions #'iar--context-circuit-breaker-pre-call)
  (add-hook 'iar-pre-tool-call-functions #'iar--context-circuit-breaker-pre-call))

(iar--context-circuit-breaker-setup)

(provide 'iar-context-circuit-breaker)