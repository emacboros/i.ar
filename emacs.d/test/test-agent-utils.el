;; -*- lexical-binding: t; -*-

;;; Tests for iar-agent-utils.el
;; Tests validation, project/personality resolution, and path helpers.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-agent-utils)

;;; --- iar--valid-name-p tests ---

(ert-deftest test-agent-utils-valid-name-p-alnum ()
  "Should accept alphanumeric name."
  (should (iar--valid-name-p "test123")))

(ert-deftest test-agent-utils-valid-name-p-hyphens-underscores ()
  "Should accept hyphens and underscores."
  (should (iar--valid-name-p "test-name_1")))

(ert-deftest test-agent-utils-valid-name-p-nil ()
  "Should reject nil."
  (should-not (iar--valid-name-p nil)))

(ert-deftest test-agent-utils-valid-name-p-empty ()
  "Should reject empty string."
  (should-not (iar--valid-name-p "")))

(ert-deftest test-agent-utils-valid-name-p-slash ()
  "Should reject names with slashes."
  (should-not (iar--valid-name-p "foo/bar")))

(ert-deftest test-agent-utils-valid-name-p-non-string ()
  "Should reject non-strings."
  (should-not (iar--valid-name-p 42)))

;;; --- iar--validate-agent-name tests ---

(ert-deftest test-agent-utils-validate-agent-name-valid ()
  "Should return name when valid."
  (should (string= "test" (iar--validate-agent-name "test"))))

