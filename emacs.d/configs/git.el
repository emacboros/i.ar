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

(defcustom iar-git-belt-push-remotes '("origin")
  "Remotes the belt #2b pre-exit commit pushes to.
c367 (2026-09-15): the belt committed but never pushed -- belt commits
landed on the shared checkout and stayed invisible to everything that
reads the bare repos (three sightings: c365 found 2, c366 found 2,
c367 found 2 again; each healed by hand). The push is the missing link
between durable (commit on the checkout) and visible (in the bare
repo every other reader pulls). Push failure is NON-FATAL: the commit
already exists; the next cycle's belt push retries. Set to nil to
disable belt pushes (tests, non-remote checkouts)."
  :type '(repeat string)
  :group 'iar)

(provide 'iar-config-git)
