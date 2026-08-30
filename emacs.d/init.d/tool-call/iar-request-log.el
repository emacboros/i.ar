;; -*- lexical-binding: t; -*-

;;; Request Log -- the witness (Track A4)
;;
;; Problem: an agent's malformed emissions (bad tool-call shapes,
;; degenerate JSON, pre-dispatch failures) are invisible to the agent
;; itself. The 2026-08-30 live event: a malformed read_file call hung
;; gptel; the human saw it in the status line, the agent had no
;; record -- its session began after the failed emission died. This
;; module is the instrument that closes that asymmetry: every request
;; lifecycle event lands in a durable file the agent can read after
;; the fact.
;;
;; What gets logged (audit/<project>/<agent>/REQUESTS.log):
;;   REQ n START     -- model, message count, payload tail (the last
;;                      two messages: the agent's most recent emission
;;                      as it survives in conversation history)
;;   REQ n RESPONSE   -- HTTP status + raw response body tail, dumped
;;                      from the process buffer BEFORE gptel destroys
;;                      it (this is where emissions that crash the
;;                      parser live -- they never reach the buffer)
;;   REQ n PARSE      -- what gptel extracted: tool call specs with
;;                      arguments (malformed shapes visible), status,
;;                      error field
;;   REQ n FILTER-ERROR -- a signal inside the stream filter: the
;;                      error message plus the offending output chunk
;;                      (the exact bytes that broke the parse), then
;;                      re-signaled so behavior is unchanged
;;   REQ n ABORT      -- partial response dumped before gptel-abort
;;                      kills the process buffer (covers watchdog
;;                      aborts and human aborts -- both go through
;;                      gptel-abort)
;;
;; Mechanism (all advice, idempotent setup):
;;   - :after  gptel-curl-get-response      -> START (register REQ id
;;     for the process via gptel--request-alist fsm match)
;;   - :before gptel-curl--stream-cleanup   -> RESPONSE + PARSE
;;   - :before gptel-curl--sentinel         -> RESPONSE + PARSE
;;   - :around gptel-curl--stream-filter    -> FILTER-ERROR (witness
;;     the crashing chunk, then re-signal)
;;   - :before gptel-abort                  -> ABORT + partial dump
;;
;; Storage: single-line sanitized entries (log-injection safe, same
;; sanitization as the audit log), rotated to REQUESTS.log.1 at
;; `iar-request-log-max-size'. The log is NOT injected into LLM
;; context -- it is read deliberately via read_file for forensics.
;;
;; Non-goals: interactive Emacs debug tooling (edebug, *gptel-log*
;; buffers) -- that stays the human's. Auto-injection into context.
;;
;; Pure helpers (iar--reqlog-cap, iar--reqlog-payload-tail,
;; iar--reqlog-tool-specs) are unit tested; lifecycle advice is
;; best-effort (never signals, never blocks a request).

(require 'gptel)
(require 'cl-lib)
(require 'subr-x)
(require 'json)
(require 'iar-utils)
(require 'iar-audit-log)
(require 'iar-agent-utils)

;; Forward declarations -- owned by configs/tool-limits.el.
;; defvar is a no-op when the defcustom has already bound them
;; (configs load before init.d modules in init.el).
(defvar iar-request-log-enabled nil
  "When non-nil, log gptel request lifecycles to REQUESTS.log.
Owned by configs/tool-limits.el.")
(defvar iar-request-log-max-size nil
  "Maximum REQUESTS.log size in bytes before rotation.
Owned by configs/tool-limits.el. nil disables rotation.")
(defvar iar-request-log-tail-chars nil
  "Maximum characters of serialized payload tail per START entry.
Owned by configs/tool-limits.el. nil disables the cap.")
(defvar iar-request-log-body-chars nil
  "Maximum characters of raw response body tail per RESPONSE entry.
Owned by configs/tool-limits.el. nil disables the cap.")

(defvar iar--reqlog-counter 0
  "Request counter for this Emacs session. REQ ids in REQUESTS.log.")

(defvar iar--reqlog-processes (make-hash-table :test 'eq :weakness 'key)
  "Hash: request process -> REQ id. Weakness 'key: entries die with
the process, no cleanup needed (same pattern as the watchdog).")

;;; ---------------------------------------------------------
;;; Pure helpers (unit tested)
;;; ---------------------------------------------------------

(defun iar--reqlog-cap (s n)
  "Return S truncated to at most N chars with an omission marker.
Non-string S is returned unchanged (as-is). nil N disables the cap.
The marker ...[+K chars] reports how much was omitted, so the reader
knows the entry was capped without inflating the log."
  (if (or (null n) (not (stringp s)) (<= (length s) n))
      s
    (let ((keep (max 0 (- n 20))))
      (format "%s...[+%d chars]" (substring s 0 keep)
              (- (length s) keep)))))

(defun iar--reqlog-payload-tail (messages)
  "Serialize the last two MESSAGES as capped JSON.
MESSAGES is the :messages vector from request data. The last message
is usually the tool result / user turn; the second-to-last is the
agent's most recent emission (assistant turn with tool calls). Two
messages capture both. Returns \"nil\" when absent, and
\"unserializable\" when encoding fails -- never signals."
  (condition-case nil
      (if (or (not (vectorp messages)) (zerop (length messages)))
          "nil"
        (let* ((n (length messages))
               (start (max 0 (- n 2)))
               (tail (if (zerop start)
                         messages
                       (vconcat (cl-subseq messages start)))))
          (iar--reqlog-cap (gptel--json-encode tail)
                           iar-request-log-tail-chars)))
    (error "unserializable")))

(defun iar--reqlog-tool-specs (tool-use)
  "Format TOOL-USE specs for the log: name(args) per spec, capped.
TOOL-USE is the list of call-spec plists gptel extracted (after the
A2b sanitizer these always have string :name and plist-or-nil :args,
but this function tolerates any shape). Returns \"none\" when empty,
\"unserializable\" on unexpected structure. Never signals."
  (condition-case nil
      (if (null tool-use)
          "none"
        (let ((parts
               (mapcar
                (lambda (spec)
                  (let ((name (if (plistp spec)
                                  (or (plist-get spec :name) "?")
                                "?"))
                        (args (if (plistp spec)
                                  (plist-get spec :args)
                                nil)))
                    (format "%s(%s)" name
                            (iar--reqlog-cap (prin1-to-string args) 300))))
                tool-use)))
          (iar--reqlog-cap (mapconcat #'identity parts " ") 1000)))
    (error "unserializable")))

;;; ---------------------------------------------------------
;;; Log writing
;;; ---------------------------------------------------------

(defun iar--reqlog-path ()
  "Path to REQUESTS.log for the current agent.
Mirrors the USAGE.log / cycle.log location scheme.
Falls back to the request buffer's agent name: the curl process
buffers are not the conversation buffer, so `iar--get-agent-name'
resolves to the global default (set by agent-loader/cycle) -- but
in fresh batch contexts even that can be unset. The START advice
captures the name from the FSM's :buffer while it is live and
stores it in `iar--reqlog-agent'; later events (RESPONSE, PARSE,
FILTER-ERROR, ABORT) run after the conversation buffer may be
gone, so they use the captured name."
  (let* ((agent (or (and (boundp 'iar--reqlog-agent) iar--reqlog-agent)
                     (iar--get-agent-name)
                     "unknown"))
         (project (or (and (boundp 'iar--current-project)
                           (or (and (local-variable-p 'iar--current-project)
                                    iar--current-project)
                               (default-value 'iar--current-project)))
                      (getenv "IAR_PROJECT")
                      "iar")))
    (expand-file-name
     (format "%s/%s/REQUESTS.log" project agent)
     (expand-file-name iar-audit-path iar-personalization-path))))

(defvar iar--reqlog-agent nil
  "Agent name captured at request start (START advice).
Cleared per request; used by later lifecycle events when the
conversation buffer is dead and the global default is unset.")

(defun iar--reqlog-maybe-rotate ()
  "Rotate REQUESTS.log to .1 if it exceeds `iar-request-log-max-size'.
