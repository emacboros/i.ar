;; -*- lexical-binding: t; -*-

;;; Watchdog notice suppression tests (aria c53, conveyor-belt fix)
;;
;; The Aevum c52 finding: the watchdog abort notice written into the
;; gptel buffer becomes permanent context the agent re-sends. At the
;; context wall it forces front-truncation -- the conveyor belt that
;; erased the child's head. Fix: suppress the notice in unattended
;; run buffers (cycle/one-shot), keep it for interactive humans.

(require 'ert)
(require 'cl-lib)
(require 'gptel)
(require 'iar-request-watchdog)

;;; --- unattended-buffer detection ---

(ert-deftest test-watchdog-notice-cycle-buffer-is-unattended ()
  "The active cycle's buffer is detected as unattended."
  (with-temp-buffer
    (let ((iar--cycle-state (list :agent "aria" :buffer (current-buffer)))
          (iar--one-shot-state nil))
      (should (iar--watchdog-unattended-buffer-p (current-buffer))))))

(ert-deftest test-watchdog-notice-one-shot-buffer-is-unattended ()
  "The active one-shot's buffer is detected as unattended."
  (with-temp-buffer
    (let ((iar--cycle-state nil)
          (iar--one-shot-state (list :agent "delegate" :buffer (current-buffer))))
      (should (iar--watchdog-unattended-buffer-p (current-buffer))))))

(ert-deftest test-watchdog-notice-plain-buffer-is-attended ()
  "A buffer with no cycle/one-shot state is interactive (attended)."
  (with-temp-buffer
    (let ((iar--cycle-state nil)
          (iar--one-shot-state nil))
      (should-not (iar--watchdog-unattended-buffer-p (current-buffer))))))

(ert-deftest test-watchdog-notice-other-buffer-is-attended ()
  "A buffer that is NOT the state's buffer is attended (interactive)."
  (with-temp-buffer
    (let* ((iar--cycle-state (list :agent "aria" :buffer (current-buffer)))
           (iar--one-shot-state nil))
      (with-temp-buffer
        ;; different buffer, cycle state points elsewhere
        (should-not (iar--watchdog-unattended-buffer-p (current-buffer)))))))

(ert-deftest test-watchdog-notice-dead-buffer-is-attended ()
  "A dead buffer is never unattended (live check first)."
  (let ((dead (get-buffer-create " *watchdog-notice-dead-test*")))
    (kill-buffer dead)
    (let ((iar--cycle-state (list :agent "aria" :buffer dead))
          (iar--one-shot-state nil))
      (should-not (iar--watchdog-unattended-buffer-p dead)))))

(ert-deftest test-watchdog-notice-unbound-state-is-attended ()
  "Unbound state variables (cycle module absent) read as attended --
the conservative default: an interactive user never loses their
notice to a state-shape bug."
  (with-temp-buffer
    (let ((iar--cycle-state :unbound)
          (iar--one-shot-state :unbound))
      ;; :unbound is a non-nil atom -- bound but not a plist; the
      ;; plistp guard must reject it.
      (should-not (iar--watchdog-unattended-buffer-p (current-buffer))))))

;;; --- abort behavior (notice insert gated) ---

(defvar watchdog-notice-test--inserted nil)
(defvar gptel-abort-called nil)

(ert-deftest test-watchdog-abort-suppresses-notice-in-cycle-buffer ()
  "Aborting a request in the cycle buffer does NOT insert the notice."
  (let* ((buf (get-buffer-create " *watchdog-notice-cycle-test*"))
         (fsm (gptel-make-fsm :info (list :buffer buf)))
         (iar--cycle-state (list :agent "aria" :buffer buf)))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (insert "model output so far"))
          (let ((gptel--request-alist (list (list :fake-proc fsm))))
            (cl-letf (((symbol-function 'gptel-abort) (lambda (_b) nil)))
              (iar--watchdog-abort :fake-proc "stalled stream: no data for 999s")))
          (with-current-buffer buf
            (should (string= "model output so far"
                             (buffer-substring-no-properties
                              (point-min) (point-max))))))
      (kill-buffer buf))))

(ert-deftest test-watchdog-abort-keeps-notice-in-interactive-buffer ()
  "Aborting a request in an interactive buffer DOES insert the notice."
  (let* ((buf (get-buffer-create " *watchdog-notice-interactive-test*"))
         (fsm (gptel-make-fsm :info (list :buffer buf))))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (insert "model output so far"))
          (let ((gptel--request-alist (list (list :fake-proc fsm)))
                (iar--cycle-state nil)
                (iar--one-shot-state nil))
            (cl-letf (((symbol-function 'gptel-abort)
                       (lambda (b) (setq gptel-abort-called b))))
              (iar--watchdog-abort :fake-proc "stalled stream: no data for 999s")))
          (should (eq gptel-abort-called buf))
          (with-current-buffer buf
            (should (string-match-p
                     "\\[watchdog: request aborted -- stalled stream"
                     (buffer-substring-no-properties
                      (point-min) (point-max))))))
      (kill-buffer buf))))

(ert-deftest test-watchdog-abort-suppress-toggle-respected ()
  "Setting the suppress var to nil restores the notice everywhere."
  (let* ((buf (get-buffer-create " *watchdog-notice-toggle-test*"))
         (fsm (gptel-make-fsm :info (list :buffer buf)))
         (iar--cycle-state (list :agent "aria" :buffer buf)))
    (unwind-protect
        (progn
          (with-current-buffer buf (insert "x"))
          (let ((gptel--request-alist (list (list :fake-proc fsm)))
                (iar-watchdog-notice-suppress-unattended nil))
            (cl-letf (((symbol-function 'gptel-abort) (lambda (_b) nil)))
              (iar--watchdog-abort :fake-proc "no response data after 999s")))
          (with-current-buffer buf
            (should (string-match-p "\\[watchdog: request aborted"
                                    (buffer-substring-no-properties
                                     (point-min) (point-max))))))
      (kill-buffer buf))))

(ert-deftest test-watchdog-abort-never-signals-on-garbage ()
  "The abort path is error-proof: garbage process + no state must
not signal (the timer callback contract)."
  (let ((gptel--request-alist nil)
        (iar--cycle-state nil)
        (iar--one-shot-state nil))
    (should-not (iar--watchdog-abort (list :garbage) "test reason"))))

(provide 'test-watchdog-notice)
