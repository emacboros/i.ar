;; -*- lexical-binding: t; -*-

;;; Tests for the write guard (relay 0084)
;; The write-back poison: a tool-result truncation notice written back
;; into a file as content. The guard refuses any write_file/append_file
;; content containing the notice skeleton.
;;
;; Disease-reproducing tests (law 39: the fixture must reproduce the
;; DISEASE, not the shape): each blocked-write test writes the EXACT
;; notice format iar--truncate-tool-result emits, with real numbers,
;; through the real iar--fs-write-file / iar--fs-append-file entry
;; points, and verifies the file on disk is UNCHANGED.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-tool--write-file)
(require 'iar-tool--append-file)

;;; --- Fixtures ---

(defvar test-wg--tmpdir nil)

(defun test-wg--setup ()
  (setq test-wg--tmpdir (make-temp-file "test-wg-" :dir-flag)))

(defun test-wg--teardown ()
  (when (and test-wg--tmpdir (file-exists-p test-wg--tmpdir))
    (delete-directory test-wg--tmpdir t)
    (setq test-wg--tmpdir nil)))

(defmacro with-wg-fixture (&rest body)
  `(unwind-protect (progn (test-wg--setup) ,@body)
     (test-wg--teardown)))

(defun test-wg--file-content (path)
  (with-temp-buffer
    (insert-file-contents path)
    (buffer-string)))

;;; --- Unit: iar--guard-check-content ---

(ert-deftest test-wg-content-guard-blocks-exact-notice ()
  "The exact notice shape iar--truncate-tool-result emits is refused."
  (let ((notice "\n[... truncated: 13719 total chars, kept first 5000 and last 5000 ...]\n"))
    (should (stringp (iar--guard-check-content (concat "head" notice "tail"))))
    ;; The reason must name the disease and the escape route.
    (should (string-match-p "truncat" (iar--guard-check-content (concat "head" notice))))))

(ert-deftest test-wg-content-guard-blocks-any-numbers ()
  "The skeleton matches regardless of the notice's numbers."
  (dolist (notice '("[... truncated: 1 total chars, kept first 0 and last 1 ...]"
                    "[... truncated: 999999 total chars, kept first 500000 and last 500000 ...]"
                    "[... truncated: 10000 total chars, kept first 5000 and last 5000 ...]"))
    (should (stringp (iar--guard-check-content notice)))))

(ert-deftest test-wg-content-guard-allows-clean-content ()
  "Ordinary content -- including bracket-heavy text -- passes."
  (should-not (iar--guard-check-content "hello world\n"))
  (should-not (iar--guard-check-content "[... truncated by hand ...]\n"))
  (should-not (iar--guard-check-content "truncated: 5 total chars\n"))
  (should-not (iar--guard-check-content "[... file truncated at 1000 characters ...]\n"))
  (should-not (iar--guard-check-content "")))

(ert-deftest test-wg-content-guard-nil-and-nonstring ()
  "nil and non-string content pass through (nothing to poison)."
  (should-not (iar--guard-check-content nil))
  (should-not (iar--guard-check-content 42)))

(ert-deftest test-wg-content-guard-disabled-passes ()
  "iar-write-guard-enabled nil disables the content check entirely."
  (let ((iar-write-guard-enabled nil))
    (should-not (iar--guard-check-content
                 "[... truncated: 100 total chars, kept first 50 and last 50 ...]"))))

(ert-deftest test-wg-content-guard-partial-notice-not-enough ()
  "A fragment that does not complete the skeleton is allowed (no FPs)."
  (should-not (iar--guard-check-content "[... truncated: 100 total chars"))
  (should-not (iar--guard-check-content "kept first 10 and last 10 ...]")))

;;; --- Integration: the real write path refuses the poison ---

(ert-deftest test-wg-write-file-refuses-poisoned-content ()
  "write_file with the REAL notice in content is refused, file unchanged.
Reproduces the disease: continuo's 2026-09-17 write of the truncated
test-loop-chain.el view (notice embedded at line 119)."
  (with-wg-fixture
    (let* ((target (expand-file-name "victim.el" test-wg--tmpdir))
           (original "(ert-deftest test-a () (should t))\n(ert-deftest test-b () (should t))\n(ert-deftest test-c () (should t))\n")
           ;; Exactly what iar--truncate-tool-result emits (max 10000):
           (poisoned (concat (substring original 0 20)
                             "\n[... truncated: 13106 total chars, kept first 5000 and last 5000 ...]\n"
                             (substring original -20))))
      (iar--fs-write-file target original)
      (let ((result (iar--fs-write-file target poisoned)))
        (should (string-match-p "Error" result))
        (should (string-match-p "truncat" result))
        ;; The file on disk is UNTOUCHED -- the poison never landed.
        (should (string= (test-wg--file-content target) original))))))

(ert-deftest test-wg-append-file-refuses-poisoned-content ()
  "append_file with notice-bearing content is refused, file unchanged."
  (with-wg-fixture
    (let* ((target (expand-file-name "journal.txt" test-wg--tmpdir)))
      (iar--fs-write-file target "clean line\n")
      (let ((result (iar--fs-append-file
                     target "[... truncated: 500 total chars, kept first 250 and last 250 ...]\n")))
        (should (string-match-p "Error" result))
        (should (string= (test-wg--file-content target) "clean line\n"))))))

(ert-deftest test-wg-write-file-allows-clean-content ()
  "Clean writes still succeed (no false-positive regression)."
  (with-wg-fixture
    (let ((target (expand-file-name "clean.txt" test-wg--tmpdir)))
      (should (string-match-p "Success" (iar--fs-write-file target "fine\n")))
      (should (string-match-p "Success" (iar--fs-append-file target "also fine\n")))
      (should (string= (test-wg--file-content target) "fine\nalso fine\n")))))

(ert-deftest test-wg-write-guard-disabled-allows-poison ()
  "Guard disabled: the poison write goes through (belt-off behavior)."
  (with-wg-fixture
    (let* ((iar-write-guard-enabled nil)
           (target (expand-file-name "off.txt" test-wg--tmpdir))
           (poison "[... truncated: 10 total chars, kept first 5 and last 5 ...]"))
      (iar--fs-write-file target "before\n")
      (should (string-match-p "Success" (iar--fs-write-file target poison)))
      (should (string= (test-wg--file-content target) poison)))))

(ert-deftest test-wg-write-file-buffer-path-also-guarded ()
  "The buffer-write branch checks content too (not just the temp-file branch)."
  (with-wg-fixture
    (let* ((target (expand-file-name "buffered.txt" test-wg--tmpdir))
           (poison "[... truncated: 20 total chars, kept first 10 and last 10 ...]"))
      (iar--fs-write-file target "original\n")
      (let ((buf (find-file target)))
        (unwind-protect
            (let ((result (iar--fs-write-file target poison)))
              (should (string-match-p "Error" result))
              ;; Buffer unmodified by the refused write
              (with-current-buffer buf
                (should (string= (buffer-string) "original\n"))))
          (when (buffer-live-p buf) (kill-buffer buf)))))))
