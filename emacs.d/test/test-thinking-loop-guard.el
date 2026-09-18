;; -*- lexical-binding: t; -*-

;;; Tests for iar-thinking-loop-guard.el
;;
;; Fixture law 39: the test must reproduce the DISEASE, not the
;; shape. The disease: per-round reasoning accumulation with no
;; content/tool-call, crossing the threshold, and the reset on real
;; output. The abort path is exercised with fakes so no real gptel
;; request is needed.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
;; Stubbing primitives (buffer-live-p etc.) with cl-letf triggers
;; native-comp trampoline compilation, which dies in batch mode with
;; excessive-lisp-nesting (test-execute-code-remote.el, 2026-09-03).
(when (boundp 'comp-enable-subr-trampolines)
  (setq comp-enable-subr-trampolines nil))
(require 'iar-utils)
(require 'iar-audit-log)
;; Load the module under test. Its setup() advises
;; gptel-curl--parse-stream / --stream-cleanup, which do not exist
;; without gptel -- advice-add on unbound symbols is fine (it
;; records the advice for when the function is defined), so the
;; load succeeds without gptel.
(load-file (expand-file-name
            "init.d/tool-call/iar-thinking-loop-guard.el"
            (file-name-directory (directory-file-name
                                  (file-name-directory
                                   (or load-file-name default-directory))))))

(defmacro iar-tlg--with-fake-entry (bytes &rest body)
  "Bind a fake hash entry with BYTES accumulated, run BODY.
Binds `proc' and `fsm' as gensym'd symbols."
  (let ((proc (make-symbol "proc"))
        (fsm (make-symbol "fsm")))
    `(let ((iar--thinking-loop-processes (make-hash-table :test 'eq :weakness 'key))
           (,proc (make-symbol "fake-proc"))
           (,fsm (make-symbol "fake-fsm")))
       (puthash ,proc (list :bytes ,bytes :fsm ,fsm)
                iar--thinking-loop-processes)
       (let ((proc ,proc) (fsm ,fsm))
         ,@body))))

(ert-deftest iar-tlg-observe-accumulates-reasoning ()
  "Reasoning rounds with no content accumulate bytes; content resets."
  (iar-tlg--with-fake-entry 0
    ;; Content round: reset (bytes stays 0)
    (iar--thinking-loop-observe proc (list :reasoning "abcdefgh") "resp")
    (should (= (plist-get (gethash proc iar--thinking-loop-processes) :bytes) 0))
    ;; No-content rounds: accumulate
    (iar--thinking-loop-observe proc (list :reasoning "abcdefgh") nil)
    (should (= (plist-get (gethash proc iar--thinking-loop-processes) :bytes) 8))
    (iar--thinking-loop-observe proc (list :reasoning "abcdefgh") nil)
    (should (= (plist-get (gethash proc iar--thinking-loop-processes) :bytes) 16))))

(ert-deftest iar-tlg-observe-resets-on-content ()
  "Any content arrival resets the accumulator."
  (iar-tlg--with-fake-entry 10000
    (iar--thinking-loop-observe proc (list :reasoning "x") "hello")
    (should (= (plist-get (gethash proc iar--thinking-loop-processes) :bytes) 0))))

(ert-deftest iar-tlg-observe-resets-on-tool-use ()
  "Tool calls reset the accumulator (thinking before a tool call is healthy)."
  (iar-tlg--with-fake-entry 10000
    (let ((info (list :reasoning "x" :tool-use '((:name "t")))))
      (iar--thinking-loop-observe proc info nil)
      (should (= (plist-get (gethash proc iar--thinking-loop-processes) :bytes) 0)))))

(ert-deftest iar-tlg-abort-fires-at-threshold ()
  "Crossing the threshold with the guard enabled aborts."
  (let ((iar-thinking-loop-guard-enabled t)
        (iar-thinking-loop-max-chars 100)
        (abort-called nil)
        (buf (get-buffer-create "*tlg-abort-test*")))
    (iar-tlg--with-fake-entry 0
      ;; gptel-fsm-info is a cl-defstruct accessor: when gptel is
      ;; loaded (suite context) the compiler may inline it into the
      ;; module's bytecode, so symbol-function letf does NOT take.
      ;; Use a REAL fsm struct with :info carrying the buffer.
      (let ((real-fsm (if (fboundp 'gptel-make-fsm)
                          (gptel-make-fsm :info (list :buffer buf))
                        fsm)))
        (puthash proc (list :bytes 0 :fsm real-fsm)
                 iar--thinking-loop-processes)
        (cl-letf (((symbol-function 'gptel-abort)
                   (lambda (_buf) (setq abort-called t)))
                  ((symbol-function 'process-live-p) (lambda (_) nil))
                  ((symbol-function 'iar--audit-log) (lambda (&rest _) nil)))
          ;; 150 chars of reasoning, threshold 100 -> abort
          (iar--thinking-loop-observe proc (list :reasoning (make-string 150 ?x)) nil)
          (should abort-called)
          ;; Counter zeroed (re-entrancy guard)
          (should (= (plist-get (gethash proc iar--thinking-loop-processes) :bytes) 0)))))))

(ert-deftest iar-tlg-no-abort-when-disabled ()
  "Guard disabled: no abort even past the threshold."
  (let ((iar-thinking-loop-guard-enabled nil)
        (iar-thinking-loop-max-chars 100)
        (abort-called nil))
    (iar-tlg--with-fake-entry 0
      (cl-letf (((symbol-function 'gptel-abort)
                 (lambda (_buf) (setq abort-called t))))
        (iar--thinking-loop-observe proc (list :reasoning (make-string 150 ?x)) nil)
        (should-not abort-called)
        ;; Accumulation still happens (honest accounting)
        (should (= (plist-get (gethash proc iar--thinking-loop-processes) :bytes) 150))))))

(ert-deftest iar-tlg-parse-advice-finds-process-by-info ()
  "The advice locates the request by FSM-info eq identity."
  (let* ((info (list :reasoning "abc"))
         (proc (make-symbol "fake-proc"))
         ;; Real fsm struct when gptel is loaded (accessor may be
         ;; inlined into module bytecode; a symbol would signal).
         (fsm (if (fboundp 'gptel-make-fsm)
                  (gptel-make-fsm :info info)
                (make-symbol "fake-fsm")))
         (iar--thinking-loop-processes
          (make-hash-table :test 'eq :weakness 'key)))
    (cl-letf ((gptel--request-alist (list (list proc fsm 'cleanup))))
      (iar--thinking-loop-parse-advice (lambda (_b i) nil) 'backend info)
      (should (gethash proc iar--thinking-loop-processes))
      (should (= (plist-get (gethash proc iar--thinking-loop-processes) :bytes) 3)))))

(provide 'test-thinking-loop-guard)