Best-effort: errors are demoted to messages, never signal (same
pattern as `iar--audit-maybe-rotate')."
  (when (and (integerp iar-request-log-max-size)
             (> iar-request-log-max-size 0))
    (let ((path (iar--reqlog-path)))
      (when (file-exists-p path)
        (let ((size (file-attribute-size (file-attributes path))))
          (when (and size (> size iar-request-log-max-size))
            (condition-case err
                (rename-file path (concat path ".1") t)
              (error
               (message "Warning: request log rotation failed: %s"
                        (error-message-string err))))))))))

(defun iar--reqlog-append (fmt &rest args)
  "Append one sanitized single-line entry to REQUESTS.log.
FMT and ARGS are passed to `format'. Newlines in the result are
escaped (log-injection safe, same sanitization as the audit log).
Best-effort: never signals."
  (condition-case err
      (let* ((path (iar--reqlog-path))
             (dir (file-name-directory path))
             (line (iar--audit-sanitize-detail
                    (concat (format-time-string "[%Y-%m-%d %H:%M:%S] ")
                            (apply #'format fmt args)))))
        (make-directory dir t)
        (iar--reqlog-maybe-rotate)
        (write-region (concat line "\n") nil path t 'silent))
    (error
     (message "Warning: request log write failed: %s"
              (error-message-string err)))))

;;; ---------------------------------------------------------
;;; Request lifecycle advice
;;; ---------------------------------------------------------

(defun iar--reqlog-start-advice (fsm)
  ":after advice on `gptel-curl-get-response': log request start.
Registers the new process (matched by FSM in `gptel--request-alist')
to a fresh REQ id so later events attribute to this request.
Captures the agent name from the conversation buffer while it is
live -- process buffers and later events cannot resolve it."
  (condition-case err
      (when iar-request-log-enabled
        (let* ((info (gptel-fsm-info fsm))
               (model (plist-get info :model))
               (backend (when (plist-get info :backend)
                          (gptel-backend-name (plist-get info :backend))))
               (data (plist-get info :data))
               (messages (and (plistp data) (plist-get data :messages)))
               (count (if (vectorp messages) (length messages) 0))
               (id (cl-incf iar--reqlog-counter))
               (conv-buf (plist-get info :buffer)))
          ;; Capture agent name while the conversation buffer is live
          (setq iar--reqlog-agent
                (or (and (bufferp conv-buf) (buffer-live-p conv-buf)
                         (buffer-local-value 'iar--current-agent-name conv-buf))
                    (and (boundp 'iar--current-agent-name)
                         (or (and (local-variable-p 'iar--current-agent-name)
                                  iar--current-agent-name)
                             (default-value 'iar--current-agent-name)))
                    "unknown"))
          (iar--reqlog-append "REQ %d START backend=%s model=%s msgs=%d tail=%s"
                              id (or backend "?") (or model "?") count
                              (iar--reqlog-payload-tail messages))
          (dolist (entry gptel--request-alist)
            (when (eq (cadr entry) fsm)
              (puthash (car entry) id iar--reqlog-processes)))))
    (error
     (message "[request-log] start advice failed: %s"
              (error-message-string err)))))

(defun iar--reqlog-dump (process)
  "Dump raw response tail + parse result for PROCESS. Best-effort.
Runs :before gptel's cleanup/sentinel destroy the process buffer --
this is the only place the raw response (including emissions that
crashed the parser and never reached the conversation buffer) is
still readable."
  (condition-case err
      (when iar-request-log-enabled
        (let* ((id (or (gethash process iar--reqlog-processes) 0))
               (buf (process-buffer process))
               (entry (alist-get process gptel--request-alist))
               (fsm (car entry))
               (info (when fsm (gptel-fsm-info fsm))))
          (when (buffer-live-p buf)
            (with-current-buffer buf
              (let* ((raw (buffer-substring-no-properties
                           (point-min) (point-max)))
                     (status (if (string-match "^HTTP[^ ]* \\([0-9]+\\)" raw)
                                 (match-string 1 raw)
                               "?"))
                     (body (if (string-match "\n\n" raw)
                               (substring raw (match-end 0))
                             raw)))
                (iar--reqlog-append "REQ %d RESPONSE http=%s body_tail=%s"
                                    id status
                                    (iar--reqlog-cap body
                                                     iar-request-log-body-chars)))))
          (when info
            (let ((tool-use (plist-get info :tool-use))
                  (errdata (plist-get info :error))
                  (status (plist-get info :status)))
              (iar--reqlog-append
               "REQ %d PARSE status=%s tools=%d specs=%s error=%s"
               id (or status "?")
               (if (listp tool-use) (length tool-use) 0)
               (iar--reqlog-tool-specs tool-use)
               (or errdata "nil"))))))
    (error
     (message "[request-log] dump failed: %s"
              (error-message-string err)))))

(defun iar--reqlog-dump-advice (process _status)
  ":before advice on cleanup/sentinel: dump before buffer destruction."
  (iar--reqlog-dump process))

(defun iar--reqlog-filter-advice (orig-fn process output)
  ":around advice on `gptel-curl--stream-filter': witness filter errors.
On success: pass through (no per-chunk logging -- too noisy).
On error: log the error and the offending OUTPUT chunk (the exact
bytes that broke the parse -- the witness), then re-signal so gptel
and Emacs see exactly the behavior they saw without this advice."
  (condition-case err
      (funcall orig-fn process output)
    (error
     (condition-case nil
         (when iar-request-log-enabled
           (let ((id (or (gethash process iar--reqlog-processes) 0)))
             (iar--reqlog-append "REQ %d FILTER-ERROR %s chunk=%s"
                                 id (error-message-string err)
                                 (iar--reqlog-cap output 1000))))
       (error nil))
     (signal (car err) (cdr err)))))

(defun iar--reqlog-abort-advice (buf)
  ":before advice on `gptel-abort': dump the partial response before
the abort-fn kills the process and its buffer. Covers watchdog
aborts (the watchdog calls gptel-abort) and human aborts."
  (condition-case err
      (when iar-request-log-enabled
        (let ((entry (cl-find-if
                      (lambda (e)
                        (eq (thread-first (cadr e)
                                          (gptel-fsm-info)
                                          (plist-get :buffer))
                            buf))
                      gptel--request-alist)))
          (when entry
            (let* ((process (car entry))
                   (id (or (gethash process iar--reqlog-processes) 0)))
              (when (process-live-p process)
                (iar--reqlog-append "REQ %d ABORT (partial response follows)"
                                    id)
                (iar--reqlog-dump process))))))
    (error
     (message "[request-log] abort advice failed: %s"
              (error-message-string err)))))

;;; ---------------------------------------------------------
;;; Setup
;;; ---------------------------------------------------------

(defun iar--reqlog-setup ()
  "Install request log advice. Idempotent."
  (advice-remove 'gptel-curl-get-response #'iar--reqlog-start-advice)
  (advice-add 'gptel-curl-get-response :after #'iar--reqlog-start-advice)
  (advice-remove 'gptel-curl--stream-cleanup #'iar--reqlog-dump-advice)
  (advice-add 'gptel-curl--stream-cleanup :before #'iar--reqlog-dump-advice)
  (advice-remove 'gptel-curl--sentinel #'iar--reqlog-dump-advice)
  (advice-add 'gptel-curl--sentinel :before #'iar--reqlog-dump-advice)
  (advice-remove 'gptel-curl--stream-filter #'iar--reqlog-filter-advice)
  (advice-add 'gptel-curl--stream-filter :around #'iar--reqlog-filter-advice)
  (advice-remove 'gptel-abort #'iar--reqlog-abort-advice)
  (advice-add 'gptel-abort :before #'iar--reqlog-abort-advice)
  (message "[request-log] Witness installed"))

(iar--reqlog-setup)

(provide 'iar-request-log)