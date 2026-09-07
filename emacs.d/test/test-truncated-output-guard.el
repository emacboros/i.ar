;; -*- lexical-binding: t; -*-

;;; Tests for the per-request truncated-output guard (ladder item C).
;;; The guard keys on stop=length + tokens_out > threshold, NOT on raw
;;; tokens_out alone -- a complete 30k-token response (stop=stop) is
;;; legitimate (c100 data: continuo max 13739, aria one outlier 31670).
;;; Pure-function tests: no live processes, no network.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)

(require 'iar-request-log)
(require 'iar-agent-cycle)

;;; --- iar--cycle-truncated-output-p ---

(ert-deftest test-truncated-output-stop-length-over-threshold ()
  "stop=length with output above threshold: runaway."
  (let ((iar--reqlog-last-stop "length")
        (iar--reqlog-last-tokens-out 65536))
    (should (iar--cycle-truncated-output-p))))

(ert-deftest test-truncated-output-stop-length-under-threshold ()
  "stop=length with small output: not a runaway (legit short truncation)."
  (let ((iar--reqlog-last-stop "length")
        (iar--reqlog-last-tokens-out 5000))
    (should-not (iar--cycle-truncated-output-p))))

(ert-deftest test-truncated-output-stop-stop-large ()
  "stop=stop with large output: NOT a runaway (complete response is legit)."
  (let ((iar--reqlog-last-stop "stop")
        (iar--reqlog-last-tokens-out 31670))
    (should-not (iar--cycle-truncated-output-p))))

(ert-deftest test-truncated-output-stop-stop-small ()
  "stop=stop with small output: not a runaway."
  (let ((iar--reqlog-last-stop "stop")
        (iar--reqlog-last-tokens-out 1000))
    (should-not (iar--cycle-truncated-output-p))))

(ert-deftest test-truncated-output-nil-stop ()
  "nil stop-reason: not a runaway (no data)."
  (let ((iar--reqlog-last-stop nil)
        (iar--reqlog-last-tokens-out 65536))
    (should-not (iar--cycle-truncated-output-p))))

(ert-deftest test-truncated-output-nil-tokens ()
  "nil tokens-out: not a runaway (no data)."
  (let ((iar--reqlog-last-stop "length")
        (iar--reqlog-last-tokens-out nil))
    (should-not (iar--cycle-truncated-output-p))))

(ert-deftest test-truncated-output-at-threshold ()
  "Output exactly at threshold: not a runaway (strict >)."
  (let ((iar--reqlog-last-stop "length")
        (iar--reqlog-last-tokens-out iar-cycle-truncated-output-threshold))
    (should-not (iar--cycle-truncated-output-p))))

;;; --- iar--reqlog-reset-last ---

(ert-deftest test-reqlog-reset-last-clears-state ()
  "Reset clears both shared fields."
  (setq iar--reqlog-last-stop "length"
        iar--reqlog-last-tokens-out 65536)
  (iar--reqlog-reset-last)
  (should (null iar--reqlog-last-stop))
  (should (null iar--reqlog-last-tokens-out)))
