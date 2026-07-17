;; -*- lexical-binding: t; -*-

;;; reload_agent Tool -- Re-read agent prompt.org and update system message
;;
;; Reloads the current agent's profile from its prompt.org file and
;; updates the gptel system message in the current chat buffer.

(require 'iar-tool-call)
(require 'iar-agent-utils)
(require 'iar-utils)
(require 'iar-agent-loader)
(require 'iar-mount-awareness)

;; Forward-declared: owned by configs/paths.el.
;; Declared here so this module can resolve agent profile paths.
(defvar iar-agents-path nil
  "Relative path to agent profile directories.")

(defun iar--tool-reload-agent (&optional agent-name)
  "Reload the current agent's profile from its prompt.org file and update
the gptel system message in the current buffer.
If AGENT-NAME is provided (e.g., \"mccarthy\"), reload that agent
instead of the currently loaded one."
  (condition-case err
      (let* ((agent-dir (expand-file-name iar-agents-path user-emacs-directory))
             (target-name
              (if (and agent-name (stringp agent-name) (iar--non-blank-p agent-name))
                  (progn
                    (iar--validate-agent-name agent-name)
                    agent-name)
                (let ((current (iar--get-agent-name)))
                  (if current
                      current
                    (error "No agent currently loaded in this buffer. Pass agent_name to reload a specific agent.")))))
             (target-file (expand-file-name (format "%s/prompt.org" target-name) agent-dir))
             (_ (unless (string-prefix-p agent-dir (file-truename target-file))
                  (error "Path traversal blocked for agent reload")))
             (profile (iar--load-agent-profile target-name)))
        (unless profile
          (error "Agent profile '%s' not found in agents.d/" target-name))
        (setq-local gptel-system-prompt
                    (if (fboundp 'iar--extra-mounts-prompt-string)
                        (concat profile (iar--extra-mounts-prompt-string))
                      profile))
        (setq-local iar--current-agent-file target-file)
        (setq iar--current-agent-file target-file)
        (setq-local iar--current-agent-name target-name)
        (setq iar--current-agent-name target-name)
        (format "Success: Reloaded agent profile '%s'. System message updated in current buffer (%d chars)."
                target-name (length profile)))
    (error
     (format "Error: Failed to reload agent: %s" (error-message-string err)))))

(iar-tool-register
 (gptel-make-tool
  :name "reload_agent"
  :description "Reload the current agent's gptel prompt from its .org file, updating the system message in the current chat buffer. Use after modifying an agent's .org profile to test changes without killing the chat. Optionally pass agent_name to reload a specific agent."
  :args (list '(:name "agent_name" :type "string" :description "Optional: name of agent to reload (e.g., 'mccarthy'). If omitted, reloads the currently loaded agent." :optional t))
  :function #'iar--tool-reload-agent))

(provide 'iar-reload-agent)