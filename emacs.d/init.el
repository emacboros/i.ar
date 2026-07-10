;; -*- lexical-binding: t; -*-

;; Always load the newest .el file, even if a stale .elc exists.
;; This prevents stale byte-compiled code from shadowing source fixes.
(setq load-prefer-newer t)

(add-to-list 'load-path (expand-file-name "init.d" user-emacs-directory))

;; Central parameter configuration (must load before any init.d modules)
(load-file (expand-file-name "metaconfig/parameters.el" user-emacs-directory))

;; Locale and UTF-8 configuration (must load before anything else)
(load "locale.el")

;; Package manager setup
(load "package_setup.el")

;; UI cleanup
(load "ui_cleanup.el")

;; Evil mode setup
(load "evil_mode.el")

;; GPTEL backend configuration
(load "gptel_setup.el")

;; Prompt loader -- load prompt templates from common/ directory
;; Must load before delegate_tool, memory_tools, and loop_guard which
;; call my-gptel--load-prompt at load time (in defconst forms).
(load "prompt_loader.el")

;; Output sanitizer (must load before code_tools.el)
(load "output_sanitizer.el")
;; Native filesystem tools for gptel
(load "fs_tools.el")
;; Local code execution tools for gptel
(load "code_tools.el")

;; Replacement utility tool
(load "replacement_tool.el")

;; Dynamic agent loader
(load "agent_loader.el")

;; Multi-agent delegation tool
(load "delegate_tool.el")

;; Reload tools (reload_os, reload_agent)
(load "reload_tools.el")

;; Memory summarization tool (C-c m in gptel-mode)
(load "memory_tools.el")

;; Elisp syntax checker tool
(load "check_elisp_tool.el")

;; Task reader and unified history tools
(load "task_tools.el")

;; Loop guard — detect and break repetitive tool call loops
(load "loop_guard.el")

;; File guard — protected path enforcement
(load "file_guard.el")
;; Audit logging — records all file operations and command executions
(load "audit_log.el")

;; ──────────────────────────────────────────────────────────
;; Auto-discovery: load any init.d/*.el not explicitly loaded above.
;; This allows autonomous agents (e.g. darwin) to create new modules
;; that get picked up automatically on next cycle without modifying init.el.
;; ──────────────────────────────────────────────────────────
(let ((explicit-loads '("locale" "package_setup" "ui_cleanup" "evil_mode"
                        "gptel_setup" "output_sanitizer" "fs_tools"
                        "code_tools" "replacement_tool" "agent_loader"
                        "delegate_tool" "reload_tools" "memory_tools"
                        "check_elisp_tool" "task_tools"
                        "loop_guard" "file_guard" "audit_log"
                        "prompt_loader"))
      (init-dir (expand-file-name "init.d" user-emacs-directory)))
  (dolist (file (directory-files init-dir nil "\\.el\\'"))
    (let ((basename (file-name-sans-extension file)))
      (unless (member basename explicit-loads)
        (load (expand-file-name file init-dir))))))
(custom-set-variables
 ;; custom-set-variables was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 '(my-gptel--guard-allow-self-modification t))
(custom-set-faces
 ;; custom-set-faces was added by Custom.
 ;; If you edit it by hand, you could mess it up, so be careful.
 ;; Your init file should contain only one such instance.
 ;; If there is more than one, they won't work right.
 )
