;; Tests: post-response breaker (text-only runaway coverage).
(require 'ert)
(require 'iar-agent-cycle)
(require 'iar-tool-call)

(ert-deftest test-fence-breaker-text-arms-on-first-over-limit-continue ()
  "A text-only turn at over-limit context arms the breaker and
ALLOWS the continue re-send (grace round-trip for the summary) --
the pre-tool-call breaker never sees prose turns; without this the
runaway re-sends 800k chars per turn until max-turns. The arm must
not block the re-send: blocking suppresses the very response that
would carry the summary and leaves the run idle until timeout (the
c67 zombie, 13m48s dead air)."
  (let ((buf (get-buffer-create "*test-breaker-text1*"))
        (sent nil))
    (unwind-protect
        (let ((iar-cycle-context-limit-chars 100)
              (iar--cycle-state (iar--cycle-make-state "test" buf "Continue." 40))
              (iar--one-shot-state nil)
              (iar--cycle-error-strikes 0))
          (with-current-buffer buf (insert (make-string 200 ?x)))
          ;; Stub gptel-send: the arm must ALLOW the re-send, so the
          ;; handler proceeds to gptel-send. In batch a real send
          ;; pollutes the process-filter state of later tests.
          (cl-letf (((symbol-function 'gptel-send)
                     (lambda () (setq sent t))))
            (with-current-buffer buf
              (let ((start (point)))
                (insert "prose response, no sentinel")
                (iar--cycle-post-response-handler start (point)))))
          (should (plist-get iar--cycle-state :breaker-fired))
          ;; Not ended yet: grace round-trip granted
          (should-not (plist-get iar--cycle-state :completed))
          ;; The re-send was allowed (grace round-trip proceeds)
          (should sent))
      (kill-buffer buf))))

(ert-deftest test-fence-breaker-text-ends-run-on-second-continue ()
  "After the grace round-trip, another text-only continue at
over-limit context ends the run (completed, exit 1)."
  (let ((buf (get-buffer-create "*test-breaker-text2*")))
    (unwind-protect
        (let ((iar-cycle-context-limit-chars 100)
              (iar--cycle-state (iar--cycle-make-state "test" buf "Continue." 40))
              (iar--one-shot-state nil)
              (iar--cycle-error-strikes 0))
          (with-current-buffer buf (insert (make-string 200 ?x)))
          ;; Stub gptel-send: the arm now ALLOWS the re-send, so the
          ;; handler proceeds to gptel-send on the first (arm) turn.
          (cl-letf (((symbol-function 'gptel-send) (lambda ())))
            (with-current-buffer buf
              (let ((start (point)))
                (insert "prose response 1")
                (iar--cycle-post-response-handler start (point))))
            ;; Second text turn, still over limit -> ends run
            (with-current-buffer buf
              (let ((start (point)))
                (insert "prose response 2")
                (iar--cycle-post-response-handler start (point)))))
          (should (plist-get iar--cycle-state :completed))
          (should (= 1 (plist-get iar--cycle-state :exit-code))))
      (kill-buffer buf))))

(ert-deftest test-fence-breaker-text-invisible-under-limit ()
  "Under the limit the text check is invisible: the no-continue
branch ends the cycle normally, the breaker never arms, and no
re-send is attempted (cont-prompt nil avoids a live gptel-send in
batch -- a failed send pollutes the process-filter state of later
tests)."
  (let ((buf (get-buffer-create "*test-breaker-text3*")))
    (unwind-protect
        (let ((iar-cycle-context-limit-chars 100000)
              (iar--cycle-state (iar--cycle-make-state "test" buf nil 40))
              (iar--one-shot-state nil)
              (iar--cycle-error-strikes 0))
          (with-current-buffer buf (insert (make-string 200 ?x)))
          (with-current-buffer buf
            (let ((start (point)))
              (insert "prose response")
              (iar--cycle-post-response-handler start (point))))
          (should-not (plist-get iar--cycle-state :breaker-fired))
          ;; No continue prompt -> cycle ended normally, exit untouched
          (should (plist-get iar--cycle-state :completed))
          (should (= 0 (plist-get iar--cycle-state :exit-code))))
      (kill-buffer buf))))

(ert-deftest test-fence-breaker-text-shared-flag-with-tool-hook ()
  "Armed by the tool-call breaker, a text-only continue ends the
run -- one flag, two gates."
  (let ((buf (get-buffer-create "*test-breaker-text4*")))
    (unwind-protect
        (let ((iar-cycle-context-limit-chars 100)
              (iar--cycle-state (iar--cycle-make-state "test" buf "Continue." 40))
              (iar--one-shot-state nil)
              (iar--cycle-error-strikes 0))
          (with-current-buffer buf (insert (make-string 200 ?x)))
          ;; Tool-call breaker arms it
          (should (iar--cycle-context-breaker
                   (list :name "execute_code_local" :args '(:command "ls"))))
          ;; Text-only continue: shared flag -> ends run. Stub
          ;; gptel-send: the arm path (if reached) would re-send.
          (cl-letf (((symbol-function 'gptel-send) (lambda ())))
            (with-current-buffer buf
              (let ((start (point)))
                (insert "prose response")
                (iar--cycle-post-response-handler start (point)))))
          (should (plist-get iar--cycle-state :completed))
          (should (= 1 (plist-get iar--cycle-state :exit-code))))
      (kill-buffer buf))))

(ert-deftest test-fence-breaker-text-no-state-passes ()
  "No active state -> the text check is a no-op (nil)."
  (let ((iar--cycle-state nil)
        (iar--one-shot-state nil))
    (should-not (iar--cycle-breaker-text-check nil))))

(ert-deftest test-fence-breaker-text-arm-then-tool-fire ()
  "Differential test for the c67 flag-loss path: arm the breaker via
the TEXT-CHECK (post-response continue branch), then fire the TOOL-CALL
breaker. c67's arm at 17:44:55 was the text-check arm; REQ-58's tool
call should have ended the run but did not (17 more calls ran). This
pins the shared-flag contract in the exact direction c67 exercised:
text arm -> tool fire must end the run."
  (let ((buf (get-buffer-create "*test-breaker-text5*")))
    (unwind-protect
        (let ((iar-cycle-context-limit-chars 100)
              (iar--cycle-state (iar--cycle-make-state "test" buf "Continue." 40))
              (iar--one-shot-state nil)
              (iar--cycle-error-strikes 0))
          (with-current-buffer buf (insert (make-string 200 ?x)))
          ;; Text-check arms the breaker (c67 17:44:55 path). The arm
          ;; now ALLOWS the re-send, so the handler calls gptel-send
          ;; -- stub it to avoid a live process in batch.
          (cl-letf (((symbol-function 'gptel-send) (lambda ())))
            (with-current-buffer buf
              (let ((start (point)))
                (insert "prose response")
                (iar--cycle-post-response-handler start (point))))
            (should (plist-get iar--cycle-state :breaker-fired))
            (should-not (plist-get iar--cycle-state :completed))
            ;; Tool-call breaker fires next (c67 REQ-58 path): shared
            ;; flag must end the run.
            (let ((result (iar--cycle-context-breaker
                           (list :name "execute_code_local" :args '(:command "ls")))))
              (should result)
              (should (plist-get result :block))
              (should (plist-get iar--cycle-state :completed))
              (should (= 1 (plist-get iar--cycle-state :exit-code))))))
      (kill-buffer buf))))

(ert-deftest test-fence-output-runaway-detects-repetition ()
  "A response with many identical trimmed lines is flagged as a
text-only output runaway (the deepseek-v4-flash degradation shape:
c-fail REQ-51 had 4612 identical 'Let me check the caller.' lines,
65536 output tokens, no tool call)."
  (let ((buf (get-buffer-create "*test-runaway1*")))
    (unwind-protect
        (with-current-buffer buf
          (erase-buffer)
          (dotimes (_ 30) (insert "Let me check the caller.\n"))
          (should (iar--cycle-output-runaway-p (point-min) (point-max))))
      (kill-buffer buf))))

(ert-deftest test-fence-output-runaway-ignores-normal ()
  "A normal response with distinct lines is NOT flagged."
  (let ((buf (get-buffer-create "*test-runaway2*")))
    (unwind-protect
        (with-current-buffer buf
          (erase-buffer)
          (insert "First line of analysis.\nSecond distinct line.\nThird line.\n")
          (should-not (iar--cycle-output-runaway-p (point-min) (point-max))))
      (kill-buffer buf))))

(ert-deftest test-fence-output-runaway-below-threshold ()
  "Fewer than the threshold of identical lines is not a runaway."
  (let ((buf (get-buffer-create "*test-runaway3*")))
    (unwind-protect
        (let ((iar-cycle-output-runaway-min-repeats 20))
          (with-current-buffer buf
            (erase-buffer)
            (dotimes (_ 10) (insert "same line\n"))
            (should-not (iar--cycle-output-runaway-p (point-min) (point-max)))))
      (kill-buffer buf))))

(ert-deftest test-fence-output-runaway-ends-cycle ()
  "A text-only output runaway in the continue branch ends the cycle
with exit 1 -- the c-fail REQ-51 shape must not re-send and burn
another 65536-token output budget on the same loop. First fire gives
ONE recovery round-trip (the model is usually stuck in decision
paralysis, not truly degraded); a SECOND fire ends the run."
  (let ((buf (get-buffer-create "*test-runaway4*"))
        (sent 0))
    (unwind-protect
        (let ((iar-cycle-context-limit-chars 100000)
              (iar--cycle-state (iar--cycle-make-state "test" buf "Continue." 40))
              (iar--one-shot-state nil)
              (iar--cycle-error-strikes 0))
          (with-current-buffer buf (insert (make-string 200 ?x)))
          ;; Stub gptel-send: the recovery prompt re-sends on first fire.
          (cl-letf (((symbol-function 'gptel-send)
                     (lambda () (cl-incf sent))))
            (with-current-buffer buf
              ;; First fire: recovery round-trip, cycle NOT ended.
              (let ((start (point)))
                (dotimes (_ 30) (insert "Let me check the caller.\n"))
                (iar--cycle-post-response-handler start (point))))
            (should (= 1 sent))
            (should (plist-get iar--cycle-state :runaway-recovery-given))
            (should-not (plist-get iar--cycle-state :completed))
            ;; Second fire: cycle ends, exit 1.
            (with-current-buffer buf
              (let ((start (point)))
                (dotimes (_ 30) (insert "Let me check the caller.\n"))
                (iar--cycle-post-response-handler start (point)))))
          (should (plist-get iar--cycle-state :completed))
          (should (= 1 (plist-get iar--cycle-state :exit-code))))
      (kill-buffer buf))))
;;; --- Scaffolding exclusion, per-response guard (aria c55 fire shape) ---

(ert-deftest test-fence-output-runaway-ignores-tool-block-scaffolding ()
  "The per-response runaway guard must not fire on gptel tool-call
display scaffolding. This is the EXACT c55 fire shape: the fence fired
on a healthy final response because the scanned region contained 66
identical truncated \"``` tool (execute_code_local ...)\" preview lines
(propertized 'gptel 'ignore / '(tool . id) by gptel) against a
threshold of 20 -- zero model repetition required. Old code used
buffer-substring-no-properties, which stripped the properties and
counted the scaffolding as model speech. Differential: old code fires
(30 previews > 20), new code must not (5 model lines < 20)."
  (let ((buf (get-buffer-create "*test-runaway-scaffold*")))
    (unwind-protect
        (with-current-buffer buf
          (erase-buffer)
          ;; 30 identical tool-block previews, propertized as gptel
          ;; machine-inserted regions (half 'ignore fences, half tool
          ;; blocks -- both classes the helper must exclude).
          (dotimes (_ 15)
            (insert (propertize "``` tool (execute_code_local :command \"cd /root/i.ar ...)"
                                'gptel 'ignore)
                    "\n"))
          (dotimes (_ 15)
            (insert (propertize "⦿ Tool result: [03:21:52] --- services:\nactive\nactive"
                                'gptel '(tool . 42))
                    "\n"))
          ;; 5 model lines -- under the 20-line threshold. Must NOT fire.
          (let ((start (point)))
            (dotimes (_ 5) (insert "Normal model analysis line.\n"))
            (should-not (iar--cycle-output-runaway-p start (point))))
          ;; Control: 25 identical MODEL lines MUST still fire.
          (let ((start (point)))
            (dotimes (_ 25) (insert "Degenerate repeated model line.\n"))
            (should (iar--cycle-output-runaway-p start (point)))))
      (kill-buffer buf))))
