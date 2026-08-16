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
  "Should resolve tasks dir for current project."
  (with-temp-buffer
    (let ((iar--current-project "test-project"))
      (let ((result (iar--resolve-project-tasks-dir)))
        (should (stringp result))
        (should (string-match-p "test-project" result))
        (should (string-match-p "tasks" result))))))

;;; --- iar--resolve-project-audit-dir tests ---

(ert-deftest test-agent-utils-resolve-project-audit-dir ()
  "Should resolve audit dir for current project + personality."
  (with-temp-buffer
    (let ((iar--current-project "test-project")
          (iar--current-personality "mirror"))
      (let ((result (iar--resolve-project-audit-dir)))
        (should (stringp result))
        (should (string-match-p "test-project" result))
        (should (string-match-p "mirror" result))
        (should (string-match-p "audit" result))))))

(ert-deftest test-agent-utils-resolve-project-audit-dir-no-personality ()
  "Should signal error when no personality is set."
  (with-temp-buffer
    (let ((iar--current-project "test-project")
          (iar--current-personality nil)
          (iar--current-agent-name nil)
          (iar--current-agent-file nil))
      (should-error (iar--resolve-project-audit-dir) :type 'error))))

(provide 'test-agent-utils)
;;; test-agent-utils.el ends here
