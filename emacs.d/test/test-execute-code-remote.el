;; -*- lexical-binding: t; -*-

;;; Tests for execute_code_remote.el
;;
;; Unit tests for target resolution, validation, and env var parsing.
;; Integration tests (tagged :integration) require podman/ssh and are
;; skipped in normal CI runs.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-tool--execute-code-remote)

;;; --- Target resolution tests ---

(ert-deftest test-remote-resolve-local-container ()
  "Local container target resolves when IAR_CONTAINER_<target> env var exists."
  (let ((process-environment (cons "IAR_CONTAINER_PENTEST=iar-pentest-123"
                                   process-environment)))
    (let ((resolved (iar--resolve-target "pentest")))
      (should (eq (plist-get resolved :type) :local))
      (should (string= (plist-get resolved :container) "iar-pentest-123")))))

(ert-deftest test-remote-resolve-unknown-target ()
  "Unknown target resolves to :type :unknown."
  (let ((process-environment (remove "IAR_CONTAINER_NONEXISTENT=foo"
                                      process-environment)))
    (let ((resolved (iar--resolve-target "nonexistent-target-xyz")))
      (should (eq (plist-get resolved :type) :unknown)))))

(ert-deftest test-remote-resolve-container-env-var ()
  "iar--resolve-container-env-var returns the container name from env."
  (let ((process-environment (cons "IAR_CONTAINER_CONCEPTS=iar-concepts-456"
                                   process-environment)))
    (should (string= (iar--resolve-container-env-var "concepts")
                     "iar-concepts-456"))))

(ert-deftest test-remote-resolve-container-env-var-missing ()
  "iar--resolve-container-env-var returns nil when env var is absent."
  (should (null (iar--resolve-container-env-var "no-such-target"))))

(ert-deftest test-remote-resolve-container-env-var-uppercase ()
  "Env var name is uppercased from target name."
  ;; Target "life-org" -> IAR_CONTAINER_LIFE-ORG
  (let ((process-environment (cons "IAR_CONTAINER_LIFE-ORG=iar-lifeorg-789"
                                   process-environment)))
    (should (string= (iar--resolve-container-env-var "life-org")
                     "iar-lifeorg-789"))))

;;; --- Remote target config tests ---

(ert-deftest test-remote-parse-remote-targets-env ()
  "Parse IAR_REMOTE_TARGETS env var into alist."
  (let ((process-environment (cons "IAR_REMOTE_TARGETS=sophon:10.66.0.5:22:debug-agent,rammstein:10.66.0.1:22:debug-agent"
                                   process-environment)))
    (let ((targets (iar--parse-remote-targets-env)))
      (should (consp targets))
      (should (assoc "sophon" targets))
      (should (string= (plist-get (cdr (assoc "sophon" targets)) :host)
                       "10.66.0.5"))
      (should (= (plist-get (cdr (assoc "sophon" targets)) :port) 22))
      (should (string= (plist-get (cdr (assoc "sophon" targets)) :user)
                       "debug-agent"))
      (should (assoc "rammstein" targets)))))

(ert-deftest test-remote-parse-remote-targets-env-empty ()
  "Empty IAR_REMOTE_TARGETS returns nil."
  (let ((process-environment (cons "IAR_REMOTE_TARGETS="
                                   process-environment)))
    (should (null (iar--parse-remote-targets-env))))

  (let ((process-environment (remove "IAR_REMOTE_TARGETS="
                                      process-environment)))
    (should (null (iar--parse-remote-targets-env)))))

(ert-deftest test-remote-parse-remote-targets-env-default-port ()
  "Missing port defaults to 22."
  (let ((process-environment (cons "IAR_REMOTE_TARGETS=host1:10.0.0.1"
                                   process-environment)))
    (let ((targets (iar--parse-remote-targets-env)))
      (should (assoc "host1" targets))
      (should (= (plist-get (cdr (assoc "host1" targets)) :port) 22))
      ;; Default user
      (should (string= (plist-get (cdr (assoc "host1" targets)) :user)
                       "debug-agent")))))

