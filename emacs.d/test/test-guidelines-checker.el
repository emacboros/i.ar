;; -*- lexical-binding: t; -*-

;;; Tests for iar-guidelines-checker.el
;; Tests individual check functions with known violation patterns.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-guidelines-checker)

;;; --- Helpers ---

(defun test-gc--write-temp-el (content)
  "Write CONTENT to a temp .el file and return the path."
  (let ((tmpfile (make-temp-file "test-gc-" nil ".el")))
    (with-temp-file tmpfile
      (insert content))
    tmpfile))

(defun test-gc--with-violations (content check-fn)
  "Run CHECK-FN on a temp file with CONTENT, return violations."
  (let ((tmpfile (test-gc--write-temp-el content))
        (iar--guidelines-violations nil))
    (unwind-protect
        (progn
          (funcall check-fn tmpfile)
          iar--guidelines-violations)
      (delete-file tmpfile))))

;;; --- iar--codebase-dir tests ---

(ert-deftest test-gc-codebase-dir ()
  "iar--codebase-dir should return init.d path."
  (let ((result (iar--codebase-dir)))
    (should (stringp result))
    (should (string-match-p "init.d" result))))

;;; --- iar--line-is-comment-p tests ---

(ert-deftest test-gc-line-is-comment-semicolon ()
  "Should detect semicolon comments."
  (should (iar--line-is-comment-p ";;; comment"))
  (should (iar--line-is-comment-p "  ;; comment"))
  (should (iar--line-is-comment-p "; comment")))

(ert-deftest test-gc-line-is-comment-not-comment ()
  "Should not detect non-comments."
  (should-not (iar--line-is-comment-p "(defun foo () 1)"))
  (should-not (iar--line-is-comment-p "  (message \"hello\")"))
  (should-not (iar--line-is-comment-p "")))

;;; --- iar--check-naming-prefixes tests ---

