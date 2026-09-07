;; -*- lexical-binding: t; -*-
;; Belt #2 tests (continuo cycle 55): iar--usage-write-log-now.
;; The pre-exit usage write (c54, a7e1cf5) had no direct tests: the
;; orphan-write race fix was production-observed but never pinned by
;; the suite. These tests pin: (1) it returns t on success and writes
;; the line, (2) it never signals when the write path is broken
;; (exit path must not break), (3) it is idempotent in effect with
;; the kill-emacs-hook write (two calls = two lines, both parseable).

(require 'ert)

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
  "Two writes (pre-exit + hook net) = two lines, both parseable."
  (let* ((tmpdir (make-temp-file "usage-now-" t))
         (iar-personalization-path tmpdir)
         (iar-audit-path "audit")
         (iar--current-agent-name "testagent")
         (iar--current-project "testproject"))
    (unwind-protect
        (progn
          (iar--usage-reset)
          (iar--usage-write-log-now)
          (iar--usage-write-log)        ; the kill-emacs-hook net
          (with-temp-buffer
            (insert-file-contents
             (expand-file-name "audit/testproject/testagent/USAGE.log" tmpdir))
            (should (equal (count-lines (point-min) (point-max)) 2))
            ;; Both lines carry the full field set (newline guard holds).
            (goto-char (point-min))
            (should (looking-at "^\\[.*\\] requests=[0-9]+ input=[0-9]+ output=[0-9]+ total=[0-9]+ model="))
            (forward-line 1)
            (should (looking-at "^\\[.*\\] requests=[0-9]+ input=[0-9]+ output=[0-9]+ total=[0-9]+ model="))))
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
  "Belt #2 commit targets ONLY USAGE.log -- never sweeps siblings."
  (let* ((tmpdir (make-temp-file "usage-sweep-" t))
         (repo-dir (expand-file-name "repo" tmpdir))
         (iar-personalization-path repo-dir)
         (iar-audit-path "audit")
         (iar--current-agent-name "testagent")
         (iar--current-project "testproject")
         (sibling-file (expand-file-name "audit/testproject/testagent/JOURNAL.org" repo-dir)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory sibling-file) t)
          (with-temp-file sibling-file (insert "sibling uncommitted work\n"))
          (let ((default-directory repo-dir))
            (call-process "git" nil nil nil "init" "-q")
            (call-process "git" nil nil nil "config" "user.name" "Test")
            (call-process "git" nil nil nil "config" "user.email" "t@i.ar")
            (call-process "git" nil nil nil "add" "-A")
            (call-process "git" nil nil nil "commit" "-qm" "init"))
          ;; Modify the sibling file AFTER init -- it must stay
          ;; uncommitted through belt #2's commit.
          (with-temp-file sibling-file (insert "sibling NEW uncommitted work\n"))
          (iar--usage-reset)
          (setq iar--usage-requests 1 iar--usage-input-tokens 10
                iar--usage-output-tokens 5 iar--usage-model "m")
          (should (eq (iar--usage-write-log-now) t))
          ;; The sibling's change is NOT in the belt #2 commit.
          (let ((default-directory repo-dir))
            (call-process "git" nil nil nil "status" "--porcelain"))
          (with-temp-buffer
            (let ((default-directory repo-dir))
              (call-process "git" nil t nil "diff" "--" "audit/testproject/testagent/JOURNAL.org"))
            (should (string-match-p "sibling NEW" (buffer-string)))))
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
