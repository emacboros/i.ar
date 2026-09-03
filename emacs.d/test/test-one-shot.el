;; -*- lexical-binding: t; -*-

;;; Tests for one-shot mode in iar-agent-cycle.el
;; Tests the pure helper functions: iar--one-shot-extract-response,
;; iar--one-shot-make-state, and iar--one-shot-tool-call-tracker.
;; The main iar-run-one-shot function involves timers, processes,
;; and gptel state -- too complex for unit tests without heavy mocking.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-agent-cycle)

;;; --- iar--one-shot-extract-response: delimiter detection ---

(ert-deftest test-one-shot-extract-response-basic ()
  "Should extract content between delimiters."
  (let ((text "Some reasoning here.\n\n=== BEGIN FINAL RESPONSE ===\nThis is the final output.\n=== END FINAL RESPONSE ===\n"))
    (should (string= "This is the final output."
                     (iar--one-shot-extract-response text)))))

(ert-deftest test-one-shot-extract-response-multiline ()
  "Should extract multi-line content between delimiters."
  (let ((text "Work done.\n=== BEGIN FINAL RESPONSE ===\nLine 1\nLine 2\nLine 3\n=== END FINAL RESPONSE ==="))
    (should (string= "Line 1\nLine 2\nLine 3"
                     (iar--one-shot-extract-response text)))))

(ert-deftest test-one-shot-extract-response-no-delimiters ()
  "Should return nil when delimiters are not present."
  (let ((text "Just some text without delimiters."))
    (should (null (iar--one-shot-extract-response text)))))

(ert-deftest test-one-shot-extract-response-only-open ()
  "Should return nil when only the opening delimiter is present."
  (let ((text "=== BEGIN FINAL RESPONSE ===\nSome text but no close."))
    (should (null (iar--one-shot-extract-response text)))))

(ert-deftest test-one-shot-extract-response-only-close ()
  "Should return nil when only the closing delimiter is present."
  (let ((text "Some text but no open.\n=== END FINAL RESPONSE ==="))
    (should (null (iar--one-shot-extract-response text)))))

(ert-deftest test-one-shot-extract-response-empty-content ()
  "Should return empty string when delimiters are adjacent."
  (let ((text "=== BEGIN FINAL RESPONSE ===\n=== END FINAL RESPONSE ==="))
    (should (string= "" (iar--one-shot-extract-response text)))))

(ert-deftest test-one-shot-extract-response-whitespace-trimmed ()
  "Should trim whitespace around extracted content."
  (let ((text "=== BEGIN FINAL RESPONSE ===\n\n  Content here  \n\n=== END FINAL RESPONSE ==="))
    (should (string= "Content here"
                     (iar--one-shot-extract-response text)))))

(ert-deftest test-one-shot-extract-response-content-with-delimiter-text ()
  "Should handle content that mentions the delimiter text without matching."
  (let ((text "=== BEGIN FINAL RESPONSE ===\nI looked for === END FINAL RESPONSE === but found nothing.\n=== END FINAL RESPONSE ==="))
    (should (string= "I looked for === END FINAL RESPONSE === but found nothing."
                     (iar--one-shot-extract-response text)))))

(ert-deftest test-one-shot-extract-response-empty-input ()
  "Should return nil for empty string input."
  (should (null (iar--one-shot-extract-response ""))))

;;; --- Parity: fences dispatch to one-shot (2026-09-03) ---
;; The cap, breaker, and tombstone dispatch on the active state:
;; cycle first, then one-shot. These tests pin the one-shot side;
;; the cycle side is pinned in test-invisible-cycle-fences.el.

(ert-deftest test-one-shot-cap-blocks-at-limit ()
  "SOFT cap fires for a one-shot run past the tool-call cap: the
call is blocked with the DELIMITER landing (not CYCLE_COMPLETE --
a one-shot has no cycle to complete), and the run is NOT ended."
  (let ((buf (get-buffer-create "*test-oneshot-cap*")))
    (unwind-protect
        (let ((iar--cycle-state nil)
              (iar--one-shot-state (iar--one-shot-make-state "test" buf 40)))
          (setf (plist-get iar--one-shot-state :tool-call-count)
                iar-cycle-tool-call-cap)
          (let ((result (iar--cycle-tool-call-cap
                         (list :name "execute_code_local" :args nil))))
            (should (plist-get result :block))
            (should (string-match-p "BEGIN FINAL RESPONSE"
                                    (plist-get result :block)))
            (should-not (string-match-p "CYCLE_COMPLETE"
                                        (plist-get result :block)))
            (should-not (plist-get iar--one-shot-state :completed))
            (should (= 1 (plist-get iar--one-shot-state :cap-blocks)))))
      (kill-buffer buf))))

