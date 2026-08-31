;; -*- lexical-binding: t; -*-

;;; Agent Cycle -- Headless batch entry point for autonomous agent loops
;;
;; This module provides `iar-run-cycle', a generic function that:
;; 1. Creates a gptel buffer with the assembled prompt (archetype + personality + project)
;; 2. Sends the cycle prompt ("Wake up. Do your thing. Stop.")
;; 3. Waits for the full delegation chain to complete
;; 4. Exits Emacs when done (or on timeout)
;;
;; The --agent flag specifies a personality name. The archetype is determined
;; by the personality-to-archetype map (e.g., darwin -> autonomous).
;; The project is determined by the personality name (e.g., darwin -> darwin project).
;;
;; Usage (batch mode):
;;   emacs --batch -l /root/.emacs.d/init.el \
;;         --eval '(iar-run-cycle :agent "darwin" :timeout 7200)'

(require 'gptel)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-utils)  ; iar--read-file-string, iar--current-project-name
(require 'iar-prompt-loader)
(require 'iar-tool-guard)
(require 'iar-tool-call)
(require 'iar-agent-loader)  ; iar--archetype-for-personality, iar--project-for-personality, iar--setup-assembled-buffer
(require 'iar-prompt-assembly)  ; iar--assemble-prompt

(defvar iar-guard-allow-self-modification)

;; Forward-declared: owned by configs/cycle.el.
(defvar iar-cycle-timeout nil
  "Default timeout for an agent cycle in seconds.")
(defvar iar-cycle-max-turns nil
  "Maximum number of LLM response turns before forcing cycle end.")

(defconst iar-personality-cycle-map
  '(("darwin" . "self_modification")
    ("gardener" . "monitoring")
    ("librarian" . "documentation_sync")
    ("test-continuous" . "test_continuous")
    ("aria" . "aria_daily"))
  "Mapping from personality names to default cycle files.
Used when :cycle is not explicitly provided to iar-run-cycle.")

;; Forward-declared: owned by configs/paths.el.
(defvar iar-cycles-path nil
  "Relative path to cycle definition files.")
;; Forward-declared: owned by configs/paths.el.
(defvar iar-personalization-path nil
  "Absolute path to the personalization mount point.")
(defvar iar-audit-path nil
  "Relative path to audit log directory.")

;;; ---------------------------------------------------------
;;; Token usage summary
;;; ---------------------------------------------------------

(defun iar--cycle-token-summary ()
  "Return a token usage summary string for cycle result messages.
Returns empty string if usage tracking is not available."
  (let ((totals (iar--usage-totals)))
    (format "\nTokens: %d in / %d out / %d total\nRequests: %d"
            (plist-get totals :input-tokens)
            (plist-get totals :output-tokens)
            (plist-get totals :total-tokens)
            (plist-get totals :requests))))

;;; ---------------------------------------------------------
;;; Cycle logging
;;; ---------------------------------------------------------

(defun iar--cycle-log-append (agent-name start end)
  "Append the latest LLM response to audit/<agent-name>/cycle.log.
START and END are buffer positions delimiting the new response text.
Creates the log file if it does not exist.  Prepends a timestamp."
  (when (and (integerp start) (integerp end) (< start end))
    (let* ((project (iar--current-project-name))
           (log-path (expand-file-name
                      (format "%s/%s/cycle.log" project agent-name)
                      (expand-file-name iar-audit-path iar-personalization-path)))
           (timestamp (format-time-string "[%Y-%m-%d %H:%M:%S]"))
           (response (with-current-buffer (current-buffer)
                       (save-restriction
                         (widen)
                         (buffer-substring-no-properties
                          (min (max start (point-min)) (point-max))
                          (min (max end (point-min)) (point-max)))))))
      (make-directory (file-name-directory log-path) t)
      (with-temp-buffer
        (insert timestamp "\n" response "\n\n")
        (let ((coding-system-for-write 'utf-8))
          (append-to-file (point-min) (point-max) log-path))))))

;;; ---------------------------------------------------------
;;; Cycle prompt loading
;;; ---------------------------------------------------------

(defun iar--cycle-load-cycle-prompt (cycle-name)
  "Load a cycle prompt from agents.d/cycles/<cycle-name>.org.
CYCLE-NAME is the cycle file name without extension (e.g., self_modification).
Signals an error if the cycle file is not found."
  (let* ((cycles-dir (expand-file-name iar-cycles-path user-emacs-directory))
         (cycle-path (expand-file-name (format "%s.org" cycle-name) cycles-dir)))
    (or (iar--read-file-string cycle-path)
        (error "Cycle '%s' not found at %s" cycle-name cycle-path))))

(defun iar--cycle-for-personality (personality-name)
  "Return the default cycle name for PERSONALITY-NAME.
Looks up `iar-personality-cycle-map'. Returns nil if not in the map."
  (cdr (assoc personality-name iar-personality-cycle-map)))

