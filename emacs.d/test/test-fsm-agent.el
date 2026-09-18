;; -*- lexical-binding: t; -*-
;; Quick verification tests for the FSM-resolved audit agent (c143)
(require 'ert)
(require 'iar-tool-call)

(ert-deftest test-fsm-agent-resolves-from-fsm-buffer ()
  "The FSM resolver returns the agent name from the FSM's :buffer."
  (let ((old-default (default-value 'iar--current-agent-name)))
    (unwind-protect
        (with-temp-buffer
          (setq-local iar--current-agent-name "parentaria")
          (let* ((info (list :buffer (current-buffer)))
                 (fsm (gptel-make-fsm :info info)))
            (should (string= "parentaria"
                             (iar--audit-log-agent-name-from-fsm fsm)))))
      (setq-default iar--current-agent-name old-default))))

(ert-deftest test-fsm-agent-falls-back-to-current-buffer-when-fsm-nil ()
  "fsm=nil: legacy current-buffer resolution is used (test paths)."
  (let ((old-default (default-value 'iar--current-agent-name)))
    (unwind-protect
        (progn
          (setq-default iar--current-agent-name "legacyname")
          (should (string= "legacyname"
                           (iar--audit-log-agent-name-from-fsm nil))))
      (setq-default iar--current-agent-name old-default))))

(ert-deftest test-fsm-agent-falls-back-when-buffer-dead ()
  "A dead FSM buffer falls back to legacy resolution."
  (let ((old-default (default-value 'iar--current-agent-name)))
    (unwind-protect
        (progn
          (setq-default iar--current-agent-name "fallbackname")
          (let* ((dead-buf (generate-new-buffer "dead"))
                 (info (list :buffer dead-buf))
                 (fsm (gptel-make-fsm :info info)))
            (kill-buffer dead-buf)
            (should (string= "fallbackname"
                             (iar--audit-log-agent-name-from-fsm fsm)))))
      (setq-default iar--current-agent-name old-default))))

(ert-deftest test-fsm-agent-never-signals-on-garbage-fsm ()
  "A garbage fsm (non-struct) returns a string, never signals."
  (should (stringp (iar--audit-log-agent-name-from-fsm 'garbage)))
  (should (stringp (iar--audit-log-agent-name-from-fsm 42))))

(ert-deftest test-fsm-agent-ignores-buffer-without-agent-name ()
  "A live FSM buffer without the buffer-local name falls back."
  (let ((old-default (default-value 'iar--current-agent-name)))
    (unwind-protect
        (progn
          (setq-default iar--current-agent-name "fallbackname")
          (with-temp-buffer
            (let* ((info (list :buffer (current-buffer)))
                   (fsm (gptel-make-fsm :info info)))
              ;; No buffer-local iar--current-agent-name in this buffer.
              (should (string= "fallbackname"
                               (iar--audit-log-agent-name-from-fsm fsm))))))
      (setq-default iar--current-agent-name old-default))))

(ert-deftest test-truncate-advice-passes-fsm-resolved-agent-to-bridge ()
  "The advice passes the FSM-resolved agent into the bridge (the
async-completion misattribution fix: the agent must come from the
FSM's :buffer, not the current buffer)."
  (let ((seen-agent :unset) (logged nil))
    (cl-letf (((symbol-function 'iar--audit-log-as)
               (lambda (agent _tool detail)
                 (setq seen-agent agent logged detail)))
              ((symbol-function 'iar--bridge-pre-tool-call) (lambda (_i) nil))
              ((default-value 'iar-post-tool-call-functions) nil))
      (with-temp-buffer
        (setq-local iar--current-agent-name "fsmagent")
        (let* ((info (list :buffer (current-buffer)))
               (fsm (gptel-make-fsm :info info)))
          ;; current-buffer IS the fsm buffer here; simulate the async
          ;; completion context by running the bridge from a FOREIGN
          ;; current buffer.
          (with-temp-buffer
            (iar--truncate-tool-result-advice
             (lambda (_fsm _spec _call result) result)  ; orig: identity
             fsm
             nil  ; tool-spec
             '(:name "delegate" :args (:task "review"))
             "short")))
        (should (equal "fsmagent" seen-agent))))))
