;; -*- lexical-binding: t; -*-
;; Tests: hook-stop recovery (c384) -- a pre/post-tool-call hook stop
;; (loop-guard hard stop, chain guard, breaker) arrives as a FAILED
;; request (:status "Stopped by hook") and previously ended the cycle
;; on the dead-cycle guard with zero re-prompt (RUN11 09-24 05:57Z,
;; RUN42 09-23). A hook stop is a GUARD ABORT: re-prompt with an
;; abort-aware prompt naming the identical-call loop, cap 2, past cap
;; end LOUD. Production evidence: audit/iar/aria/cycle-2026-09-24.log
;; RUN11; rage organ sev=3 after the c382 vocabulary fix.
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

(defconst iar-test--hook-stop-status "Stopped by hook")
(defconst iar-test--hook-stop-error
  "Request stopped: agent called execute_code_local with identical arguments 6 times.
The loop guard has blocked 3 attempts and the model has not self-corrected.
Stopping to prevent resource waste.")

(ert-deftest test-hook-stopped-p-detects-exact-status ()
  "The predicate fires on gptel's exact hook-stop status string."
  (with-temp-buffer
    (iar-test--make-fsm-with-error iar-test--hook-stop-status
                                   iar-test--hook-stop-error)
    (should (iar--request-hook-stopped-p))))

(ert-deftest test-hook-stopped-p-nil-on-genuine-failures ()
  "Genuine backend failures (502, 429, curl) do NOT classify as
hook stops -- the transient/permanent classes keep their own paths."
  (with-temp-buffer
    (iar-test--make-fsm-with-error "(HTTP/1.1 502 Bad Gateway)" "Malformed JSON in response")
    (should-not (iar--request-hook-stopped-p)))
  (with-temp-buffer
    (iar-test--make-fsm-with-error "(HTTP/1.1 429 Too Many Requests)" "rate limited")
    (should-not (iar--request-hook-stopped-p)))
  (with-temp-buffer
    (iar-test--make-fsm-with-error "Curl failure" "Curl failed with exit code 35.")
    (should-not (iar--request-hook-stopped-p))))

(ert-deftest test-hook-stopped-p-nil-on-missing-data ()
  "No FSM data -> nil (dead-cycle guard keeps its teeth)."
  (with-temp-buffer
    (setq gptel--fsm-last nil)
    (should-not (iar--request-hook-stopped-p))))

(ert-deftest test-hook-stop-recovery-fires-on-strike-1 ()
  "A hook-stopped request with a fresh abort budget RE-PROMPTS with
the abort-aware prompt instead of ending the cycle (the RUN11 shape,
fixed)."
  (let ((buf (get-buffer-create "*test-hookstop1*"))
        (sent nil))
    (unwind-protect
        (let ((iar--cycle-state (iar--cycle-make-state "test" buf "Continue." 40))
              (iar--one-shot-state nil)
              (iar--cycle-error-strikes 0)
              (iar--cycle-abort-strikes 0)
              (iar--cycle-retry-count 0)
              (gptel--request-alist nil))
          (with-current-buffer buf
            (text-mode)
            (gptel-mode 1)
            (iar-test--make-fsm-with-error iar-test--hook-stop-status
                                           iar-test--hook-stop-error)
            (cl-letf (((symbol-function 'gptel-send)
                       (lambda () (setq sent t))))
              (let ((start (point)))
                (insert "x")
                (iar--cycle-post-response-handler start start))))
          (should-not (plist-get iar--cycle-state :completed))
          (should (= 1 iar--cycle-abort-strikes))
          (should sent)
          ;; The re-prompt names the actual failure (law 41).
          (with-current-buffer buf
            (goto-char (point-min))
            (should (search-forward "HARD-STOPPED by the loop guard" nil t))))
      (kill-buffer buf))))

(ert-deftest test-hook-stop-recovery-cap-ends-loud ()
  "Past the abort-reprompt cap (2), a hook stop ends the cycle LOUD
(exit 1) instead of burning another budget on the same pattern."
  (let ((buf (get-buffer-create "*test-hookstop2*")))
    (unwind-protect
        (let ((iar--cycle-state (iar--cycle-make-state "test" buf "Continue." 40))
              (iar--one-shot-state nil)
              (iar--cycle-error-strikes 1)
              (iar--cycle-abort-strikes 2)  ; cap already reached
              (iar--cycle-retry-count 0)
              (gptel--request-alist nil))
          (with-current-buffer buf
            (text-mode)
            (gptel-mode 1)
            (iar-test--make-fsm-with-error iar-test--hook-stop-status
                                           iar-test--hook-stop-error)
            (let ((start (point)))
              (insert "x")
              (iar--cycle-post-response-handler start start)))
          (should (plist-get iar--cycle-state :completed))
          (should (= 1 (plist-get iar--cycle-state :exit-code)))
          (should (= 2 iar--cycle-abort-strikes)))  ; not incremented past cap
      (kill-buffer buf))))

(ert-deftest test-hook-stop-recovery-three-strikes-still-ends ()
  "Three consecutive failed requests end the cycle via the existing
3-strikes check BEFORE the hook-stop branch -- no infinite
re-prompt loop on a model that never self-corrects."
  (let ((buf (get-buffer-create "*test-hookstop3*")))
    (unwind-protect
        (let ((iar--cycle-state (iar--cycle-make-state "test" buf "Continue." 40))
              (iar--one-shot-state nil)
              (iar--cycle-error-strikes 2)  ; this failure = strike 3
              (iar--cycle-abort-strikes 0)
              (iar--cycle-retry-count 0)
              (gptel--request-alist nil))
          (with-current-buffer buf
            (text-mode)
            (gptel-mode 1)
            (iar-test--make-fsm-with-error iar-test--hook-stop-status
                                           iar-test--hook-stop-error)
            (let ((start (point)))
              (insert "x")
              (iar--cycle-post-response-handler start start)))
          (should (plist-get iar--cycle-state :completed))
          (should (= 1 (plist-get iar--cycle-state :exit-code)))
          (should (= 0 iar--cycle-abort-strikes)))  ; branch never reached
      (kill-buffer buf))))

(ert-deftest test-hook-stop-one-shot-mirror-fires ()
  "The one-shot failed path mirrors the cycle path: hook stop ->
abort-aware re-prompt, not death."
  (let ((buf (get-buffer-create "*test-hookstop4*"))
        (sent nil))
    (unwind-protect
        (let ((iar--one-shot-state (list :agent "test" :buffer buf
                                         :continue "Continue." :max-turns 40
                                         :completed nil :exit-code 0))
              (iar--one-shot-error-strikes 0)
              (iar--one-shot-abort-strikes 0)
              (iar--one-shot-retry-count 0)
              (gptel--request-alist nil))
          (with-current-buffer buf
            (text-mode)
            (gptel-mode 1)
            (iar-test--make-fsm-with-error iar-test--hook-stop-status
                                           iar-test--hook-stop-error)
            (cl-letf (((symbol-function 'gptel-send)
                       (lambda () (setq sent t))))
              (let ((start (point)))
                (insert "x")
                (iar--one-shot-post-response-handler start start))))
          (should-not (plist-get iar--one-shot-state :completed))
          (should (= 1 iar--one-shot-abort-strikes))
          (should sent))
      (kill-buffer buf))))

(ert-deftest test-hook-stop-one-shot-past-cap-ends-loud ()
  "One-shot: past the abort-reprompt cap, a hook stop ends LOUD."
  (let ((buf (get-buffer-create "*test-hookstop5*")))
    (unwind-protect
        (let ((iar--one-shot-state (list :agent "test" :buffer buf
                                         :continue "Continue." :max-turns 40
                                         :completed nil :exit-code 0))
              (iar--one-shot-error-strikes 1)
              (iar--one-shot-abort-strikes 2)
              (iar--one-shot-retry-count 0)
              (gptel--request-alist nil))
          (with-current-buffer buf
            (text-mode)
            (gptel-mode 1)
            (iar-test--make-fsm-with-error iar-test--hook-stop-status
                                           iar-test--hook-stop-error)
            (let ((start (point)))
              (insert "x")
              (iar--one-shot-post-response-handler start start)))
          (should (plist-get iar--one-shot-state :completed))
          (should (= 1 (plist-get iar--one-shot-state :exit-code))))
      (kill-buffer buf))))

(ert-deftest test-hook-stop-does-not-shadow-transient ()
  "A genuine 502 with a fresh retry budget still takes the transient
retry path -- the hook-stop branch must not capture it (the c357
protection is intact)."
  (let ((buf (get-buffer-create "*test-hookstop6*"))
        (sent nil))
    (unwind-protect
        (let ((iar--cycle-state (iar--cycle-make-state "test" buf "Continue." 40))
              (iar--one-shot-state nil)
              (iar--cycle-error-strikes 0)
              (iar--cycle-abort-strikes 0)
              (iar--cycle-retry-count 0)
              (gptel--request-alist nil))
          (with-current-buffer buf
            (text-mode)
            (gptel-mode 1)
            (iar-test--make-fsm-with-error "(HTTP/1.1 502 Bad Gateway)" "Malformed JSON in response")
            (cl-letf (((symbol-function 'gptel-send)
                       (lambda () (setq sent t)))
                      ((symbol-function 'sleep-for) (lambda (_secs) nil)))
              (let ((start (point)))
                (insert "x")
                (iar--cycle-post-response-handler start start))))
          (should-not (plist-get iar--cycle-state :completed))
          (should (= 1 iar--cycle-retry-count))
          (should (= 0 iar--cycle-abort-strikes))
          (should sent))
      (kill-buffer buf))))

(ert-deftest test-hook-stop-429-still-ends-immediately ()
  "A 429 (permanent) with fresh budgets still ends immediately via
the dead-cycle guard -- the hook-stop branch must not capture it."
  (let ((buf (get-buffer-create "*test-hookstop7*")))
    (unwind-protect
        (let ((iar--cycle-state (iar--cycle-make-state "test" buf "Continue." 40))
              (iar--one-shot-state nil)
              (iar--cycle-error-strikes 0)
              (iar--cycle-abort-strikes 0)
              (iar--cycle-retry-count 0)
              (gptel--request-alist nil))
          (with-current-buffer buf
            (text-mode)
            (gptel-mode 1)
            (iar-test--make-fsm-with-error "(HTTP/1.1 429 Too Many Requests)" "rate limited")
            (let ((start (point)))
              (insert "x")
              (iar--cycle-post-response-handler start start)))
          (should (plist-get iar--cycle-state :completed))
          (should (= 1 (plist-get iar--cycle-state :exit-code)))
          (should (= 0 iar--cycle-abort-strikes)))
      (kill-buffer buf))))