(ert-deftest test-agent-utils-validate-agent-name-invalid ()
  "Should signal error for invalid name."
  (should-error (iar--validate-agent-name "foo/bar") :type 'error))

;;; --- iar--validate-task-path tests ---

(ert-deftest test-agent-utils-validate-task-path-valid ()
  "Should return path when valid."
  (should (string= "a/b" (iar--validate-task-path "a/b"))))

(ert-deftest test-agent-utils-validate-task-path-nil ()
  "Should signal error for nil path."
  (should-error (iar--validate-task-path nil) :type 'error))

(ert-deftest test-agent-utils-validate-task-path-empty ()
  "Should signal error for empty path."
  (should-error (iar--validate-task-path "  ") :type 'error))

(ert-deftest test-agent-utils-validate-task-path-non-string ()
  "Should signal error for non-string path."
  (should-error (iar--validate-task-path 42) :type 'error))

;;; --- iar--current-project-name tests ---

(ert-deftest test-agent-utils-current-project-name-from-var ()
  "Should return project from iar--current-project."
  (with-temp-buffer
    (let ((iar--current-project "my-project"))
      (should (string= "my-project" (iar--current-project-name))))))

(ert-deftest test-agent-utils-current-project-name-from-env ()
  "Should return project from IAR_PROJECT env var."
  (with-temp-buffer
    (let ((iar--current-project nil)
          (process-environment (cons "IAR_PROJECT=env-project" process-environment)))
      (should (string= "env-project" (iar--current-project-name))))))

(ert-deftest test-agent-utils-current-project-name-default ()
  "Should return 'iar' when no project is set."
  (with-temp-buffer
    (let ((iar--current-project nil)
          (process-environment (remove "IAR_PROJECT=iar" process-environment)))
      (should (string= "iar" (iar--current-project-name))))))

;;; --- iar--current-personality-name tests ---

(ert-deftest test-agent-utils-current-personality-name-from-var ()
  "Should return personality from iar--current-personality."
  (with-temp-buffer
    (let ((iar--current-personality "mirror"))
      (should (string= "mirror" (iar--current-personality-name))))))

(ert-deftest test-agent-utils-current-personality-name-fallback ()
  "Should fall back to iar--get-agent-name when personality is nil."
  (with-temp-buffer
    (let ((iar--current-personality nil)
          (iar--current-agent-name "fallback-agent"))
      (should (string= "fallback-agent" (iar--current-personality-name))))))

(ert-deftest test-agent-utils-current-personality-name-nil ()
  "Should return nil when no personality is set."
  (with-temp-buffer
    (let ((iar--current-personality nil)
          (iar--current-agent-name nil)
          (iar--current-agent-file nil))
      (should (null (iar--current-personality-name))))))

;;; --- iar--resolve-project-tasks-dir tests ---

(ert-deftest test-agent-utils-resolve-project-tasks-dir ()
  "Should resolve tasks dir for current project (no personality)."
  (with-temp-buffer
    (let ((iar--current-project "test-project")
          (iar--current-personality nil)
          (iar--current-agent-name nil)
          (iar--current-agent-file nil))
      (let ((result (iar--resolve-project-tasks-dir)))
        (should (stringp result))
        (should (string-match-p "test-project" result))
        (should (string-match-p "tasks" result))
        ;; Legacy layout: no personality segment.
        (should-not (string-match-p "tasks/test-project/" result))))))

(ert-deftest test-agent-utils-resolve-project-tasks-dir-per-agent ()
  "With a personality, tasks dir gains a personality segment.
Regression for the 2026-09-03 shared-ROADMAP clobber: two agents
in one project must not share tasks/<project>/."
  (with-temp-buffer
    (let ((iar--current-project "test-project")
          (process-environment (cons "IAR_PROJECT=test-project"
                                     process-environment)))
      (setq iar--current-personality "aria")
      (should (string-match-p "tasks/test-project/aria"
                              (iar--resolve-project-tasks-dir)))
      (setq iar--current-personality "continuo")
      (should (string-match-p "tasks/test-project/continuo"
                              (iar--resolve-project-tasks-dir)))
      ;; The two resolutions differ -- that is the whole point.
      (setq iar--current-personality "aria")
      (let ((aria (iar--resolve-project-tasks-dir)))
        (setq iar--current-personality "continuo")
        (let ((continuo (iar--resolve-project-tasks-dir)))
          (should-not (string= aria continuo)))))))

(ert-deftest test-agent-utils-resolve-project-tasks-dir-rejects-bad-personality ()
  "A personality with invalid characters must be rejected."
  (with-temp-buffer
    (let ((iar--current-project "test-project")
          (iar--current-personality "../evil"))
      (should-error (iar--resolve-project-tasks-dir)))))

(provide 'test-agent-utils)
;;; test-agent-utils.el ends here
;;; --- task-path prefix-doubling guard (2026-09-11, aria c208) ---
;; Regression: agents passing "project/personality/..." paths produced
;; doubled on-disk trees (tasks/iar/continuo/iar/continuo/...).

(ert-deftest test-agent-utils-strip-agent-prefix-strips ()
  "Should strip a leading project/personality prefix."
  (with-temp-buffer
    (let ((iar--current-project "iar")
          (iar--current-personality "continuo"))
      (should (string= "tasks/context-budget-integration"
                       (iar--task-path-strip-agent-prefix
                        "iar/continuo/tasks/context-budget-integration"))))))

(ert-deftest test-agent-utils-strip-agent-prefix-leaves-plain ()
  "Should leave plain paths untouched."
  (with-temp-buffer
    (let ((iar--current-project "iar")
          (iar--current-personality "continuo"))
      (should (string= "failure-reduction/context-budget-rule"
                       (iar--task-path-strip-agent-prefix
                        "failure-reduction/context-budget-rule"))))))

(ert-deftest test-agent-utils-strip-agent-prefix-other-agent-prefix ()
  "A DIFFERENT agent's prefix is content, not a prefix -- leave it."
  (with-temp-buffer
    (let ((iar--current-project "iar")
          (iar--current-personality "continuo"))
      (should (string= "aria/aria-something"
                       (iar--task-path-strip-agent-prefix
                        "aria/aria-something"))))))

(ert-deftest test-agent-utils-strip-agent-prefix-no-personality ()
  "No personality active: nothing to strip, path unchanged."
  (with-temp-buffer
    (let ((iar--current-project "iar")
          (iar--current-personality nil))
      (should (string= "iar/continuo/tasks/x"
                       (iar--task-path-strip-agent-prefix
                        "iar/continuo/tasks/x"))))))

(ert-deftest test-agent-utils-resolve-task-dir-no-doubling ()
  "End-to-end: resolving an agent-prefixed path must NOT double it.
The doubled path was tasks/iar/continuo/iar/continuo/... on disk."
  (with-temp-buffer
    (let ((iar--current-project "iar")
          (iar--current-personality "continuo"))
      (let ((result (iar--resolve-task-dir
                     "iar/continuo/tasks/context-budget-integration")))
        (should (string-match-p "tasks/iar/continuo/tasks/context-budget-integration" result))
        (should-not (string-match-p "iar/continuo/iar/continuo" result))))))

(provide 'test-agent-utils)
