;; -*- lexical-binding: t; -*-

;;; Tests for the cross-response repetition guard (c111 finding).
;;; The deepseek-v4-flash text-only loop repeats the SAME paragraph
;;; ACROSS responses (5-10 reps each, under the per-response 20-line
;;; threshold), so the per-response output-runaway guard never fires
;;; until the final 65536-token response. This guard tracks the
;;; most-repeated line across the last N responses and fires when its
;;; cumulative count crosses the threshold -- catching the loop at
;;; response ~5-6, saving ~17 requests of burn per occurrence.
;;; Pure-function tests: no live processes, no network.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)

(require 'iar-agent-cycle)

;;; --- iar--cycle-cross-response-repetition-p ---

(ert-deftest test-cross-rep-fires-on-accumulated-repetition ()
  "A line repeated 10 times across several responses (each under the
per-response 20-line threshold) accumulates past the cross-response
threshold and fires on the 3rd response (30 cumulative)."
  (let ((buf (get-buffer-create "*test-crossrep1*")))
    (unwind-protect
        (let ((iar-cycle-cross-response-window 5)
              (iar-cycle-cross-response-threshold 30)
              (iar--cycle-state (iar--cycle-make-state "test" buf "Continue." 40))
              (iar--one-shot-state nil))
          (with-current-buffer buf
            (erase-buffer)
            ;; 4 responses, 10 reps each = 40 cumulative > 30 threshold.
            (dotimes (i 4)
              (let ((start (point)))
                (dotimes (_ 10) (insert "Let me think about what I can actually do this cycle.\n"))
                (if (< i 2)
                    (should-not (iar--cycle-cross-response-repetition-p start (point)))
                  (should (iar--cycle-cross-response-repetition-p start (point))))))))
      (kill-buffer buf))))

(ert-deftest test-cross-rep-does-not-fire-below-threshold ()
  "Distinct lines across responses never accumulate past the threshold."
  (let ((buf (get-buffer-create "*test-crossrep2*")))
    (unwind-protect
        (let ((iar-cycle-cross-response-window 5)
              (iar-cycle-cross-response-threshold 30)
              (iar--cycle-state (iar--cycle-make-state "test" buf "Continue." 40))
              (iar--one-shot-state nil))
          (with-current-buffer buf
            (erase-buffer)
            (dotimes (i 4)
              (let ((start (point)))
                (dotimes (_ 10) (insert (format "Distinct line %d.\n" i)))
                (should-not (iar--cycle-cross-response-repetition-p start (point)))))))
      (kill-buffer buf))))

(ert-deftest test-cross-rep-window-evicts-oldest ()
  "The sliding window evicts the oldest response, so a line that stops
repeating falls out of the window and no longer accumulates."
  (let ((buf (get-buffer-create "*test-crossrep3*")))
    (unwind-protect
        (let ((iar-cycle-cross-response-window 3)
              (iar-cycle-cross-response-threshold 30)
              (iar--cycle-state (iar--cycle-make-state "test" buf "Continue." 40))
              (iar--one-shot-state nil))
          (with-current-buffer buf
            (erase-buffer)
            ;; 3 responses of 10 reps = 30, at threshold -> fires on 3rd.
            (dotimes (i 3)
              (let ((start (point)))
                (dotimes (_ 10) (insert "Repeated line.\n"))
                (if (< i 2)
                    (should-not (iar--cycle-cross-response-repetition-p start (point)))
                  (should (iar--cycle-cross-response-repetition-p start (point))))))
            ;; Now 3 responses of DISTINCT lines: the repeated line
            ;; falls out of the window (evicted) and no longer fires.
            (dotimes (i 3)
              (let ((start (point)))
                (dotimes (_ 10) (insert (format "Fresh line %d.\n" i)))
                (should-not (iar--cycle-cross-response-repetition-p start (point)))))))
      (kill-buffer buf))))

(ert-deftest test-cross-rep-ignores-empty-region ()
  "An empty region (start == end) is not a repetition."
  (let ((buf (get-buffer-create "*test-crossrep4*")))
    (unwind-protect
        (let ((iar--cycle-state (iar--cycle-make-state "test" buf "Continue." 40))
              (iar--one-shot-state nil))
          (with-current-buffer buf
            (erase-buffer)
            (let ((p (point)))
              (should-not (iar--cycle-cross-response-repetition-p p p)))))
      (kill-buffer buf))))

