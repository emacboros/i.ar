;; -*- lexical-binding: t; -*-

;;; Tool Call Layer -- The Single Integration Point with gptel
;;
;; This module is the ONLY place in i.ar that touches gptel's internal
;; FSM, curl internals, or tool processing. All other i.ar modules hook
;; into THIS layer, not gptel directly.
;;
;; What this layer owns:
;; - Tool registration (wraps gptel-make-tool + add-to-list)
;; - Pre/post-tool-call hooks (i.ar's own, not gptel's)
;; - Result truncation (intercepts before buffer insertion)
;; - Audit logging (every tool call logged with status + args detail)
;; - Token usage tracking (parses from Ollama responses via curl advice)
;;
;; What this layer does NOT own:
;; - Tool function implementation (tools define their own functions)
;; - Tool descriptions (stay in tool code, GUIDELINES.org rule 15)
;; - FSM state monitoring (debug modules are separate, hook here)
;;
;; Architecture:
;;   Tool files call iar-tool-register instead of add-to-list 'gptel-tools.
;;   Loop guard / tool guard add to iar-pre-tool-call-functions instead
;;   of gptel-pre-tool-call-functions.
;;   Truncation happens via :around advice on gptel--process-tool-call,
;;   installed here.
;;   Audit logging happens in the post-tool-call path, installed here.
;;   Token parsing happens via :before advice on gptel-curl--stream-cleanup
;;   and gptel-curl--sentinel, installed here.
;;
;; If gptel's internals change, only this file needs updating.

