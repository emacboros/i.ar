;; -*- lexical-binding: t; -*-
;; Unit tests for the Ollama streaming done_reason capture
;; (gptel-ollama.el, cycle 116).
;;
;; Background: the non-streaming path (gptel--parse-response) stores
;; :done_reason in :stop-reason, but the streaming path
;; (gptel-curl--parse-stream) never did.  i.ar agents run with
;; :stream t, so a generation truncated by num_predict was
;; indistinguishable from a complete stop -- the Aevum experiment
;; (2026-09-01) showed the cost: a watchdog-killed/truncated response
;; fed back into the next tick's context looked identical to a
;; finished one, and the child built on a fiction.
;;
;; These tests exercise the streaming parse method directly with
;; synthetic Ollama NDJSON chunks.

(require 'ert)
(add-to-list 'load-path "/root/.emacs.d/gptel-fork")
(require 'gptel)
(require 'gptel-ollama)

(defun test-ollama--stream-parse (chunks)
  "Run gptel-curl--parse-stream on CHUNKS (list of JSON strings).
Returns the INFO plist after parsing."
  (let ((info (list :backend (gptel-make-ollama "TestOllamaStream"
                                 :host "localhost:11434")
                    :data (list :messages (vector)))))
    (with-temp-buffer
      (dolist (chunk chunks)
        (insert chunk "\n"))
      (goto-char (point-min))
      (gptel-curl--parse-stream
       (gptel-make-ollama "TestOllamaStream2" :host "localhost:11434")
       info))
    info))

(ert-deftest test-ollama-stream-done-reason-stop ()
  "A complete generation captures done_reason=stop."
  (let* ((chunks (list "{\"message\":{\"content\":\"hello\"},\"done\":false}"
                       "{\"message\":{\"content\":\" world\"},\"done\":true,\"done_reason\":\"stop\",\"prompt_eval_count\":10,\"eval_count\":20}"))
         (info (test-ollama--stream-parse chunks)))
    (should (equal (plist-get info :stop-reason) "stop"))))

(ert-deftest test-ollama-stream-done-reason-length ()
  "A num_predict-truncated generation captures done_reason=length.
This is the Aevum signature: the response ends mid-thought and the
caller must be able to tell."
  (let* ((chunks (list "{\"message\":{\"content\":\"partial res\"},\"done\":false}"
                       "{\"message\":{\"content\":\"ponse\"},\"done\":true,\"done_reason\":\"length\",\"prompt_eval_count\":100,\"eval_count\":4096}"))
         (info (test-ollama--stream-parse chunks)))
    (should (equal (plist-get info :stop-reason) "length"))))

(ert-deftest test-ollama-stream-no-done-reason-yet ()
  "Mid-stream chunks (done absent) leave :stop-reason unset."
  (let* ((chunks (list "{\"message\":{\"content\":\"still going\"},\"done\":false}"))
         (info (test-ollama--stream-parse chunks)))
    (should (null (plist-get info :stop-reason)))))

(ert-deftest test-ollama-stream-done-reason-with-tool-calls ()
  "done_reason is captured even when the chunk carries tool_calls
(the two paths are independent)."
  (let* ((chunks (list "{\"message\":{\"content\":null,\"tool_calls\":[{\"function\":{\"name\":\"read_file\",\"arguments\":{\"filepath\":\"/tmp/x\"}}}]},\"done\":true,\"done_reason\":\"stop\"}"))
         (info (test-ollama--stream-parse chunks)))
    (should (equal (plist-get info :stop-reason) "stop"))
    (should (= (length (plist-get info :tool-use)) 1))))

(ert-deftest test-ollama-stream-content-returned ()
  "Regression guard: the method still returns concatenated content
(the patch must not disturb the return value -- gptel inserts it
into the response buffer)."
  (let* ((chunks (list "{\"message\":{\"content\":\"a\"},\"done\":false}"
                       "{\"message\":{\"content\":\"b\"},\"done\":true,\"done_reason\":\"stop\"}"))
         (out (with-temp-buffer
                (insert (mapconcat #'identity chunks "\n"))
                (goto-char (point-min))
                (gptel-curl--parse-stream
                 (gptel-make-ollama "TestOllamaStream3" :host "localhost:11434")
                 (list :backend (gptel-make-ollama "TestOllamaStream4"
                                    :host "localhost:11434")
                       :data (list :messages (vector)))))))
    (should (equal out "ab"))))