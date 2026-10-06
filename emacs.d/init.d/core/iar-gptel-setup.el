;; -*- lexical-binding: t; -*-

(defvar iar-gptel-backend)
(defvar iar-gptel-default-model)
(defvar iar-fork-path)

;; If a gptel fork path is configured, prepend it to load-path so the
;; fork takes precedence over the ELPA-installed package.  This is used
;; when a fix has been merged upstream but hasn't shipped in an ELPA
;; release yet.  When nil, the ELPA package is used as normal.
(when (and iar-fork-path
           (stringp iar-fork-path)
           (file-directory-p iar-fork-path))
  (message "[gptel] Using fork from %s (overriding ELPA package)" iar-fork-path)
  (add-to-list 'load-path iar-fork-path))

;; 2026-10-06 (aria): :ensure t here RE-TRIGGERED the gptel install at
;; this point even after iar-package-setup's fork-aware skip -- the
;; second half of the 2026-10-05/06 outage (use-package tried the
;; rotated-away MELPA tar and died). The install decision belongs to
;; iar--ensure-package (fork-aware, failure-tolerant). Here we only
;; LOAD: the fork if present, else the ELPA copy (which
;; iar--ensure-package has already installed or healed).
;; A gptel that fails to LOAD here is a real error: kill init loudly
;; (a silent missing-gptel would break every request downstream).
(require 'gptel)

(use-package gptel
  :ensure nil
  :config
  (load (expand-file-name "gptel.el"
                          (expand-file-name "configs" user-emacs-directory)))
  (setq-default gptel-backend iar-gptel-backend)
  (setq-default gptel-model iar-gptel-default-model))
(provide 'iar-gptel-setup)
