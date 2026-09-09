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
Measured (2026-09-09): continuo's deepest 24h cycle ran 85
REQUESTS -- the turn guard counts final responses only (c39: the
tool loop never reaches DONE), so tool-heavy cycles legally
exceed this cap and the binding fences were the 120-call cap and
the 30-min wall. Raised with them so prose-heavy deep cycles are
not the next fence to kill good work. Pathology is owned by the
loop guard, the output-runaway guards and the context breaker;
this is the absolute bound only."
  :type 'integer
  :safe #'iar--positive-integer-p
  :group 'iar)

(provide 'iar-config-cycle)