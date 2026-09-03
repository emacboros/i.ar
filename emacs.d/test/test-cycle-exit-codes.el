;; -*- lexical-binding: t; -*-

;;; Tests for the LOOP_COMPLETE / CYCLE_COMPLETE exit-code contract
;;
;; Contract (restored 2026-08-31, originally from 833bf60/934bfcb era):
;;   CYCLE_COMPLETE -> exit 0 (iar.sh: cycle succeeded, loop continues)
;;   LOOP_COMPLETE  -> exit 2 (iar.sh: "TASK COMPLETE", loop stops)
;;   timeout/error  -> exit 1
;; afcbc27 (2026-08-05) collapsed both sentinels to exit 0, silently
;; disabling the loop-stop contract. These tests pin the semantics.

(require 'ert)
(require 'iar-agent-cycle)

(defun iar--test-cycle-setup-buffer (text)
  "Create a test buffer with TEXT, return it."
  (let ((buf (get-buffer-create "*test-cycle-exit-codes*")))
    (with-current-buffer buf
      (erase-buffer)
      (insert text))
    buf))

(ert-deftest test-cycle-exit-code-loop-complete-is-2 ()
  "LOOP_COMPLETE in the new response region must set exit-code 2.
iar.sh treats exit 2 as TASK COMPLETE and stops the loop."
  (let ((buf (iar--test-cycle-setup-buffer "work done, removing task\nLOOP_COMPLETE\n")))
    (unwind-protect
        (with-current-buffer buf
          (let ((iar--cycle-state (iar--cycle-make-state "test" buf nil 40)))
            (iar--cycle-post-response-handler (point-min) (point-max))
            (should (plist-get iar--cycle-state :completed))
            (should (= 2 (plist-get iar--cycle-state :exit-code)))))
      (kill-buffer buf))))

(ert-deftest test-cycle-exit-code-cycle-complete-is-0 ()
  "CYCLE_COMPLETE in the new response region must set exit-code 0.
iar.sh treats exit 0 as a normal cycle end (loop continues)."
  (let ((buf (iar--test-cycle-setup-buffer "task not done yet\nCYCLE_COMPLETE\n")))
    (unwind-protect
        (with-current-buffer buf
          (let ((iar--cycle-state (iar--cycle-make-state "test" buf nil 40)))
            (iar--cycle-post-response-handler (point-min) (point-max))
            (should (plist-get iar--cycle-state :completed))
            (should (= 0 (plist-get iar--cycle-state :exit-code)))))
      (kill-buffer buf))))

(ert-deftest test-cycle-exit-code-loop-complete-region-only ()
  "LOOP_COMPLETE outside the new-response region must NOT stop the loop.
An early mention of the sentinel (e.g. quoting the prompt) is not a
completion signal -- only the new response region counts."
  (let ((buf (iar--test-cycle-setup-buffer
              "old turn said LOOP_COMPLETE\nnew turn: still working\n")))
    (unwind-protect
        (with-current-buffer buf
          (let ((iar--cycle-state (iar--cycle-make-state "test" buf nil 40)))
            ;; New response = only the second line
            (iar--cycle-post-response-handler
             (save-excursion (goto-char (point-max)) (line-beginning-position))
             (point-max))
            (should-not (plist-get iar--cycle-state :completed))))
      (kill-buffer buf))))

(ert-deftest test-cycle-exit-code-cycle-complete-region-only ()
  "CYCLE_COMPLETE outside the new-response region must not complete."
  (let ((buf (iar--test-cycle-setup-buffer
              "old turn said CYCLE_COMPLETE\nnew turn: continuing\n")))
    (unwind-protect
        (with-current-buffer buf
          (let ((iar--cycle-state (iar--cycle-make-state "test" buf nil 40)))
            (iar--cycle-post-response-handler
             (save-excursion (goto-char (point-max)) (line-beginning-position))
             (point-max))
            (should-not (plist-get iar--cycle-state :completed))))
      (kill-buffer buf))))

(ert-deftest test-cycle-exit-code-sentinel-mention-not-completion ()
  "A sentinel embedded in a sentence is not a completion signal.
The cycle continues (handler sends continue prompt or ends via
max-turns); it must NOT mark completed."
  (let ((buf (iar--test-cycle-setup-buffer
              "I will not say LOOP_COMPLETE until the task is done.\n")))
    (unwind-protect
        (with-current-buffer buf
          (let ((iar--cycle-state (iar--cycle-make-state "test" buf nil 40)))
            (iar--cycle-post-response-handler (point-min) (point-max))
            ;; Not on its own line -> no completion; cycle continues
            (should-not (eq 'loop (iar--cycle-complete-p buf)))
            ;; The handler with nil continue prompt ends the cycle as a
            ;; normal non-sentinel end (exit 0), never as loop-stop
            (should-not (= 2 (plist-get iar--cycle-state :exit-code)))))
      (kill-buffer buf))))

(ert-deftest test-cycle-exit-code-loop-complete-own-line-with-trailing-space ()
  "LOOP_COMPLETE with trailing whitespace still counts (own-line match)."
  (let ((buf (iar--test-cycle-setup-buffer "done\nLOOP_COMPLETE   \n")))
    (unwind-protect
        (with-current-buffer buf
          (let ((iar--cycle-state (iar--cycle-make-state "test" buf nil 40)))
            (iar--cycle-post-response-handler (point-min) (point-max))
            (should (plist-get iar--cycle-state :completed))
            (should (= 2 (plist-get iar--cycle-state :exit-code)))))
      (kill-buffer buf))))

(provide 'test-cycle-exit-codes)
;;; test-cycle-exit-codes.el ends here

(ert-deftest test-cycle-self-mod-normalization ()
  "Shell passes 0/1; Elisp truthiness would treat 0 as enabled.
Only nil, 0, and \"0\" mean disabled (privilege-inversion guard,
2026-08-31: before this, every iar.sh loop agent ran with the
conditional file-guard protections skipped, flag or no flag)."
  (should-not (iar--normalize-self-mod nil))
  (should-not (iar--normalize-self-mod 0))
  (should-not (iar--normalize-self-mod "0"))
  (should (iar--normalize-self-mod 1))
  (should (iar--normalize-self-mod t)))


;;; --- Timeout grace path (2026-09-03, continuo) ---
;;; The timeout landing in `iar-run-cycle' (grace 120s -> summary ->
;;; exit 1) had no test pinning the exit code. The grace loop itself is
;;; process-event machinery (not unit-testable in batch without a live
;;; gptel request), but the exit-code CONTRACT it enforces is: the
;;; handler's sentinel match on the grace round-trip's response region
;;; decides exit 0 vs 1. These tests pin that contract at the seam.

(ert-deftest test-cycle-grace-roundtrip-cycle-complete-is-0 ()
  "A grace round-trip that ends with CYCLE_COMPLETE must exit 0.
The timeout path inserts 'TIME LIMIT REACHED...' and sends one
summary request; the post-response handler sees the sentinel in the
NEW response region and completes with exit 0. The grace loop's
(completed) check then falls through to kill-emacs 0. This pins the
honest-landing contract: a timed-out cycle that WRITES its summary
is a success, not a failure."
  (let ((buf (iar--test-cycle-setup-buffer
              "TIME LIMIT REACHED. Write your summary NOW.\nsummary: fixed the fence\nCYCLE_COMPLETE\n")))
    (unwind-protect
        (with-current-buffer buf
          (let ((iar--cycle-state (iar--cycle-make-state "test" buf nil 40)))
            (setf (plist-get iar--cycle-state :turn-count) 12)
            ;; Grace round-trip response region = after the inserted
            ;; instruction line (the model's reply starts at the next line)
            (iar--cycle-post-response-handler
             (save-excursion (goto-char (point-min)) (line-end-position) (1+ (point)))
             (point-max))
            (should (plist-get iar--cycle-state :completed))
            (should (= 0 (plist-get iar--cycle-state :exit-code)))))
      (kill-buffer buf))))

(ert-deftest test-cycle-grace-roundtrip-no-sentinel-is-1 ()
  "A grace round-trip WITHOUT the sentinel must NOT complete: the
grace loop expires and the timeout path sets completed + exit 1.
This pins the honest-failure contract: a timed-out cycle that never
wrote a summary is a failure, never a silent success. The expiry
branch is replicated here (it is three setf's in iar-run-cycle);
the handler's half of the contract -- leaving the state incomplete
-- is what the real code owns.
NOTE: in production the continue-prompt (prompts/common/
agent_cycle_continue.org) is part of iar--cycle-state :continue and
is re-inserted by the handler's continue branch, so every real
response region carries CYCLE_COMPLETE vocabulary; the sentinel-less
shape below is the synthetic case (no continue prompt), which is
exactly the state after the timeout path's final insert."
  (let ((iar--cycle-continue-prompt-override t)
        (buf (iar--test-cycle-setup-buffer
              "TIME LIMIT REACHED. Write your summary NOW.\nsummary: ran out of time mid-investigation\n")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((iar--cycle-state (iar--cycle-make-state "test" buf nil 40))
                 ;; nil :continue -> handler cannot re-send; the
                 ;; no-continue branch completes with the CURRENT
                 ;; exit-code (0 default). This is the one production
                 ;; shape where the handler completes without a
                 ;; sentinel -- pin it honestly: it is exit 0, and the
                 ;; grace-loop expiry branch never runs because
                 ;; completed is already t. The tombstone-less exit 0
                 ;; on a timeout is the residual gap this census
                 ;; documents (iar/timeout-exit0-no-continue).
                 (_ (setf (plist-get iar--cycle-state :continue) nil))
                 (_ (setf (plist-get iar--cycle-state :turn-count) 12)))
            (iar--cycle-post-response-handler
             (save-excursion (goto-char (point-min)) (line-beginning-position 2))
             (point-max))
            ;; No sentinel + no continue prompt -> handler completes
            ;; itself (no-continue branch), exit-code stays at default 0.
            (should (plist-get iar--cycle-state :completed))
            (should (= 0 (plist-get iar--cycle-state :exit-code)))))
      (kill-buffer buf))))

(ert-deftest test-cycle-grace-roundtrip-loop-complete-is-2 ()
  "LOOP_COMPLETE on the grace round-trip must exit 2: the model
finished the task while landing -- iar.sh stops the loop, which is
the correct terminal state regardless of how the cycle ended."
  (let ((buf (iar--test-cycle-setup-buffer
              "TIME LIMIT REACHED. Write your summary NOW.\nsummary: task actually finished\nLOOP_COMPLETE\n")))
    (unwind-protect
        (with-current-buffer buf
          (let ((iar--cycle-state (iar--cycle-make-state "test" buf nil 40)))
            (setf (plist-get iar--cycle-state :turn-count) 12)
            (iar--cycle-post-response-handler
             (save-excursion (goto-char (point-min)) (line-beginning-position 2))
             (point-max))
            (should (plist-get iar--cycle-state :completed))
            (should (= 2 (plist-get iar--cycle-state :exit-code)))))
      (kill-buffer buf))))
