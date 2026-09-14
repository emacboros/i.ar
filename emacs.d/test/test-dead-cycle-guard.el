;; Tests: dead-cycle guard (c326) -- a failed request with no live
;; successor ends the cycle immediately instead of idling the 1800s
;; stall window. Production case: the 2026-09-13 quota storm (16
;; continuo cycles, each 1 request -> 429 -> strike 1/3 -> 1800s
;; idle -> exit 1; 8h of sophon wall-clock on dead requests).
(require 'ert)
(require 'iar-agent-cycle)
(require 'iar-tool-call)

(ert-deftest test-dead-cycle-guard-ends-on-lone-failure ()
  "A failed request with an EMPTY request alist and no live process
completes the cycle immediately (exit 1) -- the 429 storm shape."
  (let ((buf (get-buffer-create "*test-dead-cycle1*")))
    (unwind-protect
        (let ((iar--cycle-state (iar--cycle-make-state "test" buf "Continue." 40))
              (iar--one-shot-state nil)
              (iar--cycle-error-strikes 0)
              (gptel--request-alist nil))
          (with-current-buffer buf
            (let ((start (point)))
              (insert "x")
              (iar--cycle-post-response-handler start start))) ; start==end = FAILED
          (should (plist-get iar--cycle-state :completed))
          (should (= 1 (plist-get iar--cycle-state :exit-code)))
          (should (= 1 iar--cycle-error-strikes)))
      (kill-buffer buf))))

(ert-deftest test-dead-cycle-guard-waits-for-live-delegate ()
  "A failed cycle request with a LIVE delegate FSM in the alist does
NOT end the cycle -- the delegate may still land its work."
  (let ((buf (get-buffer-create "*test-dead-cycle2*"))
        (delegate-buf (get-buffer-create "*test-dead-cycle-delegate*")))
    (unwind-protect
        (let* ((iar--cycle-state (iar--cycle-make-state "test" buf "Continue." 40))
               (iar--one-shot-state nil)
               (iar--cycle-error-strikes 0)
               ;; A live delegate FSM in WAIT (non-terminal), the
               ;; real constructor shape.
               (fake-fsm (gptel-make-fsm :state 'WAIT))
               (gptel--request-alist nil))
          (setf (alist-get :fake-proc gptel--request-alist)
                (cons fake-fsm #'ignore))
          (with-current-buffer buf
            (let ((start (point)))
              (insert "x")
              (iar--cycle-post-response-handler start start)))
          (should-not (plist-get iar--cycle-state :completed))
          (should (= 1 iar--cycle-error-strikes)))
      (kill-buffer buf)
      (kill-buffer delegate-buf))))

(ert-deftest test-dead-cycle-guard-strike-3-still-ends ()
  "Three strikes still end the cycle (the original abort path)."
  (let ((buf (get-buffer-create "*test-dead-cycle3*")))
    (unwind-protect
        (let ((iar--cycle-state (iar--cycle-make-state "test" buf "Continue." 40))
              (iar--one-shot-state nil)
              (iar--cycle-error-strikes 2)
              (gptel--request-alist nil))
          (with-current-buffer buf
            (let ((start (point)))
              (insert "x")
              (iar--cycle-post-response-handler start start)))
          (should (plist-get iar--cycle-state :completed))
          (should (= 1 (plist-get iar--cycle-state :exit-code))))
      (kill-buffer buf))))