(ert-deftest test-cross-rep-ends-cycle-on-second-fire ()
  "A cross-response repetition in the continue branch gives ONE
recovery round-trip, then a second fire ends the cycle with exit 1 --
the same contract as the per-response runaway, sharing
:runaway-recovery-given. Threshold 15: call 1 (10 reps) is under and
falls to the continue branch (gptel-send via continue); call 2 (20
cumulative) fires and gives recovery (gptel-send via recovery); call 3
(30 cumulative) fires again, recovery already given -> cycle ends,
exit 1."
  (let ((buf (get-buffer-create "*test-crossrep5*"))
        (sent 0))
    (unwind-protect
        (let ((iar-cycle-context-limit-chars 100000)
              (iar-cycle-cross-response-window 5)
              (iar-cycle-cross-response-threshold 15)
              (iar--cycle-state (iar--cycle-make-state "test" buf "Continue." 40))
              (iar--one-shot-state nil)
              (iar--cycle-error-strikes 0))
          (with-current-buffer buf (insert (make-string 200 ?x)))
          (cl-letf (((symbol-function 'gptel-send)
                     (lambda () (cl-incf sent))))
            (with-current-buffer buf
              ;; Call 1: 10 reps, under threshold -> continue branch
              ;; (gptel-send via continue), no recovery.
              (let ((start (point)))
                (dotimes (_ 10) (insert "Repeated line.\n"))
                (iar--cycle-post-response-handler start (point))))
            (should (= 1 sent))  ; continue-path send
            (should-not (plist-get iar--cycle-state :runaway-recovery-given))
            (should-not (plist-get iar--cycle-state :completed))
            ;; Call 2: 10 more = 20 >= 15 -> fire, recovery round-trip.
            (with-current-buffer buf
              (let ((start (point)))
                (dotimes (_ 10) (insert "Repeated line.\n"))
                (iar--cycle-post-response-handler start (point))))
            (should (= 2 sent))  ; recovery-path send
            (should (plist-get iar--cycle-state :runaway-recovery-given))
            (should-not (plist-get iar--cycle-state :completed))
            ;; Call 3: 10 more = 30 -> fire again, recovery already
            ;; given -> cycle ends, exit 1.
            (with-current-buffer buf
              (let ((start (point)))
                (dotimes (_ 10) (insert "Repeated line.\n"))
                (iar--cycle-post-response-handler start (point)))))
          (should (plist-get iar--cycle-state :completed))
          (should (= 1 (plist-get iar--cycle-state :exit-code))))
      (kill-buffer buf))))

;;; --- Scaffolding exclusion (aria c54/c55 fix) ---

(ert-deftest test-cross-rep-ignores-tool-block-scaffolding ()
  "Tool-call display blocks (propertized 'gptel '(tool . id)) must NOT
count toward the runaway census -- aria c54/c55 found the fence firing
on ~95 tool-call display blocks (5211 lines, 131 '```' + 66 identical
truncated previews) with zero model repetition. 30 identical tool-block
previews + 5 model lines must NOT fire; 25 identical MODEL lines MUST."
  (let ((buf (get-buffer-create "*test-crossrep-scaffold*")))
    (unwind-protect
        (let ((iar-cycle-cross-response-window 5)
              (iar-cycle-cross-response-threshold 30)
              (iar--cycle-state (iar--cycle-make-state "test" buf "Continue." 40))
              (iar--one-shot-state nil))
          (with-current-buffer buf
            (erase-buffer)
            ;; 30 identical tool-block previews (propertized 'ignore)
            (dotimes (_ 30)
              (insert (propertize "``` tool (execute_code_local :command \"cd /root/i.ar ...)"
                                  'gptel 'ignore)
                      "\n"))
            ;; 5 model lines -- under the 20-line per-response threshold,
            ;; and 5 < 30 cross-response threshold. Must NOT fire.
            (let ((start (point)))
              (dotimes (_ 5) (insert "Normal model analysis line.\n"))
              (should-not (iar--cycle-cross-response-repetition-p start (point))))))
      (kill-buffer buf))))

(ert-deftest test-cross-rep-model-lines-still-count ()
  "Model text (unpropertized) must still accumulate across responses --
the guard must not be silenced by the scaffolding filter."
  (let ((buf (get-buffer-create "*test-crossrep-model*")))
    (unwind-protect
        (let ((iar-cycle-cross-response-window 5)
              (iar-cycle-cross-response-threshold 30)
              (iar--cycle-state (iar--cycle-make-state "test" buf "Continue." 40))
              (iar--one-shot-state nil))
          (with-current-buffer buf
            (erase-buffer)
            ;; 4 responses of 10 model lines each = 40 cumulative > 30.
            (dotimes (i 4)
              (let ((start (point)))
                (dotimes (_ 10) (insert "Let me think about what I can actually do.\n"))
                (if (< i 2)
                    (should-not (iar--cycle-cross-response-repetition-p start (point)))
                  (should (iar--cycle-cross-response-repetition-p start (point))))))))
      (kill-buffer buf))))

(ert-deftest test-cross-rep-tool-result-content-excluded ()
  "Tool RESULT content (propertized 'gptel '(tool . id)) must NOT count
-- identical tool results (e.g. the same error repeated) are scaffolding,
not model speech."
  (let ((buf (get-buffer-create "*test-crossrep-toolresult*")))
    (unwind-protect
        (let ((iar-cycle-cross-response-window 5)
              (iar-cycle-cross-response-threshold 30)
              (iar--cycle-state (iar--cycle-make-state "test" buf "Continue." 40))
              (iar--one-shot-state nil))
          (with-current-buffer buf
            (erase-buffer)
            ;; 30 identical tool RESULT blocks (propertized (tool . id))
            (dotimes (_ 30)
              (insert (propertize "Error: Tool 'foo' is not available. Available tools: bar"
                                  'gptel '(tool . 42))
                      "\n"))
            ;; 5 model lines -- must NOT fire.
            (let ((start (point)))
              (dotimes (_ 5) (insert "Normal model analysis line.\n"))
              (should-not (iar--cycle-cross-response-repetition-p start (point))))))
      (kill-buffer buf))))
