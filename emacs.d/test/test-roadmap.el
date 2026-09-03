;; -*- lexical-binding: t; -*-

;;; Tests for read_roadmap and write_roadmap tools.
;; Tests reading and writing the ROADMAP.org file in the agent's tasks directory.
;;
;; 2026-09-03 (continuo): per-agent roadmap isolation. Roadmaps resolve
;; to tasks/<project>/<personality>/ when a personality is active, so
;; two agents sharing a project no longer clobber each other's
;; ROADMAP.org (tasks/* is gitignored -- the clobber was invisible to
;; git status). Fixtures set iar--current-personality accordingly.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-agent-utils)
(require 'iar-tool--read-roadmap)
(require 'iar-tool--write-roadmap)

;;; --- Test fixtures ---

(defvar test-roadmap--tmpdir nil
  "Temporary directory for roadmap tool tests.")

(defun test-roadmap--teardown ()
  "Remove the temporary directory."
  (when (and test-roadmap--tmpdir (file-exists-p test-roadmap--tmpdir))
    (delete-directory test-roadmap--tmpdir t)
    (setq test-roadmap--tmpdir nil)))

(defun test-roadmap--with-env (body-fn)
  "Run BODY-FN with the standard roadmap test environment.
Environment: temp personalization dir, project=testagent,
personality=testagent, existing ROADMAP.org at
tasks/testagent/testagent/ROADMAP.org."
  (let ((old-emacs-dir user-emacs-directory)
        (old-agent-name (and (boundp 'iar--current-agent-name)
                             iar--current-agent-name))
        (old-project (and (boundp 'iar--current-project)
                          iar--current-project))
        (old-personality (and (boundp 'iar--current-personality)
                              iar--current-personality))
        (old-pers-path (and (boundp 'iar-personalization-path)
                            iar-personalization-path)))
    (unwind-protect
        (progn
          (setq test-roadmap--tmpdir (make-temp-file "test-roadmap-" :dir-flag))
          (let ((roadmap-dir (expand-file-name "tasks/testagent/testagent" test-roadmap--tmpdir)))
            (make-directory roadmap-dir t)
            (with-temp-file (expand-file-name "ROADMAP.org" roadmap-dir)
              (insert "* Existing Roadmap\n\nOld content here.")))
          (let ((user-emacs-directory test-roadmap--tmpdir))
            (setq iar--current-agent-name "testagent")
            (setq iar--current-project "testagent")
            (setq iar--current-personality "testagent")
            (setq iar-personalization-path test-roadmap--tmpdir)
            (funcall body-fn)))
      (test-roadmap--teardown)
      (setq user-emacs-directory old-emacs-dir)
      (setq iar--current-agent-name old-agent-name)
      (setq iar--current-project old-project)
      (setq iar--current-personality old-personality)
      (setq iar-personalization-path old-pers-path))))

(defmacro with-roadmap-fixture (&rest body)
  "Execute BODY with the standard roadmap test environment."
  (declare (indent 0))
  `(test-roadmap--with-env (lambda () ,@body)))

;;; --- read_roadmap tests ---

(ert-deftest test-roadmap-read-existing ()
  "read_roadmap should return the content of an existing ROADMAP.org."
  (with-roadmap-fixture
    (let ((result (iar--tool-read-roadmap)))
      (should (stringp result))
      (should (string-match-p "Existing Roadmap" result))
      (should (string-match-p "Old content here" result)))))

(ert-deftest test-roadmap-read-missing ()
  "read_roadmap should return a message when no roadmap exists."
  (test-roadmap--with-env
   (lambda ()
     (delete-file (expand-file-name
                   "tasks/testagent/testagent/ROADMAP.org"
                   test-roadmap--tmpdir))
     (let ((result (iar--tool-read-roadmap)))
       (should (stringp result))
       (should (string-match-p "No roadmap found" result))))))

(ert-deftest test-roadmap-write-new ()
  "write_roadmap should create a new ROADMAP.org at the per-agent path."
  (test-roadmap--with-env
   (lambda ()
     (delete-file (expand-file-name
                   "tasks/testagent/testagent/ROADMAP.org"
                   test-roadmap--tmpdir))
     (let ((result (iar--tool-write-roadmap "* New Roadmap\n\nFresh content.")))
       (should (stringp result))
       (should (string-match-p "Success" result))
       (let ((roadmap-path (expand-file-name
                            "tasks/testagent/testagent/ROADMAP.org"
                            test-roadmap--tmpdir)))
         (should (file-exists-p roadmap-path))
         (with-temp-buffer
           (insert-file-contents roadmap-path)
           (should (string-match-p "New Roadmap" (buffer-string)))))))))

(ert-deftest test-roadmap-write-overwrite ()
  "write_roadmap should overwrite an existing ROADMAP.org."
  (with-roadmap-fixture
    (let ((result (iar--tool-write-roadmap "* Updated Roadmap\n\nNew content.")))
      (should (stringp result))
      (should (string-match-p "Success" result))
      (let ((roadmap-path (expand-file-name
                           "tasks/testagent/testagent/ROADMAP.org"
                           test-roadmap--tmpdir)))
        (with-temp-buffer
          (insert-file-contents roadmap-path)
          (should (string-match-p "Updated Roadmap" (buffer-string)))
          (should-not (string-match-p "Existing Roadmap" (buffer-string))))))))

;;; --- Per-agent isolation (the 2026-09-03 clobber regression) ---

(ert-deftest test-roadmap-per-agent-isolation ()
  "Two personalities in one project must resolve to different roadmaps."
  (with-roadmap-fixture
    (let ((aria-result (iar--tool-read-roadmap)))
      (should (string-match-p "Existing Roadmap" aria-result))
      ;; Switch personality in the same project.
      (setq iar--current-personality "otheragent")
      (setq iar--current-agent-name "otheragent")
      ;; Other agent sees no roadmap (its directory does not exist).
      (let ((result (iar--tool-read-roadmap)))
        (should (stringp result))
        (should (string-match-p "No roadmap found" result)))
      ;; Other agent writes its own roadmap; aria's is untouched.
      (let ((result (iar--tool-write-roadmap "* Other Agent Roadmap")))
        (should (string-match-p "Success" result)))
      (with-temp-buffer
        (insert-file-contents
         (expand-file-name "tasks/testagent/testagent/ROADMAP.org"
                           test-roadmap--tmpdir))
        (should (string-match-p "Existing Roadmap" (buffer-string))))
      (with-temp-buffer
        (insert-file-contents
         (expand-file-name "tasks/testagent/otheragent/ROADMAP.org"
                           test-roadmap--tmpdir))
        (should (string-match-p "Other Agent Roadmap" (buffer-string)))))))

(ert-deftest test-roadmap-no-personality-falls-back-to-project ()
  "Without a personality, roadmap resolves to the project dir (legacy)."
  (test-roadmap--with-env
   (lambda ()
     (setq iar--current-personality nil)
     (setq iar--current-agent-name nil)
     (setq iar--current-agent-file nil)
     (let ((result (iar--tool-read-roadmap)))
       (should (stringp result))
       ;; Legacy path has no ROADMAP.org in this fixture -> missing message,
       ;; which proves resolution went to tasks/testagent/ not .../testagent/.
       (should (string-match-p "No roadmap found" result))
       (should (string-match-p "tasks/testagent/ROADMAP.org" result))))))

;;; --- error handler tests ---

(ert-deftest test-roadmap-write-error-handler ()
  "iar--tool-write-roadmap should return error string on failure."
  (cl-letf (((symbol-function 'iar--resolve-project-tasks-dir)
             (lambda () (signal 'file-error "mock error"))))
    (let ((result (iar--tool-write-roadmap "test content")))
      (should (stringp result))
      (should (string-match-p "Error writing roadmap" result)))))

(ert-deftest test-roadmap-read-error-handler ()
  "iar--tool-read-roadmap should return error string on failure."
  (cl-letf (((symbol-function 'iar--resolve-project-tasks-dir)
             (lambda () (signal 'file-error "mock error"))))
    (let ((result (iar--tool-read-roadmap)))
      (should (stringp result))
      (should (string-match-p "Error reading roadmap" result)))))

(provide 'test-roadmap)
;;; test-roadmap.el ends here