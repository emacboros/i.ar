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
