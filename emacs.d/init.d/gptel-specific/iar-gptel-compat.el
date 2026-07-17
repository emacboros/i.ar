;; -*- lexical-binding: t; -*-

;;; Gptel Compatibility Layer
;;
;; This module wraps all gptel internal symbols that i.ar hooks into,
;; providing a single indirection point. If gptel's internals change
;; (e.g., in a 1.0 release), only this file needs updating.
;;
;; All modules in init.d/ should use these wrappers instead of
;; referencing gptel internals directly.
;;
;; Categories wrapped:
;; - FSM access (gptel-fsm-p, gptel-fsm-info, gptel-fsm-state,
;;   gptel--fsm-transition, gptel--fsm-next, gptel--fsm-last)
;; - Tool processing (gptel--process-tool-call, gptel--handle-tool-use)
;; - Curl internals (gptel-curl--get-config, gptel-curl--stream-cleanup,
;;   gptel-curl--sentinel)
;; - Request tracking (gptel--request-alist)
;; - Hook variables (gptel-pre-tool-call-functions,
;;   gptel-post-tool-call-functions, gptel-post-response-functions)
;;
;; Public API symbols (gptel-make-tool, gptel-send, gptel-mode, etc.)
;; are NOT wrapped -- they are semver-protected and used directly.

(require 'gptel)

;;; ---------------------------------------------------------
;;; FSM Access
;;; ---------------------------------------------------------

(defun iar-gptel-fsm-p (fsm)
  "Return non-nil if FSM is a gptel FSM object."
  (gptel-fsm-p fsm))

(defun iar-gptel-fsm-info (fsm)
  "Return the info plist from FSM."
  (gptel-fsm-info fsm))

(defun iar-gptel-fsm-state (fsm)
  "Return the current state of FSM."
  (gptel-fsm-state fsm))

(defun iar-gptel-fsm-next (fsm)
  "Return the next state for FSM.
Wraps `gptel--fsm-next'."
  (gptel--fsm-next fsm))

(defun iar-gptel-fsm-last (buffer)
  "Return the last FSM for BUFFER.
Wraps `gptel--fsm-last'."
  (buffer-local-value 'gptel--fsm-last buffer))

(defun iar-gptel-fsm-transition (fsm &optional new-state)
  "Trigger FSM transition to NEW-STATE.
Wraps `gptel--fsm-transition'."
  (gptel--fsm-transition fsm new-state))

;;; ---------------------------------------------------------
;;; Tool Processing
;;; ---------------------------------------------------------

(defun iar-gptel-process-tool-call (fsm tool-spec tool-call result)
  "Process a tool call result.
Wraps `gptel--process-tool-call'."
  (gptel--process-tool-call fsm tool-spec tool-call result))

(defun iar-gptel-handle-tool-use (fsm)
  "Handle pending tool use for FSM.
Wraps `gptel--handle-tool-use'."
  (gptel--handle-tool-use fsm))

;;; ---------------------------------------------------------
;;; Curl Internals
;;; ---------------------------------------------------------

(defun iar-gptel-curl-get-config (info uuid)
  "Return curl config string for request.
Wraps `gptel-curl--get-config'."
  (gptel-curl--get-config info uuid))

(defun iar-gptel-curl-stream-cleanup (process status)
  "Clean up after streaming response.
Wraps `gptel-curl--stream-cleanup'."
  (gptel-curl--stream-cleanup process status))

(defun iar-gptel-curl-sentinel (process status)
  "Process sentinel for curl requests.
Wraps `gptel-curl--sentinel'."
  (gptel-curl--sentinel process status))

;;; ---------------------------------------------------------
;;; Request Tracking
;;; ---------------------------------------------------------

(defvar iar-gptel-request-alist nil
  "Alias for gptel request alist.
This is a defvar, not a defalias -- defvaralias on buffer-local
variables does not work reliably. Use `iar-gptel-request-alist'
as a read-only reference; for buffer-local access use
\(buffer-local-value \\='iar-gptel-request-alist buffer).")

;; Use defvaralias for the request alist so existing code that reads
;; gptel--request-alist works through our wrapper.  We can't use
;; defvaralias here because gptel--request-alist is buffer-local and
;; defvaralias doesn't propagate buffer-local values.  Instead, we
;; provide the accessor below.

(defun iar-gptel-get-request-alist ()
  "Return the current value of gptel's request alist.
Reads `gptel--request-alist' in the current buffer."
  (if (boundp 'gptel--request-alist)
      gptel--request-alist
    nil))

;;; ---------------------------------------------------------
;;; Hook Variables
;;; ---------------------------------------------------------
;; We use defvaralias for hook variables so that add-hook and remove-hook
;; work transparently.  defvaralias creates a variable alias that
;; propagates setq and buffer-local state.

(when (boundp 'gptel-pre-tool-call-functions)
  (defvaralias 'iar-gptel-pre-tool-call-functions
    'gptel-pre-tool-call-functions
    "Alias for `gptel-pre-tool-call-functions'."))

(when (boundp 'gptel-post-tool-call-functions)
  (defvaralias 'iar-gptel-post-tool-call-functions
    'gptel-post-tool-call-functions
    "Alias for `gptel-post-tool-call-functions'."))

(when (boundp 'gptel-post-response-functions)
  (defvaralias 'iar-gptel-post-response-functions
    'gptel-post-response-functions
    "Alias for `gptel-post-response-functions'."))

;;; ---------------------------------------------------------
;;; Advice Installation
;;; ---------------------------------------------------------
;; Centralized advice-add so that if gptel renames internal functions,
;; only this file needs updating. Modules call these instead of
;; (advice-add 'gptel--process-tool-call ...).

(defun iar-gptel-advise-process-tool-call (where function)
  "Add advice FUNCTION on `gptel--process-tool-call' at WHERE."
  (advice-add 'gptel--process-tool-call where function))

(defun iar-gptel-advise-fsm-transition (where function)
  "Add advice FUNCTION on `gptel--fsm-transition' at WHERE."
  (advice-add 'gptel--fsm-transition where function))

(defun iar-gptel-advise-handle-tool-use (where function)
  "Add advice FUNCTION on `gptel--handle-tool-use' at WHERE."
  (advice-add 'gptel--handle-tool-use where function))

(defun iar-gptel-advise-curl-get-config (where function)
  "Add advice FUNCTION on `gptel-curl--get-config' at WHERE."
  (advice-add 'gptel-curl--get-config where function))

(defun iar-gptel-advise-curl-stream-cleanup (where function)
  "Add advice FUNCTION on `gptel-curl--stream-cleanup' at WHERE."
  (advice-add 'gptel-curl--stream-cleanup where function))

(defun iar-gptel-advise-curl-sentinel (where function)
  "Add advice FUNCTION on `gptel-curl--sentinel' at WHERE."
  (advice-add 'gptel-curl--sentinel where function))

(provide 'iar-gptel-compat)