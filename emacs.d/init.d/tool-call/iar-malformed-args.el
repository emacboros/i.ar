;; -*- lexical-binding: t; -*-

;;; Malformed Tool Call Feedback (Track A2)
;;
;; When a tool function errors on wrong argument shapes, gptel's
;; condition-case catches the signal and returns the raw elisp
;; error string ("Wrong type argument: stringp, 123") as the tool
;; result. The model cannot learn from that -- it doesn't say
;; WHICH argument was wrong or WHAT shape was expected.
;;
;; This module wraps tool functions at registration time
;; (iar-tool-make / iar-tool-register -- the single choke point
;; every i.ar tool passes through) so that errors carry the tool
;; spec: the argument name, the received value, and the expected
;; type. The model gets an actionable message instead of noise.
;;
;; It also catches arity errors: if the model omitted a required
;; argument, the raw error is "wrong-number-of-arguments" with no
;; context. The wrapper knows the arg names from the spec and can
;; say which ones are missing.
;;
;; Wrapped errors are tagged <tool_call_error> so the model can
;; recognize them as its own mistakes to fix, not tool failures
;; to give up on.

(require 'gptel)
(require 'cl-lib)
(require 'subr-x)

(defvar iar-malformed-args-feedback t
  "When non-nil, wrap tool functions with arg-shape error feedback.
Owned by configs/tool-limits.el (forward-declared here).")

;;; ---------------------------------------------------------
;;; Spec formatting (pure -- unit tested)
;;; ---------------------------------------------------------

(defun iar--format-arg-spec (arg-plist)
  "Format one arg spec entry for error messages.
ARG-PLIST is a gptel arg spec: (:name \"path\" :type \"string\")."
  (format "%s:%s"
          (or (plist-get arg-plist :name) "?")
          (or (plist-get arg-plist :type) "?")))

(defun iar--format-tool-spec (tool-spec)
  "Format all arg specs of TOOL-SPEC as \"name:type name:type\"."
  (mapconcat #'iar--format-arg-spec
             (gptel-tool-args tool-spec) " "))

(defun iar--describe-value (value)
  "Render VALUE for an error message: type + truncated repr."
  (let ((repr (condition-case nil
                  (truncate-string-to-width
                   (format "%S" value) 120)
                (error "<unprintable>"))))
    (format "%s %s" (type-of value) repr)))

;;; ---------------------------------------------------------
;;; The wrapper
;;; ---------------------------------------------------------

(defun iar--wrap-tool-function (tool-spec function)
  "Return a wrapped FUNCTION for TOOL-SPEC.
Sync tools: catches errors, returns structured feedback string.
Async tools: catches errors in the callback path, calls the
CALLBACK with structured feedback instead of the raw error.
The wrapper preserves the original function's arity via &rest --
gptel's apply uses the SPEC's arg order, not the lambda list."
  (let ((name (gptel-tool-name tool-spec))
        (spec-str (iar--format-tool-spec tool-spec))
        (async (gptel-tool-async tool-spec)))
    (if async
        (lambda (callback &rest args)
          (condition-case err
              (apply function callback args)
            (error
             (funcall callback
                      (iar--malformed-feedback
                       name spec-str err args)))))
      (lambda (&rest args)
        (condition-case err
            (apply function args)
          (error
           (iar--malformed-feedback name spec-str err args)))))))

(defun iar--malformed-feedback (name spec-str err args)
  "Build the structured error message for a failed tool call.
NAME is the tool name, SPEC-STR the arg spec string, ERR the
signaled error data, ARGS the received argument values."
  (let ((err-str (mapconcat #'gptel--to-string err " ")))
    (if (and (stringp err-str)
             (string-match-p "wrong-number-of-arguments" err-str))
        (format
         "<tool_call_error>
Your call to %s had the wrong number of arguments.
Expected args: %s
Retry the tool call with the correct arguments.
</tool_call_error>"
         name spec-str)
      (format
       "<tool_call_error>
Your call to %s failed on argument shape or value.
Expected args: %s
Received: %s
Error: %s
Check the argument types and values and retry.
</tool_call_error>"
       name spec-str
       (mapconcat #'iar--describe-value args ", ")
       err-str))))

;;; ---------------------------------------------------------
;;; Registration hooks (wrap at the choke point)
;;; ---------------------------------------------------------

(defun iar--maybe-wrap-tool (tool)
  "Wrap TOOL's function if malformed-args feedback is enabled.
Returns the (possibly same) tool object. Structs are immutable
after construction -- build a new one with the wrapped function."
  (if (or (not iar-malformed-args-feedback)
          (null tool)
          (not (gptel-tool-function tool)))
      tool
    (let ((wrapped (iar--wrap-tool-function tool (gptel-tool-function tool))))
      ;; Preserve all slots; replace function. gptel--copy-tool
      ;; exists for exactly this.
      (let ((copy (gptel--copy-tool tool)))
        (setf (gptel-tool-function copy) wrapped)
        copy))))

(defun iar-tool-register (tool)
  "Register TOOL (a gptel tool object) with the tool system.
Wraps TOOL's function with malformed-args feedback first (A2).
This is the only function outside init.el that modifies gptel-tools."
  (add-to-list 'gptel-tools (iar--maybe-wrap-tool tool)))

(defun iar-tool-make (name description args function &optional async)
  "Create and register a gptel tool.
NAME is the tool name string.
DESCRIPTION is the tool description string (API contract with LLM).
ARGS is a list of plists describing tool arguments.
FUNCTION is the function to call when the tool is invoked.
ASYNC is non-nil for async tools (function takes callback as first arg).
Returns the created tool object (wrapped for A2 feedback)."
  (let ((tool (gptel-make-tool
               :name name
               :description description
               :args args
               :function function
               :async (when async t))))
    (iar-tool-register tool)
    tool))

(provide 'iar-malformed-args)