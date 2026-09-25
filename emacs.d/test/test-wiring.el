;; -*- lexical-binding: t; -*-
;; Wiring test: every init.d module must be loaded by init.el.
;;
;; Law: COMMITTED-BUILD-IS-NOT-WIRED (aria c329, 2026-09-24). Continuo's
;; context circuit breaker (c6158d1) was committed as a 120-line module
;; with a green suite and a green reviewer -- and never loaded, because
;; nothing asked "is it wired?". The suite stayed green because the
;; module never loaded; green proved nothing about it. This test makes
;; the wiring itself a suite assertion: a new module file without a
;; load line in init.el turns the suite RED at commit time.
;;
;; Exemptions: files that are intentionally not load-lined in init.el.
;; Keep this list SHORT and justified -- an exemption is a claim that
;; the file is dead code or loaded by another mechanism, and both need
;; a reason in the comment.

(require 'ert)
(require 'cl-lib)

(defconst test-wiring-exemptions
  '()
  "init.d module files intentionally NOT load-lined in init.el.
Empty by design: every shipped module should be wired. If you add an
exemption, document WHY the file exists unwired.")

(defun test-wiring--module-files ()
  "All .el files under init.d/, as \"subdir/file.el\" paths."
  (let* ((init-dir (expand-file-name "init.d" user-emacs-directory))
         (files nil))
    (dolist (subdir (directory-files init-dir t "^[^.]"))
      (when (file-directory-p subdir)
        (dolist (file (directory-files subdir t "\\.el\\'"))
          (setq files (cons (concat (file-name-nondirectory subdir)
                                    "/"
                                    (file-name-nondirectory file))
                            files)))))
    (sort files #'string<)))

(defun test-wiring--init-el-load-targets ()
  "List (BASENAME . DIRVAR) of every file init.el loads via
(load (expand-file-name \"X.el\" DIRVAR))."
  (let* ((init-el (expand-file-name "init.el" user-emacs-directory))
         (targets nil))
    (when (file-exists-p init-el)
      (with-temp-buffer
        (insert-file-contents init-el)
        (goto-char (point-min))
        (while (re-search-forward
                "(load[[:space:]]*(expand-file-name[[:space:]\n]+\"\\([^\"]+\\.el\\)\"[[:space:]\n]+\\(\\(?:\\w\\|\\s_\\|-\\)+\\))"
                nil t)
          (setq targets (cons (cons (match-string 1) (match-string 2))
                              targets)))))
    targets))

(defun test-wiring--dirvar->dir (dirvar)
  "Map an init.el directory-variable name to a filesystem directory.
Unknown variables return nil (the caller treats that as a phantom)."
  (let* ((init-dir (expand-file-name "init.d" user-emacs-directory))
         (mapping '(("configs-dir" . "configs")
                    ("init-shared-dir" . "init.d/shared")
                    ("init-core-dir" . "init.d/core")
                    ("init-tool-call-dir" . "init.d/tool-call")
                    ("init-security-dir" . "init.d/security")
                    ("init-tools-fs-dir" . "init.d/tools/filesystem")
                    ("init-tools-code-dir" . "init.d/tools/code")
                    ("init-tools-tasks-dir" . "init.d/tools/tasks")
                    ("init-tools-notify-dir" . "init.d/tools/notify")
                    ("init-tools-git-dir" . "init.d/tools/git")
                    ("init-tools-knowledge-dir" . "init.d/tools/knowledge")
                    ("tools-agent-dir" . "init.d/tools/agent")
                    ("init-agent-dir" . "init.d/agent")
                    ("init-debug-dir" . "init.d/debug")
                    ("init-session-dir" . "init.d/session")
                    ("init-dynamic-dir" . "init.d/dynamic")))
         (rel (cdr (assoc dirvar mapping))))
    (when rel (expand-file-name rel (expand-file-name ".." init-dir)))))

(ert-deftest test-wiring-every-module-loaded ()
  "Every .el file under init.d/ must have a load line in init.el.
Regression for COMMITTED-BUILD-IS-NOT-WIRED (c6158d1: a committed
module that nothing loaded; the suite stayed green because the
module never loaded)."
  (let* ((modules (test-wiring--module-files))
         (loaded (test-wiring--init-el-load-targets))
         (loaded-names (mapcar #'car loaded))
         (unwired (cl-remove-if
                   (lambda (m)
                     (or (member (file-name-nondirectory m) loaded-names)
                         (member m test-wiring-exemptions)))
                   modules)))
    (should (consp modules))            ; sanity: we actually found modules
    (should (null unwired))))

(ert-deftest test-wiring-no-phantom-load-lines ()
  "Every load line in init.el must name a file that EXISTS in the
directory its variable points at. A load line pointing at a
deleted/renamed module is a different wiring lie: the line looks
wired, the file is gone."
  (let* ((loaded (test-wiring--init-el-load-targets))
         (missing nil))
    (dolist (target loaded)
      (let* ((dir (test-wiring--dirvar->dir (cdr target)))
             (path (when dir (expand-file-name (car target) dir))))
        (unless (and dir path (file-exists-p path))
          (setq missing (cons (car target) missing)))))
    (should (null missing))))

(provide 'test-wiring)
;;; test-wiring.el ends here