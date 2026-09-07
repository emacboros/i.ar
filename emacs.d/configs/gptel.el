;; -*- lexical-binding: t; -*-

;; =============================================================================
;; Ollama Backend Configuration
;; =============================================================================
;;
;; Configures the Ollama backend for gptel. Three things: determines
;; which host to connect to, creates the backend with available models
;; and request params, and picks the default model.
;;
;; Host is determined by: EMACBOROS_OLLAMA_HOST env var, or fallback
;; to localhost:11434. No hardcoded network topology in public repo
;; (GUIDELINES.org rule 52).
;;
;; Thinking control: EMACBOROS_OLLAMA_NO_THINK (set by iar.sh --no-think)
;; adds think:false to every request. Ollama >= 0.31 accepts the param
;; for all models, but per-model behavior varies (observed 2026-09-03):
;;   nemotron-3-super:120b -- honored, thinking suppressed
;;   gpt-oss:20b/120b      -- ignored, model thinks anyway
;;   glm-5.3:cloud         -- harmful: thinking leaks into content
;;   non-thinking models   -- no-op
;; Known quirks are warned about at startup (see iar-ollama-no-think-quirks).

(defvar iar-ollama-host nil
  "Ollama API host. Set from EMACBOROS_OLLAMA_HOST env var or
defaults to localhost.")

(defvar iar-gptel-backend nil
  "Ollama backend instance for gptel, configured at load time.")

(defvar iar-gptel-default-model nil
  "Default model symbol for gptel, configured at load time.")

(defvar iar-ollama-no-think nil
  "When non-nil, send think:false with every Ollama request.
Set from EMACBOROS_OLLAMA_NO_THINK env var (iar.sh --no-think flag).")

(defvar iar-ollama-no-think-quirks
  '(("glm-5.3:cloud" . "thinking leaks into content -- avoid --no-think with this model")
    ("glm-5.3-flash:cloud" . "same family as glm-5.3:cloud -- likely leaks (untested)")
    ("gpt-oss:20b" . "param ignored by the model -- it thinks anyway")
    ("gpt-oss:120b" . "param ignored by the model -- it thinks anyway"))
  "Alist of model name -> known quirk when think:false is sent.
Observed on Ollama 0.31.1 (2026-09-03). Update as behavior is observed.")

(defun iar--env-truthy-p (var)
  "Return non-nil if environment variable VAR is set to a non-empty value."
  (and (getenv var)
       (not (string-empty-p (getenv var)))))

(defun iar--gptel-request-params (no-think)
  "Build the Ollama :request-params plist.
When NO-THINK is non-nil, append think:false to disable model thinking
(for models that honor the toggle)."
  (let ((params
         `(:options (
                     :temperature 0.7
                     :top_p 0.90
                     :num_ctx ,(let ((ctx-str (getenv "EMACBOROS_OLLAMA_CTX"))
                                     (ctx-num 0))
                                 (when ctx-str
                                   (setq ctx-num (string-to-number ctx-str)))
                                 (if (> ctx-num 0) ctx-num 1048576))
                     :num_predict 65536
                     ))))
    (if no-think
        (append params '(:think :json-false))
      params)))

;; Determine Ollama host: check environment variable first, fall back to localhost.
(setq iar-ollama-host
      (or (getenv "EMACBOROS_OLLAMA_HOST")
          "localhost:11434"))

;; Determine thinking mode: EMACBOROS_OLLAMA_NO_THINK (set by iar.sh --no-think).
(setq iar-ollama-no-think (iar--env-truthy-p "EMACBOROS_OLLAMA_NO_THINK"))

(setq iar-gptel-backend
      (gptel-make-ollama "Ollama"
                         :host iar-ollama-host
                         :stream t
                         :models '("north-mini-code-1.0:q8_0"
                                   "granite4.1:8b-q8_0"
                                   "granite4.1:30b"
                                   "gpt-oss:20b"
                                   "gpt-oss:120b"
                                   "mistral-medium-3.5:128b"
                                   "nemotron-3-super:120b"
                                   "nemotron-3-ultra:cloud"
                                   "deepseek-v4-flash:cloud"
                                   "deepseek-v4-pro:cloud"
                                   "glm-5.3:cloud"
                                   "glm-5.3-flash:cloud")
                         :request-params (iar--gptel-request-params iar-ollama-no-think)))

;; Default model: check EMACBOROS_OLLAMA_MODEL env var first (set by
;; iar.sh --model flag), fall back to glm-5.3:cloud.
;;
;; The model MUST be in the :models list above. If it isn't, gptel will
;; error quickly -- this is intentional, it catches typos and models
;; that haven't been added to the config yet.
(setq iar-gptel-default-model
      (intern (or (getenv "EMACBOROS_OLLAMA_MODEL")
                  "glm-5.3:cloud")))

;; Report thinking mode at startup, including known per-model quirks.
(when iar-ollama-no-think
  (let ((quirk (cdr (assoc (format "%s" iar-gptel-default-model)
                           iar-ollama-no-think-quirks))))
    (if quirk
        (message "[gptel] WARNING: --no-think active, model %s: %s"
                 iar-gptel-default-model quirk)
      (message "[gptel] Thinking disabled (think:false) for model %s"
               iar-gptel-default-model))))

(provide 'iar-config-gptel)