;; -*- lexical-binding: t; -*-

;;; Status Mode -- Custom mode-line display for agent session metrics
;;
;; Replaces buffer-monitor, request-logger, and fsm-tracer.
;; Shows 6 data points in the mode line:
;; - Agent name (from iar--get-agent-name)
;; - Prompt size in chars (from gptel-system-prompt, buffer-local)
;; - Last request input tokens (from iar--usage-last-input)
;; - Last response output tokens (from iar--usage-last-output)
;; - Cumulative input tokens (from iar--usage-input-tokens)
;; - Cumulative output tokens (from iar--usage-output-tokens)
;;
;; No gptel internals. All token data comes from the tool call layer's
;; accumulators. The mode-line construct uses (:eval ...) so it always
;; shows current values on redisplay.
;;
;; Format: [agent prompt_size] last:in/out total:in/out

(require 'subr-x)
(require 'cl-lib)
(require 'iar-utils)
(require 'iar-tool-call)

;; Forward-declared: owned by gptel.
;; Declared here so we can reference it for prompt size display before
;; gptel is loaded (it is loaded before this module in init.el, but
;; the byte-compiler needs the declaration).
(defvar gptel-system-prompt nil)

;;; ---------------------------------------------------------
;;; Formatting helpers
;;; ---------------------------------------------------------

(defun iar--status-mode-format-size (chars)
  "Format CHARS as a compact size string with K/M suffixes."
  (cond
   ((null chars) "0")
   ((< chars 1024) (format "%d" chars))
   ((< chars (* 1024 1024)) (format "%.1fK" (/ chars 1024.0)))
   (t (format "%.1fM" (/ chars (* 1024.0 1024.0))))))

(defun iar--status-mode-format-tokens (tokens)
  "Format TOKENS as a compact string with K/M suffixes."
  (cond
   ((null tokens) "0")
   ((< tokens 1000) (format "%d" tokens))
   ((< tokens 1000000) (format "%.1fK" (/ tokens 1000.0)))
   (t (format "%.1fM" (/ tokens 1000000.0)))))

;;; ---------------------------------------------------------
;;; Status mode string
;;; ---------------------------------------------------------

(defun iar--status-mode-format ()
  "Return the status mode string for the mode line.
Shows: [agent prompt_size] last:in/out total:in/out"
  (let* ((agent (or (iar--get-agent-name) "none"))
         (prompt-size (length (or gptel-system-prompt "")))
         (last-in (or iar--usage-last-input 0))
         (last-out (or iar--usage-last-output 0))
         (cum-in (or iar--usage-input-tokens 0))
         (cum-out (or iar--usage-output-tokens 0)))
    (format "  [%s %s] last:%s/%s total:%s/%s"
            agent
            (iar--status-mode-format-size prompt-size)
            (iar--status-mode-format-tokens last-in)
            (iar--status-mode-format-tokens last-out)
            (iar--status-mode-format-tokens cum-in)
            (iar--status-mode-format-tokens cum-out))))

;;; ---------------------------------------------------------
;;; Mode-line integration
;;; ---------------------------------------------------------

(defvar iar--status-mode-active nil
  "Whether status mode is installed in the mode line.")

(defun iar--status-mode-own-p (item)
  "Return non-nil if ITEM is the status mode :eval construct.
The construct is (:eval (iar--status-mode-format)).
We check that ITEM is a cons starting with :eval whose cadr's car
is the symbol iar--status-mode-format."
  (and (consp item)
       (eq (car item) :eval)
       (consp (cdr item))
       (let ((form (cadr item)))
         (and (consp form)
              (eq (car form) 'iar--status-mode-format)))))

(defun iar--status-mode-remove-from-mode-line ()
  "Remove the status mode construct from `mode-line-misc-info'."
  (when (boundp 'mode-line-misc-info)
    (setq mode-line-misc-info
          (cl-remove-if #'iar--status-mode-own-p
                        mode-line-misc-info))))

(defun iar--status-mode-update (&rest _)
  "Force a mode-line update after token data changes.
Ignores hook arguments (status info) from `iar-post-response-functions'."
  (force-mode-line-update t))

(defun iar-status-mode-enable ()
  "Install status mode in the mode line.
Idempotent: removes existing construct before adding (rule 57)."
  (when (boundp 'mode-line-misc-info)
    (iar--status-mode-remove-from-mode-line)
    (add-to-list 'mode-line-misc-info
                 '(:eval (iar--status-mode-format)))
    (remove-hook 'iar-post-response-functions #'iar--status-mode-update)
    (add-hook 'iar-post-response-functions #'iar--status-mode-update)
    (setq iar--status-mode-active t)
    (force-mode-line-update t)
    (message "[status-mode] Installed")))

(defun iar-status-mode-disable ()
  "Remove status mode from the mode line."
  (iar--status-mode-remove-from-mode-line)
  (remove-hook 'iar-post-response-functions #'iar--status-mode-update)
  (setq iar--status-mode-active nil)
  (force-mode-line-update t)
  (message "[status-mode] Removed"))

;;; ---------------------------------------------------------
;;; Setup
;;; ---------------------------------------------------------

(defun iar--status-mode-setup ()
  "Install status mode at load time."
  (iar-status-mode-enable))

(iar--status-mode-setup)

(provide 'iar-status-mode)