;; Tests: dead-run guard on the ONE-SHOT path (c327) -- a failed
;; request with no live successor ends the one-shot immediately
;; instead of idling the 1800s stall window. Production case: the
;; 09-13 nocturne 429 (16:01:55Z, 2 requests, 0 turns, idle until
;; the 1800s timeout banner). The cycle path got this guard in
;; c326 (2eb3846); this pins the one-shot twin.
(require 'ert)
(require 'iar-agent-cycle)
(require 'iar-tool-call)

(ert-deftest test-dead-run-guard-oneshot-ends-on-lone-failure ()
  "A failed one-shot request with an EMPTY request alist and no live
process completes the one-shot immediately (exit 1) -- the 09-13
nocturne 429 shape."
  (let ((os-buf (get-buffer-create "*test-dead-run-os1*")))
    (unwind-protect
        (let ((iar--one-shot-state (list :buffer os-buf :completed nil
                                         :exit-code 0 :turn-count 0
                                         :tool-call-count 0))
              (iar--cycle-state nil)
              (iar--one-shot-error-strikes 0)
              (gptel--request-alist nil))
          (with-current-buffer os-buf
            (let ((start (point)))
              (insert "x")
              (iar--one-shot-post-response-handler start start))) ; start==end = FAILED
          (should (plist-get iar--one-shot-state :completed))
          (should (= 1 (plist-get iar--one-shot-state :exit-code)))
          (should (= 1 iar--one-shot-error-strikes)))
      (kill-buffer os-buf))))

(ert-deftest test-dead-run-guard-oneshot-waits-for-live-request ()
  "A failed one-shot request with a LIVE FSM in the alist does NOT
end the one-shot -- something may still land."
  (let ((os-buf (get-buffer-create "*test-dead-run-os2*")))
    (unwind-protect
        (let* ((iar--one-shot-state (iar--cycle-make-state "test" os-buf "Continue." 40))
               (iar--cycle-state nil)
               (iar--one-shot-error-strikes 0)
               (fake-fsm (gptel-make-fsm :state 'WAIT))
               (gptel--request-alist nil))
          (setf (alist-get :fake-proc gptel--request-alist)
                (cons fake-fsm #'ignore))
          (with-current-buffer os-buf
            (let ((start (point)))
              (insert "x")
              (iar--one-shot-post-response-handler start start)))
          (should-not (plist-get iar--one-shot-state :completed))
          (should (= 1 iar--one-shot-error-strikes)))
      (kill-buffer os-buf))))