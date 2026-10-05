;;; test-invisible-burn-witness.el --- 0117 ask 3: output-token witness -*- lexical-binding: t; -*-

(require 'ert)
(require 'iar-request-log)

(ert-deftest test-invisible-burn-fires-on-c521-shape ()
  "stop=length at the ceiling with zero tools = witnessed."
  (let ((iar--reqlog-witness-ceiling 29500))
    (should (iar--reqlog-invisible-burn-p "length" 32768 nil))
    (should (iar--reqlog-invisible-burn-p "length" 32768 nil))))

(ert-deftest test-invisible-burn-silent-on-tools ()
  "stop=length at the ceiling WITH tool calls = normal truncation,
not invisible burn (the truncated-output guard owns that shape)."
  (let ((iar--reqlog-witness-ceiling 29500))
    (should-not (iar--reqlog-invisible-burn-p
                 "length" 32768 (list (list :function "x"))))))

(ert-deftest test-invisible-burn-silent-under-ceiling ()
  "Below the ceiling: not witnessed (normal long output)."
  (let ((iar--reqlog-witness-ceiling 29500))
    (should-not (iar--reqlog-invisible-burn-p "length" 20000 nil))))

(ert-deftest test-invisible-burn-silent-on-missing-data ()
  "NA tokens or nil stop: never fires (absence of evidence)."
  (let ((iar--reqlog-witness-ceiling 29500))
    (should-not (iar--reqlog-invisible-burn-p "length" nil nil))
    (should-not (iar--reqlog-invisible-burn-p nil 32768 nil))
    (should-not (iar--reqlog-invisible-burn-p "stop" 32768 nil))))

(provide 'test-invisible-burn-witness)
