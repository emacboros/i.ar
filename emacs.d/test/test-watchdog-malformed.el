;; -*- lexical-binding: t; -*-

;;; Tests for Track A1 (request watchdog) and Track A2 (malformed-args)
;; Pure-function tests: no live processes, no timers, no network.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)

(require 'iar-request-watchdog)
(require 'iar-malformed-args)
(require 'gptel)

;;; --- A1: stall decision (pure) ---

(ert-deftest test-watchdog-stall-healthy ()
  "Recent activity -> no stall reason."
  (let ((iar-request-watchdog-enabled t)
        (iar-request-idle-timeout 180)
        (iar-request-total-timeout 900))
    (should (null (iar--watchdog-stall-reason
                   (cons (current-time) (current-time)))))))

(ert-deftest test-watchdog-stall-idle-exceeded ()
  "Last activity older than idle timeout -> stall reason mentions it."
  (let ((iar-request-watchdog-enabled t)
        (iar-request-idle-timeout 180)
        (iar-request-total-timeout 900)
        (old (time-subtract nil (* 200 60))))  ; 200 minutes ago
    (let ((reason (iar--watchdog-stall-reason (cons old old))))
      (should reason)
      (should (string-match-p "stalled stream" reason)))))

(ert-deftest test-watchdog-stall-total-exceeded-no-data ()
  "No activity ever + started older than total timeout -> stall reason."
  (let ((iar-request-watchdog-enabled t)
        (iar-request-idle-timeout 180)
        (iar-request-total-timeout 900)
        (old (time-subtract nil (* 1000 60))))  ; 1000 minutes ago
    (let ((reason (iar--watchdog-stall-reason (cons old nil))))
      (should reason)
      (should (string-match-p "no response data" reason)))))

(ert-deftest test-watchdog-stall-disabled ()
  "Watchdog disabled -> never stalls, even for ancient entries."
  (let ((iar-request-watchdog-enabled nil)
        (old (time-subtract nil (* 10000 60))))
    (should (null (iar--watchdog-stall-reason (cons old old))))))

(ert-deftest test-watchdog-stall-timeouts-nil ()
  "Timeouts nil -> corresponding checks disabled."
  (let ((iar-request-watchdog-enabled t)
        (iar-request-idle-timeout nil)
        (iar-request-total-timeout nil)
        (old (time-subtract nil (* 10000 60))))
    ;; both nil: nothing can stall
    (should (null (iar--watchdog-stall-reason (cons old old))))
    ;; idle nil but total set: no-data entry still stalls on total
    (let ((iar-request-total-timeout 900))
      (should (string-match-p
               "no response data"
               (iar--watchdog-stall-reason (cons old nil)))))))

(ert-deftest test-watchdog-stall-idle-fresh-total-old ()
  "Recent activity but ancient start -> healthy (idle resets the clock)."
  (let ((iar-request-watchdog-enabled t)
        (iar-request-idle-timeout 180)
        (iar-request-total-timeout 900)
        (ancient (time-subtract nil (* 10000 60))))
    ;; total check only applies when last-activity is nil
    (should (null (iar--watchdog-stall-reason
                   (cons ancient (current-time)))))))

;;; --- A1: tracking (hash table, no live processes) ---

(ert-deftest test-watchdog-track-idempotent ()
  "iar--watchdog-track is idempotent: second call keeps first STARTED."
  (let* ((fake (list :fake-process))
         (entry-count-before (hash-table-count iar--watchdog-processes)))
    (unwind-protect
        (progn
          (iar--watchdog-track fake)
          (let ((first-started (car (gethash fake iar--watchdog-processes))))
            (should first-started)
            (iar--watchdog-track fake)
            ;; STARTED unchanged, single entry
            (should (eq first-started
                        (car (gethash fake iar--watchdog-processes))))
            ;; activity updates LAST-ACTIVITY only
            (iar--watchdog-activity fake)
            (should (eq first-started
                        (car (gethash fake iar--watchdog-processes))))
            (should (cdr (gethash fake iar--watchdog-processes)))))
      (remhash fake iar--watchdog-processes)
      (should (eq entry-count-before
                  (hash-table-count iar--watchdog-processes))))))

(ert-deftest test-malformed-arity-feedback ()
  "Arity errors produce the 'wrong number of arguments' message."
  (let ((msg (iar--malformed-feedback
              "read_file" "path:string" '(wrong-number-of-arguments nil 3)
              '("/tmp" "extra"))))
    (should (string-match-p "<tool_call_error>" msg))
    (should (string-match-p "wrong number of arguments" msg))
    (should (string-match-p "path:string" msg))
    (should (string-match-p "read_file" msg))))

(ert-deftest test-malformed-type-feedback ()
  "Type errors produce spec + received + error message."
  (let ((msg (iar--malformed-feedback
              "read_file" "path:string"
              '(wrong-type-argument stringp 123) '(123))))
    (should (string-match-p "<tool_call_error>" msg))
    (should (string-match-p "path:string" msg))
    (should (string-match-p "integer 123" msg))
    (should (string-match-p "stringp" msg))))

(ert-deftest test-malformed-describe-value ()
  "Value rendering: type name + truncated repr."
  (should (string-match-p "string" (iar--describe-value "hello")))
  (should (string-match-p "integer 42" (iar--describe-value 42)))
  ;; long values are truncated, not dumped in full
  (let ((long (make-string 500 ?x)))
    (should (< (length (iar--describe-value long)) 200))))

;;; --- A2: wrapping (real tool objects, no dispatch) ---

(ert-deftest test-malformed-wrap-sync-tool ()
  "Wrapped sync tool returns structured feedback on bad args."
  (let* ((tool (gptel-make-tool
                :name "test_wrap_sync"
                :description "test"
                :args (list '(:name "path" :type "string"))
                :function (lambda (path)
                            ;; signals on non-string like a real tool would
                            (unless (stringp path)
                              (signal 'wrong-type-argument
                                      (list 'stringp path)))
                            (format "contents of %s" path))))
         (wrapped (iar--maybe-wrap-tool tool)))
    (should (not (eq tool wrapped)))  ; a copy was made
    (should (string= (gptel-tool-name wrapped) "test_wrap_sync"))
    ;; good args still work
    (should (string= "contents of /tmp"
                     (funcall (gptel-tool-function wrapped) "/tmp")))
    ;; bad args: structured feedback, not a raw signal
    (let ((result (funcall (gptel-tool-function wrapped) 123)))
      (should (stringp result))
      (should (string-match-p "<tool_call_error>" result))
      (should (string-match-p "path:string" result)))))

(ert-deftest test-malformed-wrap-async-tool ()
  "Wrapped async tool calls callback with feedback on bad args."
  (let* ((captured nil)
         (tool (gptel-make-tool
                :name "test_wrap_async"
                :description "test"
                :args (list '(:name "command" :type "string"))
                :async t
                :function (lambda (callback command)
                            (condition-case err
                                (progn (stringp command)
                                       (funcall callback "ok"))
                              (error (funcall callback
                                              (format "Error: %s"
                                                      (error-message-string err))))))))
         (wrapped (iar--maybe-wrap-tool tool))
         (fn (gptel-tool-function wrapped)))
    ;; good path: callback gets "ok"
    (setq captured nil)
    (funcall (lambda (cb &rest args) (apply fn cb args))
             (lambda (r) (setq captured r)) "echo hi")
    (should (equal "ok" captured))
    ;; the async wrapper catches signals from the function itself
    (setq captured nil)
    (cl-letf (((symbol-function 'gptel-tool-async) (lambda (&rest _) t)))
      (funcall fn (lambda (r) (setq captured r)) 123))
    (should (and captured (stringp captured)))))

(ert-deftest test-malformed-wrap-disabled ()
  "Feedback disabled -> tool passes through unwrapped."
  (let ((iar-malformed-args-feedback nil)
        (tool (gptel-make-tool
               :name "test_wrap_off"
               :description "test"
               :args (list)
               :function #'identity)))
    (should (eq tool (iar--maybe-wrap-tool tool)))))

(ert-deftest test-malformed-wrap-preserves-slots ()
  "The wrapped copy preserves name, description, args, async."
  (let* ((tool (gptel-make-tool
                :name "test_wrap_slots"
                :description "the description"
                :args (list '(:name "a" :type "string")
                            '(:name "b" :type "integer"))
                :function (lambda (a b) (+ (length a) b))))
         (wrapped (iar--maybe-wrap-tool tool)))
    (should (string= "test_wrap_slots" (gptel-tool-name wrapped)))
    (should (string= "the description" (gptel-tool-description wrapped)))
    (should (equal (gptel-tool-args tool) (gptel-tool-args wrapped)))
    (should (eq (gptel-tool-async tool) (gptel-tool-async wrapped)))
    ;; and it works
    (should (= 5 (funcall (gptel-tool-function wrapped) "hello" 0)))))

(ert-deftest test-malformed-register-wraps ()
  "iar-tool-register (redefined by A2 module) registers a wrapped tool."
  (let ((gptel-tools nil))
    (let ((orig (gptel-make-tool
                 :name "test_reg_wrap"
                 :description "test"
                 :args (list '(:name "x" :type "string"))
                 :function (lambda (x)
                             (unless (stringp x)
                               (signal 'wrong-type-argument
                                       (list 'stringp x)))
                             x))))
      (iar-tool-register orig)
      ;; the REGISTERED tool (in gptel-tools) is the wrapped copy
      (let ((registered (car gptel-tools)))
        (should (gptel-tool-p registered))
        (should (string= "test_reg_wrap" (gptel-tool-name registered)))
        ;; its function is a wrapper: bad arg -> structured feedback
        (should (string-match-p
                 "<tool_call_error>"
                 (funcall (gptel-tool-function registered) :wrong)))
        ;; the original object was NOT registered unwrapped
        (should (not (eq orig registered)))))))

(provide 'test-watchdog-malformed)