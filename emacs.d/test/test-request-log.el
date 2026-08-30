;; -*- lexical-binding: t; -*-

;;; Tests for Track A4 (request log -- the witness)
;; Pure-function tests: no live processes, no timers, no network.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'json)

(require 'iar-request-log)

;;; --- cap ---

(ert-deftest test-reqlog-cap-short-string-unchanged ()
  "Short string with a cap: returned unchanged."
  (should (equal (iar--reqlog-cap "hello" 100) "hello")))

(ert-deftest test-reqlog-cap-long-string-truncated ()
  "Long string with a cap: truncated with omission marker."
  (let* ((s (make-string 500 ?x))
         (out (iar--reqlog-cap s 100)))
    (should (< (length out) 130))
    (should (string-match-p "\\.\\.\\.\\[\\+420 chars\\]" out))))

(ert-deftest test-reqlog-cap-nil-n-disables ()
  "nil cap: string returned unchanged regardless of length."
  (let ((s (make-string 5000 ?x)))
    (should (equal (iar--reqlog-cap s nil) s))))

(ert-deftest test-reqlog-cap-non-string-unchanged ()
  "Non-string input: returned as-is."
  (should (equal (iar--reqlog-cap 42 100) 42))
  (should (null (iar--reqlog-cap nil 100))))

(ert-deftest test-reqlog-cap-exact-length ()
  "String exactly at the cap: unchanged (no marker)."
  (let ((s (make-string 100 ?x)))
    (should (equal (iar--reqlog-cap s 100) s))))

;;; --- payload tail ---

(ert-deftest test-reqlog-payload-tail-nil-messages ()
  "nil / empty messages: the string \"nil\"."
  (should (equal (iar--reqlog-payload-tail nil) "nil"))
  (should (equal (iar--reqlog-payload-tail (vector)) "nil")))

(ert-deftest test-reqlog-payload-tail-two-messages ()
  "Two messages: both serialized."
  (let* ((msgs (vector (list :role "user" :content "hi")
                       (list :role "assistant" :content "there")))
         (out (iar--reqlog-payload-tail msgs)))
    (should (stringp out))
    (should (string-match-p "hi" out))
    (should (string-match-p "there" out))))

(ert-deftest test-reqlog-payload-tail-five-messages-keeps-last-two ()
  "Five messages: only the last two serialized."
  (let* ((msgs (vector (list :role "user" :content "m1")
                       (list :role "assistant" :content "m2")
                       (list :role "user" :content "m3")
                       (list :role "assistant" :content "m4")
                       (list :role "user" :content "m5")))
         (out (iar--reqlog-payload-tail msgs)))
    (should (string-match-p "m5" out))
    (should (string-match-p "m4" out))
    (should (not (string-match-p "m1" out)))))

(ert-deftest test-reqlog-payload-tail-capped ()
  "Tail respects the cap when set."
  (let ((iar-request-log-tail-chars 50))
    (let* ((msgs (vector (list :role "user" :content
                               (make-string 5000 ?x))))
           (out (iar--reqlog-payload-tail msgs)))
      (should (stringp out))
      (should (< (length out) 100)))))

(ert-deftest test-reqlog-payload-tail-unserializable ()
  "Degenerate message content: returns \"unserializable\", no signal."
  (let* ((msgs (vector (list :role "user" :content
                             (make-symbol "weird"))))
         (out (iar--reqlog-payload-tail msgs)))
    (should (stringp out))
    (should (member out '("unserializable" "nil")))))

;;; --- tool specs ---

(ert-deftest test-reqlog-tool-specs-none ()
  "nil tool-use: \"none\"."
  (should (equal (iar--reqlog-tool-specs nil) "none")))

(ert-deftest test-reqlog-tool-specs-well-formed ()
  "Well-formed specs: name(args) format."
  (let* ((specs (list (list :name "read_file"
                            :args (list :filepath "/tmp/x")))))
    (should (equal (iar--reqlog-tool-specs specs)
                   "read_file((:filepath \"/tmp/x\"))"))))

(ert-deftest test-reqlog-tool-specs-multiple ()
  "Multiple specs: space-separated."
  (let* ((specs (list (list :name "a" :args nil)
                      (list :name "b" :args (list :k "v")))))
    (should (equal (iar--reqlog-tool-specs specs)
                   "a(nil) b((:k \"v\"))"))))

(ert-deftest test-reqlog-tool-specs-degenerate-no-signal ()
  "Degenerate specs (non-plist, missing name): tolerated, no signal."
  (let ((out (iar--reqlog-tool-specs (list "raw-string" 42))))
    (should (stringp out))
    (should (string-match-p "?" out))))

(ert-deftest test-reqlog-tool-specs-malformed-marker ()
  "A2b sanitizer output shape: name=malformed_tool_call, args nil."
  (let* ((specs (list (list :name "malformed_tool_call" :args nil))))
    (should (equal (iar--reqlog-tool-specs specs)
                   "malformed_tool_call(nil)"))))

(ert-deftest test-reqlog-tool-specs-long-args-capped ()
  "Very long args: capped at 300 chars per spec."
  (let* ((specs (list (list :name "execute_code_local"
                            :args (list :command (make-string 5000 ?x))))))
    (let ((out (iar--reqlog-tool-specs specs)))
      (should (< (length out) 1100))
      (should (string-match-p "execute_code_local" out)))))

;;; --- log path ---

(ert-deftest test-reqlog-path-shape ()
  "Log path lands in audit/<project>/<agent>/REQUESTS.log."
  (let ((path (iar--reqlog-path)))
    (should (string-match-p "REQUESTS\\.log\\'" path))
    (should (string-match-p "audit" path))))

;;; --- append + rotation (filesystem, temp dirs) ---

(ert-deftest test-reqlog-append-writes-sanitized-line ()
  "Append writes a single line with escaped newlines."
  (let* ((tmpdir (make-temp-file "reqlog-test-" t))
         (iar-personalization-path tmpdir)
         (iar-audit-path "audit")
         (iar--current-agent-name "testagent")
         (iar--current-project "testproject"))
    (unwind-protect
        (progn
          (iar--reqlog-append "REQ %d TEST %s" 1 "line1\nline2")
          (let ((path (expand-file-name
                       "audit/testproject/testagent/REQUESTS.log" tmpdir)))
            (should (file-exists-p path))
            (with-temp-buffer
              (insert-file-contents path)
              ;; one physical line: newline escaped by sanitizer
              (should (equal (count-lines (point-min) (point-max)) 1))
              (should (string-match-p "line1\\\\nline2" (buffer-string))))))
      (delete-directory tmpdir :recursive))))

(ert-deftest test-reqlog-append-disabled-module-still-writes ()
  "iar--reqlog-append itself is unconditional (advice gates on
iar-request-log-enabled); direct calls write regardless."
  (let* ((tmpdir (make-temp-file "reqlog-test-" t))
         (iar-personalization-path tmpdir)
         (iar-audit-path "audit")
         (iar--current-agent-name "testagent")
         (iar--current-project "testproject"))
    (unwind-protect
        (progn
          (iar--reqlog-append "REQ %d TEST" 2)
          (should (file-exists-p
                   (expand-file-name
                    "audit/testproject/testagent/REQUESTS.log" tmpdir))))
      (delete-directory tmpdir :recursive))))

(ert-deftest test-reqlog-rotation ()
  "Log exceeding max-size rotates to .1."
  (let* ((tmpdir (make-temp-file "reqlog-test-" t))
         (iar-personalization-path tmpdir)
         (iar-audit-path "audit")
         (iar--current-agent-name "testagent")
         (iar--current-project "testproject")
         (iar-request-log-max-size 100))
    (unwind-protect
        (progn
          ;; First entry: small file
          (iar--reqlog-append "REQ 1 small entry")
          (should (file-exists-p
                   (expand-file-name
                    "audit/testproject/testagent/REQUESTS.log" tmpdir)))
          ;; Second entry: file now exceeds 100 bytes (rotation check
          ;; runs BEFORE the write, so this write lands in the big file)
          (iar--reqlog-append "REQ 2 %s" (make-string 300 ?y))
          ;; Third entry: rotation check sees the oversized file ->
          ;; rotates to .1, then writes fresh
          (iar--reqlog-append "REQ 3 after rotation")
          (let ((rotated (expand-file-name
                          "audit/testproject/testagent/REQUESTS.log.1" tmpdir))
                (fresh (expand-file-name
                        "audit/testproject/testagent/REQUESTS.log" tmpdir)))
            (should (file-exists-p rotated))
            (should (file-exists-p fresh))
            ;; rotated file contains entries 1 and 2
            (with-temp-buffer
              (insert-file-contents rotated)
              (should (string-match-p "REQ 1" (buffer-string)))
              (should (string-match-p "REQ 2" (buffer-string))))
            ;; fresh file has only the new entry
            (with-temp-buffer
              (insert-file-contents fresh)
              (should (string-match-p "REQ 3" (buffer-string)))
              (should (not (string-match-p "REQ 1" (buffer-string)))))))
      (delete-directory tmpdir :recursive))))

(ert-deftest test-reqlog-rotation-disabled ()
  "nil max-size: no rotation ever."
  (let* ((tmpdir (make-temp-file "reqlog-test-" t))
         (iar-personalization-path tmpdir)
         (iar-audit-path "audit")
         (iar--current-agent-name "testagent")
         (iar--current-project "testproject")
         (iar-request-log-max-size nil))
    (unwind-protect
        (progn
          (iar--reqlog-append "REQ 1 %s" (make-string 300 ?y))
          (iar--reqlog-append "REQ 2 %s" (make-string 300 ?y))
          (should (not (file-exists-p
                        (expand-file-name
                         "audit/testproject/testagent/REQUESTS.log.1"
                         tmpdir)))))
      (delete-directory tmpdir :recursive))))

;;; --- filter advice error-witnessing (pure part) ---

(ert-deftest test-reqlog-filter-advice-resignals ()
  "The :around filter advice re-signals errors after logging."
  (let* ((tmpdir (make-temp-file "reqlog-test-" t))
         (iar-personalization-path tmpdir)
         (iar-audit-path "audit")
         (iar--current-agent-name "testagent")
         (iar--current-project "testproject")
         (iar-request-log-enabled t)
         (orig (lambda (_p _o) (error "boom")))
         (fake-proc 'fake-proc))
    (unwind-protect
        (let ((signaled nil))
          (condition-case err
              (iar--reqlog-filter-advice orig fake-proc "chunk")
            (error (setq signaled (error-message-string err))))
          (should (equal signaled "boom"))
          ;; and the error was witnessed in the log
          (let ((path (expand-file-name
                       "audit/testproject/testagent/REQUESTS.log" tmpdir)))
            (should (file-exists-p path))
            (with-temp-buffer
              (insert-file-contents path)
              (should (string-match-p "FILTER-ERROR" (buffer-string)))
              (should (string-match-p "boom" (buffer-string)))
              (should (string-match-p "chunk" (buffer-string))))))
      (delete-directory tmpdir :recursive))))

(ert-deftest test-reqlog-filter-advice-passes-through ()
  "No error: advice returns the wrapped function's value."
  (let* ((tmpdir (make-temp-file "reqlog-test-" t))
         (iar-personalization-path tmpdir)
         (iar-audit-path "audit")
         (iar--current-agent-name "testagent")
         (iar--current-project "testproject")
         (iar-request-log-enabled t)
         (orig (lambda (_p _o) 'ok))
         (fake-proc 'fake-proc))
    (unwind-protect
        (should (eq (iar--reqlog-filter-advice orig fake-proc "chunk") 'ok))
      (delete-directory tmpdir :recursive))))

;;; --- setup idempotence ---

(ert-deftest test-reqlog-setup-idempotent ()
  "Running setup twice does not duplicate advice or signal."
  (should (progn (iar--reqlog-setup) (iar--reqlog-setup) t)))

(provide 'test-request-log)