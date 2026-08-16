;; -*- lexical-binding: t; -*-

;;; Tests for iar-utils.el
;; Tests shared utility functions.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-utils)

;;; --- iar--get-agent-name tests ---

(ert-deftest test-utils-get-agent-name-from-local ()
  "Should return buffer-local agent name when set."
  (with-temp-buffer
    (setq-local iar--current-agent-name "test-agent")
    (should (string= "test-agent" (iar--get-agent-name)))))

(ert-deftest test-utils-get-agent-name-from-global ()
  "Should return global default when no buffer-local value."
  (with-temp-buffer
    (let ((iar--current-agent-name "global-agent"))
      (should (string= "global-agent" (iar--get-agent-name))))))

(ert-deftest test-utils-get-agent-name-nil-both ()
  "Should return nil when neither local nor global is set."
  (with-temp-buffer
    (let ((iar--current-agent-name nil))
      (should (null (iar--get-agent-name))))))

(ert-deftest test-utils-get-agent-name-from-file ()
  "Should derive name from agent-file when name is nil."
  (with-temp-buffer
    (let ((iar--current-agent-name nil)
          (iar--current-agent-file "/some/path/darwin/agent.org"))
      (should (string= "darwin" (iar--get-agent-name))))))

(ert-deftest test-utils-get-agent-name-from-file-global ()
  "Should derive name from global agent-file when local is nil."
  (with-temp-buffer
    (let ((iar--current-agent-name nil)
          (iar--current-agent-file nil))
      (setq-default iar--current-agent-file "/path/mirror/agent.org")
      (should (string= "mirror" (iar--get-agent-name)))
      (setq-default iar--current-agent-file nil))))

(ert-deftest test-utils-get-agent-name-unbound ()
  "Should return nil when variables are unbound."
  (with-temp-buffer
    (let ((iar--current-agent-name nil)
          (iar--current-agent-file nil))
      (should (null (iar--get-agent-name))))))

;;; --- iar--non-blank-p tests ---

(ert-deftest test-utils-non-blank-p-normal ()
  "Should return non-nil for non-blank string."
  (should (iar--non-blank-p "hello")))

(ert-deftest test-utils-non-blank-p-empty ()
  "Should return nil for empty string."
  (should-not (iar--non-blank-p "")))

(ert-deftest test-utils-non-blank-p-whitespace ()
  "Should return nil for whitespace-only string."
  (should-not (iar--non-blank-p "   \n\t  ")))

(ert-deftest test-utils-non-blank-p-nil ()
  "Should return nil for nil."
  (should-not (iar--non-blank-p nil)))

(ert-deftest test-utils-non-blank-p-non-string ()
  "Should return nil for non-string."
  (should-not (iar--non-blank-p 42)))

;;; --- iar--path-traversal-check tests ---

(ert-deftest test-utils-path-traversal-safe ()
  "Should return path when it's within base-dir."
  (let* ((base (make-temp-file "test-trav-" :dir-flag))
         (file (expand-file-name "test.txt" base)))
    (unwind-protect
        (should (string= file (iar--path-traversal-check file base)))
      (delete-directory base t))))

(ert-deftest test-utils-path-traversal-blocked ()
  "Should signal error when path escapes base-dir."
  (let* ((base (make-temp-file "test-trav-" :dir-flag))
         (outside (make-temp-file "test-trav-outside-" :dir-flag)))
    (unwind-protect
        (let ((file (expand-file-name "test.txt" outside)))
          (should-error (iar--path-traversal-check file base)
                        :type 'error))
      (delete-directory base t)
      (delete-directory outside t))))

(ert-deftest test-utils-path-traversal-nonexistent-fallback ()
  "Should use expanded path when file-truename fails (file doesn't exist yet)."
  (let* ((base (make-temp-file "test-trav-" :dir-flag))
         (file (expand-file-name "newfile.txt" base)))
    (unwind-protect
        ;; file doesn't exist yet, file-truename falls back to expanded path
        (should (string= file (iar--path-traversal-check file base)))
      (delete-directory base t))))

;;; --- iar--read-file-string tests ---

(ert-deftest test-utils-read-file-string-existing ()
  "Should return trimmed content for existing file."
  (let ((tmpfile (make-temp-file "test-read-")))
    (unwind-protect
        (progn
          (with-temp-file tmpfile
            (insert "  hello world  \n\n"))
          (should (string= "hello world" (iar--read-file-string tmpfile))))
      (delete-file tmpfile))))

(ert-deftest test-utils-read-file-string-nonexistent ()
  "Should return nil for nonexistent file."
  (should (null (iar--read-file-string "/nonexistent/path/to/file.txt"))))

;;; --- iar--read-description-org tests ---

(ert-deftest test-utils-read-description-org-existing ()
  "Should return content when description.org exists."
  (let ((tmpdir (make-temp-file "test-desc-" :dir-flag)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "description.org" tmpdir)
            (insert "Test task description\n"))
          (should (string= "Test task description"
                           (iar--read-description-org tmpdir))))
      (delete-directory tmpdir t))))

