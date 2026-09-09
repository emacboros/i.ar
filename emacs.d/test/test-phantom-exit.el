;; -*- lexical-binding: t; -*-
;; c132 regression tests: sentinel inside thinking (gptel 'ignore) must NOT end a cycle.
(require 'ert)
(require 'iar-agent-cycle)

(defun iar--test-phantom-buffer (text)
  "Insert TEXT into a fresh buffer with gptel text-properties emulating
gptel's thinking-block insertion (gptel-include-reasoning 'ignore)."
  (let ((buf (get-buffer-create "*test-phantom-exit*")))
    (with-current-buffer buf
      (erase-buffer)
      ;; thinking block: fenced with 'ignore properties (like gptel does)
      (let ((think "``` reasoning\nWe are done. I will signal CYCLE_COMPLETE now.\n```\n")
            (content "CYCLE_COMPLETE\n"))
        (insert (propertize think 'gptel 'ignore))
        (insert content)))
    buf))

(ert-deftest test-phantom-exit-sentinel-in-thinking-not-complete ()
  "c132: a sentinel inside a gptel 'ignore (thinking) span must NOT
complete the cycle. Live-fire: continuo turn 557 (req 260909165458-70)
ended exit 0 with zero durable output because the sentinel matched
inside nemotron's thinking block."
  (let ((buf (iar--test-phantom-buffer "")))
    (unwind-protect
        (with-current-buffer buf
          (erase-buffer)
          (insert (propertize "``` reasoning\nI should signal CYCLE_COMPLETE now.\n```\n"))
          (should-not (iar--cycle-complete-p (current-buffer) (point-min) (point-max))))
      (kill-buffer buf))))

(ert-deftest test-phantom-exit-real-sentinel-still-matches ()
  "A sentinel in MODEL text (no gptel property) still completes."
  (let ((buf (get-buffer-create "*test-phantom-exit*")))
    (unwind-protect
        (with-current-buffer buf
          (erase-buffer)
          (insert (propertize "``` reasoning\nI should signal CYCLE_COMPLETE now.\n```\n"))
          (insert "CYCLE_COMPLETE\n")
          (should (eq 'cycle (iar--cycle-complete-p (current-buffer) (point-min) (point-max)))))
      (kill-buffer buf))))

(ert-deftest test-phantom-exit-sentinel-in-tool-span-not-complete ()
  "A sentinel inside a tool-call span (gptel (tool . id)) must NOT complete."
  (let ((buf (get-buffer-create "*test-phantom-exit*")))
    (unwind-protect
        (with-current-buffer buf
          (erase-buffer)
          (insert (propertize "tool output mentioning CYCLE_COMPLETE\n" 'gptel '(tool . "call_1")))
          (should-not (iar--cycle-complete-p (current-buffer) (point-min) (point-max))))
      (kill-buffer buf))))

(ert-deftest test-phantom-exit-prose-then-sentinel-still-matches ()
  "c59 case preserved: leading prose on the sentinel line still matches."
  (let ((buf (get-buffer-create "*test-phantom-exit*")))
    (unwind-protect
        (with-current-buffer buf
          (erase-buffer)
          (insert "all steps complete -> CYCLE_COMPLETE.\n")
          (should (eq 'cycle (iar--cycle-complete-p (current-buffer) (point-min) (point-max)))))
      (kill-buffer buf))))

(ert-deftest test-phantom-exit-c39-negative-case-preserved ()
  "c39 case preserved: prose containing the token with trailing text does not match."
  (let ((buf (get-buffer-create "*test-phantom-exit*")))
    (unwind-protect
        (with-current-buffer buf
          (erase-buffer)
          (insert "end with CYCLE_COMPLETE time. later\n")
          (should-not (iar--cycle-complete-p (current-buffer) (point-min) (point-max))))
      (kill-buffer buf))))
