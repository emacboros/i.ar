;; -*- lexical-binding: t; -*-

;;; Tests for the 0/0 tombstone policy (aria-0026, ratified session XI
;;; 2026-09-10). A text-only cycle-end with tokens_out=0 and stop=stop
;;; is indistinguishable from a clean end at the response layer, but it
;;; is a nemotron streaming anomaly (~1/900): the model emitted nothing.
;;; continuo turn 557 (req 260909165458-70) ended exit 0 with zero
;;; durable output -- no memory pass, no record. RULING: a 0/0 end is
;;; tombstone-worthy, never a clean end. Tombstone + exit 1, no re-send
;;; (a 0/0 end is already empty; re-prompting is the tombstone's job to
;;; record, not to fix -- c152 design finding).

(require 'ert)
(require 'cl-lib)
(require 'subr-x)

(require 'iar-request-log)
(require 'iar-agent-cycle)

;;; --- iar--cycle-empty-response-p (the detector) ---

(ert-deftest test-empty-response-stop-stop-zero-out-is-anomalous ()
  "stop=stop with tokens_out=0: the 0/0 tombstone shape."
  (let ((iar--reqlog-last-stop "stop")
        (iar--reqlog-last-tokens-out 0))
    (should (iar--cycle-empty-response-p))))

(ert-deftest test-empty-response-nil-out-is-not-anomalous ()
  "nil tokens_out (no data): NOT the 0/0 shape -- never fire on missing data."
  (let ((iar--reqlog-last-stop "stop")
        (iar--reqlog-last-tokens-out nil))
    (should-not (iar--cycle-empty-response-p))))

(ert-deftest test-empty-response-nonzero-out-is-not-anomalous ()
  "stop=stop with real output: a normal response."
  (let ((iar--reqlog-last-stop "stop")
        (iar--reqlog-last-tokens-out 2457))
    (should-not (iar--cycle-empty-response-p))))

(ert-deftest test-empty-response-nil-stop-is-not-anomalous ()
  "nil stop (no data): NOT the 0/0 shape."
  (let ((iar--reqlog-last-stop nil)
        (iar--reqlog-last-tokens-out 0))
    (should-not (iar--cycle-empty-response-p))))

(ert-deftest test-empty-response-length-stop-is-not-this-guard ()
  "stop=length is the truncated-output guard's shape, not this one --
even at 0 tokens it is not the 0/0 stop=stop anomaly."
  (let ((iar--reqlog-last-stop "length")
        (iar--reqlog-last-tokens-out 0))
    (should-not (iar--cycle-empty-response-p))))

;;; --- handler-level behavior ---

(ert-deftest test-empty-response-ends-cycle-tombstone-exit-1 ()
  "A 0/0 text-only end in the post-response handler: cycle completes,
exit 1, NO re-send (the tombstone records the anomaly; re-prompting a
0/0 end is not the fix -- continuo turn 557)."
  (let ((buf (get-buffer-create "*test-empty-resp1*"))
        (sent 0))
    (unwind-protect
        (let ((iar-cycle-context-limit-chars 100000)
              (iar--cycle-state (iar--cycle-make-state "test" buf "Continue." 40))
              (iar--one-shot-state nil)
              (iar--cycle-error-strikes 0)
              (iar--reqlog-last-stop "stop")
              (iar--reqlog-last-tokens-out 0))
          (with-current-buffer buf (erase-buffer) (insert (make-string 100 ?x)))
          (cl-letf (((symbol-function 'gptel-send)
                     (lambda () (cl-incf sent)))
                    ((symbol-function 'iar--cycle-tombstone)
                     (lambda (_agent _secs) t)))
            (with-current-buffer buf
              (let ((start (point)))
                (insert "\n")  ; empty model response region
                (iar--cycle-post-response-handler start (point)))))
          (should (plist-get iar--cycle-state :completed))
          (should (= 1 (plist-get iar--cycle-state :exit-code)))
          ;; No re-send: the empty end is recorded, not retried.
          (should (= 0 sent)))
      (kill-buffer buf))))

(ert-deftest test-empty-response-normal-end-unaffected ()
  "A normal text-only end (real tokens_out, sentinel present) still
completes exit 0 through the sentinel branch -- the 0/0 guard must
not shadow it."
  (let ((buf (get-buffer-create "*test-empty-resp2*"))
        (sent 0))
    (unwind-protect
        (let ((iar-cycle-context-limit-chars 100000)
              (iar--cycle-state (iar--cycle-make-state "test" buf "Continue." 40))
              (iar--one-shot-state nil)
              (iar--cycle-error-strikes 0)
              (iar--reqlog-last-stop "stop")
              (iar--reqlog-last-tokens-out 1200))
          (with-current-buffer buf (erase-buffer) (insert (make-string 100 ?x)))
          (cl-letf (((symbol-function 'gptel-send)
                     (lambda () (cl-incf sent))))
            (with-current-buffer buf
              (let ((start (point)))
                (insert "cycle done, record written\nCYCLE_COMPLETE\n")
                (iar--cycle-post-response-handler start (point)))))
          (should (plist-get iar--cycle-state :completed))
          (should (= 0 (plist-get iar--cycle-state :exit-code)))
          (should (= 0 sent)))
      (kill-buffer buf))))

(ert-deftest test-empty-response-with-tool-calls-not-anomalous ()
  "A response region containing tool-call spans (tokens_out > 0) is
normal work, not the 0/0 shape. The detector reads the reqlog state,
which carries the real token count; this test pins that a tool-heavy
response never trips the empty guard."
  (let ((iar--reqlog-last-stop "stop")
        (iar--reqlog-last-tokens-out 900))
    (should-not (iar--cycle-empty-response-p))))

(ert-deftest test-empty-response-failed-request-path-unchanged ()
  "The failed-request path (start == end) keeps its strike logic -- the
0/0 guard must not intercept it (a failed request has no PARSE data;
reqlog state is nil here)."
  (let ((buf (get-buffer-create "*test-empty-resp3*"))
        (sent 0))
    (unwind-protect
        (let ((iar-cycle-context-limit-chars 100000)
              (iar--cycle-state (iar--cycle-make-state "test" buf "Continue." 40))
              (iar--one-shot-state nil)
              (iar--cycle-error-strikes 0)
              (iar--reqlog-last-stop nil)
              (iar--reqlog-last-tokens-out nil))
          (with-current-buffer buf (erase-buffer) (insert (make-string 100 ?x)))
          (cl-letf (((symbol-function 'gptel-send)
                     (lambda () (cl-incf sent))))
            (with-current-buffer buf
              (let ((start (point)))
                (iar--cycle-post-response-handler start start))))  ; start == end: FAILED
          ;; Strike counted, not completed (1 strike < 3).
          (should (= 1 iar--cycle-error-strikes))
          (should-not (plist-get iar--cycle-state :completed)))
      (kill-buffer buf))))