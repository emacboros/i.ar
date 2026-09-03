;; Tests: post-response breaker (text-only runaway coverage).
(require 'ert)
(require 'iar-agent-cycle)
(require 'iar-tool-call)

(ert-deftest test-fence-breaker-text-arms-on-first-over-limit-continue ()
  "A text-only turn at over-limit context arms the breaker and
blocks the continue re-send -- the pre-tool-call breaker never sees
prose turns; without this the runaway re-sends 800k chars per turn
until max-turns."
  (let ((buf (get-buffer-create "*test-breaker-text1*")))
    (unwind-protect
        (let ((iar-cycle-context-limit-chars 100)
              (iar--cycle-state (iar--cycle-make-state "test" buf "Continue." 40))
              (iar--one-shot-state nil)
              (iar--cycle-error-strikes 0))
          (with-current-buffer buf (insert (make-string 200 ?x)))
          (with-current-buffer buf
            (let ((start (point)))
              (insert "prose response, no sentinel")
              (iar--cycle-post-response-handler start (point))))
          (should (plist-get iar--cycle-state :breaker-fired))
          ;; Not ended yet: grace round-trip granted
          (should-not (plist-get iar--cycle-state :completed)))
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
          (with-current-buffer buf
            (let ((start (point)))
              (insert "prose response 1")
              (iar--cycle-post-response-handler start (point))))
          ;; Second text turn, still over limit
          (with-current-buffer buf
            (let ((start (point)))
              (insert "prose response 2")
              (iar--cycle-post-response-handler start (point))))
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
          ;; Text-only continue: shared flag -> ends run
          (with-current-buffer buf
            (let ((start (point)))
              (insert "prose response")
              (iar--cycle-post-response-handler start (point))))
          (should (plist-get iar--cycle-state :completed))
          (should (= 1 (plist-get iar--cycle-state :exit-code))))
      (kill-buffer buf))))

(ert-deftest test-fence-breaker-text-no-state-passes ()
  "No active state -> the text check is a no-op (nil)."
  (let ((iar--cycle-state nil)
        (iar--one-shot-state nil))
    (should-not (iar--cycle-breaker-text-check nil))))
