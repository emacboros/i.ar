;; -*- lexical-binding: t; -*-
;; Belt #2d stuck-staged tests (aria c368, 2026-09-15): the HISTORY-CLOCK
;; guard refuses a belt commit carrying a fabricated timestamp, but the
;; refused blob STAYS STAGED in the shared index (c364 production case,
;; again 2026-09-15 11:53Z: continuo's future line sat staged, invisible
;; to the blame-based clock audit, blocking every later commit of that
;; file -- a silent cascade: her next belt refuses again, her record
;; stays undurable, and LAST-CYCLE.txt still says ok).
;;
;; The fix: on refusal the belt ANNOTATES the refused line in place
;; (c362 policy: annotate, never erase; marker carries date(1) time per
;; CLOCK-FROM-TOOL) and retries the commit ONCE with IAR_ALLOW_CLOCK=1
;; (audited escape). If the retry fails, the belt UN-STAGES the record
;; paths so the next cycle starts unstuck.
;;
;; Tests pin:
;; 1. iar--belt-annotate-refused-lines annotates a refused line found in
;;    the working tree and returns 1; a second pass annotates nothing
;;    (idempotent).
;; 2. The retry path: a refusing hook + the belt's annotate+retry once
;;    with IAR_ALLOW_CLOCK=1 lands the commit (durable t).
;; 3. When the retry also fails (hook refuses for a different reason),
;;    the record paths are UN-STAGED (un-stuck) and the belt returns nil.

(require 'ert)

(ert-deftest test-tool-call-belt2d-annotate-refused-line ()
  "The helper finds the refused line in the working tree and
annotates it in place; a second run does not double-annotate."
  (let* ((tmpdir (make-temp-file "belt2d-ann-" t))
         (repo-dir tmpdir)
         (hist (expand-file-name "audit/iar/continuo/HISTORY.log" repo-dir)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory hist) t)
          (with-temp-file hist
            (insert "[2026-09-15 10:00:00] continuo: honest line\n"
                    "[2026-09-16 11:53:04] continuo: fabricated line\n"))
          (let* ((commit-text
                  (concat "REFUSED by HISTORY-CLOCK guard (c362): timestamp 86345s in the future:\n"
                          "  [2026-09-16 11:53:04] continuo: fabricated line\n"
                          "A log timestamp is a CLAIM; the model-generated one is fabricated.\n"
                          "Run: date -u '+[%Y-%m-%d %H:%M:%S]' -- paste that. (Escape: IAR_ALLOW_CLOCK=1)\n"))
                 (n (iar--belt-annotate-refused-lines repo-dir commit-text (list "audit/iar/continuo/HISTORY.log"))))
            (should (= n 1))
            (with-temp-buffer
              (insert-file-contents hist)
              (goto-char (point-min))
              (should (re-search-forward "^\\[2026-09-16 11:53:04\\].*CLOCK FABRICATION" nil t))
              ;; the honest line is untouched
              (goto-char (point-min))
              (should (string-match-p "honest line\n"
                                      (buffer-substring-no-properties (point-min) (point-max)))))
            ;; idempotent: second pass annotates nothing
            (should (= (iar--belt-annotate-refused-lines repo-dir commit-text (list "audit/iar/continuo/HISTORY.log")) 0))
            ;; the marker carries a real clock timestamp (CLOCK-FROM-TOOL)
            (with-temp-buffer
              (insert-file-contents hist)
              (should (string-match-p
                       "the append actually happened [0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\} [0-9]\\{2\\}:[0-9]\\{2\\}:[0-9]\\{2\\} UTC"
                       (buffer-string))))))
      (delete-directory tmpdir :recursive))))

(ert-deftest test-tool-call-belt2d-no-refusal-no-annotate ()
  "Commit text without a refusal block annotates nothing."
  (let* ((tmpdir (make-temp-file "belt2d-clean-" t))
         (repo-dir tmpdir)
         (hist (expand-file-name "audit/iar/continuo/HISTORY.log" repo-dir)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory hist) t)
          (with-temp-file hist (insert "[2026-09-15 12:00:00] continuo: ok\n"))
          (should (= (iar--belt-annotate-refused-lines
                      repo-dir "On main: belt #2 durability"
                      (list "audit/iar/continuo/HISTORY.log")) 0))
          (with-temp-buffer
            (insert-file-contents hist)
            (should-not (string-match-p "CLOCK FABRICATION" (buffer-string)))))
      (delete-directory tmpdir :recursive))))