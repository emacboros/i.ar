;; -*- lexical-binding: t; -*-

;; =============================================================================
;; Agent Cycle Parameters
;; =============================================================================

(defcustom iar-cycle-timeout 7200
  "Default timeout for an agent cycle in seconds (120 minutes)."
  :type 'integer
  :safe (lambda (v) (and (integerp v) (> v 0)))
  :group 'iar)

(defcustom iar-cycle-max-turns 40
  "Maximum number of LLM response turns before forcing cycle end.
Each turn is one model response (with or without tool calls).
This prevents infinite loops."
  :type 'integer
  :safe (lambda (v) (and (integerp v) (> v 0)))
  :group 'iar)

(provide 'iar-config-cycle)