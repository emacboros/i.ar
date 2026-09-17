;; -*- lexical-binding: t; -*-
;; Fixture-hygiene pin (aria c379, 2026-09-17): the nested-git creator
;; class, mechanized.
;;
;; Production (c369->c372): a MID-EDIT version of the belt2d tests ran
;; `git init -q` / `git add -A` / `git commit -qm init` with
;; default-directory NOT bound to the tmp repo. The ambient cwd took
;; the hit -- run-tests.sh cds to /root/i.ar/emacs.d, so a root-owned
;; nested .git appeared inside the REAL emacs.d tree, locked out every
;; cycle start for 27h (preflight read it as a writable escape vector).
;; The 09-16 tripwire re-fires were the same class: relative
;; (make-directory ".git/hooks" :parents) landing in emacs.d.
;;
;; The class law: test code with relative git ops must bind
;; default-directory FIRST. This file pins that law STATICALLY: it
;; scans every test-*.el file on disk (the same files the suite loads)
;; and fails loud if any git invocation or relative .git make-directory
;; is lexically OUTSIDE a default-directory let-bind.
;;
;; Why static, not a runtime canary: the mid-edit state is exactly the
;; state a runtime canary would miss (the canary runs the committed
;; tests, which were clean; the damage came from the file being edited).
;; A static scan reads the file as it exists on disk -- the same bytes
;; the next suite run will load. It catches the regression at the
;; moment it is written, not after it fires.
;;
;; Scope: only test files (test-*.el). Source modules legitimately run
;; git against the real checkout (the belt, the tools). The scan
;; recognizes a bind as any line containing `default-directory' between
;; the git op and the enclosing (ert-deftest -- the same heuristic a
;; human reviewer applies, mechanized.
;;
;; Known-good exceptions (verified by hand, c379):
;; - test-usage-belt2c-push.el:33 -- `git init -q --bare bare-dir' with
;;   an EXPLICIT target path (no cwd dependence; the bare-dir is
;;   make-temp-file-anchored). The scan accepts explicit-target git
;;   inits (a path arg after the flags) and flags only bare `git init'.
;;
;; GUARD-AUTHORING LAW note (c362/c363): this file DISCUSSES git ops in
;; its comments and scans for git ops in code. The scanners therefore
;; strip comment-only lines before matching -- a guard that
;; pattern-matches its own documentation fires on itself (the c362
;; pre-commit guard's own scar, reproduced and fixed here on first
;; run of this very file).

(require 'ert)
(require 'cl-lib)

(defconst fixture-hygiene--test-dir
  (expand-file-name "test" user-emacs-directory)
  "Directory the suite loads test files from (run-tests.el sets
user-emacs-directory to the repo emacs.d).")

(defun fixture-hygiene--code-lines (src)
  "Split SRC into lines, dropping comment-only lines. The scanners
match CODE, not prose -- otherwise this file's own discussion of the
bug shapes trips the scan (guard-authoring law, c362)."
  (cl-loop for l in (split-string src "\n")
           ;; drop full-line comments (the only comment shape used in
           ;; the test files); inline trailing comments after code are
           ;; kept -- the code part still matches.
           unless (string-match-p "^[ \t]*;" l)
           collect l))

(defun fixture-hygiene--git-op-lines (src)
  "Return (LINE-NO . TEXT) for git invocations in SRC (code only).
Line numbers are indices into the CODE-line list (dense, stable
within a run); the violation report names them as such."
  (let ((lines (fixture-hygiene--code-lines src))
        out)
    (cl-loop for i from 0 below (length lines)
             for l = (nth i lines)
             ;; call-process "git" ... -- the only git invocation shape
             ;; used in test fixtures (verified c379: zero shell-command
             ;; git calls in test files).
             when (string-match-p "call-process \"git\"" l)
             do (push (cons (1+ i) l) out))
    (nreverse out)))

(defun fixture-hygiene--relative-git-mkdir-lines (src)
  "Return (LINE-NO . TEXT) for RELATIVE .git make-directory calls."
  (let ((lines (fixture-hygiene--code-lines src))
        out)
    (cl-loop for i from 0 below (length lines)
             for l = (nth i lines)
             ;; make-directory ".git..." or (make-directory "./.git..."
             ;; -- a relative path, cwd-dependent. Absolute/expand-file-name
             ;; forms are anchored and safe.
            when (string-match-p "make-directory[ \t]*\"\\(\\./\\)?\\.git" l)
             do (push (cons (1+ i) l) out))
    (nreverse out)))

(defun fixture-hygiene--explicit-init-p (line)
  "Non-nil when LINE is a git init with an explicit target path
(cwd-independent): `git init -q --bare <path>' or `git init <path>'."
  ;; call-process "git" nil nil nil "init" ... with a path arg after
  ;; the flags. Crude but sufficient: look for a quoted path token
  ;; after "init" that is not a flag.
  (and (string-match-p "call-process \"git\"" line)
       (string-match-p "\"init\"" line)
       (string-match-p "\"-q\"\\|\"--bare\"" line)
       ;; explicit target: a quoted arg that is not a flag follows init
       (string-match-p "\"init\"[^;]*\"[^\"-][^\"]*\"" line)))

