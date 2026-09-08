;; -*- lexical-binding: t; -*-

;;; execute_code_local tool for gptel
;; Async shell command execution in the container.
;;
;; This is an ASYNC tool: the function receives a callback as its first
;; argument (per gptel's :async convention) and calls it with the result
;; when the process completes. This keeps Emacs fully responsive during
;; long-running commands (network requests, compilation, etc.) because
;; gptel's state machine is not blocked waiting for the tool to return.
;;
;; Output sanitization: When iar--sanitize-exec-output is non-nil
;; (enabled for CTF/external operations), the output is passed through
;; iar--sanitize-external-output to strip control sequences and
;; flag prompt injection patterns before returning to the AI.  The flag
;; is captured at call time (not read in the sentinel) because process
;; sentinels run in an unpredictable buffer context.

(require 'iar-tool-call)
(require 'iar-output-sanitizer)
(require 'iar-rate-limit)

(defcustom iar-exec-default-timeout 600
  "Default timeout in seconds for async shell commands.
One hung tool call once ate a full 1800s cycle budget (aria c62/c63:
a single rg with no timeout stalled the tool-execution window, the
one window no watchdog watches). 600s bounds the damage to a third
of a cycle; callers needing longer (builds, test suites) pass an
explicit timeout."
  :type 'integer
  :group 'iar)

(defun iar--async-shell-command (callback command &optional timeout)
  "Run COMMAND asynchronously, returning result via CALLBACK.

Returns immediately, calls CALLBACK with the result string when done.
TIMEOUT in seconds kills the process on true hangs. Default: the
`iar-exec-default-timeout' variable (600s) -- a cycle budget is 1800s,
so one hung call must never be able to eat it. Callers may pass a
larger explicit timeout for legitimately slow commands (builds,
suite runs).

Uses :connection-type 'pipe to prevent pty allocation.  Without a TTY,
programs detect non-interactive mode via isatty() and skip pagers,
color codes, and interactive prompts.  No environment variable patches
needed."
  (let* ((cb callback)
         (cmd command)
         (timeout (or timeout iar-exec-default-timeout))
         (buf (generate-new-buffer " *gptel-async-shell*"))
         (timed-out nil)
         (timer nil)
         (proc nil)
         (sanitize-output (bound-and-true-p iar--sanitize-exec-output)))
    ;; Rate limit: sleep before exec if enabled
    (iar--rate-limit-maybe-sleep)
    (setq proc
          (condition-case err
              (make-process
               :name "gptel-async-cmd"
               :buffer buf
               :connection-type 'pipe
               :command (list shell-file-name "-c" cmd)
               :sentinel
               (lambda (proc _event)
                 (when (memq (process-status proc) '(exit signal))
                   (when timer (cancel-timer timer))
                   (let* ((exit-code (process-exit-status proc))
                          (output (if (buffer-live-p buf)
                                      (with-current-buffer buf (buffer-string))
                                    "[buffer was no longer live — output lost]")))
                     (when (buffer-live-p buf) (kill-buffer buf))
                     (let ((result
                            (cond
                             (timed-out
                              (format "[TIMEOUT after %ds — process killed]\n%s" timeout output))
                             ((and exit-code (/= exit-code 0))
                              (format "Command exited with code %d.\nOutput:\n%s" exit-code output))
                             (t output))))
                       (funcall cb
                                (if sanitize-output
                                    (iar--sanitize-external-output result)
                                  result)))))))
            (error
             (when (buffer-live-p buf) (kill-buffer buf))
             (signal (car err) (cdr err)))))
    (setq timer
          (run-with-timer timeout nil
                          (lambda ()
                            (when (process-live-p proc)
                              (setq timed-out t)
                              (delete-process proc)))))))

(iar-tool-register
 (gptel-make-tool
  :name "execute_code_local"
  :description "Execute bash commands in the Emacs container. Available: bash, dig, nmap, openssl, python3, jq, whois, traceroute, tcpdump, rg, git, curl, find, gawk, sed, grep, gcc, make, tar, gzip, unzip."
  :args (list '(:name "command" :type "string" :description "The bash command to execute. Use bash syntax."))
  :async t
  :function (lambda (callback command)
              (condition-case err
                  (iar--async-shell-command callback command)
                (error (funcall callback
                                (format "Error: Failed to execute command: %s\nDetail: %s"
                                        command (error-message-string err))))))))

(provide 'iar-tool--execute-code-local)