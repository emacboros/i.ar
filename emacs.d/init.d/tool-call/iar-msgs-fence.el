;; -*- lexical-binding: t; -*-

;;; Msgs Fence -- soft/hard caps on per-request message count
;;
;; Mirrors the context-size fence (iar-context-fence.el) on the MSGS
;; dimension: the message count of the last request is the best
;; pre-call estimate of the next request's size (each request re-sends
;; the accumulated conversation plus one response plus one tool
;; result).
;;
;; Relay 0035 option B (aria c201 design note, built c203): the
;; behavioral msgs>=400 rule (continuo's stop-if-crossed rule) becomes
;; a structural backstop. Option A (d4cac66) made msgs checkable with
;; one grep of the PARSE line; this fence makes the rule checkable by
;; the PLUMBING -- the model never has to poll anything, which is what
;; killed continuo c177 (self-echo trap, 39 variants, 5.29M tokens).
;;
;; Census data (c201, first msgs=N census): aria p50=155 p90=336
;; max=398 (n=828); continuo p50=39 p90=81 max=160 (n=470); zero
;; requests >=400 msgs ever on either side. The soft cap (400) warns
;; just past aria's observed max; the hard cap (600) is the 1.5x
;; backstop. The rule binds deep cycles (aria's shape), not continuo's.
;;
;; Data source: iar--reqlog-last-msgs, published by iar-request-log.el
;; dump alongside iar--reqlog-last-tokens-in. NA (unavailable) -> nil:
;; the fence never fires on absence of data.
;;
;; Scope: cycles and one-shots (state-dispatched, same as the other
;; fences). Interactive sessions are NOT fenced -- the human is the
;; interactive session's budget owner.
;;
;; Config: configs/tool-limits.el owns the defcustoms.

(require 'iar-utils)

;; Forward-declared: owned by iar-request-log.el (loads via `load' in
;; init.el; runtime reads are safe, standalone loads need the default).
(defvar iar--reqlog-last-msgs nil
  "Message count of the most recently dumped request (integer).
Published by iar-request-log.el's dump alongside
iar--reqlog-last-tokens-in. nil until the first request completes
(or when the count was unavailable).")

;; Forward-declared: owned by configs/tool-limits.el.
(defvar iar-msgs-fence nil
  "When non-nil, fence cycles/one-shots on per-request message count.
Owned by configs/tool-limits.el.")
(defvar iar-msgs-soft-cap nil
  "SOFT WARN: message count at which one call is blocked with a
converge notice (fires once per run). Owned by configs/tool-limits.el.")
(defvar iar-msgs-hard-cap nil
  "HARD CAP: message count past which non-memory tool calls are
blocked with the landing instruction. Owned by configs/tool-limits.el.")
(defvar iar-msgs-hard-cap-blocks nil
  "Ignored hard-cap blocks before the run is force-ended.
Owned by configs/tool-limits.el.")

(defun iar--msgs-fence-active-state ()
  "Return the active run state (cycle first, then one-shot), or nil."
  (let ((state (or (and (boundp 'iar--cycle-state) iar--cycle-state)
                   (and (boundp 'iar--one-shot-state) iar--one-shot-state))))
    (when (plistp state) state)))

(defun iar--msgs-fence-message (kind msgs limit)
  "Build the fence message for KIND at MSGS against LIMIT."
  (pcase kind
    (:warn
     (format "MSGS FAT warning: the last request carried %d messages (soft cap %d). Message count grows one-per-round-trip and every message rides every future request. Converge NOW: close the thread, batch remaining work into single commands, write your records (journal/HISTORY/roadmap) before starting anything new. This call was NOT lost -- retry it. This warning fires once."
             msgs limit))
    (:hard
     (format "MSGS HARD CAP (%d messages) exceeded (last request: %d). STOP calling tools (except memory/record tools: append_file, write_file, write_subtask, write_roadmap, git_commit, send_telegram -- those still work). %s"
             limit msgs
             (iar--fence-summary-instruction)))))

(defun iar--msgs-fence-pre-call (info)
  "Pre-tool-call hook: msgs soft warn + hard cap.
INFO is the gptel pre-tool-call plist (:name :args :buffer ...).
Returns nil (allow) or (:block MSG). Memory/record tools are never
blocked: the landing IS the memory pass (same list as the other
fences). No state, no msgs yet (first request of a run), or
disabled -> nil."
  (when (and iar-msgs-fence
             (integerp iar--reqlog-last-msgs)
             (> iar--reqlog-last-msgs 0))
    (let ((state (iar--msgs-fence-active-state)))
      (when state
        (let* ((agent (plist-get state :agent))
               (tool-name (plist-get info :name))
               (memory-tool-p (member tool-name '("append_file" "write_file"
                                                  "write_subtask" "write_roadmap"
                                                  "git_commit" "send_telegram")))
               (msgs iar--reqlog-last-msgs))
          (cond
           ;; ---- HARD CAP ----
           ((and (not memory-tool-p)
                 (>= msgs iar-msgs-hard-cap))
            (let ((blocks (1+ (or (plist-get state :msgs-blocks) 0))))
              (setf (plist-get state :msgs-blocks) blocks)
              (iar--fence-state-writeback state)
              (if (>= blocks iar-msgs-hard-cap-blocks)
                  (progn
                    (message "[%s] Msgs hard cap: %d ignored blocks (msgs %d >= %d) -- ending run"
                             agent blocks msgs iar-msgs-hard-cap)
                    ;; c-scar law: absent-key setf through the alias is
                    ;; lossy -- writeback AFTER every mutation, and the
                    ;; keys are setf'd on the same `state' object the
                    ;; writeback publishes.
                    (setq state (plist-put state :completed t))
                    (setq state (plist-put state :exit-code 1))
                    (iar--fence-state-writeback state)
                    (list :block
                          (format "Msgs hard cap: %d ignored landing instructions at >= %d messages. The run is ending now."
                                  blocks iar-msgs-hard-cap)))
                (message "[%s] Msgs hard cap (%d msgs >= %d) -- blocking tool, demanding summary (block %d/%d)"
                         agent msgs iar-msgs-hard-cap blocks iar-msgs-hard-cap-blocks)
                (list :block
                      (format "Msgs hard cap (%d messages) exceeded. STOP calling tools (except memory/record tools: append_file, write_file, write_subtask, write_roadmap, git_commit, send_telegram -- those still work). %s"
                              msgs (iar--fence-summary-instruction))))))
           ;; ---- SOFT WARN (once per run) ----
           ((and (not memory-tool-p)
                 (>= msgs iar-msgs-soft-cap)
                 (not (plist-get state :msgs-warned)))
            (setf (plist-get state :msgs-warned) t)
            (iar--fence-state-writeback state)
            (message "[%s] Msgs soft cap warning (msgs %d >= %d) -- one call blocked with notice"
                     agent msgs iar-msgs-soft-cap)
            (list :block
                  (iar--msgs-fence-message :warn msgs iar-msgs-soft-cap)))
           ;; Under all gates -> allow
           (t nil)))))))

(defun iar--msgs-fence-setup ()
  "Install the msgs fence on the pre-tool-call hook. Idempotent."
  (remove-hook 'iar-pre-tool-call-functions #'iar--msgs-fence-pre-call)
  (add-hook 'iar-pre-tool-call-functions #'iar--msgs-fence-pre-call))

(iar--msgs-fence-setup)

(provide 'iar-msgs-fence)