;; -*- lexical-binding: t; -*-

;;; Text-Mode Tool Call Detector -- the channel-switch witness
;;
;; Finding (2026-09-01, Aevum cycle 80): a model can switch from the
;; API's native JSON tool-call channel to the transcript's markdown
;; channel. The response then contains a ``` tool block (or a
;; self-timestamped receipt line) as PLAIN TEXT, with zero native
;; tool_calls. gptel's parser is correct per its contract -- there is
;; nothing to parse -- and the tick is indistinguishable from a
;; successful chat tick. The model may even hallucinate the tool
;; result ("Success: File written...") because the transcript taught
;; it what success looks like.
;;
;; This module makes that failure VISIBLE:
;; 1. Detects text-mode tool blocks in the response text (``` blocks
;;    whose first line looks like a tool invocation, and fake receipt
;;    lines matching the transcript's own Success format).
;; 2. Logs a REQUESTS.log line (the witness the agent can read).
;; 3. Fires iar-text-mode-detected-functions so the loop layer can
;;    inject a correction note next tick.
;;
;; Detection is heuristic by design: false positives are cheap (a log
;; line), false negatives are the silent failure we are guarding.
;; A response that MENTIONS tool syntax in prose may match; the
;; correction note is advisory, not blocking.

(require 'cl-lib)

;;; ---------------------------------------------------------
;;; Configuration
;;; ---------------------------------------------------------

(defcustom iar-text-mode-detect-enabled t
  "When non-nil, scan responses for text-mode tool blocks.
Runs in the post-response path; cost is two regex searches over the
new response text."
  :type 'boolean
  :safe #'booleanp
  :group 'iar)

(defcustom iar-text-mode-max-report 3
  "Maximum text-mode blocks reported per response (log noise cap)."
  :type 'integer
  :safe #'iar--positive-integer-or-nil-p
  :group 'iar)

;;; ---------------------------------------------------------
;;; Hook for the loop layer
;;; ---------------------------------------------------------

(defvar iar-text-mode-detected-functions nil
  "Hook run when text-mode tool blocks are detected in a response.
Each function receives (COUNT SNIPPETS) where COUNT is the number of
detected blocks and SNIPPETS is a list of trimmed first-line strings.
Runs in the conversation buffer, after the response is recorded.
The cycle layer uses this to inject an advisory note next tick.")

;;; ---------------------------------------------------------
;;; Detection
;;; ---------------------------------------------------------

;; First line of a fenced block that looks like a tool call:
;;   tool-name: {...}          (iar transcript style)
;;   tool-name(...)            (prose-call style)
;;   write_file / execute_code / read_file etc. bare
;; Deliberately loose: a fenced block starting with a known-ish tool
;; verb is the signal; we are not parsing arguments here.
(defconst iar-text-mode--tool-line-re
  (concat
   "\\([a-z][a-z0-9_-]\\{2,30\\}\\)"    ; tool-ish name (braces escaped: Emacs regexp)
   "[ \t]*[:()]")                          ; call syntax
  "Regexp matching a fenced-block first line that looks like a tool call.")

;; The receipt line the transcript format teaches: a timestamped
;; Success/Error line inside the model's own text output, exactly the
;; format iar-tool-result-timestamp prepends to real results.
(defconst iar-text-mode--receipt-re
  "^[ \t]*\\[[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\} [0-9]\\{2\\}:[0-9]\\{2\\}:[0-9]\\{2\\}\\][ \t]+\\(Success\\|Error\\|Error:\\)"
  "Regexp matching a self-generated tool-result receipt line.")

(defun iar-text-mode--scan-region (start end)
  "Scan START..END for text-mode tool blocks and receipt lines.
Returns (COUNT . SNIPPETS); snippets are first-line strings, capped
at `iar-text-mode-max-report'."
  (let ((count 0)
        (snippets nil)
        (cap (or iar-text-mode-max-report 3)))
    (save-excursion
      (save-restriction
        (narrow-to-region start end)
        (goto-char (point-min))
        ;; Fenced blocks
        (while (and (< count cap)
                    (re-search-forward "^```[ \t]*\\([a-z0-9_-]*\\)[ \t]*$" nil t))
          (let* ((lang (match-string 1))
                 (block-start (match-end 0))
                 (block-end (or (and (re-search-forward "^```" nil t)
                                     (match-beginning 0))
                                (point-max)))
                 (first-line (progn
                               ;; After the fence-line match, point sits at
                               ;; the END of the fence line itself --
                               ;; line-end-position is that same line's end
                               ;; (empty substring). Move to the block's
                               ;; first CONTENT line before extracting.
                               (goto-char block-start)
                               (forward-line 1)
                               (buffer-substring
                                (point)
                                (min block-end
                                     (line-end-position)
                                     (+ (point) 200))))))
            (when (or (and (stringp lang)
                           (not (string-empty-p lang))
                           (member lang '("tool" "tools" "json" "elisp" "emacs-lisp")))
                      ;; Unlabeled fence: fall back to the first-line
                      ;; heuristic. Labeled non-tool languages (bash,
                      ;; python, ...) are NOT scanned -- print( in a
                      ;; ```python block is code, not a tool call
                      ;; (false positive found by test, cycle 118).
                      (and (stringp lang)
                           (string-empty-p lang)
                           (with-temp-buffer
                             (insert first-line)
                             (goto-char (point-min))
                             (re-search-forward iar-text-mode--tool-line-re nil t))))
              (cl-incf count)
              (push (string-trim
                     (car (split-string first-line "\n"))) snippets))
            (goto-char block-end)))
        ;; Receipt lines (outside the cap -- receipts are the stronger signal)
        (goto-char (point-min))
        (while (and (< count cap)
                    (re-search-forward iar-text-mode--receipt-re nil t))
          (cl-incf count)
          (push (string-trim
                 (buffer-substring (line-beginning-position)
                                   (min (line-end-position)
                                        (+ (line-beginning-position) 160)))
                 ) snippets))))
    (cons count (nreverse snippets))))

;;; ---------------------------------------------------------
;;; Post-response integration
;;; ---------------------------------------------------------

(defun iar--text-mode-post-response (start end)
  "Post-response hook: scan the new response region START..END.
START == END (failed request) is skipped -- nothing to scan.
Logs to REQUESTS.log via iar--reqlog-append and fires the hook."
  (when (and iar-text-mode-detect-enabled
             (number-or-marker-p start) (number-or-marker-p end)
             (< start end))
    (condition-case err
        (let* ((res (iar-text-mode--scan-region start end))
               (count (car res))
               (snippets (cdr res)))
          (when (> count 0)
            ;; The witness: REQUESTS.log survives even when the
            ;; conversation buffer is truncated or the model forgets.
            (ignore-errors
              (iar--reqlog-append
               "TEXT-MODE-DETECT blocks=%d snippets=%S"
               count snippets))
            (message "[text-mode-detector] %d text-mode tool block(s) in response"
                     count)
            (run-hook-with-args 'iar-text-mode-detected-functions
                                count snippets)))
      (error
       (message "[text-mode-detector] scan failed: %s"
                (error-message-string err))))))

(defun iar--text-mode-setup ()
  "Install the detector on the i.ar post-response bridge.
Idempotent. Runs after iar-tool-call's bridge, which passes through
gptel's (status info) -- but the cycle handler convention is
buffer positions, so we hook the gptel-level post-response path
with the same convention the cycle handler uses: the bridge runs
iar-post-response-functions with (status info); the CYCLE handler
uses positions. To stay decoupled, we hook gptel-post-response-
functions directly here with our own position-capturing wrapper."
  ;; gptel-post-response-functions receive (response info); the fork's
  ;; cycle handler receives positions from a different hook. The
  ;; position-delimited region is what the cycle layer already logs;
  ;; we reuse that convention by hooking the SAME gptel hook the
  ;; bridge uses, and resolving positions from the response text.
  (add-hook 'gptel-post-response-functions
            #'iar--text-mode-gptel-post-response))

(defvar iar--text-mode-last-response nil
  "Last response text seen by the gptel post-response hook.
Set by `iar--text-mode-gptel-post-response'; consumed by the
position-based scan when the cycle layer calls us.")

(defun iar--text-mode-gptel-post-response (response _info)
  "gptel post-response hook: capture RESPONSE text for scanning.
The actual scan runs in `iar--text-mode-scan-last' so the cycle
layer can call it with its own timing; but for interactive use we
scan immediately when the response is a string."
  (setq iar--text-mode-last-response response)
  (when (stringp response)
    (with-temp-buffer
      (insert response)
      (iar--text-mode-post-response (point-min) (point-max)))))

(iar--text-mode-setup)

(provide 'iar-text-mode-detector)
