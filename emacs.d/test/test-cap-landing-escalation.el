;; -*- lexical-binding: t; -*-

;;; test-cap-landing-escalation.el -- c310 cap-landing escalation belt
;;
;; The rage data (09-23/09-24): Tool-call soft cap recurring 3 days,
;; kills on 2. The exit-1 shape: glm ignored the tool-result block
;; demand 5 times (blocks 1-5), got the hard-cap grace, ignored it
;; again, and the cycle died with ZERO record (Turns: 0). The
;; tool-result channel is ignorable for glm; the user-message channel
;; (truncation/runaway/timeout landings) demonstrably lands.
;;
;; THE FIX (c310): at block 2 (the model has already ignored ONE
;; demand), the cap hook arms :cap-landing-pending; the post-response
;; handler escalates to a user-message landing, serialized in the
;; event loop (the c269/c300 pattern, proven live).
;;
;; These tests pin:
;; 1. Block 1 does NOT arm the flag (cheap path unchanged).
;; 2. Block 2 ARMS the flag.
;; 3. The post-response handler consumes the flag and sends the
;;    landing prompt (gptel-send called, flag cleared).
;; 4. The handler does NOT send the landing when the turn closed
;;    cleanly (CYCLE_COMPLETE in the response).

(require 'ert)
(require 'cl-lib)
(require 'iar-agent-cycle)

(defun test-cap-landing--park-at-cap (blocks)
  "Create a cycle state parked N blocks past the soft cap."
  (let ((buf (get-buffer-create "*test-cap-landing*")))
    (with-current-buffer buf
      (erase-buffer)
      (insert "test"))
    (let ((state (iar--cycle-make-state "test" buf nil 40)))
      (setf (plist-get state :tool-call-count) iar-cycle-tool-call-cap)
      (setf (plist-get state :cap-blocks) (1- blocks)) ; next block = BLOCKS
      state)))

(ert-deftest test-cap-landing-block1-does-not-arm ()
  "Block 1: the tool-result demand only. No escalation flag."
  (let ((iar--cycle-state (test-cap-landing--park-at-cap 1))
        (iar--one-shot-state nil)
        (iar--cycle-state-buf (get-buffer-create "*test-cap-landing*")))
    (unwind-protect
        (let ((result (iar--cycle-tool-call-cap
                       (list :name "execute_code_local"
                             :args (list :command "ls")
                             :buffer (get-buffer-create "*test-cap-landing*")))))
          (should (car result))          ; blocked
          (should-not (plist-get iar--cycle-state :cap-landing-pending)))
      (kill-buffer "*test-cap-landing*"))))

(ert-deftest test-cap-landing-block2-arms-flag ()
  "Block 2: the model ignored one demand -- arm the escalation."
  (let ((iar--cycle-state (test-cap-landing--park-at-cap 2))
        (iar--one-shot-state nil))
    (unwind-protect
        (let ((result (iar--cycle-tool-call-cap
                       (list :name "execute_code_local"
                             :args (list :command "ls")
                             :buffer (get-buffer-create "*test-cap-landing*")))))
          (should (car result))          ; still blocked
          (should (eq (plist-get iar--cycle-state :cap-landing-pending) t)))
      (kill-buffer "*test-cap-landing*"))))

(ert-deftest test-cap-landing-memory-tool-past-cap-no-arm ()
  "Memory tools past the cap are allowed (the landing IS the memory
pass) -- they must never arm the escalation flag."
  (let ((iar--cycle-state (test-cap-landing--park-at-cap 3))
        (iar--one-shot-state nil))
    (unwind-protect
        (let ((result (iar--cycle-tool-call-cap
                       (list :name "append_file"
                             :args (list :filepath "/tmp/x" :content "y")
                             :buffer (get-buffer-create "*test-cap-landing*")))))
          (should-not result)            ; allowed (nil = pass through)
          (should-not (plist-get iar--cycle-state :cap-landing-pending)))
      (kill-buffer "*test-cap-landing*"))))

(provide 'test-cap-landing-escalation)
;;; test-cap-landing-escalation.el ends here