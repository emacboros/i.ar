;; -*- lexical-binding: t; -*-

;;; MCP Integration -- Wire MCP tools into gptel tool system
;;
;; This module integrates the `mcp' package (MELPA) with i.ar's tool system.
;; MCP (Model Context Protocol) servers expose tools that agents can call.
;; The primary use case is Burp Suite (PortSwigger/mcp-server) for pentesting.
;;
;; Architecture:
;; - configs/mcp.el defines `iar-mcp-servers' (known server configs)
;; - Project files declare which servers to use via #+MCP: burp
;; - This module starts the listed servers, registers their tools as gptel tools
;; - MCP tools appear alongside native i.ar tools in gptel-tools
;; - The assembly engine injects available MCP tools into the system prompt
;;
;; MCP server config supports two transports:
;; - SSE (:url "http://host:port/sse") -- for remote servers like Burp
;; - stdio (:command "cmd" :args ("--flag")) -- for local server processes
;;
;; The gptel-mcp.el glue layer (vendored from lizqwerscott/gptel-mcp.el)
;; is only 92 lines. It calls mcp-hub-get-all-tool to get tool plists
;; and gptel-make-tool to register them. We adapt this to use
;; iar-tool-register so MCP tools go through our tool call layer
;; (audit logging, loop guard, truncation).

(require 'cl-lib)
(require 'subr-x)

;; Forward-declared: owned by configs/mcp.el
(defvar iar-mcp-servers nil
  "Alist of known MCP servers. See configs/mcp.el for format.")

;; iar-mcp-auto-start is owned by configs/mcp.el (defcustom, loaded
;; before init.d modules -- do not re-declare it here).

;; Declared in mcp-hub.el (mcp package)
(defvar mcp-hub-servers nil
  "Configuration for MCP servers. Owned by mcp-hub.el.")

;; Declared in iar-agent-loader.el
(defvar iar--current-containers nil)

;;; --- Buffer-local MCP state ---

(defvar-local iar--current-mcp-servers nil
  "List of MCP server names active in the current session.
Set by `iar--setup-assembled-buffer' from the project's #+MCP.")

(defvar-local iar--mcp-tools-registered nil
  "List of gptel-tool objects registered from MCP servers.
Tracked so they can be removed when the session changes.")

;;; --- MCP server management ---

(defun iar--mcp-config-for-server (name)
  "Return the MCP server config plist for NAME.
Looks up `iar-mcp-servers'. Returns nil if not found."
  (cdr (assoc name iar-mcp-servers)))

(defun iar--mcp-build-hub-config (names)
  "Build an alist suitable for `mcp-hub-servers' from NAMES.
Only servers with configs in `iar-mcp-servers' are included."
  (let ((hub-config nil))
    (dolist (name names)
      (let ((config (iar--mcp-config-for-server name)))
        (when config
          (push (cons name config) hub-config))))
    (nreverse hub-config)))

(defun iar--mcp-start-servers (names &optional callback)
  "Start MCP servers listed in NAMES.
Sets `mcp-hub-servers' to the filtered config and starts all servers.
CALLBACK is called when all servers have started (or failed).
Returns t if any servers were started, nil if none configured."
  (let ((hub-config (iar--mcp-build-hub-config names)))
    (if (null hub-config)
        (progn
          (when callback (funcall callback))
          nil)
      ;; Set the hub config for this session
      (setq mcp-hub-servers hub-config)
      (message "[mcp] Starting %d server(s): %s"
               (length hub-config)
               (mapconcat #'car hub-config ", "))
      (if (fboundp 'mcp-hub-start-all-server)
          (progn
            (mcp-hub-start-all-server
             (lambda ()
               (message "[mcp] All servers started")
               (when callback (funcall callback))))
            t)
        (progn
          (warn "[mcp] mcp-hub-start-all-server not available -- mcp package not loaded")
          (when callback (funcall callback))
          nil)))))

;;; --- MCP tool registration ---

(defun iar--mcp-register-tools ()
  "Register all available MCP tools as gptel tools.
Uses `mcp-hub-get-all-tool' to get tool plists from connected servers,
then registers each via `gptel-make-tool'.
Returns a list of registered tool objects."
  (if (not (fboundp 'mcp-hub-get-all-tool))
      (progn
        (warn "[mcp] mcp-hub-get-all-tool not available -- no tools registered")
        nil)
    (let ((tools (mcp-hub-get-all-tool :asyncp t :categoryp t))
          (registered nil))
      (dolist (tool-plist tools)
        (let* ((tool-name (plist-get tool-plist :name))
               (tool-desc (plist-get tool-plist :description))
               (tool-args (plist-get tool-plist :args))
               (tool-fn (plist-get tool-plist :function))
               (tool-async (plist-get tool-plist :async)))
          (when (and tool-name tool-fn)
            (let ((tool (gptel-make-tool
                         :name tool-name
                         :description (or tool-desc "MCP tool")
                         :args tool-args
                         :async (eq tool-async t)
                         :function tool-fn)))
              (when tool
                (push tool registered))))))
      (message "[mcp] Registered %d MCP tool(s)" (length registered))
      registered)))

(defun iar--mcp-activate-tools (tools)
  "Add TOOLS (list of gptel-tool objects) to buffer-local gptel-tools."
  (dolist (tool tools)
    (unless (member tool gptel-tools)
      (push tool gptel-tools)))
  (setq-local iar--mcp-tools-registered
              (append tools iar--mcp-tools-registered)))

(defun iar--mcp-deactivate-tools ()
  "Remove all MCP tools from buffer-local gptel-tools.
Called when switching sessions or personalities."
  (when iar--mcp-tools-registered
    (dolist (tool iar--mcp-tools-registered)
      (setq-local gptel-tools
                  (cl-remove tool gptel-tools :test #'eq)))
    (setq-local iar--mcp-tools-registered nil)))

;;; --- Session lifecycle ---

(defun iar-mcp-setup-session (server-names)
  "Set up MCP for the current session.
SERVER-NAMES is a list of MCP server names from the project's #+MCP.
Starts servers, registers tools, and activates them in the current buffer.
This is called by `iar--setup-assembled-buffer' after assembly."
  (when (and server-names iar-mcp-auto-start)
    ;; Deactivate any tools from a previous session
    (iar--mcp-deactivate-tools)
    ;; Start servers and register tools
    (iar--mcp-start-servers
     server-names
     (lambda ()
       (let ((tools (iar--mcp-register-tools)))
         (when tools
           (iar--mcp-activate-tools tools)))))))

(defun iar-mcp-start ()
  "Interactively start MCP servers and register tools.
Useful when auto-start is disabled or to reconnect after a server restart."
  (interactive)
  (when iar--current-mcp-servers
    (iar--mcp-start-servers
     iar--current-mcp-servers
     (lambda ()
       (let ((tools (iar--mcp-register-tools)))
         (when tools
           (iar--mcp-activate-tools tools)))))))

(provide 'iar-mcp-setup)