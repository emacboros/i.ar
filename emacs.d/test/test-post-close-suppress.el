;; -*- lexical-binding: t; -*-
;;; c348 post-close request suppression tests (relay 0069 option a).
;;; The empty-end class: the terminal-echo close sets :completed and
;;; blocks the echo call, but gptel's tool loop transitions TRET -> WAIT
;;; and fires ONE MORE request (gptel--handle-wait). The model answers
;;; that post-completion question with an empty body (0/0) and the
;;; tombstone kills a cycle that had already done its job. Census:
;;; 14 empty-ends in continuo's log (8-in-7d), all immediately after
;;; the echo request (c348 full-population verification).
;;;
;;; The fix: a :around gate on gptel--handle-wait -- when the active
;;; run is :completed, the request never fires. Law 39: tests replay
;;; the production shape (a live FSM whose WAIT handler would fire a
;;; curl request), and assert the gate's contract:
;;; - :completed t  -> suppressed (no curl fire, no request)
;;; - :completed nil -> fires (the cycle's first request, grace
;;;   round-trips, landing re-sends all pass through)
;;; - no state -> fires (interactive/delegate paths untouched)

(require 'ert)
(require 'cl-lib)
(require 'iar-agent-cycle)

(defun iar--test-suppress-fsm ()
  "A minimal FSM whose info plist has the keys gptel--handle-wait
touches (:buffer for the post-request hook)."
  (gptel-make-fsm :info (list :buffer (get-buffer-create "*test-suppress*"))))

(ert-deftest test-post-close-suppress-blocks-after-completed ()
  "A completed run's next WAIT is suppressed: no request fires."
  (let* ((buf (get-buffer-create "*test-suppress*"))
         (iar--cycle-state (iar--cycle-make-state "test" buf nil 40))
         (iar--one-shot-state nil)
         (fired nil))
    (unwind-protect
        (progn
          (plist-put iar--cycle-state :completed t)
          (plist-put iar--cycle-state :exit-code 0)
          (cl-letf (((symbol-function 'gptel-curl-get-response)
                     (lambda (&rest _) (setq fired t))))
            (with-current-buffer buf
              ;; The FSM is mid-tool-loop: TRET -> WAIT transition
              ;; invokes WAIT's handler (gptel--handle-wait), which is
              ;; advised with the gate.
              (gptel--handle-wait (iar--test-suppress-fsm)))
            (should-not fired)))
      (setq iar--cycle-state nil)
      (kill-buffer buf))))

(ert-deftest test-post-close-suppress-passes-before-completed ()
  "An active (not completed) run's WAIT fires normally: the cycle's
first request, grace round-trips, and landing re-sends all pass."
  (let* ((buf (get-buffer-create "*test-suppress*"))
         (iar--cycle-state (iar--cycle-make-state "test" buf nil 40))
         (iar--one-shot-state nil)
         (fired nil))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'gptel-curl-get-response)
                     (lambda (&rest _) (setq fired t))))
            (with-current-buffer buf
              (gptel--handle-wait (iar--test-suppress-fsm)))
            (should fired)))
      (setq iar--cycle-state nil)
      (kill-buffer buf))))

(ert-deftest test-post-close-suppress-passes-without-state ()
  "No active state (interactive gptel, delegates) -> WAIT fires."
  (let* ((iar--cycle-state nil)
         (iar--one-shot-state nil)
         (fired nil)
         (buf (get-buffer-create "*test-suppress*")))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'gptel-curl-get-response)
                     (lambda (&rest _) (setq fired t))))
            (with-current-buffer buf
              (gptel--handle-wait (iar--test-suppress-fsm)))
            (should fired)))
      (kill-buffer buf))))

(ert-deftest test-post-close-suppress-one-shot-completed ()
  "One-shot edition: a completed one-shot's WAIT is suppressed too."
  (let* ((buf (get-buffer-create "*test-suppress*"))
         (iar--cycle-state nil)
         (iar--one-shot-state (iar--cycle-make-state "test" buf nil 40))
         (fired nil))
    (unwind-protect
        (progn
          (plist-put iar--one-shot-state :completed t)
          (plist-put iar--one-shot-state :exit-code 0)
          (cl-letf (((symbol-function 'gptel-curl-get-response)
                     (lambda (&rest _) (setq fired t))))
            (with-current-buffer buf
              (gptel--handle-wait (iar--test-suppress-fsm)))
            (should-not fired)))
      (setq iar--one-shot-state nil)
      (kill-buffer buf))))

(ert-deftest test-post-close-suppress-advice-registered ()
  "The gate is registered as advice on gptel--handle-wait."
  (should (advice-member-p 'iar--cycle-suppress-post-close-wait
                           'gptel--handle-wait)))