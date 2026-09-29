;; -*- lexical-binding: t; -*-

;;; Tests for iar-content-shape.el (the c546 truncated-write class)
;;
;; The c546 forensics: a nemotron write_roadmap emitted a truncated
;; document (ends mid-sentence, line count collapsed 172->132) with a
;; legal stop=stop. The content-shape check catches the WRITTEN FILE's
;; shape at the tool layer. These tests pin the three signals:
;; 1. missing trailing newline (mid-line end)
;; 2. mid-sentence last line heuristic
;; 3. implausible line-count collapse vs the existing file
;;
;; c547 test-design note: the first draft of the "clean write" tests
;; used a 3-line replacement against a 20-line fixture -- which the
;; check CORRECTLY flags as a collapse. The tests now use realistic
;; shapes: a clean rewrite keeps most of the file, a truncated write
;; loses >30%.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-content-shape)

;;; --- Fixtures ---

(defvar test-content-shape--tmpdir nil
  "Temporary directory for content-shape tests.")

(defmacro with-content-shape-fixture (&rest body)
  "Run BODY with a fresh temp directory."
  (declare (indent 0))
  `(unwind-protect
       (progn
         (setq test-content-shape--tmpdir
               (make-temp-file "test-shape-" :dir-flag))
         ,@body)
     (when (and test-content-shape--tmpdir
                (file-exists-p test-content-shape--tmpdir))
       (delete-directory test-content-shape--tmpdir t)
       (setq test-content-shape--tmpdir nil))))

(defun test-content-shape--write-old (lines)
  "Write LINES (a list of strings) to old.org in the fixture dir."
  (let ((path (expand-file-name "old.org" test-content-shape--tmpdir)))
    (with-temp-file path
      (dolist (l lines) (insert l "\n")))
    path))

;;; --- ends-complete ---

(ert-deftest test-content-shape-ends-complete-newline ()
  "Content ending in a newline is complete."
  (should (iar--content-shape--ends-complete "line1\nline2\n")))

(ert-deftest test-content-shape-ends-complete-empty ()
  "Empty content is exempt (write_file supports empty files)."
  (should (iar--content-shape--ends-complete "")))

(ert-deftest test-content-shape-ends-midline ()
  "Content NOT ending in a newline is the truncation signature."
  (should-not (iar--content-shape--ends-complete "line1\nline2")))

;;; --- mid-sentence tail ---

(ert-deftest test-content-shape-mid-sentence-detected ()
  "A long unpunctuated last line is flagged."
  (should (iar--content-shape--mid-sentence-tail
           "* Header\n\nSome complete text here.\nAnd a long trailing line that just keeps going without any terminal punctuation mark")))

(ert-deftest test-content-shape-mid-sentence-clean-period ()
  "A long last line ending in a period is clean."
  (should-not (iar--content-shape--mid-sentence-tail
           "* Header\n\nSome complete text here.\nAnd a long trailing line that ends with a proper terminal punctuation mark.")))

(ert-deftest test-content-shape-mid-sentence-org-structure-exempt ()
  "Org structure lines (headings, list items, tables) are exempt."
  (should-not (iar--content-shape--mid-sentence-tail
           "text.\n* A heading that is quite long and has no terminal punctuation on it at all"))
  (should-not (iar--content-shape--mid-sentence-tail
           "text.\n- A list item that is quite long and has no terminal punctuation on it at all"))
  (should-not (iar--content-shape--mid-sentence-tail
           "text.\n| a | table | row | that is long and has no terminal punctuation at all here |")))

(ert-deftest test-content-shape-mid-sentence-short-line-exempt ()
  "Short last lines are exempt (the >60 char gate)."
  (should-not (iar--content-shape--mid-sentence-tail "text.\nshort line")))

;;; --- full check: the three signals ---

(ert-deftest test-content-shape-check-clean-write ()
  "A clean full-file rewrite (same scale) produces no warning."
  (with-content-shape-fixture
    (let ((path (test-content-shape--write-old
                 (make-list 20 "existing filler line here."))))
      (should-not (iar--content-shape--check
                   (concat (string-join (make-list 18 "* New roadmap section with complete content.") "\n") "\n")
                   path)))))

(ert-deftest test-content-shape-check-midline-write ()
  "A write ending mid-line warns (signal 1)."
  (with-content-shape-fixture
    (let ((path (test-content-shape--write-old
                 (make-list 20 "existing filler line here."))))
      (should (string-match-p "does not end with a newline"
                              (iar--content-shape--check
                               "* New roadmap\n\nComplete content but cut of" path))))))

(ert-deftest test-content-shape-check-collapse-write ()
  "A write collapsing line count >30% warns (signal 3)."
  (with-content-shape-fixture
    (let ((path (test-content-shape--write-old
                 (make-list 100 "existing filler line here."))))
      (let ((warning (iar--content-shape--check
                      "* New roadmap\n\nShort content.\n" path)))
        (should (stringp warning))
        (should (string-match-p "collapsed 100 -> 3" warning))))))

(ert-deftest test-content-shape-check-rewrite-shrink-ok ()
  "A legitimate big rewrite (20% loss, under the 30% gate) does not
warn on collapse."
  (with-content-shape-fixture
    (let ((path (test-content-shape--write-old
                 (make-list 100 "existing filler line here."))))
      ;; 80 new lines = 20% loss, under the 30% gate
      (should-not (iar--content-shape--check
                   (concat (string-join (make-list 80 "x") "\n") "\n") path)))))

(ert-deftest test-content-shape-check-small-file-exempt ()
  "Files under iar-content-shape-min-lines are exempt from collapse."
  (with-content-shape-fixture
    (let ((path (test-content-shape--write-old '("one" "two" "three"))))
      (should-not (iar--content-shape--check "single\n" path)))))

(ert-deftest test-content-shape-check-new-file-no-collapse ()
  "A write to a nonexistent path cannot collapse (no old file)."
  (with-content-shape-fixture
    (should-not (iar--content-shape--check
                 "* Fresh roadmap\n\nContent.\n"
                 (expand-file-name "nonexistent.org" test-content-shape--tmpdir)))))

(ert-deftest test-content-shape-check-empty-content-exempt ()
  "Empty content: the mid-line signal must NOT fire (string-empty-p
exempt) and collapse may warn -- but empty writes are legal
(progress-guard fixed-point class), so collapse on empty is still
reported; this test pins that empty content does not crash."
  (with-content-shape-fixture
    (let ((path (test-content-shape--write-old
                 (make-list 20 "existing filler line here."))))
      (should (stringp (iar--content-shape--check "" path))))))

(provide 'test-content-shape)