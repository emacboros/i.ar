;; -*- lexical-binding: t; -*-

;;; Delegate Tool for gptel - Multi-Agent Delegation (Async)
;; Allows an agent to spawn a sub-agent with a specific profile to handle a sub-task.
;;
;; This is an ASYNC tool: the function receives a callback as its first
;; argument (per gptel's :async convention) and calls it with the result when
;; the sub-agent completes. This keeps Emacs responsive during delegation and
;; allows nested delegation chains without freezing the editor.
;;
;; The sub-agent's output is streamed live into the parent buffer so the user
;; can watch progress as it happens.

(require 'iar-tool-call)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-agent-utils)  ; validation
(require 'iar-agent-loader)  ; iar--setup-assembled-buffer, iar--archetype-for-personality, iar--project-for-personality
(require 'iar-prompt-assembly)  ; iar--assemble-prompt
(require 'iar-tool-guard)    ; iar--block-unknown-tools
(require 'iar-prompt-loader)  ; iar--load-prompt
(require 'iar-mount-awareness)  ; iar--extra-mounts-prompt-string

;; Declared in configs/ (split parameter files) (loaded before init.d modules).
;; Forward-declared: owned by configs/paths.el.
(defvar iar-personalities-path nil
  "Relative path to personality definition files.")

(defvar iar-delegation-result-marker nil
  "Marker that sub-agents emit before their concise summary.")



;;; Buffer-local state for tracking delegation depth

(defvar-local iar--delegate-depth 0
  "Buffer-local: current delegation depth for this agent session.
0 = top-level agent (not spawned via delegate).
1+ = spawned via delegate. Used to limit recursion depth.")

;; Parameters iar-delegate-max-depth and iar-delegate-max-turns
;; are defined in configs/ (split parameter files) (loaded early in init.el).
;; No defcustom here -- the module references them as dynamic variables.

;;; Internal functions

;;; Timeout handler (extracted to reduce nesting depth)

(defun iar--delegate-restore-parent-defaults (parent-agent-sym parent-file-sym)
  "Restore the parent's global-default agent identity from symbols.
Idempotent.  Runs at every delegate completion point (normal,
marker, exhaustion, timeout, dead-buffer) so the parent's
process-wide default is never left pointing at the sub-agent (c57:
aria c3's cycle-exit USAGE write resolved the leaked `reviewer'
default and landed in the reviewer's audit tree)."
  (when (and parent-agent-sym (boundp parent-agent-sym))
    (setq-default iar--current-agent-name (symbol-value parent-agent-sym)))
  (when (and parent-file-sym (boundp parent-file-sym))
    (setq-default iar--current-agent-file (symbol-value parent-file-sym))))

(defun iar--delegate-timeout-handler (buf callback agent completed-sym
                                               resp-start timeout-secs
                                               parent-agent-sym
                                               parent-file-sym)
  "Handle a delegate timeout.
This function is called by a timer when the sub-agent hasn't completed
within TIMEOUT-SECS.  It aborts the gptel request and calls CALLBACK
with a timeout message or partial response.

COMPLETED-SYM is a symbol whose value is checked dynamically (not a
static boolean).  This is critical: gptel-abort may trigger the
completion hook which sets the symbol to t before the fallback lambda
runs.  Using a symbol ensures the fallback sees the updated value
and avoids a double-callback race."
  (cond
   ((not (buffer-live-p buf))
    (unless (symbol-value completed-sym)
      (set completed-sym t)
      (iar--delegate-restore-parent-defaults parent-agent-sym parent-file-sym)
      (funcall callback
               (format "Delegate '%s' buffer was killed before completion." agent))))
   ((symbol-value completed-sym))  ; Already done, nothing to do
   (t
    (gptel-abort buf)
    ;; Fallback: if gptel-abort doesn't trigger the post-response hook,
    ;; force completion after a brief delay.  Check the symbol's current
    ;; value (not a captured snapshot) so that if the completion hook
    ;; fired between gptel-abort and this fallback, we skip the callback.
    ;; Set completed-sym to t before calling the callback to prevent a
    ;; double-callback if the completion hook fires after the fallback.
    (run-with-timer
     1 nil
     (lambda ()
       (unless (symbol-value completed-sym)
         (set completed-sym t)
         (iar--delegate-restore-parent-defaults parent-agent-sym parent-file-sym)
         (let ((partial
                (when (buffer-live-p buf)
                  (with-current-buffer buf
                    (save-restriction
                      (widen)
                      (if (and resp-start (< resp-start (point-max)))
                          (buffer-substring-no-properties resp-start (point-max))
                        ""))))))
           ;; Delay buffer kill to avoid "Selecting deleted buffer" in sentinel
           (run-with-timer
            3 nil
            (lambda ()
              (when (buffer-live-p buf) (kill-buffer buf))))
           (funcall callback
                    (if (and partial (iar--non-blank-p partial))
                        (format "[TIMEOUT after %ds -- partial response captured]\n\n%s"
                                timeout-secs partial)
                      (format "[TIMEOUT after %ds -- no response was generated before timeout]"
                              timeout-secs))))))))))

;;; Async tool function

(defun iar--tool-delegate (callback agent task &optional context timeout)
  "Delegate a task to a sub-agent with a specific profile.  ASYNC tool.
CALLBACK is gptel's async tool callback.  AGENT is the profile name
(optional, defaults to agent-assistant for pipeline delegation).
TASK is the task description.  CONTEXT is optional context.
TIMEOUT is optional max seconds to wait (default 600, minimum 1)."
  (let* ((ctx (or context "No additional context provided."))
         (timeout-secs (cond
                        ((integerp timeout) timeout)
                        ((stringp timeout) (string-to-number timeout))
                        ((numberp timeout) (floor timeout))
                        (t 600)))
         ;; Ensure timeout is at least 1 second
         (timeout-secs (max 1 timeout-secs))
         ;; Default to agent-assistant when agent is nil or empty
         (effective-agent
          (if (and agent (stringp agent) (> (length agent) 0)
                   (string-match "[^[:space:]]" agent))
              agent
            "agent-assistant"))
         (task-valid (and task (stringp task) (> (length task) 0)
                          (string-match "[^[:space:]]" task))))
    (cond
     ((not task-valid)
      (funcall callback "Delegate tool error: :task must be a non-empty string"))
     (t
      (condition-case err
          (let* ((archetype (iar--archetype-for-personality effective-agent))
                 (project (iar--project-for-personality effective-agent))
                 (result (iar--assemble-prompt archetype effective-agent project))
                 (profile (plist-get result :prompt))
                 (tools (plist-get result :tools)))
            (iar--spawn-async-delegate
             callback effective-agent task ctx timeout-secs profile tools))
        (error
         (funcall callback
                  (format "Delegate error: personality '%s' not found: %s"
                          effective-agent (error-message-string err)))))))))

(defconst iar--delegate-continue-prompt
  (iar--load-prompt "delegate_continue")
  "Prompt sent to a delegate when it produces a text-only response
without calling any tools in the current turn.  This nudges the model
to either call its tools (instead of narrating intentions) or produce
its final response if the task is already complete.
Loaded from knowledge/prompts/common/delegate_continue.org")

(defun iar--delegate-extract-result (full-response)
  "Extract the concise result from FULL-RESPONSE.
If the DELEGATION RESULT marker is found, return the text after it
(trimmed).  Otherwise, check if the response itself looks like a
final result (contains the marker text inline) and return as-is.
If no marker at all, return FULL-RESPONSE unchanged so the parent
gets something useful."
  (let ((marker-pos
         (string-match iar-delegation-result-marker full-response)))
    (if marker-pos
        (string-trim
         (substring full-response (match-end 0)))
      full-response)))

(defun iar--delegate-completion-fn (buf callback agent completed-sym
                                             timer-sym timeout-secs
                                             tools-called-sym turn-count-sym
                                             max-turns parent-agent-sym
                                             parent-file-sym)
  "Return a completion hook function for the delegate buffer.
BUF is the delegate buffer.  CALLBACK is gptel's async callback.
AGENT is the agent name.  COMPLETED-SYM is a symbol holding the completed flag.
TIMER-SYM is a symbol holding the timer.  TIMEOUT-SECS is the timeout.
TOOLS-CALLED-SYM is a symbol holding the tool-called flag for the current turn.
TURN-COUNT-SYM is a symbol holding the turn counter.
MAX-TURNS is the maximum number of text-only turns before forcing completion.

COMPLETION LOGIC:
The hook is called at every gptel response boundary (DONE, ERRS, ABRT).
It distinguishes three cases:

1. Tools were called this turn (tools-called-sym is non-nil): This is a
   genuine response after tool use.  Extract the result after the
   DELEGATION RESULT marker and return it to the parent.  Done.

2. No tools called, under max turns: The model produced a text-only
   response.  Check if it contains the DELEGATION RESULT marker -- if so,
   the model is signaling completion (simple tasks that need no tools).
   Return the extracted result.  If no marker, re-prompt with
   `iar--delegate-continue-prompt' to nudge the model to act or finish.

3. No tools called and max turns reached: Return whatever text we have.
   This is the exhaustion fallback -- prevents infinite re-prompting."
  (lambda (start end)
    (unless (symbol-value completed-sym)
      (let ((tools-called (symbol-value tools-called-sym))
            (turn-count (symbol-value turn-count-sym)))
        (let* ((full-response
                (save-restriction
                  (widen)
                  (if (and (integerp start) (integerp end) (< start end))
                      (buffer-substring-no-properties
                       (min (max start (point-min)) (point-max))
                       (min (max end (point-min)) (point-max)))
                    "")))
               (has-marker
                (and (stringp full-response)
                     (string-match-p iar-delegation-result-marker full-response))))
          (cond
           ;; Case 1: Tools were called this turn -- genuine response, return it.
           ;; Extract only the text after the "=== DELEGATION RESULT ===" marker.
           ;; Falls back to full response if marker is not found.
           (tools-called
            (set completed-sym t)
            (when (symbol-value timer-sym)
              (cancel-timer (symbol-value timer-sym)))
            ;; c143: restore the parent's global-default identity BEFORE
            ;; the callback. The callback is the parent's async tool
            ;; completion (gptel--process-tool-call runs from the
            ;; delegate's own completion path); without the restore, the
            ;; parent's post-completion audit lines (and the tool-call
            ;; bridge's agent resolution fallback) resolve the leaked
            ;; sub-agent default -- the 15:19:38 misattribution class.
            (iar--delegate-restore-parent-defaults parent-agent-sym parent-file-sym)
            (let* ((response (iar--delegate-extract-result full-response)))
              (run-with-timer
               5 nil
               (lambda ()
                 (when (buffer-live-p buf) (kill-buffer buf))))
              (funcall callback
                       (if (and response (iar--non-blank-p response))
                           (format "Delegate '%s' completed:\n\n%s" agent response)
                         (format "Delegate '%s' returned empty response (timeout: %ds)."
                                 agent timeout-secs)))))

           ;; Case 2a: No tools called, but response has DELEGATION RESULT marker.
           ;; The model is signaling completion for a task that needed no tools.
           ;; Return the extracted result -- do not re-prompt.
           ((and (not tools-called) has-marker)
            (set completed-sym t)
            (when (symbol-value timer-sym)
              (cancel-timer (symbol-value timer-sym)))
            ;; c143: restore before callback (same reasoning as case 1).
            (iar--delegate-restore-parent-defaults parent-agent-sym parent-file-sym)
            (let* ((response (iar--delegate-extract-result full-response)))
              (run-with-timer
               5 nil
               (lambda ()
                 (when (buffer-live-p buf) (kill-buffer buf))))
              (funcall callback
                       (if (and response (iar--non-blank-p response))
                           (format "Delegate '%s' completed:\n\n%s" agent response)
                         (format "Delegate '%s' returned empty response (timeout: %ds)."
                                 agent timeout-secs)))))

           ;; Case 2b: No tools called, no marker, under max turns -- re-prompt.
           ((< turn-count max-turns)
            (set turn-count-sym (1+ turn-count))
            (set tools-called-sym nil)   ; Reset for next turn
            (message "[delegate] %s produced text-only response (turn %d/%d), re-prompting..."
                     agent (1+ turn-count) max-turns)
            (run-with-timer
             1 nil
             (lambda ()
               (when (and (not (symbol-value completed-sym))
                          (buffer-live-p buf))
                 (with-current-buffer buf
                   (save-restriction
                     (widen)
                     (goto-char (point-max))
                     (insert "\n\n" iar--delegate-continue-prompt)
                     (gptel-send)))))))

           ;; Case 3: No tools called and max turns reached -- return whatever we have.
           (t
            (set completed-sym t)
            (when (symbol-value timer-sym)
              (cancel-timer (symbol-value timer-sym)))
            (iar--delegate-restore-parent-defaults parent-agent-sym parent-file-sym)
            (let ((response
                   (save-restriction
                     (widen)
                     (if (and (integerp start) (integerp end) (< start end))
                         (buffer-substring-no-properties
                          (min (max start (point-min)) (point-max))
                          (min (max end (point-min)) (point-max)))
                       ""))))
              (message "[delegate] %s reached max text-only turns (%d), returning last response."
                       agent max-turns)
              (run-with-timer
               5 nil
               (lambda ()
                 (when (buffer-live-p buf) (kill-buffer buf))))
              (funcall callback
                       (if (and response (iar--non-blank-p response))
                           (format "Delegate '%s' completed (max text-only turns reached):\n\n%s"
                                   agent response)
                         (format "Delegate '%s' returned empty response after %d text-only turns."
                               agent max-turns)))))))))))

(defun iar--spawn-async-delegate (callback agent task ctx timeout-secs profile tools)
  "Spawn an async delegate buffer and send the task.
The sub-agent's streaming output is mirrored into the parent buffer
so the user can watch progress in real time."
  (let* ((parent-depth (max 0 (if (boundp 'iar--delegate-depth)
                                   iar--delegate-depth 0)))
         (task-id (format "delegate-%s-%d-%d" agent (emacs-pid) (float-time)))
         (buf (get-buffer-create (format "*gptel-delegate-%s*" task-id)))
         (full-prompt (format (iar--load-prompt "delegated_task")
                              ctx task))
         ;; Use symbols for mutable state shared with hook closures
         (completed-sym (make-symbol "completed"))
         (timer-sym (make-symbol "timer"))
         ;; Parent's global-default agent identity, captured BEFORE the
         ;; setq-default below clobbers it (c57: the delegate leaked the
         ;; global default to the sub-agent for the rest of the parent's
         ;; process -- aria c3's USAGE line was written into the
         ;; reviewer's log because the exit path resolved the leaked
         ;; global default after the delegate buffer died).
         (parent-agent-sym (make-symbol "parent-agent"))
         (parent-file-sym (make-symbol "parent-file"))
         (tools-called-sym (make-symbol "tools-called"))
         (turn-count-sym (make-symbol "turn-count"))
         (resp-start nil))
    (set completed-sym nil)
    (set timer-sym nil)
    (set tools-called-sym nil)
    (set turn-count-sym 0)
    (with-current-buffer buf
      (text-mode)
      (gptel-mode 1)
      (setq-local gptel-system-prompt profile)
      ;; Set agent name for audit logging and status mode.
      (setq-local iar--current-agent-name agent)
      ;; Capture the parent's global-default identity BEFORE clobbering
      ;; it (c57 fix): the global default is what process-buffer
      ;; contexts (USAGE writes at exit, reqlog fallbacks) resolve
      ;; after this buffer dies. Without capture+restore, every
      ;; delegate leaks the sub-agent's name into the parent's
      ;; process-wide default for the rest of the session.
      (set parent-agent-sym
           (and (boundp 'iar--current-agent-name)
                (default-value 'iar--current-agent-name)))
      (set parent-file-sym
           (and (boundp 'iar--current-agent-file)
                (default-value 'iar--current-agent-file)))
      ;; setq-default: same async-sentinel fix as iar--setup-assembled-buffer.
      (setq-default iar--current-agent-name agent)
      (setq-local iar--current-agent-file
                  (expand-file-name (format "%s.org" agent)
                                    (expand-file-name iar-personalities-path user-emacs-directory)))
      (setq-default iar--current-agent-file
            (expand-file-name (format "%s.org" agent)
                              (expand-file-name iar-personalities-path user-emacs-directory)))
      (setq-local iar--delegate-depth (1+ parent-depth))
      (when (>= iar--delegate-depth iar-delegate-max-depth)
        (setq-local gptel-tools
                    (cl-remove-if (lambda (tool)
                                    (equal (gptel-tool-name tool) "delegate"))
                                  (copy-sequence gptel-tools))))
      ;; Apply tool gating from project
      (when tools
        (setq-local gptel-tools tools))

      ;; Tool call tracker: set tools-called flag when any tool is called.
      ;; This lets the completion hook distinguish between a genuine final
      ;; response (after tool use) and a premature text-only response where
      ;; the model narrates its plan without actually calling tools.
      (add-hook 'iar-post-tool-call-functions
                (lambda (_tool-name _tool-result)
                  (set tools-called-sym t))
                nil t)

      ;; Unknown tool guard: provide early interception of hallucinated tool
      ;; names at TPRE stage with a cleaner error message than gptel's
      ;; built-in handling in gptel--handle-tool-use (TOOL state).
      (add-hook 'iar-pre-tool-call-functions
                #'iar--block-unknown-tools
                nil t)

      ;; Completion hook: called by gptel at DONE, ERRS, or ABRT state.
      (let ((completion-fn
             (iar--delegate-completion-fn
              buf callback agent completed-sym timer-sym timeout-secs
              tools-called-sym turn-count-sym iar-delegate-max-turns
              parent-agent-sym parent-file-sym)))
        (add-hook 'iar-post-response-functions completion-fn nil t)

        ;; Timeout timer: fires once after timeout-secs.
        (set timer-sym
             (run-with-timer
              timeout-secs nil
              (lambda ()
                (iar--delegate-timeout-handler
                 buf callback agent completed-sym
                 resp-start timeout-secs
                 parent-agent-sym parent-file-sym))))

        ;; Insert the prompt text into the buffer and send.
        (insert full-prompt)
        (setq resp-start (point))
        (gptel-send)))
    buf))

;; Register the delegate tool (async)
(iar-tool-register
 (gptel-make-tool
  :name "delegate"
  :description "Spawn a sub-agent for a sub-task. Omit agent for pipeline mode (agent-assistant plans, delegates to implementer/reviewer). Specify agent to spawn that personality directly."
  :args (list '(:name "agent" :type "string" :description "Personality name (e.g., 'mirror', 'implementer'). Omit for agent-assistant pipeline." :optional t)
              '(:name "task" :type "string" :description "What you want the sub-agent to accomplish. Be specific and detailed.")
              '(:name "context" :type "string" :description "Relevant context from the current conversation to pass along. Optional but recommended.")
              '(:name "timeout" :type "integer" :description "Maximum seconds to wait for delegate response. Default 600." :optional t))
  :async t
  :function #'iar--tool-delegate))

(provide 'iar-delegate)