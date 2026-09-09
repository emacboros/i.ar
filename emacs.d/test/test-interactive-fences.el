;; -*- lexical-binding: t; -*-

;;; Tests for the interactive fences (aria-0006, cycle c107).
;;; Interactive gptel sessions have no cycle/one-shot state, so every
;;; fence dispatching on (or iar--cycle-state iar--one-shot-state)
;;; was a silent no-op there -- the first INTERACTIVE text-loop
;;; degeneration (2026-09-08) had no instrument watching. This adds
;;; an optional per-buffer state + global post-response fence.
;;; Default OFF (nacho-test class): the tests bind the defcustom on.
;;; Pure-function tests: no live processes, no network.

(require 'ert)
(require 'cl-lib)

(require 'iar-agent-cycle)

(defun test-if--run-response (buf text)
  "Insert TEXT into BUF and run the interactive fence handler on the
new region. Returns the region as (start . end)."
  (with-current-buffer buf
    (let ((start (point)))
      (insert text)
      (iar--interactive-fence-handler start (point))
      (cons start (point)))))

;;; --- default-off contract ---

(ert-deftest test-int-fences-off-by-default ()
  "With iar-interactive-fences nil (the default), the handler is a
no-op: no state created, no recovery sent."
  (let ((buf (get-buffer-create "*test-intf-off*")))
    (unwind-protect
        (let ((iar-interactive-fences nil)
              (iar--cycle-state nil)
              (iar--one-shot-state nil)
              (sent 0))
          (cl-letf (((symbol-function 'gptel-send)
                     (lambda () (cl-incf sent))))
            (with-current-buffer buf
              (erase-buffer)
              (setq iar--interactive-state nil)
              (dotimes (_ 25) (insert "Loop line repeated.\n"))
              (iar--interactive-fence-handler (point-min) (point)))
            (should (= sent 0))
            (should (null (buffer-local-value 'iar--interactive-state buf)))))
      (kill-buffer buf))))

;;; --- per-response runaway ---

(ert-deftest test-int-fences-runaway-recovery-then-disarm ()
  "First runaway fire -> recovery round-trip (gptel-send called once,
:runaway-recovery-given set). Second fire -> disarm: no send, state
marked :disarmed, and a THIRD fire is a silent no-op."
  (let ((buf (get-buffer-create "*test-intf-run2*")))
    (unwind-protect
        (let ((iar-interactive-fences t)
              (iar--cycle-state nil)
              (iar--one-shot-state nil)
              (sent 0))
          (cl-letf (((symbol-function 'gptel-send)
                     (lambda () (cl-incf sent))))
            (with-current-buffer buf
              (erase-buffer)
              (setq iar--interactive-state nil)
              ;; Fire 1: 25 identical lines -> recovery.
              (let ((start (point)))
                (dotimes (_ 25) (insert "Loop line.\n"))
                (iar--interactive-fence-handler start (point)))
              (should (= sent 1))
              (should (plist-get iar--interactive-state
                                 :runaway-recovery-given))
              (should-not (plist-get iar--interactive-state :disarmed))
              ;; Fire 2: another runaway -> disarm, NO send.
              (let ((start (point)))
                (dotimes (_ 25) (insert "Loop line.\n"))
                (iar--interactive-fence-handler start (point)))
              (should (= sent 1))
              (should (plist-get iar--interactive-state :disarmed))
              ;; Fire 3: disarmed -> silent no-op.
              (let ((start (point)))
                (dotimes (_ 25) (insert "Loop line.\n"))
                (iar--interactive-fence-handler start (point)))
              (should (= sent 1)))))
      (kill-buffer buf))))

;;; --- cross-response repetition ---

(ert-deftest test-int-fences-cross-rep-fires ()
  "The same line repeated across responses accumulates past the
cross-response threshold (30) and fires on the 4th response of 10."
  (let ((buf (get-buffer-create "*test-intf-cross1*")))
    (unwind-protect
        (let ((iar-interactive-fences t)
              (iar--cycle-state nil)
              (iar--one-shot-state nil)
              (sent 0))
          (cl-letf (((symbol-function 'gptel-send)
                     (lambda () (cl-incf sent))))
            (with-current-buffer buf
              (erase-buffer)
              (setq iar--interactive-state nil)
              (dotimes (i 4)
                (let ((start (point)))
                  (dotimes (_ 10) (insert "Same paragraph line.\n"))
                  (iar--interactive-fence-handler start (point)))
                (if (< i 2)
                    (should (= sent 0))
                  (should (= sent 1))))))
          ;; Recovery given exactly once even after more responses.
          (with-current-buffer buf
            (let ((start (point)))
              (dotimes (_ 10) (insert "Same paragraph line.\n"))
              (iar--interactive-fence-handler start (point)))
            (should (= sent 1))))
      (kill-buffer buf))))

;;; --- cycle precedence ---

(ert-deftest test-int-fences-cycle-state-takes-precedence ()
  "With a cycle state active, the interactive handler must not fire
-- the cycle's own post-response handler owns the buffer. No state
created, no send."
  (let ((buf (get-buffer-create "*test-intf-cycle*")))
    (unwind-protect
        (let ((iar-interactive-fences t)
              (sent 0))
          (cl-letf (((symbol-function 'gptel-send)
                     (lambda () (cl-incf sent))))
            (with-current-buffer buf
              (erase-buffer)
              (setq iar--interactive-state nil)
              (let ((iar--cycle-state
                     (iar--cycle-make-state "test" buf "Continue." 40))
                    (iar--one-shot-state nil))
                (let ((start (point)))
                  (dotimes (_ 25) (insert "Loop line.\n"))
                  (iar--interactive-fence-handler start (point)))
                (should (= sent 0))
                (should (null iar--interactive-state)))))
          )
      (kill-buffer buf))))

;;; --- one-shot precedence ---

(ert-deftest test-int-fences-one-shot-state-takes-precedence ()
  "With a one-shot state active, the interactive handler must not
fire -- the one-shot's own handler owns the buffer."
  (let ((buf (get-buffer-create "*test-intf-oneshot*")))
    (unwind-protect
        (let ((iar-interactive-fences t)
              (iar--cycle-state nil)
              (sent 0))
          (cl-letf (((symbol-function 'gptel-send)
                     (lambda () (cl-incf sent))))
            (with-current-buffer buf
              (erase-buffer)
              (setq iar--interactive-state nil)
              (let ((iar--one-shot-state
                     (list :agent "test" :turn-count 0)))
                (let ((start (point)))
                  (dotimes (_ 25) (insert "Loop line.\n"))
                  (iar--interactive-fence-handler start (point)))
                (should (= sent 0))
                (should (null iar--interactive-state))))))
      (kill-buffer buf))))

;;; --- clean responses never fire ---

(ert-deftest test-int-fences-clean-responses-noop ()
  "Distinct, short responses never fire the fence and never send."
  (let ((buf (get-buffer-create "*test-intf-clean*")))
    (unwind-protect
        (let ((iar-interactive-fences t)
              (iar--cycle-state nil)
              (iar--one-shot-state nil)
              (sent 0))
          (cl-letf (((symbol-function 'gptel-send)
                     (lambda () (cl-incf sent))))
            (with-current-buffer buf
              (erase-buffer)
              (setq iar--interactive-state nil)
              (dotimes (i 8)
                (let ((start (point)))
                  (insert (format "Fresh analysis line %d: the result is %d.\n" i (* i 7)))
                  (iar--interactive-fence-handler start (point))))
              (should (= sent 0))
              (should-not (plist-get iar--interactive-state
                                     :runaway-recovery-given)))))
      (kill-buffer buf))))

;;; --- reset command ---

(ert-deftest test-int-fences-reset-rearms ()
  "iar--interactive-fences-reset clears the state so a disarmed
buffer re-arms."
  (let ((buf (get-buffer-create "*test-intf-reset*")))
    (unwind-protect
        (with-current-buffer buf
          (setq iar--interactive-state
                (list :cross-rep-window nil
                      :runaway-recovery-given t
                      :disarmed t))
          (iar--interactive-fences-reset)
          (should (null iar--interactive-state)))
      (kill-buffer buf))))
