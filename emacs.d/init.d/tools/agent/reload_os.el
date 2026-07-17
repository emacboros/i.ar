;; -*- lexical-binding: t; -*-

;;; reload_os Tool -- Re-evaluate init.el to pick up .el modifications
;;
;; Resets the global gptel-tools list first to avoid duplicate tool
;; registrations, then re-loads init.el so all add-to-list calls
;; rebuild the list cleanly.

(require 'iar-tool-call)

(defun iar--tool-reload-os ()
  "Reload Emacs init.el to pick up modifications to .el files.
Resets the global gptel-tools list first to avoid duplicate tool
registrations, then re-loads init.el so all add-to-list calls
rebuild the list cleanly. Also clears any buffer-local gptel-tools
in the current buffer so it inherits the fresh defaults."
  (condition-case err
      (let ((init-path (expand-file-name "init.el" user-emacs-directory)))
        (set-default 'gptel-tools nil)
        (when (local-variable-p 'gptel-tools)
          (kill-local-variable 'gptel-tools))
        (load init-path nil t)
        (format "Success: Reloaded init.el (%s). All .el files re-evaluated. gptel-tools rebuilt with %d tools."
                init-path
                (length (default-value 'gptel-tools))))
    (error
     (format "Error: Failed to reload init.el: %s" (error-message-string err)))))

(iar-tool-register
 (gptel-make-tool
  :name "reload_os"
  :description "Reload Emacs init.el to pick up modifications to .el files. Use after modifying Emacs Lisp files to test changes without restarting Emacs. Resets and rebuilds gptel-tools automatically."
  :args (list)
  :function #'iar--tool-reload-os))

(provide 'iar-reload-os)