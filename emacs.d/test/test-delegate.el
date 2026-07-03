;; -*- lexical-binding: t; -*-

;;; Tests for delegate_tool.el
;; Tests depth tracking, path traversal protection, validation,
;; timeout edge cases, timeout handler, stream function, completion hook,
;; and depth limit enforcement. Full delegation tests that spawn gptel
;; sessions would require a running Ollama backend.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'delegate_tool)

;;; --- Validation tests ---

(ert-deftest test-delegate-validates-agent-name ()
  "delegate tool should reject empty or whitespace-only agent names."
  (let ((result nil))
    (my-gptel-tool-delegate (lambda (r) (setq result r)) "" "task" "context")
    (should result)
    (should (string-match-p "agent" result))))

(ert-deftest test-delegate-validates-task ()
  "delegate tool should reject empty or whitespace-only task strings."
  (let ((result nil))
    (my-gptel-tool-delegate (lambda (r) (setq result r)) "coder" "" "context")
    (should result)
    (should (string-match-p "task" result))))

(ert-deftest test-delegate-validates-agent-name-traversal ()
  "delegate tool should reject agent names with path traversal characters.
The error from my-gptel--load-agent-profile propagates through the callback."
  (dolist (bad-name '("../etc" "foo/bar" "foo;bar" "foo bar"))
    (condition-case err
        (my-gptel-tool-delegate (lambda (_r)) bad-name "task" "ctx")
      (error
       (should (string-match-p "Invalid agent name"
                               (error-message-string err))))
      (:success
       (ert-fail (format "Expected error for agent name: %s" bad-name))))))

;;; --- Depth tracking tests ---

(ert-deftest test-delegate-max-depth-constant ()
  "my-gptel--delegate-max-depth should be 3."
  (should (= my-gptel--delegate-max-depth 3)))

(ert-deftest test-delegate-depth-default ()
  "my-gptel--delegate-depth should default to 0 in a fresh buffer."
  (with-temp-buffer
    (should (= (or (and (boundp 'my-gptel--delegate-depth)
                        my-gptel--delegate-depth)
                   0)
               0))))

(ert-deftest test-delegate-depth-buffer-local ()
  "my-gptel--delegate-depth should be buffer-local."
  (with-temp-buffer
    (setq-local my-gptel--delegate-depth 2)
    (should (= my-gptel--delegate-depth 2))
    (with-temp-buffer
      (should (= (or (and (boundp 'my-gptel--delegate-depth)
                          my-gptel--delegate-depth)
                     0)
                 0)))))

;;; --- Profile loading tests ---

(ert-deftest test-delegate-load-profile-validates-name ()
  "my-gptel--load-agent-profile should reject path traversal in agent name."
  (condition-case err
      (my-gptel--load-agent-profile "../../etc/passwd")
    (error
     (should (string-match-p "Invalid agent name" (error-message-string err))))
    (:success
     (ert-fail "Expected error for path traversal"))))

(ert-deftest test-delegate-load-profile-finds-real-agent ()
  "my-gptel--load-agent-profile should load a real agent profile."
  (let ((profile (my-gptel--load-agent-profile "mccarthy")))
    (should (stringp profile))
    (should (string-match-p "McCarthy" profile))))

(ert-deftest test-delegate-load-profile-returns-nil-for-missing ()
  "my-gptel--load-agent-profile should return nil for nonexistent agent."
  (should (null (my-gptel--load-agent-profile "nonexistent_xyzzy_agent"))))

;;; --- Timeout parsing tests ---

(ert-deftest test-delegate-timeout-integer ()
  "delegate tool should accept integer timeout and pass it to spawn."
  (let ((captured-timeout nil))
    (cl-letf (((symbol-function 'my-gptel--spawn-async-delegate)
               (lambda (_cb _agent _task _ctx timeout-secs _profile)
                 (setq captured-timeout timeout-secs))))
      (my-gptel-tool-delegate (lambda (_r)) "mccarthy" "task" "ctx" 30))
    (should (= captured-timeout 30))))

(ert-deftest test-delegate-timeout-string-converted ()
  "delegate tool should convert string timeout to integer."
  (let ((captured-timeout nil))
    (cl-letf (((symbol-function 'my-gptel--spawn-async-delegate)
               (lambda (_cb _agent _task _ctx timeout-secs _profile)
                 (setq captured-timeout timeout-secs))))
      (my-gptel-tool-delegate (lambda (_r)) "mccarthy" "task" "ctx" "30"))
    (should (= captured-timeout 30))))

(ert-deftest test-delegate-timeout-default-when-nil ()
  "delegate tool should default timeout to 600 when nil."
  (let ((captured-timeout nil))
    (cl-letf (((symbol-function 'my-gptel--spawn-async-delegate)
               (lambda (_cb _agent _task _ctx timeout-secs _profile)
                 (setq captured-timeout timeout-secs))))
      (my-gptel-tool-delegate (lambda (_r)) "mccarthy" "task" "ctx" nil))
    (should (= captured-timeout 600))))

;;; --- Timeout edge case tests ---
;; These tests mock my-gptel--spawn-async-delegate to capture the
;; actual timeout value after parsing and clamping, verifying the
;; clamping behavior rather than just that the function doesn't crash.

(ert-deftest test-delegate-timeout-negative-clamped-to-1 ()
  "delegate tool should clamp negative timeout to 1 second."
  (let ((captured-timeout nil))
    (cl-letf (((symbol-function 'my-gptel--spawn-async-delegate)
               (lambda (_cb _agent _task _ctx timeout-secs _profile)
                 (setq captured-timeout timeout-secs))))
      (my-gptel-tool-delegate (lambda (_r)) "mccarthy" "task" "ctx" -5))
    (should (= captured-timeout 1))))

(ert-deftest test-delegate-timeout-zero-clamped-to-1 ()
  "delegate tool should clamp zero timeout to 1 second."
  (let ((captured-timeout nil))
    (cl-letf (((symbol-function 'my-gptel--spawn-async-delegate)
               (lambda (_cb _agent _task _ctx timeout-secs _profile)
                 (setq captured-timeout timeout-secs))))
      (my-gptel-tool-delegate (lambda (_r)) "mccarthy" "task" "ctx" 0))
    (should (= captured-timeout 1))))

(ert-deftest test-delegate-timeout-float-floored ()
  "delegate tool should floor float timeout to integer."
  (let ((captured-timeout nil))
    (cl-letf (((symbol-function 'my-gptel--spawn-async-delegate)
               (lambda (_cb _agent _task _ctx timeout-secs _profile)
                 (setq captured-timeout timeout-secs))))
      (my-gptel-tool-delegate (lambda (_r)) "mccarthy" "task" "ctx" 30.7))
    (should (= captured-timeout 30))))

;;; --- Timeout handler tests ---

(ert-deftest test-delegate-timeout-handler-dead-buffer ()
  "Timeout handler should call callback when buffer is dead and not completed."
  (let ((result nil)
        (dead-buf (generate-new-buffer "test-dead")))
    (kill-buffer dead-buf)
    (my-gptel--delegate-timeout-handler
     dead-buf (lambda (r) (setq result r)) "testagent" nil 0 30)
    (should result)
    (should (string-match-p "killed before completion" result))))

(ert-deftest test-delegate-timeout-handler-already-completed ()
  "Timeout handler should do nothing when already completed."
  (let ((result nil)
        (buf (generate-new-buffer "test-completed")))
    (unwind-protect
         (progn
           (my-gptel--delegate-timeout-handler
            buf (lambda (r) (setq result r)) "testagent" t 0 30)
           (should (null result)))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;;; --- Stream function tests ---

(defun test-delegate--setup-stream-buffers ()
  "Create parent and delegate buffers with stream tracking symbols.
Returns a plist: (:parent-buf :delegate-buf :stream-fn)."
  (let ((parent-buf (generate-new-buffer "test-parent"))
        (delegate-buf (generate-new-buffer "test-delegate"))
        (stream-marker-sym (make-symbol "stream-marker"))
        (stream-pos-sym (make-symbol "stream-pos")))
    (set stream-marker-sym nil)
    (with-current-buffer parent-buf
      (insert "Parent buffer start.\n")
      (let ((parent-marker (point-marker)))
        (with-current-buffer delegate-buf
          (insert "PROMPT TEXT\n")
          (set stream-pos-sym (point-marker)))
        (let ((stream-fn (my-gptel--delegate-stream-fn
                          parent-buf parent-marker "testagent"
                          stream-marker-sym stream-pos-sym)))
          (list :parent-buf parent-buf
                :delegate-buf delegate-buf
                :stream-fn stream-fn))))))

(ert-deftest test-delegate-stream-fn-mirrors-to-parent ()
  "Stream function should mirror new text to the parent buffer."
  (let ((fixture (test-delegate--setup-stream-buffers)))
    (unwind-protect
         (progn
           (with-current-buffer (plist-get fixture :delegate-buf)
             (goto-char (point-max))
             (insert "streamed response text\n")
             (funcall (plist-get fixture :stream-fn)))
           (with-current-buffer (plist-get fixture :parent-buf)
             (should (string-match-p "streamed response text" (buffer-string)))
             (should (string-match-p "Delegate 'testagent' streaming" (buffer-string)))))
      (when (buffer-live-p (plist-get fixture :parent-buf))
        (kill-buffer (plist-get fixture :parent-buf)))
      (when (buffer-live-p (plist-get fixture :delegate-buf))
        (kill-buffer (plist-get fixture :delegate-buf))))))

(ert-deftest test-delegate-stream-fn-no-new-text ()
  "Stream function should do nothing when there is no new text."
  (let ((fixture (test-delegate--setup-stream-buffers)))
    (unwind-protect
         (progn
           (with-current-buffer (plist-get fixture :delegate-buf)
             (funcall (plist-get fixture :stream-fn)))
           (with-current-buffer (plist-get fixture :parent-buf)
             (should-not (string-match-p "streaming" (buffer-string)))))
      (when (buffer-live-p (plist-get fixture :parent-buf))
        (kill-buffer (plist-get fixture :parent-buf)))
      (when (buffer-live-p (plist-get fixture :delegate-buf))
        (kill-buffer (plist-get fixture :delegate-buf))))))

;;; --- Completion hook tests ---

(ert-deftest test-delegate-completion-hook-sets-response ()
  "Completion hook should call callback with response when tools were called."
  (with-temp-buffer
    (insert "prefix\nresponse text here\n")
    (let ((result nil)
          (completed-sym (make-symbol "completed"))
          (timer-sym (make-symbol "timer"))
          (tools-called-sym (make-symbol "tools-called"))
          (turn-count-sym (make-symbol "turn-count")))
      (set completed-sym nil)
      (set timer-sym nil)
      (set tools-called-sym t)
      (set turn-count-sym 0)
      (let ((fn (my-gptel--delegate-completion-fn
                 (current-buffer)
                 (lambda (r) (setq result r))
                 "testagent"
                 completed-sym timer-sym 600
                 tools-called-sym turn-count-sym
                 my-gptel--delegate-max-turns)))
        (funcall fn 8 (point-max)))
      (should result)
      (should (string-match-p "response text" result))
      (should (symbol-value completed-sym)))))

(ert-deftest test-delegate-completion-hook-reprompts-without-tools ()
  "Completion hook should re-prompt when no tools were called."
  (with-temp-buffer
    (insert "prefix\nI will review the code now.\n")
    (let ((result nil)
          (completed-sym (make-symbol "completed"))
          (timer-sym (make-symbol "timer"))
          (tools-called-sym (make-symbol "tools-called"))
          (turn-count-sym (make-symbol "turn-count")))
      (set completed-sym nil)
      (set timer-sym nil)
      (set tools-called-sym nil)
      (set turn-count-sym 0)
      (let ((fn (my-gptel--delegate-completion-fn
                 (current-buffer)
                 (lambda (r) (setq result r))
                 "testagent"
                 completed-sym timer-sym 600
                 tools-called-sym turn-count-sym
                 my-gptel--delegate-max-turns)))
        (funcall fn 8 (point-max)))
      (should (null result))
      (should (null (symbol-value completed-sym)))
      (should (= (symbol-value turn-count-sym) 1)))))

(ert-deftest test-delegate-completion-hook-max-turns-returns-response ()
  "Completion hook should return response when max turns reached without tools."
  (with-temp-buffer
    (insert "prefix\ntext only response\n")
    (let ((result nil)
          (completed-sym (make-symbol "completed"))
          (timer-sym (make-symbol "timer"))
          (tools-called-sym (make-symbol "tools-called"))
          (turn-count-sym (make-symbol "turn-count")))
      (set completed-sym nil)
      (set timer-sym nil)
      (set tools-called-sym nil)
      (set turn-count-sym 15)
      (let ((fn (my-gptel--delegate-completion-fn
                 (current-buffer)
                 (lambda (r) (setq result r))
                 "testagent"
                 completed-sym timer-sym 600
                 tools-called-sym turn-count-sym 15)))
        (funcall fn 8 (point-max)))
      (should result)
      (should (string-match-p "max text-only turns" result))
      (should (symbol-value completed-sym)))))

(ert-deftest test-delegate-completion-hook-empty-response-with-tools ()
  "Completion hook should handle empty response even when tools were called."
  (with-temp-buffer
    (insert "prefix\n\n")
    (let ((result nil)
          (completed-sym (make-symbol "completed"))
          (timer-sym (make-symbol "timer"))
          (tools-called-sym (make-symbol "tools-called"))
          (turn-count-sym (make-symbol "turn-count")))
      (set completed-sym nil)
      (set timer-sym nil)
      (set tools-called-sym t)
      (set turn-count-sym 0)
      (let ((fn (my-gptel--delegate-completion-fn
                 (current-buffer)
                 (lambda (r) (setq result r))
                 "testagent"
                 completed-sym timer-sym 600
                 tools-called-sym turn-count-sym
                 my-gptel--delegate-max-turns)))
        (funcall fn 8 8))
      (should result)
      (should (string-match-p "empty response" result))
      (should (symbol-value completed-sym)))))

(ert-deftest test-delegate-completion-hook-already-completed ()
  "Completion hook should do nothing if already completed."
  (with-temp-buffer
    (insert "prefix\nsome response\n")
    (let ((result nil)
          (completed-sym (make-symbol "completed"))
          (timer-sym (make-symbol "timer"))
          (tools-called-sym (make-symbol "tools-called"))
          (turn-count-sym (make-symbol "turn-count")))
      (set completed-sym t)
      (set timer-sym nil)
      (set tools-called-sym t)
      (set turn-count-sym 0)
      (let ((fn (my-gptel--delegate-completion-fn
                 (current-buffer)
                 (lambda (r) (setq result r))
                 "testagent"
                 completed-sym timer-sym 600
                 tools-called-sym turn-count-sym
                 my-gptel--delegate-max-turns)))
        (funcall fn 8 (point-max)))
      (should (null result)))))

(provide 'test-delegate)