;; -*- lexical-binding: t; -*-

;;; Thinking-Loop Guard -- early-abort runaway reasoning streams
;;
;; The disease (relay 0085, aria c54): nemotron-3-super's thinking
;; runs away on 5-54% of continuo's cycles -- a single response
;; streams 1.2M+ chars of reasoning with NO content and NO tool
;; calls, hits the 32768 num_predict cap, and the cycle-level
;; thinking-only guard ends the cycle (exit 1, no grace). Each fire
;; burns the full output budget plus ~10 minutes of wall-clock on a
;; cycle that was never going to land.
;;
;; The mechanism here is EARLY ABORT: while the response is still
;; streaming, track how many reasoning bytes have arrived since the
;; last real content (text or tool-call). A cycle turn that thinks
;; >16k chars without producing anything is already the disease --
;; normal per-turn thinking between tool calls is <2k chars
;; (corpus: continuo's healthy runs, 09-15..09-17). Abort at 16k,
;; 75x below the smallest observed runaway (1.2M) and 8x above the
;; largest healthy thinking block.
;;
;; Hook: :around advice on `gptel-curl--parse-stream'. The ollama
;; backend accumulates this round's reasoning into info :reasoning
;; during parse and the caller resets it to nil after dispatching
;; the callback -- so immediately after the original parse returns,
;; :reasoning holds THIS round's reasoning text. The return value is
;; this round's content string. :tool-use in info is set when tool
;; calls arrived. That is the complete per-round signal, no buffer
;; inspection needed.
;;
;; Abort action: `gptel-abort' on the request buffer (the same path
;; a human abort takes). The FSM transitions to ABRT; the cycle's
;; post-response handler sees a failed request (strike counted, the
;; dead-cycle guard ends the cycle). Same terminal state as the
;; current thinking-only truncation guard, but at ~4k tokens and
;; ~2 minutes instead of 32k+ tokens and ~10 minutes. The notice is
;; SUPPRESSED in unattended buffers (the Aevum c52 conveyor-belt
;; law -- nobody reads it in a cycle run, and it pollutes context).
;;
;; Never signals: every path is condition-case wrapped (the watchdog
;; law -- a guard that crashes takes the session with it).

