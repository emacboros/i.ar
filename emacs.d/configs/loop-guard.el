;; -*- lexical-binding: t; -*-

(require 'iar-config-predicates)

;; =============================================================================
;; Loop Guard Parameters
;; =============================================================================

(defcustom iar-loop-soft-threshold 3
  "Number of identical consecutive tool calls before soft-blocking.
After this many repetitions, the tool call is blocked and a
correction message is sent to the LLM instead of executing."
  :type 'integer
  :safe #'iar--positive-integer-p
  :group 'iar)

(defcustom iar-loop-hard-threshold 6
  "Number of identical consecutive tool calls before hard-stopping.
After this many repetitions, the entire request is stopped.
Should be >= 2x the soft threshold to give the model a chance to
self-correct after the first warning.
If set <= `iar-loop-soft-threshold', the effective hard
threshold is automatically raised to soft+1 to ensure at least
one soft warning before hard-stopping."
  :type 'integer
  :safe #'iar--positive-integer-p
  :group 'iar)

(defcustom iar-loop-history-size 20
  "Maximum number of tool calls to keep in the history ring."
  :type 'integer
  :safe #'iar--positive-integer-p
  :group 'iar)

(provide 'iar-config-loop-guard)
(defcustom iar-loop-guard-chain-similarity 0.5
  "Minimum token-set Jaccard similarity between consecutive
same-tool calls' args for the chain guard to count them as one
chain. Below this, the newer call is a NEW QUESTION and the chain
counter resets (convergence reset, 2026-09-03: five witness sets
of legitimate converging investigation -- ssh -> curl -> grep --
blocked by the tool-name counter). Calibrated on production
shapes: canonical iterators score high (tail -N vs tail -M: 1.0;
git-log paging: ~0.67); same-host different-command investigation
is borderline (~0.5-0.7); tool-switching investigation ~0.07.
One-char tokens (the iterator's changing counter) are dropped
before comparison: the counter is noise, the shape is the signal."
  :type 'float
  :safe #'iar--unit-float-or-nil-p
  :group 'iar)