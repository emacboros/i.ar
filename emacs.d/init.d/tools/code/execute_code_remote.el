;; -*- lexical-binding: t; -*-

;;; execute_code_remote tool for gptel
;; Execute commands in purpose-specific containers (local or remote).
;;
;; Local targets: podman exec into a named container.
;;   Container name resolved from environment variable: IAR_CONTAINER_<target>.
;;   Shared workspace at /workspace bridges files between Emacs and containers.
;;
;; Remote targets: SSH over WireGuard to a debug container on a server.
;;   Target name -> connection details resolved from iar-remote-targets alist
;;   or from IAR_REMOTE_TARGETS environment variable.
;;   SSH via call-process with explicit argv (no shell, no injection surface).
;;
;; This is an ASYNC tool: the function receives a callback as its first
;; argument (per gptel's :async convention) and calls it with the result
;; when the process completes.

(require 'iar-tool-call)
(require 'iar-utils)
(require 'subr-x)
(require 'iar-rate-limit)

;; Declared in configs/paths.el (loaded before init.d modules).
(defvar iar-personalization-path nil
  "Absolute path to the personalization mount point.")

;;; --- Buffer-local state ---

(defvar-local iar--current-containers nil
  "List of container target names available in the current session.
Set by `iar--setup-assembled-buffer' from the project's #+CONTAINERS.
Used to validate that the agent only targets containers declared in
the project file.")

;;; --- Remote target configuration ---

(defcustom iar-remote-targets nil
  "Alist mapping remote target names to connection plists.
Each entry is (NAME . (:host \"IP\" :port PORT :user \"USER\")).
Example: ((\"sophon\" . (:host \"10.66.0.5\" :port 22 :user \"debug-agent\")))
When nil, remote targets can still be configured via the
IAR_REMOTE_TARGETS environment variable."
  :type '(alist :key-type string
                :value-type (plist :value-type (choice string integer)))
  :group 'iar)

(defun iar--parse-remote-targets-env ()
  "Parse IAR_REMOTE_TARGETS environment variable.
Format: comma-separated entries of name:host:port[:user].
Example: \"sophon:10.66.0.5:22:debug-agent,rammstein:10.66.0.1:22:debug-agent\"
Returns an alist suitable for merging with `iar-remote-targets'."
  (let ((raw (getenv "IAR_REMOTE_TARGETS")))
    (when (and raw (not (string-empty-p raw)))
      (let ((entries nil))
        (dolist (entry (split-string raw "," t))
          (let* ((parts (split-string entry ":" t))
                 (name (car parts))
                 (host (cadr parts))
                 (port (if (caddr parts) (string-to-number (caddr parts)) 22))
                 (user (or (cadddr parts) "debug-agent")))
            (when (and name host)
              (push (cons name (list :host host :port port :user user))
                    entries))))
        (nreverse entries)))))

(defun iar--resolve-remote-target (target)
  "Resolve TARGET name to a connection plist.
Checks `iar-remote-targets' first, then IAR_REMOTE_TARGETS env var.
Returns a plist (:host HOST :port PORT :user USER) or nil if not found."
  (or (cdr (assoc target iar-remote-targets))
      (cdr (assoc target (iar--parse-remote-targets-env)))))

;;; --- Target resolution ---

(defun iar--resolve-container-env-var (target)
  "Get the container name for TARGET from environment variable.
Returns the value of IAR_CONTAINER_<target> (uppercased), or nil."
  (let ((env-var (format "IAR_CONTAINER_%s" (upcase target))))
    (getenv env-var)))

(defun iar--resolve-target (target)
  "Resolve TARGET to a target type and connection details.
Returns a plist:
  (:type :local :container \"name\") for local podman exec targets.
  (:type :remote :host \"IP\" :port PORT :user \"user\") for SSH targets.
  (:type :unknown) if the target cannot be resolved."
  (cond
   ;; Local container: env var exists
   ((iar--resolve-container-env-var target)
    (list :type :local
          :container (iar--resolve-container-env-var target)))
   ;; Remote target: in config or env var
   ((iar--resolve-remote-target target)
    (let ((conn (iar--resolve-remote-target target)))
      (list :type :remote
            :host (plist-get conn :host)
            :port (or (plist-get conn :port) 22)
            :user (or (plist-get conn :user) "debug-agent"))))
   ;; Unknown
   (t (list :type :unknown))))

(defun iar--validate-target (target)
  "Check if TARGET is in the current session's container list.
Returns t if TARGET is allowed, nil otherwise.
When `iar--current-containers' is nil (no #+CONTAINERS), all targets
are rejected -- execute_code_remote should not be registered."
  (and iar--current-containers
       (member target iar--current-containers)))

;;; --- Command execution: local (podman exec) ---

(defun iar--exec-local-container (callback target command &optional timeout)
  "Execute COMMAND in local container TARGET via podman exec.
Calls CALLBACK with the result string when done.
TIMEOUT in seconds (default 3600)."
  (let* ((container-name (iar--resolve-container-env-var target))
         (timeout (or timeout 3600))
         (buf (generate-new-buffer " *gptel-remote-exec*"))
         (timed-out nil)
         (timer nil)
         (proc nil)
         (sanitize-output (bound-and-true-p iar--sanitize-exec-output)))
    ;; Rate limit: sleep before exec if enabled
    (iar--rate-limit-maybe-sleep)
    (setq proc
          (condition-case err
              (make-process
               :name "gptel-remote-exec"
               :buffer buf
               :connection-type 'pipe
               :command (list "podman" "exec" container-name
                              "/bin/bash" "-c" command)
               :sentinel
               (lambda (proc _event)
                 (when (memq (process-status proc) '(exit signal))
                   (when timer (cancel-timer timer))
                   (let* ((exit-code (process-exit-status proc))
                          (output (if (buffer-live-p buf)
                                      (with-current-buffer buf (buffer-string))
                                    "[buffer was no longer live -- output lost]")))
                     (when (buffer-live-p buf) (kill-buffer buf))
                     (let ((result
                            (cond
                             (timed-out
                              (format "[TIMEOUT after %ds -- process killed]\n%s"
                                      timeout output))
                             ((and exit-code (/= exit-code 0))
                              (format "Command exited with code %d.\nOutput:\n%s"
                                      exit-code output))
                             (t output))))
                       (funcall callback
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

;;; --- Command execution: remote (SSH) ---

(defun iar--exec-remote-ssh (callback target command &optional timeout)
  "Execute COMMAND on remote target TARGET via SSH.
Calls CALLBACK with the result string when done.
TIMEOUT in seconds (default 3600).
Uses call-process via make-process with explicit argv (no shell)."
  (let* ((conn (iar--resolve-remote-target target))
         (host (plist-get conn :host))
         (port (plist-get conn :port))
         (user (plist-get conn :user))
         (timeout (or timeout 3600))
         (buf (generate-new-buffer " *gptel-remote-ssh*"))
         (timed-out nil)
         (timer nil)
         (proc nil)
         (sanitize-output (bound-and-true-p iar--sanitize-exec-output)))
    ;; Rate limit: sleep before exec if enabled
    (iar--rate-limit-maybe-sleep)
    (setq proc
          (condition-case err
              (make-process
               :name "gptel-remote-ssh"
               :buffer buf
               :connection-type 'pipe
               :command (list "ssh"
                             "-o" "StrictHostKeyChecking=accept-new"
                             "-o" "BatchMode=yes"
                             "-o" "ConnectTimeout=10"
                             "-p" (number-to-string port)
                             (format "%s@%s" user host)
                             command)
               :sentinel
               (lambda (proc _event)
                 (when (memq (process-status proc) '(exit signal))
                   (when timer (cancel-timer timer))
                   (let* ((exit-code (process-exit-status proc))
                          (output (if (buffer-live-p buf)
                                      (with-current-buffer buf (buffer-string))
                                    "[buffer was no longer live -- output lost]")))
                     (when (buffer-live-p buf) (kill-buffer buf))
                     (let ((result
                            (cond
                             (timed-out
                              (format "[TIMEOUT after %ds -- process killed]\n%s"
                                      timeout output))
                             ((and exit-code (/= exit-code 0))
                              (format "SSH command exited with code %d.\nOutput:\n%s"
                                       exit-code output))
                             (t output))))
                       (funcall callback
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

;;; --- Main tool function ---

(defun iar--tool-execute-code-remote (callback target command)
  "Execute COMMAND in TARGET container or remote host.
TARGET is a container name from the project's #+CONTAINERS list.
CALLBACK is called with the result string when done."
  (condition-case err
      (cond
       ;; Validate target is allowed in this session
       ((not (iar--validate-target target))
        (funcall callback
                 (format "Error: Target '%s' is not in the current session's container list. Available: %s"
                         target
                         (or (mapconcat #'identity iar--current-containers ", ")
                             "(none -- no #+CONTAINERS configured)"))))
       ;; Resolve and dispatch
       (t
        (let ((resolved (iar--resolve-target target)))
          (pcase (plist-get resolved :type)
            (:local
             (iar--exec-local-container callback target command))
            (:remote
             (iar--exec-remote-ssh callback target command))
            (_
             (funcall callback
                      (format "Error: Unknown target '%s'. Not found as local container (IAR_CONTAINER_%s) or remote target."
                              target (upcase target))))))))
    (error
     (funcall callback
              (format "Error: Failed to execute remote command: %s\nDetail: %s"
                      command (error-message-string err))))))

(iar-tool-register
 (gptel-make-tool
  :name "execute_code_remote"
  :description "Execute bash in a purpose-specific container (local via podman exec, remote via SSH). Targets defined by project #+CONTAINERS."
  :args (list '(:name "target" :type "string" :description "Container target name (e.g., 'pentest', 'concepts', 'life-org').")
              '(:name "command" :type "string" :description "The bash command to execute in the target container. Use bash syntax."))
  :async t
  :function #'iar--tool-execute-code-remote))

(provide 'iar-tool--execute-code-remote)