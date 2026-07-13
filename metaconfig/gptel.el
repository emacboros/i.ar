;; -*- lexical-binding: t; -*-

(defvar iar-ollama-host nil
  "Ollama API host. Set from EMACBOROS_OLLAMA_HOST env var or defaults to remote.")

(defvar iar-gptel-backend nil
  "Ollama backend instance for gptel, configured at load time.")

(defvar iar-gptel-default-model nil
  "Default model symbol for gptel, configured at load time.")

;; Determine Ollama host: check environment variable first, fall back to remote default.
(setq iar-ollama-host
      (or (getenv "EMACBOROS_OLLAMA_HOST")
          "10.66.0.5:11434"))

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
                                   "deepseek-v4-pro:cloud"
                                   "glm-5.2:cloud")
                         :request-params `(:options (
                                          :temperature 0.7
                                          :top_p 0.90
                                          :num_ctx ,(let ((ctx-str (getenv "EMACBOROS_OLLAMA_CTX"))
                                                          (ctx-num 0))
                                                      (when ctx-str
                                                        (setq ctx-num (string-to-number ctx-str)))
                                                      (if (> ctx-num 0) ctx-num 1048576))
                                          :num_predict 65536
                                        ))))

;; Default model: check EMACBOROS_OLLAMA_MODEL env var first (set by
;; agent_loop.sh --model flag), fall back to glm-5.2:cloud.
;;
;; The model MUST be in the :models list above. If it isn't, gptel will
;; error quickly -- this is intentional, it catches typos and models
;; that haven't been added to the config yet.
(setq iar-gptel-default-model
      (intern (or (getenv "EMACBOROS_OLLAMA_MODEL")
                  "glm-5.2:cloud")))
