;; -*- lexical-binding: t; -*-

;;; Context-Size Fence -- soft/hard caps on per-request input tokens
;;
;; Mirrors the tool-call cap architecture (warn / soft / hard) on the
;; INPUT side: the budget trailer made TIME and CALLS visible; this
;; makes CONTEXT SIZE visible and bounded.
;;
;; Rationale (aria-0005 + c88 census + c90 death):
;; - 16% of requests carried tokens_in > 60k and held 27% of input burn.
;; - c90 died on the tool-call hard cap with 130 requests / 7.2M input
;;   tokens -- the fat-context class. The model cannot see its own
;;   context size; the plumbing can (request-log PARSE lines carry
;;   tokens_in).
;; - A same-tool warning does not converge behavior (proven twice:
;;   aria c57, continuo c151); STRUCTURAL visibility does (cap halving
;;   worked). Hence caps, not just a warning.
;;
;; THREE GATES (Nacho design, 2026-09-08 session VI):
;; - SOFT WARN (iar-context-soft-cap, default 128k tokens): block ONE
;;   non-memory tool call with a converge notice; the call is retried.
;;   Fires once per run. Mirrors iar-cycle-tool-call-warn.
;; - HARD CAP (iar-context-hard-cap, default 512k tokens): every
;;   non-memory tool call past this is BLOCKED with the landing
;;   instruction; memory tools still allowed. After
;;   iar-context-hard-cap-blocks ignored blocks, the run ends (exit 1).
;;   Mirrors iar-cycle-tool-call-cap + hard-cap-blocks.
;;
;; Why tokens, not chars: the existing context breaker measures
;; sendable CHARS (800k chars ~ 200k tokens) and fires as a last-resort
;; circuit breaker. This fence measures TOKENS as reported by the
;; backend (iar--reqlog-last-tokens-in), which is the honest unit the
;; billing and the burn censuses use. The two instruments are
;; complementary: chars bound the buffer, tokens bound the request.
;;
;; DATA SOURCE: iar--reqlog-last-tokens-in, published by
;; iar-request-log.el's dump (the same shared-state pattern as
;; iar--reqlog-last-tokens-out). tokens_in of the PREVIOUS request is
;; the best pre-call estimate of the NEXT request's size (the next
;; request re-sends everything plus one response plus one tool result).
;;
;; Scope: cycles and one-shots (state-dispatched, same as the other
;; fences). Interactive sessions are NOT fenced (no state) -- the
;; human is the interactive session's budget owner.
;;
;; Config: configs/tool-limits.el owns the defcustoms.