(ert-deftest test-one-shot-cap-allows-memory-tools-past-soft-cap ()
  "Memory/record tools pass through the soft cap for one-shot runs
too -- the landing IS the record."
  (let ((buf (get-buffer-create "*test-oneshot-cap2*")))
    (unwind-protect
        (let ((iar--cycle-state nil)
              (iar--one-shot-state (iar--one-shot-make-state "test" buf 40)))
          (setf (plist-get iar--one-shot-state :tool-call-count)
                iar-cycle-tool-call-cap)
          (should-not (iar--cycle-tool-call-cap
                       (list :name "append_file" :args nil)))
          (should (= 0 (plist-get iar--one-shot-state :cap-blocks))))
      (kill-buffer buf))))

(ert-deftest test-one-shot-cap-hard-kill-after-ignored-blocks ()
  "HARD cap ends a one-shot run too: completed, exit 1."
  (let ((buf (get-buffer-create "*test-oneshot-cap3*")))
    (unwind-protect
        (let ((iar--cycle-state nil)
              (iar--one-shot-state (iar--one-shot-make-state "test" buf 40)))
          (setf (plist-get iar--one-shot-state :tool-call-count)
                iar-cycle-tool-call-cap)
          (dotimes (_ (1- iar-cycle-tool-call-hard-cap))
            (iar--cycle-tool-call-cap (list :name "read_file" :args nil)))
          (let ((result (iar--cycle-tool-call-cap
                         (list :name "read_file" :args nil))))
            (should (plist-get result :block))
            (should (plist-get iar--one-shot-state :completed))
            (should (= 1 (plist-get iar--one-shot-state :exit-code)))))
      (kill-buffer buf))))

(ert-deftest test-one-shot-cap-under-limit-passes ()
  "Under the cap the fence is invisible for one-shot runs."
  (let ((buf (get-buffer-create "*test-oneshot-cap4*")))
    (unwind-protect
        (let ((iar--cycle-state nil)
              (iar--one-shot-state (iar--one-shot-make-state "test" buf 40)))
          ;; call #59: below the warn threshold, untouched
          (setf (plist-get iar--one-shot-state :tool-call-count) 58)
          (should-not (iar--cycle-tool-call-cap
                       (list :name "read_file" :args nil)))
          ;; call #120: warn already fired, still under the cap
          (setf (plist-get iar--one-shot-state :tool-call-count) 119)
          (setf (plist-get iar--one-shot-state :cap-warned) t)
          (should-not (iar--cycle-tool-call-cap
                       (list :name "read_file" :args nil))))
      (kill-buffer buf))))