(require 'iar-utf8-scrub)
(require 'gptel)
(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'iar-utils)
(require 'iar-audit-log)

;; Forward-declared: owned by configs/paths.el.
(defvar iar-personalization-path nil
  "Absolute path to the personalization mount point.")
(defvar iar-audit-path nil
  "Relative path to the audit log directory.")

;; Forward-declared: owned by configs/tool-limits.el.
;; Declared here so truncation can reference it before configs load.
(defvar iar-tool-result-max-chars nil
  "Maximum characters of tool result output before truncation.
Owned by configs/tool-limits.el.")

;;; ---------------------------------------------------------
;;; i.ar Tool Registration
;;; ---------------------------------------------------------
;; Wraps gptel-make-tool + add-to-list so tools don't touch gptel-tools directly.

;; OWNED BY iar-malformed-args.el (Track A2): it defines
;; iar-tool-register / iar-tool-make with the malformed-args
;; wrapper. This file must NOT redefine them (a redefinition here
;; would silently strip the wrapper). Required here so a standalone
;; load of the tool-call layer still gets the functions.

(require 'iar-malformed-args)  ; iar-tool-register, iar-tool-make

;;; ---------------------------------------------------------
;;; i.ar Hook Variables
;;; ---------------------------------------------------------
;; i.ar's own hook variables. These are distinct from gptel's hooks.
;; gptel's hooks (gptel-pre-tool-call-functions, gptel-post-tool-call-functions,
;; gptel-post-response-functions) are used internally by this layer to
;; bridge into gptel. i.ar modules use these instead.

(defvar iar-pre-tool-call-functions nil
  "Hook run before a tool call is executed.
Each function receives the gptel info plist. A function can return
\(:block . message) to block the call, or nil to allow it.
This is bridged to gptel-pre-tool-call-functions by the tool call layer.")

(defvar iar-post-tool-call-functions nil
  "Hook run after a tool call completes.
Each function receives (tool-name tool-result).
This is bridged to gptel-post-tool-call-functions by the tool call layer.")

(defvar iar-post-response-functions nil
  "Hook run after a complete LLM response is processed.
Each function receives (status info) where status is a symbol.
This is bridged to gptel-post-response-functions by the tool call layer.")

;;; ---------------------------------------------------------
;;; Bridge: i.ar hooks -> gptel hooks
;;; ---------------------------------------------------------

(defun iar--bridge-pre-tool-call (info)
  "Bridge function: run `iar-pre-tool-call-functions' for INFO.
Returns (:block . message) if any hook function blocks, nil otherwise."
  (run-hook-with-args-until-success 'iar-pre-tool-call-functions info))

(defun iar--bridge-post-tool-call (tool-name tool-result &optional args)
  "Bridge function: run `iar-post-tool-call-functions' for TOOL-NAME
and TOOL-RESULT.  Also logs every tool call to the audit log.

ARGS (optional) is the tool call's argument plist, used for the
audit detail: for effectful tools the arguments ARE the fact being
audited (which file was written, what command ran). Captured by
`iar--truncate-tool-result-advice' from the tool-call struct while
the conversation buffer is current -- async tool sentinels lose
that context, so it must be taken here, not in the sentinel."
  ;; Capture the agent name NOW, in the conversation buffer's dynamic
  ;; context. By the time this runs we are inside gptel--handle-tool-use's
  ;; with-current-buffer on the conversation buffer, so buffer-locals
  ;; resolve. Async sentinels (execute_code_local's shell sentinel) run
  ;; later in a dead context -- that is why 4238+ audit lines said
  ;; "nil" for agent (2026-08-31 finding).
  (iar--audit-log-tool-call-with-agent
   tool-name args tool-result (iar--audit-log-agent-name))
  (run-hook-with-args 'iar-post-tool-call-functions tool-name tool-result))

(defun iar--bridge-post-response (status info)
  "Bridge function: run `iar-post-response-functions' for STATUS and INFO."
  (run-hook-with-args 'iar-post-response-functions status info))

;;; ---------------------------------------------------------
;;; Result Truncation
;;; ---------------------------------------------------------

(defun iar--truncate-tool-result (result)
  "Truncate RESULT if it exceeds `iar-tool-result-max-chars'.
Uses middle-truncation: preserves first N/2 and last N/2 chars,
replaces middle with a notice showing total size and how much was kept.
Returns RESULT unchanged if under limit or if truncation is disabled."
  (let ((max-chars iar-tool-result-max-chars))
    (cond
     ((null max-chars) result)
     ((not (stringp result)) result)
     ((<= (length result) max-chars) result)
     (t (let* ((total (length result))
               (keep (/ max-chars 2))
               (head (substring result 0 keep))
               (tail (substring result (- total keep)))
               (notice (format "\n[... truncated: %d total chars, kept first %d and last %d ...]\n"
                               total keep keep)))
          (concat head notice tail))))))

(defun iar--truncate-tool-result-advice (orig-fun fsm tool-spec tool-call result)
  "Around advice on `gptel--process-tool-call'.
Scrubs raw bytes from RESULT (utf-8), then truncates it before it
enters the conversation buffer. The scrub is the json-value-p
sentinel-crash fix (2026-09-02): raw binary bytes in a tool result
(restic lock blobs via ssh) became raw-eight-bit chars in the
conversation, and json-serialize rejected them on the NEXT request,
killing batch Emacs with exit 255. Scrub happens before truncation
so both paths see clean text.
Also runs post-tool-call audit logging after the original function."
  (let* ((tool-name (when tool-spec (gptel-tool-name tool-spec)))
         (args (when (plistp tool-call) (plist-get tool-call :args)))
         (truncated (iar--truncate-tool-result
                     (iar--utf8-scrub result)))
         (ret (funcall orig-fun fsm tool-spec tool-call truncated)))
    ;; Post-tool-call: audit log (with args detail) + i.ar hooks
    (iar--bridge-post-tool-call tool-name truncated args)
    ret))

;;; ---------------------------------------------------------
;;; Token Usage Tracking
;;; ---------------------------------------------------------
;; Accumulators for token usage. The parse function lives here
;; (moved from iar-request-logger.el when the debug modules were
;; replaced by iar-status-mode.el in Phase 3).
;;
;; Curl advice on gptel-curl--stream-cleanup and gptel-curl--sentinel
;; calls the parse function to extract token counts from Ollama
;; streaming responses before gptel parses them.

(defvar iar--usage-requests 0
  "Total number of LLM requests in the current session.")
(defvar iar--usage-input-tokens 0
  "Total input tokens in the current session.")
(defvar iar--usage-output-tokens 0
  "Total output tokens in the current session.")
(defvar iar--usage-last-input 0
  "Input tokens of the most recent request.")
(defvar iar--usage-last-output 0
  "Output tokens of the most recent request.")
(defvar iar--usage-start-time nil
  "Start time of the current usage window (set by `iar--usage-reset').")
(defvar iar--usage-model nil
  "Model name from the most recent response.")

(defun iar--usage-reset ()
  "Reset all usage counters (called at cycle start)."
  (setq iar--usage-requests 0
        iar--usage-input-tokens 0
        iar--usage-output-tokens 0
        iar--usage-last-input 0
        iar--usage-last-output 0
        iar--usage-start-time (current-time)
        iar--usage-model nil))

(defun iar--usage-totals ()
  "Return a plist with current usage totals."
  (list :requests iar--usage-requests
        :input-tokens iar--usage-input-tokens
        :output-tokens iar--usage-output-tokens
        :total-tokens (+ iar--usage-input-tokens iar--usage-output-tokens)
        :last-input iar--usage-last-input
        :last-output iar--usage-last-output
        :duration-secs (if iar--usage-start-time
                           (time-convert (time-subtract nil iar--usage-start-time)
                                          'integer)
                         0)
        :model (or iar--usage-model "nil")))

(defun iar--usage-write-log ()
  "Write usage summary to audit/<agent>/USAGE.log.
Best-effort: errors are demoted to messages (kill-emacs-hook must
never fail)."
  (condition-case err
      (let* ((agent (or (iar--get-agent-name) "unknown"))
             (project (or (iar--current-project-name) "nil"))
             (log-dir (expand-file-name
                       (format "%s/%s" project agent)
                       (expand-file-name iar-audit-path iar-personalization-path)))
             (log-path (expand-file-name "USAGE.log" log-dir)))
        (make-directory log-dir t)
        (let ((totals (iar--usage-totals)))
          (with-temp-buffer
            (insert (format "[%s] requests=%d input=%d output=%d total=%d model=%s\n"
                            (format-time-string "%Y-%m-%d %H:%M:%S")
                            (plist-get totals :requests)
                            (plist-get totals :input-tokens)
                            (plist-get totals :output-tokens)
                            (plist-get totals :total-tokens)
                            (plist-get totals :model)))
            (append-to-file (point-min) (point-max) log-path))))
    (error
     (message "Warning: usage log write failed: %s"
              (error-message-string err)))))

(defun iar--usage-parse-tokens (body)
  "Parse token counts from response BODY.
Ollama's final streaming chunk contains:
  \"done\":true,\"prompt_eval_count\":N,\"eval_count\":N
Extract these and accumulate into the global counters.
Also extracts the model name from the response.

The token match is anchored to the JSON field shape (quoted key,
colon, digits) and takes the LAST occurrence in BODY. Two poison
shapes killed the first version (c34: USAGE input=260928629061 vs
real 5330014, ~49k inflation): the model's own output can contain
the bare field name (thinking prose, tool-call arguments quoting
meter code), and the old loose regex `prompt_eval_count[^0-9]*...'
matched that echo and -- the [^0-9]* gap being permissive --
captured the next digit run, often a neighboring total_duration in
nanoseconds (~2e9 per request). Any occurrence inside a JSON
string value is quote-escaped in the SSE stream, so the quoted
anchor is structurally immune to echoes; the last-match rule
additionally survives curl-buffer residue from a previous response
(done:true chunk rides the END of the stream)."
  ;; Extract model name (appears in every chunk)
  (when (string-match "\"model\":\"\\([^\"]+\\)\"" body)
    (setq iar--usage-model (match-string 1 body)))
  ;; prompt_eval_count: quoted anchor + last match (see docstring).
  (let ((pos 0) val found)
    (while (string-match "\"prompt_eval_count\"[[:space:]]*:[[:space:]]*\\([0-9]+\\)" body pos)
      (setq val (string-to-number (match-string 1 body))
            found t
            pos (match-end 0)))
    (when found
      (setq iar--usage-last-input val)
      (setq iar--usage-input-tokens (+ iar--usage-input-tokens val))))
  ;; eval_count: same treatment (was quote-anchored but first-match).
  (let ((pos 0) val found)
    (while (string-match "\"eval_count\"[[:space:]]*:[[:space:]]*\\([0-9]+\\)" body pos)
      (setq val (string-to-number (match-string 1 body))
            found t
            pos (match-end 0)))
    (when found
      (setq iar--usage-last-output val)
      (setq iar--usage-output-tokens (+ iar--usage-output-tokens val)))))

;;; ---------------------------------------------------------
;;; Curl Advice: Token Parsing
;;; ---------------------------------------------------------
;; :before advice on gptel's curl cleanup functions to parse token
;; counts from the raw response before gptel processes it.

(defun iar--usage-parse-from-curl (process)
  "Parse token counts from PROCESS buffer before gptel cleans up.
Reads the raw response body, extracts token counts, and increments
the request counter. Best-effort: errors are demoted to messages."
  (condition-case err
      (let ((proc-buf (process-buffer process)))
        (when (buffer-live-p proc-buf)
          (with-current-buffer proc-buf
            (let* ((raw-content (buffer-substring-no-properties
                                 (point-min) (point-max)))
                   ;; Strip HTTP headers -- find the blank line separator
                   (header-end (string-match "\n\n" raw-content))
                   (body (if header-end
                             (substring raw-content (+ header-end 2))
                           raw-content)))
              (iar--usage-parse-tokens body)
              (cl-incf iar--usage-requests)))))
    (error
     (message "Warning: token parse from curl failed: %s"
              (error-message-string err)))))

(defun iar--usage-curl-stream-cleanup-advice (process _status)
  "Before advice on `gptel-curl--stream-cleanup' to parse tokens."
  (iar--usage-parse-from-curl process))

(defun iar--usage-curl-sentinel-advice (process _status)
  "Before advice on `gptel-curl--sentinel' to parse tokens."
  (iar--usage-parse-from-curl process))

;;; ---------------------------------------------------------
;;; Setup: Install bridges and advice
;;; ---------------------------------------------------------

(defun iar--tool-call-setup ()
  "Install all tool call layer bridges and advice.
Idempotent: removes existing advice before adding."
  ;; Bridge i.ar hooks into gptel's hooks
  (add-hook 'gptel-pre-tool-call-functions #'iar--bridge-pre-tool-call)
  (add-hook 'gptel-post-response-functions #'iar--bridge-post-response)
  ;; Install truncation + audit logging advice
  (advice-remove 'gptel--process-tool-call #'iar--truncate-tool-result-advice)
  (advice-add 'gptel--process-tool-call :around #'iar--truncate-tool-result-advice)
  ;; Install token parsing advice on curl functions
  (advice-remove 'gptel-curl--stream-cleanup #'iar--usage-curl-stream-cleanup-advice)
  (advice-add 'gptel-curl--stream-cleanup :before #'iar--usage-curl-stream-cleanup-advice)
  (advice-remove 'gptel-curl--sentinel #'iar--usage-curl-sentinel-advice)
  (advice-add 'gptel-curl--sentinel :before #'iar--usage-curl-sentinel-advice)
  ;; Write usage log on exit
  (add-hook 'kill-emacs-hook #'iar--usage-write-log)
  (message "[tool-call] Layer installed"))

(iar--tool-call-setup)

(provide 'iar-tool-call)