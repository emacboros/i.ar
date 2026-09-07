;; -*- lexical-binding: t; -*-

;;; Shared Utilities for i.ar Agent System
;;
;; Common helper functions extracted from multiple modules to eliminate
;; DRY violations.  Loaded before all other init.d modules.
;;
;; Consolidates:
;; - Agent name resolution (was duplicated in iar-audit-log, iar-buffer-monitor,
;;   iar-request-logger, iar-fsm-tracer, task_tools, iar-reload-tools)
;; - File reading helpers (was duplicated in read_task, read_knowledge,
;;   read_roadmap, read_history, prompt-loader, prompt-assembly)
;; - Approximate token counting (was duplicated in iar-knowledge-loader,
;;   iar-buffer-monitor)
;; - Audit log path (was duplicated in iar-audit-log, iar-buffer-monitor)
;; - Save hook suppression macro (was in fs_tools, needed by
;;   replacement_tool)

(require 'subr-x)

;; Declared in configs/ (split parameter files) (loaded before init.d modules).
;; Forward-declared: owned by configs/paths.el.
(defvar iar-personalization-path nil
  "Absolute path to the personalization mount point.")
(defvar iar-audit-path nil
  "Relative path to audit log directory.")

;;; --- Agent name resolution ---

(defun iar--get-agent-name ()
  "Return the current agent name, or nil if none is set.
Checks `iar--current-agent-name' (buffer-local, set by
iar-agent-loader or iar-agent-cycle).  Falls back to the global
default value (set by agent-cycle for process-buffer contexts).
Then falls back to deriving the name from `iar--current-agent-file'
(the prompt.org path), checking buffer-local then global default.
Returns nil if none are set.

This function is called from debug module advice (iar-status-mode)
and the tool call layer, which run in gptel's process buffers, not
in the gptel conversation buffer.  The agent name is set
buffer-locally in the conversation buffer AND as a global default
so it is visible in process buffer contexts."
  (let ((name (if (boundp 'iar--current-agent-name)
                  (or (and (local-variable-p 'iar--current-agent-name)
                           iar--current-agent-name)
                      (default-value 'iar--current-agent-name))
                nil)))
    (or name
        (let ((file (if (boundp 'iar--current-agent-file)
                        (or (and (local-variable-p 'iar--current-agent-file)
                                 iar--current-agent-file)
                            (default-value 'iar--current-agent-file))
                      nil)))
          (when file
            (file-name-nondirectory
             (directory-file-name
              (file-name-directory file))))))))

;;; --- Non-blank string check ---

(defun iar--non-blank-p (string)
  "Return non-nil if STRING is a non-blank string (contains at least one non-whitespace char).
Returns nil for nil, empty strings, and whitespace-only strings."
  (and (stringp string)
       (string-match-p "\\S-" string)))

;;; --- Path traversal defense ---

(defun iar--path-traversal-check (path base-dir)
  "Check that PATH (expanded) does not escape BASE-DIR (expanded).
Uses `file-truename' to resolve symlinks before checking.
Returns PATH if safe, signals an error if traversal is detected.
If `file-truename' fails on PATH (file doesn't exist yet), falls back
to the expanded path and checks against the truename of BASE-DIR."
  (let* ((base-real (file-truename base-dir))
         (path-real (condition-case nil
                        (file-truename path)
                      (error path))))
    ;; Separator-aware prefix check: require base to match up to a path
    ;; separator. A bare string-prefix-p would accept /base-evil as inside
    ;; /base (prefix collision between sibling directories). Appending "/"
    ;; to both sides makes the boundary exact and still accepts the
    ;; path == base case.
    (if (string-prefix-p (concat base-real "/") (concat path-real "/"))
        path
      (error "Path traversal attempt blocked: '%s' escapes '%s'" path base-dir))))

;;; --- File reading helpers ---

(defun iar--read-file-string (filepath)
  "Read FILEPATH and return its trimmed contents as a string.
Returns nil if the file does not exist."
  (when (file-exists-p filepath)
    (with-temp-buffer
      (insert-file-contents filepath)
      (string-trim (buffer-string)))))

(defun iar--read-description-org (dir)
  "Read the description.org file in DIR.
Returns the trimmed content as a string, or nil if not found."
  (iar--read-file-string (expand-file-name "description.org" dir)))

(defun iar--dirs-with-description (dir)
  "Return a list of subdirectory paths in DIR that contain a description.org.
Only subdirectories with a description.org file are included.
Sorted alphabetically.  Hidden directories (starting with .) are excluded."
  (let (entries)
    (when (file-directory-p dir)
      (dolist (entry (directory-files dir t "^[^.]" t))
        (when (and (file-directory-p entry)
                   (file-exists-p (expand-file-name "description.org" entry)))
          (push entry entries))))
    (nreverse (sort entries #'string<))))

;;; --- Approximate token counting ---

(defun iar--approx-token-count (chars)
  "Return an approximate token count for CHARS (a character count).
Uses the heuristic of ~4 characters per token, which is a rough
estimate for English text and code.  Not exact, but sufficient
for detecting context window overflow before it happens.
Returns 0 for nil, negative, or zero input."
  (if (or (null chars) (<= chars 0))
      0
    (/ chars 4)))

;;; --- Audit log path ---

(defconst iar--audit-log-path
  (expand-file-name "audit.log"
                    (expand-file-name iar-audit-path iar-personalization-path))
  "Path to the central audit log for all agent file operations.")

;;; --- Save hook suppression ---

(defmacro iar--with-suppressed-save-hooks (&rest body)
  "Execute BODY with all save-related hooks bound to nil.
This prevents user-configured hooks (format-on-save, lint-on-save,
trailing-whitespace cleanup, VC annotations, etc.) from mutating
content during programmatic saves."
  (declare (indent 0))
  `(let ((before-save-hook nil)
         (after-save-hook nil)
         (write-file-functions nil)
         (write-contents-functions nil)
         (write-region-annotate-functions nil))
     ,@body))

(defun iar--format-size (chars)
  "Format CHARS (a character count, integer) as a human-readable size string."
  (let ((tokens (iar--approx-token-count chars)))
    (format "%d chars (~%d tokens)" chars tokens)))

(provide 'iar-utils)