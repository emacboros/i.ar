;; -*- lexical-binding: t; -*-

;;; Tool Result Timestamping -- Time Perception for Agents
;;
;; Adds a wall-clock timestamp to every tool result before it enters
;; the conversation buffer. The agent sees WHEN each tool call
;; completed, giving it a sense of elapsed time between actions --
;; the difference between operating blind in time and knowing that
;; 40 minutes passed between one file read and the next.
;;
;; This module hooks into the tool call layer via advice on
;; gptel--process-tool-call (installed in iar-tool-call.el's
;; truncation advice chain). It runs BEFORE truncation so the
;; timestamp is always visible even in truncated results.
;;
;; Format: [HH:MM:SS] -- 8 chars + brackets, minimal token cost,
;; human-readable, no date (session-scoped; date is in the prompt
;; and audit log).
;;
;; Config: configs/tool-limits.el owns iar-tool-result-timestamps (nil to
;; disable).

(require 'iar-utils)

;; Owned by configs/tool-limits.el. Loaded via (load ...) in init.el -- the
;; config files are loaded by filename, not by feature name (configs
;; don't follow the filename=feature convention). Forward-declare the
;; variable so standalone loads work even without the config loaded.
(defvar iar-tool-result-timestamps nil
  "When non-nil, prepend wall-clock timestamps to tool results.
Owned by configs/tool-limits.el.")

(defun iar--timestamp-tool-result (result)
  "Prepend a wall-clock timestamp to RESULT if enabled.
Returns RESULT unchanged when disabled, non-string, or already
timestamped (idempotent -- advice may run twice on the same result)."
  (if (or (null iar-tool-result-timestamps)
          (not (stringp result))
          (string-prefix-p "[" result))
      result
    (format "[%s] %s" (format-time-string "%H:%M:%S") result)))

(defun iar--timestamp-tool-result-advice (orig-fun fsm tool-spec tool-call result)
  "Around advice on `gptel--process-tool-call'.
Timestamps RESULT before truncation, then delegates to ORIG-FUN."
  (let* ((stamped (iar--timestamp-tool-result result))
         (ret (funcall orig-fun fsm tool-spec tool-call stamped)))
    ret))

(defun iar--timestamp-setup ()
  "Install timestamp advice. Idempotent."
  (advice-remove 'gptel--process-tool-call #'iar--timestamp-tool-result-advice)
  (advice-add 'gptel--process-tool-call :around #'iar--timestamp-tool-result-advice))

(iar--timestamp-setup)

(provide 'iar-tool-result-timestamp)