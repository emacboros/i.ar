;;; Test: ollama stream parser captures mid-stream error chunks
(require 'gptel-ollama)
(require 'gptel-request)
(require 'ert)

(defmacro gptel-ollama-test--parse (body &rest setup)
  "Run the ollama stream parser over BODY (string) with SETUP bindings.
Returns the resulting info plist; the parse buffer is current."
  `(with-temp-buffer
     ,@setup
     (insert ,body)
     (goto-char (point-min))
     (let ((info (list :backend (gptel--make-ollama :name "test"))))
       ;; simulate: bobp + re-search-forward "^{" like the real filter
       (gptel-curl--parse-stream (plist-get info :backend) info)
       info)))

(ert-deftest test-ollama-error-chunk-captured ()
  "A bare {\"error\":...} chunk sets info :error and :status."
  (let* ((body "{\"model\":\"m\",\"message\":{\"role\":\"assistant\",\"content\":\"\",\"thinking\":\"We\"},\"done\":false}\n{\"error\":\"Internal Server Error (ref: abc)\"}\n")
         (info (with-temp-buffer
                 (insert body)
                 (goto-char (point-min))
                 (let ((i (list :backend (gptel--make-ollama :name "t"))))
                   (gptel-curl--parse-stream (plist-get i :backend) i)
                   i))))
    (should (equal (plist-get info :error) "Internal Server Error (ref: abc)"))
    (should (string-match-p "Ollama error" (plist-get info :status)))))

(ert-deftest test-ollama-error-chunk-no-token-poison ()
  "The error chunk must not publish 0/0 tokens."
  (let* ((body "{\"model\":\"m\",\"message\":{\"role\":\"assistant\",\"content\":\"\",\"thinking\":\".\"},\"done\":false}\n{\"error\":\"boom\"}\n")
         (info (with-temp-buffer
                 (insert body)
                 (goto-char (point-min))
                 (let ((i (list :backend (gptel--make-ollama :name "t"))))
                   (gptel-curl--parse-stream (plist-get i :backend) i)
                   i))))
    (should (equal (plist-get info :tokens) nil))))

(ert-deftest test-ollama-normal-stream-unaffected ()
  "A normal stream (thinking + content + done) still parses."
  (let* ((body "{\"model\":\"m\",\"message\":{\"role\":\"assistant\",\"content\":\"\",\"thinking\":\"th\"},\"done\":false}\n{\"model\":\"m\",\"message\":{\"role\":\"assistant\",\"content\":\"Hello\"},\"done\":false}\n{\"model\":\"m\",\"message\":{\"role\":\"assistant\",\"content\":\"\"},\"done\":true,\"done_reason\":\"stop\",\"prompt_eval_count\":10,\"eval_count\":5}\n")
         (info (with-temp-buffer
                 (insert body)
                 (goto-char (point-min))
                 (let ((i (list :backend (gptel--make-ollama :name "t"))))
                   (gptel-curl--parse-stream (plist-get i :backend) i)
                   i))))
    (should (equal (plist-get info :stop-reason) "stop"))
    (should (equal (plist-get info :tokens) (list :input 10 :output 5)))
    (should (equal (plist-get info :error) nil))))

(ert-deftest test-ollama-error-after-done-reason ()
  "An error chunk mid-stream (no done chunk) leaves prior state intact
and captures the error. NOTE: a done:true chunk jumps to point-max, so
a trailing error chunk after done:true is never parsed (upstream
behavior, unchanged)."
  (let* ((body "{\"model\":\"m\",\"message\":{\"role\":\"assistant\",\"content\":\"\",\"thinking\":\"partial\"},\"done\":false}\n{\"error\":\"late boom\"}\n")
         (info (with-temp-buffer
                 (insert body)
                 (goto-char (point-min))
                 (let ((i (list :backend (gptel--make-ollama :name "t"))))
                   (gptel-curl--parse-stream (plist-get i :backend) i)
                   i))))
    (should (equal (plist-get info :error) "late boom"))
    (should (equal (plist-get info :tokens) nil))))
