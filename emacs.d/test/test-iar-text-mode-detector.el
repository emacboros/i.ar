;; -*- lexical-binding: t; -*-

;;; Tests for iar-text-mode-detector -- the channel-switch witness
;;
;; Covers:
;; 1. Fenced tool blocks (``` tool ... ```) are detected.
;; 2. Fenced blocks with tool-call first lines (write_file: ...) detected.
;; 3. Self-generated receipt lines ([ts] Success: ...) detected.
;; 4. Prose that merely mentions tool names is NOT flagged.
;; 5. Plain code blocks (```bash, ```python) are NOT flagged.
;; 6. Failed requests (start == end) are skipped.
;; 7. Cap: more than iar-text-mode-max-report blocks -> capped count.
;; 8. Hook fires with (count snippets).
;; 9. gptel post-response path scans string responses.
;; 10. Disabled -> no scan.

(require 'ert)
(require 'iar-text-mode-detector)

;;; ---------------------------------------------------------
;;; iar-text-mode--scan-region
;;; ---------------------------------------------------------

(ert-deftest test-text-mode-detect-fenced-tool-block ()
  "A fenced ``` tool block with a tool call inside is detected."
  (with-temp-buffer
    (insert "Some prose.\n``` tool\nwrite_file :content \"x\" :filepath \"/tmp/y\"\n```\nMore prose.\n")
    (let ((res (iar-text-mode--scan-region (point-min) (point-max))))
      (should (= (car res) 1))
      (should (cl-some (lambda (s) (string-prefix-p "write_file" s)) (cdr res))))))

(ert-deftest test-text-mode-detect-fenced-call-syntax ()
  "A fenced block whose first line uses call syntax (tool(...)) is detected."
  (with-temp-buffer
    (insert "``` \nread_file(filepath=\"/tmp/x\")\n```\n")
    (let ((res (iar-text-mode--scan-region (point-min) (point-max))))
      (should (= (car res) 1)))))

(ert-deftest test-text-mode-detect-receipt-line ()
  "A self-generated timestamped Success receipt line is detected."
  (with-temp-buffer
    (insert "I have written the file.\n[2026-09-01 22:51:30] Success: File written to '/tmp/x'\n")
    (let ((res (iar-text-mode--scan-region (point-min) (point-max))))
      (should (= (car res) 1))
      (should (cl-some (lambda (s) (string-match-p "Success" s)) (cdr res))))))

(ert-deftest test-text-mode-detect-error-receipt ()
  "A self-generated Error receipt line is also detected."
  (with-temp-buffer
    (insert "[2026-09-01 10:00:00] Error: File not found\n")
    (let ((res (iar-text-mode--scan-region (point-min) (point-max))))
      (should (= (car res) 1)))))

(ert-deftest test-text-mode-prose-mention-not-flagged ()
  "Prose that mentions tool names without fenced syntax is NOT flagged."
  (with-temp-buffer
    (insert "I could use write_file or read_file to inspect this. The tool call layer handles it.\n")
    (let ((res (iar-text-mode--scan-region (point-min) (point-max))))
      (should (= (car res) 0)))))

(ert-deftest test-text-mode-plain-code-block-not-flagged ()
  "Plain code blocks (bash, python) are not tool calls."
  (with-temp-buffer
    (insert "```bash\nls -la /tmp\n```\n```python\nprint('hi')\n```\n")
    (let ((res (iar-text-mode--scan-region (point-min) (point-max))))
      (should (= (car res) 0)))))

(ert-deftest test-text-mode-empty-region ()
  "Empty region: zero detections, no error."
  (with-temp-buffer
    (let ((res (iar-text-mode--scan-region (point-min) (point-min))))
      (should (= (car res) 0))
      (should (null (cdr res))))))

(ert-deftest test-text-mode-cap-limits-report ()
  "More blocks than the cap: count capped at iar-text-mode-max-report."
  (let ((iar-text-mode-max-report 2))
    (with-temp-buffer
      (insert "``` tool\nwrite_file :a 1\n```\n``` tool\nread_file :a 2\n```\n``` tool\nlist_directory :a 3\n```\n")
      (let ((res (iar-text-mode--scan-region (point-min) (point-max))))
        (should (= (car res) 2))))))

(ert-deftest test-text-mode-unclosed-block-clamped ()
  "An unclosed fenced block is clamped to point-max, not an error."
  (with-temp-buffer
    (insert "``` tool\nwrite_file :content \"x\"\n")
    (let ((res (iar-text-mode--scan-region (point-min) (point-max))))
      (should (= (car res) 1)))))

;;; ---------------------------------------------------------
;;; iar--text-mode-post-response (hook path)
;;; ---------------------------------------------------------

(ert-deftest test-text-mode-post-response-logs-and-fires-hook ()
  "Post-response with detected blocks: REQUESTS.log line + hook fires."
  (let* ((hook-called nil)
         (hook-count nil)
         (log-file (make-temp-file "reqlog" t)))
    (unwind-protect
        (progn
          ;; Redirect reqlog append target for the test.
          (cl-letf (((symbol-function 'iar--reqlog-append)
                     (lambda (_fmt &rest _args) nil))
                    ;; cl-letf on symbol-value: dynamic setq/restore,
                    ;; immune to ERT's lexical test-body compilation
                    ;; (a plain let on a defvar'd var inside an ert
                    ;; body does NOT bind dynamically -- found live
                    ;; 2026-09-02, cycle 118).
                    ((symbol-value 'iar-text-mode-detected-functions)
                     (list (lambda (count _snippets)
                             (setq hook-called t hook-count count)))))
            (with-temp-buffer
              (insert "``` tool\nwrite_file :content \"x\"\n```\n")
              (iar--text-mode-post-response (point-min) (point-max))))
          (should hook-called)
          (should (= hook-count 1)))
      (delete-directory log-file t))))

(ert-deftest test-text-mode-post-response-failed-request-skipped ()
  "START == END (failed request) is skipped without error."
  (let ((hook-called nil))
    (cl-letf (((symbol-value 'iar-text-mode-detected-functions)
               (list (lambda (&rest _) (setq hook-called t)))))
      (iar--text-mode-post-response 5 5))
    (should (null hook-called))))

(ert-deftest test-text-mode-post-response-clean-response-no-hook ()
  "A clean response fires no hook and logs nothing."
  (let ((hook-called nil))
    (cl-letf (((symbol-value 'iar-text-mode-detected-functions)
               (list (lambda (&rest _) (setq hook-called t)))))
      (with-temp-buffer
        (insert "All good. I read the file and it was fine.\n")
        (iar--text-mode-post-response (point-min) (point-max))))
    (should (null hook-called))))

(ert-deftest test-text-mode-post-response-disabled ()
  "When disabled, no scan runs, no hook fires."
  (let ((hook-called nil))
    (cl-letf (((symbol-value 'iar-text-mode-detect-enabled) nil)
              ((symbol-value 'iar-text-mode-detected-functions)
               (list (lambda (&rest _) (setq hook-called t)))))
      (with-temp-buffer
        (insert "``` tool\nwrite_file :content \"x\"\n```\n")
        (iar--text-mode-post-response (point-min) (point-max))))
    (should (null hook-called))))

;;; ---------------------------------------------------------
;;; gptel post-response path
;;; ---------------------------------------------------------

(ert-deftest test-text-mode-gptel-post-response-scans-string ()
  "The gptel hook scans string responses and fires the hook."
  (let ((hook-called nil))
    (cl-letf (((symbol-value 'iar-text-mode-detected-functions)
               (list (lambda (count _snippets) (setq hook-called count)))))
      (iar--text-mode-gptel-post-response
       "Here is my action:\n``` tool\nwrite_file :content \"x\" :filepath \"/tmp/x\"\n```\n" nil))
    (should hook-called)
    (should (= hook-called 1))))

(ert-deftest test-text-mode-gptel-post-response-nonstring-ignored ()
  "Non-string responses (nil on failure) are ignored."
  (let ((hook-called nil))
    (cl-letf (((symbol-value 'iar-text-mode-detected-functions)
               (list (lambda (&rest _) (setq hook-called t)))))
      (iar--text-mode-gptel-post-response nil nil))
    (should (null hook-called))))

(provide 'test-iar-text-mode-detector)