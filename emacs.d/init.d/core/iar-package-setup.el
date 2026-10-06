;; -*- lexical-binding: t; -*-

;;; 1. PACKAGE MANAGER SETUP
(require 'package)
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
(package-initialize)
(unless package-archive-contents
  (package-refresh-contents))

;; --- gptel install: fork-aware + failure-tolerant (2026-10-06, aria) ---
;; ROOT CAUSE of the 2026-10-05/06 outage (~1100 dead rotations per
;; agent, exit 255 at init): sophon's elpa/gptel-20260826.2228/ lost
;; its untracked package files (gptel.el, gptel-pkg.el,
;; gptel-autoloads.el). Without gptel-pkg.el, package.el does not
;; register gptel -> package-installed-p nil -> package-install ->
;; the CACHED archive-contents (Aug 30) points at
;; gptel-20260826.2228.tar, which MELPA rotated away (live version
;; 20261002.545) -> 404 -> init died -> every cycle exit 255.
;; TWO structural facts make the install unnecessary and the failure
;; fatal:
;;   1. When EMACBOROS_GPTEL_FORK_PATH is set (every cycle + session),
;;      iar-gptel-setup.el prepends the fork to load-path and the ELPA
;;      copy is NEVER loaded. The install is pure ceremony.
;;   2. A package-install error at init is FATAL (top-level signal
;;      kills the cycle before the agent wakes).
;; Fixes, in order of durability:
;;   a. Fork present -> skip the install entirely (fork IS gptel).
;;   b. Elpa dir present but descriptor missing -> write a minimal
;;      gptel-pkg.el (version from the dir name) so package.el
;;      registers it. Self-heals the registered-package state with
;;      no network.
;;   c. Any remaining package-install failure -> warn, never kill
;;      init. A missing optional package must degrade, not kill the
;;      cycle. (The test suite surfaces real missing deps loudly.)

(defun iar--elpa-dir-version (dir)
  "Extract the version list from a package dir name like foo-20260826.2228."
  (let ((name (file-name-nondirectory (directory-file-name dir))))
    (when (string-match "\\`\\([^.].*?\\)-\\([0-9]+\\(?:[.][0-9]+\\)*\\)\\'" name)
      (version-to-list (match-string 2 name)))))

(defun iar--heal-elpa-descriptor (pkg dir)
  "Ensure DIR has a -pkg.el so package.el registers package PKG.
Writes a minimal define-package form using the version parsed from
the directory name. Idempotent: does nothing if the descriptor
already exists."
  (let* ((pkg-name (symbol-name pkg))
         (pkg-file (expand-file-name (concat pkg-name "-pkg.el") dir)))
    (unless (file-exists-p pkg-file)
      (let ((version (iar--elpa-dir-version dir)))
        (when version
          (condition-case e
              (progn
                (with-temp-file pkg-file
                  (insert (format
                           "(define-package \"%s\" \"%s\"\n  \"Descriptor healed by iar-package-setup (dir-name version; original files lost).\"\n  nil)\n"
                           pkg-name (package-version-join version))))
                (message "[iar-package-setup] healed %s (wrote %s)" pkg-name pkg-file))
            (error
             (message "[iar-package-setup] heal of %s failed: %S" pkg-name e))))))))

(defun iar--ensure-package (pkg)
  "Install PKG if missing; warn instead of dying on failure.
Fork-aware for gptel: if the fork is configured, the ELPA copy is
never loaded, so a missing/unregistered ELPA gptel is not an error."
  (if (package-installed-p pkg)
      nil
    (cond
     ;; (a) fork-aware skip
     ((and (eq pkg 'gptel)
           (getenv "EMACBOROS_GPTEL_FORK_PATH")
           (file-directory-p (getenv "EMACBOROS_GPTEL_FORK_PATH")))
      (message "[iar-package-setup] gptel not registered in ELPA; fork at %s is the runtime -- skipping install"
               (getenv "EMACBOROS_GPTEL_FORK_PATH")))
     ;; (b) self-heal the descriptor when the dir exists
     ((and (eq pkg 'gptel)
           (file-directory-p package-user-dir)
           (cl-find-if
            (lambda (d) (and (string-match-p "\\`gptel-[0-9]" (file-name-nondirectory (directory-file-name d)))
                             (file-directory-p d)))
            (directory-files package-user-dir t "\\`[^.]")))
      (iar--heal-elpa-descriptor pkg (cl-find-if
                                      (lambda (d) (string-match-p "\\`gptel-[0-9]" (file-name-nondirectory (directory-file-name d))))
                                      (directory-files package-user-dir t "\\`[^.]")))
      (setq package-alist nil)          ; force re-derivation
      (package-load-all-descriptors)
      (if (package-installed-p pkg)
          (message "[iar-package-setup] gptel healed from dir descriptor")
        (message "[iar-package-setup] gptel still unregistered after heal; continuing (fork is the runtime)")))
     ;; (c) tolerate any remaining failure
     (t
      (condition-case e
          (package-install pkg)
        (error
         (message "[iar-package-setup] WARNING: package-install of %s failed: %S -- continuing (init must not die here)"
                  pkg e)))))))

(iar--ensure-package 'gptel)
(iar--ensure-package 'undercover)
(iar--ensure-package 'mcp)

(provide 'iar-package-setup)
