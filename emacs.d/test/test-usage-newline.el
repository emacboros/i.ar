;;; test-usage-newline.el -- newline guard tests (continuo c49)
(require 'ert)

(ert-deftest test-usage-newline-guard-appends-when-missing ()
  "File lacking trailing newline gets one before append."
  (let ((tmp (make-temp-file "usage-test")))
    (unwind-protect
        (progn
          (write-region "[2026-09-04 02:33:26] requests=1 input=100 output=10 total=110 model=m" nil tmp)
          (iar--ensure-trailing-newline tmp)
          (append-to-file "[2026-09-04 05:07:30] requests=2 input=200 output=20 total=220 model=m\n" nil tmp)
          (with-temp-buffer
            (insert-file-contents tmp)
            (goto-char (point-min))
            (should (search-forward "02:33:26] requests=1 input=100 output=10 total=110 model=m\n[2026-09-04 05:07:30]" nil t))))
      (delete-file tmp))))

(ert-deftest test-usage-newline-guard-noop-when-present ()
  "File already ending in newline is untouched."
  (let ((tmp (make-temp-file "usage-test"))
        (mtime-before nil))
    (unwind-protect
        (progn
          (write-region "line\n" nil tmp)
          (setq mtime-before (nth 5 (file-attributes tmp)))
          (sleep-for 0 1100)
          (should (eq (iar--ensure-trailing-newline tmp) nil))
          (should (equal mtime-before (nth 5 (file-attributes tmp)))))
      (delete-file tmp))))

(ert-deftest test-usage-newline-guard-missing-file-noop ()
  "Nonexistent file: no error, returns nil."
  (let ((tmp (make-temp-file "usage-test")))
    (delete-file tmp)
    (should (eq (iar--ensure-trailing-newline tmp) nil))))

(ert-deftest test-usage-newline-guard-empty-file-noop ()
  "Empty file: no error, returns nil (nothing to glue)."
  (let ((tmp (make-temp-file "usage-test")))
    (unwind-protect
        (should (eq (iar--ensure-trailing-newline tmp) nil))
      (delete-file tmp))))

(ert-deftest test-usage-newline-guard-glued-file-repairs ()
  "A file with two GLUED lines (the c45/c46 scar) gets split by the guard."
  (let ((tmp (make-temp-file "usage-test")))
    (unwind-protect
        (progn
          (write-region "[2026-09-04 02:33:26] requests=1 input=100 output=10 total=110 model=m[2026-09-04 04:09:09] requests=3 input=300 output=30 total=330 model=m" nil tmp)
          (iar--ensure-trailing-newline tmp)
          (append-to-file "[2026-09-04 05:07:30] requests=4 input=400 output=40 total=440 model=m\n" nil tmp)
          (with-temp-buffer
            (insert-file-contents tmp)
            (should (search-forward "model=m\n[2026-09-04 05:07:30]" nil t))))
      (delete-file tmp))))