(ert-deftest test-gc-check-naming-clean ()
  "Should find no violations in clean file."
  (let ((violations (test-gc--with-violations
                     "(defun iar--foo () 1)\n(provide 'iar-foo)\n"
                     #'iar--check-naming-prefixes)))
    (should (null violations))))

(ert-deftest test-gc-check-naming-my-gptel ()
  "Should detect my-gptel-- prefix."
  (let ((violations (test-gc--with-violations
                     "(defun my-gptel--foo () 1)\n"
                     #'iar--check-naming-prefixes)))
    (should (= 1 (length violations)))
    (should (string-match-p "rule 1" (car violations)))))

(ert-deftest test-gc-check-naming-iar-mygptel ()
  "Should detect iar--mygptel-- prefix."
  (let ((violations (test-gc--with-violations
                     "(defun iar--mygptel--foo () 1)\n"
                     #'iar--check-naming-prefixes)))
    (should (= 1 (length violations)))
    (should (string-match-p "rule 1" (car violations)))))

;;; --- iar--check-provide-statement tests ---

(ert-deftest test-gc-check-provide-present ()
  "Should find no violation when provide exists."
  (let ((violations (test-gc--with-violations
                     "(defun foo () 1)\n(provide 'foo)\n"
                     #'iar--check-provide-statement)))
    (should (null violations))))

(ert-deftest test-gc-check-provide-missing ()
  "Should detect missing provide."
  (let ((violations (test-gc--with-violations
                     "(defun foo () 1)\n"
                     #'iar--check-provide-statement)))
    (should (= 1 (length violations)))
    (should (string-match-p "rule 9" (car violations)))))

;;; --- iar--check-provide-name-matches tests ---

(ert-deftest test-gc-check-provide-mismatch ()
  "Should detect provide name mismatch."
  (let ((tmpfile (test-gc--write-temp-el "(provide 'wrong-name)\n")))
    (unwind-protect
        (let ((iar--guidelines-violations nil))
          (iar--check-provide-name-matches tmpfile)
          (should (= 1 (length iar--guidelines-violations)))
          (should (string-match-p "rule 9" (car iar--guidelines-violations))))
      (delete-file tmpfile))))

;;; --- iar--check-temp-file-prefix tests ---

(ert-deftest test-gc-check-temp-prefix-clean ()
  "Should find no violation for iar- prefixed temp files."
  (let ((violations (test-gc--with-violations
                     "(let ((f (make-temp-file \"iar-test-\"))) f)\n"
                     #'iar--check-temp-file-prefix)))
    (should (null violations))))

(ert-deftest test-gc-check-temp-prefix-violation ()
  "Should detect non-iar- temp file prefix."
  (let ((violations (test-gc--with-violations
                     "(let ((f (make-temp-file \"test-\"))) f)\n"
                     #'iar--check-temp-file-prefix)))
    (should (= 1 (length violations)))
    (should (string-match-p "rule 4" (car violations)))))

;;; --- iar--check-anonymous-lambda-advice tests ---

(ert-deftest test-gc-check-lambda-advice-clean ()
  "Should find no violation for named function advice."
  (let ((violations (test-gc--with-violations
                     "(advice-add 'foo :around #'my-fn)\n"
                     #'iar--check-anonymous-lambda-advice)))
    (should (null violations))))

(ert-deftest test-gc-check-lambda-advice-violation ()
  "Should detect anonymous lambda in advice-add."
  (let ((violations (test-gc--with-violations
                     "(advice-add 'foo :around (lambda (x) x))\n"
                     #'iar--check-anonymous-lambda-advice)))
    (should (= 1 (length violations)))
    (should (string-match-p "rule 49" (car violations)))))

;;; --- iar--check-override-advice tests ---

(ert-deftest test-gc-check-override-clean ()
  "Should find no violation for :around advice."
  (let ((violations (test-gc--with-violations
                     "(advice-add 'foo :around #'my-fn)\n"
                     #'iar--check-override-advice)))
    (should (null violations))))

(ert-deftest test-gc-check-override-violation ()
  "Should detect :override advice."
  (let ((violations (test-gc--with-violations
                     "(advice-add 'foo :override #'my-fn)\n"
                     #'iar--check-override-advice)))
    (should (= 1 (length violations)))
    (should (string-match-p "rule 51" (car violations)))))

;;; --- iar--check-cl-return-from tests ---

(ert-deftest test-gc-check-cl-return-from-clean ()
  "Should find no violation when no cl-return-from."
  (let ((violations (test-gc--with-violations
                     "(defun foo () (cl-block bar 1))\n"
                     #'iar--check-cl-return-from)))
    (should (null violations))))

(ert-deftest test-gc-check-cl-return-from-violation ()
  "Should detect cl-return-from."
  (let ((violations (test-gc--with-violations
                     "(defun foo () (cl-return-from bar 1))\n"
                     #'iar--check-cl-return-from)))
    (should (>= (length violations) 1))
    (should (string-match-p "rule 48" (car violations)))))

;;; --- iar--check-hardcoded-personal-data tests ---

(ert-deftest test-gc-check-personal-data-clean ()
  "Should find no violation in clean file."
  (let ((violations (test-gc--with-violations
                     "(defun foo () (message \"hello\"))\n"
                     #'iar--check-hardcoded-personal-data)))
    (should (null violations))))

(ert-deftest test-gc-check-personal-data-violation ()
  "Should detect hardcoded personal data."
  (let ((violations (test-gc--with-violations
                     "(setq name \"Ignacio\")\n"
                     #'iar--check-hardcoded-personal-data)))
    (should (= 1 (length violations)))
    (should (string-match-p "rule 52" (car violations)))))

;;; --- iar--check-side-effects-let* tests ---

(ert-deftest test-gc-check-side-effects-clean ()
  "Should find no violation in clean file."
  (let ((violations (test-gc--with-violations
                     "(let* ((x 1) (y 2)) (+ x y))\n"
                     #'iar--check-side-effects-let*)))
    (should (null violations))))

(ert-deftest test-gc-check-side-effects-violation ()
  "Should detect side effects in let* bindings."
  (let ((violations (test-gc--with-violations
                     "(let* (_ (unless t (make-directory dir t))) 1)\n"
                     #'iar--check-side-effects-let*)))
    (should (= 1 (length violations)))
    (should (string-match-p "rule 47" (car violations)))))

;;; --- iar--all-elisp-files tests ---

(ert-deftest test-gc-all-elisp-files-returns-list ()
  "iar--all-elisp-files should return a list of .el files."
  (let ((files (iar--all-elisp-files)))
    (should (listp files))
    (should (> (length files) 0))))

;;; --- iar-check-guidelines tests ---

(ert-deftest test-gc-check-guidelines-returns-nil-when-clean ()
  "iar-check-guidelines should return nil when no violations."
  (let ((result (iar-check-guidelines)))
    (should (null result))))

(provide 'test-guidelines-checker)
;;; test-guidelines-checker.el ends here
