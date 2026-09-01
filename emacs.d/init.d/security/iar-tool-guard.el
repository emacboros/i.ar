;; -*- lexical-binding: t; -*-

;;; Tool Guard -- Unknown tool name interception
;;
;; Pre-tool-call hook that blocks hallucinated tool names at the TPRE
;; stage, before gptel--handle-tool-use runs. Returns (:block message)
;; for unknown tools, nil for known tools.
;;
;; Used by delegate buffers and cycle buffers to provide early interception
;; of hallucinated tool names with a cleaner error message than gptel's
;; built-in handling.

(require 'cl-lib)
(require 'iar-tool-call)
(require 'iar-prompt-loader)  ; iar--load-prompt

(defun iar--block-unknown-tools (info)
  "Pre-tool-call hook to block unknown tool names.
INFO is the plist from `gptel-pre-tool-call-functions' containing
:name, :args, :buffer, :backend, and :model.  Returns nil if the
tool is known, or (:block message) if the tool name is not in
`gptel-tools'.

This hook intercepts unknown tool calls at the TPRE stage (before
`gptel--handle-tool-use' runs) and returns (:block ...) which causes
gptel to inject an error result via `gptel--process-tool-call'.  This
provides earlier feedback and a cleaner error message than gptel's
built-in unknown-tool handling in `gptel--handle-tool-use' (TOOL
state).  Both paths set :result on the tool-call, allowing the FSM
to progress.

Uses the dynamic variable `gptel-tools' (not `info :tools') because
the hook's INFO plist does not include a :tools key -- gptel only
passes :name, :args, :buffer, :backend, and :model to pre-tool-call
hooks.  `gptel-tools' is resolved in the buffer where the hook runs
(via gptel's `with-current-buffer buffer' in the hook runner), so
buffer-local values (e.g., delegate tool removed at max depth) are
correctly seen.

Used by both `iar--spawn-async-delegate' (delegate buffers) and
`iar-run-cycle' (cycle buffer) to provide early interception of
hallucinated tool names."
  (let ((name (plist-get info :name)))
    (unless (cl-find-if (lambda (ts)
                          (equal (gptel-tool-name ts) name))
                        gptel-tools)
      (list :block
            (format (iar--load-prompt "unknown_tool")
                    name)))))

(provide 'iar-tool-guard)
;;; --- Setup ---
;; 2026-09-01: made GLOBAL. The interactive hang (00:35-00:41 AR,
;; execute_local_test_placeholder): the built-in unknown-tool branch
;; in gptel--handle-tool-use did not fire in the live session (no
;; audit entry, no error injected, FSM stalled silently). The TPRE
;; :block path (gptel.el gptel--handle-pre-tool -> gptel--process-
;; tool-call directly) is the path that provably works in
;; isolation. Cycles and delegates already had this; interactive
;; sessions now do too. One guard, all modes.
(defun iar--tool-guard-setup ()
  "Register the unknown-tool blocker globally on the pre-tool hook."
  (remove-hook 'iar-pre-tool-call-functions #'iar--block-unknown-tools)
  (add-hook 'iar-pre-tool-call-functions #'iar--block-unknown-tools))

(iar--tool-guard-setup)
