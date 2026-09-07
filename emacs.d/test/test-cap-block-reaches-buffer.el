;; -*- lexical-binding: t; -*-

;;; test-cap-block-reaches-buffer.el -- c67 differential (soft-cap block -> model context)
;;
;; The c67 anomaly family: the model ignores the soft-cap block message
;; and burns `iar-cycle-tool-call-hard-cap' ignored blocks to a hard
;; exit-1 (c86 live: 132 calls, 4.48M tok, 5 ignored blocks). Before
;; filing "model non-compliance" we must pin the machinery: does the
;; block message actually REACH the conversation the model sees?
;;
;; The production path (gptel-fork):
;;   iar--cycle-tool-call-cap returns (:block . MSG)
;;   -> gptel--handle-pre-tool (TPRE handler) sees :block
;;   -> sets tool-call :error t, wraps MSG in <tool_call_error>...</tool_call_error>
;;   -> gptel--process-tool-call puts that string on the tool-call :result
;;      and into info :tool-result
;;   -> the tool result is injected into the next request's messages
;;      (gptel--parse-tool-result / gptel--parse-buffer at the next send).
;;
;; These tests drive the REAL gptel--handle-pre-tool on a real FSM
;; (same harness as test-unknown-tool.el) and assert the block message
;; lands as the tool call's :result -- the string the model receives
;; as the tool's output. If these pass, the message reaches context
;; and the c86 behavior is model non-compliance (watching item), not
;; a machinery gap.
;;
;; Filed by continuo c87 (tasks/iar/continuo/soft-cap-c67-differential);
;; implemented by aria c16.

(require 'ert)
(require 'cl-lib)
(require 'gptel-request)
(require 'gptel)
(require 'gptel-ollama)
(require 'iar-agent-cycle)
(require 'iar-tool-call)

(defun test-cap-block--make-fsm (tool-call tool-spec)
  "Build a real gptel FSM in TOOL state with one TOOL-CALL pending.
TOOL-SPEC is registered in :tools so gptel--handle-pre-tool can find
it by name (the block path calls gptel--process-tool-call with it)."
  (let* ((backend (gptel-make-ollama "TestCapBlock"
                                     :host "localhost:11434"
                                     :models '(test-model)
                                     :stream t))
         (buf (get-buffer-create "*test-cap-block*"))
         (info (list :backend backend
                     :buffer buf
                     :tools (list tool-spec)
                     :data (list :messages [])
                     :tool-use (list tool-call))))
    (gptel-make-fsm
     :table gptel-send--transitions
     :handlers gptel-send--handlers
     :state 'TPRE
     :info info)))

(ert-deftest test-cap-block-message-reaches-tool-result ()
  "THE differential: a soft-cap :block from the real cap hook, run
through the real gptel--handle-pre-tool, must land the block message
(as <tool_call_error>) on the tool call's :result -- the text the
model receives as the tool output in the next request."
  (let* ((tool-spec (gptel-make-tool
                     :name "execute_code_local"
                     :description "run bash"
                     :args (list '(:name "command" :type "string"))
                     :function (lambda (&rest _) "SHOULD-NOT-RUN")))
         (tool-call (list :name "execute_code_local"
                          :args (list :command "ls")))
         (fsm (test-cap-block--make-fsm tool-call tool-spec))
         (cycle-buf (plist-get (gptel-fsm-info fsm) :buffer)))
    (unwind-protect
        (let ((iar--cycle-state (iar--cycle-make-state "test" cycle-buf nil 40))
              (iar--one-shot-state nil))
          ;; Park the state exactly at the soft cap: the next call is
          ;; blocked with the landing message.
          (setf (plist-get iar--cycle-state :tool-call-count)
                iar-cycle-tool-call-cap)
          ;; Drive the REAL pre-tool handler. It runs
          ;; iar-pre-tool-call-functions (which includes the cap hook via
          ;; the bridge), sees (:block . msg), and calls
          ;; gptel--process-tool-call with the wrapped message.
          (gptel--handle-pre-tool fsm)
          ;; The tool call must now carry the block message as its
          ;; result -- this is what enters the conversation as the
          ;; tool's output.
          (let ((result (plist-get tool-call :result)))
            (should result)
            (should (string-match-p "<tool_call_error>" result))
            (should (string-match-p "Tool-call soft cap" result))
            (should (string-match-p "CYCLE_COMPLETE" result)))
          ;; And the FSM must have advanced out of TPRE (result
          ;; processed, not hung).
          (should (eq (gptel-fsm-state fsm) 'TOOL)))
      (when (buffer-live-p cycle-buf) (kill-buffer cycle-buf)))))

(ert-deftest test-cap-block-error-flag-set ()
  "The block path must also set :error on the tool call (the
tool_call_error semantics), so downstream layers can distinguish a
blocked call from a successful one."
  (let* ((tool-spec (gptel-make-tool
                     :name "read_file"
                     :description "read"
                     :args (list '(:name "filepath" :type "string"))
                     :function (lambda (&rest _) "SHOULD-NOT-RUN")))
         (tool-call (list :name "read_file" :args (list :filepath "/tmp/x")))
         (fsm (test-cap-block--make-fsm tool-call tool-spec))
         (cycle-buf (plist-get (gptel-fsm-info fsm) :buffer)))
    (unwind-protect
        (let ((iar--cycle-state (iar--cycle-make-state "test" cycle-buf nil 40))
              (iar--one-shot-state nil))
          (setf (plist-get iar--cycle-state :tool-call-count)
                iar-cycle-tool-call-cap)
          (gptel--handle-pre-tool fsm)
          (should (eq (plist-get tool-call :error) t)))
      (when (buffer-live-p cycle-buf) (kill-buffer cycle-buf)))))

(ert-deftest test-cap-block-tool-result-alist-carries-message ()
  "The block message must also be recorded in info :tool-result --
the alist gptel injects into the next request's messages array."
  (let* ((tool-spec (gptel-make-tool
                     :name "execute_code_local"
                     :description "run bash"
                     :args (list '(:name "command" :type "string"))
                     :function (lambda (&rest _) "SHOULD-NOT-RUN")))
         (tool-call (list :name "execute_code_local"
                          :args (list :command "pwd")))
         (fsm (test-cap-block--make-fsm tool-call tool-spec))
         (cycle-buf (plist-get (gptel-fsm-info fsm) :buffer))
         (info (gptel-fsm-info fsm)))
    (unwind-protect
        (let ((iar--cycle-state (iar--cycle-make-state "test" cycle-buf nil 40))
              (iar--one-shot-state nil))
          (setf (plist-get iar--cycle-state :tool-call-count)
                iar-cycle-tool-call-cap)
          (gptel--handle-pre-tool fsm)
          (let ((alist (plist-get info :tool-result)))
            (should alist)
            ;; (tool-spec args result-string) triples
            (let ((entry (car alist)))
              (should (= (length entry) 3))
              (should (string-match-p "Tool-call soft cap" (nth 2 entry))))))
      (when (buffer-live-p cycle-buf) (kill-buffer cycle-buf)))))

(ert-deftest test-cap-block-warn-message-reaches-tool-result ()
  "The warn path (budget warning at 60) uses the same :block
mechanism -- pin that it reaches the tool result too. This is the
warn@60 fence whose silence was suspected in the c67 family."
  (let* ((tool-spec (gptel-make-tool
                     :name "execute_code_local"
                     :description "run bash"
                     :args (list '(:name "command" :type "string"))
                     :function (lambda (&rest _) "SHOULD-NOT-RUN")))
         (tool-call (list :name "execute_code_local"
                          :args (list :command "ls")))
         (fsm (test-cap-block--make-fsm tool-call tool-spec))
         (cycle-buf (plist-get (gptel-fsm-info fsm) :buffer)))
    (unwind-protect
        (let ((iar--cycle-state (iar--cycle-make-state "test" cycle-buf nil 40))
              (iar--one-shot-state nil))
          ;; Park at the WARN threshold (not the cap): next call is
          ;; blocked once with the budget notice.
          (setf (plist-get iar--cycle-state :tool-call-count)
                (1- iar-cycle-tool-call-warn))
          (gptel--handle-pre-tool fsm)
          (let ((result (plist-get tool-call :result)))
            (should result)
            (should (string-match-p "budget warning" result)))
          ;; Warn fired exactly once
          (should (plist-get iar--cycle-state :cap-warned)))
      (when (buffer-live-p cycle-buf) (kill-buffer cycle-buf)))))

(provide 'test-cap-block-reaches-buffer)
;;; test-cap-block-reaches-buffer.el ends here