;; Test: gptel-ollama parse-stream nil-content coercion (c358).
;; A stream whose chunks carry no :content (reasoning-only bursts,
;; degenerate chunks after a corrupted generation -- aria c357-start
;; 08:00Z exit 255) must return "" not nil: the stream filter calls
;; (string-blank-p response) and nil crashes it with
;; wrong-type-argument stringp nil, killing the request mid-flight.

(require 'ert)
(require 'gptel-ollama)

(defun iar-test--ollama-parse-chunks (chunks)
  "Feed CHUNKS (list of JSON strings) through gptel-curl--parse-stream
and return its result."
  (with-temp-buffer
    (let ((info (list :backend (gptel--make-ollama)
                      :reasoning-block nil)))
      (dolist (c chunks)
        (insert c "\n"))
      (goto-char (point-min))
      (gptel-curl--parse-stream (gptel--make-ollama) info))))

(ert-deftest test-ollama-parse-stream-nil-content ()
  "Reasoning-only chunk stream -> parse-stream returns \"\" not nil."
  (let ((res (iar-test--ollama-parse-chunks
              (list "{\"model\":\"glm-5.3-flash\",\"message\":{\"role\":\"assistant\",\"thinking\":\"abc\"},\"done\":false}"
                    "{\"model\":\"glm-5.3-flash\",\"message\":{\"role\":\"assistant\",\"content\":\"\"},\"done\":true}"))))
    (should (stringp res))
    (should (equal res ""))))

(ert-deftest test-ollama-parse-stream-tool-only-chunk ()
  "Tool-call-only chunk (no content, no thinking) -> \"\" not nil."
  (let ((res (iar-test--ollama-parse-chunks
              (list "{\"model\":\"glm-5.3-flash\",\"message\":{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"function\":{\"name\":\"execute_code_local\",\"arguments\":{\"command\":\"ls\"}}}]},\"done\":false}"
                    "{\"model\":\"glm-5.3-flash\",\"message\":{\"role\":\"assistant\",\"content\":\"\"},\"done\":true}"))))
    (should (stringp res))
    (should (equal res ""))))

(ert-deftest test-ollama-parse-stream-content-still-works ()
  "Normal content chunks still concatenate (no behavior change)."
  (let ((res (iar-test--ollama-parse-chunks
              (list "{\"model\":\"glm-5.3-flash\",\"message\":{\"role\":\"assistant\",\"content\":\"hel\"},\"done\":false}"
                    "{\"model\":\"glm-5.3-flash\",\"message\":{\"role\":\"assistant\",\"content\":\"lo\"},\"done\":true}"))))
    (should (equal res "hello"))))