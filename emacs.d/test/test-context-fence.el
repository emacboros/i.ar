;; -*- lexical-binding: t; -*-

;;; Tests for iar-context-fence.el

(require 'ert)
(require 'cl-lib)

(require 'iar-context-fence)

;;; --- Gate plumbing ---

(ert-deftest test-ctx-fence-disabled ()
  "When the fence is disabled, all calls pass."
  (let ((iar-context-fence nil)
        (iar--reqlog-last-tokens-in 999999)
        (iar--cycle-state (list :agent "t" :tool-call-count 0)))
    (should-not (iar--context-fence-pre-call (list :name "read_file")))))

(ert-deftest test-ctx-fence-no-tokens-yet ()
  "First request of a run (no tokens_in published) -> allow."
  (let ((iar-context-fence t)
        (iar--reqlog-last-tokens-in nil)
        (iar--cycle-state (list :agent "t" :tool-call-count 0)))
    (should-not (iar--context-fence-pre-call (list :name "read_file")))))

(ert-deftest test-ctx-fence-no-state ()
  "No active state (interactive session) -> allow."
  (let ((iar-context-fence t)
        (iar--reqlog-last-tokens-in 999999)
        (iar--cycle-state nil)
        (iar--one-shot-state nil))
    (should-not (iar--context-fence-pre-call (list :name "read_file")))))

(ert-deftest test-ctx-fence-under-caps ()
  "tokens_in under both caps -> allow."
  (let ((iar-context-fence t)
        (iar--reqlog-last-tokens-in 1000)
        (iar-context-soft-cap 131072)
        (iar-context-hard-cap 524288)
        (iar--cycle-state (list :agent "t" :tool-call-count 0)))
    (should-not (iar--context-fence-pre-call (list :name "read_file")))))

;;; --- Soft warn ---

(ert-deftest test-ctx-fence-soft-warn-blocks-once ()
  "tokens_in >= soft cap -> ONE block with converge notice; retry
passes; the warn does not fire twice."
  (let ((iar-context-fence t)
        (iar--reqlog-last-tokens-in 140000)
        (iar-context-soft-cap 131072)
        (iar-context-hard-cap 524288)
        (iar--cycle-state (list :agent "t" :tool-call-count 0)))
    (let ((r1 (iar--context-fence-pre-call (list :name "read_file"))))
      (should (plist-get r1 :block))
      (should (string-match-p "CONTEXT FAT" (plist-get r1 :block)))
      ;; Retry passes (warned flag set)
      (should-not (iar--context-fence-pre-call (list :name "read_file")))
      ;; And a second warn never fires even on another call
      (should-not (iar--context-fence-pre-call (list :name "execute_code_local"))))))

;;; --- Hard cap ---

(ert-deftest test-ctx-fence-hard-cap-blocks ()
  "tokens_in >= hard cap -> block with landing instruction."
  (let ((iar-context-fence t)
        (iar--reqlog-last-tokens-in 600000)
        (iar-context-soft-cap 131072)
        (iar-context-hard-cap 524288)
        (iar-context-hard-cap-blocks 5)
        (iar--cycle-state (list :agent "t" :tool-call-count 0)))
    (let ((r (iar--context-fence-pre-call (list :name "read_file"))))
      (should (plist-get r :block))
      (should (string-match-p "HARD CAP" (plist-get r :block)))
      (should (string-match-p "CYCLE_COMPLETE" (plist-get r :block))))))

(ert-deftest test-ctx-fence-hard-cap-memory-tools-pass ()
  "Memory/record tools pass at the hard cap: the landing IS the
memory pass."
  (let ((iar-context-fence t)
        (iar--reqlog-last-tokens-in 600000)
        (iar-context-soft-cap 131072)
        (iar-context-hard-cap 524288)
        (iar-context-hard-cap-blocks 5)
        (iar--cycle-state (list :agent "t" :tool-call-count 0)))
    (dolist (tool '("append_file" "write_file" "write_subtask"
                    "write_roadmap" "git_commit" "send_telegram"))
      (should-not (iar--context-fence-pre-call (list :name tool))))))

(ert-deftest test-ctx-fence-hard-cap-runaway-ends-run ()
  "After iar-context-hard-cap-blocks ignored blocks, the run ends:
completed + exit 1."
  (let ((iar-context-fence t)
        (iar--reqlog-last-tokens-in 600000)
        (iar-context-soft-cap 131072)
        (iar-context-hard-cap 524288)
        (iar-context-hard-cap-blocks 5)
        (iar--cycle-state (list :agent "t" :tool-call-count 0 :exit-code 0)))
    ;; 4 blocks: still blocking, not ending
    (dotimes (_ 4)
      (should (plist-get (iar--context-fence-pre-call (list :name "read_file")) :block)))
    (should-not (plist-get iar--cycle-state :completed))
    ;; 5th block: run ends
    (let ((r (iar--context-fence-pre-call (list :name "read_file"))))
      (should (plist-get r :block))
      (should (plist-get iar--cycle-state :completed))
      (should (= 1 (plist-get iar--cycle-state :exit-code))))))

;;; --- One-shot parity ---

(ert-deftest test-ctx-fence-one-shot-parity ()
  "One-shot runs are fenced too (mode-generic fences, c39 parity)."
  (let ((iar-context-fence t)
        (iar--reqlog-last-tokens-in 600000)
        (iar-context-soft-cap 131072)
        (iar-context-hard-cap 524288)
        (iar-context-hard-cap-blocks 5)
        (iar--cycle-state nil)
        (iar--one-shot-state (list :agent "t" :tool-call-count 0)))
    (let ((r (iar--context-fence-pre-call (list :name "read_file"))))
      (should (plist-get r :block))
      ;; One-shot must NOT be told to write CYCLE_COMPLETE (c39 law)
      (should-not (string-match-p "CYCLE_COMPLETE" (plist-get r :block))))))

;;; --- Soft warn suppressed at hard cap ---

(ert-deftest test-ctx-fence-hard-wins-over-soft ()
  "At hard-cap range, the hard branch wins (no soft warn noise)."
  (let ((iar-context-fence t)
        (iar--reqlog-last-tokens-in 600000)
        (iar-context-soft-cap 131072)
        (iar-context-hard-cap 524288)
        (iar-context-hard-cap-blocks 5)
        (iar--cycle-state (list :agent "t" :tool-call-count 0)))
    (let ((r (iar--context-fence-pre-call (list :name "read_file"))))
      (should (string-match-p "HARD CAP" (plist-get r :block)))
      (should (plist-get iar--cycle-state :ctx-blocks))
      (should-not (plist-get iar--cycle-state :ctx-warned)))))

;;; --- Request-log integration ---

(ert-deftest test-reqlog-last-tokens-in-reset ()
  "iar--reqlog-reset-last clears tokens-in (no stale cross-cycle reads)."
  (setq iar--reqlog-last-tokens-in 123456)
  (iar--reqlog-reset-last)
  (should-not iar--reqlog-last-tokens-in))