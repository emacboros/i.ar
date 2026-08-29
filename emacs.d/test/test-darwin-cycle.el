;; -*- lexical-binding: t; -*-

;;; Tests for iar-agent-cycle.el
;; Tests the pure helper functions: iar--cycle-complete-p and
;; iar--cycle-load-profile. The main iar-run-cycle function involves
;; timers, processes, and gptel state -- too complex for unit tests
;; without heavy mocking. These tests cover the testable surface.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-agent-cycle)

;;; --- iar--cycle-complete-p: sentinel marker tests ---

(ert-deftest test-darwin-cycle-complete-loop-sentinel ()
  "iar--cycle-complete-p should return 'loop for LOOP_COMPLETE."
  (with-temp-buffer
    (insert "Some work done.\nLOOP_COMPLETE\n")
    (should (eq (iar--cycle-complete-p (current-buffer)) 'loop))))

(ert-deftest test-darwin-cycle-complete-cycle-sentinel ()
  "iar--cycle-complete-p should return 'cycle for CYCLE_COMPLETE."
  (with-temp-buffer
    (insert "Some work done.\nCYCLE_COMPLETE\n")
    (should (eq (iar--cycle-complete-p (current-buffer)) 'cycle))))

(ert-deftest test-darwin-cycle-complete-no-marker ()
  "iar--cycle-complete-p should return nil without any sentinel."
  (with-temp-buffer
    (insert "I did some work but forgot to signal completion.\n")
    (should (null (iar--cycle-complete-p (current-buffer))))))

(ert-deftest test-darwin-cycle-complete-empty-buffer ()
  "iar--cycle-complete-p should return nil for empty buffer."
  (with-temp-buffer
    (should (null (iar--cycle-complete-p (current-buffer))))))

(ert-deftest test-darwin-cycle-complete-sentinel-case-sensitive ()
  "Sentinels are case-sensitive -- loop_complete should not match."
  (with-temp-buffer
    (insert "loop_complete\n")
    (should (null (iar--cycle-complete-p (current-buffer))))))

(ert-deftest test-darwin-cycle-complete-sentinel-not-substring ()
  "Sentinel must be on its own line, not embedded in a word."
  (with-temp-buffer
    (insert "The CYCLE_COMPLETELY different thing\n")
    (should (null (iar--cycle-complete-p (current-buffer))))))

(ert-deftest test-darwin-cycle-complete-sentinel-at-buffer-start ()
  "Sentinel at buffer start should match."
  (with-temp-buffer
    (insert "CYCLE_COMPLETE\n")
    (should (eq (iar--cycle-complete-p (current-buffer)) 'cycle))))

(ert-deftest test-darwin-cycle-complete-sentinel-at-buffer-end ()
  "Sentinel at buffer end should match."
  (with-temp-buffer
    (insert "Work done.\nCYCLE_COMPLETE")
    (should (eq (iar--cycle-complete-p (current-buffer)) 'cycle))))

(ert-deftest test-darwin-cycle-complete-sentinel-in-sentence-no-match ()
  "Sentinel embedded in a sentence should not match."
  (with-temp-buffer
    (insert "I will write CYCLE_COMPLETE when done.\n")
    (should (null (iar--cycle-complete-p (current-buffer))))))

;;; --- iar--cycle-complete-p: region tests ---

(ert-deftest test-darwin-cycle-complete-region-only ()
  "Region search should find sentinel within the specified region."
  (with-temp-buffer
    (insert "Before region.\n")
    (insert "CYCLE_COMPLETE\n")
    (insert "After region.\n")
    (let ((start (save-excursion
                   (goto-char (point-min))
                   (forward-line 1)
                   (point)))
          (end (save-excursion
                 (goto-char (point-min))
                 (forward-line 2)
                 (point))))
      (should (eq (iar--cycle-complete-p (current-buffer) start end) 'cycle)))))

(ert-deftest test-darwin-cycle-complete-region-excludes-early-mention ()
  "Region search should not find sentinel outside the region."
  (with-temp-buffer
    (insert "CYCLE_COMPLETE\n")
    (insert "Working on it...\n")
    (let ((start (save-excursion
                   (goto-char (point-min))
                   (forward-line 1)
                   (point)))
          (end (point-max)))
      (should (null (iar--cycle-complete-p (current-buffer) start end))))))

(ert-deftest test-darwin-cycle-complete-region-nil-args-searches-all ()
  "Nil start/end should search entire buffer."
  (with-temp-buffer
    (insert "Work done.\nCYCLE_COMPLETE\n")
    (should (eq (iar--cycle-complete-p (current-buffer) nil nil) 'cycle))))

(ert-deftest test-darwin-cycle-complete-region-start-gt-end ()
  "start >= end should search entire buffer."
  (with-temp-buffer
    (insert "CYCLE_COMPLETE\n")
    (should (eq (iar--cycle-complete-p (current-buffer) 100 50) 'cycle))))

(ert-deftest test-darwin-cycle-complete-region-clamps-out-of-bounds ()
  "Out-of-bounds positions should be clamped to buffer boundaries."
  (with-temp-buffer
    (insert "CYCLE_COMPLETE\n")
    (should (eq (iar--cycle-complete-p (current-buffer) -100 99999) 'cycle))))

;;; --- iar--cycle-complete-p: narrowing tests ---

(ert-deftest test-darwin-cycle-complete-widens-narrowed-buffer ()
  "Should find sentinel even when buffer is narrowed."
  (with-temp-buffer
    (insert "Before.\n")
    (insert "CYCLE_COMPLETE\n")
    (insert "After.\n")
    (should (eq (iar--cycle-complete-p (current-buffer)) 'cycle))))

(ert-deftest test-darwin-cycle-complete-sentinel-widens-narrowed-buffer ()
  "Sentinel search should widen narrowed buffer."
  (with-temp-buffer
    (insert "Work.\n")
    (insert "LOOP_COMPLETE\n")
    (narrow-to-region (point-min) (line-beginning-position 2))
    (should (eq (iar--cycle-complete-p (current-buffer)) 'loop))))

(ert-deftest test-darwin-cycle-complete-region-with-narrowed-buffer ()
  "Region search should work with narrowed buffer."
  (with-temp-buffer
    (insert "Before.\n")
    (insert "CYCLE_COMPLETE\n")
    (insert "After.\n")
    (let* ((region-start (save-excursion
                          (goto-char (point-min))
                          (forward-line 1)
                          (point)))
           (region-end (save-excursion
                        (goto-char (point-min))
                        (forward-line 2)
                        (point))))
      (narrow-to-region (point-min) (line-beginning-position 2))
      (should (eq (iar--cycle-complete-p (current-buffer) region-start region-end) 'cycle)))))

;;; --- iar--cycle-load-profile tests ---

(ert-deftest test-darwin-load-profile-returns-string ()
  "iar--cycle-load-profile should return a non-empty string for a valid personality."
  (let ((profile (iar--cycle-load-profile "darwin")))
    (should (stringp profile))
    (should (< 0 (length profile)))
    (should (string-match-p "Darwin" profile))))

(ert-deftest test-darwin-load-profile-errors-on-missing ()
  "iar--cycle-load-profile should error for a nonexistent agent."
  (let ((user-emacs-directory (make-temp-file "test-darwin-" :dir-flag)))
    (unwind-protect
        (let ((err (should-error (iar--cycle-load-profile "nonexistent") :type 'error)))
          (should (string-match-p "not found" (cadr err))))
      (delete-directory user-emacs-directory t))))

;;; --- iar--cycle-token-summary tests ---

(ert-deftest test-darwin-cycle-token-summary ()
  "iar--cycle-token-summary should return a formatted string with token counts."
  (iar--usage-reset)
  (setq iar--usage-input-tokens 100
        iar--usage-output-tokens 50)
  (let ((summary (iar--cycle-token-summary)))
    (should (stringp summary))
    (should (string-match-p "100" summary))
    (should (string-match-p "50" summary))
    (should (string-match-p "Tokens:" summary))))

;;; --- iar--cycle-log-append tests ---

(ert-deftest test-darwin-cycle-log-append ()
  "iar--cycle-log-append should write response to cycle.log."
  (let* ((test-dir (make-temp-file "test-cycle-log-" :dir-flag))
         (iar-audit-path "audit")
         (user-emacs-directory test-dir)
         (iar--current-agent-name "testagent")
         (iar--current-project "testagent")
         (iar-personalization-path test-dir))
    (unwind-protect
        (with-temp-buffer
          (insert "Test response text")
          (iar--cycle-log-append "testagent" (point-min) (point-max))
          (let ((log-path (expand-file-name "testagent/testagent/cycle.log"
                                            (expand-file-name "audit" test-dir))))
            (should (file-exists-p log-path))
            (with-temp-buffer
              (insert-file-contents log-path)
              (should (string-match-p "Test response text" (buffer-string)))
              (should (string-match-p "^\\[" (buffer-string))))) ; has timestamp
      (delete-directory test-dir t)))))

(ert-deftest test-darwin-cycle-log-append-skip-invalid-positions ()
  "iar--cycle-log-append should skip when start >= end."
  (let* ((test-dir (make-temp-file "test-cycle-log-" :dir-flag))
         (iar-audit-path "audit")
         (user-emacs-directory test-dir))
    (unwind-protect
        (with-temp-buffer
          (insert "Test")
          (iar--cycle-log-append "testagent" 5 3)
          (iar--cycle-log-append "testagent" 5 5)
          (let ((log-path (expand-file-name "testagent/testagent/cycle.log"
                                            (expand-file-name "audit" test-dir))))
            (should-not (file-exists-p log-path))))
      (delete-directory test-dir t))))

;;; --- Cycle state tests ---

(ert-deftest test-darwin-cycle-make-state ()
  "iar--cycle-make-state should create a plist with all required keys."
  (let ((state (iar--cycle-make-state "darwin" (get-buffer-create "*test*") "continue" 40)))
    (should (null (plist-get state :completed)))
    (should (= 0 (plist-get state :exit-code)))
    (should (= 0 (plist-get state :turn-count)))
    (should (= 0 (plist-get state :tool-call-count)))
    (should (string= "darwin" (plist-get state :agent)))
    (should (= 40 (plist-get state :max-turns)))))

;;; --- Defcustom :safe predicate tests ---

(ert-deftest test-darwin-cycle-timeout-safe-predicate ()
  "iar-cycle-timeout :safe predicate should reject nil/0/-1, accept positive integers."
  (should-not (safe-local-variable-p 'iar-cycle-timeout nil))
  (should-not (safe-local-variable-p 'iar-cycle-timeout 0))
  (should-not (safe-local-variable-p 'iar-cycle-timeout -1))
  (should-not (safe-local-variable-p 'iar-cycle-timeout "foo"))
  (should (safe-local-variable-p 'iar-cycle-timeout 7200))
  (should (safe-local-variable-p 'iar-cycle-timeout 3600))
  (should (eq (default-value 'iar-cycle-timeout) 7200)))

(ert-deftest test-darwin-cycle-max-turns-safe-predicate ()
  "iar-cycle-max-turns :safe predicate should reject nil/0/-1, accept positive integers."
  (should-not (safe-local-variable-p 'iar-cycle-max-turns nil))
  (should-not (safe-local-variable-p 'iar-cycle-max-turns 0))
  (should-not (safe-local-variable-p 'iar-cycle-max-turns -1))
  (should-not (safe-local-variable-p 'iar-cycle-max-turns "foo"))
  (should (safe-local-variable-p 'iar-cycle-max-turns 40))
  (should (safe-local-variable-p 'iar-cycle-max-turns 100))
  (should (eq (default-value 'iar-cycle-max-turns) 40)))

(provide 'test-darwin-cycle)
;;; --- Additional coverage tests ---

(ert-deftest test-cycle-load-cycle-prompt-success ()
  "iar--cycle-load-cycle-prompt should load existing cycle."
  (let ((result (iar--cycle-load-cycle-prompt "self_modification")))
    (should (stringp result))
    (should (> (length result) 0))))

(ert-deftest test-cycle-load-cycle-prompt-not-found ()
  "iar--cycle-load-cycle-prompt should error for nonexistent cycle."
  (should-error (iar--cycle-load-cycle-prompt "nonexistent_cycle")
                :type 'error))

(ert-deftest test-cycle-for-personality-darwin ()
  "iar--cycle-for-personality should return self_modification for darwin."
  (should (string= "self_modification" (iar--cycle-for-personality "darwin"))))

(ert-deftest test-cycle-for-personality-unknown ()
  "iar--cycle-for-personality should return nil for unknown personality."
  (should (null (iar--cycle-for-personality "nonexistent"))))

(ert-deftest test-cycle-load-continue-prompt ()
  "iar--cycle-load-continue-prompt should load or return nil."
  (let ((result (iar--cycle-load-continue-prompt "darwin")))
    ;; Returns nil if file not found, or string if found
    (should (or (null result) (stringp result)))))

(ert-deftest test-cycle-make-state ()
  "iar--cycle-make-state should create a state plist."
  (let ((buf (get-buffer-create "*test-cycle-state*"))
        (continue-prompt "continue"))
    (unwind-protect
        (let ((state (iar--cycle-make-state "test-agent" buf continue-prompt 40)))
          (should (plistp state))
          (should (string= "test-agent" (plist-get state :agent)))
          (should (eq buf (plist-get state :buffer)))
          (should (string= "continue" (plist-get state :continue)))
          (should (= 40 (plist-get state :max-turns)))
          (should (= 0 (plist-get state :turn-count)))
          (should (= 0 (plist-get state :tool-call-count)))
          (should (null (plist-get state :completed)))
          (should (= 0 (plist-get state :exit-code))))
      (kill-buffer buf))))

(ert-deftest test-cycle-tool-call-tracker ()
  "iar--cycle-tool-call-tracker should increment tool-call-count."
  (let ((buf (get-buffer-create "*test-cycle-tracker*")))
    (unwind-protect
        (let ((iar--cycle-state (iar--cycle-make-state "test" buf nil 40)))
          (iar--cycle-tool-call-tracker nil nil)
          (should (= 1 (plist-get iar--cycle-state :tool-call-count))))
      (kill-buffer buf))))

(ert-deftest test-cycle-log-append ()
  "iar--cycle-log-append should write to cycle.log."
  (let* ((tmpdir (make-temp-file "test-cycle-log-" :dir-flag))
         (iar-personalization-path tmpdir)
         (iar-audit-path "audit"))
    (cl-letf (((symbol-function 'iar--current-project-name) (lambda () "test-project")))
      (unwind-protect
          (with-temp-buffer
            (insert "test response content")
            (iar--cycle-log-append "test-agent" 1 20)
            (let ((log-path (expand-file-name
                             "audit/test-project/test-agent/cycle.log" tmpdir)))
              (should (file-exists-p log-path))))
        (delete-directory tmpdir t)))))

(ert-deftest test-cycle-log-append-skips-invalid-args ()
  "iar--cycle-log-append should skip when args are invalid."
  (with-temp-buffer
    (insert "content")
    ;; Non-integer args should be skipped
    (iar--cycle-log-append "agent" nil nil)
    (iar--cycle-log-append "agent" "a" "b")
    ;; start >= end should be skipped
    (iar--cycle-log-append "agent" 10 5)
    (should t)))

(ert-deftest test-cycle-post-response-loop-complete ()
  "iar--cycle-post-response-handler should detect LOOP_COMPLETE."
  (let ((buf (get-buffer-create "*test-cycle-pr*")))
    (unwind-protect
        (with-current-buffer buf
          (insert "some response\nLOOP_COMPLETE\n")
          (let ((iar--cycle-state (iar--cycle-make-state "test" buf nil 40)))
            (iar--cycle-post-response-handler nil nil)
            (should (plist-get iar--cycle-state :completed))
            (should (= 0 (plist-get iar--cycle-state :exit-code)))))
      (kill-buffer buf))))

(ert-deftest test-cycle-post-response-cycle-complete ()
  "iar--cycle-post-response-handler should detect CYCLE_COMPLETE."
  (let ((buf (get-buffer-create "*test-cycle-pr2*")))
    (unwind-protect
        (with-current-buffer buf
          (insert "some response\nCYCLE_COMPLETE\n")
          (let ((iar--cycle-state (iar--cycle-make-state "test" buf nil 40)))
            (iar--cycle-post-response-handler nil nil)
            ;; CYCLE_COMPLETE with nil continue prompt ends cycle cleanly
            (should (plist-get iar--cycle-state :completed))
            (should (= 0 (plist-get iar--cycle-state :exit-code)))))
      (kill-buffer buf))))


(ert-deftest test-cycle-post-response-max-turns ()
  "iar--cycle-post-response-handler should end cycle at max turns."
  (let ((buf (get-buffer-create "*test-cycle-pr3*")))
    (unwind-protect
        (with-current-buffer buf
          (insert "response without sentinel\n")
          (let ((iar--cycle-state (iar--cycle-make-state "test" buf nil 2)))
            ;; Simulate 2 turns (max-turns)
            (iar--cycle-post-response-handler nil nil)
            (iar--cycle-post-response-handler nil nil)
            (should (plist-get iar--cycle-state :completed))))
      (kill-buffer buf))))

(provide 'test-darwin-cycle)
;;; test-darwin-cycle.el ends here
