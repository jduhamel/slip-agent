;;;; 02-streaming.lisp — consume the :stream channel chunk by chunk.
;;;;
;;;; Usage (from the slip repo root):
;;;;
;;;;   ANTHROPIC_API_KEY=sk-ant-... \
;;;;     go run cmd/slip/main.go plugins/slip-agent/examples/02-streaming.lisp
;;;;
;;;; Without an API key, fake-chat-model streams character-by-character
;;;; so you can still see the gi:range consumption pattern.

(require 'agent "plugins/slip-agent")

(defun pick-model ()
  (cond ((getenv "ANTHROPIC_API_KEY")
         (init-chat-model "claude-haiku-4-5" :max-tokens 100))
        (t
         (fake-chat-model
          :scripted-responses
          (list (ai-message :content "Streaming output, one character at a time."))))))

(let* ((model (pick-model))
       (channel (send model :stream
                      (list (human-message "Tell me a single short sentence about Lisp.")))))
  ;; gi:range iterates the channel until it closes; each chunk is an
  ;; ai-message-chunk whose :content is the incremental text.
  (range (lambda (chunk)
           (format t "~A" (send chunk :content)))
         channel)
  (format t "~%"))
