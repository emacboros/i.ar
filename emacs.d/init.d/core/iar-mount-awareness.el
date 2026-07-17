;; -*- lexical-binding: t; -*-

;;; Mount Awareness -- Extra Mount Discovery
;;
;; Reads the IAR_EXTRA_MOUNTS environment variable (set by emacboros.sh)
;; and makes extra mount information available for injection into agent
;; system prompts.  This lets agents discover mounted directories
;; without being told verbally.
;;
;; The env var format is comma-separated "path:mode" pairs:
;;   IAR_EXTRA_MOUNTS=/var/home/nacho/repos/infra:ro,/tmp/work:rw
;;
;; When no extra mounts are present, the env var is unset and
;; `iar--extra-mounts' returns nil.  The agent loader checks this
;; and appends mount info to the system prompt only when mounts exist.

(require 'subr-x)
(require 'iar-prompt-loader)

;;; --- Mount parsing ---

(defun iar--parse-extra-mounts (env-string)
  "Parse IAR_EXTRA_MOUNTS env var string into a list of (path . mode) pairs.
ENV-STRING is the raw comma-separated value, e.g. \"/path1:ro,/path2:rw\".
Returns nil if ENV-STRING is nil or empty."
  (when (and (stringp env-string)
             (not (string-empty-p env-string)))
    (let (mounts)
      (dolist (entry (split-string env-string "," t))
        (let* ((parts (split-string entry ":" t))
               (path (car parts))
               (mode (or (cadr parts) "rw")))
          (when (and path (not (string-empty-p path)))
            (push (cons path mode) mounts))))
      (nreverse mounts))))

(defvar iar--extra-mounts
  (iar--parse-extra-mounts (getenv "IAR_EXTRA_MOUNTS"))
  "List of extra mounts as (path . mode) pairs.
Parsed from IAR_EXTRA_MOUNTS env var at load time.
Nil when no extra mounts are configured.")

;;; --- System prompt injection ---

(defun iar--extra-mounts-prompt-string ()
  "Return a string describing extra mounts for the system prompt.
Returns empty string when no extra mounts are configured.
Prompt text is loaded from agents.d/common/mount_info.org (rule 53)."
  (if (null iar--extra-mounts)
      ""
    (let ((template (or (iar--load-prompt "mount_info") ""))
          (entries
           (mapconcat
            (lambda (mount)
              (format "- %s (%s)" (car mount)
                      (if (string= (cdr mount) "ro") "read-only" "read-write")))
            iar--extra-mounts "\n")))
      (format template entries))))

(provide 'iar-mount-awareness)