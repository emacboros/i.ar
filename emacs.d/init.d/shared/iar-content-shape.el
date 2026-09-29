;; -*- lexical-binding: t; -*-

;;; Content-shape guard for full-file write tools.
;;
;; 2026-09-29 (aria c547): the c546 forensics found a nemotron
;; write_roadmap call that wrote a TRUNCATED document (ends
;; mid-sentence, stale header) with a legal stop=stop -- no guard
;; can catch it at the call site. But the WRITTEN FILE's shape is
;; checkable: a full-file write whose content ends mid-line, or
;; whose line count collapses implausibly vs the file it replaces,
;; is the signature of an arg-level truncation.
;;
;; Policy: WARN in the tool result (never block -- legitimate
;; rewrites do shrink files). The warning text lands in the tool
;; result so the emitting model sees it in-context and can re-write
;; if the truncation was unintended.
;;
;; BUFFER-INDEPENDENCE (c547 test scar): the line counts are computed
;; from CONTENT in a private temp buffer, never from the current
;; buffer. The first draft read (point-min)/(point-max) of whatever
;; buffer was current at call time -- in gptel process buffers that
;; is unrelated text, and the collapse check compared garbage. The
;; fixture-encodes-theory class, caught by my own tests before
;; deploy.
;;
;; REGEX CHAR-CLASS SCAR (c547): "[*#-|]" puts "-" between # and |
;; -- a RANGE (0x23..0x7C) covering almost every printable char,
;; including "A". The structure exemption matched everything and the
;; mid-sentence signal never fired. Dashes in char classes go LAST
;; (or escaped).

(require 'cl-lib)

(defgroup iar-content-shape nil
  "Content-shape checks for full-file write tools."
  :group 'iar)

(defcustom iar-content-shape-min-lines 10
  "Files shorter than this many lines are exempt from the
line-count-collapse check (small files shrink freely)."
  :type 'natnum)

(defun iar--content-shape--ends-complete (content)
  "Return non-nil if CONTENT ends with a complete line (newline
terminated or empty)."
  (or (string-empty-p content)
      (string-suffix-p "\n" content)))

(defun iar--content-shape--mid-sentence-tail (content)
  "Heuristic: return non-nil if CONTENT's last line looks like it
was cut mid-sentence. Signals on a last line that is long (>60
chars), has no sentence-terminal punctuation, and does not look
like org/markdown structure (headings, list items, tables)."
  (let* ((lines (split-string content "\n" t))
         (last-line (car (last lines))))
    (and last-line
         (> (length last-line) 60)
         (not (string-match-p "[.:;)\"'`*]$" last-line))
         (not (string-match-p "\\`[*#|\\-]" last-line)))))

(defun iar--content-shape--line-count (content)
  "Count lines in CONTENT without touching the current buffer."
  (with-temp-buffer
    (insert content)
    (count-lines (point-min) (point-max))))

(defun iar--content-shape--check (content old-path)
  "Check CONTENT's shape against OLD-PATH's current shape.
Returns a warning string or nil. Checks:
1. content ends mid-line (no trailing newline)
2. content's last line looks mid-sentence
3. line count collapses implausibly vs the existing file
   (>30% loss on files >= iar-content-shape-min-lines lines).
Buffer-independent: all counts derive from CONTENT itself."
  (let* ((warnings nil)
         (old-lines (when (and old-path (file-exists-p old-path))
                      (with-temp-buffer
                        (insert-file-contents old-path)
                        (count-lines (point-min) (point-max)))))
         (new-lines (iar--content-shape--line-count content))
         (loss (when (and old-lines (> old-lines iar-content-shape-min-lines))
                 (/ (float (- old-lines new-lines)) old-lines))))
    (unless (iar--content-shape--ends-complete content)
      (push "content does not end with a newline (possible truncation)" warnings))
    (when (iar--content-shape--mid-sentence-tail content)
      (push "last line looks cut mid-sentence (possible truncation)" warnings))
    (when (and loss (> loss 0.30))
      (push (format "line count collapsed %d -> %d (-%.0f%%, possible truncation)"
                    old-lines new-lines (* loss 100))
            warnings))
    (when warnings
      (format "WARNING (content-shape): %s" (string-join warnings "; ")))))

(provide 'iar-content-shape)