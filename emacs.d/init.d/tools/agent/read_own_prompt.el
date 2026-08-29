;; -*- lexical-binding: t; -*-

;;; read_own_prompt tool -- programmatic self-inspection
;;
;; Returns the agent's own assembled system prompt as a tool result.
;; Uses the same assembly code as C-c a (iar--assemble-prompt) so the
;; result is exactly what the LLM receives: archetype, personality,
;; project objective, knowledge, memory injection, mounts, containers.
;;
;; This closes the self-inspection loop: an agent can verify its own
;; prompt (and prompt changes) without asking the human.

(require 'iar-tool-call)
(require 'iar-prompt-assembly)

(defun iar--tool-read-own-prompt ()
  "Return the current agent's assembled system prompt.
Re-assembles from the current archetype/personality/project if they
are set (buffer-local), otherwise returns the live gptel-system-prompt.
Both paths are shown so the agent can detect drift between what was
assembled at load time and what is in effect now."
  (condition-case err
      (let* ((archetype (or iar--current-archetype "interactive"))
             (personality (or (iar--current-personality-name)
                              (iar--get-agent-name)
                              "unknown"))
             (project (or (iar--current-project-name) "iar"))
             (live (or gptel-system-prompt ""))
             (assembled
              (if (and personality (not (string= personality "unknown")))
                  (plist-get (iar--assemble-prompt archetype personality project)
                             :prompt)
                ""))
             (header
              (format "=== SELF-INSPECTION ===\nArchetype: %s\nPersonality: %s\nProject: %s\nLive prompt: %d chars\nRe-assembled now: %d chars\n\n"
                      archetype personality project
                      (length live) (length assembled))))
        (if (and assembled (> (length assembled) 0)
                 (not (string= assembled live)))
            (format "%sNOTE: live prompt and fresh assembly DIFFER (prompt was changed after load, or memory files changed). Fresh assembly:\n\n%s"
                    header assembled)
          (format "%sLive system prompt (matches fresh assembly):\n\n%s"
                  header live)))
    (error
     (format "Error reading own prompt: %s" (error-message-string err)))))

(iar-tool-register
 (gptel-make-tool
  :name "read_own_prompt"
  :description "Read your own assembled system prompt (archetype, personality, project, knowledge, memory injection). For self-inspection and verifying prompt changes."
  :args '()
  :function #'iar--tool-read-own-prompt))

(provide 'iar-tool--read-own-prompt)