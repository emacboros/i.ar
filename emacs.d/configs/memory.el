;; -*- lexical-binding: t; -*-

(require 'iar-config-predicates)

;; =============================================================================
;; Personal File Injection Parameters
;; =============================================================================

(defcustom iar-personal-file-max-lines 120
  "Maximum number of lines to inject from memory files (LOGS.md and
JOURNAL.org for interactive, STATE.org for autonomous/continuous) into
an agent's system prompt. DIGEST.md is exempt -- it is always injected
in full because it is the curated identity index.
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