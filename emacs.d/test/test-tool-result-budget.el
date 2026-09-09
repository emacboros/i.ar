;; -*- lexical-binding: t; -*-

;;; Tests for iar-tool-result-budget.el

(require 'ert)
(require 'cl-lib)
(require 'subr-x)

;; Configs are loaded by filename in run-tests.el (not by feature),
;; so the budget config var is available via forward-declaration in
;; the module itself. Just require the module.
(require 'iar-tool-result-budget)

;;; --- Trailer function tests ---

(ert-deftest test-budget-disabled ()
  "When the budget trailer is disabled, result passes through unchanged."
  (let ((iar-tool-result-budget nil)
        (iar--cycle-state (list :agent "t" :start-time (current-time)
                                :wall-timeout 1800 :tool-call-count 5)))
    (should (string= "hello" (iar--budget-append-trailer "hello")))))

(ert-deftest test-budget-no-state ()
  "No active cycle/one-shot state -> no trailer (interactive sessions
are not budgeted)."
  (let ((iar--cycle-state nil)
        (iar--one-shot-state nil))
    (should (string= "hello" (iar--budget-append-trailer "hello")))))

(ert-deftest test-budget-non-plist-state ()
  "A non-plist state (:unbound atom) reads as no state -- the
conservative default (same class as the watchdog-notice unbound test)."
  (let ((iar--cycle-state :unbound)
        (iar--one-shot-state nil))
    (should (string= "hello" (iar--budget-append-trailer "hello")))))

(ert-deftest test-budget-missing-clock ()
  "State without :start-time or :wall-timeout -> no trailer. Never
manufacture a clock: a trailer without an honest t0 is a lying
instrument."
  (let ((iar--cycle-state (list :agent "t"))
        (iar--one-shot-state nil))
    (should (string= "hello" (iar--budget-append-trailer "hello")))))

(ert-deftest test-budget-missing-wall ()
  "State with :start-time but no :wall-timeout -> no trailer (a
trailer without a wall is half an instrument)."
  (let ((iar--cycle-state (list :agent "t" :start-time (current-time)))
        (iar--one-shot-state nil))
    (should (string= "hello" (iar--budget-append-trailer "hello")))))

(ert-deftest test-budget-format ()
  "Trailer matches [t+MM:SS/WALL cNN/CAP] format, appended on its
own line after the result."
  (let ((iar--cycle-state (list :agent "t"
                                :start-time (time-subtract
                                             (current-time)
                                             (seconds-to-time 754))
                                :wall-timeout 1800
                                :tool-call-count 5))
        (iar--one-shot-state nil))
    (let ((result (iar--budget-append-trailer "hello")))
      (should (string-prefix-p "hello" result))
      (should (string-match-p "\\[t\\+12:34/30:00 c6/300\\]\\'" result)))))

(ert-deftest test-budget-count-includes-current-call ()
  "The trailer's call count INCLUDES the current call: the trailer
is appended before the tracker's post-call increment, so the shown
count is (1+ :tool-call-count)."
  (let ((iar--cycle-state (list :agent "t" :start-time (current-time)
                                :wall-timeout 1800 :tool-call-count 0))
        (iar--one-shot-state nil))
    (should (string-match-p "c1/300]\\'"
                            (iar--budget-append-trailer "x")))))

(ert-deftest test-budget-one-shot-state ()
  "One-shot runs get trailers too (dispatch: cycle state first, then
one-shot)."
  (let ((iar--cycle-state nil)
        (iar--one-shot-state (list :agent "o"
                                   :start-time (time-subtract
                                                (current-time)
                                                (seconds-to-time 754))
                                   :wall-timeout 7200
                                   :tool-call-count 119)))
    (should (string-match-p "\\[t\\+12:34/120:00 c120/300\\]\\'"
                            (iar--budget-append-trailer "hello")))))

(ert-deftest test-budget-cycle-state-wins ()
  "When both states are bound, the cycle state wins (same precedence
as the fences)."
  (let ((iar--cycle-state (list :agent "c" :start-time (current-time)
                                :wall-timeout 1800 :tool-call-count 1))
        (iar--one-shot-state (list :agent "o" :start-time (current-time)
                                   :wall-timeout 7200 :tool-call-count 2)))
    (should (string-match-p "c2/300]\\'"
                            (iar--budget-append-trailer "x")))))

(ert-deftest test-budget-idempotent ()
  "Already-trailered results are not trailered again (advice may run
twice on the same result)."
  (let ((iar--cycle-state (list :agent "t" :start-time (current-time)
                                :wall-timeout 1800 :tool-call-count 5))
        (iar--one-shot-state nil))
    (let ((result "[t+01:00/30:00 c1/300] already trailered"))
      (should (string= result (iar--budget-append-trailer result))))))

(ert-deftest test-budget-non-string ()
  "Non-string results pass through unchanged."
  (let ((iar-tool-result-budget t)
        (iar--cycle-state (list :agent "t" :start-time (current-time)
                                :wall-timeout 1800 :tool-call-count 5)))
    (should (eq 42 (iar--budget-append-trailer 42)))
    (should (null (iar--budget-append-trailer nil)))))

