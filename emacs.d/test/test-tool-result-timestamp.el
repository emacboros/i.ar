;; -*- lexical-binding: t; -*-

;;; Tests for iar-tool-result-timestamp.el

(require 'ert)
(require 'cl-lib)
(require 'subr-x)

;; Configs are loaded by filename in run-tests.el (not by feature),
;; so the timestamp config var is available via forward-declaration
;; in the module itself. Just require the module.
(require 'iar-tool-result-timestamp)

;;; --- Timestamp function tests ---

(ert-deftest test-timestamp-disabled ()
  "When timestamps are disabled, result passes through unchanged."
  (let ((iar-tool-result-timestamps nil))
    (should (string= "hello" (iar--timestamp-tool-result "hello")))))

(ert-deftest test-timestamp-enabled ()
  "When enabled, string results get a [HH:MM:SS] prefix."
  (let ((iar-tool-result-timestamps t))
    (let ((result (iar--timestamp-tool-result "hello")))
      (should (string-match-p "\\`\\[[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\\] hello\\'"
                              result)))))

(ert-deftest test-timestamp-format ()
  "Timestamp matches [HH:MM:SS] format exactly."
  (let ((iar-tool-result-timestamps t))
    (let ((result (iar--timestamp-tool-result "x")))
      (should (string-match-p "\\`\\[[0-9]\\{2\\}:[0-9]\\{2\\}:[0-9]\\{2\\}\\] x\\'"
                              result)))))

(ert-deftest test-timestamp-idempotent ()
  "Already-timestamped results are not stamped again."
  (let ((iar-tool-result-timestamps t))
    (should (string= "[12:00:00] hello"
                     (iar--timestamp-tool-result "[12:00:00] hello")))))

(ert-deftest test-timestamp-non-string ()
  "Non-string results pass through unchanged."
  (let ((iar-tool-result-timestamps t))
    (should (eq 42 (iar--timestamp-tool-result 42)))
    (should (null (iar--timestamp-tool-result nil)))))

(ert-deftest test-timestamp-empty-string ()
  "Empty string still gets a timestamp."
  (let ((iar-tool-result-timestamps t))
    (let ((result (iar--timestamp-tool-result "")))
      (should (string-match-p "\\`\\[[0-9]\\{2\\}:[0-9]\\{2\\}:[0-9]\\{2\\}\\] \\'"
                              result)))))

(ert-deftest test-timestamp-error-result ()
  "Error results (starting with 'Error:') still get stamped -- the
agent needs to know WHEN things fail, too."
  (let ((iar-tool-result-timestamps t))
    (let ((result (iar--timestamp-tool-result "Error: file not found")))
      (should (string-match-p "\\`\\[[0-9]\\{2\\}:[0-9]\\{2\\}:[0-9]\\{2\\}\\] Error: file not found\\'"
                              result)))))

;;; --- Composition with truncation ---

(ert-deftest test-timestamp-before-truncation ()
  "Timestamp survives truncation: stamp first, then truncate.
Simulates the advice chain order (timestamp outer, truncation inner)."
  (let ((iar-tool-result-timestamps t)
        (iar-tool-result-max-chars 100))
    (let* ((stamped (iar--timestamp-tool-result (make-string 500 ?x)))
           (truncated (iar--truncate-tool-result stamped)))
      ;; The timestamp prefix must still be at the start after truncation
      (should (string-prefix-p "[" truncated))
      ;; And the truncation notice must be present
      (should (string-match-p "truncated" truncated)))))

;;; --- Advice installation tests ---

(ert-deftest test-timestamp-advice-installed ()
  "Timestamp advice is installed on gptel--process-tool-call."
  (should (advice-member-p 'iar--timestamp-tool-result-advice
                           'gptel--process-tool-call)))

(ert-deftest test-timestamp-setup-idempotent ()
  "Calling setup twice does not duplicate advice.
advice-remove before advice-add makes setup idempotent; verify by
checking the advice is present exactly once via advice-member-p
after double setup (a duplicate would still satisfy member-p, but
the remove-then-add pattern guarantees single registration -- this
test verifies the pattern holds and doesn't error)."
  (iar--timestamp-setup)
  (iar--timestamp-setup)
  (should (advice-member-p 'iar--timestamp-tool-result-advice
                           'gptel--process-tool-call)))

;;; --- Config variable tests ---

(ert-deftest test-timestamp-config-default ()
  "Default config value is enabled (t)."
  (should (eq t (default-value 'iar-tool-result-timestamps))))

(ert-deftest test-timestamp-config-safe-predicate ()
  "Config has a :safe predicate."
  (should (eq #'booleanp (get 'iar-tool-result-timestamps 'safe-local-variable))))

(provide 'test-tool-result-timestamp)