(ert-deftest test-one-shot-breaker-arms-and-ends ()
  "Context breaker dispatches to one-shot: first fire arms (grace
round-trip), second fire ends the run (completed, exit 1)."
  (let ((buf (get-buffer-create "*test-oneshot-breaker*")))
    (unwind-protect
        (let ((iar-cycle-context-limit-chars 100)
              (iar--cycle-state nil)
              (iar--one-shot-state (iar--one-shot-make-state "test" buf 40)))
          (with-current-buffer buf (insert (make-string 200 ?x)))
          ;; First fire: arms the breaker
          (let ((r1 (iar--cycle-context-breaker
                     (list :name "execute_code_local" :args '(:command "ls")))))
            (should (plist-get r1 :block))
            (should (plist-get iar--one-shot-state :breaker-fired))
            (should-not (plist-get iar--one-shot-state :completed)))
          ;; Second fire: ends the run
          (let ((r2 (iar--cycle-context-breaker
                     (list :name "execute_code_local" :args '(:command "pwd")))))
            (should (plist-get r2 :block))
            (should (plist-get iar--one-shot-state :completed))
            (should (= 1 (plist-get iar--one-shot-state :exit-code)))))
      (kill-buffer buf))))

(ert-deftest test-one-shot-breaker-allows-under-limit ()
  "Under the context limit the breaker never fires for one-shot runs."
  (let ((buf (get-buffer-create "*test-oneshot-breaker2*")))
    (unwind-protect
        (let ((iar-cycle-context-limit-chars 100000)
              (iar--cycle-state nil)
              (iar--one-shot-state (iar--one-shot-make-state "test" buf 40)))
          (with-current-buffer buf (insert (make-string 200 ?x)))
          (should-not (iar--cycle-context-breaker
                       (list :name "execute_code_local" :args '(:command "ls")))))
      (kill-buffer buf))))

(ert-deftest test-one-shot-tombstone-writes-journal ()
  "The tombstone dispatches to one-shot state: writes the [TIMED
OUT] record to the agent's cycle.log. Before the parity fix a
timed-out one-shot exited 0 with NOTHING written."
  (let* ((tmpdir (make-temp-file "test-oneshot-tomb-" :dir-flag))
         (iar-personalization-path tmpdir)
         (iar-audit-path "audit"))
    (cl-letf (((symbol-function 'iar--current-project-name) (lambda () "test-project"))
              ((symbol-function 'iar--usage-totals)
               (lambda () (list :input-tokens 1000 :output-tokens 500
                                :total-tokens 1500 :requests 42))))
      (unwind-protect
          (let ((buf (get-buffer-create "*test-oneshot-tomb*")))
            (unwind-protect
                (with-current-buffer buf
                  (insert "last one-shot activity before the timeout")
                  (let ((iar--cycle-state nil)
                        (iar--one-shot-state
                         (iar--one-shot-make-state "test-agent" buf 40)))
                    (setf (plist-get iar--one-shot-state :turn-count) 3)
                    (setf (plist-get iar--one-shot-state :tool-call-count) 17)
                    (iar--cycle-tombstone "test-agent" 7200)
                    (let ((log-path (expand-file-name
                                     "audit/test-project/test-agent/cycle.log" tmpdir)))
                      (should (file-exists-p log-path))
                      (with-temp-buffer
                        (insert-file-contents log-path)
                        (let ((content (buffer-string)))
                          (should (string-match-p "\\[TIMED OUT\\]" content))
                          (should (string-match-p "Turns: 3" content))
                          (should (string-match-p "Tool calls: 17" content))
                          (should (string-match-p "42 requests" content))
                          (should (string-match-p "last one-shot activity" content)))))))
              (kill-buffer buf)))
        (delete-directory tmpdir t)))))

(ert-deftest test-one-shot-tombstone-cycle-state-takes-precedence ()
  "When both states are active (cycle running a delegate that
started a one-shot), the tombstone records the CYCLE state."
  (let* ((tmpdir (make-temp-file "test-oneshot-tomb2-" :dir-flag))
         (iar-personalization-path tmpdir)
         (iar-audit-path "audit"))
    (cl-letf (((symbol-function 'iar--current-project-name) (lambda () "test-project"))
              ((symbol-function 'iar--usage-totals)
               (lambda () (list :input-tokens 0 :output-tokens 0
                                :total-tokens 0 :requests 0))))
      (unwind-protect
          (let ((cbuf (get-buffer-create "*test-oneshot-tomb2-c*"))
                (obuf (get-buffer-create "*test-oneshot-tomb2-o*")))
            (unwind-protect
                (with-current-buffer cbuf
                  (insert "cycle activity")
                  (let ((iar--cycle-state
                         (iar--cycle-make-state "test-agent" cbuf nil 40))
                        (iar--one-shot-state
                         (iar--one-shot-make-state "test-agent" obuf 40)))
                    (setf (plist-get iar--cycle-state :turn-count) 9)
                    (setf (plist-get iar--one-shot-state :turn-count) 2)
                    (iar--cycle-tombstone "test-agent" 1800)
                    (with-temp-buffer
                      (insert-file-contents
                       (expand-file-name "audit/test-project/test-agent/cycle.log" tmpdir))
                      (should (string-match-p "Turns: 9" (buffer-string))))))
              (kill-buffer cbuf)
              (kill-buffer obuf)))
        (delete-directory tmpdir t)))))

(ert-deftest test-one-shot-tracker-state-guarded ()
  "The one-shot tracker must not signal with no active one-shot
state (it now fires globally on every tool call, including during
cycle runs and interactive use)."
  (let ((iar--one-shot-state nil))
    (should-not (iar--one-shot-tool-call-tracker nil nil))))

(ert-deftest test-one-shot-make-state-has-cap-blocks ()
  "One-shot state carries :cap-blocks (the hard-cap counter) --
the fence machinery reads it."
  (let ((state (iar--one-shot-make-state "test" nil 40)))
    (should (= 0 (plist-get state :cap-blocks)))))

;;; --- iar--one-shot-make-state ---

(ert-deftest test-one-shot-make-state-defaults ()
  "Should create a state plist with correct defaults."
  (let ((state (iar--one-shot-make-state "mirror" (get-buffer-create "*test*") 40)))
    (should (string= "mirror" (plist-get state :agent)))
    (should (= 40 (plist-get state :max-turns)))
    (should (= 0 (plist-get state :turn-count)))
    (should (= 0 (plist-get state :tool-call-count)))
    (should (null (plist-get state :completed)))
    (should (= 0 (plist-get state :exit-code)))
    (should (null (plist-get state :final-response)))))

;;; --- iar--one-shot-tool-call-tracker ---

(ert-deftest test-one-shot-tool-call-tracker-increments ()
  "Should increment tool-call-count in the current one-shot state."
  (let ((iar--one-shot-state (iar--one-shot-make-state "test" nil 40)))
    (iar--one-shot-tool-call-tracker nil nil)
    (should (= 1 (plist-get iar--one-shot-state :tool-call-count)))
    (iar--one-shot-tool-call-tracker nil nil)
    (should (= 2 (plist-get iar--one-shot-state :tool-call-count)))))

;;; --- Delimiter config tests ---

(ert-deftest test-one-shot-delimiter-config-non-empty ()
  "Delimiter config values should be non-empty strings."
  (should (stringp iar-one-shot-response-open))
  (should (< 0 (length iar-one-shot-response-open)))
  (should (stringp iar-one-shot-response-close))
  (should (< 0 (length iar-one-shot-response-close))))

(ert-deftest test-one-shot-delimiter-config-contains-final-response ()
  "Delimiter config should contain 'FINAL RESPONSE' text."
  (should (string-match-p "FINAL RESPONSE" iar-one-shot-response-open))
  (should (string-match-p "FINAL RESPONSE" iar-one-shot-response-close)))

;;; --- Nudge prompt test ---

(ert-deftest test-one-shot-nudge-prompt-non-empty ()
  "Nudge prompt should be a non-empty string containing delimiter instructions."
  (should (stringp iar--one-shot-nudge-prompt))
  (should (< 0 (length iar--one-shot-nudge-prompt)))
  (should (string-match-p "BEGIN FINAL RESPONSE" iar--one-shot-nudge-prompt))
  (should (string-match-p "END FINAL RESPONSE" iar--one-shot-nudge-prompt)))

(provide 'test-one-shot)
;;; --- Additional coverage tests ---

(ert-deftest test-one-shot-post-response-handler-complete ()
  "iar--one-shot-post-response-handler should detect completion delimiters."
  (let ((buf (get-buffer-create "*test-oneshot-pr*")))
    (unwind-protect
        (with-current-buffer buf
          (insert "=== BEGIN FINAL RESPONSE ===\nTest response\n=== END FINAL RESPONSE ===\n")
          (let ((iar--one-shot-state (iar--one-shot-make-state "test" buf 40)))
            ;; handler signature is (start end): the new response region
            (iar--one-shot-post-response-handler (point-min) (point-max))
            (should (plist-get iar--one-shot-state :completed))
            (should (string= "Test response" (plist-get iar--one-shot-state :final-response)))))
      (kill-buffer buf))))

(ert-deftest test-one-shot-post-response-handler-no-delimiters ()
  "iar--one-shot-post-response-handler should not complete without delimiters.
MUST mock gptel-send: the nudge path fires a real request whose async
response arrives during a LATER test (stray process filter on a dead
buffer -> the documented suite heisenbug). This was the root cause."
  (let ((buf (get-buffer-create "*test-oneshot-pr2*")))
    (unwind-protect
        (with-current-buffer buf
          (insert "response without delimiters\n")
          (let ((iar--one-shot-state (iar--one-shot-make-state "test" buf 40)))
            (cl-letf (((symbol-function 'gptel-send) (lambda () nil)))
              (iar--one-shot-post-response-handler (point-min) (point-max))
              (should-not (plist-get iar--one-shot-state :completed)))))
      (kill-buffer buf))))

(ert-deftest test-one-shot-post-response-handler-max-turns ()
  "iar--one-shot-post-response-handler should end at max turns.
MUST mock gptel-send: turn 1 hits the nudge path (real request -> stray
async response -> suite heisenbug)."
  (let ((buf (get-buffer-create "*test-oneshot-pr3*")))
    (unwind-protect
        (with-current-buffer buf
          (insert "response\n")
          (let ((iar--one-shot-state (iar--one-shot-make-state "test" buf 2)))
            (cl-letf (((symbol-function 'gptel-send) (lambda () nil)))
              ;; turn 1: real positions (success path, under limit)
              (iar--one-shot-post-response-handler (point-min) (point-max))
              ;; turn 2: real positions again (success path, hits limit)
              (iar--one-shot-post-response-handler (point-min) (point-max))
              (should (plist-get iar--one-shot-state :completed)))))
      (kill-buffer buf))))

(provide 'test-one-shot)
;;; test-one-shot.el ends here
