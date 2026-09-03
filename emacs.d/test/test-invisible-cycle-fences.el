;; -*- lexical-binding: t; -*-

;;; Tests for the invisible-cycle fences (fix A + fix C)
;;
;; Fix A: reliable tool-call counting + per-cycle cap.
;;   The old tracker ran on a buffer-local hook in cycle-buf, but the
;;   advice that fires it runs from async sentinels where
;;   current-buffer != cycle-buf -- 360 calls counted as 13.
;;   New design: the tracker is GLOBAL (default-value based), the
;;   counter lives in iar--cycle-state (global special var), and a
;;   pre-tool-call hook enforces the cap.
;;
;; Fix D: context circuit breaker (2026-09-02, continuo): when the cycle
;; buffer exceeds 800k chars (~200k tokens), the breaker blocks tool
;; calls -- first fire grants one grace round-trip to write a summary,
;; second fire ends the cycle.
;;
;; Fix C: timeout tombstone. When the cycle times out, the state that
;;   exists at kill time (turns, tool calls, tokens, last activity)
;;   is written to the journal before kill-emacs, instead of dying
;;   silently (four cycles on Sep 1-2 burned ~150M tokens with zero
;;   record).
;;
;; Evidence: knowledge/aria/invisible-cycles.md (cycle 127, 2026-09-02).
;;
;; 2026-09-03 parity fix (continuo): the cap, breaker, and tombstone
;; now dispatch on the active state -- cycle first, then one-shot
;; (iar--one-shot-state). One-shot runs were previously UNPROTECTED:
;; no cap, no breaker, no tombstone. Tests in test-one-shot.el cover
;; the one-shot side; these tests pin the cycle side.

