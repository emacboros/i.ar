;; -*- lexical-binding: t; -*-
;; Belt #2 tests (continuo cycle 55): iar--usage-write-log-now.
;; The pre-exit usage write (c54, a7e1cf5) had no direct tests: the
;; orphan-write race fix was production-observed but never pinned by
;; the suite. These tests pin: (1) it returns t on success and writes
;; the line, (2) it never signals when the write path is broken
;; (exit path must not break), (3) it is idempotent in effect with
;; the kill-emacs-hook write.
;; c262 UPDATE: "idempotent in effect" now means ONE line, not two.
;; The c258-c259 USAGE.log doubling census showed the second write
;; (kill-emacs-hook) landing as an unstaged duplicate that the next
;; belt commit's `git add -f' swept into history (root cause: c262 --
;; reset_worktree resets REPO_DIR (i.ar), never the personalization
;; tree). The dedupe guard in iar--usage-write-log kills the dup at
;; birth: same timestamp+counts line already last => skip. Tests
;; updated: two identical writes = one line; a DIFFERENT line appends.
;; c58 UPDATE: "identical" means identical CONTENT (counts), not the
;; full line -- belt#2 and the kill-emacs-hook write seconds apart, so
;; their timestamps differ; the guard compares content only.

(require 'ert)
(require 'cl-lib)

(ert-deftest test-tool-call-usage-write-log-now-writes-line ()
  "Pre-exit write returns t and appends a summary line."
  (let* ((tmpdir (make-temp-file "usage-now-" t))
         (iar-personalization-path tmpdir)
         (iar-audit-path "audit")
         (iar--current-agent-name "testagent")
         (iar--current-project "testproject"))
    (unwind-protect
        (progn
          (iar--usage-reset)
          (setq iar--usage-requests 5
                iar--usage-input-tokens 200
                iar--usage-output-tokens 80
                iar--usage-model "test-model")
          (should (eq (iar--usage-write-log-now) t))
          (let ((path (expand-file-name
                       "audit/testproject/testagent/USAGE.log" tmpdir)))
            (should (file-exists-p path))
            (with-temp-buffer
              (insert-file-contents path)
              (should (string-match-p "requests=5 " (buffer-string)))
              (should (string-match-p "input=200 " (buffer-string)))
              (should (string-match-p "output=80 " (buffer-string)))
              (should (string-match-p "model=test-model" (buffer-string))))))
      (delete-directory tmpdir :recursive))))

(ert-deftest test-tool-call-usage-write-log-now-never-signals ()
  "Broken write path: returns nil, does NOT signal (exit path safe)."
  (let* ((tmpdir (make-temp-file "usage-now-" t))
         (iar-personalization-path tmpdir)
         (iar-audit-path "audit")
         (iar--current-agent-name "testagent")
         (iar--current-project "testproject")
         (path (expand-file-name
                "audit/testproject/testagent/USAGE.log" tmpdir)))
    (unwind-protect
        (progn
          (iar--usage-reset)
          ;; Make the write fail: USAGE.log exists as a DIRECTORY, so
          ;; append-to-file signals. write-log-now must catch it.
          (make-directory (file-name-directory path) t)
          (make-directory path)
          (should (eq (iar--usage-write-log-now) nil))
          (should (file-directory-p path)))
      (delete-directory tmpdir :recursive))))

(ert-deftest test-tool-call-usage-write-log-now-idempotent-with-hook ()
  "Two writes (pre-exit + hook net) with the same counts = ONE line
(c262 dedupe guard, c58 content form: the dup dies at birth even
when the two writes straddle a timestamp change -- the real belt#2
and kill-emacs writes are seconds apart)."
  (let* ((tmpdir (make-temp-file "usage-now-" t))
         (iar-personalization-path tmpdir)
         (iar-audit-path "audit")
         (iar--current-agent-name "testagent")
         (iar--current-project "testproject"))
    (unwind-protect
        (progn
          (iar--usage-reset)
          ;; Pin the stamp for the first write, then let the second
          ;; write see a DIFFERENT timestamp: the guard must still
          ;; skip (content comparison, c58).
          (cl-letf (((symbol-function 'format-time-string)
                     (lambda (_fmt &optional _time _zone)
                       "2026-09-18 10:21:49")))
            (iar--usage-write-log-now))
          (cl-letf (((symbol-function 'format-time-string)
                     (lambda (_fmt &optional _time _zone)
                       "2026-09-18 10:22:03")))
            (iar--usage-write-log))      ; the kill-emacs-hook net
          (with-temp-buffer
            (insert-file-contents
             (expand-file-name "audit/testproject/testagent/USAGE.log" tmpdir))
            (should (equal (count-lines (point-min) (point-max)) 1))
            (should (looking-at "^\\[.*\\] requests=[0-9]+ input=[0-9]+ output=[0-9]+ total=[0-9]+ model="))))
      (delete-directory tmpdir :recursive))))

(ert-deftest test-tool-call-usage-write-log-dedupe-different-line-appends ()
  "A DIFFERENT line (new counts) still appends after a dedupe skip."
  (let* ((tmpdir (make-temp-file "usage-dedupe-" t))
         (iar-personalization-path tmpdir)
         (iar-audit-path "audit")
         (iar--current-agent-name "testagent")
         (iar--current-project "testproject"))
    (unwind-protect
        (progn
          (iar--usage-reset)
          (setq iar--usage-requests 5 iar--usage-input-tokens 200
                iar--usage-output-tokens 80 iar--usage-model "m")
          (should (eq (iar--usage-write-log) t))
          ;; Identical second write: skipped (nil = honest no-op).
          ;; Pin the stamp: the two writes must share a timestamp for
          ;; this to be a same-close pair (content guard, c58).
          (cl-letf (((symbol-function 'format-time-string)
                     (lambda (_fmt &optional _time _zone)
                       "2026-09-18 10:21:49")))
            (should (eq (iar--usage-write-log) nil)))
          ;; Changed counts: appends (different content, guard passes).
          (setq iar--usage-requests 9 iar--usage-input-tokens 300)
          (should (eq (iar--usage-write-log) t))
          (with-temp-buffer
            (insert-file-contents
             (expand-file-name "audit/testproject/testagent/USAGE.log" tmpdir))
            (should (equal (count-lines (point-min) (point-max)) 2))
            (should (string-match-p "requests=5 " (buffer-string)))
            (should (string-match-p "requests=9 " (buffer-string)))))
      (delete-directory tmpdir :recursive))))

(ert-deftest test-tool-call-usage-write-log-now-glued-file-safe ()
  "Unterminated existing file: the newline guard fires, no glue."
  (let* ((tmpdir (make-temp-file "usage-now-" t))
         (iar-personalization-path tmpdir)
         (iar-audit-path "audit")
         (iar--current-agent-name "testagent")
         (iar--current-project "testproject")
         (dir (expand-file-name "audit/testproject/testagent" tmpdir)))
    (unwind-protect
        (progn
          (make-directory dir t)
          (let ((path (expand-file-name "USAGE.log" dir)))
            (with-temp-file path (insert "[old] requests=1 input=1 output=1 total=2 model=m"))
            (iar--usage-reset)
            (iar--usage-write-log-now)
            (with-temp-buffer
              (insert-file-contents path)
              ;; The old line is intact on its own line; the new line
              ;; starts fresh, not glued onto "model=m".
              (goto-char (point-min))
              (should (looking-at "^\\[old\\] requests=1"))
              (forward-line 1)
              (should (looking-at "^\\["))))
      (delete-directory tmpdir :recursive)))))

(ert-deftest test-tool-call-usage-write-log-now-commits-line ()
  "Belt #2 commits its own USAGE line (c86 durability fix)."
  (let* ((tmpdir (make-temp-file "usage-commit-" t))
         (repo-dir (expand-file-name "repo" tmpdir))
         (iar-personalization-path repo-dir)
         (iar-audit-path "audit")
         (iar--current-agent-name "testagent")
         (iar--current-project "testproject"))
    (unwind-protect
        (progn
          ;; Real git repo, real commit -- the durability contract.
          (make-directory repo-dir)
          (let ((default-directory repo-dir))
            (call-process "git" nil nil nil "init" "-q")
            (call-process "git" nil nil nil "config" "user.name" "Test")
            (call-process "git" nil nil nil "config" "user.email" "t@i.ar")
            (call-process "git" nil nil nil "add" "-A")
            (call-process "git" nil nil nil "commit" "-qm" "init"))
          (iar--usage-reset)
          (setq iar--usage-requests 3 iar--usage-input-tokens 100
                iar--usage-output-tokens 40 iar--usage-model "m")
          (should (eq (iar--usage-write-log-now) t))
          ;; The line is committed, not just written: a reset --hard
          ;; must NOT erase it (the c85 failure mode).
          (let ((default-directory repo-dir))
            (call-process "git" nil nil nil "reset" "--hard" "-q")
            (call-process "git" nil nil nil "clean" "-fdq"))
          (let ((path (expand-file-name
                       "audit/testproject/testagent/USAGE.log" repo-dir)))
            (should (file-exists-p path))
            (with-temp-buffer
              (insert-file-contents path)
              (should (string-match-p "requests=3 " (buffer-string))))))
      (delete-directory tmpdir :recursive))))

(ert-deftest test-tool-call-usage-write-log-now-commit-does-not-sweep ()
  "Belt #2b (c292): the belt commits the agent's OWN record files
(JOURNAL.org rides the belt now) but NEVER a sibling agent's files.
c292 finding: continuo's close protocol has no commit step -- 9 of 10
runs left her record uncommitted and its durability rode aria's
belt-syncing. The belt now carries the agent's record; the old
same-agent-JOURNAL-must-stay-dirty contract is INVERTED. The
sibling-protection contract survives: another agent's dirty files
stay out of this commit."
  (let* ((tmpdir (make-temp-file "usage-sweep-" t))
         (repo-dir (expand-file-name "repo" tmpdir))
         (iar-personalization-path repo-dir)
         (iar-audit-path "audit")
         (iar--current-agent-name "testagent")
         (iar--current-project "testproject")
         (own-journal (expand-file-name "audit/testproject/testagent/JOURNAL.org" repo-dir))
         (sibling-journal (expand-file-name "audit/testproject/sibling/JOURNAL.org" repo-dir)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory own-journal) t)
          (make-directory (file-name-directory sibling-journal) t)
          (with-temp-file own-journal (insert "own v1\n"))
          (with-temp-file sibling-journal (insert "sibling v1\n"))
          (let ((default-directory repo-dir))
            (call-process "git" nil nil nil "init" "-q")
            (call-process "git" nil nil nil "config" "user.name" "Test")
            (call-process "git" nil nil nil "config" "user.email" "t@i.ar")
            (call-process "git" nil nil nil "add" "-A")
            (call-process "git" nil nil nil "commit" "-qm" "init"))
          ;; Modify BOTH after init: the agent's own journal (must ride
          ;; the belt now) and the sibling's journal (must NOT).
          (with-temp-file own-journal (insert "own v2 -- rides the belt\n"))
          (with-temp-file sibling-journal (insert "sibling v2 -- stays out\n"))
          (iar--usage-reset)
          (setq iar--usage-requests 1 iar--usage-input-tokens 10
                iar--usage-output-tokens 5 iar--usage-model "m")
          (should (eq (iar--usage-write-log-now) t))
          ;; OWN journal change IS committed (belt #2b).
          (with-temp-buffer
            (let ((default-directory repo-dir))
              (call-process "git" nil t nil "show" "--stat" "HEAD"))
            (should (string-match-p "JOURNAL.org" (buffer-string))))
          (with-temp-buffer
            (let ((default-directory repo-dir))
              (call-process "git" nil t nil "show" "HEAD:audit/testproject/testagent/JOURNAL.org"))
            (should (string-match-p "own v2" (buffer-string))))
          ;; SIBLING journal change is NOT in the commit (still dirty).
          (with-temp-buffer
            (let ((default-directory repo-dir))
              (call-process "git" nil t nil "diff" "--" "audit/testproject/sibling/JOURNAL.org"))
            (should (string-match-p "sibling v2" (buffer-string)))))
      (delete-directory tmpdir :recursive))))

(ert-deftest test-tool-call-usage-write-log-now-belt2b-never-sweeps-cycle-log ()
  "Belt #2b stages a FIXED record-file list: the rolling cycle.log
(86MB, the c270 resurrection class) and scratch files never ride it."
  (let* ((tmpdir (make-temp-file "usage-cyclog-" t))
         (repo-dir (expand-file-name "repo" tmpdir))
         (iar-personalization-path repo-dir)
         (iar-audit-path "audit")
         (iar--current-agent-name "testagent")
         (iar--current-project "testproject")
         (cyclog (expand-file-name "audit/testproject/testagent/cycle.log" repo-dir))
         (scratch (expand-file-name "audit/testproject/testwrite" repo-dir)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory cyclog) t)
          (make-directory scratch t)
          (with-temp-file cyclog (insert "rolling transcript -- huge\n"))
          (with-temp-file (expand-file-name "junk.txt" scratch) (insert "scratch\n"))
          (let ((default-directory repo-dir))
            (call-process "git" nil nil nil "init" "-q")
            (call-process "git" nil nil nil "config" "user.name" "Test")
            (call-process "git" nil nil nil "config" "user.email" "t@i.ar")
            (with-temp-file (expand-file-name ".gitignore" repo-dir)
              (insert "audit/*\n"))
            (call-process "git" nil nil nil "add" "-A")
            (call-process "git" nil nil nil "commit" "-qm" "init"))
          (iar--usage-reset)
          (setq iar--usage-requests 1 iar--usage-input-tokens 10
                iar--usage-output-tokens 5 iar--usage-model "m")
          (should (eq (iar--usage-write-log-now) t))
          ;; Neither cycle.log nor scratch is tracked after the belt.
          (let ((default-directory repo-dir))
            (with-temp-buffer
              (call-process "git" nil t nil "ls-files" "audit/testproject/testagent/")
              (should (not (string-match-p "cycle\.log" (buffer-string))))
              (should (not (string-match-p "testwrite" (buffer-string)))))))
      (delete-directory tmpdir :recursive))))

(ert-deftest test-tool-call-usage-write-log-now-force-stage-untracked ()
  "NEW agent (untracked, gitignored USAGE.log): belt #2 still commits
the line (c86 addendum -- add -f force-stage)."
  (let* ((tmpdir (make-temp-file "usage-force-" t))
         (repo-dir (expand-file-name "repo" tmpdir))
         (iar-personalization-path repo-dir)
         (iar-audit-path "audit")
         (iar--current-agent-name "newagent")
         (iar--current-project "testproject"))
    (unwind-protect
        (progn
          (make-directory repo-dir)
          (let ((default-directory repo-dir))
            (call-process "git" nil nil nil "init" "-q")
            (call-process "git" nil nil nil "config" "user.name" "Test")
            (call-process "git" nil nil nil "config" "user.email" "t@i.ar")
            (with-temp-file (expand-file-name ".gitignore" repo-dir)
              (insert "audit/*\n"))
            (call-process "git" nil nil nil "add" "-A")
            (call-process "git" nil nil nil "commit" "-qm" "init"))
          (iar--usage-reset)
          (setq iar--usage-requests 7 iar--usage-input-tokens 70
                iar--usage-output-tokens 21 iar--usage-model "m")
          (should (eq (iar--usage-write-log-now) t))
          ;; The line is COMMITTED despite audit/* being gitignored
          ;; and the file untracked: survives reset --hard + clean.
          (let ((default-directory repo-dir))
            (call-process "git" nil nil nil "reset" "--hard" "-q")
            (call-process "git" nil nil nil "clean" "-fdq"))
          (let ((path (expand-file-name
                       "audit/testproject/newagent/USAGE.log" repo-dir)))
            (should (file-exists-p path))
            (with-temp-buffer
              (insert-file-contents path)
              (should (string-match-p "requests=7 " (buffer-string))))))
      (delete-directory tmpdir :recursive))))

(ert-deftest test-tool-call-usage-write-log-now-add-failure-honest-nil ()
  "Unwritable git index: add fails, belt #2 returns nil (honest)."
  (let* ((tmpdir (make-temp-file "usage-addfail-" t))
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
            (call-process "git" nil nil nil "add" "-A")
            (call-process "git" nil nil nil "commit" "-qm" "init"))
          ;; Break the index: .git/index.lock as a DIRECTORY makes
          ;; `git add` fail (cannot create the real index.lock).
          (make-directory (expand-file-name ".git/index.lock" repo-dir) t)
          (iar--usage-reset)
          (setq iar--usage-requests 1 iar--usage-input-tokens 10
                iar--usage-output-tokens 5 iar--usage-model "m")
          (should (eq (iar--usage-write-log-now) nil)))
      (delete-directory tmpdir :recursive))))

(ert-deftest test-tool-call-usage-write-log-now-refusal-honest-nil ()
  "c364: a pre-commit hook REFUSAL must return nil, not be conflated
with 'nothing to commit' (exit 1). Production case: continuo
2026-09-15 10:35Z -- the HISTORY-CLOCK guard refused her belt commit
(fabricated timestamp), the belt read exit 1 as durable-success, and
her record rode undurable until a sibling healed it."
  (let* ((tmpdir (make-temp-file "usage-refusal-" t))
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
            ;; A pre-commit hook that ALWAYS refuses (prints REFUSED,
            ;; exits 1) -- the guard shape.
            (make-directory ".git/hooks" :parents)
            (with-temp-file ".git/hooks/pre-commit"
              (insert "#!/bin/sh\necho 'REFUSED by test guard' >&2\nexit 1\n"))
            (call-process "chmod" nil nil nil "+x" ".git/hooks/pre-commit")
            (call-process "git" nil nil nil "add" "-A")
            (call-process "git" nil nil nil "commit" "-qm" "init"))
          (iar--usage-reset)
          (setq iar--usage-requests 3 iar--usage-input-tokens 100
                iar--usage-output-tokens 40 iar--usage-model "m")
          ;; The belt must report NOT durable (nil), not hollow-success.
          (should (eq (iar--usage-write-log-now) nil)))
      (delete-directory tmpdir :recursive))))

(ert-deftest test-tool-call-usage-write-log-dedupe-different-timestamp ()
  "c58: belt#2 and the kill-emacs-hook write within one close
straddle the close-out work, so their TIMESTAMPS differ while the
COUNTS are identical (production census 2026-09-18: 20/20 continuo
closes double-wrote, 14s apart). The c262 guard compared the full
line including the timestamp and NEVER fired. The guard must compare
content: same counts, different stamp = skip."
  (let* ((tmpdir (make-temp-file "usage-dedupe-ts-" t))
         (iar-personalization-path tmpdir)
         (iar-audit-path "audit")
         (iar--current-agent-name "testagent")
         (iar--current-project "testproject"))
    (unwind-protect
        (progn
          (iar--usage-reset)
          (setq iar--usage-requests 80 iar--usage-input-tokens 2744593
                iar--usage-output-tokens 57704 iar--usage-model "nemotron")
          (should (eq (iar--usage-write-log) t))
          ;; Simulate the second write landing after the timestamp
          ;; changed: monkey-patch format-time-string for this call.
          (cl-letf (((symbol-function 'format-time-string)
                     (lambda (fmt &optional _time _zone)
                       (should (string-equal fmt "%Y-%m-%d %H:%M:%S"))
                       "2026-09-18 10:22:03")))
            (should (eq (iar--usage-write-log) nil))) ; dup: skipped
          (with-temp-buffer
            (insert-file-contents
             (expand-file-name "audit/testproject/testagent/USAGE.log" tmpdir))
            (should (equal (count-lines (point-min) (point-max)) 1))))
      (delete-directory tmpdir :recursive))))
