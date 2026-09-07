;; -*- lexical-binding: t; -*-

;;; Agent Loader for gptel -- Assembly-based prompt construction
;;
;; Replaces the monolithic prompt.org loading with three-axis assembly:
;; Archetype (behavioral mode) + Personality (voice) + Project (knowledge/tools/objective).
;;
;; C-c a: Select personality -> assemble with interactive archetype + default project.
;; C-c p: Switch personality -> re-assemble with current archetype + project.
;;
;; The assembly engine (iar-prompt-assembly.el) handles:
;; - Reading archetype, personality, base_context
;; - Mode-based memory injection (LOGS.md or STATE.org)
;; - Auto-loading project knowledge
;; - Tool gating via #+TOOLS metadata
;; - Container injection via #+CONTAINERS metadata
;; - MCP server activation via #+MCP metadata

(require 'cl-lib)
(require 'subr-x)
(require 'iar-agent-utils)  ; iar--validate-agent-name, iar--path-traversal-check
(require 'iar-utils)  ; iar--non-blank-p
(require 'iar-prompt-assembly)
(require 'iar-project-parser)

(declare-function gptel-mode "gptel" (&optional arg))
(defvar gptel-mode-map)
(defvar gptel-tools)

;; Declared in configs/ (loaded before init.d modules).
(defvar iar-key-load-agent nil
  "Keybinding to load an agent personality.")
(defvar iar-key-load-personality nil
  "Keybinding to switch personality.")
(defvar iar-personalities-path nil
  "Relative path to personality definition files.")
(defvar iar-archetypes-path nil
  "Relative path to archetype definition files.")
(defvar iar-projects-path nil
  "Relative path to project definition files.")
(defvar iar-personalization-path nil
  "Absolute path to the personalization mount point.")

;; Declared in iar-knowledge-loader.el.
(defvar iar--knowledge-base-prompt nil)
(defvar iar--knowledge-loaded-labels nil)
(defvar iar--knowledge-blocks nil)

;; Declared in execute_code_remote.el.
(defvar iar--current-containers nil
  "List of container target names available in the current session.")

;;; --- Agent state variables ---

(defvar iar--current-agent-name nil
  "Name of the currently loaded personality (e.g., \"mirror\").
Set buffer-local by `iar-load-agent'. Alias for `iar--current-personality'
for backward compatibility with audit logging and path resolution.")

(defvar iar--current-agent-file nil
  "Full path to the currently loaded personality's .org file.
Set buffer-local by `iar-load-agent'. Kept for backward compat.")

(defvar-local iar--current-archetype nil
  "Name of the currently loaded archetype (e.g., \"interactive\").")

(defvar-local iar--current-personality nil
  "Name of the currently loaded personality (e.g., \"mirror\").")

(defvar-local iar--current-project nil
  "Name of the currently loaded project (e.g., \"default\").")

;;; --- Personality-to-archetype mapping ---

(defconst iar-personality-archetype-map
  '(("mirror" . "interactive")
    ("bessie" . "interactive")
    ("aria" . "aria-cycle") ; cycle runner only; interactive sessions hardcode interactive (C-c a)
    ("continuo" . "aria-cycle") ; second cycle agent (sibling); same runner, rotated by timer
    ("darwin" . "autonomous")
    ("gardener" . "continuous")
    ("librarian" . "continuous")
    ("agent-assistant" . "agent-assistant")
    ("implementer" . "implementer")
    ("reviewer" . "reviewer")
    ("pentest" . "interactive"))
  "Mapping from personality names to default archetype names.
Used by the cycle runner to determine the archetype from the --agent flag.")

;;; --- Personality discovery ---

(defun iar--personality-names ()
  "Return a list of available personality names (strings).
Reads from agents.d/personalities/*.org."
  (let ((pdir (expand-file-name iar-personalities-path user-emacs-directory))
        names)
    (when (file-directory-p pdir)
      (dolist (entry (directory-files pdir nil "\\.org\\'" t))
        (push (file-name-base entry) names)))
    (sort names #'string<)))

(defun iar--archetype-for-personality (personality-name)
  "Return the default archetype for PERSONALITY-NAME.
Looks up `iar-personality-archetype-map'. Returns \"interactive\" if
the personality is not in the map."
  (or (cdr (assoc personality-name iar-personality-archetype-map))
      "interactive"))

(defconst iar-personality-project-map
  '(("bessie" . "moto"))
  "Mapping from personality names to project names.
Explicit override used by `iar--project-for-personality' when the
project name differs from the personality name. Checked before the
personality-name-as-project convention. Personalities not listed
here resolve by convention: project file matching the personality
name, else the \"iar\" default project.")

(defun iar--project-for-personality (personality-name)
  "Return the project name for PERSONALITY-NAME.
Resolution order:
1. `iar-personality-project-map' -- explicit personality->project override
2. Project file matching the personality name (convention)
3. \"iar\" -- default project"
  (or (cdr (assoc personality-name iar-personality-project-map))
      (let ((project-path (expand-file-name
                           (format "%s.org" personality-name)
                           (expand-file-name iar-projects-path iar-personalization-path))))
        (if (file-exists-p project-path)
            personality-name
          "iar"))))

;;; --- Assembly and buffer setup ---

(defun iar--setup-assembled-buffer (archetype personality project &optional extra-knowledge)
  "Assemble prompt and set up buffer-local state.
ARCHETYPE, PERSONALITY, PROJECT are name strings.
Sets gptel-system-prompt, gptel-tools, and all tracking variables.
EXTRA-KNOWLEDGE (optional list of strings) appends extra knowledge
labels to the project's #+KNOWLEDGE (see `iar--assemble-prompt').
Returns the assembled plist."
  (let ((result (iar--assemble-prompt archetype personality project extra-knowledge)))
    (setq-local gptel-system-prompt (plist-get result :prompt))
    (setq-local gptel-tools (plist-get result :tools))
    (setq-local iar--current-archetype archetype)
    (setq-local iar--current-personality personality)
    (setq-local iar--current-project project)
    ;; Container targets from #+CONTAINERS (used by execute_code_remote)
    (setq-local iar--current-containers (plist-get result :containers))
    ;; MCP servers from #+MCP (used by iar-mcp-setup)
    (setq-local iar--current-mcp-servers (plist-get result :mcp))
    ;; Start MCP servers and register their tools
    (when (fboundp 'iar-mcp-setup-session)
      (iar-mcp-setup-session (plist-get result :mcp)))
    ;; Backward compat: agent-name = personality name
    ;; setq-default, NOT setq: after setq-local, a bare setq rebinds the
    ;; BUFFER-LOCAL value and the global default stays nil -- async tool
    ;; sentinels and kill-emacs then resolve agent=nil (4238 audit lines
    ;; said nil/unknown, 2026-08-31).
    (setq-local iar--current-agent-name personality)
    (setq-default iar--current-agent-name personality)
    ;; Backward compat: agent-file = personality file path
    (let ((pers-path (expand-file-name
                      (format "%s.org" personality)
                      (expand-file-name iar-personalities-path user-emacs-directory))))
      (setq-local iar--current-agent-file pers-path)
      (setq-default iar--current-agent-file pers-path))
    ;; Reset knowledge state (manual C-c k loads stack on top)
    ;; Set loaded labels from auto-loaded knowledge so C-c i can report them
    (setq-local iar--knowledge-base-prompt nil)
    (setq-local iar--knowledge-loaded-labels (plist-get result :knowledge-labels))
    (setq-local iar--knowledge-blocks nil)
    result))

;;; --- Interactive commands ---

(defun iar-load-agent ()
  "Prompt user to select a personality and assemble the system prompt.
Uses the interactive archetype + selected personality + default project.
This is the primary entry point for interactive sessions (C-c a)."
  (interactive)
  (let* ((names (iar--personality-names))
         (_ (unless names
              (user-error "No personalities found in %s"
                          (expand-file-name iar-personalities-path user-emacs-directory))))
         (chosen (completing-read "Select Personality: " names nil t))
         (archetype "interactive")
         (project (iar--project-for-personality chosen)))
    (unless (bound-and-true-p gptel-mode)
      (gptel-mode 1))
    (let ((result (iar--setup-assembled-buffer archetype chosen project)))
      (message "[OK] Personality %s loaded! Archetype: %s, Project: %s. Prompt: %d chars (~%d tokens)"
               chosen archetype project
               (length (plist-get result :prompt))
               (/ (length (plist-get result :prompt)) 4)))))

(defun iar-load-personality (name)
  "Non-interactively switch personality to NAME.
Re-assembles the prompt with the current archetype and project.
Returns t if loaded, nil if personality not found."
  (let* ((names (iar--personality-names))
         (archetype (or iar--current-archetype "interactive"))
         (project (iar--current-project-name)))
    (if (not (member name names))
        (progn
          (message "[personality] '%s' not found" name)
          nil)
      (let ((result (iar--setup-assembled-buffer archetype name project)))
        (message "[personality] Switched to '%s'. Prompt: %d chars (~%d tokens)"
                 name (length (plist-get result :prompt))
                 (/ (length (plist-get result :prompt)) 4))
        t))))

(defun iar-load-personality-interactive ()
  "Prompt user to select a personality and switch to it.
Re-assembles the prompt with the current archetype and project.
This is C-c p -- switch personality mid-session."
  (interactive)
  (unless (bound-and-true-p gptel-mode)
    (gptel-mode 1))
  (let* ((names (iar--personality-names))
         (_ (unless names
              (user-error "No personalities found in %s"
                          (expand-file-name iar-personalities-path user-emacs-directory))))
         (name (completing-read "Switch personality: " names nil t)))
    (iar-load-personality name)))

(defun iar-personality-info ()
  "Return a string describing the currently loaded personality.
Used by iar-prompt-info to display personality in the prompt breakdown."
  (or (iar--current-personality-name)
      "none"))

(with-eval-after-load 'gptel
  (keymap-set gptel-mode-map iar-key-load-agent #'iar-load-agent)
  (keymap-set gptel-mode-map iar-key-load-personality #'iar-load-personality-interactive))

(provide 'iar-agent-loader)