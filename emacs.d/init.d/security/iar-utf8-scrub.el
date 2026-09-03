;; -*- lexical-binding: t; -*-
;;; UTF-8 Scrub for Tool Results (the json-value-p sentinel crash fix)
;;
;; 2026-09-02: two cycles died exit 255 with "Wrong type argument:
;; json-value-p" in the process sentinel. Root cause: a tool result
;; (restic lock inspection via ssh) contained raw binary bytes
;; (non-UTF-8). The bytes entered the conversation buffer as
;; raw-eight-bit chars (codepoints #x3FFF80..#x3FFFFF in Emacs's
;; internal representation). gptel's next request serializes the
;; conversation with json-serialize, which REJECTS raw-eight-bit
;; chars -> the error fired in the curl sentinel -> batch Emacs died
;; with exit 255 -> the whole cycle's work was lost.
;;
;; The fix: scrub tool results BEFORE they enter the conversation.
;; Raw-eight-bit chars are replaced with U+FFFD (REPLACEMENT
;; CHARACTER). Valid UTF-8 text (including non-ASCII like "café" or
;; "中文") passes through unchanged. Unibyte strings (rare here;
;; results arrive via utf-8-unix process coding) are decoded first.
;;
;; Empirically validated (Emacs 30.2):
;;   - raw bytes -> U+FFFD, json-serialize accepts the result
;;   - clean multibyte text round-trips identically
;;   - 1MB string scrubs in ~0.1s (fast path: clean strings skip
;;     the mapconcat entirely -- only a linear char scan runs)
;;
;; Wire-in: iar-tool-call.el's truncate advice calls this BEFORE
;; truncation, so every tool result (sync or async) is scrubbed at
;; the single choke point where results already flow.

(require 'cl-lib)

(defconst iar--raw-byte-char-min #x3fff80
  "Minimum codepoint of Emacs raw-eight-bit chars (byte #x80).")

(defconst iar--raw-byte-char-max #x400000
  "Exclusive upper bound of raw-eight-bit chars (byte #x100).")

(defun iar--string-has-raw-bytes (s)
  "Return non-nil if S contains raw-eight-bit chars."
  (let ((i 0) (n (length s)) (found nil))
    (while (and (not found) (< i n))
      (let ((ch (aref s i)))
        (when (and (>= ch iar--raw-byte-char-min)
                   (< ch iar--raw-byte-char-max))
          (setq found t)))
      (setq i (1+ i)))
    found))

(defun iar--utf8-scrub (s)
  "Return S safe for json-serialize.
Raw-eight-bit chars (invalid UTF-8 bytes) become U+FFFD.
Non-string input passes through unchanged. Clean strings are
returned as-is (identity check first, no allocation)."
  (if (not (stringp s)) s
    (let ((m (if (multibyte-string-p s) s
               (decode-coding-string s 'utf-8 t))))
      (if (not (multibyte-string-p m)) s
        (if (not (iar--string-has-raw-bytes m)) m
          (mapconcat (lambda (ch)
                       (if (and (>= ch iar--raw-byte-char-min)
                                (< ch iar--raw-byte-char-max))
                           "\uFFFD" (char-to-string ch)))
                     m ""))))))

(provide 'iar-utf8-scrub)