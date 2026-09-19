;; -*- lexical-binding: t; -*-

;;; Tests for iar-audit-log.el
;; Tests the audit logging system: agent name resolution, log formatting,
;; and the wrapper functions for each tool type (write, replace, append, exec).
;; Uses a temporary audit log path to avoid polluting the real audit log.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-audit-log)

;; Silence byte-compiler warnings for dynamically-bound test variables.
(defvar iar-audit-log-max-size)
(defvar iar--current-agent-name)
(declare-function iar--audit-maybe-rotate "iar-audit-log" ())

;;; --- Test fixtures ---

(defvar test-audit--tmpdir nil
  "Temporary directory for audit log tests.")
(defvar test-audit--log-path nil
  "Temporary audit log file path.")
(defvar test-audit--old-agent-name nil
  "Saved agent name for restoration.")

(defun test-audit--setup ()
  "Create a fresh temporary directory and audit log file."
  (setq test-audit--tmpdir (make-temp-file "test-audit-" :dir-flag))
  (setq test-audit--log-path (expand-file-name "audit.log" test-audit--tmpdir))
  (setq test-audit--old-agent-name
        (and (boundp 'iar--current-agent-name)
             iar--current-agent-name))
  (setq iar--current-agent-name "testagent"))

(defun test-audit--teardown ()
  "Remove the temporary directory and restore agent name."
  (when (and test-audit--tmpdir (file-exists-p test-audit--tmpdir))
    (delete-directory test-audit--tmpdir t))
  (setq test-audit--tmpdir nil)
  (setq test-audit--log-path nil)
  (setq iar--current-agent-name test-audit--old-agent-name))

(defmacro with-audit-fixture (&rest body)
  "Execute BODY with a temporary audit log path and test agent name.
Temporarily rebinds `iar--audit-log-path' to a temp file."
  (declare (indent 0))
  `(unwind-protect
       (progn
         (test-audit--setup)
         (let ((iar--audit-log-path test-audit--log-path))
           ,@body))
     (test-audit--teardown)))

(defun test-audit--read-log ()
  "Read the current audit log file contents."
  (if (file-exists-p test-audit--log-path)
      (with-temp-buffer
        (insert-file-contents test-audit--log-path)
        (buffer-string))
    ""))

;;; --- Agent name resolution tests ---

(ert-deftest test-audit-get-agent-name-when-set ()
  "iar--get-agent-name should return the current agent name."
  (let ((iar--current-agent-name "darwin"))
    (should (string= (iar--get-agent-name) "darwin"))))

(ert-deftest test-audit-get-agent-name-when-unset ()
  "iar--get-agent-name should return nil when no agent is set at all."
  (let ((iar--current-agent-name nil)
        (iar--current-agent-file nil))
    (should (string= (iar--get-agent-name) nil))))

(ert-deftest test-audit-get-agent-name-when-nil ()
  "iar--get-agent-name should return nil when name AND file are nil.
With a file set, the resolver derives the name from it (documented
fallback), so a true-nil test must clear both."
  (let ((iar--current-agent-name nil)
        (iar--current-agent-file nil))
    (should (string= (iar--get-agent-name) nil))))

;;; --- Core audit log tests ---

(ert-deftest test-audit-log-writes-formatted-line ()
  "iar--audit-log should write a timestamped, pipe-delimited line."
  (with-audit-fixture
    (iar--audit-log "write_file" "/some/path/file.txt")
    (let ((content (test-audit--read-log)))
      (should (string-match-p "\\[[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\} [0-9]\\{2\\}:[0-9]\\{2\\}:[0-9]\\{2\\}\\]" content))
      (should (string-match-p "testagent" content))
      (should (string-match-p "write_file" content))
      (should (string-match-p "/some/path/file.txt" content)))))

(ert-deftest test-audit-log-appends-multiple-entries ()
  "iar--audit-log should append entries, not overwrite."
  (with-audit-fixture
    (iar--audit-log "write_file" "/path/a.txt")
    (iar--audit-log "append_file" "/path/b.txt")
    (let ((content (test-audit--read-log)))
      (should (string-match-p "/path/a.txt" content))
      (should (string-match-p "/path/b.txt" content))
      ;; Two lines = two entries
      (should (= (length (split-string content "\n" t)) 2)))))

(ert-deftest test-audit-log-creates-directory-if-missing ()
  "iar--audit-log should create the workspace directory if it doesn't exist."
  (let ((test-audit--tmpdir (make-temp-file "test-audit-" :dir-flag))
        (test-audit--log-path nil)
        (test-audit--old-agent-name
         (and (boundp 'iar--current-agent-name)
              iar--current-agent-name)))
    (setq iar--current-agent-name "testagent")
    (setq test-audit--log-path
          (expand-file-name "workspace/audit.log" test-audit--tmpdir))
    (unwind-protect
        (let ((iar--audit-log-path test-audit--log-path))
          (should-not (file-exists-p (file-name-directory test-audit--log-path)))
          (iar--audit-log "write_file" "/test.txt")
          (should (file-exists-p test-audit--log-path)))
      (when (and test-audit--tmpdir (file-exists-p test-audit--tmpdir))
        (delete-directory test-audit--tmpdir t))
      (setq iar--current-agent-name test-audit--old-agent-name))))

;;; --- Wrapper function tests ---

(ert-deftest test-audit-log-write-logs-path ()
  "iar--audit-log-write should log the filepath with write_file tool name."
  (with-audit-fixture
    (iar--audit-log-write "/some/file.el")
    (let ((content (test-audit--read-log)))
      (should (string-match-p "write_file" content))
      (should (string-match-p "/some/file.el" content)))))
