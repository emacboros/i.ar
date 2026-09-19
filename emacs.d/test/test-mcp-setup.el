;; -*- lexical-binding: t; -*-

;;; Tests for iar-mcp-setup.el
;;
;; Unit tests for MCP server config resolution, hub config building,
;; and session lifecycle. MCP package functions are mocked -- these
;; tests verify i.ar's integration logic, not the mcp package itself.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'iar-mcp-setup)

;;; --- Server config resolution tests ---

(ert-deftest test-mcp-config-for-server-found ()
  "iar--mcp-config-for-server returns config for known server."
  (let ((iar-mcp-servers
         '(("burp" . (:url "http://localhost:9876/sse"))
           ("custom" . (:command "my-server" :args ("--flag"))))))
    (let ((config (iar--mcp-config-for-server "burp")))
      (should (string= (plist-get config :url) "http://localhost:9876/sse")))
    (let ((config (iar--mcp-config-for-server "custom")))
      (should (string= (plist-get config :command) "my-server")))))

(ert-deftest test-mcp-config-for-server-not-found ()
  "iar--mcp-config-for-server returns nil for unknown server."
  (let ((iar-mcp-servers '(("burp" . (:url "http://localhost:9876/sse")))))
    (should (null (iar--mcp-config-for-server "unknown")))))

;;; --- Hub config building tests ---

(ert-deftest test-mcp-build-hub-config-filters-unknown ()
  "iar--mcp-build-hub-config only includes servers with configs."
  (let ((iar-mcp-servers
         '(("burp" . (:url "http://localhost:9876/sse")))))
    (let ((hub (iar--mcp-build-hub-config '("burp" "unknown"))))
      (should (= (length hub) 1))
      (should (assoc "burp" hub))
      (should-not (assoc "unknown" hub)))))

(ert-deftest test-mcp-build-hub-config-empty ()
  "iar--mcp-build-hub-config returns nil for empty names."
  (let ((iar-mcp-servers '(("burp" . (:url "http://localhost:9876/sse")))))
    (should (null (iar--mcp-build-hub-config nil)))
    (should (null (iar--mcp-build-hub-config '())))))

(ert-deftest test-mcp-build-hub-config-no-matching ()
  "iar--mcp-build-hub-config returns nil when no names match configs."
  (let ((iar-mcp-servers '(("burp" . (:url "http://localhost:9876/sse")))))
    (should (null (iar--mcp-build-hub-config '("unknown1" "unknown2"))))))

;;; --- Filter servers tests ---


(ert-deftest test-mcp-format-servers-empty ()
  "iar--format-mcp-servers returns empty string for nil/empty."
  (should (string= (iar--format-mcp-servers nil) ""))
  (should (string= (iar--format-mcp-servers '()) "")))

(ert-deftest test-mcp-format-servers-known ()
  "iar--format-mcp-servers returns formatted block for known servers."
  (let ((result (iar--format-mcp-servers '("burp"))))
    (should (stringp result))
    (should (string-match-p "MCP SERVERS" result))
    (should (string-match-p "burp:" result))
    (should (string-match-p "Burp Suite" result))))

(ert-deftest test-mcp-format-servers-unknown ()
  "iar--format-mcp-servers handles unknown server names gracefully."
  (let ((result (iar--format-mcp-servers '("custom-unknown"))))
    (should (stringp result))
    (should (string-match-p "custom-unknown:" result))
    (should (string-match-p "unknown type" result))))

;;; --- Session lifecycle tests ---

(ert-deftest test-mcp-setup-session-no-servers ()
  "iar-mcp-setup-session does nothing when server-names is nil."
  (let ((iar-mcp-auto-start t)
        (started nil))
    ;; Mock iar--mcp-start-servers to track if it was called
    (cl-letf (((symbol-function 'iar--mcp-start-servers)
               (lambda (names &optional callback)
                 (setq started names)
                 (when callback (funcall callback)))))
      (iar-mcp-setup-session nil)
      (should (null started)))))

(ert-deftest test-mcp-setup-session-auto-start-disabled ()
  "iar-mcp-setup-session does nothing when auto-start is nil."
  (let ((iar-mcp-auto-start nil)
        (started nil))
    (cl-letf (((symbol-function 'iar--mcp-start-servers)
               (lambda (names &optional callback)
                 (setq started names)
                 (when callback (funcall callback)))))
      (iar-mcp-setup-session '("burp"))
      (should (null started)))))

(provide 'test-mcp-setup)

;;; --- Additional coverage tests ---

(ert-deftest test-mcp-start-servers-no-config ()
  "iar--mcp-start-servers should return nil when no servers configured."
  (let ((iar-mcp-servers nil))
    (should (null (iar--mcp-start-servers '("unknown"))))
    (should (null (iar--mcp-start-servers nil)))))

(ert-deftest test-mcp-start-servers-with-config ()
  "iar--mcp-start-servers should start servers and return t."
  (let ((iar-mcp-servers '(("test-server" . (:url "http://localhost:9876/sse"))))
        (mcp-hub-servers nil)
        (start-called nil))
    (cl-letf (((symbol-function 'mcp-hub-start-all-server)
               (lambda (cb)
                 (setq start-called t)
                 (when cb (funcall cb)))))
      (let ((callback-called nil))
        (let ((result (iar--mcp-start-servers '("test-server")
                                               (lambda () (setq callback-called t)))))
          (should (eq t result))
          (should start-called)
          (should callback-called)
          (should mcp-hub-servers))))))

(ert-deftest test-mcp-activate-tools ()
  "iar--mcp-activate-tools should add tools to gptel-tools."
  (with-temp-buffer
    (let ((gptel-tools nil)
          (tool (gptel-make-tool
                 :name "test-mcp-act"
                 :description "test"
                 :args nil
                 :function (lambda () "result")))
          (iar--mcp-tools-registered nil))
      (iar--mcp-activate-tools (list tool))
      (should (member tool gptel-tools))
      (should (member tool iar--mcp-tools-registered)))))

(ert-deftest test-mcp-activate-tools-no-duplicates ()
  "iar--mcp-activate-tools should not add duplicate tools."
  (with-temp-buffer
    (let ((gptel-tools nil)
          (tool (gptel-make-tool
                 :name "test-mcp-dup"
                 :description "test"
                 :args nil
                 :function (lambda () "result")))
          (iar--mcp-tools-registered nil))
      (iar--mcp-activate-tools (list tool))
      (iar--mcp-activate-tools (list tool))
      (should (= 1 (length gptel-tools))))))

(ert-deftest test-mcp-deactivate-tools ()
  "iar--mcp-deactivate-tools should remove MCP tools from gptel-tools."
  (with-temp-buffer
    (let ((tool (gptel-make-tool
                 :name "test-mcp-rem"
                 :description "test"
                 :args nil
                 :function (lambda () "result")))
          (gptel-tools nil)
          (iar--mcp-tools-registered nil))
      (iar--mcp-activate-tools (list tool))
      (should (member tool gptel-tools))
      (iar--mcp-deactivate-tools)
      (should-not (member tool gptel-tools))
      (should (null iar--mcp-tools-registered)))))

(ert-deftest test-mcp-deactivate-no-tools ()
  "iar--mcp-deactivate-tools should handle nil registered tools."
  (with-temp-buffer
    (let ((iar--mcp-tools-registered nil))
      (iar--mcp-deactivate-tools)
      (should t))))

(provide 'test-mcp-setup)
;;; test-mcp-setup.el ends here
