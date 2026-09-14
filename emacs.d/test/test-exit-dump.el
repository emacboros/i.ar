;; -*- lexical-binding: t; -*-
;;; c323 exit-dump tests (orphan fix v2): the event-loop exit dumps any
;;; request still in flight. c322 live verification: the orphan is the
;;; POST-CLOSE re-send, not the echo -- the echo completes normally and
;;; its lines land; the re-send (sent after the close blocks the echo
;;; call) is killed mid-flight by kill-emacs. Law 39: the fixture
;;; replays the PRODUCTION sequence, not a plausible one.

(require 'ert)
(require 'cl-lib)
(require 'iar-agent-cycle)
(require 'iar-request-log)

(defun iar--test-exit-dump-live-re-send ()
  "PRODUCTION sequence replay (c322 census, continuo 260914141203):
1. the echo request (-27) COMPLETES normally -- START/RESPONSE/PARSE
   landed via the normal sentinel path (simulated: lines pre-written,
   process dead, entry REMOVED from the alist by the sentinel);
2. the post-close re-send (-28) is in flight -- live process, START
   registered, no RESPONSE/PARSE yet;
3. the event loop exits (iar--cycle-exit-dump) -> the re-send gets
   RESPONSE+PARSE.
Before this fix, step 3 was a no-op and -28 was the orphan."
  (let* ((tmpdir (make-temp-file "exit-dump-" t))
         (iar-personalization-path tmpdir)
         (iar-audit-path "audit")
         (iar--current-agent-name "testagent")
         (iar-request-log-enabled t)
         (buf (iar--test-echo-close-dump-hook-buffer))
         (echo-proc (list 'echo-proc))       ; completed + removed
         (resend-proc (list 'resend-proc))   ; in flight
         (resend-info (list :buffer buf :model "m" :status 'success
                            :tool-use nil :error nil))
         (resend-fsm (gptel-make-fsm :info resend-info)))
    (unwind-protect
        (progn
          (set-default 'iar--current-project "testproject")
          ;; Step 1: the echo completed. Its id was registered; the
          ;; sentinel already removed the alist entry (production
          ;; behavior: gptel-curl--stream-cleanup removes it).
          (puthash echo-proc "REQ-T-27" iar--reqlog-processes)
          (puthash echo-proc "testagent" iar--reqlog-process-agents)
          ;; Step 2: the re-send is live, registered, in the alist.
          (puthash resend-proc "REQ-T-28" iar--reqlog-processes)
          (puthash resend-proc "testagent" iar--reqlog-process-agents)
          (with-temp-buffer
            (insert "HTTP/1.1 200 OK\n\n{\"done\":true}")
            (let ((proc-buf (current-buffer)))
              (cl-letf (((symbol-function 'process-buffer)
                         (lambda (p) (if (eq p resend-proc) proc-buf nil)))
                        ((symbol-function 'process-live-p)
                         (lambda (p) (eq p resend-proc)))
                        ((symbol-function 'alist-get)
                         (lambda (key alist &optional _default _testfn _remove)
                           (cdr (assq key alist)))))
                (let ((gptel--request-alist (list (list resend-proc resend-fsm)))
                      (iar--cycle-state
                       (iar--cycle-make-state "testagent" buf nil 40)))
                  ;; Step 3: the exit path fires the dump.
                  (iar--cycle-exit-dump)))))
          ;; The re-send's lines must EXIST (the regression: they
          ;; never landed before the exit dump).
          (let ((path (expand-file-name
                       "audit/testproject/testagent/REQUESTS.log" tmpdir)))
            (should (file-exists-p path))
            (with-temp-buffer
              (insert-file-contents path)
              (let ((text (buffer-string)))
                (should (string-match-p "REQ REQ-T-28 RESPONSE http=200" text))
                (should (string-match-p "REQ REQ-T-28 PARSE status=success" text))))))
      (clrhash iar--reqlog-processes)
      (clrhash iar--reqlog-process-agents)
      (setq iar--reqlog-agent nil)
      (setq iar--cycle-state nil)
      (set-default 'iar--current-project nil)
      (kill-buffer buf)
      (delete-directory tmpdir :recursive))))

(ert-deftest test-exit-dump-live-re-send-gets-lines ()
  "The PRODUCTION sequence: echo completed, re-send in flight,
exit dump writes the re-send's RESPONSE+PARSE (the orphan's lines)."
  (iar--test-exit-dump-live-re-send))

(ert-deftest test-exit-dump-no-live-request-no-op ()
  "All requests completed (alist empty): the exit dump is a no-op,
no crash -- the common clean-exit shape."
  (let ((gptel--request-alist nil)
        (iar--cycle-state nil)
        (iar--one-shot-state nil))
    (should (progn (iar--cycle-exit-dump) t))))

(ert-deftest test-exit-dump-dead-process-no-op ()
  "A dead process in the alist (sentinel raced, entry not yet
removed): no dump, no crash -- no double-write of lines that
already landed."
  (let* ((tmpdir (make-temp-file "exit-dump-dead-" t))
         (iar-personalization-path tmpdir)
         (iar-audit-path "audit")
         (iar--current-agent-name "testagent")
         (iar-request-log-enabled t)
         (buf (generate-new-buffer " *exit-dump-dead*"))
         (proc (list 'dead-proc))
         (info (list :buffer buf :model "m" :status 'success
                     :tool-use nil :error nil))
         (fsm (gptel-make-fsm :info info)))
    (unwind-protect
        (progn
          (set-default 'iar--current-project "testproject")
          ;; Registered (its lines already landed via the sentinel)
          ;; but the process is dead: the gethash-guard skips it.
          (puthash proc "REQ-T-99" iar--reqlog-processes)
          (puthash proc "testagent" iar--reqlog-process-agents)
          (cl-letf (((symbol-function 'process-live-p) (lambda (_p) nil)))
            (let ((gptel--request-alist (list (list proc fsm))))
              (iar--cycle-exit-dump)))
          ;; No new lines: the dead request's lines already landed.
          (should-not (file-exists-p
                       (expand-file-name
                        "audit/testproject/testagent/REQUESTS.log" tmpdir))))
      (clrhash iar--reqlog-processes)
      (clrhash iar--reqlog-process-agents)
      (setq iar--reqlog-agent nil)
      (set-default 'iar--current-project nil)
      (kill-buffer buf)
      (delete-directory tmpdir :recursive))))

(provide 'test-exit-dump)
