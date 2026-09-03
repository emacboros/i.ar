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

;; Stubbing a primitive (make-process) with cl-letf triggers native-comp
;; trampoline compilation, which dies in batch mode with
;; excessive-lisp-nesting (tramp-archive file-name-handler recursion,
;; observed 2026-09-03). Advice-around does not recompile the primitive.
;; Disable trampolines for this test file's session as a belt-and-braces
;; guard: any test that stubs a primitive sets this before cl-letf runs.
(when (boundp 'comp-enable-subr-trampolines)
  (setq comp-enable-subr-trampolines nil))

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
  "Allowed target passes validation."
  (let ((iar--current-containers '("pentest" "concepts")))
    (should (iar--validate-target "pentest"))
    (should (iar--validate-target "concepts"))))

(ert-deftest test-remote-validate-target-not-allowed ()
  "Target not in container list fails validation."
  (let ((iar--current-containers '("pentest")))
    (should-not (iar--validate-target "concepts"))))

(ert-deftest test-remote-validate-target-no-containers ()
  "With no container list configured, all targets are rejected."
  (let ((iar--current-containers nil))
    (should-not (iar--validate-target "pentest"))))

;;; --- Tool-level rejection tests ---

(ert-deftest test-remote-tool-rejects-unauthorized-target ()
  "Tool rejects a target not in the session's container list."
  (let ((iar--current-containers '("allowed-target"))
        (result nil))
    (iar--tool-execute-code-remote
     (lambda (r) (setq result r))
     "forbidden-target" "echo hello")
    (should (stringp result))
    (should (string-match-p "Error" result))
    (should (string-match-p "not in the current session's container list" result))
    (should (string-match-p "allowed-target" result))))

(ert-deftest test-remote-tool-rejects-unknown-target ()
  "Tool rejects a target that resolves to :unknown."
  (let ((iar--current-containers '("ghost-target"))
        (result nil))
    (iar--tool-execute-code-remote
     (lambda (r) (setq result r))
     "ghost-target" "echo hello")
    (should (stringp result))
    (should (string-match-p "Error" result))
    (should (string-match-p "Unknown target" result))))

(ert-deftest test-remote-tool-error-handler ()
  "Errors from the dispatch path are caught and returned as strings."
  (let ((iar--current-containers '("test-target"))
        (result nil))
    (cl-letf (((symbol-function 'iar--resolve-target)
               (lambda (_target) (error "boom"))))
      (iar--tool-execute-code-remote
       (lambda (r) (setq result r))
       "test-target" "echo hello")
      (should (stringp result))
      (should (string-match-p "Error" result))
      (should (string-match-p "boom" result)))))

(ert-deftest test-remote-tool-local-dispatch ()
  "iar--tool-execute-code-remote should dispatch to local container exec."
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

;;; --- Preflight honest-failure tests (2026-09-03, fix C) ---
;; Regression for the sidecar-wiring failure (knowledge/aria/
;; research-sidecar-wiring.md): every execute_code_remote call since the
;; sidecar existed failed with a generic re-signaled "No such file or
;; directory, podman" error that failure-first could not see (cycle exit
;; stayed green; audit bridge logged the callback as success). The
;; preflight must return an honest diagnosis instead.

(ert-deftest test-remote-preflight-podman-missing-honest-error ()
  "Without a podman binary, local exec returns an honest diagnosis,
calls the callback exactly once, and never spawns a process."
  (let ((iar--current-containers '("research"))
        (process-environment (cons "IAR_CONTAINER_RESEARCH=iar-research-1"
                                   process-environment))
        (results nil)
        (spawned nil))
    (advice-add 'make-process :around
                (lambda (_orig &rest _args) (setq spawned t))
                '((name . preflight-stub)))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (_name) nil)))
      (unwind-protect
          (progn
            (iar--tool-execute-code-remote
             (lambda (r) (push r results))
             "research" "echo hello")
            (should (= (length results) 1))
            (should (string-match-p "podman client not found" (car results)))
            (should (string-match-p "Do not retry" (car results)))
            (should (string-match-p "execute_code_local" (car results)))
            (should-not spawned))
        (advice-remove 'make-process 'preflight-stub)))))

(ert-deftest test-remote-preflight-ssh-missing-honest-error ()
  "Without an ssh binary, remote exec returns an honest diagnosis
and never spawns a process."
  (let ((iar--current-containers '("sophon"))
        (iar-remote-targets '(("sophon" . (:host "10.66.0.5" :port 22 :user "debug-agent"))))
        (results nil)
        (spawned nil))
    (advice-add 'make-process :around
                (lambda (_orig &rest _args) (setq spawned t))
                '((name . preflight-stub)))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (_name) nil)))
      (unwind-protect
          (progn
            (iar--tool-execute-code-remote
             (lambda (r) (push r results))
             "sophon" "echo hello")
            (should (= (length results) 1))
            (should (string-match-p "ssh client not found" (car results)))
            (should-not spawned))
        (advice-remove 'make-process 'preflight-stub)))))

(ert-deftest test-remote-preflight-present-proceeds-to-dispatch ()
  "With the binary present, preflight is a no-op and dispatch
proceeds (no behavior change on the happy path)."
  (let ((iar--current-containers '("research"))
        (process-environment (cons "IAR_CONTAINER_RESEARCH=iar-research-1"
                                   process-environment))
        (results nil)
        (dispatched nil))
    (advice-add 'make-process :around
                (lambda (orig &rest args)
                  (setq dispatched t)
                  ;; Emulate a clean exit: insert output into the tool's
                  ;; own buffer, then start a REAL short-lived process
                  ;; (via the original make-process -- advice recursion
                  ;; would blow max-lisp-eval-depth) carrying the tool's
                  ;; own sentinel; on exit the sentinel reads the buffer
                  ;; and calls the callback, exactly like a real exec.
                  (let ((buf (plist-get args :buffer))
                        (sentinel (plist-get args :sentinel)))
                    (with-current-buffer buf (insert "sidecar says hi"))
                    (let ((real-proc (funcall orig :name "probe" :buffer buf
                                              :command '("sleep" "0.05"))))
                      (set-process-sentinel real-proc sentinel)
                      real-proc)))
                '((name . preflight-stub)))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (_name) t))
              ((symbol-function 'iar--rate-limit-maybe-sleep)
               (lambda () nil)))
      (unwind-protect
          (progn
            (iar--tool-execute-code-remote
             (lambda (r) (push r results))
             "research" "echo hello")
            ;; the emulated process needs a moment to exit and fire the
            ;; sentinel that delivers the callback
            (sit-for 0.5)
            (should dispatched)
            (should (string-match-p "sidecar says hi" (car results))))
        (advice-remove 'make-process 'preflight-stub)))))

(provide 'test-execute-code-remote)
;;; test-execute-code-remote.el ends here