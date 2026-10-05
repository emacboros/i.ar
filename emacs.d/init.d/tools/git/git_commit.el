;; -*- lexical-binding: t; -*-

;;; git_commit tool for gptel
;; Stage all changes and commit in a git repository.
;;
;; This is a SYNC tool (local git operations are fast).  It runs
;; git add -A && git commit in the specified repository directory.
;; Git identity (user.name, user.email) is set if not already configured.
;;
;; This tool exists so continuous agents can persist their work without
;; needing execute_code_local for git operations.  It uses call-process
;; directly -- no shell, no injection surface.
;;
;; Resurrection guard (c270): a stale checkout that still has a
;; gitignored rolling transcript (audit/<agent>/cycle.log) tracked
;; re-adds it on every `git add -A' -- a tracked file ignores
;; .gitignore, so the 85MB transcript came back on every commit (109
;; commits carried ~6.7GiB of blobs before the re-untrack).  After
;; add -A, staged paths matching `iar-git-commit-refuse-pattern' are
;; unstaged and reported.  Dated transcripts (cycle-YYYY-MM-DD.log)
;; deliberately do NOT match: those are tracked intentionally via the
;; belt discipline.
;;
;; Audit: every commit is logged to the central audit log.

(require 'iar-tool-call)
(require 'iar-utils)

;; Declared in configs/ (split parameter files) (loaded before init.d modules).
(defvar iar-git-author-name nil
  "Default git author name for agent commits.")
(defvar iar-git-author-email nil
  "Default git author email for agent commits.")

(defvar iar-git-commit-refuse-pattern "\\`audit/.*cycle\\.log\\'"
  "Staged paths matching this regexp are unstaged before commit.
These are the rolling raw session transcripts (audit/<agent>/cycle.log):
gitignored by policy and never wanted in git.  The only way they get
staged is a stale checkout that still tracks them (the c270
resurrection vector).  Dated transcripts (cycle-YYYY-MM-DD.log) do not
match and remain committable via `git add -f' (belt discipline).")

(defun iar--git-run (repo-dir &rest args)
  "Run git with ARGS in REPO-DIR.
Returns (exit-code . output-string).  Uses call-process directly --
no shell interpretation."
  (with-temp-buffer
    (let ((default-directory (expand-file-name repo-dir)))
      (cons (apply #'call-process "git" nil t nil args)
            (buffer-string)))))

(defun iar--git-ensure-identity (repo-dir)
  "Ensure git user.name and user.email are set in REPO-DIR.
Sets them from iar-git-author-name and iar-git-author-email if not
already configured.  Returns t if identity is set, nil if it cannot
be set (missing config)."
  (let ((name-result (iar--git-run repo-dir "config" "user.name"))
        (email-result (iar--git-run repo-dir "config" "user.email")))
    (when (and (/= 0 (car name-result))
               iar-git-author-name)
      (iar--git-run repo-dir "config" "user.name" iar-git-author-name))
    (when (and (/= 0 (car email-result))
               iar-git-author-email)
      (iar--git-run repo-dir "config" "user.email" iar-git-author-email))
    (let ((name-check (iar--git-run repo-dir "config" "user.name"))
          (email-check (iar--git-run repo-dir "config" "user.email")))
      (and (= 0 (car name-check))
           (= 0 (car email-check))))))

(defun iar--git-unstage-refused (repo-dir)
  "Unstage staged paths in REPO-DIR matching `iar-git-commit-refuse-pattern'.
Returns the list of unstaged paths (empty if none).  Runs after
`git add -A' and before the commit.  This is the c270 resurrection
guard: a tracked-but-ignored rolling transcript swept back in by
add -A on every commit in a stale checkout."
  (let* ((staged-result (iar--git-run repo-dir "diff" "--cached" "--name-only"))
         (staged (when (= 0 (car staged-result))
                   (split-string (cdr staged-result) "\n" t)))
         (offenders (seq-filter
                     (lambda (path)
                       (string-match-p iar-git-commit-refuse-pattern path))
                     staged)))
    (dolist (path offenders)
      (iar--git-run repo-dir "rm" "--cached" "--quiet" path))
    offenders))

;; 0126 (Nacho approved 2026-10-05): the foreign-tree commit guard.
;; c540/c546 evidence: belt commits carried the OTHER agent's audit
;; files (3 her-roadmap rides, 0 reverse; one deliberate add of a file
;; I did not write in a state I did not check). The staged-set is the
;; right seam: it covers add -A sweeps AND explicit adds, at commit
;; time where the damage actually happens.
;;
;; Rule: staged paths under ANOTHER agent's audit/ tree are unstaged
;; and reported (hard refuse -- no agent ever has a reason to commit
;; another agent's audit tree). Staged paths under another agent's
;; tasks/ tree are also refused UNLESS IAR_ALLOW_FOREIGN=1 is set in
;; the environment (heals legitimately touch the other's tasks; the
;; override makes that deliberate).

(defvar iar-git-foreign-audit-refusals nil
  "Foreign audit paths unstaged by the last git_commit (for tests).")

(defun iar--git-agent-of-path (path)
  "Return the agent name embedded in an audit/ or tasks/ PATH, or nil.
audit/iar/aria/x.org -> aria; tasks/iar/continuo/foo -> continuo.
Shape: <top>/<project>/<agent>/... -- the agent is segment 3."
  (when (stringp path)
    (let ((segments (split-string path "/" t)))
      (when (>= (length segments) 3)
        (let ((top (nth 0 segments))
              (agent (nth 2 segments)))
          (when (and (member top '("audit" "tasks"))
                     (string-match-p "^[a-z][a-z0-9-]*$" agent))
            agent))))))

(defun iar--git-unstage-foreign (repo-dir agent)
  "Unstage staged paths in REPO-DIR belonging to OTHER agents'
audit/ or tasks/ trees. AUDIT paths: hard refuse. TASKS paths:
refuse unless the IAR_ALLOW_FOREIGN env var is set (deliberate
heal override). Returns the list of refused paths."
  (let* ((staged-result (iar--git-run repo-dir "diff" "--cached" "--name-only"))
         (staged (when (= 0 (car staged-result))
                   (split-string (cdr staged-result) "
" t)))
         (allow-foreign (equal (getenv "IAR_ALLOW_FOREIGN") "1"))
         refused)
    (dolist (path staged)
      (let ((owner (iar--git-agent-of-path path)))
        (when (and owner agent (not (equal owner agent)))
          (let ((audit-p (string-prefix-p "audit/" path))
                (tasks-p (string-prefix-p "tasks/" path)))
            (when (or audit-p
                      (and tasks-p (not allow-foreign)))
              (push path refused)
              (iar--git-run repo-dir "rm" "--cached" "--quiet" path))))))
    (setq refused (nreverse refused))
    (setq iar-git-foreign-audit-refusals refused)
    (when refused
      (message "[git-commit] FOREIGN-TREE refuse: unstaged %s (agent %s%s)"
               (mapconcat #'identity refused ", ")
               agent
               (if allow-foreign " -- IAR_ALLOW_FOREIGN ignored for audit paths" "")))
    refused))

(defun iar--tool-git-commit (repo_path message)
  "Stage all changes and commit in REPO_PATH with MESSAGE.
Returns a string starting with Success: or Error:."
  (let* ((repo-dir (expand-file-name repo_path))
         (agent (iar--get-agent-name)))
    (cond
     ((not (file-directory-p repo-dir))
      (format "Error: Repository directory does not exist: %s" repo-dir))
     ((not (file-directory-p (expand-file-name ".git" repo-dir)))
      (format "Error: Not a git repository (no .git directory): %s" repo-dir))
     ((or (null message) (string-empty-p message))
      "Error: Commit message is empty. Provide a non-empty commit message.")
     (t
      (let ((identity-ok (iar--git-ensure-identity repo-dir)))
        (unless identity-ok
          (iar--git-run repo-dir "config" "user.name" "i.ar Agent")
          (iar--git-run repo-dir "config" "user.email"
                       (format "%s@i.ar.local" agent))))
      (let ((add-result (iar--git-run repo-dir "add" "-A")))
        (if (/= 0 (car add-result))
            (format "Error: git add -A failed: %s" (cdr add-result))
          (let* ((refused (append (iar--git-unstage-foreign repo-dir agent)
                                  (iar--git-unstage-refused repo-dir)))
                 (refused-note (if refused
                                   (format "\nNote: refused to stage file(s): %s"
                                           (mapconcat #'identity refused ", "))
                                 ""))
                 (status-result (iar--git-run repo-dir "diff" "--cached" "--quiet")))
            (if (= 0 (car status-result))
                (format "Success: No changes to commit. Working tree is clean.%s"
                        refused-note)
              (let* ((commit-result (iar--git-run repo-dir "commit" "-m" message))
                     (exit-code (car commit-result))
                     (output (cdr commit-result)))
                (if (= 0 exit-code)
                    (format "Success: Committed in %s\n%s%s"
                            repo-dir (string-trim output) refused-note)
                  (format "Error: git commit failed (exit %d): %s"
                          exit-code output)))))))))))

(iar-tool-register
 (gptel-make-tool
  :name "git_commit"
  :description "Stage all changes and commit in a git repo. Git identity auto-configured. Refuses to stage gitignored rolling transcripts (audit/*/cycle.log)."
  :args (list '(:name "repo_path" :type "string" :description "Absolute path to repo root (must contain .git).")
              '(:name "message" :type "string" :description "Commit message describing what was changed. Keep it concise but descriptive."))
  :function #'iar--tool-git-commit))

(provide 'iar-tool--git-commit)