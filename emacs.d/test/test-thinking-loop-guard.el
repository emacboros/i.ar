;; -*- lexical-binding: t; -*-

;;; Tests for the thinking-only truncation discriminator
;;; (iar--cycle-thinking-only-response-p, 2026-09-10).
;;;
;;; The nemotron-era fire class: stop=length at the 32768 num_predict
;;; cap with a THINKING-ONLY response (1M+ chars of streamed reasoning,
;;; no model text outside gptel `ignore' spans). The grace round-trip
;;; cannot land such a response -- the model loops in reasoning. The
;;; discriminator lets the truncated-output guard end these cycles
;;; immediately instead of spending the grace.
;;;
;;; Pure-function tests: build buffers with gptel text-properties,
;;; no live processes, no network.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)

(require 'iar-request-log)
(require 'iar-agent-cycle)

(defun tg--make-thinking-only-buffer ()
  "Build a buffer with a large reasoning span and no model text.
Mimics gptel's property layout: reasoning is `gptel' `ignore'."
  (with-current-buffer (get-buffer-create " *tg-thinking-only*")
    (erase-buffer)
    (insert (make-string 10000 ?x))
    ;; Mark the whole span as reasoning (ignore).
    (put-text-property (point-min) (point-max) 'gptel 'ignore)
    (current-buffer)))

(defun tg--make-mixed-response-buffer ()
  "Build a buffer with a reasoning span AND real model text after it."
  (with-current-buffer (get-buffer-create " *tg-mixed*")
    (erase-buffer)
    (let ((beg (point)))
      (insert (make-string 5000 ?r))
      (put-text-property beg (point) 'gptel 'ignore)
      (insert "\nVisible model text: the analysis concluded X.\n")
      (current-buffer))))

(defun tg--make-text-only-response-buffer ()
  "Build a buffer with only model text (no reasoning)."
  (with-current-buffer (get-buffer-create " *tg-text-only*")
    (erase-buffer)
    (insert "The morning protocol completed. All checks green.\n")
    (insert "Next: post lab-notes and end the cycle.\n")
    (current-buffer)))

(ert-deftest test-thinking-only-large-reasoning-no-text ()
  "1M-char reasoning span, no model text: thinking-only."
  (with-current-buffer (tg--make-thinking-only-buffer)
    (should (iar--cycle-thinking-only-response-p (point-min) (point-max)))))

(ert-deftest test-thinking-only-mixed-response-not-flagged ()
  "Reasoning + real model text: NOT thinking-only (grace applies)."
  (with-current-buffer (tg--make-mixed-response-buffer)
    (should-not (iar--cycle-thinking-only-response-p (point-min) (point-max)))))

(ert-deftest test-thinking-only-text-only-not-flagged ()
  "Plain text response: NOT thinking-only."
  (with-current-buffer (tg--make-text-only-response-buffer)
    (should-not (iar--cycle-thinking-only-response-p (point-min) (point-max)))))

(ert-deftest test-thinking-only-tiny-region-not-flagged ()
  "A tiny region (<500 raw chars) is never thinking-only: too little
evidence to end a cycle on."
  (with-current-buffer (tg--make-thinking-only-buffer)
    (should-not (iar--cycle-thinking-only-response-p 1 100))))

(ert-deftest test-thinking-only-degenerate-region-nil ()
  "start == end (failed request shape): nil, never fires."
  (with-current-buffer (tg--make-thinking-only-buffer)
    (should-not (iar--cycle-thinking-only-response-p 100 100))))

(ert-deftest test-thinking-only-nil-region-nil ()
  "Non-integer positions: nil."
  (with-current-buffer (tg--make-thinking-only-buffer)
    (should-not (iar--cycle-thinking-only-response-p nil nil))))

(ert-deftest test-thinking-only-small-visible-text-still-flagged ()
  "A short stray separator (e.g. \\n) inside a huge reasoning span is
still thinking-only: the 20-char text budget tolerates separators."
  (with-current-buffer (tg--make-thinking-only-buffer)
    ;; Add a tiny non-ignore separator span.
    (goto-char (point-max))
    (let ((beg (point)))
      (insert "\n")
      (put-text-property beg (point) 'gptel 'response))
    (should (iar--cycle-thinking-only-response-p (point-min) (point-max)))))

(ert-deftest test-thinking-only-real-text-over-budget-not-flagged ()
  "Model text over the 200-char budget: NOT thinking-only."
  (with-current-buffer (tg--make-thinking-only-buffer)
    (goto-char (point-max))
    (let ((beg (point)))
      (insert (make-string 300 ?v))
      (put-text-property beg (point) 'gptel 'response))
    (should-not (iar--cycle-thinking-only-response-p (point-min) (point-max)))))