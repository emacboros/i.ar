;; -*- lexical-binding: t; -*-

;; =============================================================================
;; Git Commit Tool Parameters
;; =============================================================================
;;
;; Git author identity for agent commits. Set via environment variables
;; (IAR_GIT_AUTHOR_NAME, IAR_GIT_AUTHOR_EMAIL) with generic fallbacks.
;; No personal data in public repo files (GUIDELINES.org rule 52).

(defcustom iar-git-author-name
  (or (getenv "IAR_GIT_AUTHOR_NAME") "i.ar Agent")
  "Default git author name for agent commits.
Used by the git_commit tool when the repository does not have
user.name configured.  Can be set via IAR_GIT_AUTHOR_NAME env var."
  :type 'string
  :group 'iar)

(defcustom iar-git-author-email
  (or (getenv "IAR_GIT_AUTHOR_EMAIL") "agent@i.ar.local")
  "Default git author email for agent commits.
Used by the git_commit tool when the repository does not have
user.email configured.  Can be set via IAR_GIT_AUTHOR_EMAIL env var."
  :type 'string
  :group 'iar)

(provide 'iar-config-git)