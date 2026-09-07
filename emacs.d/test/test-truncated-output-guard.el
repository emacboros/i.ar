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
;;; --- handler-level grace round-trip tests (c44 port) ---

(ert-deftest test-truncated-output-first-fire-gives-landing-grace ()
  "First truncated-output fire in the post-response handler: ONE
grace round-trip -- the landing prompt is inserted and gptel-send is
called again; the cycle is NOT ended. Port of the timeout grace
pattern; the c42 death (record lost mid-consolidation) is the case
this fixes."
  (let ((buf (get-buffer-create "*test-truncgrace1*"))
        (sent 0))
    (unwind-protect
        (let ((iar-cycle-context-limit-chars 100000)
              (iar--cycle-state (iar--cycle-make-state "test" buf "Continue." 40))
              (iar--one-shot-state nil)
              (iar--cycle-error-strikes 0)
              (iar--reqlog-last-stop "length")
              (iar--reqlog-last-tokens-out 65536))
          (with-current-buffer buf (erase-buffer) (insert (make-string 100 ?x)))
          (cl-letf (((symbol-function 'gptel-send)
                     (lambda () (cl-incf sent))))
            (with-current-buffer buf
              (let ((start (point)))
                (insert "partial consolidated findings, thinking cut mid-stream\n")
                (iar--cycle-post-response-handler start (point)))))
          ;; Grace round-trip: sent again, not ended.
          (should (= 1 sent))
          (should (plist-get iar--cycle-state :runaway-recovery-given))
          (should-not (plist-get iar--cycle-state :completed))
          ;; The landing prompt reached the buffer.
          (with-current-buffer buf
            (should (string-match-p "truncated mid-thought" (buffer-string)))))
      (kill-buffer buf))))

(ert-deftest test-truncated-output-second-fire-ends-cycle ()
  "Second truncated-output fire (recovery already given): cycle ends,
exit 1 -- the model kept looping after its grace round-trip."
  (let ((buf (get-buffer-create "*test-truncgrace2*"))
        (sent 0))
    (unwind-protect
        (let ((iar-cycle-context-limit-chars 100000)
              (iar--cycle-state (iar--cycle-make-state "test" buf "Continue." 40))
              (iar--one-shot-state nil)
              (iar--cycle-error-strikes 0)
              (iar--reqlog-last-stop "length")
              (iar--reqlog-last-tokens-out 65536))
          (with-current-buffer buf (erase-buffer) (insert (make-string 100 ?x)))
          (cl-letf (((symbol-function 'gptel-send)
                     (lambda () (cl-incf sent))))
            (with-current-buffer buf
              ;; First fire: grace round-trip.
              (let ((start (point)))
                (insert "first truncated response\n")
                (iar--cycle-post-response-handler start (point))))
            (should (= 1 sent))
            (should-not (plist-get iar--cycle-state :completed))
            ;; Simulate the model landing a normal response in between
            ;; (stop=stop resets the truncated check) then truncating
            ;; AGAIN: second fire ends the cycle.
            (setq iar--reqlog-last-stop "stop"
                  iar--reqlog-last-tokens-out 500)
            (with-current-buffer buf
              (let ((start (point)))
                (insert "good landed response\n")
                (iar--cycle-post-response-handler start (point))))
            (should-not (plist-get iar--cycle-state :completed))
            (setq iar--reqlog-last-stop "length"
                  iar--reqlog-last-tokens-out 65536)
            (with-current-buffer buf
              (let ((start (point)))
                (insert "second truncated response\n")
                (iar--cycle-post-response-handler start (point)))))
          (should (plist-get iar--cycle-state :completed))
          (should (= 1 (plist-get iar--cycle-state :exit-code))))
      (kill-buffer buf))))

(ert-deftest test-truncated-output-grace-shares-budget-with-runaway ()
  "The truncated-output grace shares :runaway-recovery-given with the
per-response runaway: a runaway recovery followed by a truncated fire
ends the cycle (one snap-out OR one landing per cycle)."
  (let ((buf (get-buffer-create "*test-truncgrace3*"))
        (sent 0))
    (unwind-protect
        (let ((iar-cycle-context-limit-chars 100000)
              (iar--cycle-state (iar--cycle-make-state "test" buf "Continue." 40))
              (iar--one-shot-state nil)
              (iar--cycle-error-strikes 0)
              (iar--reqlog-last-stop "stop")
              (iar--reqlog-last-tokens-out 1000))
          (with-current-buffer buf (erase-buffer) (insert (make-string 100 ?x)))
          (cl-letf (((symbol-function 'gptel-send)
                     (lambda () (cl-incf sent))))
            (with-current-buffer buf
              ;; Per-response runaway fires first: gives recovery.
              (let ((start (point)))
                (dotimes (_ 20) (insert "Same line.\n"))
                (iar--cycle-post-response-handler start (point))))
            (should (= 1 sent))
            (should (plist-get iar--cycle-state :runaway-recovery-given))
            ;; Then a truncated fire: budget already spent -> ends.
            (setq iar--reqlog-last-stop "length"
                  iar--reqlog-last-tokens-out 65536)
            (with-current-buffer buf
              (let ((start (point)))
                (insert "truncated after runaway\n")
                (iar--cycle-post-response-handler start (point)))))
          (should (plist-get iar--cycle-state :completed))
          (should (= 1 (plist-get iar--cycle-state :exit-code))))
      (kill-buffer buf))))