(defun fixture-hygiene--inside-default-directory-bind-p (lines line-idx)
  "Non-nil when the git op at LINE-IDX (0-based, into LINES) is
lexically inside a default-directory let-bind: scan backwards for a
line mentioning default-directory before the enclosing (ert-deftest."
  (let ((hit nil)
        (i line-idx))
    (while (and (>= i 0) (not hit))
      (cond
       ((string-match-p "default-directory" (nth i lines))
        (setq hit t))
       ;; stop at the deftest boundary (the op is top-level in the test)
       ((and (string-match-p "(ert-deftest" (nth i lines)) (/= i line-idx))
        (setq i -1))
       (t (setq i (1- i)))))
    hit))

(ert-deftest test-fixture-hygiene-git-ops-bound ()
  "Every git invocation in every test file is lexically inside a
default-directory bind (or is an explicit-target git init). The
c372 creator class -- relative git ops inheriting the runner's cwd
-- must be caught when written, not after it locks out the cycles."
  (let* ((test-dir fixture-hygiene--test-dir)
         (files (directory-files test-dir t "^test-.*\\.el\\'"))
         violations)
    (dolist (file files)
      (let ((src (with-temp-buffer
                   (insert-file-contents file)
                   (buffer-string)))
            (code-lines (fixture-hygiene--code-lines
                         (with-temp-buffer
                           (insert-file-contents file)
                           (buffer-string)))))
        (dolist (op (append (fixture-hygiene--git-op-lines src)
                            (fixture-hygiene--relative-git-mkdir-lines src)))
          (let* ((lineno (car op))
                 (text (cdr op))
                 (idx (1- lineno)))
            (unless (or (fixture-hygiene--explicit-init-p text)
                        (fixture-hygiene--inside-default-directory-bind-p
                         code-lines idx))
              (push (format "%s:code-line %d: %s"
                            (file-name-nondirectory file)
                            lineno (string-trim text))
                    violations))))))
    (should-not violations)
    ;; The scan must actually see the git-op files (a scan that reads
    ;; zero files is a fake-clean by construction -- c358c family).
    (should (> (length files) 50))))

(ert-deftest test-fixture-hygiene-scan-finds-plant ()
  "Negative test: the scanner flags a planted unbound git op. A
guard that cannot fail is not a guard (c362 guard-authoring law)."
  (let ((src (concat "(ert-deftest planted ()\n"
                     "  (call-process \"git\" nil nil nil \"init\" \"-q\")\n"
                     "  (make-directory \".git/hooks\" :parents))\n")))
    (should (= 1 (length (fixture-hygiene--git-op-lines src))))
    (should (= 1 (length (fixture-hygiene--relative-git-mkdir-lines src))))
    ;; neither is an explicit-target init
    (should-not (fixture-hygiene--explicit-init-p
                 (cdr (car (fixture-hygiene--git-op-lines src)))))))

(provide 'test-fixture-hygiene)
;;; test-fixture-hygiene.el ends here