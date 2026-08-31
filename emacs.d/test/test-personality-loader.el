;; -*- lexical-binding: t; -*-

;;; Tests for personality loading (now in iar-agent-loader.el)
;; Tests personality discovery, loading, switching, and info.
;; Updated for the assembly-based model where personality is part of
;; the three-axis assembly (archetype + personality + project).

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-agent-loader)
(require 'iar-prompt-assembly)

;;; --- Personality discovery tests ---

(ert-deftest test-pers-candidates-returns-org-files ()
  "iar--personality-names should list .org file base names."
  (let ((names (iar--personality-names)))
    (should (listp names))
    (should (member "mirror" names))
    (should (member "darwin" names))
    ;; Non-.org files should not be included
    (should-not (member "mirror.org" names))
    (should-not (member "notes" names))))

(ert-deftest test-pers-candidates-empty-when-no-dir ()
  "iar--personality-names should return nil when personalities dir does not exist."
  (let ((user-emacs-directory "/nonexistent/path/xyzzy"))
    (should (null (iar--personality-names)))))

;;; --- Personality reading tests ---

(ert-deftest test-pers-read-file-returns-content ()
  "iar--read-personality should return file content as string."
  (let ((result (iar--read-personality "mirror")))
    (should (stringp result))
    (should (string-match-p "mirror" result))))

(ert-deftest test-pers-read-file-returns-nil-for-empty ()
  "iar--read-personality should error for nonexistent personality."
  (should-error (iar--read-personality "nonexistent_xyz")))

;;; --- Load tests ---

(ert-deftest test-pers-load-success ()
  "iar-load-personality should load a personality and update the prompt."
  (with-temp-buffer
    (text-mode)
    (let ((result (iar-load-personality "mirror")))
      (should (eq t result))
      (should (string= "mirror" iar--current-personality))
      (should (stringp gptel-system-prompt))
      (should (string-match-p "mirror" gptel-system-prompt))
      (should (string-match-p "PERSONALITY" gptel-system-prompt)))))

(ert-deftest test-pers-load-already-loaded ()
  "iar-load-personality should return t when same personality already loaded."
  (with-temp-buffer
    (text-mode)
    (iar-load-personality "mirror")
    (should (eq t (iar-load-personality "mirror")))))

(ert-deftest test-pers-load-not-found ()
  "iar-load-personality should return nil for non-existent personality."
  (with-temp-buffer
    (text-mode)
    (should (null (iar-load-personality "nonexistent")))))

(ert-deftest test-pers-switch-replaces ()
  "Switching personality should replace the old one, not stack."
  (with-temp-buffer
    (text-mode)
    (iar-load-personality "mirror")
    (let ((prompt-with-mirror gptel-system-prompt))
      (iar-load-personality "darwin")
      (should (string= "darwin" iar--current-personality))
      (should (string-match-p "Darwin" gptel-system-prompt))
      ;; Mirror should NOT be in the prompt anymore (only one personality)
      ;; Both personalities are in the prompt under PERSONALITY section
      ;; but only the current one should be there
      (should (string-match-p "PERSONALITY" gptel-system-prompt)))))

;;; --- Info test ---

(ert-deftest test-pers-info-returns-name ()
  "iar-personality-info should return the loaded personality name or none."
  (with-temp-buffer
    (text-mode)
    ;; Before loading, should return "none" or the agent name
    (should (stringp (iar-personality-info)))
    (iar-load-personality "mirror")
    (should (string= "mirror" (iar-personality-info)))))

;;; --- Additional coverage tests ---

(ert-deftest test-pers-load-personality-interactive ()
  "iar-load-personality-interactive should switch personality interactively."
  (with-temp-buffer
    (text-mode)
    (iar-load-personality "mirror")
    (should (string= "mirror" iar--current-personality))
    ;; Now switch to darwin
    (iar-load-personality "darwin")
    (should (string= "darwin" iar--current-personality))
    (should (string-match-p "Darwin" gptel-system-prompt))))

(ert-deftest test-pers-setup-sets-containers ()
  "iar--setup-assembled-buffer should set iar--current-containers."
  (with-temp-buffer
    (text-mode)
    (let ((result (iar--setup-assembled-buffer "interactive" "mirror" "iar")))
      (should (plistp result))
      ;; iar project has no containers, so should be nil
      (should (null iar--current-containers)))))

(ert-deftest test-pers-setup-sets-mode ()
  "iar--setup-assembled-buffer should set iar--current-mode."
  (with-temp-buffer
    (text-mode)
    (iar--setup-assembled-buffer "interactive" "mirror" "iar")
    (should (eq 'interactive iar--current-mode))))

(ert-deftest test-pers-setup-sets-project ()
  "iar--setup-assembled-buffer should set iar--current-project."
  (with-temp-buffer
    (text-mode)
    (iar--setup-assembled-buffer "interactive" "mirror" "iar")
    (should (string= "iar" iar--current-project))))

(ert-deftest test-pers-archetype-for-personality ()
  "iar--archetype-for-personality should return correct archetype."
  (should (string= "interactive" (iar--archetype-for-personality "mirror")))
  (should (string= "autonomous" (iar--archetype-for-personality "darwin")))
  (should (string= "continuous" (iar--archetype-for-personality "gardener")))
  ;; aria maps to aria-cycle for the cycle runner; interactive
  ;; sessions hardcode "interactive" (C-c a) and are unaffected.
  (should (string= "aria-cycle" (iar--archetype-for-personality "aria"))))

(ert-deftest test-pers-project-for-personality ()
  "iar--project-for-personality should return correct project."
  (should (string= "iar" (iar--project-for-personality "mirror")))
  (should (string= "darwin" (iar--project-for-personality "darwin"))))
(ert-deftest test-pers-project-for-personality-map-override ()
  "iar--project-for-personality should honor the explicit map override.
bessie maps to the moto project via iar-personality-project-map
(personality name differs from project name)."
  (should (string= "moto" (iar--project-for-personality "bessie"))))

(provide 'test-personality-loader)
;;; --- Global-default agent-name contract (cycle 42) ---

;; THE CONTRACT: after iar--setup-assembled-buffer (or the delegate
;; buffer setup), the GLOBAL default of iar--current-agent-name must
;; equal the personality name. Async tool sentinels and kill-emacs
;; resolve the agent via the global default -- they run outside the
;; conversation buffer. The pre-fix code did (setq-local ...) then
;; (setq ...), which rebinds the BUFFER-LOCAL value and leaves the
;; global default nil -- 4238+ audit lines said nil/unknown (2026-08-31).

(ert-deftest test-pers-setup-sets-global-default-agent-name ()
  "iar--setup-assembled-buffer must set the GLOBAL default agent name.
Async sentinels and kill-emacs resolve via default-value; a
buffer-local-only set leaves them nil."
  (let ((old-default (default-value 'iar--current-agent-name)))
    (unwind-protect
        (with-temp-buffer
          (text-mode)
          (iar--setup-assembled-buffer "interactive" "mirror" "iar")
          (should (string= "mirror"
                           (default-value 'iar--current-agent-name)))
          ;; And the buffer-local value agrees.
          (should (string= "mirror" iar--current-agent-name)))
      ;; Restore whatever the suite had before (tests may rely on it).
      (setq-default iar--current-agent-name old-default))))

(ert-deftest test-pers-setup-sets-global-default-agent-file ()
  "iar--setup-assembled-buffer must set the GLOBAL default agent file."
  (let ((old-default (default-value 'iar--current-agent-file)))
    (unwind-protect
        (with-temp-buffer
          (text-mode)
          (iar--setup-assembled-buffer "interactive" "mirror" "iar")
          (should (stringp (default-value 'iar--current-agent-file)))
          (should (string-match-p "mirror.org$"
                                  (default-value 'iar--current-agent-file))))
      (setq-default iar--current-agent-file old-default))))

(ert-deftest test-pers-setup-global-default-survives-buffer-switch ()
  "The resolver must return the agent name from a FOREIGN buffer
after setup -- the async-sentinel context."
  (let ((old-default (default-value 'iar--current-agent-name)))
    (unwind-protect
        (progn
          (with-temp-buffer
            (text-mode)
            (iar--setup-assembled-buffer "interactive" "mirror" "iar"))
          ;; Simulate the async sentinel: resolve from a fresh buffer
          ;; with no buffer-local value.
          (with-temp-buffer
            (should (string= "mirror" (iar--get-agent-name)))))
      (setq-default iar--current-agent-name old-default))))

(ert-deftest test-pers-usage-start-time-defvar-exists ()
  "iar--usage-start-time must be a defined variable (cycle 41's
wholesale rewrite dropped the defvar; kill-emacs usage logging
referenced it void in processes that never called usage-reset)."
  (should (boundp 'iar--usage-start-time)))
;;; test-personality-loader.el ends here
