;; Tests: transient-error retry (c357) -- a 5xx / connection-level
;; failure retries with backoff instead of killing the cycle on
;; strike 1; a permanent failure (429, model not found) does NOT
;; retry (the c326 quota-storm lesson: retrying dead requests burns
;; wall-clock). Production case: aria c357-start, 2026-09-15 07:30Z
;; cycle-start 502 (connection reset) killed the cycle in 14s with
;; zero work done; the 09-13 quota storm is the counter-class.
(require 'ert)
(require 'iar-agent-cycle)
(require 'iar-tool-call)

(defun iar-test--make-fsm-with-error (status err)
  "Build a fake FSM whose info carries STATUS and ERR, install as
gptel--fsm-last in the current buffer."
  (let ((fsm (gptel-make-fsm :state 'ERRS)))
    (setf (gptel-fsm-info fsm)
          (list :status status :error err))
    (setq gptel--fsm-last fsm)
    fsm))

(ert-deftest test-transient-classifier-5xx ()
  "HTTP 502 Bad Gateway classifies as transient."
  (with-temp-buffer
    (iar-test--make-fsm-with-error "(HTTP/1.1 502 Bad Gateway) read: connection reset by peer"
                                   "Malformed JSON in response")
    (should (iar--request-transient-error-p))))

(ert-deftest test-transient-classifier-curl-failure ()
  "Curl connection-level failure classifies as transient."
  (with-temp-buffer
    (iar-test--make-fsm-with-error "Curl failure"
                                   "Curl failed with exit code 35. See Curl manpage for details.")
    (should (iar--request-transient-error-p))))

(ert-deftest test-transient-classifier-429-permanent ()
  "HTTP 429 (quota storm class) does NOT retry."
  (with-temp-buffer
    (iar-test--make-fsm-with-error "(HTTP/1.1 429 Too Many Requests)"
                                   "rate limit exceeded")
    (should-not (iar--request-transient-error-p))))

(ert-deftest test-transient-classifier-model-404-permanent ()
  "Model-not-found (the 2026-08-30 2537-retry storm class) does NOT retry."
  (with-temp-buffer
    (iar-test--make-fsm-with-error "(HTTP/1.1 404 Not Found)"
                                   "model 'nemotron-3-super' not found")
    (should-not (iar--request-transient-error-p))))

(ert-deftest test-transient-classifier-no-data-fail-safe ()
  "No error data -> nil (unknown class never retries; the dead-cycle
guard keeps its teeth)."
  (with-temp-buffer
    (setq gptel--fsm-last nil)
    (should-not (iar--request-transient-error-p))))

(ert-deftest test-transient-retry-fires-on-lone-502 ()
  "A lone 502 with no live successor RETRIES instead of ending the
cycle (the c357-start production shape). The retry re-sends the
continue prompt."
  (let ((buf (get-buffer-create "*test-transient1*"))
        (sent nil))
    (unwind-protect
        (let ((iar--cycle-state (iar--cycle-make-state "test" buf "Continue." 40))
              (iar--one-shot-state nil)
              (iar--cycle-error-strikes 0)
              (iar--cycle-retry-count 0)
              (gptel--request-alist nil))
          (with-current-buffer buf
            (text-mode)
            (gptel-mode 1)
            (iar-test--make-fsm-with-error "(HTTP/1.1 502 Bad Gateway)" "Malformed JSON in response")
            ;; Stub gptel-send: record the re-send, don't hit the network.
            (cl-letf (((symbol-function 'gptel-send)
                       (lambda () (setq sent t)))
                      ((symbol-function 'sleep-for) (lambda (_secs) nil)))
              (let ((start (point)))
                (insert "x")
                (iar--cycle-post-response-handler start start))))
          (should-not (plist-get iar--cycle-state :completed))
          (should (= 1 iar--cycle-retry-count))
          (should sent))
      (kill-buffer buf))))

(ert-deftest test-transient-retry-budget-exhausts ()
  "After the retry budget (3), a 4th transient failure ends the
cycle -- no infinite retry loop on a hard-down gateway."
  (let ((buf (get-buffer-create "*test-transient2*")))
    (unwind-protect
        (let ((iar--cycle-state (iar--cycle-make-state "test" buf "Continue." 40))
              (iar--one-shot-state nil)
              (iar--cycle-error-strikes 0)
              (iar--cycle-retry-count 3)   ; budget already spent
              (gptel--request-alist nil))
          (with-current-buffer buf
            (iar-test--make-fsm-with-error "(HTTP/1.1 502 Bad Gateway)" "Malformed JSON in response")
            (let ((start (point)))
              (insert "x")
              (iar--cycle-post-response-handler start start)))
          (should (plist-get iar--cycle-state :completed))
          (should (= 1 (plist-get iar--cycle-state :exit-code)))
          (should (= 3 iar--cycle-retry-count)))  ; not incremented past budget
      (kill-buffer buf))))

(ert-deftest test-transient-retry-permanent-still-ends ()
  "A 429 with a fresh retry budget still ends the cycle immediately --
the dead-cycle guard's original protection is intact."
  (let ((buf (get-buffer-create "*test-transient3*")))
    (unwind-protect
        (let ((iar--cycle-state (iar--cycle-make-state "test" buf "Continue." 40))
              (iar--one-shot-state nil)
              (iar--cycle-error-strikes 0)
              (iar--cycle-retry-count 0)
              (gptel--request-alist nil))
          (with-current-buffer buf
            (iar-test--make-fsm-with-error "(HTTP/1.1 429 Too Many Requests)" "rate limited")
            (let ((start (point)))
              (insert "x")
              (iar--cycle-post-response-handler start start)))
          (should (plist-get iar--cycle-state :completed))
          (should (= 1 (plist-get iar--cycle-state :exit-code)))
          (should (= 0 iar--cycle-retry-count)))  ; no retry spent
      (kill-buffer buf))))

(ert-deftest test-transient-retry-reset-on-success ()
  "A successful response resets the retry budget (same contract as
the strike counter)."
  (let ((buf (get-buffer-create "*test-transient4*")))
    (unwind-protect
        (let ((iar--cycle-state (iar--cycle-make-state "test" buf "Continue." 40))
              (iar--one-shot-state nil)
              (iar--cycle-error-strikes 2)
              (iar--cycle-retry-count 2))
          (with-current-buffer buf
            (text-mode)
            (gptel-mode 1)
            (let ((start (point)))
              (insert "CYCLE_COMPLETE")
              (iar--cycle-post-response-handler start (point))))
          (should (= 0 iar--cycle-retry-count))
          (should (= 0 iar--cycle-error-strikes)))
      (kill-buffer buf))))