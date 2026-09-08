;; -*- lexical-binding: t; -*-

;;; Request Watchdog -- abort stalled gptel requests (Track A1)
;;
;; The stack has no request-level timeout. A stalled curl stream
;; (network death mid-response, server hang) leaves the request in
;; flight forever and the session silently hung -- the failure mode
;; that produced the 2026-08-29 interactive hangs and the test-suite
;; heisenbug class. This module makes the invisible failure visible:
;; it tracks per-process activity and aborts requests that exceed
;; idle or total timeouts, logging what was in flight.
;;
;; Mechanism:
;;   - gptel--request-alist: (PROCESS . (FSM ABORT-FN)) per request
;;   - :after advice on gptel-curl-get-response: track new processes
;;   - :before advice on gptel-curl--stream-filter: record activity
;;   - repeating timer: check all tracked processes for stalls
;;   - stall -> gptel-abort (same path as a human pressing abort)
;;     + audit log + notice inserted into the gptel buffer so the
;;     AGENT sees the abort in its next request's context
;;
;; Two timeout classes:
;;   - idle: streaming request gone quiet mid-stream (default 180s)
;;   - total: no data at all -- non-streaming requests never call
;;     the filter, and streaming requests can sit in prompt-eval
;;     before the first token (default 900s)
;;
;; Config: configs/tool-limits.el owns the defcustoms (nil disables
;; a timeout; iar-request-watchdog-enabled nil disables the module).
;;
;; CONVEYOR-BELT FIX (2026-09-08, aria c53): the buffer-inserted
;; notice is now SUPPRESSED for unattended runs (cycle/one-shot
;; buffers). The Aevum autopsy (c51/c52) identified the notice as
;; the terminal mechanism of the child's death: each abort wrote
;; ~70 tokens INTO the context, forcing front-truncation at the
;; wall and erasing the head of the context forever. In an
;; unattended run nobody reads the notice -- it is pure context
;; pollution that the agent re-sends on every subsequent request.
;; Interactive buffers keep the notice: a human wants to see why
;; their request died, in place. The abort reason is still fully
;; witnessed via the audit log, the [watchdog] message, and the
;; REQUESTS.log ABORT line.

