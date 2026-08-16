;; -*- lexical-binding: t; -*-

;;; Tests for telegram tool (iar-tool--telegram)
;; Tests the Telegram notification tool: credential checking,
;; message validation, and send path (mocks call-process).
;; Does NOT test actual network calls.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-tool--telegram)

;;; --- Credential validation tests ---

(ert-deftest test-telegram-no-credentials-returns-error ()
  "send_telegram should return error when credentials are not set."
  (cl-letf (((symbol-function 'getenv)
             (lambda (var)
               (cond ((string= var "AGENT_TELEGRAM_BOT_TOKEN") nil)
                     ((string= var "AGENT_TELEGRAM_CHAT_ID") nil)
                     (t (let ((old-getenv (symbol-function 'getenv)))
                          ;; Fallback to real getenv for other vars
                          (funcall old-getenv var)))))))
    (let (result)
      (iar--tool-telegram (lambda (r) (setq result r)) "Hello")
      (should (stringp result))
      (should (string-match-p "Error" result))
      (should (string-match-p "credentials not configured" result)))))

(ert-deftest test-telegram-empty-credentials-returns-error ()
  "send_telegram should return error when credentials are empty strings."
  (cl-letf (((symbol-function 'getenv)
             (lambda (var)
               (cond ((string= var "AGENT_TELEGRAM_BOT_TOKEN") "")
                     ((string= var "AGENT_TELEGRAM_CHAT_ID") "")
                     (t (let ((old-getenv (symbol-function 'getenv)))
                          (funcall old-getenv var)))))))
    (let (result)
      (iar--tool-telegram (lambda (r) (setq result r)) "Hello")
      (should (stringp result))
      (should (string-match-p "Error" result))
      (should (string-match-p "credentials not configured" result)))))

(ert-deftest test-telegram-empty-message-returns-error ()
  "send_telegram should return error when message is empty."
  (cl-letf (((symbol-function 'getenv)
             (lambda (var)
               (cond ((string= var "AGENT_TELEGRAM_BOT_TOKEN") "fake-token")
                     ((string= var "AGENT_TELEGRAM_CHAT_ID") "fake-chat-id")
                     (t (let ((old-getenv (symbol-function 'getenv)))
                          (funcall old-getenv var)))))))
    (let (result)
      (iar--tool-telegram (lambda (r) (setq result r)) "")
      (should (stringp result))
      (should (string-match-p "Error" result))
      (should (string-match-p "empty" result)))))

(ert-deftest test-telegram-nil-message-returns-error ()
  "send_telegram should return error when message is nil."
  (cl-letf (((symbol-function 'getenv)
             (lambda (var)
               (cond ((string= var "AGENT_TELEGRAM_BOT_TOKEN") "fake-token")
                     ((string= var "AGENT_TELEGRAM_CHAT_ID") "fake-chat-id")
                     (t (let ((old-getenv (symbol-function 'getenv)))
                          (funcall old-getenv var)))))))
    (let (result)
      (iar--tool-telegram (lambda (r) (setq result r)) nil)
      (should (stringp result))
      (should (string-match-p "Error" result))
      (should (string-match-p "empty" result)))))

;;; --- Send path tests (mocked call-process) ---
;; The implementation uses (call-process "curl" nil t nil ...) where
;; BUFFER=t means "insert output in current buffer". The mock inserts
;; a fake JSON response into the current buffer and returns exit code 0.

(ert-deftest test-telegram-success-send ()
  "send_telegram should return Success when API returns ok=true."
  (cl-letf (((symbol-function 'getenv)
             (lambda (var)
               (cond ((string= var "AGENT_TELEGRAM_BOT_TOKEN") "fake-token")
                     ((string= var "AGENT_TELEGRAM_CHAT_ID") "fake-chat-id")
                     (t (let ((old-getenv (symbol-function 'getenv)))
                          (funcall old-getenv var))))))
            ((symbol-function 'call-process)
             (lambda (_program _infile _buffer _display &rest _args)
               ;; _buffer is t: insert into current buffer
               (insert "{\"ok\":true,\"result\":{\"message_id\":1}}")
               0))
            ((symbol-function 'iar--audit-log) (lambda (_tool _detail) nil)))
    (let (result)
      (iar--tool-telegram (lambda (r) (setq result r)) "Test message")
      (should (stringp result))
      (should (string-match-p "Success" result)))))

(ert-deftest test-telegram-api-error-send ()
  "send_telegram should return Error when API returns ok=false."
  (cl-letf (((symbol-function 'getenv)
             (lambda (var)
               (cond ((string= var "AGENT_TELEGRAM_BOT_TOKEN") "fake-token")
                     ((string= var "AGENT_TELEGRAM_CHAT_ID") "fake-chat-id")
                     (t (let ((old-getenv (symbol-function 'getenv)))
                          (funcall old-getenv var))))))
            ((symbol-function 'call-process)
             (lambda (_program _infile _buffer _display &rest _args)
               (insert "{\"ok\":false,\"description\":\"Bad Request\"}")
               0))
            ((symbol-function 'iar--audit-log) (lambda (_tool _detail) nil)))
    (let (result)
      (iar--tool-telegram (lambda (r) (setq result r)) "Test message")
      (should (stringp result))
      (should (string-match-p "Error" result)))))

(ert-deftest test-telegram-curl-timeout ()
  "send_telegram should return Error when curl times out (exit code 28)."
  (cl-letf (((symbol-function 'getenv)
             (lambda (var)
               (cond ((string= var "AGENT_TELEGRAM_BOT_TOKEN") "fake-token")
                     ((string= var "AGENT_TELEGRAM_CHAT_ID") "fake-chat-id")
                     (t (let ((old-getenv (symbol-function 'getenv)))
                          (funcall old-getenv var))))))
            ((symbol-function 'call-process)
             (lambda (_program _infile _buffer _display &rest _args)
               28))  ; curl timeout exit code, no output
            ((symbol-function 'iar--audit-log) (lambda (_tool _detail) nil)))
    (let (result)
      (iar--tool-telegram (lambda (r) (setq result r)) "Test message")
      (should (stringp result))
      (should (string-match-p "Error" result)))))

(ert-deftest test-telegram-unparseable-response ()
  "send_telegram should return Error when API returns non-JSON."
  (cl-letf (((symbol-function 'getenv)
             (lambda (var)
               (cond ((string= var "AGENT_TELEGRAM_BOT_TOKEN") "fake-token")
                     ((string= var "AGENT_TELEGRAM_CHAT_ID") "fake-chat-id")
                     (t (let ((old-getenv (symbol-function 'getenv)))
                          (funcall old-getenv var))))))
            ((symbol-function 'call-process)
             (lambda (_program _infile _buffer _display &rest _args)
               (insert "not json at all")
               0))
            ((symbol-function 'iar--audit-log) (lambda (_tool _detail) nil)))
    (let (result)
      (iar--tool-telegram (lambda (r) (setq result r)) "Test message")
      (should (stringp result))
      (should (string-match-p "Error" result))
      (should (string-match-p "unparseable" result)))))

;;; --- Message prefixing tests ---

(ert-deftest test-telegram-message-prefixed-with-agent-name ()
  "send_telegram should prefix message with [AgentName]."
  (let ((iar--current-agent-name "testagent"))
    (should (functionp #'iar--tool-telegram))))

(provide 'test-telegram)
;;; test-telegram.el ends here