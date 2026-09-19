;; -*- lexical-binding: t; -*-

;;; Audit Log for Agent File Operations and Command Execution
;; Appends timestamped entries to a central audit log for every
;; write_file and execute_code_local call.
;;
;; Log location: /root/personalization/audit/audit.log
;; Format: [YYYY-MM-DD HH:MM:SS] AGENT | TOOL | detail
;;
;; This is append-only. The audit log is not protected by iar-file-guard
;; (it lives in workspace/ which is the designated writable area).

(require 'subr-x)
(require 'iar-utils)

;; iar--audit-log-path is now defined in shared/utils.el.
;; iar--get-agent-name is now defined in shared/utils.el.

;; Parameter iar-audit-log-max-size is defined in
;; configs/ (split parameter files) (loaded early in init.el).

(defun iar--audit-sanitize-detail (detail)
  "Sanitize DETAIL for single-line audit log entry.
Replaces newlines and carriage returns with their visible escaped
representation to prevent log injection -- without this, a filepath
or command containing newlines could inject fake audit log entries."
  (let ((s (if (stringp detail) detail (prin1-to-string detail))))
    (setq s (replace-regexp-in-string "\n" "\\\\n" s))
    (setq s (replace-regexp-in-string "\r" "\\\\r" s))
    (setq s (iar--audit-redact-secrets s))
    s))

(defun iar--audit-maybe-rotate ()
  "Rotate the audit log if it exceeds `iar-audit-log-max-size'.
Renames the current log to `audit.log.1' (overwriting any previous
rotation) and starts a fresh log.  Rotation is best-effort: errors
are logged via `message' but do not signal, to avoid breaking the
operation being audited."
  (let ((max-size iar-audit-log-max-size))
    ;; Guard against non-integer max-size: the :safe predicate rejects
    ;; non-positive/non-integer values at the file-local-variable level,
    ;; but a direct setq to a string or other non-integer bypasses it.
    ;; A string would crash > with wrong-type-argument.  nil disables
    ;; rotation (intentional).  Skip rotation when max-size is not a
    ;; positive integer.  Matches the defense-in-depth pattern from
    ;; cycles 112-115 (iar-memory-tools, fs_tools, iar-loop-guard defcustom guards).
    (when (and (integerp max-size) (> max-size 0)
               (file-exists-p iar--audit-log-path))
      (let ((size (file-attribute-size (file-attributes iar--audit-log-path))))
        (when (and size (> size max-size))
          (condition-case err
              (let ((rotated (concat iar--audit-log-path ".1")))
                ;; rename-file with t overwrites any existing .1 file.
                (rename-file iar--audit-log-path rotated t))
            (error
             (message "Warning: audit log rotation failed: %s"
                      (error-message-string err)))))))))

(defun iar--audit-log (tool detail)
  "Append an audit entry for TOOL with DETAIL to the audit log.
Does not signal errors -- audit logging is best-effort and must
never break the operation it is auditing.
DETAIL is sanitized to prevent log injection via embedded newlines.
TOOL is expected to be a hardcoded string literal (e.g. \"write_file\")
and AGENT comes from `iar--get-agent-name' (shared/utils.el) which
returns `iar--current-agent-name' -- neither is user-controlled, so
neither is sanitized.  If this invariant changes, sanitize them too.

Before writing, checks if the log exceeds `iar-audit-log-max-size'
and rotates it if so.  This prevents unbounded growth of the audit log."
  (condition-case err
      (let ((timestamp (format-time-string "%Y-%m-%d %H:%M:%S"))
            (agent (or (iar--get-agent-name) "unknown"))
            (safe-detail (iar--audit-sanitize-detail detail)))
        ;; Rotate the log if it has grown too large.
        (iar--audit-maybe-rotate)
        ;; Ensure the audit directory exists (defense in depth --
        ;; also created at load time by iar--audit-log-setup).
        (let ((log-dir (file-name-directory iar--audit-log-path)))
          (unless (file-exists-p log-dir)
            (make-directory log-dir t)))
        ;; Bind coding-system-for-write: same defense as the request
        ;; log -- select-safe-coding-system prompts read stdin (EOF in
        ;; batch), silently losing the entry (2026-08-30).
        (let ((coding-system-for-write 'utf-8-unix))
          (write-region (format "[%s] %s | %s | %s\n" timestamp agent tool safe-detail)
                        nil iar--audit-log-path t 'silent)))
        ;; write-region accepts a string directly -- no temp buffer needed.
    (error
     (message "Warning: audit log write failed: %s"
              (error-message-string err)))))

(defun iar--audit-log-write (filepath)
  "Audit log entry for write_file to FILEPATH."
  (iar--audit-log "write_file" filepath))


(defun iar--audit-log-append (filepath)
  "Audit log entry for append_file to FILEPATH."
  (iar--audit-log "append_file" filepath))

(defun iar--audit-log-exec (command exit-code)
  "Audit log entry for execute_code_local with COMMAND and EXIT-CODE.
EXIT-CODE is 0 for success, the process exit code for non-zero exits,
or -1 if the command was killed due to timeout."
  (let ((truncated-cmd
         (if (> (length command) 200)
             (concat (substring command 0 197) "...")
           command)))
    (iar--audit-log "execute_code_local"
                         (format "exit=%d cmd=%s" exit-code truncated-cmd))))

(defun iar--audit-log-agent-name ()
  "Best-effort agent-name capture for the tool-call bridge.
Returns the agent name visible in the CURRENT buffer's dynamic
context (the bridge runs inside `with-current-buffer' on the
conversation buffer in gptel--handle-tool-use), or \"unknown\".
Never signals."
  (condition-case nil
      (or (iar--get-agent-name) "unknown")
    (error "unknown")))

(defun iar--audit-classify-result (tool-name result)
  "Classify a tool RESULT for the audit status field.
Returns one of:
  \"rejected\" -- the call never executed: tool-spec was nil
  (unknown/blocked/malformed tool name) and the result is the
  fence's <tool_call_error> injection. The fence firing is not the
  call succeeding; logging these as success trained the census to
  score failures as successes in exactly the row that carries the
  malformed-emission signal (relay aria-0007).
  \"error\" -- the result reports failure: an \"Error:\" prefix
  (tool-level errors), a \"Command exited with code N\" prefix
  (non-zero shell exit -- previously invisible: 9713 exec calls,
  zero logged as error), or a \"[TIMEOUT after Ns\" prefix
  (execute_code_local timeout kill).
  \"success\" -- everything else.
TOOL-NAME is nil exactly when the tool-spec lookup failed (blocked
or malformed call), so it is the primary rejected signal; the
result-prefix check is the corroborating witness."
  (cond
   ((and (null tool-name)
         (stringp result)
         (string-prefix-p "<tool_call_error>" result))
    "rejected")
   ((null tool-name) "rejected")
   ((not (stringp result)) "success")
   ((string-prefix-p "Error:" result) "error")
   ((string-prefix-p "Command exited with code" result) "error")
   ((string-prefix-p "[TIMEOUT after" result) "error")
   (t "success")))

(defun iar--audit-log-tool-call-with-agent (tool-name args result agent)
  "Write the audit entry for a tool call with AGENT pre-captured.
Detail policy per tool (write/append -> path, exec -> cmd capped 200,
git_commit -> repo+msg capped 80, reads -> name/status/len only).
Takes the agent name as an argument instead of resolving it (which
fails in async sentinel contexts)."
  (let* ((status (iar--audit-classify-result tool-name result))
         (detail
          (concat (format "name=%s status=%s result_len=%d"
                          (or tool-name "nil") status
                          (length (or result "")))
                  (pcase tool-name
                    ((or "write_file" "append_file")
                     (when-let* ((fp (plist-get args :filepath)))
                       (format " path=%s" fp)))
                    ((or "execute_code_local" "execute_code_remote")
                     (when-let* ((cmd (plist-get args :command)))
                       (format " cmd=%s"
                               (if (> (length cmd) 200)
                                   (concat (substring cmd 0 197) "...")
                                 cmd))))
                    ((or "read_file")
                     (when-let* ((fp (plist-get args :filepath)))
                       (format " path=%s" fp)))
                    ((or "list_directory" "read_knowledge")
                     (when-let* ((p (plist-get args :path)))
                       (format " path=%s" p)))
                    ("delegate"
                     (format " agent=%s task=%s"
                             (or (plist-get args :agent) "pipeline")
                             (let ((tk (or (plist-get args :task) "")))
                               (if (> (length tk) 80)
                                   (concat (substring tk 0 77) "...")
                                 tk))))
                    ("git_commit"
                     (format " repo=%s msg=%s"
                             (or (plist-get args :repo_path) "?")
                             (let ((m (or (plist-get args :message) "")))
                               (if (> (length m) 80)
                                   (concat (substring m 0 77) "...")
                                 m))))
                    (_ "")))))
    (iar--audit-log-as agent "tool_call" detail)))

(defun iar--audit-log-as (agent tool detail)
  "Append an audit entry as AGENT for TOOL with DETAIL.
Like `iar--audit-log' but the agent name is supplied by the caller
(pre-captured in the conversation buffer's dynamic context by the
tool-call bridge). Falls back to `iar--audit-log' resolution if
AGENT is nil. Never signals."
  (if agent
      (condition-case err
          (let ((timestamp (format-time-string "%Y-%m-%d %H:%M:%S"))
                (safe-detail (iar--audit-sanitize-detail detail)))
            (iar--audit-maybe-rotate)
            (let ((log-dir (file-name-directory iar--audit-log-path)))
              (unless (file-exists-p log-dir)
                (make-directory log-dir t)))
            (let ((coding-system-for-write 'utf-8-unix))
              (write-region (format "[%s] %s | %s | %s\n"
                                    timestamp agent tool safe-detail)
                            nil iar--audit-log-path t 'silent)))
        (error
         (message "Warning: audit log write failed: %s"
                  (error-message-string err))))
    (iar--audit-log tool detail)))

(defun iar--audit-log-setup ()
  "Create the audit log directory at load time.
Wrapped in condition-case so a missing or read-only personalization
mount does not crash init.el. The audit log write function also
handles errors gracefully."
  (condition-case err
      (let ((log-dir (file-name-directory iar--audit-log-path)))
        (unless (file-exists-p log-dir)
          (make-directory log-dir t)))
    (error
     (message "Warning: audit log setup failed: %s"
              (error-message-string err)))))

(iar--audit-log-setup)
(provide 'iar-audit-log)

(defun iar--audit-redact-secrets (s)
  "Redact secret-shaped strings from S before it lands in a log.
Classic GitHub PATs (ghp_ + 36 chars), fine-grained PATs
(github_pat_ + 40+ chars), and AWS access keys are never
legitimate audit-log content: they appear when a human pastes a
credential into a session and the request-log captures it
(2026-09-17: live all-scope PAT entered the git history via
REQUESTS.log, relay 0081). Redaction here is the structural
backstop -- the log keeps the evidence a secret EXISTED without
keeping the secret."
  (when (stringp s)
    (setq s (replace-regexp-in-string
             "ghp_[A-Za-z0-9]\\{36\\}" "ghp_[REDACTED]" s))
    (setq s (replace-regexp-in-string
             "github_pat_[A-Za-z0-9_]\\{40,\\}" "github_pat_[REDACTED]" s))
    (setq s (replace-regexp-in-string
             "AKIA[0-9A-Z]\\{16\\}" "AKIA[REDACTED]" s)))
  s)
