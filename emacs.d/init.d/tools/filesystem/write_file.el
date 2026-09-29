;; -*- lexical-binding: t; -*-

;;; write_file tool for gptel
;; Creates or overwrites a file with new content.
;; Security: checks iar-file-guard before writing. Logs to audit log.
;; 2026-09-29 (aria c547): content-shape check -- a truncated write
;; (the c546 nemotron arg-level stop class) surfaces a WARNING in the
;; tool result instead of landing silently.

(require 'iar-tool-call)
(require 'iar-file-guard)
(require 'iar-utils)  ; iar--with-suppressed-save-hooks
(require 'iar-content-shape)

(defun iar--fs-write-file (filepath content)
  "Write CONTENT to FILEPATH, creating parent dirs if needed.
If the file is open in an Emacs buffer, writes to that buffer and saves.
Otherwise, uses atomic write (temp file + rename).
Returns a string starting with \\='Success:\\=' or \\='Error:\\='."
  (let* ((expanded-path (expand-file-name filepath))
         (guard-reason (or (iar--guard-check-write expanded-path)
                           (iar--guard-check-write-content content))))
    (if guard-reason
        (format "Error: %s" guard-reason)
      (let ((buf (find-buffer-visiting expanded-path)))
        (condition-case err
            (progn
              (make-directory (file-name-directory expanded-path) t)
              (if buf
                  (with-current-buffer buf
                    (cond
                     (buffer-read-only
                      (format "Error: Buffer for '%s' is read-only" expanded-path))
                     ((buffer-modified-p)
                      (format "Error: Buffer for '%s' has unsaved modifications. Save or revert the buffer first."
                              expanded-path))
                     (t
                      (erase-buffer)
                      (insert content)
                      (iar--with-suppressed-save-hooks
                        (save-buffer))
                      (format "Success: File written to '%s'" expanded-path))))
                (let* ((shape-warning (iar--content-shape--check content expanded-path))
                       (tmp-file (make-temp-file "iar-write-")))
                  (with-temp-file tmp-file
                    (insert content))
                  (rename-file tmp-file expanded-path t)
                  (if shape-warning
                      (format "Success: File written to '%s'\n%s" expanded-path shape-warning)
                    (format "Success: File written to '%s'" expanded-path)))))
          (error (format "Error: Failed to write file to '%s'. Emacs says: %s"
                         expanded-path (error-message-string err))))))))

(iar-tool-register
 (gptel-make-tool
  :name "write_file"
  :description "Create or overwrite a file with new content."
  :args (list '(:name "filepath" :type "string" :description "Absolute path to the destination file.")
              '(:name "content" :type "string" :description "The full text content to write into the file."))
  :function #'iar--fs-write-file))

(provide 'iar-tool--write-file)