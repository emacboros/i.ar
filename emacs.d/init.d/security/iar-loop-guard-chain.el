;; -*- lexical-binding: t; -*-

;;; Loop Guard Chain -- Detect same-tool chains with varying arguments
;;
;; Companion to `iar-loop-guard' (which catches identical calls).
;; This guard catches ITERATOR patterns: the same tool called many
;; times in a row with DIFFERENT arguments each time -- paging a log
;; one window per call, walking a list one index per call. Every call
;; looks new to the identical-args guard; the pattern still burns
;; tokens without converging (the 489-round-trip git-log walk, 2026-09-02).
;;
;; CONVERGENCE RESET (2026-09-03, five witness sets): the counter
;; counts the TOOL, but iterator patterns and converging investigation
;; are different behaviors that share a tool. Iterators share long
;; common prefixes (tail -1, tail -2, tail -3; git log paging);
;; converging investigation has DISSIMILAR args (ssh systemctl, then
;; curl headers, then grep journalctl -- all "execute_code_local" to
;; a tool-name counter). Similarity is measured on token-set Jaccard
;; of the printed args: canonical iterators score high (tail -N vs
;; tail -M: 1.0; git-log paging: ~0.67); same-host different-command
;; investigation is borderline (~0.5-0.7: the ssh wrapper dominates
;; short command sets -- but a genuinely different next command
;; breaks the chain one step later, so the count self-corrects);
;; tool-switching investigation ~0.07. When
;; a same-tool call's args are dissimilar from the previous same-tool
;; call's args, the chain counter resets: the iterator keeps its
;; monotone count, the investigator gets its counter wiped.
;;
;; SOFT threshold: after N consecutive same-tool calls, block with a
;; correction message (the model can self-correct).
;; HARD threshold: after 2x soft, stop the request entirely.
;;
;; Semantics chosen deliberately (differential-tested):
;; - This guard keeps its OWN history ring (`iar--chain-history') with
;;   the raw args retained, because the identical guard's ring stores
;;   only the args md5 -- similarity cannot be measured on a hash.
;;   The identical guard's ring and behavior are untouched.
;; - The identical-args guard runs FIRST (hook order) and blocks
;;   identical repeats; when it blocks, the bridge short-circuits and
;;   this guard never sees the call, so blocked identical retries do
;;   not count toward a chain (different failure class, different
;;   guard).
;; - When THIS guard blocks, the call is already recorded in
;;   `iar--chain-history' (push happens at hook entry, before
;;   counting): a blocked call retried with new args still
;;   demonstrates the chain pattern.
;; - Calls the identical guard allowed (below its soft threshold) DO
;;   appear here. A trailing run identical to THIS call is dropped
;;   before counting (the identical guard's domain). An identical run
;;   that differs from this call counts toward the chain exactly as
;;   the previous implementation counted it -- bounded in production:
;;   the identical guard blocks such runs at its own soft threshold,
;;   so at most 2 identical calls can precede a chain count.
;;
;; HOOK ORDER IS LOAD-BEARING (2026-09-03 frozen-at-soft bug): this
;; guard MUST run AFTER `iar--loop-guard', not before. add-hook
;; prepends by default, so registering with APPEND (t) is what makes
;; the documented order true. With the wrong order the chain guard
;; counts before the identical guard pushes, a blocked call never
;; enters history, the chain count freezes at exactly the soft
;; threshold, and the hard stop is unreachable -- the model can retry
;; a blocked call forever, burning one full-context request per
;; retry (observed live 2026-09-03 06:26-06:28: ~50 soft blocks in
;; ~2.5 minutes, zero escalation, model escaped only by switching
;; tools). See test-chain-guard-escalates-through-bridge.

