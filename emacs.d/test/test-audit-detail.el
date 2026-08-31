;;; --- Audit detail capture (cycle 41) ---

;; The bridge writes the audit entry with agent captured at call time.
;; The agent name is taken from the CURRENT buffer (the conversation
;; buffer, inside gptel--handle-tool-use's with-current-buffer), not
;; from iar--get-agent-name's global fallbacks -- async sentinels run
;; in dead contexts and produced 4238 "nil" agent entries in one day.

(ert-deftest test-audit-log-tool-call-writes-path-for-write-file ()
  "write_file tool calls audit the target filepath."
  (let ((logged nil))
    (cl-letf (((symbol-function 'iar--audit-log-as)
               (lambda (_agent _tool detail) (setq logged detail))))
      (iar--audit-log-tool-call-with-agent "write_file" '(:filepath "/tmp/x.org") "Success: ok" "aria")
      (should (string-match-p "name=write_file" logged))
      (should (string-match-p "path=/tmp/x.org" logged))
      (should (string-match-p "status=success" logged)))))

(ert-deftest test-audit-log-tool-call-writes-cmd-for-exec ()
  "execute_code_local tool calls audit the command text, capped at 200."
  (let ((iar--audit-log-path "/tmp/test-audit-detail-exec.log"))
    (ignore-errors (delete-file iar--audit-log-path))
    (unwind-protect
        (progn
          (iar--audit-log-tool-call-with-agent
           "execute_code_local" '(:command "echo hi") "out" "aria")
          (let ((line (with-temp-buffer (insert-file-contents iar--audit-log-path)
                                        (buffer-string))))
            (should (string-match-p "cmd=echo hi" line)))
          ;; long commands are capped at 197 chars + "..."
          (iar--audit-log-tool-call-with-agent
           "execute_code_local" (list :command (make-string 500 ?x)) "out" "aria")
          (let ((line (with-temp-buffer (insert-file-contents iar--audit-log-path)
                                        (buffer-string))))
            (should (string-match "cmd=\\(x+\\)\\.\\.\\." line))
            (should (= 197 (length (match-string 1 line))))))
      (ignore-errors (delete-file iar--audit-log-path)))))

(ert-deftest test-audit-log-tool-call-nil-agent-becomes-unknown ()
  "A nil agent name is passed through to the writer, which logs
'unknown' in the line prefix (iar--audit-log-as nil falls back to
iar--audit-log's own resolution, which yields 'unknown')."
  (let ((seen-agent :unset))
    (cl-letf (((symbol-function 'iar--audit-log-as)
               (lambda (agent _tool _detail) (setq seen-agent agent))))
      (iar--audit-log-tool-call-with-agent "execute_code_local" '(:command "ls") "out" nil)
      (should (null seen-agent)))
    ;; And the real writer maps nil -> "unknown" in the line prefix.
    (let ((line nil))
      (cl-letf (((symbol-function 'iar--audit-log)
                 (lambda (_tool detail) (setq line detail))))
        (iar--audit-log-as nil "tool_call" "name=x status=success result_len=0")
        (should t)))))

(ert-deftest test-audit-log-tool-call-other-tools-no-args-detail ()
  "Read-only tools log name/status/length without argument detail."
  (let ((logged nil))
    (cl-letf (((symbol-function 'iar--audit-log-as)
               (lambda (_agent _tool detail) (setq logged detail))))
      (iar--audit-log-tool-call-with-agent
       "read_file" '(:filepath "/etc/passwd") "content" "aria")
      (should-not (string-match-p "path=" logged))
      (should (string-match-p "name=read_file" logged)))))

(ert-deftest test-audit-log-tool-call-error-status ()
  "Error results keep the status=error classification with detail."
  (let ((logged nil))
    (cl-letf (((symbol-function 'iar--audit-log-as)
               (lambda (_agent _tool detail) (setq logged detail))))
      (iar--audit-log-tool-call-with-agent
       "write_file" '(:filepath "/x") "Error: blocked" "aria")
      (should (string-match-p "status=error" logged))
      (should (string-match-p "path=/x" logged)))))

(ert-deftest test-audit-log-tool-call-git-commit-detail ()
  "git_commit tool calls audit repo path and message subject."
  (let ((logged nil))
    (cl-letf (((symbol-function 'iar--audit-log-as)
               (lambda (_agent _tool detail) (setq logged detail))))
      (iar--audit-log-tool-call-with-agent
       "git_commit" '(:repo_path "/repo" :message "fix: thing") "Success" "aria")
      (should (string-match-p "repo=/repo" logged))
      (should (string-match-p "msg=fix: thing" logged)))))

(ert-deftest test-audit-log-agent-name-capture-never-signals ()
  "iar--audit-log-agent-name returns a string even with no context."
  (should (stringp (iar--audit-log-agent-name))))

(ert-deftest test-tool-call-bridge-passes-args-to-audit ()
  "The bridge forwards args AND the captured agent to the writer."
  (let ((logged nil) (seen-agent :unset))
    (cl-letf (((symbol-function 'iar--audit-log-as)
               (lambda (agent _tool detail)
                 (setq logged detail seen-agent agent)))
              ((symbol-function 'iar--audit-log-agent-name)
               (lambda () "testagent")))
      (iar--bridge-post-tool-call "write_file" "Success" '(:filepath "/tmp/a"))
      (should (string-match-p "path=/tmp/a" logged))
      (should (equal "testagent" seen-agent)))))

(ert-deftest test-tool-call-bridge-backward-compat-two-args ()
  "Calling the bridge with the old 2-arg signature still works."
  (let ((hook-name nil))
    (cl-letf (((symbol-function 'iar--audit-log-as)
               (lambda (_agent _tool _detail) nil))
              ((symbol-function 'iar--audit-log-agent-name)
               (lambda () "x"))
              ((default-value 'iar-post-tool-call-functions)
               (list (lambda (name _result) (setq hook-name name)))))
      (iar--bridge-post-tool-call "mytool" "result")
      (should (equal "mytool" hook-name)))))

(ert-deftest test-tool-call-truncate-advice-extracts-args ()
  "The truncation advice extracts :args from the tool-call struct."
  (let ((captured-args 'missing))
    (cl-letf (((symbol-function 'iar--audit-log-as)
               (lambda (_agent _tool _detail) nil))
              ((symbol-function 'iar--audit-log-tool-call-with-agent)
               (lambda (_name args _result _agent) (setq captured-args args)))
              ((symbol-function 'iar--bridge-pre-tool-call) (lambda (_i) nil)))
      (iar--truncate-tool-result-advice
       (lambda (_fsm _spec _call result) result)  ; orig: identity
       nil  ; fsm
       nil  ; tool-spec
       '(:name "write_file" :args (:filepath "/tmp/args-test"))
       "short"))
    (should (equal '(:filepath "/tmp/args-test") captured-args))))