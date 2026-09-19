;; -*- lexical-binding: t; -*-

;;; Tests for the c80 abort-aware cycle branch
;;
;; Contract: a guard-aborted turn whose partial thinking landed in the
;; buffer takes the SUCCESS path (START < END). The reqlog witness for
;; an aborted stream is stop=nil + tokens-out=nil (the final chunk with
;; the token counts never arrives). The handler must re-prompt with the
;; SHARED abort-continue prompt (law 41: change the question), count
;; strikes, and end LOUD past the cap. A turn with a real stop reason
;; resets the counter.

(require 'ert)
(require 'iar-agent-cycle)
(require 'iar-agent-utils)

(defun iar--test-abort-setup-buffer (text)
  "Create a test buffer with TEXT, return it."
  (let ((buf (get-buffer-create "*test-cycle-abort*")))
    (with-current-buffer buf
      (erase-buffer)
      (insert text))
    buf))

(ert-deftest test-cycle-abort-reprompts-with-abort-aware-prompt ()
  "An aborted turn (reqlog abort flag set) re-prompts with the shared
abort-continue prompt, not the standard continue prompt."
  (let* ((buf (iar--test-abort-setup-buffer "thinking fragment (aborted mid-stream)"))
        (sent nil)
        (iar--reqlog-last-abort t)
        (iar--reqlog-last-abort-buf buf)
        (iar--cycle-abort-strikes 0))
    (unwind-protect
        (with-current-buffer buf
          (let ((iar--cycle-state (iar--cycle-make-state "test" buf "Continue." 40)))
            (cl-letf (((symbol-function 'gptel-send)
                       (lambda () (setq sent (buffer-substring-no-properties
                                              (point-min) (point-max))))))
              (iar--cycle-post-response-handler (point-min) (point-max))
              (should sent)
              (should (string-match-p "ABORTED by the thinking-loop guard" sent))
              (should (= 1 iar--cycle-abort-strikes))
              ;; Not completed: the re-prompt continues the cycle.
              (should-not (plist-get iar--cycle-state :completed)))))
      (kill-buffer buf))))

(ert-deftest test-cycle-abort-strike-counts-consecutively ()
  "Two consecutive aborted turns: strike 2, still re-prompting."
  (let* ((buf (iar--test-abort-setup-buffer "more aborted thinking"))
        (sends 0)
        (iar--reqlog-last-abort t)
        (iar--reqlog-last-abort-buf buf)
        (iar--cycle-abort-strikes 0))
    (unwind-protect
        (with-current-buffer buf
          (let ((iar--cycle-state (iar--cycle-make-state "test" buf "Continue." 40)))
            (cl-letf (((symbol-function 'gptel-send) (lambda () (cl-incf sends))))
              ;; First abort
              (setq iar--reqlog-last-abort t
                    iar--reqlog-last-abort-buf buf)
              (iar--cycle-post-response-handler (point-min) (point-max))
              (should (= 1 iar--cycle-abort-strikes))
              ;; Second abort (the re-prompt's response also aborted):
              ;; the second gptel-abort re-sets the flag (consumed on
              ;; first read).
              (setq iar--reqlog-last-abort t
                    iar--reqlog-last-abort-buf buf)
              (iar--cycle-post-response-handler (point-min) (point-max))
              (should (= 2 iar--cycle-abort-strikes))
              (should (= 2 sends))
              (should-not (plist-get iar--cycle-state :completed)))))
      (kill-buffer buf))))

(ert-deftest test-cycle-abort-ends-loud-past-cap ()
  "Third consecutive abort (cap 2): cycle ends LOUD with exit 1."
  (let* ((buf (iar--test-abort-setup-buffer "third aborted fragment"))
        (sends 0)
        (iar--reqlog-last-abort t)
        (iar--reqlog-last-abort-buf buf)
        (iar--cycle-abort-strikes 0))
    (unwind-protect
        (with-current-buffer buf
          (let ((iar--cycle-state (iar--cycle-make-state "test" buf "Continue." 40)))
            (cl-letf (((symbol-function 'gptel-send) (lambda () (cl-incf sends))))
              (setq iar--reqlog-last-abort t
                    iar--reqlog-last-abort-buf buf)
              (iar--cycle-post-response-handler (point-min) (point-max))
              (setq iar--reqlog-last-abort t
                    iar--reqlog-last-abort-buf buf)
              (iar--cycle-post-response-handler (point-min) (point-max))
              (should (= 2 iar--cycle-abort-strikes))
              ;; Third abort: past the cap
              (setq iar--reqlog-last-abort t
                    iar--reqlog-last-abort-buf buf)
              (iar--cycle-post-response-handler (point-min) (point-max))
              (should (= 3 iar--cycle-abort-strikes))
              (should (= 2 sends))              ; no third re-send
              (should (plist-get iar--cycle-state :completed))
              (should (= 1 (plist-get iar--cycle-state :exit-code))))))
      (kill-buffer buf))))

(ert-deftest test-cycle-abort-strikes-reset-on-real-turn ()
  "A turn with a real stop reason resets the abort-strike counter."
  (let ((buf (iar--test-abort-setup-buffer "normal turn output"))
        (sends 0)
        (iar--reqlog-last-abort nil)
        (iar--cycle-abort-strikes 2))
    (unwind-protect
        (with-current-buffer buf
          (let ((iar--cycle-state (iar--cycle-make-state "test" buf "Continue." 40)))
            (cl-letf (((symbol-function 'gptel-send) (lambda () (cl-incf sends))))
              ;; Real turn: falls through the abort branch (stop non-nil),
              ;; hits the continue branch, resets the counter.
              (iar--cycle-post-response-handler (point-min) (point-max))
              (should (= 0 iar--cycle-abort-strikes))
              (should (= 1 sends)))))
      (kill-buffer buf))))

(ert-deftest test-cycle-abort-branch-not-firing-on-real-stop ()
  "A turn that was NOT aborted (flag nil) does not take the abort
branch -- the flag is a direct witness, not an inference."
  (let ((buf (iar--test-abort-setup-buffer "real turn"))
        (sends 0)
        (iar--reqlog-last-abort nil)
        (iar--cycle-abort-strikes 0))
    (unwind-protect
        (with-current-buffer buf
          (let ((iar--cycle-state (iar--cycle-make-state "test" buf "Continue." 40)))
            (cl-letf (((symbol-function 'gptel-send) (lambda () (cl-incf sends))))
              (iar--cycle-post-response-handler (point-min) (point-max))
              (should (= 0 iar--cycle-abort-strikes)))))
      (kill-buffer buf))))

(ert-deftest test-cycle-abort-shared-prompt-bound ()
  "The shared prompt const is bound (iar-agent-utils loaded)."
  (should (stringp iar--abort-continue-prompt))
  (should (> (length iar--abort-continue-prompt) 100)))

(ert-deftest test-cycle-abort-delegate-alias-matches-shared ()
  "The delegate alias carries the same text as the shared prompt."
  (should (equal iar--abort-continue-prompt iar--delegate-abort-continue-prompt)))

(provide 'test-cycle-abort-aware)
(ert-deftest test-cycle-abort-foreign-buffer-not-consumed ()
  "c81: an abort recorded for a FOREIGN buffer (a delegate's) must
not take the cycle's abort branch -- the parent's healthy turn must
not take a phantom strike, and the strike counter must reset."
  (let* ((foreign-buf (get-buffer-create "*test-foreign-delegate*"))
        (buf (iar--test-abort-setup-buffer "healthy turn after delegate abort"))
        (sends 0)
        (iar--reqlog-last-abort t)
        (iar--reqlog-last-abort-buf foreign-buf)
        (iar--cycle-abort-strikes 1))
    (unwind-protect
        (with-current-buffer buf
          (let ((iar--cycle-state (iar--cycle-make-state "test" buf "Continue." 40)))
            (cl-letf (((symbol-function 'gptel-send) (lambda () (cl-incf sends))))
              (iar--cycle-post-response-handler (point-min) (point-max))
              ;; Foreign abort consumed (cleared) but NOT counted:
              (should-not iar--reqlog-last-abort)
              (should-not iar--reqlog-last-abort-buf)
              (should (= 0 iar--cycle-abort-strikes))
              (should (= 1 sends))
              (should-not (plist-get iar--cycle-state :completed)))))
      (kill-buffer buf)
      (kill-buffer foreign-buf))))

(ert-deftest test-cycle-abort-own-buffer-consumed ()
  "c81: an abort recorded for the CYCLE buffer itself still takes
the abort branch (the c80 contract, now buffer-scoped)."
  (let* ((buf (iar--test-abort-setup-buffer "own aborted thinking"))
        (sends 0)
        (iar--reqlog-last-abort t)
        (iar--reqlog-last-abort-buf buf)
        (iar--cycle-abort-strikes 0))
    (unwind-protect
        (with-current-buffer buf
          (let ((iar--cycle-state (iar--cycle-make-state "test" buf "Continue." 40)))
            (cl-letf (((symbol-function 'gptel-send) (lambda () (cl-incf sends))))
              (iar--cycle-post-response-handler (point-min) (point-max))
              (should (= 1 iar--cycle-abort-strikes))
              (should (= 1 sends))
              (should-not iar--reqlog-last-abort)
              (should-not iar--reqlog-last-abort-buf))))
      (kill-buffer buf))))

(ert-deftest test-cycle-abort-reset-last-clears-buf ()
  "c81: iar--reqlog-reset-last clears the buffer-scoped witness too."
  (let ((iar--reqlog-last-abort t)
        (iar--reqlog-last-abort-buf (current-buffer)))
    (iar--reqlog-reset-last)
    (should-not iar--reqlog-last-abort)
    (should-not iar--reqlog-last-abort-buf)))

(provide 'test-cycle-abort-aware)
