;; -*- lexical-binding: t; -*-

;;; read_file tool for gptel
;; Reads the text contents of a local file into a string.

(require 'iar-tool-call)

(defun iar--fs-read-file (filepath &optional tail-lines)
  "Read the text contents of FILEPATH into a string.
On error, returns a string starting with \\='Error:\\='.

When TAIL-LINES is a positive integer and the file has more lines
than that, only the LAST TAIL-LINES lines are returned, preceded
by a head notice showing how many lines were skipped.  This is the
correct shape for append-only files (journals, logs): their newest
content is at the tail, and a whole-file read of a large one
delivers the OLDEST content first (c409: continuo's 80 journal
reads all returned the file's stale head).

When `iar-fs-read-max-size' is a positive integer and the file
has more characters than that limit, only the first
`iar-fs-read-max-size' characters are returned, followed by a
truncation notice.  This prevents loading huge files into the AI
context.  Uses character count (not byte count) because
insert-file-contents decodes the file, and token consumption
correlates with characters.  The tail filter is applied BEFORE the
max-size truncation, so a tail read of a huge file returns the
tail, not the head."
  (let ((expanded-path (expand-file-name filepath)))
    (condition-case err
        (with-temp-buffer
          (insert-file-contents expanded-path)
          ;; Tail filter first (append-only files: newest at the tail).
          (when (and (integerp tail-lines) (> tail-lines 0))
            (let ((total-lines (count-lines (point-min) (point-max))))
              (when (> total-lines tail-lines)
                (let ((skip (- total-lines tail-lines)))
                  (forward-line skip)
                  (delete-region (point-min) (point))
                  ;; Head notice: metadata about the VIEW, not content.
                  (goto-char (point-min))
                  (insert (format "[... showing last %d of %d lines ...]\n"
                                  tail-lines total-lines))))))
          (let ((max iar-fs-read-max-size))
            (if (and (integerp max) (> max 0)
                     (> (buffer-size) max))
                (progn
                  (goto-char (1+ max))
                  (delete-region (point) (point-max))
                  (goto-char (point-max))
                  (insert (format "\n\n[... file truncated at %d characters ...]" max))
                  (buffer-string))
              (buffer-string))))
      (error (format "Error: Failed to read file '%s'. Emacs says: %s"
                      expanded-path (error-message-string err))))))

(iar-tool-register
 (gptel-make-tool
  :name "read_file"
  :description "Read the text contents of a local file into context. For large append-only files (logs, journals, histories), pass tail_lines to get the most recent content -- a whole-file read of a large log returns its OLDEST content first."
  :args (list '(:name "filepath" :type "string" :description "Absolute path to the file.")
              '(:name "tail_lines" :type "integer" :optional t
                :description "Return only the last N lines of the file (with a notice of how many lines were skipped). Use for journals/logs where the newest content is at the end. Omit to read the whole file."))
  :function #'iar--fs-read-file))

(provide 'iar-tool--read-file)