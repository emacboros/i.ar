;; -*- lexical-binding: t; -*-

;;; Tests for iar-gptel-setup.el
;; Tests that the gptel backend is configured correctly.

(require 'ert)
(require 'cl-lib)
(require 'subr-x)

(ert-deftest test-gptel-backend-defined ()
  "gptel-setup should define a default gptel-backend."
  (should (boundp 'gptel-backend))
  (should gptel-backend))

(ert-deftest test-gptel-model-defined ()
  "gptel-setup should define a default gptel-model."
  (should (boundp 'gptel-model))
  (should gptel-model))

(ert-deftest test-gptel-backend-is-ollama ()
  "gptel-setup should use an Ollama backend."
  (should (string-match-p "[Oo]llama"
                          (format "%s" (type-of gptel-backend)))))

(ert-deftest test-gptel-backend-host-is-configured ()
  "gptel-setup should point at a reachable Ollama host.
The host is configured from EMACBOROS_OLLAMA_HOST env var or defaults
to localhost:11434. We verify the host is a non-empty string with a port."
  (let ((host (gptel-backend-host gptel-backend)))
    (should (stringp host))
    (should (> (length host) 0))
    ;; Host should contain a port number (e.g., "localhost:11434")
    (should (string-match-p ":[0-9]+\\'" host))))

(ert-deftest test-gptel-no-think-env-var-off ()
  "Without EMACBOROS_OLLAMA_NO_THINK, request-params must not contain :think."
  (let ((process-environment
         (cons "EMACBOROS_OLLAMA_NO_THINK="
               (cl-remove-if (lambda (env)
                               (string-prefix-p "EMACBOROS_OLLAMA_NO_THINK=" env))
                             process-environment))))
    (load (expand-file-name "gptel.el"
                            (expand-file-name "configs" user-emacs-directory))
          nil t)
    (should (null iar-ollama-no-think))
    (should (null (plist-get (gptel-backend-request-params iar-gptel-backend)
                             :think)))))

(ert-deftest test-gptel-no-think-env-var-on ()
  "With EMACBOROS_OLLAMA_NO_THINK=1, request-params must contain :think :json-false."
  (let ((process-environment
         (cons "EMACBOROS_OLLAMA_NO_THINK=1"
               (cl-remove-if (lambda (env)
                               (string-prefix-p "EMACBOROS_OLLAMA_NO_THINK=" env))
                             process-environment))))
    (load (expand-file-name "gptel.el"
                            (expand-file-name "configs" user-emacs-directory))
          nil t)
    (should iar-ollama-no-think)
    (should (eq :json-false
                (plist-get (gptel-backend-request-params iar-gptel-backend)
                           :think)))))

(ert-deftest test-gptel-no-think-payload ()
  "gptel--request-data must merge :think :json-false into the JSON payload.
Reloading gptel.el creates a fresh backend, so gptel-backend/gptel-model
must be pointed at it before building the payload."
  (let ((process-environment
         (cons "EMACBOROS_OLLAMA_NO_THINK=1"
               (cl-remove-if (lambda (env)
                               (string-prefix-p "EMACBOROS_OLLAMA_NO_THINK=" env))
                             process-environment))))
    (load (expand-file-name "gptel.el"
                            (expand-file-name "configs" user-emacs-directory))
          nil t)
    (setq gptel-backend iar-gptel-backend)
    (setq gptel-model iar-gptel-default-model)
    (let* ((backend iar-gptel-backend)
           (data (gptel--request-data backend '("Say OK"))))
      (should (eq :json-false (plist-get data :think)))
      (should (string-match-p "\"think\":false" (json-encode data))))))

(ert-deftest test-gptel-no-think-quirk-alist ()
  "The quirk alist must be an alist of (model-name . warning-string)."
  (should (listp iar-ollama-no-think-quirks))
  (dolist (entry iar-ollama-no-think-quirks)
    (should (consp entry))
    (should (stringp (car entry)))
    (should (stringp (cdr entry)))))

(provide 'test-gptel)