(ert-deftest test-utils-read-description-org-missing ()
  "Should return nil when description.org does not exist."
  (let ((tmpdir (make-temp-file "test-desc-" :dir-flag)))
    (unwind-protect
        (should (null (iar--read-description-org tmpdir)))
      (delete-directory tmpdir t))))

;;; --- iar--dirs-with-description tests ---

(ert-deftest test-utils-dirs-with-description ()
  "Should return sorted list of subdirs containing description.org."
  (let ((tmpdir (make-temp-file "test-dirs-" :dir-flag)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "zebra" tmpdir) t)
          (make-directory (expand-file-name "alpha" tmpdir) t)
          (make-directory (expand-file-name ".hidden" tmpdir) t)
          (with-temp-file (expand-file-name "zebra/description.org" tmpdir)
            (insert "zebra task\n"))
          (with-temp-file (expand-file-name "alpha/description.org" tmpdir)
            (insert "alpha task\n"))
          ;; .hidden should be excluded (starts with .)
          ;; A subdir without description.org should be excluded
          (make-directory (expand-file-name "no-desc" tmpdir) t)
          (let ((result (iar--dirs-with-description tmpdir)))
            (should (= 2 (length result)))
            (should (or (string-match-p "alpha" (nth 0 result))
                        (string-match-p "alpha" (nth 1 result))))
            (should (or (string-match-p "zebra" (nth 0 result))
                        (string-match-p "zebra" (nth 1 result))))))
      (delete-directory tmpdir t))))

(ert-deftest test-utils-dirs-with-description-empty ()
  "Should return nil for directory with no subdirs."
  (let ((tmpdir (make-temp-file "test-dirs-" :dir-flag)))
    (unwind-protect
        (should (null (iar--dirs-with-description tmpdir)))
      (delete-directory tmpdir t))))

(ert-deftest test-utils-dirs-with-description-nonexistent ()
  "Should return nil for nonexistent directory."
  (should (null (iar--dirs-with-description "/nonexistent/path/"))))

;;; --- iar--approx-token-count tests ---

(ert-deftest test-utils-approx-token-count-normal ()
  "Should return chars/4 for positive input."
  (should (= 250 (iar--approx-token-count 1000))))

(ert-deftest test-utils-approx-token-count-zero ()
  "Should return 0 for zero."
  (should (= 0 (iar--approx-token-count 0))))

(ert-deftest test-utils-approx-token-count-negative ()
  "Should return 0 for negative."
  (should (= 0 (iar--approx-token-count -100))))

(ert-deftest test-utils-approx-token-count-nil ()
  "Should return 0 for nil."
  (should (= 0 (iar--approx-token-count nil))))

;;; --- iar--with-suppressed-save-hooks tests ---

(ert-deftest test-utils-with-suppressed-save-hooks ()
  "Should execute body with save hooks bound to nil."
  (let ((before-save-hook '(my-format-on-save))
        (after-save-hook '(my-after-save))
        (write-file-functions '(my-write-hook))
        (write-contents-functions '(my-write-contents))
        (write-region-annotate-functions '(my-annotate)))
    (iar--with-suppressed-save-hooks
     (should (null before-save-hook))
     (should (null after-save-hook))
     (should (null write-file-functions))
     (should (null write-contents-functions))
     (should (null write-region-annotate-functions)))
    ;; Hooks should be restored after
    (should (eq 'my-format-on-save (car before-save-hook)))))

(provide 'test-utils)
;;; test-utils.el ends here
