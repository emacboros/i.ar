;; -*- lexical-binding: t; -*-

;;; Fail-loud contract for the cycle continue prompt
;;;
;;; iar/timeout-exit0-no-continue (found continuo cycle 5): the loader
;;; wrapped iar--load-prompt in ignore-errors and returned nil on a
;;; missing file. A nil :continue made the post-response handler's
;;; no-continue branch complete the cycle on the FIRST response with
;;; the default exit-code 0 -- so the timeout path's grace-expiry
;;; branch (honest exit 1) was dead code, and a timed-out cycle
;;; exited 0 with no tombstone. Latent while the file exists; a path
;;; rename or partial clone flips it on with no error anywhere.
;;;
;;; Fix (2026-09-03, continuo cycle 6): fail loud at cycle start.
;;; A cycle without a continue prompt is a misconfigured house --
;;; the same class as the librarian fossil's unconditional source.
;;;
;;; NOTE on paths: the suite's iar-prompts-path is set by
;;; test-loop-chain.el to /root/i.ar/prompts/common (an absolute
;;; path -- expand-file-name with an absolute second arg ignores
;;; user-emacs-directory). Load order is alphabetical, so this file
;;; (test-cycle-continue-*) loads BEFORE test-loop-chain and must
;;; set the path itself. The production container uses agents.d/common
;;; (configs/paths.el); the repo copy at prompts/common is the
;;; source-of-truth tree the container image is built from.

(require 'ert)
(require 'iar-agent-cycle)

(ert-deftest test-cycle-continue-prompt-present-in-prod-tree ()
  "The production tree ships agent_cycle_continue.org.
The fix is fail-loud, so this must hold or every cycle dies at
start -- pin the file's existence so a rename breaks THIS test,
not production."
  (let ((path (expand-file-name "agents.d/common/agent_cycle_continue.org"
                                user-emacs-directory)))
    (should (file-exists-p path))
    (should (> (nth 7 (file-attributes path)) 0))))

(ert-deftest test-cycle-continue-prompt-loader-errors-on-missing-file ()
  "The loader must SIGNAL when the continue prompt is missing.
Before the fix it swallowed the error (ignore-errors) and returned
nil; nil :continue is the shape that resurrected timeout-as-success.
Points iar-prompts-path at an empty directory to force the miss."
  (let ((tmpdir (make-temp-file "iar-continue-test" t))
        (iar-prompts-path "agents.d/common"))
    (unwind-protect
        ;; user-emacs-directory-relative resolution: bind
        ;; iar-prompts-path to a path under the temp dir so the
        ;; prompt file cannot exist there.
        (let ((iar-prompts-path (file-name-nondirectory
                                 (directory-file-name tmpdir))))
          (should-error (iar--cycle-load-continue-prompt "darwin")
                        :type 'error))
      (delete-directory tmpdir t))))

(ert-deftest test-cycle-continue-prompt-loader-returns-content ()
  "With the real tree, the loader returns the file's content."
  (let ((result (iar--cycle-load-continue-prompt "darwin")))
    (should (stringp result))
    (should (> (length result) 0))))

(provide 'test-cycle-continue-fail-loud)
;;; test-cycle-continue-fail-loud.el ends here