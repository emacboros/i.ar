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
;;   Full capture (iar-request-log-full-capture, off by default):
;;   when enabled, the COMPLETE request payload (all messages) is
;;   written to REQUESTS-full/REQ-<id>.json at START time -- the
;;   payload the model saw, durable even if the request hangs and
;;   the watchdog kills it. Closes the instrument gap where the
;;   START tail (6 msgs / 4k chars) cannot answer "what exactly
;;   did the model see". Pruned to iar-request-log-full-max-files.
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
(defvar iar-request-log-full-capture nil
  "When non-nil, dump the FULL request payload (all messages) to
REQUESTS-full/ next to REQUESTS.log at START time -- one JSON file
per request (REQ-<id>.json). Owned by configs/tool-limits.el.
Diagnostic flag, OFF by default: each dump carries the entire
conversation (large), so enable it while hunting a specific
anomaly, not always-on. The dump is written pre-response, so it
exists even when the request hangs and the watchdog kills it.")
(defvar iar-request-log-full-max-files 200
  "Maximum number of full-injection dumps retained per agent.
Oldest REQ-*.json files are pruned after each write.
Owned by configs/tool-limits.el. nil disables pruning.")

(defvar iar--reqlog-counter 0
  "Request counter for this Emacs session. REQ ids in REQUESTS.log.")

(defvar iar--reqlog-epoch
  (format-time-string "%y%m%d%H%M%S")
  "Boot-epoch prefix for REQ ids (set once at load).
Each cycle is a fresh Emacs session appending to a SHARED
REQUESTS.log, so bare counters collide across cycles (REQ 1 from
this morning and REQ 1 from tonight are different requests). The
epoch makes ids unique across the whole log: REQ 260903221200-1.
Census law: segment per-cycle by the epoch, not by msgs markers.")

(defvar iar--reqlog-processes (make-hash-table :test 'eq :weakness 'key)
  "Hash: request process -> REQ id. Weakness \='key: entries die with
the process, no cleanup needed (same pattern as the watchdog).")

(defvar iar--reqlog-process-agents (make-hash-table :test 'eq :weakness 'key)
  "Hash: request process -> agent name captured at START.
Fix 3 (c311, attribution race): `iar--reqlog-agent' is a process-
GLOBAL -- under concurrent sub-agents (delegation) every START
overwrites it, so RESPONSE/PARSE events landed in whichever agent's
log was written most recently (verified live 2026-09-14: continuo's
-172 RESPONSE sat in agent-assistant's log). Per-fsm attribution:
the START advice stores the agent name HERE, keyed by process, and
the lifecycle advices resolve it per-process instead of reading the
global. Weakness \='key: entries die with the process.")

(defvar iar--reqlog-agent-override nil
  "Dynamic per-request agent-name override (fix 3, c311).
The lifecycle advices (RESPONSE/PARSE/FILTER-ERROR/ABORT) bind this
around their `iar--reqlog-append' calls from the per-process hash;
`iar--reqlog-log-dir' prefers it over the stale global. nil = old
behavior (global fallback).")

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

(defvar iar-request-log-tail-msgs 6
  "How many trailing messages the START payload tail serializes.
Was 2 (one tool result + one assistant emission -- enough for the
malformed-call forensics the log was built for). Raised to 6 (c66
tail-cap flag, approved by Nacho 2026-09-08): the +N msgs anomaly
needs the CONTENT of the extra messages, and roles=6 alone shows
only their shape. 6 msgs x ~1k chars each stays inside the
4k-char cap in the common case; the cap still bounds the worst
case.")

(defun iar--reqlog-payload-tail (messages)
  "Serialize the last `iar-request-log-tail-msgs' MESSAGES as capped JSON.
MESSAGES is the :messages vector from request data. Was 2 messages
(one tool result + one assistant emission); 6 since the c66 +N msgs
anomaly -- the START tail must be able to show WHAT the extra
messages are, not just that they exist (the instrument-limit class:
a tail cap that hides the very messages the anomaly consists of).
Returns \"nil\" when absent, and \"unserializable\" when encoding
fails -- never signals."
  (condition-case nil
      (if (or (not (vectorp messages)) (zerop (length messages)))
          "nil"
        (let* ((n (length messages))
               (keep (or (and (boundp 'iar-request-log-tail-msgs)
                              iar-request-log-tail-msgs)
                         6))
               (start (max 0 (- n keep)))
               (tail (if (zerop start)
                         messages
                       (vconcat (cl-subseq messages start)))))
          (iar--reqlog-cap (gptel--json-encode tail)
                           iar-request-log-tail-chars)))
    (error "unserializable")))


(defun iar--reqlog-roles (messages n)
  "Return the :role of the last N MESSAGES as a comma-joined string.
MESSAGES is the :messages vector from request data. Roles are the
gptel message roles (user/assistant/tool). This is the cheap,
permanent instrument for the +N msgs anomaly: the START line records
the last-N role sequence so a census can see whether extra messages
are front-sticky (property-bleed) or tool-region duplication without
re-reading the full payload. Returns \"nil\" when absent, a
question-mark for a message with no :role. Never signals."
  (condition-case nil
      (if (or (not (vectorp messages)) (zerop (length messages)))
          "nil"
        (let* ((len (length messages))
               (start (max 0 (- len n)))
               (roles (cl-loop for i from start below len
                               for m = (aref messages i)
                               collect (if (plistp m)
                                           (or (plist-get m :role) "?")
                                         "?"))))
          (mapconcat #'identity roles ",")))
    (error "nil")))

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

(defun iar--reqlog-log-dir ()
  "Directory holding this agent's REQUESTS.log (and REQUESTS-full/).
Mirrors the USAGE.log / cycle.log location scheme.
Falls back to the request buffer's agent name: the curl process
buffers are not the conversation buffer, so `iar--get-agent-name'
resolves to the global default (set by agent-loader/cycle) -- but
in fresh batch contexts even that can be unset. The START advice
captures the name from the FSM's :buffer while it is live and
stores it in `iar--reqlog-agent'; later events (RESPONSE, PARSE,
FILTER-ERROR, ABORT) run after the conversation buffer may be
gone, so they use the captured name."
  (let* ((agent (or (and (boundp 'iar--reqlog-agent-override)
                         iar--reqlog-agent-override)
                     (and (boundp 'iar--reqlog-agent) iar--reqlog-agent)
                     (iar--get-agent-name)
                     "unknown"))
         (project (or (and (boundp 'iar--current-project)
                           (or (and (local-variable-p 'iar--current-project)
                                    iar--current-project)
                               (default-value 'iar--current-project)))
                      (getenv "IAR_PROJECT")
                      "iar")))
    (expand-file-name (format "%s/%s" project agent)
                      (expand-file-name iar-audit-path iar-personalization-path))))

(defun iar--reqlog-path ()
  "Path to REQUESTS.log for the current agent."
  (expand-file-name "REQUESTS.log" (iar--reqlog-log-dir)))

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
Best-effort: never signals.
coding-system-for-write is bound to utf-8-unix: the coding-system
confirmation prompt (select-safe-coding-system) reads stdin, which
is EOF in batch mode -- the entry would be lost silently."
  (condition-case err
      (let* ((path (iar--reqlog-path))
             (dir (file-name-directory path))
             (line (iar--audit-sanitize-detail
                    (concat (format-time-string "[%Y-%m-%d %H:%M:%S] ")
                            (apply #'format fmt args)))))
        (make-directory dir t)
        (iar--reqlog-maybe-rotate)
        ;; Bind coding-system-for-write so select-safe-coding-system
        ;; never runs. In batch cycles, write-region from
        ;; process-filter context occasionally triggered the
        ;; coding-system confirmation prompt; batch stdin is EOF, so
        ;; the prompt signal died, the condition-case caught it, and
        ;; the entry was silently lost (7/100 STARTs in cycle 2,
        ;; 2026-08-30 -- found by cycle-Aria reading its own log).
        (let ((coding-system-for-write 'utf-8-unix))
          (write-region (concat line "\n") nil path t 'silent)))
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
               (id (format "%s-%d" iar--reqlog-epoch
                           (cl-incf iar--reqlog-counter)))
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
          (iar--reqlog-append "REQ %s START backend=%s model=%s msgs=%d roles=%s tail=%s"
                              id (or backend "?") (or model "?") count
                              (iar--reqlog-roles messages 6)
                              (iar--reqlog-payload-tail messages))
          (when iar-request-log-full-capture
            (iar--reqlog-full-dump id info messages))
          (dolist (entry gptel--request-alist)
            (when (eq (cadr entry) fsm)
              (puthash (car entry) id iar--reqlog-processes)
              ;; Fix 3 (c311): attribute this process to the agent
              ;; captured above -- later events resolve per-process.
              (puthash (car entry) iar--reqlog-agent
                       iar--reqlog-process-agents)))))
    (error
     (message "[request-log] start advice failed: %s"
              (error-message-string err)))))

(defvar iar--reqlog-last-stop nil
  "Stop-reason of the most recently dumped request (string).
Set by `iar--reqlog-dump' from the fork's :stop-reason. The cycle's
post-response handler reads this to detect a truncated generation
(stop=length) without re-parsing the log. Reset to nil at cycle start
by `iar--reqlog-reset-last'.")

(defvar iar--reqlog-last-tokens-out nil
  "Output token count of the most recently dumped request (integer).
Set by `iar--reqlog-dump' from the fork's :tokens :output. Paired with
`iar--reqlog-last-stop' for the per-request truncated-output guard.")

(defvar iar--reqlog-last-tokens-in nil
  "Input token count of the most recently dumped request (integer).
Set by `iar--reqlog-dump' from the fork's :tokens :input. Read by
the context-size fence (iar-context-fence.el) as the best pre-call
estimate of the NEXT request's size (each request re-sends the
accumulated context). Reset to nil at cycle start by
`iar--reqlog-reset-last'.")

(defvar iar--reqlog-last-tool-specs nil
  "Tool-use call specs of the most recently dumped request (list).
Set by `iar--reqlog-dump' from the fork's :tool-use -- the same plist
list the PARSE line serializes, kept raw so readers can discriminate
on names AND args (the terminal-echo close detector reads the LAST
spec's :name and :args; the log line's 300-char arg cap would mangle
long args). Reset to nil at cycle start by `iar--reqlog-reset-last'.
nil means the last request carried no tool calls (or no data).")

(defvar iar--reqlog-last-msgs nil
  "Message count of the most recently dumped request (integer).
Set by `iar--reqlog-dump' from `iar--reqlog-msgs-count' (NA -> nil:
the fence must never fire on absence of data). Read by the msgs
fence (iar-msgs-fence.el) as the pre-call estimate of the NEXT
request's message count. Reset to nil at cycle start by
`iar--reqlog-reset-last'.")

(defvar iar--reqlog-last-abort nil
  "Non-nil when the most recent request was ABORTED via gptel-abort
(c80). Set by `iar--reqlog-abort-advice' (which runs BEFORE the
post-response hooks that gptel--handle-abort fires); consumed and
cleared by the cycle handler's abort-aware branch. Direct witness:
the abort advice KNOWS the abort happened -- no inference from
absent stop/token data (which is also the shape of a reqlog-disabled
session and would hijack every turn).")

(defun iar--reqlog-reset-last ()
  "Reset the last-request stop/tokens-out shared state to nil.
Called at cycle start so a stale value from a previous cycle (or a
delegate's request) is never read as this cycle's first response."
  (setq iar--reqlog-last-stop nil
        iar--reqlog-last-tokens-out nil
        iar--reqlog-last-tokens-in nil
        iar--reqlog-last-tool-specs nil
        iar--reqlog-last-msgs nil
        iar--reqlog-last-abort nil))

(defun iar--reqlog-msgs-count (info)
  "Return the message count of the request described by FSM INFO.
Relay 0035 option A: PARSE lines carry msgs=N as a first-class field
so a context-budget rule is checkable with one grep of the PARSE
line -- no START-line polling, no self-echo trap (the model's spec
echo cannot match a digits-required pattern). NA when unavailable.
Never signals."
  (condition-case nil
      (let ((msgs (and (plistp info)
                       (plistp (plist-get info :data))
                       (plist-get (plist-get info :data) :messages))))
        (if (vectorp msgs) (length msgs) "NA"))
    (error "NA")))

(defun iar--reqlog-json-str (v)
  "Return V as a JSON-safe scalar string. Symbols -> symbol-name
(gptel-model is interned; json-serialize rejects symbol values --
the c211 full-dump failure, wrong-type-argument json-value-p).
Strings pass through; anything else -> prin1-to-string."
  (cond ((symbolp v) (symbol-name v))
        ((stringp v) v)
        (t (prin1-to-string v))))

(defun iar--reqlog-full-dir ()
  "Directory for full-injection dumps: REQUESTS-full/ next to REQUESTS.log."
  (expand-file-name "REQUESTS-full" (iar--reqlog-log-dir)))

(defun iar--reqlog-full-prune (dir max-files)
  "Keep only the newest MAX-FILES REQ-*.json files in DIR.
Best-effort: never signals. nil/non-positive MAX-FILES disables."
  (when (and (integerp max-files) (> max-files 0)
             (file-directory-p dir))
    (condition-case nil
        (let* ((files (directory-files dir t "\\`REQ-.*\\.json\\'"))
               (sorted (sort files #'file-newer-than-file-p))
               (excess (nthcdr max-files sorted)))
          (dolist (f excess)
            (ignore-errors (delete-file f))))
      (error nil))))

(defun iar--reqlog-full-dump (id info messages)
  "Write the full request payload for REQ ID to REQUESTS-full/.
INFO is the fsm info (model/backend); MESSAGES the full :messages
vector -- the payload the model SAW, captured pre-response so it
survives watchdog kills. Best-effort: never signals. Prunes old
dumps to `iar-request-log-full-max-files'."
  (condition-case err
      (let* ((dir (iar--reqlog-full-dir))
             (path (expand-file-name (format "REQ-%s.json" id) dir))
             (payload (list
                       :id id
                       :time (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t)
                       ;; gptel-model is a SYMBOL (intern'd model name);
                       ;; json-serialize rejects symbols as values
                       ;; (wrong-type-argument json-value-p). Stringify.
                       :model (iar--reqlog-json-str (plist-get info :model))
                       :backend (and (plist-get info :backend)
                                     (gptel-backend-name
                                      (plist-get info :backend)))
                       :msgs (and (vectorp messages) (length messages))
                       :messages messages)))
        (make-directory dir t)
        (let ((coding-system-for-write 'utf-8-unix))
          (write-region (gptel--json-encode payload) nil path nil 'silent))
        (iar--reqlog-full-prune dir iar-request-log-full-max-files))
    (error
     (message "[request-log] full dump failed: %s"
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
               ;; Fix 3 (c311): resolve THIS request's agent per-process
               ;; instead of trusting the process-global (attribution
               ;; race under concurrent sub-agents).
               (agent (gethash process iar--reqlog-process-agents))
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
                     (body (if (string-match "\r?\n\r?\n" raw)
                               (substring raw (match-end 0))
                             raw)))
                (let ((iar--reqlog-agent-override agent))
                  (iar--reqlog-append "REQ %s RESPONSE http=%s body_tail=%s"
                                      id status
                                      (iar--reqlog-cap body
                                                       iar-request-log-body-chars))))))
          (when info
            (let* ((tool-use (plist-get info :tool-use))
                   (errdata (plist-get info :error))
                   (status (plist-get info :status))
                   ;; Terminal done_reason (stop/length/load/error).
                   ;; Captured by the fork's streaming parser since
                   ;; 970da80; length = truncated generation (num_predict
                   ;; hit or watchdog kill). Without this, a truncated
                   ;; response is indistinguishable from a complete one
                   ;; -- the Aevum lesson (run 1, ticks 37+).
                   (stop (plist-get info :stop-reason))
                   ;; Token counts from the fork's Ollama parser
                   ;; (:tokens = last request's counts, set on the
                   ;; done:true chunk). Logged here because the
                   ;; RESPONSE body_tail is capped at ~4k chars and
                   ;; the done:true chunk rides the END of the
                   ;; stream: large-output requests lose their token
                   ;; counts in RESPONSE (the c33 instrument-bias finding).
                   ;; The PARSE line sees `info' after the full stream
                   ;; was parsed, so the counts are complete here
                   ;; regardless of output size.
                   (tokens (plist-get info :tokens))
                   (tok-in (and (plistp tokens) (plist-get tokens :input)))
                   (tok-out (and (plistp tokens) (plist-get tokens :output))))
              ;; Publish the last-request stop/tokens-out to the shared
              ;; state the cycle's post-response guard reads. This runs
              ;; :before gptel-curl--stream-cleanup, i.e. BEFORE the
              ;; post-response handler -- so the guard sees the request
              ;; that just completed, not a stale one.
              (let ((msgs (iar--reqlog-msgs-count info)))
                (setq iar--reqlog-last-stop stop
                      iar--reqlog-last-tokens-out tok-out
                      iar--reqlog-last-tokens-in tok-in
                      iar--reqlog-last-tool-specs (and (listp tool-use) tool-use)
                      ;; Publish the message count for the msgs fence.
                      ;; NA (unavailable) -> nil: the fence never fires
                      ;; on absence of data (same contract as tokens).
                      iar--reqlog-last-msgs (and (integerp msgs) msgs)))
              (let ((iar--reqlog-agent-override agent))
                (iar--reqlog-append
                 "REQ %s PARSE status=%s tools=%d specs=%s error=%s stop=%s tokens_in=%s tokens_out=%s msgs=%s"
                 id (or status "?")
                 (if (listp tool-use) (length tool-use) 0)
                 (iar--reqlog-tool-specs tool-use)
                 (or errdata "nil")
                 (or stop "nil")
                 (or tok-in "NA")
                 (or tok-out "NA")
                 (iar--reqlog-msgs-count info)))))))
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
           (let ((id (or (gethash process iar--reqlog-processes) 0))
                 (agent (gethash process iar--reqlog-process-agents)))
             (let ((iar--reqlog-agent-override agent))
               (iar--reqlog-append "REQ %s FILTER-ERROR %s chunk=%s"
                                   id (error-message-string err)
                                   (iar--reqlog-cap output 1000)))))
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
                   (id (or (gethash process iar--reqlog-processes) 0))
                   (agent (gethash process iar--reqlog-process-agents)))
            (setq iar--reqlog-last-abort t)
              (when (process-live-p process)
                (let ((iar--reqlog-agent-override agent))
                  (iar--reqlog-append "REQ %s ABORT (partial response follows)"
                                      id))
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