(require 'cl-lib)
(require 'iar-utils)
(require 'iar-audit-log)

;; Forward declarations -- owned by configs/tool-limits.el.
(defvar iar-thinking-loop-guard-enabled nil
  "When non-nil, the thinking-loop guard aborts runaway reasoning
streams. Owned by configs/tool-limits.el.")
(defvar iar-thinking-loop-max-chars nil
  "Reasoning bytes allowed since the last real content before
aborting. Owned by configs/tool-limits.el.")
(defvar iar-thinking-loop-max-chars-per-model nil
  "Alist (MODEL-PREFIX . MAX-CHARS) overriding the uniform
threshold per model. Owned by configs/tool-limits.el.")

;; Cycle/one-shot state lives in iar-agent-cycle.el. Defvars keep
;; standalone loads + byte-compilation clean.
(defvar iar--cycle-state)
(defvar iar--one-shot-state)

(defvar iar--thinking-loop-processes
  (make-hash-table :test 'eq :weakness 'key)
  "Hash: live request process -> plist (:bytes N :fsm FSM).
Weakness `key: entries die with the process. BYTES is reasoning
accumulated since the last content/tool-call.")

;;; ---------------------------------------------------------
;;; Core check
;;; ---------------------------------------------------------

(defun iar--thinking-loop-register (process fsm)
  "Track PROCESS with its FSM. Idempotent per process."
  (unless (gethash process iar--thinking-loop-processes)
    (puthash process (list :bytes 0 :fsm fsm)
             iar--thinking-loop-processes)))

(defun iar--thinking-loop-observe (process info result)
  "Account one parse-stream round for PROCESS.
INFO is the FSM info plist, RESULT the parse-stream return value
(this round's content string, or a list/cons for multipart)."
  (let ((entry (gethash process iar--thinking-loop-processes)))
    (when entry
      (let* ((reasoning (plist-get info :reasoning))
             (reasoning-len (if (stringp reasoning) (length reasoning) 0))
             (tool-use (plist-get info :tool-use))
             (content-len (cond
                           ((stringp result) (length result))
                           ((listp result)
                            ;; cons/multipart: count string members
                            (cl-loop for x in result
                                     when (stringp x) sum (length x)))
                           (t 0))))
        (cond
         ;; Real content or tool calls: the turn produced something.
         ;; Reset the accumulator -- thinking that PRECEDES output is
         ;; healthy thinking.
         ((or (> content-len 0) tool-use)
          (setf (plist-get entry :bytes) 0))
         ;; Reasoning arrived with nothing else: accumulate.
         ((> reasoning-len 0)
          (cl-incf (plist-get entry :bytes) reasoning-len)))
        ;; Abort check (per-model threshold: first prefix match
        ;; wins, uniform fallback otherwise)
        ;; gptel-model is an intern'd SYMBOL in production (configs/
        ;; gptel.el interns the model name) -- the c88 root cause was
        ;; (stringp :model) failing on that symbol, silently skipping
        ;; the alist and running the uniform 16000 all night. Coerce
        ;; to string FIRST, then match (iar--reqlog-json-str's law:
        ;; symbols -> symbol-name; iar-request-log.el carries the
        ;; same comment).
        (let* ((model-name (plist-get info :model))
               (model-str (cond ((symbolp model-name) (symbol-name model-name))
                                ((stringp model-name) model-name)
                                (t nil)))
               (threshold
                (or (cl-loop for (prefix . chars)
                             in iar-thinking-loop-max-chars-per-model
                             when (and (stringp prefix)
                                       (stringp model-str)
                                       (string-prefix-p prefix model-str))
                             return chars)
                    iar-thinking-loop-max-chars
                    16000)))
          (when (and iar-thinking-loop-guard-enabled
                     (> (plist-get entry :bytes) threshold))
            (iar--thinking-loop-abort process entry info threshold)))))))

(defun iar--thinking-loop-abort (process entry info &optional threshold)
  "Abort the runaway request PROCESS (ENTRY holds the counters).
THRESHOLD is the resolved per-model limit, for honest reporting."
  ;; Zero the counter FIRST: the abort itself may re-enter the parse
  ;; path during teardown; a re-entrant abort must be a no-op.
  (setf (plist-get entry :bytes) 0)
  (let* ((fsm (plist-get entry :fsm))
         (buf (when fsm (plist-get (gptel-fsm-info fsm) :buffer)))
         ;; Same symbol->string coercion as the observe path: %s on a
         ;; symbol prints its name, so the witness line LOOKED right
         ;; while the resolution failed (c88's sharpest detail).
         (model-name (when info (plist-get info :model)))
         (model (cond ((symbolp model-name) (symbol-name model-name))
                      ((stringp model-name) model-name)
                      (t nil))))
    (condition-case err
        (progn
          (iar--audit-log
           "thinking-loop-guard"
           (format "aborted runaway reasoning stream: >%d chars with no content, model=%s"
                   (or threshold iar-thinking-loop-max-chars 16000)
                   (or model "nil")))
          (message "[thinking-loop-guard] Aborting runaway reasoning stream (%d chars, no content, model=%s)"
                   (or threshold iar-thinking-loop-max-chars 16000)
                   (or model "nil"))
          (when (and (bufferp buf) (buffer-live-p buf))
            ;; Notice suppressed in unattended runs (Aevum c52 law):
            ;; the abort is witnessed by the audit log + this message.
            (gptel-abort buf))
          (when (process-live-p process)
            (delete-process process)))
      (error
       (message "[thinking-loop-guard] Abort failed: %s"
                (error-message-string err))))))

;;; ---------------------------------------------------------
;;; Advice + setup
;;; ---------------------------------------------------------

(defun iar--thinking-loop-parse-advice (orig-fn backend info)
  ":around advice on `gptel-curl--parse-stream'.
Calls the original, then accounts the round. Never signals."
  (let ((result (condition-case err
                    (funcall orig-fn backend info)
                  (error
                   (message "[thinking-loop-guard] parse-stream error (demoted): %s"
                            (error-message-string err))
                   nil))))
    (condition-case guard-err
        (when (plistp info)
          ;; Find the live request whose FSM info is THIS info (eq
          ;; identity -- proc-info does not carry its own FSM ref).
          (let ((found (cl-some
                        (lambda (entry)
                          (let ((fsm (cadr entry)))
                            (when (and fsm (eq (gptel-fsm-info fsm) info))
                              (cons (car entry) fsm))))
                        gptel--request-alist)))
            (when found
              (iar--thinking-loop-register (car found) (cdr found))
              (iar--thinking-loop-observe (car found) info result))))
      (error
       (message "[thinking-loop-guard] check error (demoted): %s"
                (error-message-string guard-err))))
    result))

(defun iar--thinking-loop-cleanup-advice (process _status)
  ":before advice on `gptel-curl--stream-cleanup': drop the entry."
  (remhash process iar--thinking-loop-processes))

(defun iar--thinking-loop-setup ()
  "Install guard advice. Idempotent."
  (advice-remove 'gptel-curl--parse-stream #'iar--thinking-loop-parse-advice)
  (advice-add 'gptel-curl--parse-stream :around
              #'iar--thinking-loop-parse-advice)
  (advice-remove 'gptel-curl--stream-cleanup #'iar--thinking-loop-cleanup-advice)
  (advice-add 'gptel-curl--stream-cleanup :before
              #'iar--thinking-loop-cleanup-advice)
  ;; The installed line is the RUNTIME WITNESS for the per-model
  ;; config (c89): a5d21f0 shipped the alist but the installed line
  ;; never named it, so "deployed" had no witness distinct from
  ;; "armed". Print the full alist (prin1-to-string -- the alist is
  ;; data, not user content).
  (let ((witness
         (format "installed: enabled=%s max-chars=%s per-model=%s"
                 iar-thinking-loop-guard-enabled
                 (or iar-thinking-loop-max-chars 16000)
                 (if iar-thinking-loop-max-chars-per-model
                     (prin1-to-string
                      iar-thinking-loop-max-chars-per-model)
                   "none"))))
    (iar--audit-log "thinking-loop-guard" witness)
    (message "[thinking-loop-guard] %s" witness)))

(iar--thinking-loop-setup)

(provide 'iar-thinking-loop-guard)

;; Forward declaration: gptel--request-alist is owned by gptel
;; (gptel-request.el). Declared so the module loads and byte-compiles
;; clean without gptel present (advice binds lazily; the variable is
;; only read inside the parse advice, which runs only when gptel is
;; live).
(defvar gptel--request-alist nil
  "Alist of live gptel requests: (PROCESS . (FSM ABORT-FN)).
Owned by gptel-request.el; declared here for standalone loads.")