(ert-deftest test-remote-resolve-remote-target-from-defcustom ()
  "Resolve remote target from iar-remote-targets defcustom."
  (let ((iar-remote-targets
         '(("test-host" . (:host "192.168.1.1" :port 2222 :user "agent")))))
    (let ((resolved (iar--resolve-remote-target "test-host")))
      (should (string= (plist-get resolved :host) "192.168.1.1"))
      (should (= (plist-get resolved :port) 2222))
      (should (string= (plist-get resolved :user) "agent")))))

(ert-deftest test-remote-resolve-remote-target-not-found ()
  "Unknown remote target returns nil."
  (let ((iar-remote-targets nil))
    (should (null (iar--resolve-remote-target "no-such-remote")))))

(ert-deftest test-remote-resolve-target-remote-from-env ()
  "Remote target resolved from env var when not in defcustom."
  (let ((iar-remote-targets nil)
        (process-environment (cons "IAR_REMOTE_TARGETS=debug1:10.0.0.5:22"
                                   process-environment)))
    (let ((resolved (iar--resolve-target "debug1")))
      (should (eq (plist-get resolved :type) :remote))
      (should (string= (plist-get resolved :host) "10.0.0.5"))
      (should (= (plist-get resolved :port) 22))
      (should (string= (plist-get resolved :user) "debug-agent")))))

;;; --- Target validation tests ---

(ert-deftest test-remote-validate-target-allowed ()
  "Target in current-containers list is allowed."
  (let ((iar--current-containers '("pentest" "concepts")))
    (should (iar--validate-target "pentest"))
    (should (iar--validate-target "concepts"))))

(ert-deftest test-remote-validate-target-not-allowed ()
  "Target not in current-containers list is rejected."
  (let ((iar--current-containers '("pentest")))
    (should-not (iar--validate-target "concepts"))
    (should-not (iar--validate-target "life-org"))))

(ert-deftest test-remote-validate-target-no-containers ()
  "When current-containers is nil, all targets are rejected."
  (let ((iar--current-containers nil))
    (should-not (iar--validate-target "pentest"))
    (should-not (iar--validate-target "anything"))))

;;; --- Tool function error path tests ---

(ert-deftest test-remote-tool-rejects-unauthorized-target ()
  "Tool returns error for target not in container list."
  (let ((iar--current-containers '("pentest"))
        (result nil))
    (iar--tool-execute-code-remote
     (lambda (r) (setq result r))
     "concepts" "echo hello")
    ;; The callback is called synchronously for the error path
    (should (stringp result))
    (should (string-match-p "not in the current session" result))))

(ert-deftest test-remote-tool-rejects-unknown-target ()
  "Tool returns error for target that cannot be resolved."
  (let ((iar--current-containers '("ghost"))
        (result nil))
    (iar--tool-execute-code-remote
     (lambda (r) (setq result r))
     "ghost" "echo hello")
    (should (stringp result))
    (should (string-match-p "Unknown target" result))))

(provide 'test-execute-code-remote)
;;; test-execute-code-remote.el ends here
;;; --- Additional coverage tests ---

(ert-deftest test-remote-tool-error-handler ()
  "iar--tool-execute-code-remote should catch errors and return via callback."
  (let ((iar--current-containers '("test-target")))
    (cl-letf (((symbol-function 'iar--resolve-target)
               (lambda (_target) (signal 'error "mock error"))))
      (let (result)
        (iar--tool-execute-code-remote
         (lambda (r) (setq result r))
         "test-target" "echo hello")
        (should (stringp result))
        (should (string-match-p "Error" result))))))

(ert-deftest test-remote-tool-local-dispatch ()
  "iar--tool-execute-code-remote should dispatch to local container."
  (let ((iar--current-containers '("test-target"))
        (dispatched nil))
    (cl-letf (((symbol-function 'iar--resolve-target)
               (lambda (_target) (list :type :local :container "test-container")))
              ((symbol-function 'iar--exec-local-container)
               (lambda (callback _target _command &optional _timeout)
                 (setq dispatched :local)
                 (funcall callback "local result"))))
      (let (result)
        (iar--tool-execute-code-remote
         (lambda (r) (setq result r))
         "test-target" "echo hello")
        (should (eq dispatched :local))
        (should (string= "local result" result))))))

(ert-deftest test-remote-tool-remote-dispatch ()
  "iar--tool-execute-code-remote should dispatch to remote SSH."
  (let ((iar--current-containers '("test-target"))
        (dispatched nil))
    (cl-letf (((symbol-function 'iar--resolve-target)
               (lambda (_target) (list :type :remote :host "10.66.0.5" :port 22 :user "debug-agent")))
              ((symbol-function 'iar--exec-remote-ssh)
               (lambda (callback _target _command &optional _timeout)
                 (setq dispatched :remote)
                 (funcall callback "remote result"))))
      (let (result)
        (iar--tool-execute-code-remote
         (lambda (r) (setq result r))
         "test-target" "echo hello")
        (should (eq dispatched :remote))
        (should (string= "remote result" result))))))

(ert-deftest test-remote-tool-unknown-type-dispatch ()
  "iar--tool-execute-code-remote should handle unknown target type."
  (let ((iar--current-containers '("test-target")))
    (cl-letf (((symbol-function 'iar--resolve-target)
               (lambda (_target) (list :type :unknown))))
      (let (result)
        (iar--tool-execute-code-remote
         (lambda (r) (setq result r))
         "test-target" "echo hello")
        (should (stringp result))
        (should (string-match-p "Error" result))
        (should (string-match-p "Unknown target" result))))))

(ert-deftest test-remote-resolve-remote-target-from-env ()
  "iar--resolve-remote-target should find target from env var."
  (cl-letf (((symbol-function 'getenv)
             (lambda (var)
               (cond ((string= var "IAR_REMOTE_TARGETS")
                      "test-host:10.66.0.99:22:debug-user")
                     (t (let ((old (symbol-function 'getenv)))
                          (funcall old var)))))))
    (let ((result (iar--resolve-remote-target "test-host")))
      (should (string= "10.66.0.99" (plist-get result :host)))
      (should (= 22 (plist-get result :port)))
      (should (string= "debug-user" (plist-get result :user))))))

(provide 'test-execute-code-remote)
;;; test-execute-code-remote.el ends here
