;; -*- lexical-binding: t; -*-

;;; telegram tool for gptel
;; Send a Telegram notification message from inside the container.
;;
;; This is an ASYNC tool: the function receives a callback as its first
;; argument (per gptel's :async convention) and calls it with the result
;; when the curl process completes.
;;
;; The message is automatically prefixed with [AgentName] so the human
;; can identify which agent sent it.  Credentials come from environment
;; variables (AGENT_TELEGRAM_BOT_TOKEN, AGENT_TELEGRAM_CHAT_ID) which
;; are set by iar.sh and passed into the container via -e flags.
;;
;; Audit: every message sent is logged to the central audit log.
;;
;; IMPLEMENTATION NOTE: This tool uses synchronous `call-process' instead
;; of async `make-process'.  The tool is already async from gptel's
;; perspective (the callback is invoked when done), so we can block
;; briefly while curl runs.  curl's -m flag provides a hard timeout,
;; making the behavior deterministic and eliminating the sentinel/timer
;; race conditions that caused the previous hang bug.

(require 'iar-tool-call)
(require 'iar-utils)

(defun iar--tool-telegram (callback message)
  "Send MESSAGE via Telegram Bot API.
Calls CALLBACK with the result string when done.
Credentials are read from AGENT_TELEGRAM_BOT_TOKEN and
AGENT_TELEGRAM_CHAT_ID environment variables.
The message is prefixed with [AgentName] for identification."
  (let* ((token (getenv "AGENT_TELEGRAM_BOT_TOKEN"))
         (chat-id (getenv "AGENT_TELEGRAM_CHAT_ID"))
         (agent (iar--get-agent-name))
         (full-message (format "[%s] %s" agent message)))
    (cond
     ;; No credentials configured
     ((or (null token) (string-empty-p token)
          (null chat-id) (string-empty-p chat-id))
      (funcall callback
               "Error: Telegram credentials not configured. AGENT_TELEGRAM_BOT_TOKEN and AGENT_TELEGRAM_CHAT_ID environment variables must be set."))
     ;; Empty message
     ((or (null message) (string-empty-p message))
      (funcall callback "Error: Message is empty. Provide a non-empty message to send."))
     ;; Send via curl (synchronous, with hard timeout)
     (t
      (let* ((url (format "https://api.telegram.org/bot%s/sendMessage" token))
             (payload (json-serialize
                       `(:chat_id ,chat-id
                         :text ,full-message)))
             (output (with-temp-buffer
                       (let ((exit-code
                              (call-process
                               "curl" nil t nil
                               "-s" "-m" "10" "--connect-timeout" "5"
                               "-X" "POST"
                               "-H" "Content-Type: application/json"
                               "-d" payload
                               url)))
                         (cons exit-code (buffer-string)))))
             (exit-code (car output))
             (response-text (cdr output))
             (ok nil)
             (parse-error nil))
        ;; Parse JSON response to check success
        (condition-case err
            (let ((parsed (with-temp-buffer
                            (insert response-text)
                            (goto-char (point-min))
                            (let ((json-object-type 'plist))
                              (json-read)))))
              (setq ok (eq (plist-get parsed :ok) t)))
          (error
           (setq parse-error (error-message-string err))))
        ;; Log to audit (bare format was a no-op in previous version)
        (iar--audit-log 'telegram
                        (format "msg=%s ok=%s exit=%d"
                                (substring full-message 0 (min 100 (length full-message)))
                                (if ok "yes" "no") exit-code))
        (funcall callback
                 (cond
                  (ok
                   (format "Success: Telegram message sent. [%s] %s" agent message))
                  (parse-error
                   (format "Error: Telegram API returned unparseable response (exit %d): %s"
                           exit-code response-text))
                  (t
                   (format "Error: Telegram API returned (exit %d): %s"
                           exit-code response-text)))))))))

(iar-tool-register
 (gptel-make-tool
  :name "send_telegram"
  :description "Send a Telegram notification. Message prefixed with agent name."
  :args (list '(:name "message" :type "string" :description "The message text to send. Keep it concise -- this is a notification, not a report."))
  :async t
  :function #'iar--tool-telegram))

(provide 'iar-tool--telegram)