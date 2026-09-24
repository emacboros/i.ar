;; -*- lexical-binding: t; -*-

;;; Tests for the c323 fix: A-FAILED-REQUEST-IS-AN-EMPTY-REGION-UNTIL-PROVEN.
;;;
;;; Live-fire evidence (aria c322, req 260924185718-159, 2026-09-24
;;; 19:12Z): a thinking-only final response (HTTP 200, stop=stop,
;;; tokens_out=626, zero tool calls, zero model text -- all 626 tokens
;;; were reasoning in gptel `ignore' spans) produces start==end at the
;;; model-text level, exactly the gptel failed-request signal. The old
;;; handler counted a strike, the dead-cycle guard ended the cycle
;;; exit 1 AFTER the work had landed -- a clean close misfiled as a
;;; death. The reqlog already witnesses the truth (status=200,
;;; stop=stop, tokens_out>0, tools=0); the handler now consults it on
;;; the start==end path.
;;;
;;; Classification (start == end):
;;;   reqlog says stop=stop, tokens_out > 0  -> thinking-only END:
;;;     the model finished and said nothing. One re-prompt with the
;;;     close demand; second fire = tombstone exit 1 (the model is
;;;     looping in reasoning; a second re-prompt would burn the same
;;;     budget -- the thinking-loop-truncation lesson).
;;;   reqlog says stop=stop, tokens_out = 0  -> the 0/0 shape:
;;;     tombstone immediately (aria-0026 contract, unchanged).
;;;   anything else (nil data, stop=length, error data) -> FAILED
;;;     request: strike, transient retry, dead-cycle guard (unchanged).

(require 'ert)
(require 'cl-lib)

(require 'iar-request-log)
(require 'iar-agent-cycle)

;;; --- the detector ---

(ert-deftest test-thinking-only-failed-req-detector-200-stop-real-tokens ()
  "stop=stop with tokens_out > 0 on a start==end region: the
thinking-only-end shape (c322 live fire, 626 tokens)."
  (let ((iar--reqlog-last-stop "stop")
        (iar--reqlog-last-tokens-out 626))
    (should (iar--cycle-thinking-only-end-p))))

(ert-deftest test-thinking-only-failed-req-detector-zero-tokens-not-this-shape ()
  "stop=stop with tokens_out=0 is the 0/0 tombstone shape, NOT the
thinking-only-end shape -- the two must stay disjoint."
  (let ((iar--reqlog-last-stop "stop")
        (iar--reqlog-last-tokens-out 0))
    (should-not (iar--cycle-thinking-only-end-p))))

(ert-deftest test-thinking-only-failed-req-detector-nil-data-not-this-shape ()
  "nil reqlog data (no witness): never classify as thinking-only-end.
Absence of evidence is not evidence -- the failed-request path keeps
its teeth on missing data (the c80 inference lesson)."
  (let ((iar--reqlog-last-stop nil)
        (iar--reqlog-last-tokens-out nil))
    (should-not (iar--cycle-thinking-only-end-p))))

(ert-deftest test-thinking-only-failed-req-detector-length-stop-not-this-shape ()
  "stop=length is the truncated-output guard's shape, not this one."
  (let ((iar--reqlog-last-stop "length")
        (iar--reqlog-last-tokens-out 65536))
    (should-not (iar--cycle-thinking-only-end-p))))

(ert-deftest test-thinking-only-failed-req-detector-error-stop-not-this-shape ()
  "stop=error is a real failure, not a thinking-only end."
  (let ((iar--reqlog-last-stop "error")
        (iar--reqlog-last-tokens-out 100))
    (should-not (iar--cycle-thinking-only-end-p))))

;;; --- handler-level behavior ---

(ert-deftest test-thinking-only-end-reprompts-once-then-tombstones ()
  "A thinking-only end (start==end, stop=stop, tokens_out>0): first
fire re-prompts with the close demand, no strike counted; second fire
tombstones exit 1. The model finished and said nothing -- the c322
shape, where the work had already landed and the close was misfiled
as a transport death."
  (let ((buf (get-buffer-create "*test-thinkonly1*"))
        (sent 0)
        (tombstoned 0))
    (unwind-protect
        (let ((iar-cycle-context-limit-chars 100000)
              (iar--cycle-state (iar--cycle-make-state "test" buf "Continue." 40))
              (iar--one-shot-state nil)
              (iar--cycle-error-strikes 0)
              (iar--cycle-retry-count 0)
              (iar--cycle-thinking-only-reprompted nil)
              (iar--reqlog-last-stop "stop")
              (iar--reqlog-last-tokens-out 626)
              (gptel--request-alist nil))
          (with-current-buffer buf (erase-buffer) (insert (make-string 100 ?x)))
          (cl-letf (((symbol-function 'gptel-send)
                     (lambda () (cl-incf sent)))
                    ((symbol-function 'iar--cycle-tombstone)
                     (lambda (_agent _secs) (cl-incf tombstoned) t)))
            (with-current-buffer buf
              ;; First fire: re-prompt, cycle not complete. The strike
              ;; IS counted (an empty region is an anomaly worth
              ;; witnessing) but the branch fires via the one-shot flag.
              (let ((start (point)))
                (iar--cycle-post-response-handler start start))
              (should (= 1 iar--cycle-error-strikes))
              (should (= 1 sent))
              (should-not (plist-get iar--cycle-state :completed))
              ;; Second fire: tombstone, exit 1.
              (let ((start (point)))
                (iar--cycle-post-response-handler start start))
              (should (= 1 tombstoned))
              (should (plist-get iar--cycle-state :completed))
              (should (= 1 (plist-get iar--cycle-state :exit-code))))))
      (kill-buffer buf))))

(ert-deftest test-thinking-only-end-completing-response-still-closes ()
  "A thinking-only end whose region (before the re-prompt fires)
carries a sentinel in model text must still close normally -- the
re-prompt branch is ordered AFTER the sentinel branch in the success
path, but the failed path must not shadow a real close either. Here:
the reqlog says thinking-only-end, and the region is empty, so the
re-prompt fires; the re-prompted turn then closes via the sentinel."
  (let ((buf (get-buffer-create "*test-thinkonly2*"))
        (sent 0))
    (unwind-protect
        (let ((iar-cycle-context-limit-chars 100000)
              (iar--cycle-state (iar--cycle-make-state "test" buf "Continue." 40))
              (iar--one-shot-state nil)
              (iar--cycle-error-strikes 0)
              (iar--cycle-retry-count 0)
              (iar--cycle-thinking-only-reprompted nil)
              (iar--reqlog-last-stop "stop")
              (iar--reqlog-last-tokens-out 626)
              (gptel--request-alist nil))
          (with-current-buffer buf (erase-buffer) (insert (make-string 100 ?x)))
          (cl-letf (((symbol-function 'gptel-send)
                     (lambda () (cl-incf sent))))
            (with-current-buffer buf
              ;; Thinking-only end: re-prompt fires.
              (let ((start (point)))
                (iar--cycle-post-response-handler start start))
              (should (= 1 sent))
              ;; The re-prompted turn lands a real close.
              (let ((start (point)))
                (insert "record written\nCYCLE_COMPLETE\n")
                (iar--cycle-post-response-handler start (point)))
              (should (plist-get iar--cycle-state :completed))
              (should (= 0 (plist-get iar--cycle-state :exit-code))))))
      (kill-buffer buf))))

(ert-deftest test-thinking-only-end-real-failure-still-strikes ()
  "A REAL failed request (no reqlog witness -- the transport died
before any data arrived) still counts its strike and hits the
dead-cycle guard. The fix must not disarm the original guard."
  (let ((buf (get-buffer-create "*test-thinkonly3*"))
        (sent 0))
    (unwind-protect
        (let ((iar-cycle-context-limit-chars 100000)
              (iar--cycle-state (iar--cycle-make-state "test" buf "Continue." 40))
              (iar--one-shot-state nil)
              (iar--cycle-error-strikes 0)
              (iar--cycle-retry-count 0)
              (iar--cycle-thinking-only-reprompted nil)
              (iar--reqlog-last-stop nil)
              (iar--reqlog-last-tokens-out nil)
              (gptel--request-alist nil))
          (with-current-buffer buf (erase-buffer) (insert (make-string 100 ?x)))
          (cl-letf (((symbol-function 'gptel-send)
                     (lambda () (cl-incf sent))))
            (with-current-buffer buf
              (let ((start (point)))
                (iar--cycle-post-response-handler start start))))
          (should (= 1 iar--cycle-error-strikes))
          (should (plist-get iar--cycle-state :completed))
          (should (= 1 (plist-get iar--cycle-state :exit-code)))
          (should (= 0 sent)))
      (kill-buffer buf))))

(ert-deftest test-thinking-only-end-strike-counter-reset-on-success ()
  "A successful turn after a thinking-only re-prompt resets the
one-shot re-prompt budget (the flag is per-consecutive, like the
strike counter)."
  (let ((buf (get-buffer-create "*test-thinkonly4*"))
        (sent 0))
    (unwind-protect
        (let ((iar-cycle-context-limit-chars 100000)
              (iar--cycle-state (iar--cycle-make-state "test" buf "Continue." 40))
              (iar--one-shot-state nil)
              (iar--cycle-error-strikes 0)
              (iar--cycle-retry-count 0)
              (iar--cycle-thinking-only-reprompted t)  ; stale from earlier
              (iar--reqlog-last-stop "stop")
              (iar--reqlog-last-tokens-out 800)
              (gptel--request-alist nil))
          (with-current-buffer buf (erase-buffer) (insert (make-string 100 ?x)))
          (cl-letf (((symbol-function 'gptel-send)
                     (lambda () (cl-incf sent))))
            (with-current-buffer buf
              (let ((start (point)))
                (insert "working on it\n")
                (iar--cycle-post-response-handler start (point)))))
          ;; Success path ran: flag cleared.
          (should-not iar--cycle-thinking-only-reprompted)
          (should (= 0 iar--cycle-error-strikes)))
      (kill-buffer buf))))

(ert-deftest test-thinking-only-end-transient-retry-preferred-when-error-data ()
  "If the FSM carries TRANSIENT error data (5xx), the retry branch
keeps priority over the thinking-only-end branch -- a 502 with a
partial parse must retry, not re-prompt. Ordering: transient-retry
branch is checked BEFORE the thinking-only-end branch inside the
failed path."
  (let ((buf (get-buffer-create "*test-thinkonly5*"))
        (sent 0))
    (unwind-protect
        (let ((iar-cycle-context-limit-chars 100000)
              (iar--cycle-state (iar--cycle-make-state "test" buf "Continue." 40))
              (iar--one-shot-state nil)
              (iar--cycle-error-strikes 0)
              (iar--cycle-retry-count 0)
              (iar--cycle-thinking-only-reprompted nil)
              (iar--reqlog-last-stop "stop")
              (iar--reqlog-last-tokens-out 626)
              (gptel--request-alist nil))
          (with-current-buffer buf (erase-buffer) (insert (make-string 100 ?x)))
          (cl-letf (((symbol-function 'gptel-send)
                     (lambda () (cl-incf sent)))
                    ((symbol-function 'iar--request-transient-error-p)
                     (lambda () t)))
            (with-current-buffer buf
              (let ((start (point)))
                (iar--cycle-post-response-handler start start))))
          ;; Retry branch fired (backoff sleep + re-send), not the
          ;; thinking-only re-prompt.
          (should (= 1 iar--cycle-retry-count))
          (should (= 1 sent))
          (should (= 1 iar--cycle-error-strikes)))
      (kill-buffer buf))))