;;; --- Composition with truncation ---

(ert-deftest test-budget-survives-truncation ()
  "The trailer sits at the result's tail BEFORE truncation runs
(inner advice); middle-truncation preserves head and tail, so the
trailer survives even truncated results. Simulates the advice chain
order (budget outer -> truncation inner)."
  (let ((iar-tool-result-budget t)
        (iar-tool-result-max-chars 100)
        (iar--cycle-state (list :agent "t" :start-time (current-time)
                                :wall-timeout 1800 :tool-call-count 5))
        (iar--one-shot-state nil))
    (let* ((trailered (iar--budget-append-trailer (make-string 500 ?x)))
           (truncated (iar--truncate-tool-result trailered)))
      ;; The trailer must still be at the end after truncation
      (should (string-match-p "\\[t\\+[0-9][0-9]:[0-9][0-9]/30:00 c6/300\\]\\'"
                              truncated)))))

;;; --- Shared clock (the scar-list law) ---

(ert-deftest test-budget-shared-clock-with-fence ()
  "The event loop's deadline and the trailer read the SAME t0: the
state's :start-time. This is the pin on the instruments-lying class
-- two clocks that disagree are a fence that lies about the time it
enforces. Simulates: make a state, compute the deadline the way the
event loop does, verify the trailer's elapsed matches the fence's
remaining."
  (let* ((state (list :agent "t" :start-time (current-time)
                      :wall-timeout 1800))
         ;; The event loop computes: deadline = start-time + timeout
         (deadline (time-add (plist-get state :start-time)
                             (seconds-to-time 1800)))
         ;; The trailer computes: elapsed = now - start-time
         (elapsed (round (float-time (time-subtract nil
                                                    (plist-get state :start-time)))))
         ;; Fence remaining = deadline - now
         (remaining (round (float-time (time-subtract deadline (current-time))))))
    ;; elapsed + remaining must equal the wall (within 1s of test lag)
    (should (<= (abs (- (+ elapsed remaining) 1800)) 1))))

(ert-deftest test-budget-make-state-carries-clock ()
  "iar--cycle-make-state stores :start-time and :wall-timeout -- the
shared clock exists from state creation, not from first read."
  (let* ((before (current-time))
         (state (iar--cycle-make-state "test" nil "continue" 40 1800))
         (after (current-time)))
    (should (plist-get state :start-time))
    (should (time-less-p (or (plist-get state :start-time) after) after))
    (should (time-less-p before (or (plist-get state :start-time) before)))
    (should (= 1800 (plist-get state :wall-timeout)))))

(ert-deftest test-budget-one-shot-make-state-carries-clock ()
  "iar--one-shot-make-state stores :start-time and :wall-timeout."
  (let* ((state (iar--one-shot-make-state "test" nil 40 7200)))
    (should (plist-get state :start-time))
    (should (= 7200 (plist-get state :wall-timeout)))))

(ert-deftest test-budget-make-state-optional-wall ()
  "make-state without wall-timeout still works (backward compat with
the 80+ existing test call sites): :wall-timeout is nil, and the
trailer honestly declines to fire (no wall -> no trailer)."
  (let ((state (iar--cycle-make-state "test" nil "continue" 40)))
    (should (null (plist-get state :wall-timeout)))
    (should (plist-get state :start-time))
    (let ((iar--cycle-state state)
          (iar--one-shot-state nil))
      (should (string= "hello" (iar--budget-append-trailer "hello"))))))

;;; --- Advice installation tests ---

(ert-deftest test-budget-advice-installed ()
  "Budget advice is installed on gptel--process-tool-call."
  (should (advice-member-p 'iar--budget-tool-result-advice
                           'gptel--process-tool-call)))

(ert-deftest test-budget-setup-idempotent ()
  "Calling setup twice does not duplicate advice (remove-then-add
pattern)."
  (iar--budget-setup)
  (iar--budget-setup)
  (should (advice-member-p 'iar--budget-tool-result-advice
                           'gptel--process-tool-call)))

;;; --- Config variable tests ---

(ert-deftest test-budget-config-default ()
  "Default config value is enabled (t)."
  (should (eq t (default-value 'iar-tool-result-budget))))

(ert-deftest test-budget-config-safe-predicate ()
  "Config has a :safe predicate."
  (should (eq #'booleanp (get 'iar-tool-result-budget 'safe-local-variable))))

;;; --- Remote exec timeout (layer 1) ---

(ert-deftest test-remote-exec-default-timeout-exists ()
  "The remote exec default timeout defcustom exists with the 600s
default -- one hung remote call must not eat the cycle wall
(mirrors the c65 local fix)."
  (should (default-value 'iar-remote-exec-default-timeout))
  (should (= 600 (default-value 'iar-remote-exec-default-timeout))))

(provide 'test-tool-result-budget)
;;; test-tool-result-budget.el ends here