;; -*- lexical-binding: t; -*-

(require 'iar-config-predicates)

;; =============================================================================
;; Agent Cycle Parameters
;; =============================================================================

(defcustom iar-cycle-timeout 7200
  "Default timeout for an agent cycle in seconds (120 minutes)."
  :type 'integer
  :safe #'iar--positive-integer-p
  :group 'iar)

(defcustom iar-cycle-max-turns 120
  "Maximum number of LLM response turns before forcing cycle end.
Each turn is one model response (with or without tool calls).
This prevents infinite loops. Raised 40 -> 120 (2026-09-09, Nacho:
cycle performance degraded vs interactive; headroom available).
Measured: continuo's best cycle in the 09-09 log ran 85 turns --
the old 40 killed that shape. Pathology is owned by the loop
guard, the output-runaway guards and the context breaker; this
is the absolute bound only."
  :type 'integer
  :safe #'iar--positive-integer-p
  :group 'iar)

(provide 'iar-config-cycle)