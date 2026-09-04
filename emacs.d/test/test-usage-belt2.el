;; -*- lexical-binding: t; -*-
;; Belt #2 tests (continuo cycle 55): iar--usage-write-log-now.
;; The pre-exit usage write (c54, a7e1cf5) had no direct tests: the
;; orphan-write race fix was production-observed but never pinned by
;; the suite. These tests pin: (1) it returns t on success and writes
;; the line, (2) it never signals when the write path is broken
;; (exit path must not break), (3) it is idempotent in effect with
;; the kill-emacs-hook write (two calls = two lines, both parseable).

(require 'ert)

(ert-deftest test-tool-call-usage-write-log-now-writes-line ()
  "Pre-exit write returns t and appends a summary line."
  (let* ((tmpdir (make-temp-file "usage-now-" t))
         (iar-personalization-path tmpdir)
         (iar-audit-path "audit")
         (iar--current-agent-name "testagent")
         (iar--current-project "testproject"))
    (unwind-protect
        (progn
          (iar--usage-reset)
          (setq iar--usage-requests 5
                iar--usage-input-tokens 200
                iar--usage-output-tokens 80
                iar--usage-model "test-model")
          (should (eq (iar--usage-write-log-now) t))
          (let ((path (expand-file-name
                       "audit/testproject/testagent/USAGE.log" tmpdir)))
            (should (file-exists-p path))
            (with-temp-buffer
              (insert-file-contents path)
              (should (string-match-p "requests=5 " (buffer-string)))
              (should (string-match-p "input=200 " (buffer-string)))
              (should (string-match-p "output=80 " (buffer-string)))
              (should (string-match-p "model=test-model" (buffer-string))))))
      (delete-directory tmpdir :recursive))))

(ert-deftest test-tool-call-usage-write-log-now-never-signals ()
  "Broken write path: returns nil, does NOT signal (exit path safe)."
  (let* ((tmpdir (make-temp-file "usage-now-" t))
         (iar-personalization-path tmpdir)
         (iar-audit-path "audit")
         (iar--current-agent-name "testagent")
         (iar--current-project "testproject")
         (path (expand-file-name
                "audit/testproject/testagent/USAGE.log" tmpdir)))
    (unwind-protect
        (progn
          (iar--usage-reset)
          ;; Make the write fail: USAGE.log exists as a DIRECTORY, so
          ;; append-to-file signals. write-log-now must catch it.
          (make-directory (file-name-directory path) t)
          (make-directory path)
          (should (eq (iar--usage-write-log-now) nil))
          (should (file-directory-p path)))
      (delete-directory tmpdir :recursive))))

(ert-deftest test-tool-call-usage-write-log-now-idempotent-with-hook ()
  "Two writes (pre-exit + hook net) = two lines, both parseable."
  (let* ((tmpdir (make-temp-file "usage-now-" t))
         (iar-personalization-path tmpdir)
         (iar-audit-path "audit")
         (iar--current-agent-name "testagent")
         (iar--current-project "testproject"))
    (unwind-protect
        (progn
          (iar--usage-reset)
          (iar--usage-write-log-now)
          (iar--usage-write-log)        ; the kill-emacs-hook net
          (with-temp-buffer
            (insert-file-contents
             (expand-file-name "audit/testproject/testagent/USAGE.log" tmpdir))
            (should (equal (count-lines (point-min) (point-max)) 2))
            ;; Both lines carry the full field set (newline guard holds).
            (goto-char (point-min))
            (should (looking-at "^\\[.*\\] requests=[0-9]+ input=[0-9]+ output=[0-9]+ total=[0-9]+ model="))
            (forward-line 1)
            (should (looking-at "^\\[.*\\] requests=[0-9]+ input=[0-9]+ output=[0-9]+ total=[0-9]+ model="))))
      (delete-directory tmpdir :recursive))))

(ert-deftest test-tool-call-usage-write-log-now-glued-file-safe ()
  "Unterminated existing file: the newline guard fires, no glue."
  (let* ((tmpdir (make-temp-file "usage-now-" t))
         (iar-personalization-path tmpdir)
         (iar-audit-path "audit")
         (iar--current-agent-name "testagent")
         (iar--current-project "testproject")
         (dir (expand-file-name "audit/testproject/testagent" tmpdir)))
    (unwind-protect
        (progn
          (make-directory dir t)
          (let ((path (expand-file-name "USAGE.log" dir)))
            (with-temp-file path (insert "[old] requests=1 input=1 output=1 total=2 model=m"))
            (iar--usage-reset)
            (iar--usage-write-log-now)
            (with-temp-buffer
              (insert-file-contents path)
              ;; The old line is intact on its own line; the new line
              ;; starts fresh, not glued onto "model=m".
              (goto-char (point-min))
              (should (looking-at "^\\[old\\] requests=1"))
              (forward-line 1)
              (should (looking-at "^\\["))))
      (delete-directory tmpdir :recursive)))))
