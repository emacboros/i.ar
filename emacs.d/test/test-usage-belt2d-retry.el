;; -*- lexical-binding: t; -*-
;; Belt #2d retry tests (aria c368, 2026-09-15): the refusal branch now
;; HEALS at the action site instead of leaving the refused blob staged.
;;
;; Production shape (2026-09-15 11:53Z): continuo's belt commit was
;; refused by the HISTORY-CLOCK guard (fabricated +24h timestamp); the
;; blob stayed STAGED in the shared index; the blame-based clock audit
;; never saw it (staged lines have no blame commit); her next belt would
;; refuse again -- a silent record-undurability cascade with
;; LAST-CYCLE.txt still reading ok.
;;
;; Tests pin:
;; 1. A guard-shaped refusal (REFUSED + the offending line printed) is
;;    annotated in place and the commit RETRIES with IAR_ALLOW_CLOCK=1:
;;    the record lands (t) and the commit exists.
;; 2. A refusal whose offending line is NOT annotatable (no matching
;;    line in the working tree) still retries; if the retry fails the
;;    record paths are UN-STAGED (git status clean) and the belt
;;    returns nil.

(require 'ert)

(ert-deftest test-tool-call-usage-belt2d-refusal-annotates-and-retries ()
  "Guard-shaped refusal: annotate the refused line, retry with the
audited escape, record lands durable."
  (let* ((tmpdir (make-temp-file "belt2d-retry-" t))
         (repo-dir (expand-file-name "repo" tmpdir))
         (iar-personalization-path repo-dir)
         (iar-audit-path "audit")
         (iar--current-agent-name "testagent")
         (iar--current-project "testproject"))
    (unwind-protect
        (progn
          (make-directory repo-dir)
          (let ((default-directory repo-dir))
            (call-process "git" nil nil nil "init" "-q")
            (call-process "git" nil nil nil "config" "user.name" "Test")
            (call-process "git" nil nil nil "config" "user.email" "t@i.ar")
            ;; A HISTORY-CLOCK-shaped guard: refuses a commit whose
            ;; HISTORY.log carries a future-dated line, printing the
            ;; offending line (the real guard's output shape).
            (make-directory ".git/hooks" :parents)
            (with-temp-file ".git/hooks/pre-commit"
              (insert "#!/bin/sh\n"
                      "if [ \"$IAR_ALLOW_CLOCK\" = \"1\" ]; then exit 0; fi\n"
                      "if git diff --cached -U0 -- audit/testproject/testagent/HISTORY.log | grep '^+\\[2026-09-16' >/dev/null 2>&1; then\n"
                      "  line=$(git diff --cached -U0 -- audit/testproject/testagent/HISTORY.log | grep '^+\\[2026-09-16' | sed 's/^+//')\n"
                      "  echo 'REFUSED by HISTORY-CLOCK guard (c362): timestamp 86345s in the future:' >&2\n"
                      "  echo \"  $line\" >&2\n"
                      "  echo 'A log timestamp is a CLAIM.' >&2\n"
                      "  exit 1\n"
                      "fi\n"
                      "exit 0\n"))
            (call-process "chmod" nil nil nil "+x" ".git/hooks/pre-commit")
            (call-process "git" nil nil nil "add" "-A")
            (call-process "git" nil nil nil "commit" "-qm" "init"))
          (iar--usage-reset)
          (setq iar--usage-requests 3 iar--usage-input-tokens 100
                iar--usage-output-tokens 40 iar--usage-model "m")
          ;; Pre-plant the fabricated line the way the model would: the
          ;; record path carries a future-dated line BEFORE the belt runs.
          (let ((hist (expand-file-name "audit/testproject/testagent/HISTORY.log" repo-dir)))
            (make-directory (file-name-directory hist) t)
            (with-temp-file hist
              (insert "[2026-09-16 11:53:04] testagent: fabricated line\n")))
          ;; The belt must survive the refusal: annotate + retry => t.
          (should (eq (iar--usage-write-log-now) t))
          ;; The commit exists and carries the ANNOTATED line.
          (let ((default-directory repo-dir)
                (out1 (generate-new-buffer " *belt2d-log1*"))
                (out2 (generate-new-buffer " *belt2d-log2*")))
            (call-process "git" nil (list out1 t) nil "log" "-1" "--format=%B")
            (let ((msg (with-current-buffer out1 (buffer-string))))
              (should (string-match-p "belt #2 durability" msg)))
            (call-process "git" nil (list out2 t) nil "show" "HEAD:audit/testproject/testagent/HISTORY.log")
            (let ((content (with-current-buffer out2 (buffer-string))))
              (should (string-match-p "CLOCK FABRICATION" content))
              (should (string-match-p "belt #2d auto-annotate" content)))
            (kill-buffer out1)
            (kill-buffer out2)))
      (delete-directory tmpdir :recursive))))

(ert-deftest test-tool-call-usage-belt2d-retry-fails-unstages ()
  "A refusal the annotator cannot heal (offending line not in the
working tree): retry fails, record paths are UN-STAGED (the next
cycle starts unstuck), belt returns nil."
  (let* ((tmpdir (make-temp-file "belt2d-unstuck-" t))
         (repo-dir (expand-file-name "repo" tmpdir))
         (iar-personalization-path repo-dir)
         (iar-audit-path "audit")
         (iar--current-agent-name "testagent")
         (iar--current-project "testproject"))
    (unwind-protect
        (progn
          (make-directory repo-dir)
          (let ((default-directory repo-dir))
            (call-process "git" nil nil nil "init" "-q")
            (call-process "git" nil nil nil "config" "user.name" "Test")
            (call-process "git" nil nil nil "config" "user.email" "t@i.ar")
            ;; Refuses ALWAYS, but prints a line that matches nothing in
            ;; the working tree -- the annotator heals nothing, the
            ;; retry hits the same refusal.
            (make-directory ".git/hooks" :parents)
            (with-temp-file ".git/hooks/pre-commit"
              (insert "#!/bin/sh\n"
                      "echo 'REFUSED by test guard: timestamp 999s in the future:' >&2\n"
                      "echo '  [2026-09-16 00:00:00] nobody: ghost line' >&2\n"
                      "exit 1\n"))
            (call-process "chmod" nil nil nil "+x" ".git/hooks/pre-commit")
            (call-process "git" nil nil nil "add" "-A")
            (call-process "git" nil nil nil "commit" "-qm" "init"))
          (iar--usage-reset)
          (setq iar--usage-requests 3 iar--usage-input-tokens 100
                iar--usage-output-tokens 40 iar--usage-model "m")
          ;; Belt returns nil (not durable)...
          (should (eq (iar--usage-write-log-now) nil))
          ;; ...and NOTHING stays staged (un-stuck index).
          (let ((default-directory repo-dir)
                (out (generate-new-buffer " *belt2d-status*")))
            (call-process "git" nil (list out t) nil "status" "--porcelain")
            (let ((staged (with-current-buffer out
                            (buffer-string))))
              (kill-buffer out)
              (should-not (string-match-p "^M " staged))
              (should-not (string-match-p "^A " staged)))))
      (delete-directory tmpdir :recursive))))