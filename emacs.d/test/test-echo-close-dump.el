;; -*- lexical-binding: t; -*-
;;; c320 terminal-echo orphan fix tests: the close dumps the final
;;; request's RESPONSE+PARSE lines before the event loop exits.

(require 'ert)
(require 'cl-lib)
(require 'iar-agent-cycle)
(require 'iar-request-log)

(defun iar--test-echo-close-dump-hook-buffer ()
  "Build a response buffer for the close tests: thinking (ignore) +
tool span, model text empty -- the echo-only production shape."
  (iar--test-terminal-echo-buffer
   (list (cons "``` reasoning\nWe are done.\n```\n" 'ignore)
         (cons "``` tool (execute_code_local ...)\n```" '(tool . "call_1")))))

(ert-deftest test-echo-close-dump-dumps-live-request ()
  "The echo close dumps the live request: RESPONSE+PARSE land in the
agent's REQUESTS.log even though the event loop exits immediately
after the close (c320: 76/76 continuo cycles had an orphan START)."
  (let* ((tmpdir (make-temp-file "echo-close-" t))
         (iar-personalization-path tmpdir)
         (iar-audit-path "audit")
         (iar--current-agent-name "testagent")
         (iar-request-log-enabled t)
         (buf (iar--test-echo-close-dump-hook-buffer))
         (proc (list 'fake-proc))
         (info (list :buffer buf :model "m" :status 'success
                     :tool-use nil :error nil))
         (fsm (gptel-make-fsm :info info)))
    (unwind-protect
        (progn
          (set-default 'iar--current-project "testproject")
          ;; The curl process buffer: raw HTTP response, as production.
          (with-temp-buffer
            (insert "HTTP/1.1 200 OK\n\n{\"done\":true}")
            (let ((proc-buf (current-buffer)))
              (puthash proc "REQ-T-1" iar--reqlog-processes)
              (puthash proc "testagent" iar--reqlog-process-agents)
              (cl-letf (((symbol-function 'process-buffer) (lambda (_p) proc-buf))
                        ((symbol-function 'process-live-p) (lambda (_p) t))
                        ((symbol-function 'alist-get)
                         (lambda (key alist &optional _default _testfn _remove)
                           (cdr (assq key alist)))))
                (let ((gptel--request-alist (list (list proc fsm)))
                      (iar--cycle-state (iar--cycle-make-state "testagent" buf nil 40))
                      (iar--one-shot-state nil)
                      (iar--reqlog-last-tool-specs
                       (list (list :name "execute_code_local"
                                   :args "echo \"CYCLE_COMPLETE\""))))
                  (with-current-buffer buf
                    (setq gptel--fsm-last
                          (gptel-make-fsm
                           :info (list :position (copy-marker (point-min))
                                       :tracking-marker (copy-marker (point-max))))))
                  ;; Fire the close exactly as the pre-tool-call hook does.
                  (iar--cycle-terminal-echo-close
                   (list :name "execute_code_local" :args "echo \"CYCLE_COMPLETE\""))))))
          ;; The final request's lines must now EXIST in the log --
          ;; this is the regression: before the fix they never landed.
          (let ((path (expand-file-name
                       "audit/testproject/testagent/REQUESTS.log" tmpdir)))
            (should (file-exists-p path))
            (with-temp-buffer
              (insert-file-contents path)
              (let ((text (buffer-string)))
                (should (string-match-p "RESPONSE http=200" text))
                (should (string-match-p "PARSE status=success" text))))))
      (clrhash iar--reqlog-processes)
      (clrhash iar--reqlog-process-agents)
      (setq iar--reqlog-agent nil)
      (setq iar--cycle-state nil)
      (set-default 'iar--current-project nil)
      (kill-buffer buf)
      (delete-directory tmpdir :recursive))))

(ert-deftest test-echo-close-dump-no-live-request-no-op ()
  "No live request matching the cycle buffer: the close still works,
no crash, no dump (the request already completed the normal way)."
  (let* ((buf (iar--test-echo-close-dump-hook-buffer))
         (iar--cycle-state (iar--cycle-make-state "testagent" buf nil 40))
         (iar--one-shot-state nil))
    (unwind-protect
        (with-current-buffer buf
          (setq gptel--fsm-last
                (gptel-make-fsm
                 :info (list :position (copy-marker (point-min))
                             :tracking-marker (copy-marker (point-max)))))
          (let ((gptel--request-alist nil)
                (iar--reqlog-last-tool-specs
                 (list (list :name "execute_code_local"
                             :args "echo \"CYCLE_COMPLETE\""))))
            (let ((result (iar--cycle-terminal-echo-close
                           (list :name "execute_code_local"
                                 :args "echo \"CYCLE_COMPLETE\""))))
              (should (plist-get result :block))
              (should (plist-get iar--cycle-state :completed))
              (should (= 0 (plist-get iar--cycle-state :exit-code))))))
      (setq iar--cycle-state nil)
      (kill-buffer buf))))

(ert-deftest test-echo-close-dump-dead-process-no-op ()
  "A DEAD process in the alist (request finished, sentinel raced):
no dump, no crash -- the close proceeds."
  (let* ((tmpdir (make-temp-file "echo-close-dead-" t))
         (iar-personalization-path tmpdir)
         (iar-audit-path "audit")
         (iar--current-agent-name "testagent")
         (iar-request-log-enabled t)
         (buf (iar--test-echo-close-dump-hook-buffer))
         (proc (list 'fake-proc))
         (info (list :buffer buf :model "m" :status 'success
                     :tool-use nil :error nil))
         (fsm (gptel-make-fsm :info info)))
    (unwind-protect
        (progn
          (set-default 'iar--current-project "testproject")
          (cl-letf (((symbol-function 'process-live-p) (lambda (_p) nil)))
            (let ((gptel--request-alist (list (list proc fsm)))
                  (iar--cycle-state (iar--cycle-make-state "testagent" buf nil 40))
                  (iar--one-shot-state nil)
                  (iar--reqlog-last-tool-specs
                   (list (list :name "execute_code_local"
                               :args "echo \"CYCLE_COMPLETE\""))))
              (with-current-buffer buf
                (setq gptel--fsm-last
                      (gptel-make-fsm
                       :info (list :position (copy-marker (point-min))
                                   :tracking-marker (copy-marker (point-max))))))
              (iar--cycle-terminal-echo-close
               (list :name "execute_code_local" :args "echo \"CYCLE_COMPLETE\""))
              (should (plist-get iar--cycle-state :completed))))
          ;; Dead process -> no dump -> no log file created.
          (should-not (file-exists-p
                       (expand-file-name
                        "audit/testproject/testagent/REQUESTS.log" tmpdir))))
      (setq iar--cycle-state nil)
      (set-default 'iar--current-project nil)
      (kill-buffer buf)
      (delete-directory tmpdir :recursive))))

(provide 'test-echo-close-dump)