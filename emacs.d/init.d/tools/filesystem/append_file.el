;; -*- lexical-binding: t; -*-

;;; append_file tool for gptel
;; Appends text content to the end of an existing file.
;; Security: checks iar-file-guard before writing. Logs to audit log.
;; Newline contract (c51): after ANY successful append, the file is
;; newline-terminated. append_file prepends a newline when the file
;; lacks one AND guarantees a trailing newline on non-empty content.
;; Rationale: shell >> (execute_code_local) has no prepend logic, so
;; a file left without a trailing newline GLUES the next shell append
;; onto the last line (7 journal headers glued, continuo c2-c39 +
;; aria c93-c11). append_file is the house writer; it must leave the
;; file in a state any writer can extend safely.

(require 'iar-tool-call)
(require 'iar-file-guard)
(require 'iar-utils)  ; iar--with-suppressed-save-hooks

(defun iar--fs-append-file (filepath content)
  "Append CONTENT to the end of FILEPATH.
If the file is open in an Emacs buffer, appends to that buffer and saves.
Otherwise, appends directly to the file on disk.
If the file exists and does not end with a newline, one is prepended.
Non-empty CONTENT without a trailing newline gets one appended, so the
file is always newline-terminated after a successful append.
If the file does not exist, it is created.  Parent directories are
created if needed, matching `iar--fs-write-file' behavior.
Returns a string starting with \\='Success:\\=' or \\='Error:\\='."
  (let* ((expanded-path (expand-file-name filepath))
         (guard-reason (or (iar--guard-check-append expanded-path)
                           (iar--guard-check-append-content content))))
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
                      (save-restriction
                        (widen)
                        (goto-char (point-max))
                        (unless (or (= (point-min) (point-max))
                                    (string-suffix-p "\n" (buffer-substring-no-properties
                                                           (max (point-min) (1- (point-max)))
                                                           (point-max))))
                          (insert "\n"))
                        (insert (if (and (> (length content) 0)
                                         (not (string-suffix-p "\n" content)))
                                    (concat content "\n")
                                  content)))
                      (iar--with-suppressed-save-hooks
                        (save-buffer))
                      (format "Success: Content appended to '%s'" expanded-path))))
                (let* ((attrs (file-attributes expanded-path))
                       (size (and attrs (file-attribute-size attrs)))
                       (prefix
                        (if (and size (> size 0))
                            (condition-case nil
                                (with-temp-buffer
                                  (insert-file-contents expanded-path nil (1- size) size)
                                  (if (string-suffix-p "\n" (buffer-string))
                                      ""
                                    "\n"))
                              (error ""))
                          "")))
                  (write-region (concat prefix content
                                        (if (and (> (length content) 0)
                                                 (not (string-suffix-p "\n" content)))
                                            "\n"
                                          ""))
                                nil expanded-path t 'silent)
                  (format "Success: Content appended to '%s'" expanded-path))))
          (error (format "Error: Failed to append to '%s'. Emacs says: %s"
                         expanded-path (error-message-string err))))))))

(iar-tool-register
 (gptel-make-tool
  :name "append_file"
  :description "Append text to end of file. Prepends newline if needed; guarantees the file ends with a newline after the append."
  :args (list '(:name "filepath" :type "string" :description "Absolute path to the file.")
              '(:name "content" :type "string" :description "The text content to add to the end of the file."))
  :function #'iar--fs-append-file))

(provide 'iar-tool--append-file)