;; -*- lexical-binding: t; -*-

;;; Digest pressure guard tests (2026-09-02, aria cycle 137)
;;
;; Covers iar--read-digest-guarded in iar-prompt-assembly.el:
;; - under warn threshold: passes through untouched, no truncation
;; - over warn, under hard cap: passes through untouched (warn only)
;; - over hard cap: truncates to the tail, prepends a marker with
;;   the diet law, and the marker states the dropped char count
;; - empty/missing digest: returns empty string
;; - injection wiring: iar--inject-memory uses the guarded reader
;;
;; The guard exists because DIGEST.md is injected FULL on every
;; request of every cycle (aria-cycle + interactive). Regrowth is
;; a pressure problem, not a one-time diet problem.

(require 'ert)

(defvar iar-personalization-path nil)
(defvar iar-audit-path nil)

(defun test-digest-guard--setup (content)
  "Write CONTENT to a scratch DIGEST.md, return (project . agent)."
  (let* ((project "test_digestproj")
         (agent "test_digestagent")
         (dir (expand-file-name
               (format "%s/%s" project agent)
               (expand-file-name iar-audit-path iar-personalization-path)))
         (file (expand-file-name "DIGEST.md" dir)))
    (make-directory dir t)
    (with-temp-file file (insert content))
    (cons project agent)))

(defun test-digest-guard--teardown (pair)
  (let* ((dir (expand-file-name
               (format "%s/%s" (car pair) (cdr pair))
               (expand-file-name iar-audit-path iar-personalization-path))))
    (ignore-errors (delete-directory dir t))))

(ert-deftest test-digest-guard-under-warn-passthrough ()
  "Digest under the warn threshold passes through byte-identical."
  (let* ((content (make-string 1000 ?a))
         (pair (test-digest-guard--setup content)))
    (unwind-protect
        (should (string= (iar--read-digest-guarded (car pair) (cdr pair))
                         content))
      (test-digest-guard--teardown pair))))

(ert-deftest test-digest-guard-warn-zone-passthrough ()
  "Digest between warn and hard cap passes through untouched (warn is advisory)."
  (let* ((content (make-string 14000 ?b))
         (pair (test-digest-guard--setup content)))
    (unwind-protect
        (should (string= (iar--read-digest-guarded (car pair) (cdr pair))
                         content))
      (test-digest-guard--teardown pair))))

(ert-deftest test-digest-guard-hard-cap-truncates-tail ()
  "Digest over the hard cap is truncated to the LAST cap chars."
  (let* ((content (concat (make-string 1000 ?H) (make-string 17000 ?T)))
         (pair (test-digest-guard--setup content))
         (result (iar--read-digest-guarded (car pair) (cdr pair))))
    (unwind-protect
        (progn
          ;; Total = marker + cap chars of tail
          (should (> (length result) iar-digest-hard-cap-chars))
          ;; The tail is preserved: the result ends with the last cap chars
          (should (string-suffix-p (substring content (- iar-digest-hard-cap-chars)) result))
          ;; Marker present and states the dropped count
          (should (string-match-p "DIGEST TRUNCATED" result))
          (should (string-match-p "DIET THIS FILE" result)))
      (test-digest-guard--teardown pair))))

(ert-deftest test-digest-guard-hard-cap-drops-head ()
  "Truncation drops the HEAD (the law section) -- the marker says so."
  (let* ((content (concat "LAW SECTION THAT MUST BE DROPPED\n"
                          (make-string 17000 ?x)))
         (pair (test-digest-guard--setup content))
         (result (iar--read-digest-guarded (car pair) (cdr pair))))
    (unwind-protect
        (progn
          (should-not (string-match-p "LAW SECTION THAT MUST BE DROPPED" result))
          (should (string-match-p "dropped" result)))
      (test-digest-guard--teardown pair))))

(ert-deftest test-digest-guard-empty-digest ()
  "Missing digest returns empty string, no error."
  (should (string= (iar--read-digest-guarded "test_digestproj"
                                             "test_nonexistent_agent")
                   "")))

(ert-deftest test-digest-guard-inject-memory-uses-guard ()
  "iar--inject-memory routes DIGEST through the guarded reader:
an oversized digest in injection comes back truncated with marker."
  (let* ((content (make-string 17000 ?z))
         (pair (test-digest-guard--setup content))
         (result (iar--inject-memory 'aria-cycle (car pair) (cdr pair))))
    (unwind-protect
        (progn
          (should (string-match-p "DIGEST TRUNCATED" result))
          (should (string-match-p "=== DIGEST \\[test_digestagent\\] ===" result)))
      (test-digest-guard--teardown pair))))

(provide 'test-digest-guard)
;;; test-digest-guard.el ends here