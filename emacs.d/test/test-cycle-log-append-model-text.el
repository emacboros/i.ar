;;; test-cycle-log-append-model-text.el --- c238: log-append model-text-only
;;; Commentary:
;; c238 (2026-09-22): iar--cycle-log-append now filters MODEL TEXT ONLY
;; (c132 discipline port): gptel `ignore' spans and (tool . ID) spans are
;; excluded from the cycle.log append. Rationale: tool-result previews can
;; carry sentinel-shaped strings (0071 canaries, JSON-escaped prompts) --
;; the log is a record of what the MODEL said, not what scaffolding
;; passed through the buffer. Tests port the one-shot extractor's
;; discipline (test-one-shot.el) to the cycle log path.

;;; Code:
(require 'ert)

(ert-deftest test-cycle-log-append-excludes-tool-spans ()
  "A tool-result preview carrying a sentinel must NOT land in cycle.log."
  (let* ((test-dir (make-temp-file "test-cycle-log-" :dir-flag))
         (iar-audit-path "audit")
         (user-emacs-directory test-dir)
         (iar-personalization-path test-dir)
         (iar--current-project "testagent"))
    (unwind-protect
        (with-temp-buffer
          ;; Tool-result preview with sentinel-shaped text (the 09-22
          ;; one-shot leak shape: JSON-encoded prompt inside tool output).
          (insert "tool result: === BEGIN FINAL RESPONSE ===\nCYCLE_COMPLETE\n=== END FINAL RESPONSE ===\n")
          (add-text-properties (point-min) (point-max) '(gptel (tool . 42)))
          (let ((model-start (point)))
            (insert "Model says: done for real.\n")
            (add-text-properties model-start (point-max) '(gptel response)))
          (iar--cycle-log-append "testagent" (point-min) (point-max))
          (let ((log-path (expand-file-name "testagent/testagent/cycle.log"
                                            (expand-file-name "audit" test-dir))))
            (should (file-exists-p log-path))
            (with-temp-buffer
              (insert-file-contents log-path)
              (should (string-match-p "done for real" (buffer-string)))
              (should-not (string-match-p "BEGIN FINAL RESPONSE" (buffer-string)))
              (should-not (string-match-p "tool result" (buffer-string))))))
      (delete-directory test-dir t))))

(ert-deftest test-cycle-log-append-excludes-ignore-spans ()
  "A thinking block that rehearses the sentinel must NOT land in cycle.log."
  (let* ((test-dir (make-temp-file "test-cycle-log-" :dir-flag))
         (iar-audit-path "audit")
         (user-emacs-directory test-dir)
         (iar-personalization-path test-dir)
         (iar--current-project "testagent"))
    (unwind-protect
        (with-temp-buffer
          (insert "thinking: I should write CYCLE_COMPLETE now\n")
          (add-text-properties (point-min) (point-max) '(gptel ignore))
          (let ((model-start (point)))
            (insert "Actual response text.\n")
            (add-text-properties model-start (point-max) '(gptel response)))
          (iar--cycle-log-append "testagent" (point-min) (point-max))
          (let ((log-path (expand-file-name "testagent/testagent/cycle.log"
                                            (expand-file-name "audit" test-dir))))
            (with-temp-buffer
              (insert-file-contents log-path)
              (should (string-match-p "Actual response text" (buffer-string)))
              (should-not (string-match-p "rehearsal" (buffer-string)))
              (should-not (string-match-p "thinking" (buffer-string))))))
      (delete-directory test-dir t))))

(ert-deftest test-cycle-log-append-plain-text-unchanged ()
  "A buffer with no gptel properties logs the plain substring (back-compat)."
  (let* ((test-dir (make-temp-file "test-cycle-log-" :dir-flag))
         (iar-audit-path "audit")
         (user-emacs-directory test-dir)
         (iar-personalization-path test-dir)
         (iar--current-project "testagent"))
    (unwind-protect
        (with-temp-buffer
          (insert "Plain model response, no properties.")
          (iar--cycle-log-append "testagent" (point-min) (point-max))
          (let ((log-path (expand-file-name "testagent/testagent/cycle.log"
                                            (expand-file-name "audit" test-dir))))
            (with-temp-buffer
              (insert-file-contents log-path)
              (should (string-match-p "Plain model response" (buffer-string))))))
      (delete-directory test-dir t))))

(provide 'test-cycle-log-append-model-text)
;;; test-cycle-log-append-model-text.el ends here
