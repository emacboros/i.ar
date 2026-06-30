;; -*- lexical-binding: t; -*-

;; Emacboros --- gptel configuration
;; Copyright (C) 2026 Ignacio Agustín Randazzo
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.


(setq emacboros-gptel-backend
      (gptel-make-ollama "Ollama"
                         :host "10.66.0.3:11434"
                         :stream t
                         :models '("north-mini-code-1.0:q8_0"
                                   "granite4.1:8b-q8_0"
                                   "gpt-oss:20b"
                                   "gpt-oss:120b"
                                   "mistral-medium-3.5:128b"
                                   "nemotron-3-super:120b"
                                   "nemotron-3-ultra:cloud"
                                   "glm-5.2:cloud")
                         :request-params '(:options (
                                          :temperature 0.7
                                          :top_p 0.95
                                          :num_ctx 1048576
                                          :num_predict 65536
                                        ))))


(setq emacboros-gptel-default-model 'glm-5.2:cloud)
