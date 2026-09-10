;; -*- lexical-binding: t; -*-
;; aria-0030 regression tests: a terminal `echo CYCLE_COMPLETE` tool call
;; (echo-only response, no model text) closes the cycle; text+echo does not.
(require 'ert)
(require 'iar-agent-cycle)

(defun iar--test-terminal-echo-buffer (content)
  "Insert CONTENT into a fresh buffer with gptel text-properties:
thinking blocks propertized 'ignore, tool spans '(tool . \"call_1\"),
plain model text unpropertized. CONTENT is a list of (TEXT . PROP)
conses, PROP nil for model text."
  (let ((buf (get-buffer-create "*test-terminal-echo*")))
    (with-current-buffer buf
      (erase-buffer)
      (dolist (item content)
        (let ((text (car item))
              (prop (cdr item)))
          (insert (if prop (propertize text 'gptel prop) text)))))
    buf))

(defun iar--test-echo-spec (command)
  "Build ONE tool-use call-spec plist like the ollama parser produces."
  (list :name "execute_code_local" :args command))

(ert-deftest test-terminal-echo-echo-only-closes-cycle ()
  "aria-0030: an echo-only response (thinking + tool call, no model
text) whose last spec is execute_code_local with CYCLE_COMPLETE closes."
  (let ((buf (iar--test-terminal-echo-buffer
              (list (cons "``` reasoning\nWe are done.\n```\n" 'ignore)
                    (cons "``` tool (execute_code_local ...)\n```" '(tool . "call_1"))))))
    (unwind-protect
        (let ((iar--reqlog-last-tool-specs (list (iar--test-echo-spec "echo \"CYCLE_COMPLETE\""))))
          (with-current-buffer buf
            (should (eq 'cycle (iar--cycle-terminal-echo-p (point-min) (point-max))))))
      (kill-buffer buf))))

(ert-deftest test-terminal-echo-loop-echo-returns-loop ()
  "A LOOP_COMPLETE echo returns 'loop (exit 2 contract)."
  (let ((buf (iar--test-terminal-echo-buffer
              (list (cons "``` tool (execute_code_local ...)\n```" '(tool . "call_1"))))))
    (unwind-protect
        (let ((iar--reqlog-last-tool-specs (list (iar--test-echo-spec "echo \"LOOP_COMPLETE\""))))
          (with-current-buffer buf
            (should (eq 'loop (iar--cycle-terminal-echo-p (point-min) (point-max))))))
      (kill-buffer buf))))

(ert-deftest test-terminal-echo-with-model-text-does-not-close ()
  "A response with real model text plus an echo is mid-work, not a close."
  (let ((buf (iar--test-terminal-echo-buffer
              (list (cons "Worked on the census, all done now.\n" nil)
                    (cons "``` tool (execute_code_local ...)\n```" '(tool . "call_1"))))))
    (unwind-protect
        (let ((iar--reqlog-last-tool-specs (list (iar--test-echo-spec "echo \"CYCLE_COMPLETE\""))))
          (with-current-buffer buf
            (should-not (iar--cycle-terminal-echo-p (point-min) (point-max)))))
      (kill-buffer buf))))

(ert-deftest test-terminal-echo-last-spec-wins ()
  "The LAST spec decides: echo after other tool calls closes; echo
followed by another call does not."
  (let ((buf (iar--test-terminal-echo-buffer
              (list (cons "``` tool (execute_code_local ...)\n```" '(tool . "call_1"))))))
    (unwind-protect
        (let ((iar--reqlog-last-tool-specs
               (list (iar--test-echo-spec "echo \"CYCLE_COMPLETE\"")
                     (list :name "execute_code_local" :args "ls /tmp"))))
          (with-current-buffer buf
            ;; last spec is NOT the echo -> no close
            (should-not (iar--cycle-terminal-echo-p (point-min) (point-max))))
          (setq iar--reqlog-last-tool-specs
                (list (list :name "execute_code_local" :args "ls /tmp")
                      (iar--test-echo-spec "echo \"CYCLE_COMPLETE\"")))
          (with-current-buffer buf
            ;; last spec IS the echo -> close
            (should (eq 'cycle (iar--cycle-terminal-echo-p (point-min) (point-max))))))
      (kill-buffer buf))))

(ert-deftest test-terminal-echo-no-tool-data-does-not-close ()
  "No reqlog data (nil specs) -> no close, never fires on absence of evidence."
  (let ((buf (iar--test-terminal-echo-buffer
              (list (cons "``` tool (execute_code_local ...)\n```" '(tool . "call_1"))))))
    (unwind-protect
        (let ((iar--reqlog-last-tool-specs nil))
          (with-current-buffer buf
            (should-not (iar--cycle-terminal-echo-p (point-min) (point-max)))))
      (kill-buffer buf))))

(ert-deftest test-terminal-echo-non-echo-tool-does-not-close ()
  "A tool call that merely MENTIONS the sentinel in passing (not an echo
command shape) does not close: name must be execute_code_local AND args
must carry the sentinel -- but a real command like grep is not a close
even if it references the token... it WOULD match args. This test pins
the accepted behavior: any execute_code_local whose args contain the
sentinel as its last act closes. A grep census command mentioning the
token mid-work is protected by the model-text condition (a census turn
has model text). Here: a non-echo tool name never closes."
  (let ((buf (iar--test-terminal-echo-buffer
              (list (cons "``` tool (...)\n```" '(tool . "call_1"))))))
    (unwind-protect
        (let ((iar--reqlog-last-tool-specs
               (list (list :name "read_file" :args "/tmp/x"))))
          (with-current-buffer buf
            (should-not (iar--cycle-terminal-echo-p (point-min) (point-max)))))
      (kill-buffer buf))))

(ert-deftest test-terminal-echo-c132-tool-span-negative-preserved ()
  "c132 discipline intact: a sentinel inside a tool RESULT span with
other work after it must not close -- here the model text condition
fails because the response carries real text after the tool span."
  (let ((buf (iar--test-terminal-echo-buffer
              (list (cons "``` tool (execute_code_local ...)\n```" '(tool . "call_1"))
                    (cons "Continuing with the next step.\n" nil)))))
    (unwind-protect
        (let ((iar--reqlog-last-tool-specs (list (iar--test-echo-spec "echo \"CYCLE_COMPLETE\""))))
          (with-current-buffer buf
            (should-not (iar--cycle-terminal-echo-p (point-min) (point-max)))))
      (kill-buffer buf))))

(ert-deftest test-terminal-echo-reset-leaves-no-stale-close ()
  "iar--reqlog-reset-last clears the tool-specs var (no stale close)."
  (let ((iar--reqlog-last-tool-specs (list (iar--test-echo-spec "echo \"CYCLE_COMPLETE\""))))
    (iar--reqlog-reset-last)
    (should (null iar--reqlog-last-tool-specs))))

;;; --- pre-tool-call hook (c167 correction: the close lives in the tool path) ---

(defun iar--test-echo-hook-buffer ()
  "Build a response buffer for the hook tests: thinking (ignore) +
tool span, model text empty -- the echo-only production shape."
  (iar--test-terminal-echo-buffer
   (list (cons "``` reasoning\nWe are done.\n```\n" 'ignore)
         (cons "``` tool (execute_code_local ...)\n```" '(tool . "call_1")))))

(ert-deftest test-terminal-echo-hook-closes-cycle ()
  "The pre-tool-call hook closes the cycle on an echo-only response:
:completed t, exit 0, block message returned."
  (let* ((buf (iar--test-echo-hook-buffer))
         (iar--cycle-state (iar--cycle-make-state "test" buf nil 40)))
    (unwind-protect
        (with-current-buffer buf
          (setq gptel--fsm-last
                (gptel-make-fsm
                 :info (list :position (copy-marker (point-min))
                             :tracking-marker (copy-marker (point-max)))))
          (let ((iar--reqlog-last-tool-specs
                 (list (list :name "execute_code_local"
                             :args "echo \"CYCLE_COMPLETE\"")))
                (iar--one-shot-state nil))
            (let ((result (iar--cycle-terminal-echo-close
                           (list :name "execute_code_local"
                                 :args "echo \"CYCLE_COMPLETE\""))))
              (should (plist-get result :block))
              (should (plist-get iar--cycle-state :completed))
              (should (= 0 (plist-get iar--cycle-state :exit-code))))))
      (setq iar--cycle-state nil)
      (kill-buffer buf))))

(ert-deftest test-terminal-echo-hook-loop-echo-exit-2 ()
  "A LOOP echo closes with exit 2 (task done)."
  (let* ((buf (iar--test-echo-hook-buffer))
         (iar--cycle-state (iar--cycle-make-state "test" buf nil 40)))
    (unwind-protect
        (with-current-buffer buf
          (setq gptel--fsm-last
                (gptel-make-fsm
                 :info (list :position (copy-marker (point-min))
                             :tracking-marker (copy-marker (point-max)))))
          (let ((iar--reqlog-last-tool-specs
                 (list (list :name "execute_code_local"
                             :args "echo \"LOOP_COMPLETE\"")))
                (iar--one-shot-state nil))
            (iar--cycle-terminal-echo-close
             (list :name "execute_code_local" :args "echo \"LOOP_COMPLETE\""))
            (should (plist-get iar--cycle-state :completed))
            (should (= 2 (plist-get iar--cycle-state :exit-code)))))
      (setq iar--cycle-state nil)
      (kill-buffer buf))))

(ert-deftest test-terminal-echo-hook-no-close-on-text-response ()
  "A response with real model text + echo does NOT close (mid-work)."
  (let* ((buf (iar--test-terminal-echo-buffer
               (list (cons "Census done, moving on.\n" nil)
                     (cons "``` tool (execute_code_local ...)\n```" '(tool . "call_1")))))
         (iar--cycle-state (iar--cycle-make-state "test" buf nil 40)))
    (unwind-protect
        (with-current-buffer buf
          (setq gptel--fsm-last
                (gptel-make-fsm
                 :info (list :position (copy-marker (point-min))
                             :tracking-marker (copy-marker (point-max)))))
          (let ((iar--reqlog-last-tool-specs
                 (list (list :name "execute_code_local"
                             :args "echo \"CYCLE_COMPLETE\"")))
                (iar--one-shot-state nil))
            (should-not (iar--cycle-terminal-echo-close
                         (list :name "execute_code_local"
                               :args "echo \"CYCLE_COMPLETE\"")))
            (should-not (plist-get iar--cycle-state :completed))))
      (setq iar--cycle-state nil)
      (kill-buffer buf))))

(ert-deftest test-terminal-echo-hook-no-close-on-grep-mention ()
  "A census grep command that MENTIONS the sentinel does not close:
the echo-shape check on the executed call rejects it."
  (let* ((buf (iar--test-echo-hook-buffer))
         (iar--cycle-state (iar--cycle-make-state "test" buf nil 40)))
    (unwind-protect
        (with-current-buffer buf
          (setq gptel--fsm-last
                (gptel-make-fsm
                 :info (list :position (copy-marker (point-min))
                             :tracking-marker (copy-marker (point-max)))))
          (let ((iar--reqlog-last-tool-specs
                 (list (list :name "execute_code_local"
                             :args "grep -c CYCLE_COMPLETE /tmp/census.log")))
                (iar--one-shot-state nil))
            (should-not (iar--cycle-terminal-echo-close
                         (list :name "execute_code_local"
                               :args "grep -c CYCLE_COMPLETE /tmp/census.log")))
            (should-not (plist-get iar--cycle-state :completed))))
      (setq iar--cycle-state nil)
      (kill-buffer buf))))

(ert-deftest test-terminal-echo-hook-no-state-no-close ()
  "No active cycle/one-shot state -> nil, no crash (interactive use)."
  (let* ((buf (iar--test-echo-hook-buffer))
         (iar--cycle-state nil)
         (iar--one-shot-state nil))
    (unwind-protect
        (with-current-buffer buf
          (should-not (iar--cycle-terminal-echo-close
                       (list :name "execute_code_local"
                             :args "echo \"CYCLE_COMPLETE\""))))
      (kill-buffer buf))))

(ert-deftest test-terminal-echo-hook-one-shot-closes ()
  "The hook dispatches on one-shot state too (echo close in one-shot)."
  (let* ((buf (iar--test-echo-hook-buffer))
         (iar--cycle-state nil)
         (iar--one-shot-state (iar--cycle-make-state "test" buf nil 40)))
    (unwind-protect
        (with-current-buffer buf
          (setq gptel--fsm-last
                (gptel-make-fsm
                 :info (list :position (copy-marker (point-min))
                             :tracking-marker (copy-marker (point-max)))))
          (let ((iar--reqlog-last-tool-specs
                 (list (list :name "execute_code_local"
                             :args "echo \"CYCLE_COMPLETE\""))))
            (iar--cycle-terminal-echo-close
             (list :name "execute_code_local" :args "echo \"CYCLE_COMPLETE\""))
            (should (plist-get iar--one-shot-state :completed))
            (should (= 0 (plist-get iar--one-shot-state :exit-code)))))
      (setq iar--one-shot-state nil)
      (kill-buffer buf))))
