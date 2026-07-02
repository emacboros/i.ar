;; -*- lexical-binding: t; -*-

;;; Tests for loop_guard.el
;; Tests the loop guard that detects and breaks repetitive tool call loops.
;; Covers: args signature hashing, recent count, history ring,
;; soft/hard messages, and the main hook function behavior.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)

;;; --- Args signature tests ---

(ert-deftest test-loop-args-sig-returns-string ()
  "my-gptel--loop-args-sig should return a string (md5 hash)."
  (let ((sig (my-gptel--loop-args-sig '(:path "/tmp/foo"))))
    (should (stringp sig))
    ;; md5 produces 32 hex chars
    (should (= (length sig) 32))))

(ert-deftest test-loop-args-sig-stable ()
  "my-gptel--loop-args-sig should produce same hash for same args."
  (let ((sig1 (my-gptel--loop-args-sig '(:path "/tmp/foo" :content "bar")))
        (sig2 (my-gptel--loop-args-sig '(:path "/tmp/foo" :content "bar"))))
    (should (string= sig1 sig2))))

(ert-deftest test-loop-args-sig-different-args-different-hash ()
  "my-gptel--loop-args-sig should produce different hashes for different args."
  (let ((sig1 (my-gptel--loop-args-sig '(:path "/tmp/foo")))
        (sig2 (my-gptel--loop-args-sig '(:path "/tmp/bar"))))
    (should-not (string= sig1 sig2))))

(ert-deftest test-loop-args-sig-nil-args ()
  "my-gptel--loop-args-sig should handle nil args without error."
  (let ((sig (my-gptel--loop-args-sig nil)))
    (should (stringp sig))
    (should (= (length sig) 32))))

;;; --- Count recent tests ---

(ert-deftest test-loop-count-recent-empty-history ()
  "my-gptel--loop-count-recent should return 0 for empty history."
  (with-temp-buffer
    (should (= (my-gptel--loop-count-recent '("foo" . "abc")) 0))))

(ert-deftest test-loop-count-recent-all-matching ()
  "my-gptel--loop-count-recent should count all consecutive matching entries."
  (with-temp-buffer
    (setq-local my-gptel--loop-history
                '(("foo" . "abc") ("foo" . "abc") ("foo" . "abc")))
    (should (= (my-gptel--loop-count-recent '("foo" . "abc")) 3))))

(ert-deftest test-loop-count-recent-stops-at-non-match ()
  "my-gptel--loop-count-recent should stop counting at first non-match."
  (with-temp-buffer
    (setq-local my-gptel--loop-history
                '(("foo" . "abc") ("foo" . "abc") ("bar" . "xyz") ("foo" . "abc")))
    ;; Only counts the 2 consecutive "foo" entries at head
    (should (= (my-gptel--loop-count-recent '("foo" . "abc")) 2))))

(ert-deftest test-loop-count-recent-no-match-at-head ()
  "my-gptel--loop-count-recent should return 0 when head doesn't match."
  (with-temp-buffer
    (setq-local my-gptel--loop-history
                '(("bar" . "xyz") ("foo" . "abc") ("foo" . "abc")))
    (should (= (my-gptel--loop-count-recent '("foo" . "abc")) 0))))

;;; --- Push / history ring tests ---

(ert-deftest test-loop-push-adds-to-front ()
  "my-gptel--loop-push should add entry to front of history."
  (with-temp-buffer
    (setq-local my-gptel--loop-history nil)
    (my-gptel--loop-push '("foo" . "abc"))
    (should (equal my-gptel--loop-history '(("foo" . "abc"))))
    (my-gptel--loop-push '("bar" . "xyz"))
    (should (equal my-gptel--loop-history '(("bar" . "xyz") ("foo" . "abc"))))))

(ert-deftest test-loop-push-trims-to-max-size ()
  "my-gptel--loop-push should trim history to my-gptel-loop-history-size."
  (with-temp-buffer
    (let ((my-gptel-loop-history-size 3))
      (setq-local my-gptel--loop-history nil)
      (dotimes (i 5)
        (my-gptel--loop-push (cons "tool" (number-to-string i))))
      ;; Should only keep the 3 most recent
      (should (= (length my-gptel--loop-history) 3))
      ;; Most recent should be at front
      (should (equal (car my-gptel--loop-history) '("tool" . "4"))))))

;;; --- Message builder tests ---

(ert-deftest test-loop-soft-message-includes-name ()
  "my-gptel--loop-soft-message should include the tool name."
  (let ((msg (my-gptel--loop-soft-message "execute_code_local" 3)))
    (should (string-match-p "execute_code_local" msg))))

(ert-deftest test-loop-soft-message-includes-count ()
  "my-gptel--loop-soft-message should include the repeat count."
  (let ((msg (my-gptel--loop-soft-message "read_file" 5)))
    (should (string-match-p "5" msg))))

(ert-deftest test-loop-hard-message-includes-name ()
  "my-gptel--loop-hard-message should include the tool name."
  (let ((msg (my-gptel--loop-hard-message "write_file" 6)))
    (should (string-match-p "write_file" msg))))

(ert-deftest test-loop-hard-message-includes-count ()
  "my-gptel--loop-hard-message should include the repeat count."
  (let ((msg (my-gptel--loop-hard-message "delegate" 7)))
    (should (string-match-p "7" msg))))

;;; --- Main hook function tests ---

(ert-deftest test-loop-guard-returns-nil-first-call ()
  "my-gptel--loop-guard should return nil for first call (no loop)."
  (with-temp-buffer
    (setq-local my-gptel--loop-history nil)
    (let ((result (my-gptel--loop-guard
                   (list :name "read_file"
                         :args '(:filepath "/tmp/foo")
                         :buffer (current-buffer)))))
      (should (null result)))))

(ert-deftest test-loop-guard-returns-nil-below-soft-threshold ()
  "my-gptel--loop-guard should return nil when below soft threshold."
  (with-temp-buffer
    (let ((my-gptel-loop-soft-threshold 3))
      (setq-local my-gptel--loop-history nil)
      ;; First call
      (my-gptel--loop-guard (list :name "read_file"
                                  :args '(:filepath "/tmp/foo")
                                  :buffer (current-buffer)))
      ;; Second call (same args) -- still below threshold of 3
      (let ((result (my-gptel--loop-guard
                     (list :name "read_file"
                           :args '(:filepath "/tmp/foo")
                           :buffer (current-buffer)))))
        ;; total is 2, below soft threshold of 3
        (should (null result))))))

(ert-deftest test-loop-guard-soft-blocks-at-threshold ()
  "my-gptel--loop-guard should return :block when soft threshold is reached."
  (with-temp-buffer
    (let ((my-gptel-loop-soft-threshold 3)
          (my-gptel-loop-hard-threshold 6))
      (setq-local my-gptel--loop-history nil)
      (setq-local my-gptel--loop-block-count 0)
      (let ((info (list :name "read_file"
                        :args '(:filepath "/tmp/foo")
                        :buffer (current-buffer))))
        ;; Push 2 entries to history (simulating 2 prior calls)
        (my-gptel--loop-push (cons "read_file" (my-gptel--loop-args-sig '(:filepath "/tmp/foo"))))
        (my-gptel--loop-push (cons "read_file" (my-gptel--loop-args-sig '(:filepath "/tmp/foo"))))
        ;; Third call -- total = 3, hits soft threshold
        (let ((result (my-gptel--loop-guard info)))
          (should (plist-get result :block))
          (should (stringp (plist-get result :block)))
          ;; Block count should be incremented
          (should (= my-gptel--loop-block-count 1)))))))

(ert-deftest test-loop-guard-hard-stops-at-hard-threshold ()
  "my-gptel--loop-guard should return :stop when hard threshold is reached."
  (with-temp-buffer
    (let ((my-gptel-loop-soft-threshold 3)
          (my-gptel-loop-hard-threshold 6))
      (setq-local my-gptel--loop-history nil)
      (let* ((args '(:filepath "/tmp/foo"))
             (sig (cons "read_file" (my-gptel--loop-args-sig args)))
             (info (list :name "read_file"
                         :args args
                         :buffer (current-buffer))))
        ;; Push 5 entries (simulating 5 prior identical calls)
        (dotimes (_ 5)
          (my-gptel--loop-push sig))
        ;; Sixth call -- total = 6, hits hard threshold
        (let ((result (my-gptel--loop-guard info)))
          (should (plist-get result :stop))
          (should (plist-get result :stop-reason))
          (should (stringp (plist-get result :stop-reason))))))))

(ert-deftest test-loop-guard-resets-on-different-call ()
  "my-gptel--loop-guard should reset block count when a different call is made."
  (with-temp-buffer
    (let ((my-gptel-loop-soft-threshold 3)
          (my-gptel-loop-hard-threshold 6))
      (setq-local my-gptel--loop-history nil)
      (setq-local my-gptel--loop-block-count 2)
      ;; Make a different call
      (let ((result (my-gptel--loop-guard
                     (list :name "write_file"
                           :args '(:filepath "/tmp/bar")
                           :buffer (current-buffer)))))
        (should (null result))
        (should (= my-gptel--loop-block-count 0))))))

(ert-deftest test-loop-guard-block-message-is-informative ()
  "The soft block message should tell the model to stop and reconsider."
  (with-temp-buffer
    (let ((my-gptel-loop-soft-threshold 3)
          (my-gptel-loop-hard-threshold 6))
      (setq-local my-gptel--loop-history nil)
      (let* ((args '(:filepath "/tmp/foo"))
             (sig (cons "read_file" (my-gptel--loop-args-sig args)))
             (info (list :name "read_file"
                         :args args
                         :buffer (current-buffer))))
        (dotimes (_ 2)
          (my-gptel--loop-push sig))
        (let ((result (my-gptel--loop-guard info)))
          (let ((msg (plist-get result :block)))
            (should (string-match-p "LOOP DETECTED" msg))
            (should (string-match-p "read_file" msg))
            (should (string-match-p "DO NOT call" msg))))))))

(ert-deftest test-loop-guard-different-args-no-block ()
  "my-gptel--loop-guard should not block when same tool called with different args."
  (with-temp-buffer
    (let ((my-gptel-loop-soft-threshold 3))
      (setq-local my-gptel--loop-history nil)
      ;; Push several calls with different args
      (my-gptel--loop-guard (list :name "read_file"
                                  :args '(:filepath "/tmp/a")
                                  :buffer (current-buffer)))
      (my-gptel--loop-guard (list :name "read_file"
                                  :args '(:filepath "/tmp/b")
                                  :buffer (current-buffer)))
      (my-gptel--loop-guard (list :name "read_file"
                                  :args '(:filepath "/tmp/c")
                                  :buffer (current-buffer)))
      ;; None should have been blocked -- each call has different args
      (should (= my-gptel--loop-block-count 0)))))

(provide 'test-loop)