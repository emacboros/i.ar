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

;;; c231 HANDLER-RETURN-IS-CONTRACT fixtures -- the DISEASE, not the
;;; shape. The disease: the guard advice's demote path returned nil;
;;; the caller (gptel-curl--stream-filter ~3129) runs string-blank-p
;;; on the return value and dies on nil (continuo 13:48Z exit 255).
;;; The contract: a demoted parse returns "" -- a string the caller
;;; already handles -- never nil.

(ert-deftest iar-tlg-parse-advice-demoted-error-returns-empty-string ()
  "A signal from orig-fn is demoted to \"\", never nil (the c231 fix)."
  (let ((called nil))
    (cl-letf (((symbol-function 'orig-signal)
               (lambda (_b _i) (error "degenerate chunk"))))
      (let ((result (iar--thinking-loop-parse-advice
                     (lambda (_b _i) (error "degenerate chunk")) 'backend nil)))
        (should (stringp result))
        (should (string-empty-p result))))))

(ert-deftest iar-tlg-parse-advice-success-passthrough-shape ()
  "A successful parse returns the original's value unchanged (no
shape change on the happy path -- the contract is about the error
path only)."
  (let ((result (iar--thinking-loop-parse-advice
                 (lambda (_b _i) "hello") 'backend nil)))
    (should (equal result "hello"))))

(ert-deftest iar-tlg-parse-advice-demote-never-signals ()
  "The advice itself never signals, even when orig-fn errors and the
observer path also has no matching request (the never-signals law).
Returns \"\" (truthy-but-blank) -- asserted via no-signal + stringp."
  (let ((result (condition-case err
                    (iar--thinking-loop-parse-advice
                     (lambda (_b _i) (error "boom")) 'backend nil)
                  (error (list 'signalled (cdr err))))))
    (should (stringp result))
    (should (string-empty-p result))))

(provide 'test-thinking-loop-guard)
;;; Per-model threshold (aria c85, 2026-09-19): the uniform 16000 cap
;;; was falsified -- glm's legit census synthesis exceeds 16k (c84
;;; died exit 1 on 3 legit strikes). First prefix match wins; no
;;; match falls back to the uniform threshold.

(ert-deftest iar-tlg-per-model-threshold-overrides-uniform ()
  "A model-prefix match replaces the uniform threshold."
  (let ((iar-thinking-loop-guard-enabled t)
        (iar-thinking-loop-max-chars 100)
        (iar-thinking-loop-max-chars-per-model
         '(("glm-5.3-flash" . 200)))
        (abort-called nil))
    (iar-tlg--with-fake-entry 0
      ;; Real fsm: gptel is loaded in the suite and the abort path
      ;; calls gptel-fsm-info, which type-checks (see the threshold
      ;; test above for the full story).
      (let ((real-fsm (if (fboundp 'gptel-make-fsm)
                          (gptel-make-fsm
                           :info (list :buffer
                                       (get-buffer-create
                                        "*tlg-abort-test*")))
                        fsm)))
        (puthash proc (list :bytes 0 :fsm real-fsm)
                 iar--thinking-loop-processes))
      (cl-letf (((symbol-function 'gptel-abort)
                 (lambda (_buf) (setq abort-called t)))
                ((symbol-function 'process-live-p) (lambda (_) nil))
                ((symbol-function 'iar--audit-log) (lambda (&rest _) nil)))
        ;; 150 chars: over the uniform 100 but under glm's 200 -> no abort
        (iar--thinking-loop-observe
         proc (list :reasoning (make-string 150 ?x) :model "glm-5.3-flash") nil)
        (should-not abort-called)
        ;; +250 chars: 150+250=400 accumulated > glm's 200 -> abort
        (iar--thinking-loop-observe
         proc (list :reasoning (make-string 250 ?x) :model "glm-5.3-flash") nil)
        (should abort-called)))))

(ert-deftest iar-tlg-per-model-threshold-first-match-wins ()
  "The first matching prefix in the alist wins."
  (let ((iar-thinking-loop-guard-enabled t)
        (iar-thinking-loop-max-chars 100)
        (iar-thinking-loop-max-chars-per-model
         '(("glm-5.3" . 500) ("glm-5.3-flash" . 200)))
        (abort-called nil))
    (iar-tlg--with-fake-entry 0
      ;; Real fsm: gptel is loaded in the suite and the abort path
      ;; calls gptel-fsm-info, which type-checks (see the threshold
      ;; test above for the full story).
      (let ((real-fsm (if (fboundp 'gptel-make-fsm)
                          (gptel-make-fsm
                           :info (list :buffer
                                       (get-buffer-create
                                        "*tlg-abort-test*")))
                        fsm)))
        (puthash proc (list :bytes 0 :fsm real-fsm)
                 iar--thinking-loop-processes))
      (cl-letf (((symbol-function 'gptel-abort)
                 (lambda (_buf) (setq abort-called t)))
                ((symbol-function 'process-live-p) (lambda (_) nil))
                ((symbol-function 'iar--audit-log) (lambda (&rest _) nil)))
        ;; 250 chars: over glm-5.3-flash's 200 (second entry) but the
        ;; first matching prefix glm-5.3 -> 500 wins -> no abort
        (iar--thinking-loop-observe
         proc (list :reasoning (make-string 250 ?x) :model "glm-5.3-flash") nil)
        (should-not abort-called)
        ;; +600 chars: 250+600=850 accumulated > winning 500 -> abort
        (iar--thinking-loop-observe
         proc (list :reasoning (make-string 600 ?x) :model "glm-5.3-flash") nil)
        (should abort-called)))))

(ert-deftest iar-tlg-per-model-threshold-falls-back-to-uniform ()
  "No prefix match: the uniform threshold applies."
  (let ((iar-thinking-loop-guard-enabled t)
        (iar-thinking-loop-max-chars 100)
        (iar-thinking-loop-max-chars-per-model
         '(("nemotron-3-super" . 16000)))
        (abort-called nil))
    (iar-tlg--with-fake-entry 0
      ;; Real fsm: gptel is loaded in the suite and the abort path
      ;; calls gptel-fsm-info, which type-checks (see the threshold
      ;; test above for the full story).
      (let ((real-fsm (if (fboundp 'gptel-make-fsm)
                          (gptel-make-fsm
                           :info (list :buffer
                                       (get-buffer-create
                                        "*tlg-abort-test*")))
                        fsm)))
        (puthash proc (list :bytes 0 :fsm real-fsm)
                 iar--thinking-loop-processes))
      (cl-letf (((symbol-function 'gptel-abort)
                 (lambda (_buf) (setq abort-called t)))
                ((symbol-function 'process-live-p) (lambda (_) nil))
                ((symbol-function 'iar--audit-log) (lambda (&rest _) nil)))
        ;; Unknown model, 150 chars: uniform 100 applies -> abort
        (iar--thinking-loop-observe
         proc (list :reasoning (make-string 150 ?x) :model "deepseek-v4.1") nil)
        (should abort-called)))))

(ert-deftest iar-tlg-per-model-threshold-nil-model-uses-uniform ()
  "Missing/non-string :model in info: uniform threshold, no error."
  (let ((iar-thinking-loop-guard-enabled t)
        (iar-thinking-loop-max-chars 100)
        (iar-thinking-loop-max-chars-per-model
         '(("glm-5.3-flash" . 32000)))
        (abort-called nil))
    (iar-tlg--with-fake-entry 0
      ;; Real fsm: gptel is loaded in the suite and the abort path
      ;; calls gptel-fsm-info, which type-checks (see the threshold
      ;; test above for the full story).
      (let ((real-fsm (if (fboundp 'gptel-make-fsm)
                          (gptel-make-fsm
                           :info (list :buffer
                                       (get-buffer-create
                                        "*tlg-abort-test*")))
                        fsm)))
        (puthash proc (list :bytes 0 :fsm real-fsm)
                 iar--thinking-loop-processes))
      (cl-letf (((symbol-function 'gptel-abort)
                 (lambda (_buf) (setq abort-called t)))
                ((symbol-function 'process-live-p) (lambda (_) nil))
                ((symbol-function 'iar--audit-log) (lambda (&rest _) nil)))
        ;; No :model key at all -> uniform 100 -> abort at 150
        (iar--thinking-loop-observe
         proc (list :reasoning (make-string 150 ?x)) nil)
        (should abort-called)))))

;;; c89 symbol-model fixtures -- the DISEASE, not the shape (c40 law).
;;; Production passes :model as an intern'd SYMBOL (configs/gptel.el
;;; interns the model name). The a5d21f0 tests passed the model as a
;;; STRING, so the suite was green while production silently fell
;;; back to the uniform 16000 all night (c88 root cause). These tests
;;; pass the model as a SYMBOL, exactly as production does.

(ert-deftest iar-tlg-per-model-symbol-model-resolves-override ()
  "A symbol model name (production shape) resolves the per-model alist."
  (let ((iar-thinking-loop-guard-enabled t)
        (iar-thinking-loop-max-chars 100)
        (iar-thinking-loop-max-chars-per-model
         '(("glm-5.3-flash" . 200)))
        (abort-called nil))
    (iar-tlg--with-fake-entry 0
      (let ((real-fsm (if (fboundp 'gptel-make-fsm)
                          (gptel-make-fsm
                           :info (list :buffer
                                       (get-buffer-create
                                        "*tlg-abort-test*")))
                        fsm)))
        (puthash proc (list :bytes 0 :fsm real-fsm)
                 iar--thinking-loop-processes))
      (cl-letf (((symbol-function 'gptel-abort)
                 (lambda (_buf) (setq abort-called t)))
                ((symbol-function 'process-live-p) (lambda (_) nil))
                ((symbol-function 'iar--audit-log) (lambda (&rest _) nil)))
        ;; 150 chars, SYMBOL model: over uniform 100, under glm 200 ->
        ;; NO abort (the a5d21f0-era code aborted here: stringp failed
        ;; on the symbol, alist skipped, uniform 100 applied).
        (iar--thinking-loop-observe
         proc (list :reasoning (make-string 150 ?x) :model 'glm-5.3-flash)
         nil)
        (should-not abort-called)
        ;; +250 chars: 400 accumulated > glm's 200 -> abort.
        (iar--thinking-loop-observe
         proc (list :reasoning (make-string 250 ?x) :model 'glm-5.3-flash)
         nil)
        (should abort-called)))))

(ert-deftest iar-tlg-per-model-symbol-model-abort-reports-resolved-threshold ()
  "The abort witness line names the RESOLVED per-model threshold for
a symbol model -- the runtime witness (deployed != active law)."
  (let ((iar-thinking-loop-guard-enabled t)
        (iar-thinking-loop-max-chars 100)
        (iar-thinking-loop-max-chars-per-model
         '(("glm-5.3-flash" . 200)))
        (logged nil))
    (iar-tlg--with-fake-entry 0
      (let ((real-fsm (if (fboundp 'gptel-make-fsm)
                          (gptel-make-fsm
                           :info (list :buffer
                                       (get-buffer-create
                                        "*tlg-abort-test*")))
                        fsm)))
        (puthash proc (list :bytes 0 :fsm real-fsm)
                 iar--thinking-loop-processes))
      (cl-letf (((symbol-function 'gptel-abort) (lambda (_buf) nil))
                ((symbol-function 'process-live-p) (lambda (_) nil))
                ((symbol-function 'iar--audit-log)
                 (lambda (_tag msg) (setq logged msg))))
        (iar--thinking-loop-observe
         proc (list :reasoning (make-string 250 ?x) :model 'glm-5.3-flash)
         nil)
        (should logged)
        (should (string-match-p ">200 chars" logged))
        (should (string-match-p "model=glm-5.3-flash" logged))))))
