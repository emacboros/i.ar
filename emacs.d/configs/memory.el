;; -*- lexical-binding: t; -*-

(require 'iar-config-predicates)

;; =============================================================================
;; Personal File Injection Parameters
;; =============================================================================

(defcustom iar-personal-file-max-lines 100
  "Maximum number of lines to inject from memory files (LOGS.md for interactive,
STATE.org for autonomous/continuous) into an agent's system prompt.
When a personal file exceeds this many lines, only the last N lines are
injected (most recent content), with a truncation notice prepended.
The full file remains on disk for reference -- this only affects what
goes into the LLM context window.
Set to nil to disable truncation (inject full file regardless of size)."
  :type '(choice (integer :tag "Max lines to inject")
                 (const :tag "No limit" nil))
  :safe #'iar--positive-integer-or-nil-p
  :group 'iar)

(provide 'iar-config-memory)