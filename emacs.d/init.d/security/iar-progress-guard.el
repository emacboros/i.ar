;; -*- lexical-binding: t; -*-

;;; iar-progress-guard.el --- Detect zero-progress write loops
;;
;; The c321 finding (2026-09-24, run 260924114800): a cycle burned 2.7M
;; tokens re-emitting the same 13018-char digest to the same file 52
;; times over 24 minutes (write -> verify TWIN-MATCH -> write again),
;; hit the 3600s wall, and expired grace with zero record. No existing
;; guard caught it:
;;   - identical-call guard: needs IDENTICAL CONSECUTIVE args; the
;;     write/verify alternation breaks the chain (the interleaved
;;     execute call resets the run).
;;   - chain guard: needs same-tool chains; the alternation is
;;     write_file, execute_code_local, write_file... no chain >2.
;;   - tool-call cap: only 62 calls -- far under 300.
;; The disease is not repetition of CALLS; it is repetition of OUTCOME.
;; Same file + same size written N times = zero progress.
;;
;; Design: post-tool-call hook on write_file. Keep a small per-agent
;; history of (filepath . content-length) for recent writes. If the
;; same filepath was written with the same content length (and same
;; content md5) within the last N writes, the write made no progress.
;; After iar-progress-guard-soft identical outcomes, block with a
;; message naming the fixed point. The block is a pre-tool-call block
;; (checked at the NEXT write to the same path), so the model sees it
;; as a tool error on the call it was about to repeat.
;;
;; Why content md5 AND length: length alone can miss a same-length
;; no-progress rewrite; md5 alone is enough but length is the cheap
;; pre-filter. Both must match to count as "no progress".
;;
;; Fail-open: any error in the guard never blocks a write (a broken
;; guard must not take the write path down with it).

(require 'iar-tool-call)

(defvar iar-progress-guard-soft 3
  "Number of identical-outcome writes to the same path before the
progress guard blocks the next write to that path. 3 = the first
repeat gets a warning-grade block early enough to matter (the c321
loop ran 52 repeats).")

(defvar iar-progress-guard-history-size 12
  "How many recent write outcomes to remember.")

(defvar-local iar--progress-history nil
  "Buffer-local list of (filepath content-md5 content-length), most
recent first. Trimmed to `iar-progress-guard-history-size'.")

(defun iar--progress-guard (info)
  "Pre-tool-call hook: block a write that repeats a recent identical
outcome. INFO is the gptel tool-call plist. Returns (:block . msg)
or nil."
  (condition-case err
      (let* ((name (plist-get info :name))
             (args (plist-get info :args)))
        (when (and (equal name "write_file")
                   (plistp args))
          (let* ((filepath (plist-get args :filepath))
                 (content (plist-get args :content))
                 (md5 (and (stringp content) (md5 content)))
                 (len (and (stringp content) (length content))))
            (when (and filepath md5)
              ;; Streak semantics: how many times has this exact
              ;; (filepath . md5) outcome been written, counting
              ;; consecutive repeats (the c321 loop was 52 consecutive
              ;; identical writes interleaved with verify calls).
              (let* ((last (car iar--progress-history))
                     (same-outcome
                      (and last
                           (equal (car last) filepath)
                           (equal (nth 1 last) md5)))
                     (streak
                      (if same-outcome
                          (1+ (or (nth 3 last) 1))
                        1)))
                ;; Record this outcome: update the streak on a repeat
                ;; (replace the head), push a new entry otherwise.
                (if same-outcome
                    (setcar iar--progress-history
                            (list filepath md5 len streak))
                  (push (list filepath md5 len streak)
                        iar--progress-history))
                (when (> (length iar--progress-history)
                         iar-progress-guard-history-size)
                  (setq iar--progress-history
                        (cl-subseq iar--progress-history
                                   0 iar-progress-guard-history-size)))
                (when (>= streak iar-progress-guard-soft)
                  (format
                   ":block . PROGRESS GUARD: this exact content (md5 %s, %d chars) has now been written to '%s' %d times -- zero progress on the last %d writes. Re-writing it again cannot help. Either change the content SUBSTANTIVELY (delete or rewrite a section -- the goal is a DIFFERENT file, not a re-confirmation), or stop writing and move to the next step of your task. If the size cannot go lower, say so in text and proceed."
                   md5 len filepath streak (1- streak))))))))
    (error
     ;; Fail open: a broken guard must not block legitimate writes.
     (message "[progress-guard] internal error (ignored): %s"
              (error-message-string err))
     nil)))

(add-hook 'iar-pre-tool-call-functions #'iar--progress-guard)

(provide 'iar-progress-guard)