(require 'ert)
(require 'cl-lib)
(require 'iar-agent-cycle)
(require 'iar-tool-call)

;;; --- Fix A: global tool-call tracking ---

(ert-deftest test-fence-tool-call-tracker-counts-outside-cycle-buffer ()
  "The tracker must increment even when current-buffer is NOT the
cycle buffer (async sentinel context). Regression for the 360-as-13
bug: the old buffer-local hook never fired from sentinels."
  (let ((cycle-buf (get-buffer-create "*test-fence-cycle*"))
        (other-buf (get-buffer-create "*test-fence-other*")))
    (unwind-protect
        (let ((iar--cycle-state (iar--cycle-make-state "test" cycle-buf nil 40)))
          (with-current-buffer other-buf
            (iar--cycle-tool-call-tracker nil nil)
            (iar--cycle-tool-call-tracker nil nil)
            (iar--cycle-tool-call-tracker nil nil))
          (should (= 3 (plist-get iar--cycle-state :tool-call-count))))
      (kill-buffer cycle-buf)
      (kill-buffer other-buf))))

(ert-deftest test-fence-tool-call-tracker-no-state-is-silent ()
  "Tracker with no active cycle state must not signal (sentinels
run in arbitrary contexts; a tracker error would kill the chain)."
  (let ((iar--cycle-state nil))
    (should-not (iar--cycle-tool-call-tracker nil nil))))

(ert-deftest test-fence-tool-call-tracker-accumulates ()
  "Multiple calls accumulate in the state plist."
  (let ((buf (get-buffer-create "*test-fence-acc*")))
    (unwind-protect
        (let ((iar--cycle-state (iar--cycle-make-state "test" buf nil 40)))
          (dotimes (_ 7)
            (iar--cycle-tool-call-tracker "execute_code_local" "result"))
          (should (= 7 (plist-get iar--cycle-state :tool-call-count))))
      (kill-buffer buf))))

;;; --- Fix A: per-cycle tool-call cap ---

(ert-deftest test-fence-cap-blocks-at-limit ()
  "SOFT cap: the call that exceeds the cap is blocked (with the
landing message), but the cycle is NOT completed -- the model gets
its CYCLE_COMPLETE landing. Regression for the 53 exit-1 cycles
(2026-09-02) that burned 2.5M tokens with zero memory writes."
  (let ((cycle-buf (get-buffer-create "*test-fence-cap*")))
    (unwind-protect
        (let ((iar--cycle-state (iar--cycle-make-state "test" cycle-buf nil 40))
              (iar--one-shot-state nil))
          (setf (plist-get iar--cycle-state :tool-call-count) iar-cycle-tool-call-cap)
          (let ((result (iar--cycle-tool-call-cap
                         (list :name "execute_code_local" :args nil))))
            (should (plist-get result :block))
            (should (string-match-p "CYCLE_COMPLETE" (plist-get result :block)))
            ;; NOT completed -- soft cap grants the landing
            (should-not (plist-get iar--cycle-state :completed))
            ;; block counter armed
            (should (= 1 (plist-get iar--cycle-state :cap-blocks)))))
      (kill-buffer cycle-buf))))

(ert-deftest test-fence-cap-allows-under-limit ()
  "Calls under the cap pass through untouched."
  (let ((cycle-buf (get-buffer-create "*test-fence-cap2*")))
    (unwind-protect
        (let ((iar--cycle-state (iar--cycle-make-state "test" cycle-buf nil 40))
              (iar--one-shot-state nil))
          (setf (plist-get iar--cycle-state :tool-call-count) 59)
          (should-not (iar--cycle-tool-call-cap
                       (list :name "read_file" :args nil))))
      (kill-buffer cycle-buf))))

(ert-deftest test-fence-cap-no-state-passes ()
  "No active cycle (interactive use) -- cap never fires."
  (let ((iar--cycle-state nil)
        (iar--one-shot-state nil))
    (should-not (iar--cycle-tool-call-cap
                 (list :name "read_file" :args nil)))))

(ert-deftest test-fence-cap-default-is-120 ()
  "The cap default is 120 tool calls per cycle."
  (should (= 120 iar-cycle-tool-call-cap)))

(ert-deftest test-fence-cap-hard-kill-after-ignored-blocks ()
  "HARD cap: after `iar-cycle-tool-call-hard-cap' ignored soft
blocks, the cycle IS force-ended (completed, exit 1) -- runaway
confirmed, the model is not responding to the landing instruction."
  (let ((cycle-buf (get-buffer-create "*test-fence-cap3*")))
    (unwind-protect
        (let ((iar--cycle-state (iar--cycle-make-state "test" cycle-buf nil 40))
              (iar--one-shot-state nil))
          (setf (plist-get iar--cycle-state :tool-call-count) iar-cycle-tool-call-cap)
          ;; Burn through the soft blocks
          (dotimes (_ (1- iar-cycle-tool-call-hard-cap))
            (iar--cycle-tool-call-cap (list :name "read_file" :args nil))
            ;; simulate the model ignoring the block: counter not reset
            )
          (let ((result (iar--cycle-tool-call-cap (list :name "read_file" :args nil))))
            (should (plist-get result :block))
            (should (plist-get iar--cycle-state :completed))
            (should (= 1 (plist-get iar--cycle-state :exit-code)))))
      (kill-buffer cycle-buf))))

(ert-deftest test-fence-cap-memory-tools-allowed-past-soft-cap ()
  "Memory/record tools (append_file, write_file, git_commit, ...)
are NEVER blocked by the soft cap -- the landing IS the memory
pass. Only non-memory tools are blocked."
  (let ((cycle-buf (get-buffer-create "*test-fence-cap4*")))
    (unwind-protect
        (let ((iar--cycle-state (iar--cycle-make-state "test" cycle-buf nil 40))
              (iar--one-shot-state nil))
          (setf (plist-get iar--cycle-state :tool-call-count) iar-cycle-tool-call-cap)
          (should-not (iar--cycle-tool-call-cap
                       (list :name "append_file" :args nil)))
          (should-not (iar--cycle-tool-call-cap
                       (list :name "write_file" :args nil)))
          (should-not (iar--cycle-tool-call-cap
                       (list :name "git_commit" :args nil)))
          (should-not (iar--cycle-tool-call-cap
                       (list :name "send_telegram" :args nil)))
          ;; and no blocks were counted
          (should (= 0 (plist-get iar--cycle-state :cap-blocks))))
      (kill-buffer cycle-buf))))

;;; --- Fix C: timeout tombstone ---

(ert-deftest test-fence-tombstone-writes-journal ()
  "The tombstone writes a [TIMED OUT] entry with counts to the
agent's cycle.log."
  (let* ((tmpdir (make-temp-file "test-fence-tomb-" :dir-flag))
         (iar-personalization-path tmpdir)
         (iar-audit-path "audit"))
    (cl-letf (((symbol-function 'iar--current-project-name) (lambda () "test-project"))
              ((symbol-function 'iar--usage-totals)
               (lambda () (list :input-tokens 1000 :output-tokens 500
                                :total-tokens 1500 :requests 42))))
      (unwind-protect
          (let ((buf (get-buffer-create "*test-fence-tomb*")))
            (unwind-protect
                (with-current-buffer buf
                  (insert "last model activity before the timeout")
                  (let ((iar--cycle-state
                         (iar--cycle-make-state "test-agent" buf nil 40))
                        (iar--one-shot-state nil))
                    (setf (plist-get iar--cycle-state :turn-count) 5)
                    (setf (plist-get iar--cycle-state :tool-call-count) 23)
                    (iar--cycle-tombstone "test-agent" 1800)
                    (let ((log-path (expand-file-name
                                     "audit/test-project/test-agent/cycle.log" tmpdir)))
                      (should (file-exists-p log-path))
                      (with-temp-buffer
                        (insert-file-contents log-path)
                        (let ((content (buffer-string)))
                          (should (string-match-p "\\[TIMED OUT\\]" content))
                          (should (string-match-p "Turns: 5" content))
                          (should (string-match-p "Tool calls: 23" content))
                          (should (string-match-p "42 requests" content))
                          (should (string-match-p "last model activity" content)))))))
              (kill-buffer buf)))
        (delete-directory tmpdir t)))))

(ert-deftest test-fence-tombstone-no-state-is-safe ()
  "Tombstone with no cycle state must not signal (timeout path runs
at kill time; an error here would mask the exit)."
  (let ((iar--cycle-state nil)
        (iar--one-shot-state nil))
    (should-not (iar--cycle-tombstone "test-agent" 1800))))

(ert-deftest test-fence-tombstone-truncates-last-activity ()
  "The last-activity excerpt is capped (200 chars) -- a huge final
response must not bloat the tombstone."
  (let* ((tmpdir (make-temp-file "test-fence-tomb2-" :dir-flag))
         (iar-personalization-path tmpdir)
         (iar-audit-path "audit"))
    (cl-letf (((symbol-function 'iar--current-project-name) (lambda () "test-project"))
              ((symbol-function 'iar--usage-totals) (lambda () (list :input-tokens 0 :output-tokens 0 :total-tokens 0 :requests 0))))
      (unwind-protect
          (let ((buf (get-buffer-create "*test-fence-tomb2*")))
            (unwind-protect
                (with-current-buffer buf
                  (insert (make-string 1000 ?x))
                  (let ((iar--cycle-state
                         (iar--cycle-make-state "test-agent" buf nil 40))
                        (iar--one-shot-state nil))
                    (iar--cycle-tombstone "test-agent" 1800)
                    (with-temp-buffer
                      (insert-file-contents
                       (expand-file-name "audit/test-project/test-agent/cycle.log" tmpdir))
                      ;; 1000 x's inserted, excerpt must be capped at 200
                      (should (<= (length
                                   (buffer-substring-no-properties
                                    (point-min) (point-max)))
                                  1200))))))
              (kill-buffer buf)))
        (delete-directory tmpdir t))))

(ert-deftest test-fence-tombstone-records-timeout-duration ()
  "The tombstone records the timeout that killed the cycle."
  (let* ((tmpdir (make-temp-file "test-fence-tomb3-" :dir-flag))
         (iar-personalization-path tmpdir)
         (iar-audit-path "audit"))
    (cl-letf (((symbol-function 'iar--current-project-name) (lambda () "test-project"))
              ((symbol-function 'iar--usage-totals) (lambda () (list :input-tokens 0 :output-tokens 0 :total-tokens 0 :requests 0))))
      (unwind-protect
          (let ((buf (get-buffer-create "*test-fence-tomb3*")))
            (unwind-protect
                (with-current-buffer buf
                  (insert "x")
                  (let ((iar--cycle-state
                         (iar--cycle-make-state "test-agent" buf nil 40))
                        (iar--one-shot-state nil))
                    (iar--cycle-tombstone "test-agent" 1800)
                    (with-temp-buffer
                      (insert-file-contents
                       (expand-file-name "audit/test-project/test-agent/cycle.log" tmpdir))
                      (should (string-match-p "1800s" (buffer-string)))))))
              (kill-buffer buf)))
        (delete-directory tmpdir t))))

;;; --- Wiring: hooks registered globally ---

(ert-deftest test-fence-cap-hook-is-registered ()
  "The cap hook must be registered on the GLOBAL
iar-pre-tool-call-functions hook (the bridge runs it via
run-hook-with-args-until-success from the conversation buffer
context)."
  (should (memq #'iar--cycle-tool-call-cap iar-pre-tool-call-functions)))

(ert-deftest test-fence-tracker-hook-is-global ()
  "The tracker must be on the GLOBAL iar-post-tool-call-functions
hook, not buffer-local in cycle-buf. Regression for the context-
blind counter."
  (should (memq #'iar--cycle-tool-call-tracker iar-post-tool-call-functions)))

(ert-deftest test-fence-oneshot-tracker-hook-is-global ()
  "The one-shot tracker must ALSO be on the GLOBAL hook. The old
buffer-local registration in iar-run-one-shot never fired from
async sentinels (360-as-13 class, one-shot edition) and would
double-count on top of the global registration."
  (should (memq #'iar--one-shot-tool-call-tracker iar-post-tool-call-functions)))

;;; --- Fix D: context circuit breaker ---

(ert-deftest test-fence-breaker-arms-on-first-fire ()
  "First fire over the context limit blocks the call and arms the
breaker (:breaker-fired) -- the model gets one grace round-trip to
write its summary as text. Regression for the 1082-msg runaway that
re-sent a ~254k-token context 100+ times."
  (let ((buf (get-buffer-create "*test-fence-breaker1*")))
    (unwind-protect
        (let ((iar-cycle-context-limit-chars 100)
              (iar--cycle-state (iar--cycle-make-state "test" buf nil 40))
              (iar--one-shot-state nil))
          (with-current-buffer buf (insert (make-string 200 ?x)))
          (let ((result (iar--cycle-context-breaker
                         (list :name "execute_code_local" :args '(:command "ls")))))
            (should result)
            (should (plist-get result :block))
            (should (string-match-p "circuit breaker" (plist-get result :block)))
            ;; NOT completed yet -- grace round-trip granted
            (should-not (plist-get iar--cycle-state :completed))
            (should (plist-get iar--cycle-state :breaker-fired))))
      (kill-buffer buf))))

(ert-deftest test-fence-breaker-ends-cycle-on-second-fire ()
  "After the grace round-trip, any further tool call ends the cycle
(completed, exit 1) -- the model had its chance to write the summary."
  (let ((buf (get-buffer-create "*test-fence-breaker2*")))
    (unwind-protect
        (let ((iar-cycle-context-limit-chars 100)
              (iar--cycle-state (iar--cycle-make-state "test" buf nil 40))
              (iar--one-shot-state nil))
          (with-current-buffer buf (insert (make-string 200 ?x)))
          ;; First fire: arms the breaker
          (should (iar--cycle-context-breaker
                   (list :name "execute_code_local" :args '(:command "ls"))))
          ;; Second fire: ends the cycle
          (let ((result (iar--cycle-context-breaker
                         (list :name "execute_code_local" :args '(:command "pwd")))))
            (should result)
            (should (plist-get result :block))
            (should (plist-get iar--cycle-state :completed))
            (should (= 1 (plist-get iar--cycle-state :exit-code)))))
      (kill-buffer buf))))

(ert-deftest test-fence-breaker-allows-under-limit ()
  "Under the limit the breaker is invisible."
  (let ((buf (get-buffer-create "*test-fence-breaker3*")))
    (unwind-protect
        (let ((iar-cycle-context-limit-chars 100000)
              (iar--cycle-state (iar--cycle-make-state "test" buf nil 40))
              (iar--one-shot-state nil))
          (with-current-buffer buf (insert (make-string 200 ?x)))
          (should-not (iar--cycle-context-breaker
                       (list :name "execute_code_local" :args '(:command "ls"))))
          (should-not (plist-get iar--cycle-state :breaker-fired)))
      (kill-buffer buf))))

(ert-deftest test-fence-breaker-no-state-passes ()
  "No active cycle state (interactive session) -> nil, no signal."
  (let ((iar--cycle-state nil)
        (iar--one-shot-state nil))
    (should-not (iar--cycle-context-breaker
                 (list :name "execute_code_local" :args '(:command "ls"))))))

(ert-deftest test-fence-breaker-dead-buffer-treats-as-empty ()
  "A dead cycle buffer must not signal -- treat size as 0 (allow)."
  (let ((buf (get-buffer-create "*test-fence-breaker4*")))
    (unwind-protect
        (let ((iar-cycle-context-limit-chars 100)
              (iar--cycle-state (iar--cycle-make-state "test" buf nil 40))
              (iar--one-shot-state nil))
          (kill-buffer buf)
          (should-not (iar--cycle-context-breaker
                       (list :name "execute_code_local" :args '(:command "ls")))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest test-fence-breaker-default-limit-is-800k ()
  "Default limit is 800k chars (~200k tokens at 4 chars/token)."
  (should (= 800000 iar-cycle-context-limit-chars)))

(ert-deftest test-fence-breaker-hook-is-registered ()
  "The breaker must be on the GLOBAL iar-pre-tool-call-functions
hook (same reasoning as the cap: async sentinels run outside the
cycle buffer)."
  (should (memq #'iar--cycle-context-breaker iar-pre-tool-call-functions)))
(provide 'test-invisible-cycle-fences)
;;; test-invisible-cycle-fences.el ends here
(ert-deftest test-fence-writeback-pins-global-state ()
  "Pin iar--fence-state-writeback: mutation through the (or cycle
one-shot) alias must reach the OWNING global, not just the local
alias. Regression for the 2026-09-03 breaker bug: on Emacs 30.2
plist-put is destructive-append, so breaker tests passed even with
the writeback removed -- the fix was unpinned. This test binds the
globals to nil and a MINIMAL state (absent keys) so the writeback
is the only path that can land the write."
  (let ((iar--cycle-state nil)
        (iar--one-shot-state nil)
        (state (list :agent "test")))
    ;; Cycle path: global nil, state minimal -> only writeback lands it
    (setq iar--cycle-state state)
    (setq state (plist-put state :breaker-fired t))
    (iar--fence-state-writeback state)
    (should (plist-get iar--cycle-state :breaker-fired))
    ;; One-shot path
    (setq iar--cycle-state nil)
    (setq iar--one-shot-state (list :agent "test"))
    (setq state (plist-put state :breaker-fired nil))
    (iar--fence-state-writeback state)
    (should (eq (plist-get iar--one-shot-state :breaker-fired) nil))
    ;; Precedence: cycle state wins when both bound
    (setq iar--cycle-state (list :agent "c"))
    (setq iar--one-shot-state (list :agent "o"))
    (iar--fence-state-writeback (plist-put (list :agent "x") :completed t))
    (should (plist-get iar--cycle-state :completed))
    (should-not (plist-get iar--one-shot-state :completed))))
