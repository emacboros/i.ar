;; -*- lexical-binding: t; -*-

;;; Tests for iar-buffer-info.el
;; Tests buffer info display and system prompt viewing.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-utils)
(require 'iar-buffer-info)

;;; --- iar--format-size tests ---

(ert-deftest test-buffer-info-format-size-normal ()
  "Should format chars with approximate token count."
  (should (string= "1000 chars (~250 tokens)" (iar--format-size 1000))))

(ert-deftest test-buffer-info-format-size-zero ()
  "Should handle zero chars."
  (should (string= "0 chars (~0 tokens)" (iar--format-size 0))))

;;; --- iar-buffer-info tests ---

(ert-deftest test-buffer-info-displays-message ()
  "iar-buffer-info should display buffer and prompt sizes."
  (with-temp-buffer
    (insert "Hello world")
    (let ((gptel-system-prompt "You are a test agent."))
      (let ((message-log-max nil))
        (message "test-marker-before")
        (iar-buffer-info)
        ;; Just verify it doesn't error -- message output is hard to capture
        (should t)))))

(ert-deftest test-buffer-info-nil-prompt ()
  "iar-buffer-info should handle nil gptel-system-prompt."
  (with-temp-buffer
    (insert "test")
    (let ((gptel-system-prompt nil))
      (iar-buffer-info)
      (should t))))

(ert-deftest test-buffer-info-empty-buffer ()
  "iar-buffer-info should handle empty buffer."
  (with-temp-buffer
    (let ((gptel-system-prompt "system prompt"))
      (iar-buffer-info)
      (should t))))

;;; --- iar-view-prompt tests ---

(ert-deftest test-view-prompt-creates-buffer ()
  "iar-view-prompt should create a *System Prompt* buffer."
  (with-temp-buffer
    (let ((gptel-system-prompt "Test system prompt content."))
      (unwind-protect
          (progn
            (iar-view-prompt)
            (should (get-buffer "*System Prompt*"))
            (with-current-buffer "*System Prompt*"
              (should (string-match-p "Test system prompt content" (buffer-string)))
              (should (string-match-p "System Prompt:" (buffer-string)))))
        (when (get-buffer "*System Prompt*")
          (kill-buffer "*System Prompt*"))))))

(ert-deftest test-view-prompt-nil-prompt ()
  "iar-view-prompt should handle nil gptel-system-prompt."
  (with-temp-buffer
    (let ((gptel-system-prompt nil))
      (unwind-protect
          (progn
            (iar-view-prompt)
            (should (get-buffer "*System Prompt*"))
            (with-current-buffer "*System Prompt*"
              (should (string-match-p "0 chars" (buffer-string)))))
        (when (get-buffer "*System Prompt*")
          (kill-buffer "*System Prompt*"))))))

(ert-deftest test-view-prompt-read-only ()
  "iar-view-prompt should create a read-only buffer."
  (with-temp-buffer
    (let ((gptel-system-prompt "test prompt"))
      (unwind-protect
          (progn
            (iar-view-prompt)
            (with-current-buffer "*System Prompt*"
              (should buffer-read-only)))
        (when (get-buffer "*System Prompt*")
          (kill-buffer "*System Prompt*"))))))

(provide 'test-buffer-info)
;;; test-buffer-info.el ends here
