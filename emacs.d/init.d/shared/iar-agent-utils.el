;; -*- lexical-binding: t; -*-

;;; Shared Agent Utilities
;; Validation and path resolution functions used across multiple modules.
;;
;; Path resolution is per-project:
;; - Tasks: tasks/<project>/
;; - Audit: audit/<project>/<personality>/
;;
;; The current project is set by iar.sh --project flag (via IAR_PROJECT env var)
;; and stored in iar--current-project. The current personality is set by
;; iar-load-agent (C-c a) and stored in iar--current-personality.

(require 'cl-lib)
(require 'subr-x)
(require 'iar-utils)  ; iar--get-agent-name, iar--path-traversal-check

;; Declared in configs/ (split parameter files) (loaded before init.d modules).
;; Forward-declared: owned by configs/paths.el.
(defvar iar-personalization-path nil
  "Absolute path to the personalization mount point.")
(defvar iar-tasks-path nil
  "Relative path to task files directory.")
(defvar iar-audit-path nil
  "Relative path to audit log directory.")

;; Declared in configs/tasks.el
(defvar iar-task-description-limit nil
  "Maximum character length for a task description in create_task.")

;; Declared in iar-agent-loader.el
(defvar iar--current-project nil
  "Name of the currently loaded project.")
(defvar iar--current-personality nil
  "Name of the currently loaded personality.")

;;; --- Validation helpers ---

(defun iar--valid-name-p (name)
  "Return non-nil if NAME is a valid agent or task name.
Valid names consist only of alphanumeric characters, hyphens, and
underscores, with at least one character."
  (and (stringp name)
       (string-match-p "\\`[a-zA-Z0-9_-]+\\'" name)))

(defun iar--validate-agent-name (name)
  "Validate that NAME is a safe agent name, or signal an error.
Returns NAME if valid."
  (unless (iar--valid-name-p name)
    (error "Invalid agent name: '%s'. Only letters, digits, hyphens, and underscores are allowed." name))
  name)

(defun iar--validate-task-path (path)
  "Validate that PATH is a safe slash-separated task path.
Each segment must match `iar--valid-name-p'.  Empty or nil paths
are rejected."
  (when (or (null path) (not (stringp path)) (string-empty-p (string-trim path)))
    (error "Invalid task path: empty or nil"))
  (let ((segments (split-string path "/" t)))
    (when (null segments)
      (error "Invalid task path: '%s'" path))
    (dolist (seg segments)
      (unless (iar--valid-name-p seg)
        (error "Invalid task path segment: '%s'. Only letters, digits, hyphens, and underscores allowed." seg)))
    path))

;;; --- Project and personality resolution ---

(defun iar--current-project-name ()
  "Return the current project name.
Checks `iar--current-project' (buffer-local, set by C-c a or iar.sh).
Falls back to IAR_PROJECT env var.  Falls back to \"iar\" for
interactive sessions without --project flag."
  (or (and (boundp 'iar--current-project) iar--current-project)
      (getenv "IAR_PROJECT")
      "iar"))

(defun iar--current-personality-name ()
  "Return the current personality name.
Checks `iar--current-personality' (buffer-local, set by C-c a).
Falls back to `iar--get-agent-name' (which checks
`iar--current-agent-name' and `iar--current-agent-file').
Returns nil if no personality is set."
  (or (and (boundp 'iar--current-personality) iar--current-personality)
      (iar--get-agent-name)))

;;; --- Path resolution (per-project) ---

(defun iar--resolve-project-tasks-dir ()
  "Return the tasks directory path for the current project.
Tasks live at /root/personalization/tasks/<project>/, or
/root/personalization/tasks/<project>/<personality>/ when a
personality is active -- two agents sharing a project must not
share one ROADMAP.org (the 2026-09-03 clobber: continuo's
write_roadmap overwrote aria's rewrite, both trees clean,
file wrong, because tasks/* is gitignored)."
  (let* ((base-path (expand-file-name iar-tasks-path iar-personalization-path))
         (project (iar--current-project-name))
         (personality (iar--current-personality-name)))
    (iar--validate-agent-name project)
    (let ((resolved (if personality
                        (progn
                          (iar--validate-agent-name personality)
                          (expand-file-name personality
                                            (expand-file-name project base-path)))
                      (expand-file-name project base-path))))
      (iar--path-traversal-check resolved base-path))))

;;; --- Task path resolution ---

(defun iar--resolve-task-dir (task-path)
  "Resolve TASK-PATH to a directory within the current project's tasks dir.
TASK-PATH is a slash-separated path like i-ar-expansion/one-shot-model.
Returns the resolved directory path, or signals an error on invalid
input or path traversal."
  (setq task-path (iar--task-path-strip-agent-prefix task-path))
  (iar--validate-task-path task-path)
  (let* ((project-dir (iar--resolve-project-tasks-dir))
         (full-path (expand-file-name task-path project-dir)))
    (iar--path-traversal-check full-path project-dir)))

(defun iar--resolve-task-file (task-path)
  "Resolve TASK-PATH to a .org file within the current project's tasks dir.
TASK-PATH is a slash-separated path where the last segment is the filename.
Returns the resolved file path with .org extension, or signals an error
on invalid input or path traversal."
  (setq task-path (iar--task-path-strip-agent-prefix task-path))
  (iar--validate-task-path task-path)
  (let* ((project-dir (iar--resolve-project-tasks-dir))
         (full-path (expand-file-name (concat task-path ".org") project-dir)))
    (iar--path-traversal-check full-path project-dir)))

(defun iar--task-parent-path (task-path)
  "Return the parent path of TASK-PATH.
For a/b/c returns a/b. For a returns nil (top-level task)."
  (let ((segments (split-string task-path "/" t)))
    (if (<= (length segments) 1)
        nil
      (mapconcat #'identity (butlast segments) "/"))))

(provide 'iar-agent-utils)
;;; --- Task path prefix-doubling guard (2026-09-11, aria c208) ---
;; Regression for the doubled-path fossil layer: agents sometimes pass
;; a task path that ALREADY includes the project/personality prefix
;; ("iar/continuo/..."), producing tasks/<project>/<personality>/iar/
;; <project>/<personality>/... on disk. Untracked (gitignored), so the
;; fossils were invisible to git-based sweeps while staying readable by
;; find-based wake protocols. See knowledge/aria/
;; doubled-task-path-mechanism-2026-09-11.md.

(defun iar--task-path-strip-agent-prefix (task-path)
  "Strip a leading \"<project>/<personality>/\" prefix from TASK-PATH.
Agents frequently pass paths that already carry the project and
personality segments; expanding such a path onto the per-agent tasks
root doubles the prefix. Returns the path with the redundant prefix
removed, or TASK-PATH unchanged if it does not start with it."
  (let* ((project (ignore-errors (iar--current-project-name)))
         (personality (ignore-errors (iar--current-personality-name)))
         (prefix (and project personality
                      (format "%s/%s/" project personality))))
    (if (and prefix (string-prefix-p prefix task-path))
        (substring task-path (length prefix))
      task-path)))

(provide 'iar-agent-utils)
;;; ---------------------------------------------------------
;;; Shared abort-continue prompt (c80)
;;; ---------------------------------------------------------
;; The thinking-loop guard aborts runaway reasoning streams. When an
;; aborted turn is followed by a re-prompt, the re-prompt must CHANGE
;; THE QUESTION (law 41): "continue" re-enters the same thinking
;; pattern that just got aborted. This prompt is shared by the
;; delegate path (iar-delegate.el) and the cycle path
;; (iar-agent-cycle.el), so both layers re-prompt identically.
;; Lives in the shared layer because tools/agent/delegate.el loads
;; BEFORE agent/iar-agent-cycle.el (init.el order) -- a const owned
;; by either would be void for the other at load time.

(defconst iar--abort-continue-prompt
  "Your previous turn was ABORTED by the thinking-loop guard: over 16000
characters of reasoning with no output. Do NOT restart your thinking
from scratch -- the task context is unchanged. Skip extended thinking
entirely. Act NOW: either call the tools you need, or end your response
with your completion marker and a concise summary. Content first,
minimal reasoning."
  "Re-prompt inserted after a guard-aborted turn (delegate and cycle
layers). Law 41: change the question, not the volume.")

(provide 'iar-agent-utils)