(defun iar--cycle-load-continue-prompt (_agent-name)
  "Load the shared continue prompt from agents.d/common/agent_cycle_continue.org.
Returns nil if the file is not found (the caller handles the nil case)."
  (ignore-errors (iar--load-prompt "agent_cycle_continue")))


;;; ---------------------------------------------------------
;;; Completion detection utility
;;; ---------------------------------------------------------

(defun iar--cycle-complete-p (&optional buffer start end)
  "Check if BUFFER contains a completion sentinel on its own line.
Returns `loop' if LOOP_COMPLETE is found, `cycle' if CYCLE_COMPLETE is found.
Returns nil if neither is found. Search is case-sensitive.
Sentinel must appear on its own line (surrounded by line boundaries).
If START > END, swaps them. Positions clamped to buffer boundaries.
BUFFER defaults to the current buffer."
  (let ((buf (or buffer (current-buffer))))
    (with-current-buffer buf
      (save-restriction
        (widen)
        (let* ((buf-min (point-min))
               (buf-max (point-max))
               (search-start
                (if (and start end (> start end))
                    buf-min  ; start > end: search entire buffer
                  (min (max (or start buf-min) buf-min) buf-max)))
               (search-end
                (if (and start end (> start end))
                    buf-max
                  (max (min (or end buf-max) buf-max) buf-min)))
               (case-fold-search nil))
          (save-excursion
            (goto-char search-start)
            (cond
             ((re-search-forward "^\\(?:LOOP_COMPLETE\\)\\s-*$" search-end t) 'loop)
             ((re-search-forward "^\\(?:CYCLE_COMPLETE\\)\\s-*$" search-end t) 'cycle)
             (t nil))))))))


(defun iar--cycle-load-profile (agent-name)
  "Load a personality profile for AGENT-NAME using the assembly engine.
Returns the assembled prompt string.
Signals an error if the personality is not found."
  (let* ((archetype (iar--archetype-for-personality agent-name))
         (project (iar--project-for-personality agent-name))
         (result (iar--assemble-prompt archetype agent-name project)))
    (plist-get result :prompt)))

;;; ---------------------------------------------------------
;;; Cycle state and hooks
;;; ---------------------------------------------------------

(defvar iar--cycle-state nil
  "Current cycle state as a plist:
:agent       -- agent name string
:buffer      -- cycle buffer
:continue    -- continue prompt string or nil
:max-turns   -- max LLM turns
:turn-count  -- current turn count
:tool-call-count -- total tool calls made
:completed   -- t when cycle is done
:exit-code   -- 0 for CYCLE_COMPLETE, 1 for timeout/error,
;;               2 for LOOP_COMPLETE (task done, iar.sh stops the loop)")

(defun iar--cycle-make-state (agent buf continue max-turns)
  "Create a fresh cycle state plist."
  (list :agent agent :buffer buf :continue continue :max-turns max-turns
        :turn-count 0 :tool-call-count 0 :completed nil :exit-code 0))

(defun iar--cycle-tool-call-tracker (_tool-name _tool-result)
  "Track tool calls in the cycle. Increments tool-call-count."
  (cl-incf (plist-get iar--cycle-state :tool-call-count)))

(defvar iar--cycle-error-strikes 0
  "Consecutive failed-request strikes in the current cycle.
gptel signals a failed request by passing equal start/end positions
to post-response functions (per gptel.el docs: \"this hook runs even
if the request fails. In this case the response beginning and end
positions are both the cursor position at the time of the
request\"). Three strikes -> abort the cycle. Reset on any
successful response.")

(defun iar--cycle-post-response-handler (start end)
  "Post-response handler for cycle. START and END are buffer positions
delimiting the new response (gptel convention). START == END means the
request FAILED -- count a strike, never resend blindly (the 2026-08-30
storm: 2537 retries of a 404ing model, 1GB of log, because errors were
invisible to this handler and the lenient sentinel match hit the
prompt's own vocabulary every turn).
Wrapped in condition-case to prevent errors from hanging the event loop."
  (condition-case err
      (let* ((state iar--cycle-state)
             (agent (plist-get state :agent))
             (max-turns (plist-get state :max-turns))
             (turn-count (plist-get state :turn-count)))
        (if (and (number-or-marker-p start) (number-or-marker-p end)
                 (= start end))
            ;; ---- FAILED REQUEST PATH ----
            (progn
              (cl-incf iar--cycle-error-strikes)
              (message "[%s] Cycle request FAILED (strike %d/3)"
                       agent iar--cycle-error-strikes)
              (when (>= iar--cycle-error-strikes 3)
                (message "[%s] Three failed requests in a row -- ending cycle" agent)
                (setf (plist-get iar--cycle-state :completed) t)
                (setf (plist-get iar--cycle-state :exit-code) 1)))
          ;; ---- SUCCESS PATH ----
          (setq iar--cycle-error-strikes 0)
          (cl-incf (plist-get iar--cycle-state :turn-count))
          ;; Log ONLY the new response region (not the whole buffer --
          ;; whole-buffer logging grows quadratically with turns)
          (ignore-errors
            (iar--cycle-log-append agent start end))
          ;; Completion signals: search ONLY the new response region
          ;; (iar--cycle-complete-p takes start/end and clamps them)
          (cond
             ((iar--cycle-complete-p (current-buffer) start end)
              ;; Sentinel on its own line in the NEW response only.
              ;; LOOP_COMPLETE = task done -> exit 2 (iar.sh stops the
              ;; loop: "TASK COMPLETE", human review gate).
              ;; CYCLE_COMPLETE = more work next cycle -> exit 0.
              ;; afcbc27 (2026-08-05) collapsed both to 0, silently
              ;; disabling the loop-stop contract; restored 2026-08-31.
              (setf (plist-get iar--cycle-state :completed) t)
              (setf (plist-get iar--cycle-state :exit-code)
                    (if (eq (iar--cycle-complete-p (current-buffer) start end)
                            'loop)
                        2 0)))
             ((>= turn-count max-turns)
              ;; Max turns checked BEFORE any lenient match -- the old
              ;; lenient string-match against the whole buffer matched
              ;; the prompt's own CYCLE_COMPLETE vocabulary every turn,
              ;; making this branch dead code (storm root cause #2)
              (message "[%s] Max turns (%d) reached, ending cycle" agent max-turns)
              (setf (plist-get iar--cycle-state :completed) t)
              (setf (plist-get iar--cycle-state :exit-code) 1))
             (t
              ;; No completion signal, under turn limit -- continue
              (let ((cont-prompt (plist-get state :continue)))
                (if cont-prompt
                    (progn
                      (goto-char (point-max))
                      (insert cont-prompt)
                      (gptel-send))
                  ;; No continue prompt -- end cycle
                  (message "[%s] No continue prompt, ending cycle" agent)
                  (setf (plist-get iar--cycle-state :completed) t)))))))
    (error
     (message "[%s] Cycle post-response error: %s"
              (or (plist-get iar--cycle-state :agent) "unknown")
              (error-message-string err))
     (setf (plist-get iar--cycle-state :completed) t)
     (setf (plist-get iar--cycle-state :exit-code) 1))))

;;; ---------------------------------------------------------
;;; Main entry point
;;; ---------------------------------------------------------

(defun iar--normalize-self-mod (value)
  "Normalize a :self-modification argument VALUE to a boolean.
The shell always passes 0 or 1 (never omits the keyword), and Elisp
truthiness treats 0 as non-nil -- so a bare `(if (null sm) nil sm)'
ENABLED self-modification when the shell said 0.  Privilege
inversion: the safe default was unreachable via iar.sh.  Only nil,
0, and \"0\" mean disabled."
  (not (member value '(nil 0 "0"))))

(defun iar-run-cycle (&rest args)
  "Run one agent cycle in batch mode.
Keywords args:
  :agent NAME       -- personality name (default: \"darwin\")
  :timeout SECONDS  -- override iar-cycle-timeout
  :prompt STRING    -- override the cycle prompt (inline string)
  :cycle NAME       -- cycle name (loads agents.d/cycles/<NAME>.org).
                       Defaults to the personality's mapped cycle
                       (e.g., darwin -> self_modification).
  :self-modification BOOL -- enable self-modification (default: nil)
  :knowledge LABELS -- extra knowledge labels (list of strings),
                       appended to the project's #+KNOWLEDGE.
                       (iar.sh --knowledge passes this; before 2026-08-31
                       the keyword was accepted and silently ignored.)

The archetype is determined by the personality-to-archetype map.
The project is determined by the personality name (matching project file
or \"default\" if no matching project exists).
Knowledge is auto-loaded from the project's #+KNOWLEDGE metadata.
Tools are gated by the project's #+TOOLS metadata."
  (interactive)
  (let* ((agent-name (or (plist-get args :agent) "darwin"))
         (raw-timeout (or (plist-get args :timeout) iar-cycle-timeout))
         (timeout (if (and (integerp raw-timeout) (> raw-timeout 0))
                      raw-timeout
                    7200))
         (cycle-name (or (plist-get args :cycle)
                         (iar--cycle-for-personality agent-name)))
         (prompt (or (plist-get args :prompt)
                     (iar--cycle-load-cycle-prompt cycle-name)))
         (continue-prompt (iar--cycle-load-continue-prompt agent-name))
         (archetype (iar--archetype-for-personality agent-name))
         (project (iar--project-for-personality agent-name))
         (extra-knowledge (plist-get args :knowledge))
         (self-mod (iar--normalize-self-mod
                    (plist-get args :self-modification)))
         (cycle-buf (get-buffer-create (format "*%s-cycle*" agent-name)))
         (max-turns (if (and (integerp iar-cycle-max-turns)
                             (> iar-cycle-max-turns 0))
                        iar-cycle-max-turns
                      40)))
    (message "[%s] Starting cycle with %ds timeout (archetype: %s, project: %s, cycle: %s)"
             agent-name timeout archetype project cycle-name)
    (iar--usage-reset)
    (setq iar--cycle-state (iar--cycle-make-state agent-name cycle-buf continue-prompt max-turns)
          iar--cycle-error-strikes 0)
    (with-current-buffer cycle-buf
      (text-mode)
      (gptel-mode 1)
      ;; Assemble prompt from archetype + personality + project
      (let ((result (iar--setup-assembled-buffer archetype agent-name project extra-knowledge)))
        (message "[%s] Assembled prompt: %d chars (~%d tokens), %d tools"
                 agent-name
                 (length (plist-get result :prompt))
                 (/ (length (plist-get result :prompt)) 4)
                 (length (plist-get result :tools))))
      (setq-local gptel-stream t)
      ;; Self-modification: buffer-local so delegates inherit global nil
      (setq-local iar-guard-allow-self-modification self-mod)

      ;; Install hooks (named functions, idempotent per rule 57)
      (remove-hook 'iar-post-tool-call-functions #'iar--cycle-tool-call-tracker t)
      (add-hook 'iar-post-tool-call-functions #'iar--cycle-tool-call-tracker nil t)
      (remove-hook 'iar-pre-tool-call-functions #'iar--block-unknown-tools t)
      (add-hook 'iar-pre-tool-call-functions #'iar--block-unknown-tools nil t)
      (remove-hook 'iar-post-response-functions #'iar--cycle-post-response-handler t)
      (add-hook 'iar-post-response-functions #'iar--cycle-post-response-handler nil t)

      ;; Insert prompt and send
      (insert prompt)
      (message "[%s] Sending cycle prompt to %s agent..." agent-name agent-name)
      (gptel-send))

    ;; Batch mode event loop: wait until completed or timeout
    (when noninteractive
      (let ((idle-since nil)
            (deadline (time-add nil (seconds-to-time timeout))))
        (while (and (not (plist-get iar--cycle-state :completed))
                   (time-less-p nil deadline))
          (accept-process-output nil 1)
          (if (or (get-buffer-process cycle-buf)
                  ;; gptel curl processes live in their own proc
                  ;; buffers, not the gptel buffer -- check the
                  ;; request alist for active requests instead.
                  (and (boundp 'gptel--request-alist)
                       gptel--request-alist))
              ;; Active request -- reset idle timer
              (setq idle-since nil)
            ;; No active request -- check for idle timeout (real time,
            ;; not loop iterations: accept-process-output returns early
            ;; on any event, so iteration counts are not seconds)
            (unless (plist-get iar--cycle-state :completed)
              (unless idle-since (setq idle-since (current-time)))
              (when (> (time-convert (time-subtract nil idle-since) 'integer) 1800)
                (message "[%s] No active requests for 1800s, exiting" agent-name)
                (setf (plist-get iar--cycle-state :completed) t)))))
        ;; Cycle ended -- log results and exit
        (let ((exit-code (plist-get iar--cycle-state :exit-code))
              (turn-count (plist-get iar--cycle-state :turn-count))
              (tool-call-count (plist-get iar--cycle-state :tool-call-count)))
          (if (plist-get iar--cycle-state :completed)
              (message "[%s] Cycle complete. Turns: %d, Tool calls: %d, Exit: %d%s"
                       agent-name turn-count tool-call-count exit-code
                       (iar--cycle-token-summary))
            (message "[%s] Cycle timed out after %ds. Turns: %d, Tool calls: %d%s"
                     agent-name timeout turn-count tool-call-count
                     (iar--cycle-token-summary)))
          (setq iar--cycle-state nil)
          (kill-emacs exit-code))))))

(provide 'iar-agent-cycle)
;;; ---------------------------------------------------------
;;; One-shot mode
;;; ---------------------------------------------------------

;; Forward-declared: owned by configs/delimiters.el.
(defvar iar-one-shot-response-open nil
  "Opening delimiter for one-shot final response.")
(defvar iar-one-shot-response-close nil
  "Closing delimiter for one-shot final response.")

(defconst iar--one-shot-nudge-prompt
  (format "Continue working on your task. When you are finished, wrap your final response in %s and %s markers."
          iar-one-shot-response-open iar-one-shot-response-close)
  "Nudge prompt sent when a one-shot agent produces a response without delimiters.
Built from the delimiter defcustoms (single source: configs/delimiters.el);
a hardcoded copy here drifted from them the moment either changed.")

(defvar iar--one-shot-state nil
  "Current one-shot state as a plist:
:agent           -- agent name string
:buffer          -- one-shot buffer
:max-turns       -- max LLM turns
:turn-count      -- current turn count
:tool-call-count -- total tool calls made
:completed       -- t when one-shot is done
:exit-code       -- 0 for success, 1 for timeout/error
:final-response  -- extracted response string or nil")

(defun iar--one-shot-make-state (agent buf max-turns)
  "Create a fresh one-shot state plist."
  (list :agent agent :buffer buf :max-turns max-turns
        :turn-count 0 :tool-call-count 0
        :completed nil :exit-code 0 :final-response nil))

(defun iar--one-shot-tool-call-tracker (_tool-name _tool-result)
  "Track tool calls in one-shot mode. Increments tool-call-count."
  (cl-incf (plist-get iar--one-shot-state :tool-call-count)))

(defun iar--one-shot-extract-response (text)
  "Extract content between one-shot delimiters in TEXT.
Returns the extracted string if delimiters are found, nil otherwise.
Finds the first opening delimiter and the last closing delimiter
to handle content that mentions the delimiter text."
  (let ((open-del (or iar-one-shot-response-open "=== BEGIN FINAL RESPONSE ==="))
        (close-del (or iar-one-shot-response-close "=== END FINAL RESPONSE ===")))
    (with-temp-buffer
      (insert text)
      (goto-char (point-min))
      (when (search-forward open-del nil t)
        (let ((start (point)))
          ;; Search for the last occurrence of close-del after start
          (goto-char (point-max))
          (when (search-backward close-del start t)
            (let ((end (point)))
              (string-trim (buffer-substring-no-properties start end)))))))))


(defvar iar--one-shot-error-strikes 0
  "Consecutive failed-request strikes in the current one-shot run.
See `iar--cycle-error-strikes' for the failed-request convention.")

(defun iar--one-shot-post-response-handler (start end)
  "Post-response handler for one-shot mode. START and END are buffer
positions delimiting the new response (gptel convention). START == END
means the request FAILED -- count a strike, three strikes -> abort.
Scans the NEW RESPONSE for one-shot delimiters. If found, extracts
the final response and marks the one-shot as completed. If not found
and under max turns, sends a nudge prompt. If max turns reached,
marks as completed with exit code 1."
  (let* ((state iar--one-shot-state)
         (agent (plist-get state :agent))
         (turn-count (plist-get state :turn-count))
         (max-turns (plist-get state :max-turns)))
    (if (and (number-or-marker-p start) (number-or-marker-p end)
             (= start end))
        ;; ---- FAILED REQUEST PATH ----
        (progn
          (cl-incf iar--one-shot-error-strikes)
          (message "[%s] One-shot request FAILED (strike %d/3)"
                   agent iar--one-shot-error-strikes)
          (when (>= iar--one-shot-error-strikes 3)
            (message "[%s] Three failed requests in a row -- ending one-shot" agent)
            (setf (plist-get iar--one-shot-state :completed) t)
            (setf (plist-get iar--one-shot-state :exit-code) 1)))
      ;; ---- SUCCESS PATH ----
      (setq iar--one-shot-error-strikes 0)
      (cl-incf (plist-get iar--one-shot-state :turn-count))
      ;; Log only the new response region
      (iar--cycle-log-append agent start end)
      ;; Check for delimiters in the NEW RESPONSE only
      (let* ((response (buffer-substring-no-properties
                         (max (point-min) (min start (point-max)))
                         (max (point-min) (min end (point-max)))))
             (extracted (iar--one-shot-extract-response response)))
        (cond
         (extracted
          (setf (plist-get iar--one-shot-state :final-response) extracted)
          (setf (plist-get iar--one-shot-state :completed) t)
          (setf (plist-get iar--one-shot-state :exit-code) 0)
          (message "[%s] One-shot: final response detected (%d chars)"
                   agent (length extracted)))
         ((>= turn-count max-turns)
          (message "[%s] One-shot: max turns (%d) reached without final response"
                   agent max-turns)
          (setf (plist-get iar--one-shot-state :completed) t)
          (setf (plist-get iar--one-shot-state :exit-code) 1))
         (t
          ;; No delimiters, under turn limit -- send nudge
          (goto-char (point-max))
          (insert iar--one-shot-nudge-prompt)
          (gptel-send)))))))

(defun iar-run-one-shot (&rest args)
  "Run a one-shot agent in batch mode.
Sends a single instruction to an agent, waits for it to produce a
final response (between delimiters), extracts it, and prints to stdout.

Keywords args:
  :agent NAME       -- personality name (default: \"mirror\")
  :timeout SECONDS  -- timeout in seconds (default: 7200)
  :self-modification BOOL -- enable self-modification (default: nil)

The prompt text is read from the IAR_ONE_SHOT_PROMPT environment variable.
The archetype is forced to \"one-shot\" (not from the personality map).
The project is determined by the personality name.
Knowledge is auto-loaded from the project's #+KNOWLEDGE metadata.
Tools are gated by the project's #+TOOLS metadata."
  (interactive)
  (let* ((agent-name (or (plist-get args :agent) "mirror"))
         (raw-timeout (or (plist-get args :timeout) 7200))
         (timeout (if (and (integerp raw-timeout) (> raw-timeout 0))
                      raw-timeout
                    7200))
         (prompt (getenv "IAR_ONE_SHOT_PROMPT"))
         (archetype "one-shot")
         (project (iar--project-for-personality agent-name))
         (self-mod (iar--normalize-self-mod
                    (plist-get args :self-modification)))
         (os-buf (get-buffer-create (format "*%s-oneshot*" agent-name)))
         (max-turns (if (and (integerp iar-cycle-max-turns)
                             (> iar-cycle-max-turns 0))
                        iar-cycle-max-turns
                      40)))
    (unless (and prompt (not (string-empty-p (string-trim prompt))))
      (message "[%s] One-shot: no prompt provided (IAR_ONE_SHOT_PROMPT env var is empty)"
               agent-name)
      (kill-emacs 1))
    (message "[%s] Starting one-shot with %ds timeout (archetype: %s, project: %s)"
             agent-name timeout archetype project)
    (iar--usage-reset)
    (setq iar--one-shot-state (iar--one-shot-make-state agent-name os-buf max-turns))
    (with-current-buffer os-buf
      (text-mode)
      (gptel-mode 1)
      ;; Assemble prompt from one-shot archetype + personality + project
      (let ((result (iar--setup-assembled-buffer archetype agent-name project)))
        (message "[%s] Assembled prompt: %d chars (~%d tokens), %d tools"
                 agent-name
                 (length (plist-get result :prompt))
                 (/ (length (plist-get result :prompt)) 4)
                 (length (plist-get result :tools))))
      (setq-local gptel-stream t)
      ;; Self-modification: buffer-local so delegates inherit global nil
      (setq-local iar-guard-allow-self-modification self-mod)

      ;; Install hooks (named functions, idempotent per rule 57)
      (remove-hook 'iar-post-tool-call-functions #'iar--one-shot-tool-call-tracker t)
      (add-hook 'iar-post-tool-call-functions #'iar--one-shot-tool-call-tracker nil t)
      (remove-hook 'iar-pre-tool-call-functions #'iar--block-unknown-tools t)
      (add-hook 'iar-pre-tool-call-functions #'iar--block-unknown-tools nil t)
      (remove-hook 'iar-post-response-functions #'iar--one-shot-post-response-handler t)
      (add-hook 'iar-post-response-functions #'iar--one-shot-post-response-handler nil t)

      ;; Insert prompt and send
      (insert prompt)
      (message "[%s] Sending one-shot prompt to %s..." agent-name agent-name)
      (gptel-send))

    ;; Batch mode event loop: wait until completed or timeout
    (when noninteractive
      (let ((idle-since nil)
            (deadline (time-add nil (seconds-to-time timeout))))
        (while (and (not (plist-get iar--one-shot-state :completed))
                   (time-less-p nil deadline))
          (accept-process-output nil 1)
          (if (or (plist-get iar--one-shot-state :completed)
                  (get-buffer-process os-buf)
                  (and (boundp 'gptel--request-alist)
                       gptel--request-alist))
              ;; Active request -- reset idle timer
              (setq idle-since nil)
            ;; No active process -- check for idle timeout (real time,
            ;; not loop iterations: accept-process-output returns early
            ;; on any event, so iteration counts are not seconds)
            (progn
              (unless idle-since (setq idle-since (current-time)))
              (when (> (time-convert (time-subtract nil idle-since) 'integer) 1800)
                (message "[%s] One-shot: no active requests for 1800s, exiting"
                         agent-name)
                (setf (plist-get iar--one-shot-state :completed) t)))))
        ;; Timeout check: if deadline passed and not completed, ask for summary
        (when (and (not (plist-get iar--one-shot-state :completed))
                   (not (time-less-p nil deadline)))
          (message "[%s] One-shot: timeout reached, requesting summary..." agent-name)
          (let ((summary-prompt "Time limit reached. Stop all tool calls immediately. Summarize all findings so far and wrap your summary in === BEGIN FINAL RESPONSE === and === END FINAL RESPONSE === markers. Include all vulnerabilities discovered, even partial ones."))
            (with-current-buffer os-buf
              (goto-char (point-max))
              (insert summary-prompt)
              (gptel-send)))
          ;; Wait up to 120s for the summary response
          (let ((summary-deadline (time-add nil (seconds-to-time 120))))
            (while (and (not (plist-get iar--one-shot-state :completed))
                        (time-less-p nil summary-deadline))
              (accept-process-output nil 1))))
        ;; One-shot ended -- print result and exit
        (let ((exit-code (plist-get iar--one-shot-state :exit-code))
              (turn-count (plist-get iar--one-shot-state :turn-count))
              (tool-call-count (plist-get iar--one-shot-state :tool-call-count))
              (final-response (plist-get iar--one-shot-state :final-response)))
          (if (plist-get iar--one-shot-state :completed)
              (message "[%s] One-shot complete. Turns: %d, Tool calls: %d, Exit: %d%s"
                       agent-name turn-count tool-call-count exit-code
                       (iar--cycle-token-summary))
            (message "[%s] One-shot timed out after %ds. Turns: %d, Tool calls: %d%s"
                     agent-name timeout turn-count tool-call-count
                     (iar--cycle-token-summary)))
          ;; Print final response to stdout (clean output)
          ;; On timeout with no final-response, extract whatever is in the buffer
          (if final-response
              (princ (format "=== BEGIN FINAL RESPONSE ===\n%s\n=== END FINAL RESPONSE ===" final-response))
            (let ((buf-content (with-current-buffer os-buf
                                 (buffer-substring-no-properties (point-min) (point-max)))))
              (when (and buf-content (> (length buf-content) 0))
                (princ buf-content))))
          (setq iar--one-shot-state nil)
          (kill-emacs exit-code))))))