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

(ert-deftest test-audit-log-tool-call-read-file-logs-path ()
  "read_file tool calls audit the target filepath (file-touch graph,
connectome-metrics-design.md gap 1)."
  (let ((logged nil))
    (cl-letf (((symbol-function 'iar--audit-log-as)
               (lambda (_agent _tool detail) (setq logged detail))))
      (iar--audit-log-tool-call-with-agent
       "read_file" '(:filepath "/etc/passwd") "content" "aria")
      (should (string-match-p "path=/etc/passwd" logged))
      (should (string-match-p "name=read_file" logged)))))

(ert-deftest test-audit-log-tool-call-list-directory-logs-path ()
  "list_directory tool calls audit the target path."
  (let ((logged nil))
    (cl-letf (((symbol-function 'iar--audit-log-as)
               (lambda (_agent _tool detail) (setq logged detail))))
      (iar--audit-log-tool-call-with-agent
       "list_directory" '(:path "/tmp") "files" "aria")
      (should (string-match-p "path=/tmp" logged)))))

(ert-deftest test-audit-log-tool-call-read-knowledge-logs-path ()
  "read_knowledge tool calls audit the target path."
  (let ((logged nil))
    (cl-letf (((symbol-function 'iar--audit-log-as)
               (lambda (_agent _tool detail) (setq logged detail))))
      (iar--audit-log-tool-call-with-agent
       "read_knowledge" '(:path "aria/THREADS.org") "content" "aria")
      (should (string-match-p "path=aria/THREADS.org" logged)))))

(ert-deftest test-audit-log-tool-call-delegate-logs-lineage ()
  "delegate tool calls audit the agent + capped task (retainer-era
lineage, connectome gap 3)."
  (let ((logged nil))
    (cl-letf (((symbol-function 'iar--audit-log-as)
               (lambda (_agent _tool detail) (setq logged detail))))
      (iar--audit-log-tool-call-with-agent
       "delegate" '(:agent "reviewer" :task "review the thing") "ok" "aria")
      (should (string-match-p "agent=reviewer" logged))
      (should (string-match-p "task=review the thing" logged)))
    ;; pipeline mode (no agent arg) + long task capped at 77+"..."
    (setq logged nil)
    (cl-letf (((symbol-function 'iar--audit-log-as)
               (lambda (_agent _tool detail) (setq logged detail))))
      (iar--audit-log-tool-call-with-agent
       "delegate" (list :task (make-string 200 ?y)) "ok" "aria")
      (should (string-match-p "agent=pipeline" logged))
      (should (string-match "task=\\(y+\\)\\.\\.\\." logged))
      (should (= 77 (length (match-string 1 logged)))))))

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

;;; --- Status classifier (session VIII, 2026-09-08) ---
;;; aria-0007: fence-rejected calls must not log status=success.
;;; Exit-code/timeout visibility: exec failures were invisible.

(ert-deftest test-audit-classify-rejected-tool-call-error ()
  "A nil tool-name with <tool_call_error> result classifies rejected."
  (should (equal "rejected"
                 (iar--audit-classify-result
                  nil "<tool_call_error>\nTool blocked\n</tool_call_error>"))))

(ert-deftest test-audit-classify-rejected-nil-name-any-result ()
  "A nil tool-name classifies rejected regardless of result shape
(the tool never ran -- name=nil is the primary signal)."
  (should (equal "rejected" (iar--audit-classify-result nil nil)))
  (should (equal "rejected" (iar--audit-classify-result nil "anything"))))

(ert-deftest test-audit-classify-exec-exit-code-error ()
  "Non-zero shell exit (Command exited with code N) classifies error."
  (should (equal "error"
                 (iar--audit-classify-result
                  "execute_code_local" "Command exited with code 1.\nOutput:\nboom"))))

(ert-deftest test-audit-classify-exec-timeout-error ()
  "A timeout kill classifies error."
  (should (equal "error"
                 (iar--audit-classify-result
                  "execute_code_local" "[TIMEOUT after 600s — process killed]\nout"))))

(ert-deftest test-audit-classify-tool-error-prefix ()
  "Tool-level Error: prefix classifies error (existing contract)."
  (should (equal "error"
                 (iar--audit-classify-result "write_file" "Error: blocked"))))

(ert-deftest test-audit-classify-success-default ()
  "Normal results classify success."
  (should (equal "success" (iar--audit-classify-result "read_file" "content")))
  (should (equal "success" (iar--audit-classify-result "execute_code_local" "out\nmore")))
  (should (equal "success" (iar--audit-classify-result "write_file" nil))))

(ert-deftest test-audit-log-tool-call-rejected-status ()
  "The bridge logs status=rejected for blocked calls (aria-0007)."
  (let ((logged nil))
    (cl-letf (((symbol-function 'iar--audit-log-as)
               (lambda (_agent _tool detail) (setq logged detail))))
      (iar--audit-log-tool-call-with-agent
       nil nil "<tool_call_error>\nUnknown tool\n</tool_call_error>" "aria")
      (should (string-match-p "status=rejected" logged))
      (should (string-match-p "name=nil" logged)))))

(ert-deftest test-audit-log-tool-call-exec-exit-logs-error ()
  "The bridge logs status=error for non-zero exec exits (was invisible)."
  (let ((logged nil))
    (cl-letf (((symbol-function 'iar--audit-log-as)
               (lambda (_agent _tool detail) (setq logged detail))))
      (iar--audit-log-tool-call-with-agent
       "execute_code_local" '(:command "false") "Command exited with code 1.\nOutput:\n" "aria")
      (should (string-match-p "status=error" logged)))))
