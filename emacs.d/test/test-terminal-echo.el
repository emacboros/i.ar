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
