;; -*- lexical-binding: t; -*-

;;; Tests for iar-tool-call.el
;; Tests tool registration, truncation, hook bridging, and usage tracking.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)

(require 'iar-tool-call)

;;; --- Tool registration tests ---

(ert-deftest test-tool-call-register-adds-to-gptel-tools ()
  "iar-tool-register should add a tool to gptel-tools."
  (let ((gptel-tools nil)
        (tool (gptel-make-tool :name "test-tool-1"
                                :description "Test"
                                :args (list)
                                :function #'identity)))
    (iar-tool-register tool)
    (should (member tool gptel-tools))))

(ert-deftest test-tool-call-make-creates-and-registers ()
  "iar-tool-make should create a tool and register it."
  (let ((gptel-tools nil))
    (let ((tool (iar-tool-make "test-tool-2" "Test" (list) #'identity)))
      (should tool)
      (should (member tool gptel-tools))
      (should (string= "test-tool-2" (gptel-tool-name tool))))))

;;; --- Truncation tests ---

(ert-deftest test-tool-call-truncate-under-limit ()
  "Truncation should return string unchanged when under limit."
  (let ((iar-tool-result-max-chars 1000))
    (should (string= "hello" (iar--truncate-tool-result "hello")))))

(ert-deftest test-tool-call-truncate-over-limit ()
  "Truncation should truncate strings exceeding the limit."
  (let ((iar-tool-result-max-chars 10))
    (let ((result (iar--truncate-tool-result (make-string 100 ?x))))
      ;; Should be shorter than original
      (should (< (length result) 100))
      ;; Should contain truncation notice
      (should (string-match-p "truncated" result))
      ;; Should contain original chars at start and end
      (should (string-prefix-p "xxxxx" result))
      (should (string-suffix-p "xxxxx" result)))))

(ert-deftest test-tool-call-truncate-disabled ()
  "Truncation should be disabled when max-chars is nil."
  (let ((iar-tool-result-max-chars nil))
    (let ((big-string (make-string 100000 ?x)))
      (should (string= big-string (iar--truncate-tool-result big-string))))))

(ert-deftest test-tool-call-truncate-nil-result ()
  "Truncation should handle nil result gracefully."
  (let ((iar-tool-result-max-chars 100))
    (should (null (iar--truncate-tool-result nil)))))

(ert-deftest test-tool-call-truncate-non-string ()
  "Truncation should handle non-string result gracefully."
  (let ((iar-tool-result-max-chars 100))
    (should (eq 42 (iar--truncate-tool-result 42)))))

;;; --- Hook bridge tests ---

(ert-deftest test-tool-call-pre-hook-allows ()
  "Pre-tool-call bridge should return nil when no hook blocks."
  (let ((iar-pre-tool-call-functions nil))
    (should (null (iar--bridge-pre-tool-call '(:tool "test"))))))

(ert-deftest test-tool-call-pre-hook-blocks ()
  "Pre-tool-call bridge should return (:block . msg) when a hook blocks."
  (let ((iar-pre-tool-call-functions
         (list (lambda (info) '(:block . "blocked")))))
    (should (equal '(:block . "blocked")
                   (iar--bridge-pre-tool-call '(:tool "test"))))))

(defvar test-tool-call--hook-result nil)
(ert-deftest test-tool-call-post-hook-runs ()
  "Post-tool-call bridge should run all hook functions."
  (setq test-tool-call--hook-result nil)
  (cl-letf (((default-value 'iar-post-tool-call-functions)
             (list (lambda (name _result)
                    (setq test-tool-call--hook-result name)))))
    (iar--bridge-post-tool-call "test-tool" "result")
    (should (equal "test-tool" test-tool-call--hook-result))))

;;; --- Usage tracking tests ---

(ert-deftest test-tool-call-usage-reset ()
  "iar--usage-reset should zero all counters."
  (setq iar--usage-requests 99
        iar--usage-input-tokens 99
        iar--usage-output-tokens 99)
  (iar--usage-reset)
  (should (zerop iar--usage-requests))
  (should (zerop iar--usage-input-tokens))
  (should (zerop iar--usage-output-tokens)))

(ert-deftest test-tool-call-usage-totals ()
  "iar--usage-totals should return a plist with all fields."
  (iar--usage-reset)
  (setq iar--usage-requests 5
        iar--usage-input-tokens 100
        iar--usage-output-tokens 50)
  (let ((totals (iar--usage-totals)))
    (should (= 5 (plist-get totals :requests)))
    (should (= 100 (plist-get totals :input-tokens)))
    (should (= 50 (plist-get totals :output-tokens)))
    (should (= 150 (plist-get totals :total-tokens)))))

(ert-deftest test-tool-call-usage-parse-tokens ()
  "iar--usage-parse-tokens should parse and accumulate from JSON.
Uses regex-based parsing (same as request-logger) since that's the
canonical implementation loaded first."
  (iar--usage-reset)
  (let ((json-str "{\"model\":\"test\",\"prompt_eval_count\": 42, \"eval_count\": 17, \"done\": true}"))
    (iar--usage-parse-tokens json-str)
    (should (= 42 iar--usage-input-tokens))
    (should (= 17 iar--usage-output-tokens))))

(ert-deftest test-tool-call-usage-parse-tokens-not-done ()
  "iar--usage-parse-tokens should still accumulate from non-final chunks
(regex-based parsing accumulates whenever fields are present)."
  (iar--usage-reset)
  (let ((json-str "{\"eval_count\": 17, \"done\": false}"))
    (iar--usage-parse-tokens json-str)
    (should (= 17 iar--usage-output-tokens))))

(provide 'test-tool-call)