(require 'iar-utils)

;; Forward-declared: owned by iar-request-log.el (loads via `load' in
;; init.el; runtime reads are safe, standalone loads need the default).
(defvar iar--reqlog-last-tokens-in nil
  "Input token count of the most recently dumped request (integer).
Published by iar-request-log.el's dump alongside
iar--reqlog-last-tokens-out. nil until the first request completes.")

;; Forward-declared: owned by configs/tool-limits.el.
(defvar iar-context-fence nil
  "When non-nil, fence cycles/one-shots on per-request input tokens.
Owned by configs/tool-limits.el.")
(defvar iar-context-soft-cap nil
  "SOFT WARN: input tokens at which one call is blocked with a
converge notice (fires once per run). Owned by configs/tool-limits.el.")
(defvar iar-context-hard-cap nil
  "HARD CAP: input tokens past which non-memory tool calls are
blocked with the landing instruction. Owned by configs/tool-limits.el.")
(defvar iar-context-hard-cap-blocks nil
  "Ignored hard-cap blocks before the run is force-ended.
Owned by configs/tool-limits.el.")

(defun iar--context-fence-active-state ()
  "Return the active run state (cycle first, then one-shot), or nil."
  (let ((state (or (and (boundp 'iar--cycle-state) iar--cycle-state)
                   (and (boundp 'iar--one-shot-state) iar--one-shot-state))))
    (when (plistp state) state)))

(defun iar--context-fence-message (kind tokens limit)
  "Build the fence message for KIND at TOKENS against LIMIT."
  (pcase kind
    (:warn
     (format "CONTEXT FAT warning: the last request carried %d input tokens (soft cap %d). Context grows non-linearly in cost: every further round-trip re-sends everything. Converge NOW: close the thread, batch remaining work into single commands, write your records (journal/HISTORY/roadmap) before starting anything new. This call was NOT lost -- retry it. This warning fires once."
             tokens limit))
    (:hard
     (format "CONTEXT HARD CAP (%d tokens) exceeded (last request: %d). STOP calling tools (except memory/record tools: append_file, write_file, write_subtask, write_roadmap, git_commit, send_telegram -- those still work). %s"
             limit tokens
             (iar--fence-summary-instruction)))))

(defun iar--context-fence-pre-call (info)
  "Pre-tool-call hook: context-size soft warn + hard cap.
INFO is the gptel pre-tool-call plist (:name :args :buffer ...).
Returns nil (allow) or (:block MSG). Memory/record tools are never
blocked: the landing IS the memory pass (same list as the tool-call
cap). No state, no tokens_in yet (first request of a run), or
disabled -> nil."
  (when (and iar-context-fence
             (numberp iar--reqlog-last-tokens-in)
             (> iar--reqlog-last-tokens-in 0))
    (let ((state (iar--context-fence-active-state)))
      (when state
        (let* ((agent (plist-get state :agent))
               (tool-name (plist-get info :name))
               (memory-tool-p (member tool-name '("append_file" "write_file"
                                                  "write_subtask" "write_roadmap"
                                                  "git_commit" "send_telegram")))
               (toks iar--reqlog-last-tokens-in))
          (cond
           ;; ---- HARD CAP ----
           ((and (not memory-tool-p)
                 (>= toks iar-context-hard-cap))
            (let ((blocks (1+ (or (plist-get state :ctx-blocks) 0))))
              (setf (plist-get state :ctx-blocks) blocks)
              (iar--fence-state-writeback state)
              (if (>= blocks iar-context-hard-cap-blocks)
                  (progn
                    (message "[%s] Context hard cap: %d ignored blocks (tokens_in %d >= %d) -- ending run"
                             agent blocks toks iar-context-hard-cap)
                    ;; c-scar law: absent-key setf through the alias is
                    ;; lossy -- writeback AFTER every mutation, and the
                    ;; keys are setf'd on the same `state' object the
                    ;; writeback publishes. (:completed/:exit-code are
                    ;; absent from a fresh state; the writeback must
                    ;; follow them or the run never ends.)
                    (setq state (plist-put state :completed t))
                    (setq state (plist-put state :exit-code 1))
                    (iar--fence-state-writeback state)
                    (list :block
                          (format "Context hard cap: %d ignored landing instructions at >= %d tokens. The run is ending now."
                                  blocks iar-context-hard-cap)))
                (message "[%s] Context hard cap (%d tokens >= %d) -- blocking tool, demanding summary (block %d/%d)"
                         agent toks iar-context-hard-cap blocks iar-context-hard-cap-blocks)
                (list :block
                      (format "Context hard cap (%d tokens) exceeded. STOP calling tools (except memory/record tools: append_file, write_file, write_subtask, write_roadmap, git_commit, send_telegram -- those still work). %s"
                              toks (iar--fence-summary-instruction))))))
           ;; ---- SOFT WARN (once per run) ----
           ((and (not memory-tool-p)
                 (>= toks iar-context-soft-cap)
                 (not (plist-get state :ctx-warned)))
            (setf (plist-get state :ctx-warned) t)
            (iar--fence-state-writeback state)
            (message "[%s] Context soft cap warning (tokens_in %d >= %d) -- one call blocked with notice"
                     agent toks iar-context-soft-cap)
            (list :block
                  (iar--context-fence-message :warn toks iar-context-soft-cap)))
           ;; Under all gates -> allow
           (t nil)))))))

(defun iar--context-fence-setup ()
  "Install the context fence on the pre-tool-call hook. Idempotent."
  (remove-hook 'iar-pre-tool-call-functions #'iar--context-fence-pre-call)
  (add-hook 'iar-pre-tool-call-functions #'iar--context-fence-pre-call))

(iar--context-fence-setup)

(provide 'iar-context-fence)