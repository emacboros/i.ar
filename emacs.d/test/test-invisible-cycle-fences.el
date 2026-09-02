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
;; Fix C: timeout tombstone. When the cycle times out, the state that
;;   exists at kill time (turns, tool calls, tokens, last activity)
;;   is written to the journal before kill-emacs, instead of dying
;;   silently (four cycles on Sep 1-2 burned ~150M tokens with zero
;;   record).
;;
;; Evidence: knowledge/aria/invisible-cycles.md (cycle 127, 2026-09-02).

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
  "The cap hook must block the call that exceeds the cap."
  (let ((cycle-buf (get-buffer-create "*test-fence-cap*")))
    (unwind-protect
        (let ((iar--cycle-state (iar--cycle-make-state "test" cycle-buf nil 40)))
          (setf (plist-get iar--cycle-state :tool-call-count) 60)
          (let ((result (iar--cycle-tool-call-cap
                         (list :name "execute_code_local" :args nil))))
            (should (plist-get result :block))))
      (kill-buffer cycle-buf))))

(ert-deftest test-fence-cap-allows-under-limit ()
  "Calls under the cap pass through untouched."
  (let ((cycle-buf (get-buffer-create "*test-fence-cap2*")))
    (unwind-protect
        (let ((iar--cycle-state (iar--cycle-make-state "test" cycle-buf nil 40)))
          (setf (plist-get iar--cycle-state :tool-call-count) 59)
          (should-not (iar--cycle-tool-call-cap
                       (list :name "read_file" :args nil))))
      (kill-buffer cycle-buf))))

(ert-deftest test-fence-cap-no-state-passes ()
  "No active cycle (interactive use) -- cap never fires."
  (let ((iar--cycle-state nil))
    (should-not (iar--cycle-tool-call-cap
                 (list :name "read_file" :args nil)))))

(ert-deftest test-fence-cap-default-is-60 ()
  "The cap default is 60 tool calls per cycle."
  (should (= 60 iar-cycle-tool-call-cap)))

(ert-deftest test-fence-cap-block-marks-completed ()
  "When the cap fires, the cycle state is marked completed with
exit code 1 -- the event loop must end, not just this call blocked."
  (let ((cycle-buf (get-buffer-create "*test-fence-cap3*")))
    (unwind-protect
        (let ((iar--cycle-state (iar--cycle-make-state "test" cycle-buf nil 40)))
          (setf (plist-get iar--cycle-state :tool-call-count) 60)
          (iar--cycle-tool-call-cap (list :name "read_file" :args nil))
          (should (plist-get iar--cycle-state :completed))
          (should (= 1 (plist-get iar--cycle-state :exit-code))))
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
                         (iar--cycle-make-state "test-agent" buf nil 40)))
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
  (let ((iar--cycle-state nil))
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
                         (iar--cycle-make-state "test-agent" buf nil 40)))
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
                         (iar--cycle-make-state "test-agent" buf nil 40)))
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

(provide 'test-invisible-cycle-fences)
;;; test-invisible-cycle-fences.el ends here