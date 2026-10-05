;;; test-chain-share-window.el --- 0117 ask 2: rolling-window same-tool share -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'iar-loop-guard-chain)

(defun iar-share-call (name args)
  "Invoke the chain guard as the hook would, after the identical
guard's push. Returns nil, (:block MSG), or (:stop t ...)."
  (iar--loop-push (cons name (iar--loop-args-sig args)))
  (iar--loop-guard-chain (list :name name :args args)))

(ert-deftest test-share-window-interleaved-enumeration-fires ()
  "c521 shape: same tool 90% of a 20-call window with read_file
interleaves -- the consecutive chain never reaches 20, the share
guard fires."
  (with-temp-buffer
    (setq iar--loop-history nil)
    (let ((iar-loop-guard-chain-soft 10)
          (iar-loop-guard-chain-hard 20)
          (iar-loop-guard-chain-share-window 20)
          (iar-loop-guard-chain-share-soft 0.6)
          (iar-loop-guard-chain-share-min 20)
          (iar-loop-guard-chain-share-hard 0.85))
      ;; TRUE interleaving (the c521 shape): 18 exec + 2 reads at
      ;; positions 9 and 18 -- consecutive chain max = 9 (under the
      ;; 10 soft), so only the share guard can catch this.
      (dotimes (i 18)
        (should-not (iar-share-call "execute_code_local"
                                    (list :command (format "grep journal %d" i))))
        (when (or (= i 8) (= i 17))
          (should-not (iar-share-call "read_file" (list :path (format "/tmp/f%d" i))))))
      ;; window now: 18 exec + 2 read = 20 calls, share 0.9 >= hard.
      ;; The next exec call fires the share guard.
      (let ((result (iar-share-call "execute_code_local"
                                    (list :command "grep journal again"))))
        (should (or (plist-get result :block) (plist-get result :stop)))))))

(ert-deftest test-share-window-short-iterator-silent ()
  "Short legitimate iterators (tail paging x9) never reach the
window minimum: share guard silent, consecutive guard's job."
  (with-temp-buffer
    (setq iar--loop-history nil)
    (let ((iar-loop-guard-chain-share-min 20))
      (dotimes (i 9)
        (should-not (iar-share-call "execute_code_local"
                                    (list :command (format "tail -%d" (1+ i)))))))))

(ert-deftest test-share-window-recovery-pattern-silent ()
  "The ratified recovery shape (9 + tool-switch + 9 = 19 calls)
stays under the full-window minimum: no share fire."
  (with-temp-buffer
    (setq iar--loop-history nil)
    (let ((iar-loop-guard-chain-share-min 20)
          (iar-loop-guard-chain-share-window 20))
      (dotimes (i 9)
        (iar-share-call "execute_code_local" (list :command (format "tail -%d" (1+ i)))))
      (should-not (iar-share-call "read_file" (list :path "/tmp/x")))
      (dotimes (i 9)
        (should-not (iar-share-call "execute_code_local"
                                    (list :command (format "grep -%d" i))))))))

(ert-deftest test-share-window-memory-tools-exempt ()
  "Memory tools never trigger the share guard even at 100% share."
  (with-temp-buffer
    (setq iar--loop-history nil)
    (let ((iar-loop-guard-chain-share-min 20)
          (iar-loop-guard-chain-share-window 20))
      ;; interleave with reads so the consecutive chain guard stays
      ;; quiet; the share window is 100% append_file but memory
      ;; tools are exempt from the share guard.
      (dotimes (i 25)
        (should-not (iar-share-call "append_file"
                                    (list :filepath (format "/tmp/f%d" i) :content "x")))
        (should-not (iar-share-call "read_file" (list :path (format "/tmp/r%d" i))))))))

(provide 'test-chain-share-window)