(require 'cl-lib)
(require 'subr-x)
(require 'iar-tool-call)
(require 'iar-prompt-loader)

;;; --- Configuration ---
;; Thresholds live in configs/ split parameter files like the rest of
;; the loop guard parameters. Defaults here are the fallback.

(defvar iar-loop-guard-chain-soft 10
  "Consecutive same-tool calls (different args) before soft block.
Must be higher than `iar-loop-soft-threshold' -- a chain of
identical calls is the identical guard's job; this guard only
wants patterns that LOOK different call to call.")

(defvar iar-loop-guard-chain-hard 20
  "Consecutive same-tool calls before hard stop.")

(defvar iar-loop-guard-chain-similarity 0.5
  "Minimum token-set Jaccard similarity between consecutive
same-tool calls' args for them to count as one chain.
Below this, the newer call is a NEW QUESTION and the chain counter
resets (convergence reset). Calibrated on production shapes:
canonical iterators score high (tail -N vs tail -M: 1.0; git-log
paging: ~0.67); same-host different-command investigation is
borderline (~0.5-0.7); tool-switching investigation ~0.07. One-char
tokens (the iterator's changing counter) are dropped before
comparison: the counter is noise, the shape is the signal.")

(defvar-local iar--chain-history nil
  "Buffer-local ring of this guard's own call records.
Each entry is (NAME MD5 ARGS): tool name, args md5 (matching the
identical guard's signature, for identical-run skipping), and the
raw args plist (for similarity measurement). Most recent first.
Trimmed to `iar-loop-history-size'.")

;;; --- Args similarity ---

(defun iar--chain-args-tokens (args)
  "Tokenize ARGS for similarity comparison.
Prints the args plist and splits on non-word chars; drops tokens
shorter than 2 chars (the iterator's changing counter is noise;
the shared shape is the signal). Returns a list of downcased strings."
  (let ((print-circle nil)
        (print-level nil)
        (print-length nil))
    (cl-loop for tok in (split-string
                         (downcase (prin1-to-string args))
                         "[^a-z0-9]+")
             when (>= (length tok) 2)
             collect tok)))

(defun iar--chain-args-similar-p (args-a args-b)
  "Non-nil when ARGS-A and ARGS-B are similar enough to be the
same investigation: token-set Jaccard at least
`iar-loop-guard-chain-similarity'. Empty token sets on either side
count as similar (conservative: never reset on unparseable args)."
  (let* ((ta (iar--chain-args-tokens args-a))
         (tb (iar--chain-args-tokens args-b))
         (union (cl-union ta tb :test #'equal)))
    (if (or (null ta) (null tb) (null union))
        t
      (let ((inter (cl-intersection ta tb :test #'equal))
            ;; Defensive read: nil/non-float/out-of-range config falls
            ;; back to the 0.5 default (same shape as the threshold
            ;; guards in the hook).
            (threshold (if (and (floatp iar-loop-guard-chain-similarity)
                                (>= iar-loop-guard-chain-similarity 0.0)
                                (<= iar-loop-guard-chain-similarity 1.0))
                           iar-loop-guard-chain-similarity
                         0.5)))
        (>= (/ (float (length inter)) (length union))
            threshold)))))

;;; --- Hook function ---

(defun iar--loop-guard-chain (info)
  "Pre-tool-call hook: detect same-tool chains with different args.
INFO is the plist from `gptel-pre-tool-call-functions'.

Returns nil to allow, (:block MSG) to block with a correction,
or (:stop t :stop-reason REASON) to stop the request."
  (let* ((name (plist-get info :name))
         (args (plist-get info :args))
         (md5 (iar--loop-args-sig args)))
    ;; Record the call in this guard's own ring BEFORE counting:
    ;; a blocked call that is retried with new args still
    ;; demonstrates the chain pattern (documented semantics).
    (push (list name md5 args) iar--chain-history)
    (let ((max-size (if (and (integerp iar-loop-history-size)
                             (> iar-loop-history-size 0))
                        iar-loop-history-size
                      20)))
      (when (> (length iar--chain-history) max-size)
        (setq iar--chain-history
              (cl-subseq iar--chain-history 0 max-size))))
    ;; Count backwards from the entry BEFORE this call. prev-args
    ;; starts as THIS call's args: similarity is judged between
    ;; consecutive calls, walking most-recent-first.
    (let ((chain 0)
          (prev-args args)
          (hist (cdr iar--chain-history)))
      ;; Skip a trailing run of identical calls (the identical
      ;; guard's domain): they neither count toward the chain nor
      ;; break it.
      (while (and hist
                  (equal (caar hist) name)
                  (equal (nth 1 (car hist)) md5))
        (setq hist (cdr hist)))
      ;; Count while same tool AND each successive call's args are
      ;; SIMILAR to the previous call's args. A dissimilar-args call
      ;; is a new question: stop counting there (convergence reset).
      ;; Iterator patterns have similar args (long common prefixes)
      ;; and keep their monotone count.
      (while (and hist
                  (equal (caar hist) name))
        (let ((entry-args (nth 2 (car hist))))
          (if (and prev-args
                   (not (iar--chain-args-similar-p prev-args entry-args)))
              ;; Dissimilar: the chain broke here.
              (setq hist nil)
            (setq chain (1+ chain)
                  prev-args entry-args
                  hist (cdr hist)))))
      ;; Total chain length including this call.
      (setq chain (1+ chain))
      ;; let* (not let): final-hard references the sibling bindings.
      (let* ((effective-soft
              (let ((s iar-loop-guard-chain-soft))
                (if (and (integerp s) (> s 0)) s 10)))
             (effective-hard
              (let ((h iar-loop-guard-chain-hard))
                (if (and (integerp h) (> h 0)) h 20)))
             ;; Ensure hard > soft so the model always gets a warning.
             (final-hard (max effective-hard (1+ effective-soft))))
        (cond
         ((>= chain final-hard)
          (let ((reason (format (iar--load-prompt "loop_chain_stop")
                                name chain)))
            (message "[loop-guard-chain] HARD STOP: %s chained %d times" name chain)
            (list :stop t :stop-reason reason)))
         ((>= chain effective-soft)
          (let ((msg (format (iar--load-prompt "loop_chain_block")
                             name chain name)))
            (message "[loop-guard-chain] SOFT BLOCK: %s chained %d times" name chain)
            (list :block msg)))
         (t nil))))))

;;; --- Setup ---

(defun iar--loop-guard-chain-setup ()
  "Register the chain guard AFTER the identical-args guard.
The APPEND argument is load-bearing: add-hook prepends by default,
which would put this guard BEFORE `iar--loop-guard' in the hook
list. The bridge (`run-hook-with-args-until-success') short-circuits
at the first non-nil return: if this guard ran first, its blocks
would prevent the identical guard from ever seeing those calls, the
identical guard's history would never record them, and its
escalation would be unreachable (2026-09-03 frozen-at-soft bug)."
  (add-hook 'iar-pre-tool-call-functions #'iar--loop-guard-chain t))

(iar--loop-guard-chain-setup)

(provide 'iar-loop-guard-chain)