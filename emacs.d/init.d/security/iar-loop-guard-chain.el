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
;; SOFT threshold: after N consecutive same-tool calls, block with a
;; correction message (the model can self-correct).
;; HARD threshold: after 2x soft, stop the request entirely.
;;
;; Semantics chosen deliberately (differential-tested):
;; - The identical-args guard runs FIRST (hook order) and pushes the
;;   current call. This guard therefore drops a trailing identical
;;   entry before counting, so blocked identical calls do not count
;;   toward a chain.
;; - When THIS guard blocks, the identical guard has already pushed,
;;   so the blocked call IS in history -- but the next chain count
;;   includes it, which is correct: a blocked call that is retried
;;   with new args still demonstrates the chain pattern.
;; - Blocked calls do not escalate the identical guard's count
;;   (it counts matches, not pushes).

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

;;; --- Hook function ---

(defun iar--loop-guard-chain (info)
  "Pre-tool-call hook: detect same-tool chains with different args.
INFO is the plist from `gptel-pre-tool-call-functions'.

Returns nil to allow, (:block MSG) to block with a correction,
or (:stop t :stop-reason REASON) to stop the request."
  (let* ((name (plist-get info :name))
         (args (plist-get info :args))
         (sig (cons name (iar--loop-args-sig args)))
         (identical-count (iar--loop-count-recent sig)))
    ;; The identical-args guard runs before this hook and pushes the
    ;; current call. Drop the trailing identical entry (if present) so
    ;; this call is not counted as part of its own chain, then count
    ;; backwards while the tool name matches.
    (let* ((hist (if (> identical-count 0)
                     (nthcdr identical-count iar--loop-history)
                   iar--loop-history))
           (chain 0))
      (while (and hist
                  (equal (caar hist) name))
        (setq chain (1+ chain)
              hist (cdr hist)))
      ;; Total chain length including this call.
      (setq chain (1+ chain))
      (let ((effective-soft
             (let ((s iar-loop-guard-chain-soft))
               (if (and (integerp s) (> s 0)) s 10)))
            (effective-hard
             (let ((h iar-loop-guard-chain-hard))
               (if (and (integerp h) (> h 0)) h 20)))
            ;; Ensure hard > soft so the model always gets a warning.
            (final-hard (max (let ((h iar-loop-guard-chain-hard))
                               (if (and (integerp h) (> h 0)) h 20))
                             (1+ (let ((s iar-loop-guard-chain-soft))
                                   (if (and (integerp s) (> s 0)) s 10))))))
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
  "Register the chain guard after the identical-args guard."
  (add-hook 'iar-pre-tool-call-functions #'iar--loop-guard-chain))

(iar--loop-guard-chain-setup)

(provide 'iar-loop-guard-chain)