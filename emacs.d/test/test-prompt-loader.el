;; -*- lexical-binding: t; -*-

;;; Tests for iar-prompt-loader.el
;; Tests prompt template loading from agents.d/common/.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-prompt-loader)

(ert-deftest test-prompt-loader-load-existing ()
  "iar--load-prompt should load an existing prompt template."
  (let ((result (iar--load-prompt "agent_cycle_continue")))
    (should (stringp result))
    (should (> (length result) 0))))

(ert-deftest test-prompt-loader-load-nonexistent ()
  "iar--load-prompt should signal an error for nonexistent template."
  (should-error (iar--load-prompt "nonexistent_template_xyz")
                :type 'error))

(ert-deftest test-prompt-loader-trims-trailing-whitespace ()
  "iar--load-prompt should trim trailing newlines from the template."
  (let ((result (iar--load-prompt "agent_cycle_continue")))
    (should (stringp result))
    ;; Result should not end with a newline
    (should-not (string-suffix-p "\n" result))))

(provide 'test-prompt-loader)
;;; test-prompt-loader.el ends here