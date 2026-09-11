;;; test-reqlog-full-fix.el -- verify the symbol-model fix for full capture

(require 'ert)
(require 'json)
(require 'iar-request-log)

(ert-deftest test-reqlog-full-dump-symbol-model ()
  "Full capture survives a SYMBOL :model (gptel-model is interned).
Regression: c211 live test -- every full dump failed with
wrong-type-argument json-value-p <model> because the payload
embedded the raw symbol value. The dump must stringify it."
  (let* ((tmpdir (make-temp-file "reqlog-sym-" t))
         (iar-personalization-path tmpdir)
         (iar-audit-path "audit")
         (iar--reqlog-agent "testagent")
         (iar--current-project "testproject")
         (msgs (vector (list :role "user" :content "first")))
         (path (expand-file-name
                "audit/testproject/testagent/REQUESTS-full/REQ-sym-1.json"
                tmpdir)))
    (unwind-protect
        (progn
          (iar--reqlog-full-dump "sym-1" (list :model 'glm-5.3-flash:cloud) msgs)
          (should (file-exists-p path))
          (with-temp-buffer
            (insert-file-contents path)
            (let ((json-object-type 'plist))
              (let ((payload (json-read-from-string (buffer-string))))
                (should (equal (plist-get payload :model)
                               "glm-5.3-flash:cloud"))))))
      (delete-directory tmpdir :recursive))))

(ert-deftest test-reqlog-full-dump-string-model-still-works ()
  "String :model still encodes (no double-conversion error)."
  (let* ((tmpdir (make-temp-file "reqlog-str-" t))
         (iar-personalization-path tmpdir)
         (iar-audit-path "audit")
         (iar--reqlog-agent "testagent")
         (iar--current-project "testproject")
         (path (expand-file-name
                "audit/testproject/testagent/REQUESTS-full/REQ-str-1.json"
                tmpdir)))
    (unwind-protect
        (progn
          (iar--reqlog-full-dump "str-1" (list :model "plain-string") nil)
          (should (file-exists-p path))
          (with-temp-buffer
            (insert-file-contents path)
            (let* ((json-object-type 'plist)
                   (payload (json-read-from-string (buffer-string))))
              (should (equal (plist-get payload :model) "plain-string")))))
      (delete-directory tmpdir :recursive))))

(provide 'test-reqlog-full-fix)