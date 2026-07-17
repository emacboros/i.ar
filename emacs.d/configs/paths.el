;; -*- lexical-binding: t; -*-

;; =============================================================================
;; Base Directory Paths
;; =============================================================================
;;
;; Relative subdirectory names under `user-emacs-directory'.
;; These define where the agent system looks for agent profiles,
;; prompt templates, knowledge bases, audit logs, and task files.
;; Change these if your deployment uses a different directory layout.

(defcustom iar-agents-path "agents.d/agents"
  "Relative path to agent profile directories.
Each subdirectory contains a prompt.org file defining an agent personality."
  :type 'string
  :group 'iar)

(defcustom iar-prompts-path "agents.d/common"
  "Relative path to shared prompt templates.
Contains .org files loaded by the prompt loader for delegation,
cycle prompts, memory summarization, etc."
  :type 'string
  :group 'iar)

(defcustom iar-knowledge-path "knowledge"
  "Relative path to the knowledge base directory.
Each subdirectory is a loadable knowledge folder (via C-c k)."
  :type 'string
  :group 'iar)

(defcustom iar-audit-path "audit"
  "Relative path to the audit log directory.
Contains the global audit.log and per-agent subdirectories with
HISTORY.log, LOGS.md, SUMMARY.md, BUFFER.log, REQUESTS.log, FSM.log."
  :type 'string
  :group 'iar)

(defcustom iar-tasks-path "tasks"
  "Relative path to the task files directory.
Contains per-agent subdirectories with .md task files
(one file per task, file exists = work to do)."
  :type 'string
  :group 'iar)

(provide 'iar-config-paths)