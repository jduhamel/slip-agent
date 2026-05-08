;;;; 01-chat.lisp — single-turn chat with init-chat-model.
;;;;
;;;; Usage (from the slip repo root):
;;;;
;;;;   ANTHROPIC_API_KEY=sk-ant-... \
;;;;     go run cmd/slip/main.go plugins/slip-agent/examples/01-chat.lisp
;;;;
;;;; Without an API key it falls back to fake-chat-model so the
;;;; example always runs.

(require 'agent "plugins/slip-agent")

(defun pick-model ()
  "Real model when ANTHROPIC_API_KEY is set, fake otherwise."
  (cond ((getenv "ANTHROPIC_API_KEY")
         (init-chat-model "claude-haiku-4-5"))
        (t
         (fake-chat-model
          :scripted-responses
          (list (ai-message :content "(no API key — this is the fake model talking)"))))))

(let* ((model (pick-model))
       (msg   (send model :invoke
                    (list (system-message "Be concise.")
                          (human-message "What is the capital of France?")))))
  (format t "~A~%" (message-text msg)))
