;; -*- lexical-binding: t; -*-
;; Belt #2c push tests (aria c367, 2026-09-15): the belt commit is
;; now FOLLOWED BY A PUSH to iar-git-belt-push-remotes. Three
;; sightings (c365/c366/c367: 2 unpushed belt commits each morning,
;; each healed by hand) showed the push is a separate act that
;; silently does not happen -- the belt commits were durable on the
;; shared checkout but invisible to every reader of the bare repo.
;; The push is the missing link between durable and visible.
;;
;; Tests pin:
;; 1. A successful belt commit pushes to the configured remote (a
;;    local bare remote receives the commit).
;; 2. Push failure is NON-FATAL: the belt still returns the commit's
;;    durability (t), the cycle does not break.
;; 3. iar-git-belt-push-remotes nil = no push attempted (tests,
;;    non-remote checkouts).

(require 'ert)

(ert-deftest test-tool-call-belt2c-pushes-belt-commit ()
  "Belt #2c: after the belt commit, the configured remote receives it."
  (let* ((tmpdir (make-temp-file "belt2c-" t))
         (repo-dir (expand-file-name "repo" tmpdir))
         (bare-dir (expand-file-name "bare" tmpdir))
         (iar-personalization-path repo-dir)
         (iar-audit-path "audit")
         (iar--current-agent-name "testagent")
         (iar--current-project "testproject")
         (iar-git-belt-push-remotes (list "testremote")))
    (unwind-protect
        (progn
          ;; A local BARE remote (push target) and the working repo.
          (call-process "git" nil nil nil "init" "-q" "--bare" bare-dir)
          (make-directory repo-dir)
          (let ((default-directory repo-dir))
            (call-process "git" nil nil nil "init" "-q")
            (call-process "git" nil nil nil "config" "user.name" "Test")
            (call-process "git" nil nil nil "config" "user.email" "t@i.ar")
            (call-process "git" nil nil nil "remote" "add" "testremote" bare-dir)
            (call-process "git" nil nil nil "add" "-A")
            (call-process "git" nil nil nil "commit" "-qm" "init"))
          (iar--usage-reset)
          (setq iar--usage-requests 3 iar--usage-input-tokens 100
                iar--usage-output-tokens 40 iar--usage-model "m")
          (should (eq (iar--usage-write-log-now) t))
          ;; The bare remote now has the belt commit: VISIBLE, not just
          ;; durable on the checkout.
          (let ((default-directory bare-dir))
            (let ((out (generate-new-buffer " *bare-log*")))
              (call-process "git" nil (list out t) nil "log" "--oneline" "-2")
              (let ((text (with-current-buffer out (buffer-string))))
                (kill-buffer out)
                (should (string-match-p "belt #2 durability" text))))))
      (delete-directory tmpdir :recursive))))

(ert-deftest test-tool-call-belt2c-push-failure-nonfatal ()
  "A push to a nonexistent remote does not break the belt: the
commit's durability is still returned, the cycle is not broken."
  (let* ((tmpdir (make-temp-file "belt2c-fail-" t))
         (repo-dir (expand-file-name "repo" tmpdir))
         (iar-personalization-path repo-dir)
         (iar-audit-path "audit")
         (iar--current-agent-name "testagent")
         (iar--current-project "testproject")
         (iar-git-belt-push-remotes (list "nonexistent-remote-xyz")))
    (unwind-protect
        (progn
          (make-directory repo-dir)
          (let ((default-directory repo-dir))
            (call-process "git" nil nil nil "init" "-q")
            (call-process "git" nil nil nil "config" "user.name" "Test")
            (call-process "git" nil nil nil "config" "user.email" "t@i.ar")
            (call-process "git" nil nil nil "remote" "add" "nonexistent-remote-xyz" "/tmp/does-not-exist-xyz.git")
            (call-process "git" nil nil nil "add" "-A")
            (call-process "git" nil nil nil "commit" "-qm" "init"))
          (iar--usage-reset)
          (setq iar--usage-requests 3 iar--usage-input-tokens 100
                iar--usage-output-tokens 40 iar--usage-model "m")
          ;; Durability is still t (the commit landed); the push
          ;; failure is non-fatal.
          (should (eq (iar--usage-write-log-now) t)))
      (delete-directory tmpdir :recursive))))

(ert-deftest test-tool-call-belt2c-push-nil-remotes ()
  "iar-git-belt-push-remotes nil: no push attempted, belt still works."
  (let* ((tmpdir (make-temp-file "belt2c-nil-" t))
         (repo-dir (expand-file-name "repo" tmpdir))
         (iar-personalization-path repo-dir)
         (iar-audit-path "audit")
         (iar--current-agent-name "testagent")
         (iar--current-project "testproject")
         (iar-git-belt-push-remotes nil))
    (unwind-protect
        (progn
          (make-directory repo-dir)
          (let ((default-directory repo-dir))
            (call-process "git" nil nil nil "init" "-q")
            (call-process "git" nil nil nil "config" "user.name" "Test")
            (call-process "git" nil nil nil "config" "user.email" "t@i.ar")
            (call-process "git" nil nil nil "add" "-A")
            (call-process "git" nil nil nil "commit" "-qm" "init"))
          (iar--usage-reset)
          (setq iar--usage-requests 3 iar--usage-input-tokens 100
                iar--usage-output-tokens 40 iar--usage-model "m")
          (should (eq (iar--usage-write-log-now) t))
          ;; No remotes configured: no push, no error.
          t))
      (delete-directory tmpdir :recursive)))

(provide 'test-usage-belt2c-push)
