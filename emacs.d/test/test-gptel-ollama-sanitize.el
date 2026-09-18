;; -*- lexical-binding: t; -*-
;; Unit tests for gptel-ollama--sanitize-call-spec
(require 'ert)
(add-to-list 'load-path "/root/.emacs.d/gptel-fork")
(require 'gptel)
(require 'gptel-ollama)

(ert-deftest test-sanitize-normal ()
  "Well-formed spec passes through with :args renamed."
  (let ((spec (gptel-ollama--sanitize-call-spec
               '(:index 0 :name "read_file" :arguments (:filepath "/tmp/x")))))
    (should (equal (plist-get spec :name) "read_file"))
    (should (equal (plist-get spec :args) '(:filepath "/tmp/x")))
    (should (null (plist-get spec :arguments)))))

(ert-deftest test-sanitize-raw-text-name ()
  "Name is the whole raw call text (string) -- passes through as a name.
This is the live 2026-08-30 signature: name = '{\"name\": read_file, ...}'.
It's a string, so it doesn't crash, and it flows into unknown-tool path."
  (let* ((raw "{\"name\": read_file, \"arguments\": {\"filepath\": 12345}}")
         (spec (gptel-ollama--sanitize-call-spec
                `(:index 0 :name ,raw :arguments (:filepath 12345)))))
    (should (stringp (plist-get spec :name)))
    (should (equal (plist-get spec :name) raw))
    (should (equal (plist-get spec :args) '(:filepath 12345)))))

(ert-deftest test-sanitize-nil-function ()
  ":function missing -> nil -> malformed placeholder."
  (let ((spec (gptel-ollama--sanitize-call-spec nil)))
    (should (equal (plist-get spec :name) "malformed_tool_call"))
    (should (null (plist-get spec :args)))))

(ert-deftest test-sanitize-string-function ()
  ":function is a raw string (proxy gave up parsing) -> placeholder.
This shape crashed plist-put in the process filter before the fix."
  (let ((spec (gptel-ollama--sanitize-call-spec
               "{name: read_file, arguments: {filepath: 12345}}")))
    (should (equal (plist-get spec :name) "malformed_tool_call"))
    (should (null (plist-get spec :args)))))

(ert-deftest test-sanitize-nonstring-name ()
  ":name is not a string (JSON type-inferred integer/nil/etc) -> placeholder.
This shape crashed propertize in gptel--update-tool-call before the fix."
  (let ((spec (gptel-ollama--sanitize-call-spec '(:name 12345 :arguments (:x 1)))))
    (should (equal (plist-get spec :name) "malformed_tool_call"))
    (should (null (plist-get spec :args)))))

(ert-deftest test-sanitize-missing-name ()
  ":name missing entirely -> placeholder."
  (let ((spec (gptel-ollama--sanitize-call-spec '(:arguments (:filepath "/tmp/x")))))
    (should (equal (plist-get spec :name) "malformed_tool_call"))))

(ert-deftest test-sanitize-string-args ()
  ":arguments is a raw string (unparseable JSON) -> args nil, name kept."
  (let ((spec (gptel-ollama--sanitize-call-spec
               '(:name "read_file" :arguments "{filepath: 12345}"))))
    (should (equal (plist-get spec :name) "read_file"))
    (should (null (plist-get spec :args)))))

(ert-deftest test-sanitize-already-args ()
  "Spec already uses :args (not :arguments) -> kept."
  (let ((spec (gptel-ollama--sanitize-call-spec
               '(:name "read_file" :args (:filepath "/tmp/x")))))
    (should (equal (plist-get spec :name) "read_file"))
    (should (equal (plist-get spec :args) '(:filepath "/tmp/x")))))


(provide 'test-gptel-ollama-sanitize)