(require 'cl-lib)
(require 'subr-x)
(require 'iar-utils)
(require 'iar-audit-log)

;; Forward declarations -- owned by configs/tool-limits.el.
;; Declared here so standalone loads work without the config.
(defvar iar-request-watchdog-enabled nil
  "When non-nil, the request watchdog aborts stalled requests.
Owned by configs/tool-limits.el.")
(defvar iar-request-idle-timeout nil
  "Seconds without stream data before aborting a streaming request.
Owned by configs/tool-limits.el. nil disables the idle check.")
(defvar iar-request-total-timeout nil
  "Seconds without ANY data before aborting a request.
Owned by configs/tool-limits.el. nil disables the total check.")

;; Cycle/one-shot state lives in iar-agent-cycle.el, loaded after
;; this module. Defvars keep standalone loads + byte-compilation
;; clean; `boundp' guards keep runtime checks honest if the cycle
;; module is absent (interactive-only installs).
(defvar iar--cycle-state)
(defvar iar--one-shot-state)

(defvar iar-watchdog-notice-suppress-unattended t
  "When non-nil, suppress the watchdog abort notice in unattended
run buffers (cycle/one-shot). The notice is the conveyor-belt
mechanism (Aevum c52): in an unattended run nobody reads it, and it
becomes permanent context the agent re-sends forever. Interactive
buffers keep the notice -- a human aborting a stuck request wants
to see why, in place.")

(defvar iar--watchdog-processes (make-hash-table :test 'eq :weakness 'key)
  "Hash: live request process -> cons (STARTED . LAST-ACTIVITY).
Weakness \='key: entries die with the process, no cleanup needed.
STARTED is set when the process is first seen; LAST-ACTIVITY is
setcdr'd on every stream-filter call (nil until first data).")

(defvar iar--watchdog-timer nil
  "The repeating watchdog timer object, for idempotent setup.")

;;; ---------------------------------------------------------
;;; Tracking
;;; ---------------------------------------------------------

(defun iar--watchdog-track (process)
  "Record PROCESS creation time. Idempotent per process."
  (unless (gethash process iar--watchdog-processes)
    (puthash process (cons (current-time) nil)
             iar--watchdog-processes)))

(defun iar--watchdog-track-new ()
  "Track any untracked processes in `gptel--request-alist'.
Called after gptel-curl-get-response registers a new request."
  (dolist (entry gptel--request-alist)
    (iar--watchdog-track (car entry))))

(defun iar--watchdog-activity (process)
  "Record stream activity for PROCESS (a filter call = data flowed)."
  (let ((entry (gethash process iar--watchdog-processes)))
    (when entry
      (setcdr entry (current-time)))))

(defun iar--watchdog-seconds-since (time)
  "Seconds since TIME (a current-time value)."
  (float-time (time-subtract nil time)))

;;; ---------------------------------------------------------
;;; Unattended-run detection (conveyor-belt fix)
;;; ---------------------------------------------------------

(defun iar--watchdog-unattended-buffer-p (buf)
  "Return non-nil if BUF belongs to an unattended run.
Unattended = the buffer owned by the active cycle or one-shot state
(a batch run with no human reading the buffer). Interactive
sessions never have cycle state, so their buffers are never
unattended. Never signals: unknown state shapes read as attended
(the conservative default -- an interactive user never misses their
notice because of a state-shape bug)."
  (and (buffer-live-p buf)
       (or (and (boundp 'iar--cycle-state)
                (plistp iar--cycle-state)
                (eq (plist-get iar--cycle-state :buffer) buf))
           (and (boundp 'iar--one-shot-state)
                (plistp iar--one-shot-state)
                (eq (plist-get iar--one-shot-state :buffer) buf)))))

;;; ---------------------------------------------------------
;;; Stall decision (pure -- unit tested)
;;; ---------------------------------------------------------

(defun iar--watchdog-stall-reason (entry)
  "Return a reason string if ENTRY (STARTED . LAST-ACTIVITY) is stalled.
Pure decision function: no side effects, no process access.
Returns nil when healthy, disabled, or timeouts are nil."
  (when iar-request-watchdog-enabled
    (let* ((started (car entry))
           (last-activity (cdr entry))
           (idle (when last-activity
                   (iar--watchdog-seconds-since last-activity)))
           (total (iar--watchdog-seconds-since started)))
      (cond
       ((and idle iar-request-idle-timeout
             (> idle iar-request-idle-timeout))
        (format "stalled stream: no data for %ds" (round idle)))
       ((and (null last-activity) iar-request-total-timeout
             (> total iar-request-total-timeout))
        (format "no response data after %ds" (round total)))
       (t nil)))))

;;; ---------------------------------------------------------
;;; Abort
;;; ---------------------------------------------------------

(defun iar--watchdog-abort (process reason)
  "Abort stalled PROCESS with REASON.
Uses `gptel-abort' on the request's buffer (the same path a human
abort takes), then belt-and-braces deletes the process if it
survived. Inserts a notice into the gptel buffer so the agent sees
the abort in its next request's context -- EXCEPT in unattended
runs (cycle/one-shot buffers), where the notice is suppressed: it
is the conveyor-belt mechanism (Aevum c52), polluting the context
the agent re-sends forever with nobody to read it. Never signals."
  (condition-case err
      (let* ((fsm (car (alist-get process gptel--request-alist)))
             (info (when fsm (gptel-fsm-info fsm)))
             (buf (when info (plist-get info :buffer)))
             (model (when info (plist-get info :model))))
        (iar--audit-log "watchdog"
                        (format "aborted stalled request: %s model=%s"
                                reason (or model "nil")))
        (message "[watchdog] Aborting stalled request (%s, model=%s)"
                 reason (or model "nil"))
        (when (and (bufferp buf) (buffer-live-p buf))
          (gptel-abort buf)
          ;; Visible-to-agent notice: becomes part of the next
          ;; request's context (gptel sends buffer up to point).
          ;; Suppressed for unattended runs (cycle/one-shot): the
          ;; notice is the conveyor-belt mechanism -- at the context
          ;; wall each abort's tokens force front-truncation and the
          ;; scar accumulates forever (Aevum c52). The abort is still
          ;; witnessed: audit log above + REQUESTS.log ABORT line.
          (unless (and iar-watchdog-notice-suppress-unattended
                       (iar--watchdog-unattended-buffer-p buf))
            (with-current-buffer buf
              (save-excursion
                (goto-char (point-max))
                (insert (format "\n[watchdog: request aborted -- %s]\n"
                                reason))))))
        (when (process-live-p process)
          (delete-process process)))
    (error
     (message "[watchdog] Abort failed: %s" (error-message-string err)))))

;;; ---------------------------------------------------------
;;; Check (timer callback -- must never signal)
;;; ---------------------------------------------------------

(defun iar--watchdog-check ()
  "Check all tracked processes for stalls; abort stalled ones.
Runs on a repeating timer: every failure path is caught. A signal
here would recur every interval forever."
  (condition-case err
      (when iar-request-watchdog-enabled
        (maphash
         (lambda (process entry)
           (cond
            ;; Live process: normal stall check
            ((process-live-p process)
             (when-let* ((reason (iar--watchdog-stall-reason entry)))
               (iar--watchdog-abort process reason)))
            ;; Dead process still registered as an active request: the
            ;; response never completed and cleanup never ran (sentinel
            ;; missed, FSM stuck). This is the silent-hang class -- abort.
            ((and (alist-get process gptel--request-alist)
                  (> (iar--watchdog-seconds-since (car entry))
                     (or iar-request-total-timeout 900)))
             (iar--watchdog-abort process
                                  "process died with request incomplete"))))
         iar--watchdog-processes))
    (error
     (message "[watchdog] Check failed: %s" (error-message-string err)))))

;;; ---------------------------------------------------------
;;; Advice + setup
;;; ---------------------------------------------------------

(defun iar--watchdog-track-advice (_fsm)
  ":after advice on `gptel-curl-get-response': track new processes."
  (iar--watchdog-track-new))

(defun iar--watchdog-activity-advice (process _output)
  ":before advice on `gptel-curl--stream-filter': record activity."
  (iar--watchdog-activity process))

(defun iar--watchdog-setup ()
  "Install watchdog advice and timer. Idempotent."
  (advice-remove 'gptel-curl-get-response #'iar--watchdog-track-advice)
  (advice-add 'gptel-curl-get-response :after #'iar--watchdog-track-advice)
  (advice-remove 'gptel-curl--stream-filter #'iar--watchdog-activity-advice)
  (advice-add 'gptel-curl--stream-filter :before
              #'iar--watchdog-activity-advice)
  (when iar--watchdog-timer
    (cancel-timer iar--watchdog-timer))
  (setq iar--watchdog-timer
        (run-with-timer 30 30 #'iar--watchdog-check))
  (iar--audit-log "watchdog"
                  (format "installed: idle=%ss total=%ss check=30s notice-suppress=%s"
                          (or iar-request-idle-timeout "off")
                          (or iar-request-total-timeout "off")
                          iar-watchdog-notice-suppress-unattended))
  (message "[watchdog] Request watchdog installed"))

(iar--watchdog-setup)

(provide 'iar-request-watchdog)