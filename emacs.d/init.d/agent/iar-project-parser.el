;; -*- lexical-binding: t; -*-

;;; Project Parser -- Parse project.org files from personalization/projects/
;;
;; A project defines:
;; - #+KNOWLEDGE: which doc labels to auto-load (subdirs of docs/)
;; - #+TOOLS: which tools to register (tool name strings)
;; - #+MOUNTS: host paths to mount into the container, with optional :rw/:ro suffix
;; - #+CONTAINERS: which purpose-specific containers are available (target names)
;; - #+MCP: which MCP servers to activate (server names from iar-mcp-servers)
;; - #+OBJECTIVE: free-text scope/goal injected into the prompt
;;
;; #+MOUNTS format: space-separated list of path:mode pairs.
;;   #+MOUNTS: /path/to/repo:rw /path/to/infra:ro
;; If no :mode suffix, defaults to :rw.
;;
;; #+CONTAINERS format: space-separated list of target names.
;;   #+CONTAINERS: pentest concepts life-org
;; When present, execute_code_remote tool is registered (implied by
;; #+CONTAINERS, does not need to be listed in #+TOOLS).
;;
;; #+MCP format: space-separated list of MCP server names.
;;   #+MCP: burp
;; When present, MCP servers are started at session start and their
;; tools are registered alongside native i.ar tools.
;;
;; If #+TOOLS is absent, all tools are registered (backward compat).
;; If #+KNOWLEDGE is absent, no docs are auto-loaded.
;; If #+MOUNTS is absent, no project-specific mounts.
;; If #+CONTAINERS is absent, no containers are available.
;; If #+MCP is absent, no MCP servers are activated.
;; If #+OBJECTIVE is absent, no objective text is injected.

(require 'cl-lib)
(require 'subr-x)

;; Declared in configs/paths.el (loaded before init.d modules).
(defvar iar-projects-path nil
  "Relative path to project definition files.")

;; Forward-declared: owned by configs/paths.el.
(defvar iar-personalization-path nil
  "Absolute path to the personalization mount point.")

(defun iar--projects-dir ()
  "Return the absolute path to the projects directory."
  (expand-file-name iar-projects-path iar-personalization-path))

(defun iar--project-candidates ()
  "Build a list of selectable project candidates.
Returns a list of cons cells (NAME . PATH) where NAME is the project
name (file base name) and PATH is the full path to the .org file."
  (let ((pdir (iar--projects-dir))
        candidates)
    (when (file-directory-p pdir)
      (dolist (entry (directory-files pdir nil "\\.org\\'" t))
        (let ((full-path (expand-file-name entry pdir)))
          (when (file-regular-p full-path)
            (let ((name (file-name-base entry)))
              (push (cons name full-path) candidates))))))
    (nreverse (sort candidates (lambda (a b) (string< (car a) (car b)))))))

(defun iar--parse-mount-entry (entry)
  "Parse a single mount entry like \"/path:rw\" or \"/path\".
Returns a cons cell (PATH . MODE) where MODE is \"rw\" or \"ro\".
Defaults to \"rw\" if no mode suffix is present."
  (let* ((parts (split-string entry ":" t))
         (path (car parts))
         (mode (or (cadr parts) "rw")))
    (cons path mode)))

(defun iar--parse-project-metadata (content)
  "Parse project metadata from CONTENT.
Returns a plist with keys :knowledge, :tools, :mounts, :containers,
:mcp, :objective.
:knowledge is a list of strings (doc labels) or nil.
:tools is a list of strings (tool names) or nil (nil = all tools).
:mounts is a list of (PATH . MODE) cons cells or nil.
:containers is a list of strings (target names) or nil.
:mcp is a list of strings (MCP server names) or nil.
:objective is a string or nil."
  (let ((knowledge nil)
        (tools nil)
        (mounts nil)
        (containers nil)
        (mcp nil)
        (objective nil))
    ;; Parse #+KNOWLEDGE: space-separated list
    (when (string-match "^#\\+KNOWLEDGE:\\s-*\\(.+\\)$" content)
      (let ((raw (match-string 1 content)))
        (setq knowledge (split-string raw "\\s-+" t))))
    ;; Parse #+TOOLS: space-separated list
    (when (string-match "^#\\+TOOLS:\\s-*\\(.+\\)$" content)
      (let ((raw (match-string 1 content)))
        (setq tools (split-string raw "\\s-+" t))))
    ;; Parse #+MOUNTS: space-separated list of path:mode pairs
    (when (string-match "^#\\+MOUNTS:\\s-*\\(.+\\)$" content)
      (let ((raw (match-string 1 content)))
        (setq mounts (mapcar #'iar--parse-mount-entry
                             (split-string raw "\\s-+" t)))))
    ;; Parse #+CONTAINERS: space-separated list of target names
    (when (string-match "^#\\+CONTAINERS:\\s-*\\(.+\\)$" content)
      (let ((raw (match-string 1 content)))
        (setq containers (split-string raw "\\s-+" t))))
    ;; Parse #+MCP: space-separated list of MCP server names
    (when (string-match "^#\\+MCP:\\s-*\\(.+\\)$" content)
      (let ((raw (match-string 1 content)))
        (setq mcp (split-string raw "\\s-+" t))))
    ;; Parse #+OBJECTIVE: free text (rest of line)
    (when (string-match "^#\\+OBJECTIVE:\\s-*\\(.+\\)$" content)
      (setq objective (string-trim (match-string 1 content))))
    (list :knowledge knowledge :tools tools
          :mounts mounts :containers containers
          :mcp mcp :objective objective)))

(defun iar--parse-project (path)
  "Parse a project.org file at PATH.
Returns a plist with keys :name, :knowledge, :tools, :mounts, :containers,
:mcp, :objective.
Signals an error if the file does not exist."
  (unless (file-exists-p path)
    (error "Project file not found: %s" path))
  (let* ((name (file-name-base path))
         (content (with-temp-buffer
                    (insert-file-contents path)
                    (buffer-string)))
         (metadata (iar--parse-project-metadata content)))
    (plist-put metadata :name name)))

(defun iar--load-project (name)
  "Load a project by name from personalization/projects/<name>.org.
Returns a plist with keys :name, :knowledge, :tools, :mounts, :containers,
:mcp, :objective.
Signals an error if the project is not found."
  (let* ((candidates (iar--project-candidates))
         (entry (assoc name candidates))
         (path (cdr entry)))
    (if (null path)
        (error "Project '%s' not found in %s" name (iar--projects-dir))
      (iar--parse-project path))))

(provide 'iar-project-parser)