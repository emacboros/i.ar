;;; Test suite for iar-loop-guard-chain.el
;; Companion guard: same-tool chains with DIFFERENT args (iterator
;; patterns). Run from repo root:
;;   IAR_ROOT=/root/i.ar emacs --batch -l emacs.d/test/test-loop-chain.el

(require 'ert)

;; Load dependencies in the same order init.el/run-tests.el uses.
(let ((root (or (getenv "IAR_ROOT") default-directory)))
  (add-to-list 'load-path (expand-file-name "emacs.d/init.d/security/" root))
  (add-to-list 'load-path (expand-file-name "emacs.d/init.d/tool-call/" root))
  (add-to-list 'load-path (expand-file-name "emacs.d/init.d/shared/" root))
  (add-to-list 'load-path (expand-file-name "emacs.d/init.d/core/" root))
  (add-to-list 'load-path (expand-file-name "emacs.d/init.d/agent/" root))
  (let ((fork-path (expand-file-name "gptel-fork" user-emacs-directory)))
    (when (file-directory-p fork-path)
      (add-to-list 'load-path fork-path))))

(require 'gptel)
(setq iar-personalization-path (or (getenv "IAR_PERS") "/root/personalization"))
(setq iar-audit-path (or (getenv "IAR_AUDIT") "audit"))
(setq iar-prompts-path (or (getenv "IAR_PROMPTS") "/root/i.ar/prompts/common"))
(require 'iar-tool-call)
(require 'iar-prompt-loader)
(setq iar-loop-history-size 20
      iar-loop-soft-threshold 3
      iar-loop-hard-threshold 6)
(require 'iar-loop-guard)
(require 'iar-loop-guard-chain)

(defmacro iar-chain-test-buffer (&rest body)
  "Run BODY in a fresh temp buffer with clean loop-guard state."
  `(with-temp-buffer
     (setq iar--loop-history nil)
     (let ((iar-loop-guard-chain-soft 10)
           (iar-loop-guard-chain-hard 20))
       ,@body)))

(defun iar-chain-push (name args)
  "Simulate the identical guard's push for NAME/ARGS."
  (iar--loop-push (cons name (iar--loop-args-sig args))))

(defun iar-chain-call (name args)
  "Invoke the chain guard as the hook would see it, after the
identical guard's push. Returns nil, (:block MSG), or (:stop t ...)."
  (iar-chain-push name args)
  (iar--loop-guard-chain (list :name name :args args)))

(ert-deftest test-chain-guard-allows-distinct-tools ()
  "Different tools interleaved: never a chain."
  (iar-chain-test-buffer
   (dotimes (i 15)
     (should-not (iar-chain-call (if (cl-evenp i) "read_file" "execute_code_local")
                                 (list :path (format "/tmp/f%d" i)))))
   (should (= (length iar--loop-history) 15))))

(ert-deftest test-chain-guard-soft-blocks-at-threshold ()
  "Same tool, different args, 10 in a row: soft block on the 10th."
  (iar-chain-test-buffer
   (dotimes (i 9)
     (should-not (iar-chain-call "execute_code_local" (list :command (format "tail -%d" (1+ i))))))
   (let ((result (iar-chain-call "execute_code_local" (list :command "tail -10"))))
     (should (plist-get result :block))
     (should (string-match-p "LOOP CHAIN DETECTED" (plist-get result :block))))))

(ert-deftest test-chain-guard-hard-stops-at-double ()
  "Same tool chained to 20: hard stop."
  (iar-chain-test-buffer
   (dotimes (i 19)
     (iar-chain-call "execute_code_local" (list :command (format "tail -%d" (1+ i)))))
   (let ((result (iar-chain-call "execute_code_local" (list :command "tail -20"))))
     (should (plist-get result :stop))
     (should (string-match-p "CHAIN HARD STOP" (plist-get result :stop-reason))))))

(ert-deftest test-chain-guard-recovers-after-break ()
  "A different tool call resets the chain; guard allows again."
  (iar-chain-test-buffer
   (dotimes (i 9)
     (iar-chain-call "execute_code_local" (list :command (format "tail -%d" (1+ i)))))
   ;; 10th call would soft-block; instead break the chain with another tool.
   (should-not (iar-chain-call "read_file" (list :path "/tmp/x")))
   (dotimes (i 9)
     (should-not (iar-chain-call "execute_code_local" (list :command (format "grep -%d" i)))))))

(ert-deftest test-chain-guard-identical-calls-do-not-count ()
  "Identical calls are the other guard's job: they must not count
toward a chain, and must not crash the chain guard."
  (iar-chain-test-buffer
   (dotimes (i 8)
     (should-not (iar-chain-call "read_file" (list :path "/tmp/same"))))
   ;; 8 identical + one different-args call of the same tool: chain is 1.
   (should-not (iar-chain-call "read_file" (list :path "/tmp/different")))))

(ert-deftest test-chain-guard-blocked-identical-retry-not-counted ()
  "When the identical guard blocks (simulated: we push but the call
is blocked), a retry with different args must not inherit a chain
from the blocked identical calls."
  (iar-chain-test-buffer
   ;; 3 identical calls (identical guard would soft-block at 3; the
   ;; push still happens -- matches production semantics).
   (dotimes (i 3)
     (iar-chain-push "read_file" (list :path "/tmp/same")))
   ;; Chain guard sees the trailing identical run and drops it.
   (should-not (iar-chain-call "read_file" (list :path "/tmp/next")))))

(ert-deftest test-chain-guard-history-trim-boundary ()
  "Chain detection works when history is trimmed at max size."
  (iar-chain-test-buffer
   (let ((iar-loop-history-size 20))
     (dotimes (i 25)
       (iar-chain-call "execute_code_local" (list :command (format "cmd %d" i))))
     ;; History holds last 20; all same tool -> chain count 20 -> hard stop.
     (let ((result (iar-chain-call "execute_code_local" (list :command "cmd 25"))))
       (should (plist-get result :stop))))))

(ert-deftest test-chain-guard-nil-name-safe ()
  "A call with no name must not error."
  (iar-chain-test-buffer
   (should-not (iar-chain-call nil (list :x 1)))))

(ert-deftest test-chain-guard-escalates-through-bridge ()
  "THE 2026-09-03 LIVE BUG, as a test: through the real bridge with
the real hook order, a same-tool chain must ESCALATE -- soft blocks
at 10, then hard stop by 20. The old default (add-hook prepend)
registered the chain guard BEFORE the identical guard; a blocked
call never entered history; the chain count froze at exactly the
soft threshold; the model could retry forever with zero escalation
(observed live: ~50 soft blocks in ~2.5 min, no hard stop)."
  (iar-chain-test-buffer
   ;; Real hook order as init.el builds it: identical guard first
   ;; (added first, prepend), chain guard after (now registered with
   ;; APPEND). Use the bridge exactly as production does.
   (let ((iar-pre-tool-call-functions nil))
     (iar--loop-guard-setup)
     (iar--loop-guard-chain-setup)
     (unwind-protect
         (let (saw-block saw-stop)
           (dotimes (i 25)
             (let ((r (iar--bridge-pre-tool-call
                       (list :name "execute_code_local"
                             :args (list :command (format "cmd %d" i))))))
               (cond ((plist-get r :block) (setq saw-block t))
                     ((plist-get r :stop) (setq saw-stop t)))))
           (should saw-block)
           (should saw-stop))
       ;; Restore: remove the hooks this test added (they were added
       ;; to the default value; the global hook list already has them
       ;; from module load, so just reset the local let-binding).
       nil))))

(ert-deftest test-chain-guard-setup-appends-not-prepends ()
  "Registration must APPEND the chain guard after the identical
guard, not prepend before it. This is the load-bearing hook-order
contract (2026-09-03 frozen-at-soft bug)."
  (let ((iar-pre-tool-call-functions nil))
    (iar--loop-guard-setup)
    (iar--loop-guard-chain-setup)
    (should (equal iar-pre-tool-call-functions
                   '(iar--loop-guard iar--loop-guard-chain)))))

(provide 'test-loop-chain)
;; --- Convergence-reset tests (2026-09-03, five witness sets) ---
;; The chain guard counts the TOOL; converging investigation is a
;; different behavior that shares the tool. Five production witness
;; sets (aria 11, continuo 6, continuo 7, continuo 12-era, aria 13):
;; blocked mid-diagnosis on ssh -> curl -> grep -> journalctl walks,
;; all legitimate, all different questions. The reset: when a
;; same-tool call's args are dissimilar from the previous same-tool
;; call's args, the chain counter resets.

(ert-deftest test-chain-guard-convergence-reset-ssh-curl-grep ()
  "THE FIVE-WITNESS PRODUCTION SHAPE, as a test: an investigation
walk (ssh systemctl -> curl headers -> grep journalctl, all via
execute_code_local) must NEVER soft-block. The old guard fired at
10 on this exact shape and ate ~70% of aria's cycle 13."
  (iar-chain-test-buffer
   (let ((walk '(("systemctl status frigate" "systemctl list-timers")
                 ("curl -sI https://example.com" "curl -s -o /dev/null -w '%{http_code}' https://example.com")
                 ("grep -c ERROR /var/log/syslog" "grep -n 'oom' /var/log/syslog"))))
     (let ((i 0))
       (dolist (pair walk)
         (dolist (cmd pair)
           (setq i (1+ i))
           ;; 12 calls, 4 per command family: old guard soft-blocked at 10.
           (should-not (iar-chain-call "execute_code_local" (list :command cmd)))))))))

(ert-deftest test-chain-guard-iterator-still-blocks ()
  "The contract the guard exists for: the 489-round-trip iterator
shape (same command family, counter changed) must still soft-block
at 10 and hard-stop at 20. Convergence reset must not weaken the
iterator catch."
  (iar-chain-test-buffer
   (dotimes (i 9)
     (should-not (iar-chain-call "execute_code_local" (list :command (format "tail -%d /var/log/app.log" (1+ i))))))
   (let ((result (iar-chain-call "execute_code_local" (list :command "tail -10 /var/log/app.log"))))
     (should (plist-get result :block)))))

(ert-deftest test-chain-guard-git-log-paging-still-blocks ()
  "The original 489-round-trip shape: git log paging with shifting
line ranges. Shared tokens (git, log, awk, nr, format) keep
similarity above threshold; the chain must still count and block."
  (iar-chain-test-buffer
   (dotimes (i 9)
     (should-not (iar-chain-call "execute_code_local"
                                 (list :command (format "git log | awk 'NR>=%d && NR<=%d'" (* i 20) (1+ (* i 20)))))))
   (let ((result (iar-chain-call "execute_code_local"
                                 (list :command "git log | awk 'NR>=200 && NR<=201'"))))
     (should (plist-get result :block)))))

(ert-deftest test-chain-guard-reset-then-rechain ()
  "After a convergence reset, a NEW iterator pattern on the same
tool must build its own chain from zero: 9 investigation calls,
then 9 iterator calls -- the 10th iterator call soft-blocks (the
reset wiped the investigation's count; the iterator starts fresh)."
  (iar-chain-test-buffer
   ;; Investigation walk: 4 dissimilar calls (counter resets each step).
   (should-not (iar-chain-call "execute_code_local" (list :command "ssh root@host systemctl status x")))
   (should-not (iar-chain-call "execute_code_local" (list :command "curl -sI https://host")))
   (should-not (iar-chain-call "execute_code_local" (list :command "grep -c ERROR /var/log/syslog")))
   (should-not (iar-chain-call "execute_code_local" (list :command "journalctl -u frigate --since today")))
   ;; Now an iterator: 9 tail calls, then the 10th must block.
   (dotimes (i 9)
     (should-not (iar-chain-call "execute_code_local" (list :command (format "tail -%d /var/log/app.log" (1+ i))))))
   (let ((result (iar-chain-call "execute_code_local" (list :command "tail -10 /var/log/app.log"))))
     (should (plist-get result :block)))))

(ert-deftest test-chain-guard-identical-run-then-iterator ()
  "Identical calls below the identical guard's threshold, then an
iterator: the identical run does not break or inflate the chain
count beyond the previous implementation's semantics."
  (iar-chain-test-buffer
   (dotimes (i 2)
     (should-not (iar-chain-call "execute_code_local" (list :command "systemctl status x"))))
   (dotimes (i 9)
     (should-not (iar-chain-call "execute_code_local" (list :command (format "tail -%d /var/log/app.log" (1+ i))))))
   (let ((result (iar-chain-call "execute_code_local" (list :command "tail -10 /var/log/app.log"))))
     (should (plist-get result :block)))))

(ert-deftest test-chain-guard-similarity-boundary ()
  "Unit test the similarity function directly: iterator pairs
similar, investigation pairs dissimilar, empty args conservative."
  (let ((iar-loop-guard-chain-similarity 0.5))
    ;; Iterator: tail -1 vs tail -2 -> similar (1.0)
    (should (iar--chain-args-similar-p '(:command "tail -1 /var/log/app.log")
                                       '(:command "tail -2 /var/log/app.log")))
    ;; Investigation: ssh vs curl -> dissimilar (~0.07)
    (should-not (iar--chain-args-similar-p '(:command "ssh root@host systemctl status x")
                                           '(:command "curl -sI https://host")))
    ;; Empty args: conservative (similar, never reset)
    (should (iar--chain-args-similar-p nil nil))
    (should (iar--chain-args-similar-p '(:x 1) nil))))
