;; -*- lexical-binding: t; -*-

;;; Regression test: one-shot state must carry :request-count.
;; The c39 burn mirror (iar--usage-parse-from-curl in iar-tool-call.el)
;; does (cl-incf (plist-get iar--one-shot-state :request-count)) on
;; every request. iar--one-shot-make-state lacked the key, so plist-get
;; returned nil and cl-incf signaled wrong-type-argument
;; number-or-marker-p nil -- demoted by the advice's condition-case to
;; "Warning: token parse from curl failed" (one per request; nocturne
;; first runs: 164 in a single log) and the mirror never incremented.
;; Cycle state always had the key, so the storm was one-shot-only and
;; was misread in c218 forensics as a deepseek chunk-shape problem in
;; the gptel fork. Found and fixed in c219.

(require 'ert)
(require 'cl-lib)
(require 'iar-agent-cycle)

(ert-deftest test-one-shot-state-has-request-count ()
  "One-shot state plist must contain :request-count with numeric value."
  (let ((st (iar--one-shot-make-state "test" (get-buffer-create "*t*") 5)))
    (should (integerp (plist-get st :request-count)))))

(ert-deftest test-one-shot-request-count-incrementable ()
  "The c39 mirror's cl-incf must not signal on one-shot state."
  (let ((st (iar--one-shot-make-state "test" (get-buffer-create "*t*") 5)))
    (should-not
     (condition-case err
         (progn (cl-incf (plist-get st :request-count)) nil)
       (wrong-type-argument err)))
    (should (= 1 (plist-get st :request-count)))))

(ert-deftest test-one-shot-request-count-matches-cycle-shape ()
  "One-shot and cycle state must expose the same burn-mirror key
(the mirror is written once for both -- state shapes that differ in
a key the mirror touches are a differential bug)."
  (let ((os (iar--one-shot-make-state "t1" (get-buffer-create "*t1*") 5))
        (cy (iar--cycle-make-state "t2" (get-buffer-create "*t2*") "cont" 5)))
    (should (= 0 (plist-get os :request-count)))
    (should (= 0 (plist-get cy :request-count)))))
