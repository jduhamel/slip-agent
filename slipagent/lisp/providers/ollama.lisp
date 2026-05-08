;;;; providers/ollama.lisp — chat-ollama provider.
;;;;
;;;; Ollama exposes an OpenAI-compatible chat-completions endpoint
;;;; at http://localhost:11434/v1/chat/completions, so chat-ollama is
;;;; essentially chat-openai pointed at a different base-url with no
;;;; api-key required.  The constructor sets sane defaults.
;;;;
;;;; Quirks worth knowing (none enforced by v0.1):
;;;;   - some local models reject the system role (mistral does) —
;;;;     workaround is to merge system into the first user message.
;;;;   - tool-calling support varies by model; smaller models often
;;;;     return tool calls in the message content as text.
;;;;
;;;; If quirks need explicit handling, override :invoke-impl on a
;;;; subclass.  The base implementation is identical to chat-openai.

(defun ollama-default-base-url () "http://localhost:11434/v1/chat/completions")

(defflavor chat-ollama () (chat-openai)
  (:documentation
   "OpenAI-compatible chat-completions provider pointed at a local
Ollama daemon.  Defaults base-url to http://localhost:11434/v1 and
uses a placeholder api-key (Ollama ignores auth on localhost).

Inherits all chat-openai behaviour — request building, response
parsing, streaming, structured-output via response_format."))

(defmethod (chat-ollama :copy) ()
  (make-instance 'chat-ollama
                 :model           model
                 :temperature     temperature
                 :max-tokens      max-tokens
                 :tools           tools
                 :api-key         api-key
                 :base-url        base-url
                 :extra           extra
                 :response-format response-format
                 :poster          poster
                 :stream-poster   stream-poster))

;; resolve-api-key panics if neither slot nor env is set.  Override
;; :invoke-impl and :stream-impl to skip that check — Ollama doesn't
;; need a key on localhost.

(defmethod (chat-ollama :invoke-impl) (messages &rest config)
  (declare (ignore config))
  (let* ((url     (or base-url (ollama-default-base-url)))
         (body    (build-openai-request
                   model messages tools max-tokens temperature nil response-format))
         ;; Ollama accepts but does not require Authorization; pass a
         ;; dummy bearer so the header list is well-formed.
         (headers (list (cons "Authorization"
                              (concatenate 'string "Bearer "
                                           (or api-key "ollama")))))
         (response-bag (cond (poster (funcall poster url headers body))
                             (t (post-json url headers body)))))
    (parse-openai-response response-bag)))

(defmethod (chat-ollama :stream-impl) (messages &rest config)
  (declare (ignore config))
  (let* ((url     (or base-url (ollama-default-base-url)))
         (body    (build-openai-request
                   model messages tools max-tokens temperature t response-format))
         (headers (list (cons "Authorization"
                              (concatenate 'string "Bearer "
                                           (or api-key "ollama")))))
         (response (cond (stream-poster (funcall stream-poster url headers body))
                         (t (post-json-stream url headers body))))
         (sse-ch  (make-channel 64))
         (out-ch  (make-channel 64)))
    (run
      (recover err
        (progn (declare (ignore err)) (channel-close sse-ch))
        (parse-sse-stream (send response :body) sse-ch)))
    (run
      (recover err
        (progn (declare (ignore err)) (channel-close out-ch))
        (range (lambda (frame)
                 (let ((chunk (openai-frame-to-chunk frame)))
                   (when chunk (channel-push out-ch chunk))))
               sse-ch)
        (send response :close)
        (channel-close out-ch)))
    out-ch))

(defun chat-ollama (&key (model "llama3") temperature max-tokens
                         tools api-key base-url response-format
                         poster stream-poster)
  "Construct a chat-ollama instance.  Defaults model to llama3 and
base-url to http://localhost:11434/v1/chat/completions.  api-key is
optional (Ollama ignores it)."
  (make-instance 'chat-ollama
                 :model           model
                 :temperature     temperature
                 :max-tokens      max-tokens
                 :tools           tools
                 :api-key         api-key
                 :base-url        base-url
                 :response-format response-format
                 :poster          poster
                 :stream-poster   stream-poster))

(export 'chat-ollama)
(export 'ollama-default-base-url)
