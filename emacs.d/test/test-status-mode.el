;; -*- lexical-binding: t; -*-

;;; Tests for iar-status-mode.el

(require 'ert)
(require 'cl-lib)
(require 'subr-x)

;; Declare special variables so let creates dynamic bindings
(defvar iar--current-agent-name nil)
(defvar gptel-system-prompt nil)
(defvar iar--usage-last-input 0)
(defvar iar--usage-last-output 0)
(defvar iar--usage-input-tokens 0)
(defvar iar--usage-output-tokens 0)
(defvar iar--usage-requests 0)
(defvar iar--usage-model nil)
(defvar iar--usage-start-time nil)
;; mode-line-misc-info may not be defined in batch mode
(defvar mode-line-misc-info nil)

;; Load dependencies
(load-file (expand-file-name "init.d/shared/iar-utils.el" user-emacs-directory))
(load-file (expand-file-name "init.d/tool-call/iar-tool-call.el" user-emacs-directory))
;; Load the module under test
(load-file (expand-file-name "init.d/debug/iar-status-mode.el" user-emacs-directory))

;;; --- Test fixture: save/restore mode-line-misc-info ---

(defun test-status-mode--save-mli ()
  "Save current mode-line-misc-info state."
  (and (boundp 'mode-line-misc-info) mode-line-misc-info))

(defun test-status-mode--restore-mli (old)
  "Restore mode-line-misc-info to OLD value."
  (setq mode-line-misc-info old))

;;; --- Format helpers ---

(ert-deftest test-status-mode-format-size ()
  "Size formatting should produce compact representations."
  (should (equal (iar--status-mode-format-size 0) "0"))
  (should (equal (iar--status-mode-format-size 500) "500"))
  (should (equal (iar--status-mode-format-size 1023) "1023"))
  (should (equal (iar--status-mode-format-size 1024) "1.0K"))
  (should (equal (iar--status-mode-format-size 2048) "2.0K"))
  (should (equal (iar--status-mode-format-size 1048576) "1.0M")))

(ert-deftest test-status-mode-format-size-nil ()
  "Nil size should format as 0."
  (should (equal (iar--status-mode-format-size nil) "0")))

(ert-deftest test-status-mode-format-tokens ()
  "Token formatting should produce compact representations."
  (should (equal (iar--status-mode-format-tokens 0) "0"))
  (should (equal (iar--status-mode-format-tokens 999) "999"))
  (should (equal (iar--status-mode-format-tokens 1000) "1.0K"))
  (should (equal (iar--status-mode-format-tokens 25000) "25.0K"))
  (should (equal (iar--status-mode-format-tokens 1000000) "1.0M")))

(ert-deftest test-status-mode-format-tokens-nil ()
  "Nil tokens should format as 0."
  (should (equal (iar--status-mode-format-tokens nil) "0")))

;;; --- Status string ---

(ert-deftest test-status-mode-format-basic ()
  "Status string should contain agent name and all 6 data points."
  (let ((iar--current-agent-name "mirror")
        (gptel-system-prompt "Hello world")
        (iar--usage-last-input 1500)
        (iar--usage-last-output 300)
        (iar--usage-input-tokens 50000)
        (iar--usage-output-tokens 5000))
    (let ((str (iar--status-mode-format)))
      (should (string-match-p "\\[mirror" str))
      ;; Prompt size: "Hello world" = 11 chars
      (should (string-match-p "11\\b" str))
      ;; Last input/output
      (should (string-match-p "last:1.5K/300" str))
      ;; Cumulative
      (should (string-match-p "total:50.0K/5.0K" str)))))

(ert-deftest test-status-mode-format-no-agent ()
  "Status string should show 'none' when agent is nil."
  (let ((iar--current-agent-name nil)
        (gptel-system-prompt "test")
        (iar--usage-last-input 0)
        (iar--usage-last-output 0)
        (iar--usage-input-tokens 0)
        (iar--usage-output-tokens 0))
    (let ((str (iar--status-mode-format)))
      (should (string-match-p "\\[none" str))
      (should (string-match-p "last:0/0" str))
      (should (string-match-p "total:0/0" str)))))

(ert-deftest test-status-mode-format-no-prompt ()
  "Status string should handle nil gptel-system-prompt."
  (let ((iar--current-agent-name "darwin")
        (gptel-system-prompt nil)
        (iar--usage-last-input 100)
        (iar--usage-last-output 50)
        (iar--usage-input-tokens 1000)
        (iar--usage-output-tokens 500))
    (let ((str (iar--status-mode-format)))
      (should (string-match-p "\\[darwin" str))
      ;; nil prompt -> length 0 -> "0"
      (should (string-match-p "\\[darwin 0\\]" str))
      (should (string-match-p "last:100/50" str))
      (should (string-match-p "total:1.0K/500" str)))))

;;; --- Mode-line integration ---

(ert-deftest test-status-mode-enable-adds-to-mode-line ()
  "Enabling status mode should add the :eval construct to mode-line-misc-info."
  (let ((old-mli (test-status-mode--save-mli)))
    (unwind-protect
        (progn
          (setq mode-line-misc-info nil)
          (iar-status-mode-enable)
          (should (= 1 (length mode-line-misc-info)))
          (should (eq (car (car mode-line-misc-info)) :eval))
          (iar-status-mode-disable))
      (test-status-mode--restore-mli old-mli))))

(ert-deftest test-status-mode-enable-idempotent ()
  "Enabling twice should not add duplicate constructs (rule 57)."
  (let ((old-mli (test-status-mode--save-mli)))
    (unwind-protect
        (progn
          (setq mode-line-misc-info nil)
          (iar-status-mode-enable)
          (iar-status-mode-enable)
          (let ((count
                 (cl-count-if #'iar--status-mode-own-p mode-line-misc-info)))
            (should (= 1 count)))
          (iar-status-mode-disable))
      (test-status-mode--restore-mli old-mli))))

(ert-deftest test-status-mode-disable-removes-from-mode-line ()
  "Disabling should remove the :eval construct from mode-line-misc-info."
  (let ((old-mli (test-status-mode--save-mli)))
    (unwind-protect
        (progn
          (setq mode-line-misc-info nil)
          (iar-status-mode-enable)
          (iar-status-mode-disable)
          (should (= 0 (length mode-line-misc-info))))
      (test-status-mode--restore-mli old-mli))))

(ert-deftest test-status-mode-disable-when-not-enabled ()
  "Disabling when not enabled should be a no-op (not error)."
  (let ((old-mli (test-status-mode--save-mli)))
    (unwind-protect
        (progn
          (setq mode-line-misc-info nil)
          (iar-status-mode-disable)
          (should (= 0 (length mode-line-misc-info))))
      (test-status-mode--restore-mli old-mli)))
  (let ((old-mli (test-status-mode--save-mli)))
    (unwind-protect
        (progn
          (setq mode-line-misc-info '(("foo" . bar)))
          (iar-status-mode-disable)
          (should (= 1 (length mode-line-misc-info))))
      (test-status-mode--restore-mli old-mli))))

(ert-deftest test-status-mode-update-does-not-error ()
  "iar--status-mode-update should not error when called."
  (iar--status-mode-update))

(ert-deftest test-status-mode-active-flag ()
  "iar--status-mode-active should be t after enable, nil after disable."
  (let ((old-mli (test-status-mode--save-mli)))
    (unwind-protect
        (progn
          (setq mode-line-misc-info nil)
          (iar-status-mode-enable)
          (should iar--status-mode-active)
          (iar-status-mode-disable)
          (should-not iar--status-mode-active))
      (test-status-mode--restore-mli old-mli))))

(ert-deftest test-status-mode-format-large-numbers ()
  "Status string should format large token counts with M suffix."
  (let ((iar--current-agent-name "darwin")
        (gptel-system-prompt (make-string 2097152 ?x)) ; 2MB
        (iar--usage-last-input 2000000)
        (iar--usage-last-output 500000)
        (iar--usage-input-tokens 50000000)
        (iar--usage-output-tokens 10000000))
    (let ((str (iar--status-mode-format)))
      (should (string-match-p "2.0M" str))
      (should (string-match-p "last:2.0M/500.0K" str))
      (should (string-match-p "total:50.0M/10.0M" str)))))

(ert-deftest test-status-mode-format-preserves-other-mode-line-items ()
  "Enabling status mode should not remove existing mode-line-misc-info items."
  (let ((old-mli (test-status-mode--save-mli)))
    (unwind-protect
        (progn
          (setq mode-line-misc-info '(("existing" . item)))
          (iar-status-mode-enable)
          (should (member '("existing" . item) mode-line-misc-info))
          (should (= 2 (length mode-line-misc-info)))
          (iar-status-mode-disable)
          (should (= 1 (length mode-line-misc-info))))
      (test-status-mode--restore-mli old-mli))))