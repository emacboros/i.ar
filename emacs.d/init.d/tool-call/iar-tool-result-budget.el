;; -*- lexical-binding: t; -*-

;;; Tool Result Budget Trailer -- Time Visibility for Agents
;;
;; Appends a budget trailer to every tool result before it enters the
;; conversation buffer:
;;
;;   [t+MM:SS/WALL cNN/CAP]
;;   e.g. [t+14:32/30:00 c46/120]
;;
;; MM:SS = elapsed wall-clock since cycle start; WALL = the cycle's
;; wall-clock timeout in minutes; NN = tool calls used including this
;; one; CAP = the soft tool-call cap.
;;
;; STATE, not alarm: no thresholds, no warn logic. The c67 anomaly
;; (soft-cap warn fired silently) is evidence that threshold machinery
;; has bugs; a constant fact has no threshold logic to fail. The agent
;; reads the trailer as calibration data: plan remaining work against
;; remaining budget, closes-first as the budget depletes.
;;
;; SHARED CLOCK (the scar-list law): the trailer and the wall fence
;; read the SAME t0 -- the cycle state's :start-time, set once in
;; iar--cycle-make-state / iar--one-shot-make-state. The event loops
;; compute their deadline from the same :start-time, so the trailer's
;; clock and the fence's clock cannot drift apart. A unit test pins
;; the equality.
;;
;; Placement: OUTERMOST advice on gptel--process-tool-call (loaded
;; after iar-tool-result-timestamp.el). Chain: budget (outer) ->
;; timestamp -> truncation -> gptel original. The trailer is appended
;; BEFORE truncation at the result's tail; middle-truncation preserves
;; head and tail, so the trailer survives even truncated results.
;;
;; No active cycle/one-shot state -> no trailer (interactive sessions
;; are not budgeted). State without :start-time (minimal test plists)
;; -> no trailer (graceful: never manufacture a clock).
;;
;; Config: configs/tool-limits.el owns iar-tool-result-budget (nil to
;; disable).

(require 'iar-utils)

;; Forward-declared: owned by configs/tool-limits.el.
(defvar iar-tool-result-budget nil
  "When non-nil, append a budget trailer to tool results.
Owned by configs/tool-limits.el.")

;; Forward-declared: owned by iar-agent-cycle.el (loads after this
;; module; runtime reads are safe, standalone loads need the default).
(defvar iar-cycle-tool-call-cap 120
  "SOFT cap: tool calls per cycle before tools are blocked.
Owned by iar-agent-cycle.el; forward-declared here so the trailer
can read it without a load-order dependency.")

;; The active state variables are DEFINED in iar-tool-call.el (which
;; loads before this module); no redefinition here -- defvar only
;; binds when void, and redeclaring would be a no-op anyway. This
;; module only READS them.

(defun iar--budget-active-state ()
  "Return the active run state (cycle first, then one-shot), or nil.
Returns nil when neither state is a live plist -- interactive
sessions, delegates, and teardown windows all read as nil."
  (let ((state (or (and (boundp 'iar--cycle-state) iar--cycle-state)
                   (and (boundp 'iar--one-shot-state) iar--one-shot-state))))
    (when (plistp state) state)))

(defun iar--budget-trailer-string (state)
  "Build the budget trailer for STATE, or nil when it cannot be honest.
Honesty rules: no :start-time -> nil (never manufacture a clock);
no :wall-timeout -> nil (a trailer without a wall is half an
instrument). The tool-call count INCLUDES the current call: the
trailer is appended before the tracker's post-call increment, so
the count shown is (1+ :tool-call-count)."
  (let ((start (plist-get state :start-time))
        (wall (plist-get state :wall-timeout)))
    (when (and start wall)
      (let* ((elapsed (max 0 (round (float-time (time-subtract nil start)))))
             (mins (/ elapsed 60))
             (secs (% elapsed 60))
             (calls (1+ (or (plist-get state :tool-call-count) 0)))
             (cap (or (and (boundp 'iar-cycle-tool-call-cap)
                           iar-cycle-tool-call-cap)
                      0)))
        (format "[t+%02d:%02d/%d:%02d c%d/%d]"
                mins secs
                (/ wall 60) (% wall 60)
                calls cap)))))

(defun iar--budget-append-trailer (result)
  "Append the budget trailer to RESULT when enabled and stateful.
Returns RESULT unchanged when disabled, non-string, already
trailered (idempotent -- advice may run twice), or when no honest
trailer can be built."
  (if (or (null iar-tool-result-budget)
          (not (stringp result))
          (string-match-p "\\[t\\+[0-9][0-9]:[0-9][0-9]/" result))
      result
    (let ((state (iar--budget-active-state)))
      (if-let* ((trailer (and state (iar--budget-trailer-string state))))
          (concat result "\n" trailer)
        result))))

(defun iar--budget-tool-result-advice (orig-fun fsm tool-spec tool-call result)
  "Around advice on `gptel--process-tool-call'.
Appends the budget trailer to RESULT before the inner advice
(timestamp, truncation) and the original function see it. The
trailer sits at the result's tail, so middle-truncation preserves
it (head+tail are kept)."
  (let ((trailered (iar--budget-append-trailer result)))
    (funcall orig-fun fsm tool-spec tool-call trailered)))

(defun iar--budget-setup ()
  "Install budget trailer advice. Idempotent."
  (advice-remove 'gptel--process-tool-call #'iar--budget-tool-result-advice)
  (advice-add 'gptel--process-tool-call :around #'iar--budget-tool-result-advice))

(iar--budget-setup)

(provide 'iar-tool-result-budget)