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

(defcustom iar-delegate-drain-notlive-confirm 3
  "Consecutive not-live seconds required before the drain aborts.
c300 (2026-09-24, timeout-fork-guard): the drain's live-check has a
structural hole -- a LIVE delegate is briefly not-live between turns
(tool execution, the 1s re-prompt timer). One negative sample hit
that gap and the c149 abort fired while the delegate's own next
request was already starting (continuo 09-23 11:53:33Z: -93 PARSE
and -94 START in the same second; the abort raced the gap, the
parent re-sent while the implementer kept running -- the fork).
A single negative sample is not proof of death when the probed
thing has known gaps in its liveness signal. The drain now requires
this many CONSECUTIVE not-live ticks (1s each) before concluding
the delegate is really dead. The drain grace still bounds the
total wait. Law: LIVE-CHECK-NEEDS-CONFIRMATION."
  :type 'integer
  :safe #'iar--positive-integer-p
  :group 'iar)

(defcustom iar-delegate-abort-reprompts 2
  "Maximum number of re-prompts after a GUARD-ABORTED turn.
c71 (2026-09-18): the thinking-loop guard aborts a runaway reasoning
stream (correct), but the delegate completion hook's case 2b saw the
aborted turn as an ordinary text-only response and re-prompted with
the GENERIC continue prompt. The model restarted thinking from
scratch, ran away again, was aborted again: 16 turns = 16 aborts,
~380k tokens, one review never delivered (aria c71 census). Law 41:
when the guard fires, change the QUESTION. An aborted turn now gets
an abort-aware re-prompt (names the abort, demands content-first)
and counts a strike against this cap; past the cap the delegate
ends LOUD (reasoning-only exhaustion). Generic text-only turns
still use the plain continue prompt and iar-delegate-max-turns."
  :type 'integer
  :safe #'iar--positive-integer-p
  :group 'iar)

(provide 'iar-config-delegate)
