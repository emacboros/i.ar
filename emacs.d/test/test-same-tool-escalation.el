;;; test-same-tool-escalation.el --- 0117 ask 1: same-tool second threshold blocks the tool for the cycle -*- lexical-binding: t; -*-

(require 'ert)
(require 'iar-agent-cycle)

(ert-deftest test-same-tool-escalation-threshold-exists ()
  "The second threshold is defined and above the warn threshold."
  (should (boundp 'iar-cycle-same-tool-block))
  (should (integerp iar-cycle-same-tool-block))
  (should (> iar-cycle-same-tool-block iar-cycle-same-tool-warn)))

(ert-deftest test-same-tool-escalation-fires-block ()
  "At the block threshold, the tool is blocked for the cycle
(memory tools exempt) and the state records the escalation."
  (let ((iar-cycle-same-tool-warn 5)
        (iar-cycle-same-tool-block 8)
        (state (list :same-tool-warned t :same-tool-blocked nil
                     :cap-blocks 0 :cap-warned nil))
        (iar--fence-state-writeback (lambda (_state) nil))
        calls)
    (cl-letf (((symbol-function 'iar--fence-state-writeback)
               (lambda (st) (push st calls))))
      ;; simulate: 8th execute_code_local call this run
      (let ((result (iar--cycle-same-tool-escalation-p
                     "execute_code_local" 8 state)))
        (should (plist-get result :block))
        (should (string-match-p "blocked for the rest of this cycle"
                                (plist-get result :block)))
        (should (plist-get state :same-tool-blocked))))
    (should calls)))

(ert-deftest test-same-tool-escalation-memory-tools-exempt ()
  "Memory/record tools are never blocked by the escalation."
  (let ((iar-cycle-same-tool-warn 2)
        (iar-cycle-same-tool-block 3)
        (state (list :same-tool-warned t :same-tool-blocked nil)))
    (dolist (tool '("append_file" "write_file" "write_subtask"
                    "write_roadmap" "git_commit" "send_telegram"))
      (should-not (iar--cycle-same-tool-escalation-p tool 99 state))
      (should-not (plist-get state :same-tool-blocked)))))

(ert-deftest test-same-tool-escalation-idempotent ()
  "Once blocked, further calls stay blocked (no re-escalation churn)."
  (let ((iar-cycle-same-tool-warn 2)
        (iar-cycle-same-tool-block 3)
        (state (list :same-tool-warned t :same-tool-blocked t)))
    (let ((result (iar--cycle-same-tool-escalation-p
                   "execute_code_local" 99 state)))
      (should (plist-get result :block))
      ;; state flag unchanged, message says already-blocked
      (should (string-match-p "already blocked"
                              (plist-get result :block))))))

(ert-deftest test-same-tool-escalation-under-threshold ()
  "Below the block threshold (but past warn), no block."
  (let ((iar-cycle-same-tool-warn 5)
        (iar-cycle-same-tool-block 8)
        (state (list :same-tool-warned t :same-tool-blocked nil)))
    (should-not (iar--cycle-same-tool-escalation-p
                 "execute_code_local" 7 state))
    (should-not (plist-get state :same-tool-blocked))))

(provide 'test-same-tool-escalation)
