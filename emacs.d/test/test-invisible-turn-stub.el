;; Regression tests for the invisible-turn stub fix (P0, breaker-grace
;; compliance task).  A thinking-only turn truncated at the output cap
;; (num_predict / stop=length) produces a reasoning block (gptel 'ignore)
;; followed by a user/continue message with NO response in between.  The
;; model's own turn vanished from the messages array (invisible-turn
;; mechanism, c4/c6), so it re-derived the same analysis every turn --
;; the structural loop behind three consecutive lost cycles.
;;
;; Fix (gptel-ollama.el parse-buffer): when walking backward we hit an
;; 'ignore (reasoning) region whose NEWER neighbor is a user message
;; (last-role not 'assistant), synthesize a stub assistant message so the
;; model can see its work was cut off.
;;
;; These tests build the buffer the way gptel actually lays it out and
;; assert the parsed messages array.

(require 'ert)
(add-to-list 'load-path "/root/.emacs.d/gptel-fork")
(require 'gptel)
(require 'gptel-ollama)
(setq gptel-include-reasoning 'ignore)

(defmacro invisible-turn--with-buffer (reasoning-text response-text &rest body)
  "Build a gptel buffer with a user turn, optional REASONING-TEXT block,
and optional RESPONSE-TEXT, then run BODY with that buffer current.
REASONING-TEXT nil means no reasoning block.  RESPONSE-TEXT nil means no
response (truncated thinking-only turn).  The buffer is live for BODY
and killed afterward."
  (declare (indent 2))
  `(with-temp-buffer
     (text-mode)
     (gptel-mode 1)
     (insert "user: hello\n")
     (let ((info (list :buffer (current-buffer)
                       :position (copy-marker (point) t)
                       :include-reasoning 'ignore)))
       (when ,reasoning-text
         (gptel--insert-response
          (concat (propertize "``` reasoning\n" 'gptel 'ignore 'keymap nil)
                  (propertize ,reasoning-text 'gptel 'ignore 'front-sticky '(gptel))
                  (propertize "\n```" 'gptel 'ignore 'keymap nil)
                  gptel-response-separator)
          info t))
       (when ,response-text
         (gptel--insert-response ,response-text info)))
     ,@body))

(defun invisible-turn--parse ()
  "Parse the current buffer into a messages list.

`gptel--parse-buffer' walks backward from (point), and in the real
request flow point sits at the end of the buffer (after the response
is inserted).  The test harness must reproduce that: position point
at point-max before parsing, or the walk starts before the inserted
blocks and sees only the leading user region."
  (goto-char (point-max))
  (gptel--parse-buffer (gptel-make-ollama "InvisibleTurn" :host "localhost:11434")))

(defun invisible-turn--roles (msgs)
  "Return the :role of each message in MSGS."
  (mapcar (lambda (m) (plist-get m :role)) msgs))

(ert-deftest test-invisible-turn-normal-reasoning-response ()
  "A reasoning block followed by a real response yields no stub:
the assistant turn is the response, not a synthesized stub."
  (invisible-turn--with-buffer "thinking here" "assistant reply"
    (let ((msgs (invisible-turn--parse)))
      (should (equal (invisible-turn--roles msgs) '("user" "assistant")))
      ;; The assistant message is the real response, not the stub.
      (should (equal (plist-get (nth 1 msgs) :content) "assistant reply")))))

(ert-deftest test-invisible-turn-truncated-thinking-only-stub ()
  "A reasoning block with NO response (truncated thinking-only turn)
yields a stub assistant message so the model sees its work was cut."
  (invisible-turn--with-buffer "cut off thinking" nil
    (let ((msgs (invisible-turn--parse)))
      (should (equal (invisible-turn--roles msgs) '("user" "assistant")))
      (should (string-match-p "truncated at output cap"
                              (plist-get (nth 1 msgs) :content))))))

(ert-deftest test-invisible-turn-no-reasoning-no-stub ()
  "A plain user turn with no reasoning block produces no stub."
  (invisible-turn--with-buffer nil nil
    (let ((msgs (invisible-turn--parse)))
      (should (equal (invisible-turn--roles msgs) '("user"))))))

(ert-deftest test-invisible-turn-stub-does-not-collide-with-next-turn ()
  "A completed turn (reasoning + response) followed by a TRAILING
truncated reasoning-only turn: only the trailing truncated turn gets a
stub; the completed turn's response is untouched.  This pins the
last-role logic: a mid-conversation reasoning block with a real
response after it is NOT a truncated turn."
  (invisible-turn--with-buffer "first thinking" "first answer"
    ;; append a trailing reasoning-only turn (truncated)
    (let ((info (list :buffer (current-buffer)
                      :position (copy-marker (point-max) t)
                      :include-reasoning 'ignore)))
      (insert "\nuser: continue\n")
      (gptel--insert-response
       (concat (propertize "``` reasoning\n" 'gptel 'ignore 'keymap nil)
               (propertize "cut off thinking" 'gptel 'ignore 'front-sticky '(gptel))
               (propertize "\n```" 'gptel 'ignore 'keymap nil)
               gptel-response-separator)
       info t))
    (let ((msgs (invisible-turn--parse)))
      ;; The trailing "user: continue" text merges into the leading user
      ;; region (no gptel property boundary between them), so the shape is
      ;; user / assistant(real) / assistant(stub).
      (should (equal (invisible-turn--roles msgs)
                     '("user" "assistant" "assistant")))
      ;; First assistant = the completed turn's real response, no stub.
      (should (equal (plist-get (nth 1 msgs) :content) "first answer"))
      (should-not (string-match-p "truncated at output cap"
                                  (plist-get (nth 1 msgs) :content)))
      ;; Last assistant = stub for the trailing truncated turn.
      (should (string-match-p "truncated at output cap"
                              (plist-get (nth 2 msgs) :content))))))

(provide 'test-invisible-turn-stub)
