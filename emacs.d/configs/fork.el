;; -*- lexical-binding: t; -*-

;; =============================================================================
;; Gptel Fork Path
;; =============================================================================

(defcustom iar-fork-path
  (getenv "EMACBOROS_GPTEL_FORK_PATH")
  "Path to a local gptel fork to use instead of the ELPA package.
When set to a valid directory path, it is prepended to `load-path'
before gptel is required, so the fork takes precedence over the
installed ELPA package.

Set to nil to use the ELPA package.

Can also be set via the EMACBOROS_GPTEL_FORK_PATH environment variable
(set by the --gptel-fork flag on emacboros.sh)."
  :type '(choice (directory :tag "Path to gptel fork directory")
                 (const :tag "Use ELPA package" nil))
  :group 'iar)

(provide 'iar-config-fork)