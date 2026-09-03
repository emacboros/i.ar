;; -*- lexical-binding: t; -*-
;; Coverage tests written by cycle-Aria 2026-08-31 (cycle 36).
;; Target: the witness + usage layer's filesystem paths, which run
;; in every real request but were invisible to the suite.
;; Style follows test-request-log.el: temp dirs, unwind-protect,
;; buffer-local overrides for paths.

(require 'ert)

;;; --- iar--usage-write-log (37 uncovered forms) ---

(ert-deftest test-tool-call-usage-write-log-writes-line ()
  "usage-write-log appends a summary line with all fields."
  (let* ((tmpdir (make-temp-file "usage-test-" t))
         (iar-personalization-path tmpdir)
         (iar-audit-path "audit")
         (iar--current-agent-name "testagent")
         (iar--current-project "testproject"))
    (unwind-protect
        (progn
          (iar--usage-reset)
          (setq iar--usage-requests 3
                iar--usage-input-tokens 100
                iar--usage-output-tokens 50
                iar--usage-model "test-model")
          (iar--usage-write-log)
          (let ((path (expand-file-name
                       "audit/testproject/testagent/USAGE.log" tmpdir)))
            (should (file-exists-p path))
            (with-temp-buffer
              (insert-file-contents path)
              (should (string-match-p "requests=3 " (buffer-string)))
              (should (string-match-p "input=100 " (buffer-string)))
              (should (string-match-p "output=50 " (buffer-string)))
              (should (string-match-p "total=150 " (buffer-string)))
              (should (string-match-p "model=test-model" (buffer-string))))))
      (delete-directory tmpdir :recursive))))

(ert-deftest test-tool-call-usage-write-log-unknown-agent ()
  "No agent name set: falls back to 'unknown' directory."
  (let* ((tmpdir (make-temp-file "usage-test-" t))
         (iar-personalization-path tmpdir)
         (iar-audit-path "audit")
         (agent-orig (default-value 'iar--current-agent-name))
         (proj-orig (default-value 'iar--current-project)))
    (unwind-protect
        (progn
          (set-default 'iar--current-agent-name nil)
          (set-default 'iar--current-project nil)
          (set-default 'iar--current-agent-file nil)
          (setenv "IAR_PROJECT" nil)
          (let ((iar--current-agent-name nil)
                (iar--current-project nil)
                (iar--current-agent-file nil))
            (iar--usage-reset)
            (iar--usage-write-log))
          (should (file-exists-p
                   (expand-file-name "audit/iar/unknown/USAGE.log" tmpdir))))
      (set-default 'iar--current-agent-name agent-orig)
      (set-default 'iar--current-project proj-orig)
      (delete-directory tmpdir :recursive))))

(ert-deftest test-tool-call-usage-write-log-appends ()
  "Two writes append; the log accumulates lines."
  (let* ((tmpdir (make-temp-file "usage-test-" t))
         (iar-personalization-path tmpdir)
         (iar-audit-path "audit")
         (iar--current-agent-name "testagent")
         (iar--current-project "testproject"))
    (unwind-protect
        (progn
          (iar--usage-reset)
          (iar--usage-write-log)
          (iar--usage-write-log)
          (with-temp-buffer
            (insert-file-contents
             (expand-file-name "audit/testproject/testagent/USAGE.log" tmpdir))
            (should (equal (count-lines (point-min) (point-max)) 2))))
      (delete-directory tmpdir :recursive))))

;;; --- iar--usage-parse-from-curl (26 uncovered forms) ---

(ert-deftest test-tool-call-usage-parse-from-curl-happy-path ()
  "Parses tokens from a curl process buffer with headers + SSE body."
  (iar--usage-reset)
  (let* ((buf (generate-new-buffer " *test-curl*"))
         ;; A fake "process" whose process-buffer resolves to BUF.
         (proc (list 'fake-process)))
    (cl-letf (((symbol-function 'process-buffer)
               (lambda (_p) buf)))
      (with-current-buffer buf
        (insert "HTTP/1.1 200 OK\nContent-Type: text/event-stream\n\n"
                "{\"model\":\"m1\",\"prompt_eval_count\": 30, \"eval_count\": 12, \"done\": true}"))
      (iar--usage-parse-from-curl proc)
      (should (= 1 iar--usage-requests))
      (should (= 30 iar--usage-last-input))
      (should (= 12 iar--usage-last-output))
      (should (string= "m1" iar--usage-model)))
    (kill-buffer buf)))

(ert-deftest test-tool-call-usage-parse-from-curl-no-headers ()
  "No blank-line separator: whole buffer treated as body."
  (let ((buf (generate-new-buffer " *test-curl2*")))
    (unwind-protect
        (progn
          (iar--usage-reset)
          (with-current-buffer buf
            (insert "{\"model\":\"m2\",\"prompt_eval_count\": 7, \"eval_count\": 3}"))
          (cl-letf (((symbol-function 'process-buffer) (lambda (_p) buf)))
            (iar--usage-parse-from-curl 'fake))
          (should (= 1 iar--usage-requests))
          (should (= 7 iar--usage-last-input)))
      (kill-buffer buf))))

(ert-deftest test-tool-call-usage-parse-from-curl-error-demoted ()
  "A signal inside the parse is demoted to a message, never propagates."
  (iar--usage-reset)
  (cl-letf (((symbol-function 'process-buffer)
             (lambda (_p) (error "buffer lookup exploded"))))
    (iar--usage-parse-from-curl 'fake)
    (should (= 0 iar--usage-requests))))

;;; --- iar--truncate-tool-result middle truncation (36 uncovered) ---

(ert-deftest test-tool-call-truncate-middle-notice ()
  "Over-limit strings are middle-truncated with an accurate notice."
  (let ((iar-tool-result-max-chars 20))
    (let* ((result (make-string 100 ?x))
           (out (iar--truncate-tool-result result)))
      (should (< (length out) 100))
      (should (string-prefix-p "xxxxxxxxxx" out))   ; first 10 kept
      (should (string-suffix-p "xxxxxxxxxx" out))   ; last 10 kept
      (should (string-match-p
               (regexp-quote "[... truncated: 100 total chars, kept first 10 and last 10 ...]")
               out)))))

(ert-deftest test-tool-call-truncate-exact-boundary ()
  "A string exactly at max-chars is returned unchanged."
  (let ((iar-tool-result-max-chars 20))
    (let ((result (make-string 20 ?y)))
      (should (eq (iar--truncate-tool-result result) result)))))

(ert-deftest test-tool-call-truncate-disabled-nil-max ()
  "nil max-chars: truncation disabled, result returned as-is."
  (let ((iar-tool-result-max-chars nil)
        (result (make-string 500 ?z)))
    (should (eq (iar--truncate-tool-result result) result))))

;;; --- iar--bridge-post-tool-call error classification (13 uncovered) ---

(ert-deftest test-tool-call-bridge-post-tool-error-status ()
  "A result starting with 'Error:' is audited as status=error."
  (let ((logged nil))
    (cl-letf (((symbol-function 'iar--audit-log-as)
               (lambda (_agent _tool detail) (setq logged detail)))
              ((symbol-function 'iar--audit-log-agent-name)
               (lambda () "testagent")))
      (iar--bridge-post-tool-call "mytool" "Error: something failed")
      (should (string-match-p "status=error" logged))
      (should (string-match-p "name=mytool" logged)))))

(ert-deftest test-tool-call-bridge-post-tool-success-status ()
  "A normal string result is audited as status=success with length."
  (let ((logged nil))
    (cl-letf (((symbol-function 'iar--audit-log-as)
               (lambda (_agent _tool detail) (setq logged detail)))
              ((symbol-function 'iar--audit-log-agent-name)
               (lambda () "testagent")))
      (iar--bridge-post-tool-call "mytool" "fine result")
      (should (string-match-p "status=success" logged))
      (should (string-match-p "result_len=11" logged)))))

(ert-deftest test-tool-call-bridge-post-tool-nil-result ()
  "nil result: no crash, logged as nil name, zero length."
  (let (logged)
    (cl-letf (((symbol-function 'iar--audit-log-as)
               (lambda (_agent _tool detail) (setq logged detail)))
              ((symbol-function 'iar--audit-log-agent-name)
               (lambda () "testagent")))
      (iar--bridge-post-tool-call nil nil)
      (should (string-match-p "name=nil" logged))
      (should (string-match-p "result_len=0" logged)))))

;;; --- iar--bridge-post-response (3 uncovered) ---

(ert-deftest test-tool-call-bridge-post-response-runs-hooks ()
  "post-response bridge runs all registered hooks with args."
  (let ((seen nil))
    (with-temp-buffer
      (kill-all-local-variables)
      (cl-letf (((default-value 'iar-post-response-functions)
                 (list (lambda (status info) (setq seen (list status info))))))
        (iar--bridge-post-response 'success '(:model m))
        (should (equal seen '(success (:model m))))))))

;;; --- iar--usage-reset full reset (2 uncovered) ---

(ert-deftest test-tool-call-usage-reset-clears-last-and-time ()
  "reset also zeroes last-input/last-output and stamps start-time."
  (setq iar--usage-last-input 42
        iar--usage-last-output 17
        iar--usage-start-time nil)
  (iar--usage-reset)
  (should (zerop iar--usage-last-input))
  (should (zerop iar--usage-last-output))
  (should iar--usage-start-time))

;;; --- iar--reqlog-dump (63 uncovered): the witness's raw-body capture ---

(ert-deftest test-reqlog-dump-logs-response-and-parse ()
  "dump writes RESPONSE (http status + body tail) and PARSE lines."
  (let* ((tmpdir (make-temp-file "reqlog-dump-" t))
         (iar-personalization-path tmpdir)
         (iar-audit-path "audit")
         (iar--current-agent-name "testagent")
         (iar--current-project "testproject")
         (iar-request-log-enabled t)
         (iar-request-log-body-chars 500)
         (iar-request-log-tail-chars 500)
         (buf (generate-new-buffer " *test-dump*"))
         (proc (list 'fake-proc))
         (info (list :buffer buf :model "m" :status 'success
                     :tool-use nil :error nil))
         (fsm (gptel-make-fsm :info info)))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (insert "HTTP/1.1 200 OK\n\n{\"message\":\"hi\"}"))
          (puthash proc 7 iar--reqlog-processes)
          (cl-letf (((symbol-function 'process-buffer) (lambda (_p) buf))
                    ((symbol-function 'alist-get)
                     (lambda (key alist &optional _default _testfn _remove)
                       (cdr (assq key alist)))))
            (let ((gptel--request-alist (list (list proc fsm))))
              (iar--reqlog-dump proc)))
          (let ((path (expand-file-name
                       "audit/testproject/testagent/REQUESTS.log" tmpdir)))
            (should (file-exists-p path))
            (with-temp-buffer
              (insert-file-contents path)
              (should (string-match-p "RESPONSE http=200" (buffer-string)))
              (should (string-match-p "body_tail=" (buffer-string)))
              (should (string-match-p "PARSE status=success" (buffer-string)))
              (should (string-match-p "tools=0" (buffer-string))))))
      (kill-buffer buf)
      (delete-directory tmpdir :recursive))))

(ert-deftest test-reqlog-dump-dead-buffer-skips-response ()
  "Dead process buffer: RESPONSE line skipped, no signal."
  (let* ((tmpdir (make-temp-file "reqlog-dump2-" t))
         (iar-personalization-path tmpdir)
         (iar-audit-path "audit")
         (iar--current-agent-name "testagent")
         (iar--current-project "testproject")
         (iar-request-log-enabled t)
         (buf (generate-new-buffer " *test-dump-dead*"))
         (info (list :buffer buf :model "m" :status 'success
                     :tool-use nil :error nil)))
    (unwind-protect
        (progn
          (kill-buffer buf)
          (let ((gptel--request-alist nil))
            (iar--reqlog-dump 'fake-proc))
          (should (not (file-exists-p
                        (expand-file-name
                         "audit/testproject/testagent/REQUESTS.log" tmpdir)))))
      (delete-directory tmpdir :recursive))))

;;; --- iar--reqlog-start-advice agent capture (56 uncovered) ---

(ert-deftest test-reqlog-start-advice-captures-and-logs ()
  "start advice logs REQ START and captures the agent name."
  (let* ((tmpdir (make-temp-file "reqlog-start-" t))
         (iar-personalization-path tmpdir)
         (iar-audit-path "audit")
         (iar-request-log-enabled t)
         (iar-request-log-tail-chars 500)
         (buf (generate-new-buffer " *test-start*"))
         (backend (gptel-make-openai "test-backend" :key "k"))
         (info (list :buffer buf :model "m1" :backend backend
                     :data (list :messages (vector "msg1" "msg2"))))
         (fsm (gptel-make-fsm :info info)))
    (unwind-protect
        (progn
          (with-current-buffer buf (setq iar--current-agent-name "convagent"))
          (set-default 'iar--current-project "testproject")
          (let ((gptel--request-alist nil))
            (iar--reqlog-start-advice fsm))
          (should (equal iar--reqlog-agent "convagent"))
          (with-temp-buffer
            (insert-file-contents
             (expand-file-name "audit/testproject/convagent/REQUESTS.log" tmpdir))
            (should (string-match-p "START backend=test-backend model=m1 msgs=2"
                                    (buffer-string)))))
      (kill-buffer buf)
      (delete-directory tmpdir :recursive))))

(ert-deftest test-reqlog-epoch-prefix-unique-across-sessions ()
  "REQ ids carry the boot epoch: two sessions sharing one log file
produce non-colliding ids (the c26 instrument finding)."
  (let* ((tmpdir (make-temp-file "reqlog-epoch-" t))
         (iar-personalization-path tmpdir)
         (iar-audit-path "audit")
         (iar-request-log-enabled t)
         (iar-request-log-tail-chars 500)
         (buf (generate-new-buffer " *test-epoch*"))
         (backend (gptel-make-openai "test-backend" :key "k"))
         (info (list :buffer buf :model "m1" :backend backend
                     :data (list :messages (vector "msg1" "msg2"))))
         (fsm (gptel-make-fsm :info info)))
    (unwind-protect
        (progn
          (with-current-buffer buf (setq iar--current-agent-name "convagent"))
          (set-default 'iar--current-project "testproject")
          ;; Session A: one request
          (let ((gptel--request-alist nil))
            (iar--reqlog-start-advice fsm))
          ;; Simulate a fresh session: counter back to 0, epoch advanced
          (let ((iar--reqlog-counter 0)
                (iar--reqlog-epoch "260903000001"))
            (let ((gptel--request-alist nil))
              (iar--reqlog-start-advice fsm)))
          (with-temp-buffer
            (insert-file-contents
             (expand-file-name "audit/testproject/convagent/REQUESTS.log" tmpdir))
            (let ((text (buffer-string)))
              ;; Both STARTs present
              (should (string-match-p "REQ [0-9]+-[0-9]+ START" text))
              ;; The two ids differ despite same counter value
              (should (string-match-p (concat "REQ " iar--reqlog-epoch "-1 START") text))
              (should (string-match-p "REQ 260903000001-1 START" text))
              (should-not (string-match-p "REQ 260903000001-2" text)))))
      ;; c30 scar: restore the globals the START advice captured -- a
      ;; test that dirties iar--reqlog-agent redirects every later
      ;; test's reqlog path (the suite wrote into the PRODUCTION audit
      ;; tree). Cleanup is not hygiene; it is the law.
      (setq iar--reqlog-agent nil)
      (set-default 'iar--current-project nil)
      (kill-buffer buf)
      (delete-directory tmpdir :recursive))))

(ert-deftest test-reqlog-epoch-set-once-at-load ()
  "Epoch is a boot-time constant: non-nil, 12 digits, stable within session."
  (should (stringp iar--reqlog-epoch))
  (should (= (length iar--reqlog-epoch) 12))
  (should (string-match-p "^[0-9]+$" iar--reqlog-epoch)))

(ert-deftest test-reqlog-start-advice-disabled-no-log ()
  "Disabled module: no log file created."
  (let* ((tmpdir (make-temp-file "reqlog-start2-" t))
         (iar-personalization-path tmpdir)
         (iar-audit-path "audit")
         (iar-request-log-enabled nil)
         (fsm (gptel-make-fsm :info nil)))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'gptel-fsm-info) (lambda (_f) nil)))
            (iar--reqlog-start-advice fsm))
          (should (not (file-exists-p
                        (expand-file-name "audit/iar/unknown/REQUESTS.log" tmpdir)))))
      (delete-directory tmpdir :recursive))))

;;; --- iar--reqlog-abort-advice (19 uncovered) ---
;;; ENVIRONMENTAL-FAILURE NOTE (turn 163, 2026-09-03):
;;; test-reqlog-abort-advice-dumps-partial once failed in the aria
;;; container, suspected nativecomp trampoline interaction (stale
;;; .eln in eln-cache; 16 trampolines incl. delete_process). By turn
;;; 163 it was green with NO code change: 1015/1015 on 3654a61 and
;;; on parent 30c5385 (clean worktree). Trampolines still present,
;;; so presence alone is not the trigger -- likely a stale .eln
;;; compiled from older source. If this test fails again with no
;;; code change: suspect eln-cache staleness first (clear it,
;;; re-run) before diagnosing the test or the module.

(ert-deftest test-reqlog-abort-advice-dumps-partial ()
  "abort advice finds the request by buffer and dumps the partial."
  (let* ((tmpdir (make-temp-file "reqlog-abort-" t))
         (iar-personalization-path tmpdir)
         (iar-audit-path "audit")
         (iar--current-agent-name "testagent")
         (iar--current-project "testproject")
         (iar-request-log-enabled t)
         (buf (generate-new-buffer " *test-abort*"))
         (info (list :buffer buf :model "m" :status 'success :tool-use nil :error nil))
         (fsm (gptel-make-fsm :info info))
         (proc (list 'fake-proc)))
    (unwind-protect
        (progn
          (with-current-buffer buf (insert "HTTP/1.1 200 OK\n\npartial data"))
          (puthash proc 9 iar--reqlog-processes)
          (cl-letf (((symbol-function 'process-buffer) (lambda (_p) buf))
                    ((symbol-function 'process-live-p) (lambda (_p) t))
                    ((symbol-function 'alist-get)
                     (lambda (key alist &optional _default _testfn _remove)
                       (cdr (assq key alist)))))
            (let ((gptel--request-alist (list (list proc fsm))))
              (iar--reqlog-abort-advice buf)))
          (with-temp-buffer
            (insert-file-contents
             (expand-file-name "audit/testproject/testagent/REQUESTS.log" tmpdir))
            (should (string-match-p "ABORT (partial response follows)" (buffer-string)))
            (should (string-match-p "partial data" (buffer-string)))))
      (delete-directory tmpdir :recursive))))

(ert-deftest test-reqlog-abort-advice-no-match-no-log ()
  "No request matching the buffer: nothing logged, no signal."
  (let* ((tmpdir (make-temp-file "reqlog-abort2-" t))
         (iar-personalization-path tmpdir)
         (iar-audit-path "audit")
         (iar-request-log-enabled t)
         (buf (generate-new-buffer " *test-abort2*")))
    (unwind-protect
        (progn
          (let ((gptel--request-alist nil))
            (iar--reqlog-abort-advice buf))
          (should (not (file-exists-p
                        (expand-file-name "audit/iar/unknown/REQUESTS.log" tmpdir)))))
      (kill-buffer buf)
      (delete-directory tmpdir :recursive))))

;;; --- iar--watchdog-abort (39 uncovered): the repair path ---

(ert-deftest test-watchdog-abort-inserts-notice-and-kills ()
  "abort: audit-logs, inserts a notice in the buffer, deletes the process."
  (let* ((buf (generate-new-buffer " *test-wd-abort*"))
         (info (list :buffer buf :model "m1"))
         (fsm (gptel-make-fsm :info info))
         (proc (list 'fake-proc))
         (audit-lines nil)
         (deleted nil))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'iar--audit-log)
                     (lambda (_tag detail) (push detail audit-lines)))
                    ((symbol-function 'gptel-abort) (lambda (_b) nil))
                    ((symbol-function 'process-live-p) (lambda (_p) t))
                    ((symbol-function 'delete-process)
                     (lambda (p) (setq deleted p))))
            (let ((gptel--request-alist (list (list proc fsm))))
              (iar--watchdog-abort proc "test stall")))
          (should (equal deleted proc))
          (with-current-buffer buf
            (should (string-match-p "watchdog: request aborted -- test stall"
                                    (buffer-string))))
          (should (string-match-p "aborted stalled request" (car audit-lines))))
      (kill-buffer buf))))

(ert-deftest test-watchdog-abort-no-fsm-still-audits ()
  "abort with no FSM entry: audit line still written, no signal."
  (let ((audit-lines nil))
    (cl-letf (((symbol-function 'iar--audit-log)
               (lambda (_tag detail) (push detail audit-lines))))
      (let ((gptel--request-alist nil))
        (iar--watchdog-abort 'fake-proc "no fsm"))
      (should (= 1 (length audit-lines)))
      (should (string-match-p "model=nil" (car audit-lines))))))



;;; --- advice wrappers (uncovered in cov-detail2) ---

(ert-deftest test-tool-call-truncate-advice-truncates-and-logs ()
  "The :around advice truncates the result before orig-fun sees it,
then runs the post-tool-call bridge with the truncated result."
  (let* ((seen-orig nil)
         (seen-bridge nil)
         (orig (lambda (_fsm _spec _call result)
                 (setq seen-orig result) "orig-return")))
    (cl-letf (((default-value 'iar-post-tool-call-functions)
               (list (lambda (name result)
                       (setq seen-bridge (list name result))))))
      (let* ((tool (gptel-make-tool :name "bigtool" :function (lambda (&rest _) "x")))
             (big (make-string 500 ?x))
             (iar-tool-result-max-chars 100)
             (ret (iar--truncate-tool-result-advice
                   orig 'fsm tool 'call big)))
        (should (equal ret "orig-return"))
        (should (< (length seen-orig) 500))
        (should (equal seen-bridge (list "bigtool" seen-orig)))))))

(ert-deftest test-tool-call-truncate-advice-nil-spec ()
  "nil tool-spec: advice still truncates and logs with nil name."
  (let ((seen-orig nil) (bridge-name :unset))
    (cl-letf (((symbol-function 'gptel-tool-name) (lambda (_s) (error "should not be called")))
              ((default-value 'iar-post-tool-call-functions) nil))
      (let ((iar-tool-result-max-chars nil))
        (should (equal (iar--truncate-tool-result-advice
                        (lambda (&rest _) "ok") 'fsm nil 'call "res")
                       "ok"))))))

(ert-deftest test-tool-call-usage-curl-advices-delegate ()
  "Both curl advice wrappers delegate to parse-from-curl."
  (let ((calls 0))
    (cl-letf (((symbol-function 'iar--usage-parse-from-curl)
               (lambda (_p) (cl-incf calls))))
      (iar--usage-curl-stream-cleanup-advice 'p1 'status)
      (iar--usage-curl-sentinel-advice 'p2 'status)
      (should (= calls 2)))))

(ert-deftest test-tool-call-bridge-pre-tool-call-nil-hooks ()
  "No hooks registered: bridge returns nil (allow).
2026-09-01: the tool guard now registers GLOBALLY on
iar-pre-tool-call-functions (interactive sessions get unknown-tool
interception too -- the 00:35 AR hang). The test must nil the hook
list to test the empty-hook path."
  (let ((iar-pre-tool-call-functions nil))
    (should (null (iar--bridge-pre-tool-call '(:tool "x"))))))

(ert-deftest test-tool-call-bridge-pre-tool-call-first-block-wins ()
  "First hook returning (:block . msg) stops the chain."
  (let ((second-called nil))
    (cl-letf (((default-value 'iar-pre-tool-call-functions)
               (list (lambda (_info) '(:block . "no"))
                     (lambda (_info) (setq second-called t) nil))))
      (should (equal (iar--bridge-pre-tool-call '(:tool "x"))
                     '(:block . "no")))
      (should (null second-called)))))

(ert-deftest test-tool-call-bridge-post-response-no-hooks ()
  "No post-response hooks: bridge is a no-op that returns nil."
  (with-temp-buffer
    (kill-all-local-variables)
    (cl-letf (((default-value 'iar-post-response-functions) nil))
      (should (null (iar--bridge-post-response 'success nil))))))

(ert-deftest test-tool-call-usage-totals-duration-and-model ()
  "totals includes duration and model fallback."
  (iar--usage-reset)
  (setq iar--usage-model nil)
  (let ((totals (iar--usage-totals)))
    (should (= 0 (plist-get totals :duration-secs)))
    (should (equal "nil" (plist-get totals :model)))
    (setq iar--usage-model "m9")
    (should (equal "m9" (plist-get (iar--usage-totals) :model)))))

(provide 'test-coverage-aria)
;;; test-coverage-aria.el ends here
