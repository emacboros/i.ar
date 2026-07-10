;; -*- lexical-binding: t; -*-

;;; Knowledge Loader for gptel
;; Allows the user to inject curated knowledge files (.md/.org) from
;; knowledge/<folder>/ into the current agent's system prompt.
;;
;; This separates agent PERSONALITY (prompt.org) from agent KNOWLEDGE
;; (knowledge files).  An agent's prompt.org defines who it is; the
;; knowledge files define what it knows about a specific subject.
;;
;; Usage: C-c k in gptel-mode.  Select a knowledge folder or a specific
;; file.  The content is appended to the system prompt with clear
;; delimiters so the LLM can distinguish personality from knowledge.
;;
;; Keybindings: C-c k (in gptel-mode)

(require 'cl-lib)
(require 'subr-x)

(declare-function gptel-mode "gptel" (&optional arg))
(defvar gptel-mode-map)

;;; --- Buffer-local state for knowledge injection ---

(defvar-local my-gptel--knowledge-base-prompt nil
  "The original system prompt BEFORE any knowledge was injected.
Nil means no knowledge has been loaded in this buffer.")

(defvar-local my-gptel--knowledge-loaded-label nil
  "Label describing the currently loaded knowledge (e.g., \"linux\").
Nil means no knowledge is currently loaded.")

;;; --- Knowledge directory ---

(defun my-gptel--knowledge-dir ()
  "Return the path to the knowledge directory."
  (expand-file-name "knowledge" user-emacs-directory))

(defun my-gptel--knowledge-candidates ()
  "Build a list of selectable knowledge candidates.
Returns a list of cons cells (DISPLAY . PATH) where:
- For folders: DISPLAY is \"folder/\" and PATH is the directory
- For files:   DISPLAY is \"folder/file.org\" and PATH is the file"
  (let ((kdir (my-gptel--knowledge-dir))
        candidates)
    (when (file-directory-p kdir)
      ;; List subdirectories (knowledge folders)
      (dolist (entry (directory-files kdir nil "\\`[a-zA-Z0-9_-]+\\'" t))
        (let ((full-path (expand-file-name entry kdir)))
          (when (file-directory-p full-path)
            ;; Add the folder itself
            (push (cons (format "%s/" entry) full-path) candidates)
            ;; Add individual files within the folder
            (dolist (file (directory-files full-path nil
                                          "\\.\\(md\\|org\\)\\'" t))
              (push (cons (format "%s/%s" entry file)
                          (expand-file-name file full-path))
                    candidates))))))
    (nreverse candidates)))

(defun my-gptel--read-knowledge-files (path)
  "Read all .md and .org files from PATH and return them as a string.
If PATH is a directory, reads all .md/.org files in it (non-recursive).
If PATH is a file, reads just that file.
Returns nil if no content was found."
  (let ((files
         (if (file-directory-p path)
             (sort
              (directory-files path t "\\.\\(md\\|org\\)\\'" t)
              #'string<)
           (and (file-exists-p path) (list path))))
        (parts nil))
    (dolist (file files)
      (let* ((fname (file-name-nondirectory file))
             (content (with-temp-buffer
                        (insert-file-contents file)
                        (string-trim-right (buffer-string) "\n"))))
        (when (and content (string-match-p "\\S-" content))
          (push (format "--- %s ---\n\n%s" fname content) parts))))
    (when parts
      (mapconcat #'identity (nreverse parts) "\n\n"))))

(defun my-gptel--knowledge-label (display path)
  "Generate a human-readable label for the loaded knowledge.
DISPLAY is the completing-read selection string.
PATH is the resolved filesystem path."
  (if (file-directory-p path)
      display  ; e.g., "linux/"
    (file-name-directory display)))  ; e.g., "linux/" from "linux/backups.org"

(defun my-gptel-load-knowledge ()
  "Prompt user to select a knowledge folder or file and inject it
into the current agent's system prompt.  Knowledge content is appended
after the agent's personality prompt with clear delimiters.

If knowledge is already loaded, it is replaced (the original
personality prompt is preserved).  Selecting the same knowledge
again is a no-op."
  (interactive)
  (unless (bound-and-true-p gptel-mode)
    (gptel-mode 1))
  (let* ((candidates (my-gptel--knowledge-candidates))
         (_ (unless candidates
              (user-error "No knowledge folders found in %s"
                          (my-gptel--knowledge-dir))))
         (display (completing-read "Load knowledge: " candidates nil t))
         (path (cdr (assoc display candidates)))
         (label (my-gptel--knowledge-label display path)))
    (unless path
      (user-error "Invalid selection: %s" display))
    (if (equal label my-gptel--knowledge-loaded-label)
        ;; No-op if same knowledge is already loaded
        (message "[OK] Knowledge '%s' is already loaded." label)
      ;; Read the knowledge content and inject it
      (let ((content (my-gptel--read-knowledge-files path)))
        (unless content
          (user-error "No .md or .org files found in '%s'" display))
        ;; Save original prompt on first knowledge load
        (unless my-gptel--knowledge-base-prompt
          (setq-local my-gptel--knowledge-base-prompt gptel-system-prompt))
        ;; Build the new system prompt: personality + knowledge
        (setq-local gptel-system-prompt
                    (format "%s\n\n\n=== INJECTED KNOWLEDGE [%s] ===\n\n%s\n\n=== END INJECTED KNOWLEDGE ==="
                            my-gptel--knowledge-base-prompt
                            label
                            content))
        (setq-local my-gptel--knowledge-loaded-label label)
        (message "[OK] Knowledge '%s' loaded (%d chars injected). Total prompt: %s"
                 label (length content)
                 (my-gptel--format-size (length gptel-system-prompt)))))))

;;; --- Prompt size reporting ---

(defun my-gptel--approx-token-count (chars)
  "Return an approximate token count for CHARS (a character count).
Uses the heuristic of ~4 characters per token, which is a rough
estimate for English text and code.  Not exact, but sufficient
for detecting context window overflow before it happens."
  (if (or (null chars) (<= chars 0))
      0
    (/ chars 4)))

(defun my-gptel--format-size (chars)
  "Format CHARS (a character count, integer) as a human-readable size string."
  (let ((tokens (my-gptel--approx-token-count chars)))
    (format "%d chars (~%d tokens)" chars tokens)))

(defun my-gptel-prompt-info ()
  "Display the current system prompt size and composition.
Shows total prompt size in chars and approximate tokens, with a
breakdown of personality vs injected knowledge."
  (interactive)
  (let* ((total (length (or gptel-system-prompt "")))
         (personality (length (or my-gptel--knowledge-base-prompt
                                  gptel-system-prompt)))
         (knowledge-chars (if my-gptel--knowledge-base-prompt
                              (- total personality)
                            0))
         (knowledge-label (or my-gptel--knowledge-loaded-label "none"))
         (agent-name (or my-gptel--current-agent-name "none")))
    (message "=== Prompt Info ===\nAgent: %s\nKnowledge: %s\nPersonality: %s\nKnowledge: %s\nTotal: %s"
             agent-name
             knowledge-label
             (my-gptel--format-size personality)
             (if (> knowledge-chars 0)
                 (my-gptel--format-size knowledge-chars)
               "not loaded")
             (my-gptel--format-size total))))

(with-eval-after-load 'gptel
  (keymap-set gptel-mode-map "C-c k" #'my-gptel-load-knowledge)
  (keymap-set gptel-mode-map "C-c p" #'my-gptel-prompt-info))

(provide 'knowledge_loader)