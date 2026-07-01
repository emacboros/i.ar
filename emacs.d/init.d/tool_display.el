;; -*- lexical-binding: t; -*-

;; Display tool calls (name + arguments) in the chat buffer BEFORE they execute,
;; so the user can see what's happening while waiting for long-running tools.

(defun my-gptel--display-tool-call-pre (fsm)
  "Insert tool call info into the buffer before the tool runs.
FSM is the gptel state machine."
  (when-let* ((info (gptel-fsm-info fsm))
              (buffer (plist-get info :buffer))
              (tool-use (cl-remove-if (lambda (tc) (plist-get tc :result))
                                      (plist-get info :tool-use))))
    (with-current-buffer buffer
      (let ((tracking-marker (or (plist-get info :tracking-marker)
                                 (plist-get info :position))))
        (when (markerp tracking-marker)
          (save-excursion
            (goto-char tracking-marker)
            (dolist (tool-call tool-use)
              (let* ((name (plist-get tool-call :name))
                     (args (plist-get tool-call :args))
                     (arg-str (string-trim (prin1-to-string args))))
                ;; Truncate very long arguments for display
                (when (> (length arg-str) 500)
                  (setq arg-str (concat (substring arg-str 0 500) " ...)")))
                (let ((text (format "\n%s %s\n"
                                    (propertize (format "Calling %s:" name)
                                                'face 'font-lock-keyword-face)
                                    (propertize arg-str 'face 'font-lock-string-face))))
                  ;; Mark as response text so gptel parses it correctly
                  (add-text-properties 0 (length text)
                                       '(gptel response front-sticky (gptel))
                                       text)
                  (insert text))
                ;; Move tracking marker past inserted text so tool results
                ;; appear below the "Calling..." line.
                ;; IMPORTANT: set insertion-type to t so that subsequent
                ;; inserts (tool results, next response text) go BEFORE
                ;; the marker and advance it forward, matching gptel's
                ;; own tracking-marker behavior.
                (let ((new-marker (point-marker)))
                  (set-marker-insertion-type new-marker t)
                  (plist-put info :tracking-marker new-marker))))))))))

(with-eval-after-load 'gptel-request
  (advice-add 'gptel--handle-tool-use :before #'my-gptel--display-tool-call-pre))