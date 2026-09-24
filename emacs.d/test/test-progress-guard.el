;; -*- lexical-binding: t; -*-

;;; Tests for iar-progress-guard.el
;; Covers the zero-progress write-loop detection (c321 finding): same
;; content written to the same path N times must block at the next
;; attempt. The c321 shape (write -> verify -> write, 52 repeats) is
;; the regression case.

(require 'ert)
(require 'cl-lib)
(require 'iar-progress-guard)

(defun pg--info (filepath content)
  "Build a gptel-style tool-call INFO plist for write_file."
  (list :name "write_file"
        :args (list :filepath filepath :content content)))

;;; --- Basic detection ---

(ert-deftest test-progress-guard-allows-first-write ()
  "A first write to a path must never be blocked."
  (with-temp-buffer
    (setq-local iar--progress-history nil)
    (should-not (iar--progress-guard
                 (pg--info "/tmp/pg-a.md" "alpha")))))

(ert-deftest test-progress-guard-allows-progressing-writes ()
  "Different content each time = progress = no block."
  (with-temp-buffer
    (setq-local iar--progress-history nil)
    (should-not (iar--progress-guard (pg--info "/tmp/pg-b.md" "v1")))
    (should-not (iar--progress-guard (pg--info "/tmp/pg-b.md" "v2 longer")))
    (should-not (iar--progress-guard (pg--info "/tmp/pg-b.md" "v3")))))

(ert-deftest test-progress-guard-blocks-after-soft-repeats ()
  "The soft-th identical write to a path is blocked (streak counts
the current call: soft=3 -> writes 1-2 pass, write 3 blocks)."
  (with-temp-buffer
    (setq-local iar--progress-history nil)
    (let ((iar-progress-guard-soft 3))
      (should-not (iar--progress-guard (pg--info "/tmp/pg-c.md" "same")))
      (should-not (iar--progress-guard (pg--info "/tmp/pg-c.md" "same")))
      (should (iar--progress-guard (pg--info "/tmp/pg-c.md" "same"))))))

(ert-deftest test-progress-guard-interleaved-other-writes-still-count ()
  "The c321 shape: write -> verify -> write. The verify calls are
execute_code_local (a different hook) and must NOT reset the
streak. A write to a DIFFERENT path is real intervening work and
DOES reset it (documented semantics)."
  (with-temp-buffer
    (setq-local iar--progress-history nil)
    (let ((iar-progress-guard-soft 3))
      (should-not (iar--progress-guard (pg--info "/tmp/pg-d.md" "same")))
      (should-not (iar--progress-guard (pg--info "/tmp/pg-d.md" "same")))
      ;; an execute_code_local call is invisible to this hook: no reset
      (should-not (iar--progress-guard
                   (list :name "execute_code_local"
                         :args (list :command "wc -c /tmp/pg-d.md"))))
      ;; streak survived the interleaved non-write call
      (should (iar--progress-guard (pg--info "/tmp/pg-d.md" "same")))
      ;; but a write to a DIFFERENT path resets it
      (should-not (iar--progress-guard (pg--info "/tmp/pg-other.md" "x")))
      (should-not (iar--progress-guard (pg--info "/tmp/pg-d.md" "same"))))))

;;; --- Non-interference ---

(ert-deftest test-progress-guard-ignores-other-tools ()
  "Non-write_file tools must pass through untouched."
  (with-temp-buffer
    (setq-local iar--progress-history nil)
    (should-not (iar--progress-guard
                 (list :name "execute_code_local"
                       :args (list :command "ls")))))
  (should (null iar--progress-history)))

(ert-deftest test-progress-guard-nil-content-safe ()
  "Missing content arg must not error and must not block."
  (with-temp-buffer
    (setq-local iar--progress-history nil)
    (should-not (iar--progress-guard
                 (list :name "write_file" :args (list :filepath "/tmp/x"))))))

(ert-deftest test-progress-guard-nil-args-safe ()
  "Nil args must not error."
  (with-temp-buffer
    (setq-local iar--progress-history nil)
    (should-not (iar--progress-guard (list :name "write_file")))))

;;; --- History management ---

(ert-deftest test-progress-guard-history-trims ()
  "History must trim to iar-progress-guard-history-size."
  (with-temp-buffer
    (setq-local iar--progress-history nil)
    (let ((iar-progress-guard-history-size 4))
      (dotimes (i 10)
        (iar--progress-guard
         (pg--info (format "/tmp/pg-trim-%d.md" i) (format "content-%d" i))))
      (should (= (length iar--progress-history) 4)))))

(ert-deftest test-progress-guard-consecutive-dedupe ()
  "Consecutive identical outcomes must collapse to one history entry
(so the ring is not eaten by repeats of one outcome)."
  (with-temp-buffer
    (setq-local iar--progress-history nil)
    (let ((iar-progress-guard-soft 99)) ; never blocks
      (dotimes (_ 8)
        (iar--progress-guard (pg--info "/tmp/pg-e.md" "same")))
      (should (= (length iar--progress-history) 1)))))

(ert-deftest test-progress-guard-history-is-buffer-local ()
  "Two buffers must not share progress history."
  (let (result)
    (with-temp-buffer
      (setq-local iar--progress-history nil)
      (iar--progress-guard (pg--info "/tmp/pg-f.md" "shared"))
      (with-temp-buffer
        (setq-local iar--progress-history nil)
        ;; Second buffer: fresh history, first write must pass.
        (setq result (iar--progress-guard
                      (pg--info "/tmp/pg-f.md" "same"))))
      ;; First buffer: second identical write, soft=1 -> block here.
      (let ((iar-progress-guard-soft 1))
        (should (iar--progress-guard (pg--info "/tmp/pg-f.md" "same")))))
    (should-not result)))

;;; --- The c321 regression shape ---

(ert-deftest test-progress-guard-c321-digest-diet-shape ()
  "The exact c321 shape: 52 identical writes to the digest path,
interleaved with verify calls (not visible to this hook). The 4th
identical write (soft=3) must be blocked -- the c321 loop ran 52."
  (with-temp-buffer
    (setq-local iar--progress-history nil)
    (let ((iar-progress-guard-soft 3)
          (digest (make-string 13018 ?x))
          (blocked 0))
      (dotimes (i 52)
        (let ((r (iar--progress-guard
                  (pg--info "/tmp/digest-diet-c309.md" digest))))
          (when (and r (stringp r) (string-prefix-p ":block" r))
            (cl-incf blocked))))
      (should (= blocked 50)))))  ; 52 - 2 allowed = 50 blocked

(provide 'test-progress-guard)