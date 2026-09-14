;; -*- lexical-binding: t; -*-

(require 'iar-config-predicates)

;; =============================================================================
;; Delegate Tool Parameters
;; =============================================================================

(defcustom iar-delegate-max-depth 3
  "Maximum delegation depth allowed.
Prevents infinite recursion while permitting multi-hop chains.
Depth 0 = top-level agent, 1 = first delegate, etc."
  :type 'integer
  :safe #'iar--positive-integer-p
  :group 'iar)

(defcustom iar-delegate-max-turns 15
  "Maximum number of LLM response turns for a delegate session.
When the sub-agent produces a text-only response (no tool calls
in the current turn), it is re-prompted to continue.
This prevents models that describe tool calls in text instead of
actually calling them from terminating prematurely."
  :type 'integer
  :safe #'iar--positive-integer-p
  :group 'iar)

(provide 'iar-config-delegate)
(defcustom iar-delegate-drain-grace 300
  "Seconds a timed-out delegate may keep streaming before hard abort.
Fix-2 (c312): when a delegate's timeout fires while its pipeline is
still live, the timeout handler DRAINS (waits for the in-flight
request to finish, letting the completion hook deliver the real
result) for at most this many seconds. Past the grace, the c149
abort path applies. Bounds the worst case at delegate-timeout +
grace per delegate."
  :type 'integer
  :safe #'iar--positive-integer-p
  :group 'iar)
