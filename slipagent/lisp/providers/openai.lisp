;;;; providers/openai.lisp — chat-openai provider.
;;;;
;;;; OpenAI Chat Completions API.  Wire format:
;;;;
;;;;   POST https://api.openai.com/v1/chat/completions
;;;;   Authorization: Bearer <key>
;;;;   Content-Type: application/json
;;;;
;;;;   {
;;;;     "model": "gpt-4o",
;;;;     "messages": [...],            ; OpenAI shape per message->bag
;;;;     "temperature": 0.7,
;;;;     "max_tokens": 1024,
;;;;     "tools": [...],
;;;;     "response_format": {"type": "json_schema", "json_schema": {...}},
;;;;     "stream": true
;;;;   }
;;;;
;;;; D1's message->bag and D6's tool->openai-spec already produce the
;;;; OpenAI shapes, so request construction is mostly composition.
;;;;
;;;; Structured output: chat-openai overrides :with-structured-output
;;;; to use OpenAI's native response_format: json_schema instead of
;;;; the synthetic terminal-tool trick (which providers without native
;;;; support — Anthropic, Ollama — fall back to in D12).

(defun openai-default-base-url () "https://api.openai.com/v1/chat/completions")

(defflavor chat-openai
    ((response-format nil) (poster nil) (stream-poster nil))
    (chat-model)
  :gettable-instance-variables
  :settable-instance-variables
  :initable-instance-variables
  (:documentation
   "OpenAI Chat Completions API provider.  api-key is read from the
slot or the OPENAI_API_KEY environment variable.  base-url defaults
to api.openai.com but can be overridden for OpenAI-compatible
endpoints (Ollama, Together, Fireworks, etc.).

response-format is a defstruct symbol or a literal JSON Schema bag
for native structured output; nil disables it.

poster and stream-poster are test-injection seams; production code
leaves them nil."))

(defmethod (chat-openai :copy) ()
  (make-instance 'chat-openai
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

;;; ----------------------------------------------------------------------
;;; Request body construction
;;; ----------------------------------------------------------------------

(defun build-openai-request
    (model messages tools max-tokens temperature streaming-p response-format)
  "Construct the JSON request body bag for the OpenAI Chat Completions API."
  (let ((body (make-bag "{}")))
    (bag-set body model "model")
    (when max-tokens
      (bag-set body max-tokens "max_tokens"))
    (when temperature
      (bag-set body temperature "temperature"))
    (when streaming-p
      (bag-set body t "stream"))
    ;; messages: serialise each via D1's OpenAI-shape message->bag.
    (let ((msg-list nil))
      (dolist (m messages)
        (push (send (message->bag m) :native) msg-list))
      (bag-set body (nreverse msg-list) "messages"))
    ;; tools
    (when tools
      (let ((tool-list nil))
        (dolist (tool tools)
          (push (send (tool->openai-spec tool) :native) tool-list))
        (bag-set body (nreverse tool-list) "tools")))
    ;; response_format for structured output
    (when response-format
      (bag-set body (build-openai-response-format response-format)
               "response_format"))
    body))

(defun build-openai-response-format (schema)
  "Build the response_format object.  schema is either a bag-flavor
(used directly as the JSON Schema) or a defstruct symbol (v0.1 emits
a minimal schema based on the symbol name; full slot introspection
arrives with v0.2 type coercion)."
  (let ((rf (make-bag "{}")))
    (bag-set rf "json_schema" "type")
    (let ((js (make-bag "{}"))
          (full-schema (cond ((typep schema 'bag-flavor) schema)
                             (t (make-bag "{type: object additionalProperties: false}")))))
      (bag-set js (cond ((symbolp schema) (symbol-name schema))
                        (t "structured_output"))
               "name")
      (bag-set js full-schema "schema")
      (bag-set js t "strict")
      (bag-set rf js "json_schema"))
    rf))

;;; ----------------------------------------------------------------------
;;; Response parsing
;;; ----------------------------------------------------------------------

(defun parse-openai-response (response-bag)
  "Convert an OpenAI Chat Completions response bag into an ai-message.
Tool calls are converted to tool-use-blocks and merged with text into
a content-block list (or a bare string when no tool calls).  D1's
bag->message handles this shape but only returns text-block + tool-use
blocks; we add response-metadata + usage on top."
  (let* ((choices (send response-bag :get "choices"))
         (choice  (cond ((listp choices) (car choices))
                        (t nil)))
         (message-alist (cond ((null choice) nil)
                              (t (cdr (assoc "message" choice :test #'equal)))))
         (text          (cdr (assoc "content" message-alist :test #'equal)))
         (tool-calls    (cdr (assoc "tool_calls" message-alist :test #'equal)))
         (finish-reason (cdr (assoc "finish_reason" choice :test #'equal)))
         (content       (cond
                          ((and (zerop-or-nil text) (null tool-calls)) "")
                          ((null tool-calls) text)
                          (t
                           (let ((blocks nil))
                             (when (and text (> (length text) 0))
                               (push (text-block text) blocks))
                             (dolist (tc tool-calls)
                               (push (openai-bag->tool-use-block tc) blocks))
                             (nreverse blocks))))))
    (ai-message
     :content           content
     :id                (send response-bag :get "id")
     :response-metadata (list (cons :model         (send response-bag :get "model"))
                              (cons :finish-reason finish-reason))
     :usage             (parse-openai-usage (send response-bag :get "usage")))))

(defun zerop-or-nil (s)
  "True if s is nil or a zero-length string."
  (or (null s) (zerop (length s))))

(defun parse-openai-usage (usage-alist)
  "Convert OpenAI usage block to keyword-keyed alist."
  (cond ((null usage-alist) nil)
        (t (list
            (cons :input-tokens
                  (cdr (assoc "prompt_tokens"     usage-alist :test #'equal)))
            (cons :output-tokens
                  (cdr (assoc "completion_tokens" usage-alist :test #'equal)))
            (cons :total-tokens
                  (cdr (assoc "total_tokens"      usage-alist :test #'equal)))))))

;;; ----------------------------------------------------------------------
;;; Streaming frame -> chunk
;;; ----------------------------------------------------------------------

(defun openai-frame-to-chunk (frame)
  "Convert an OpenAI SSE frame (cons \"message\" bag) into an
ai-message-chunk, or nil for frames with no user-visible delta.

Each chunk has choices[0].delta with optional content + tool_calls."
  (let* ((bag    (cdr frame))
         (choices (send bag :get "choices"))
         (choice  (cond ((listp choices) (car choices))
                        (t nil)))
         (delta-alist  (cond ((null choice) nil)
                             (t (cdr (assoc "delta" choice :test #'equal)))))
         (content      (cond ((null delta-alist) nil)
                             (t (cdr (assoc "content" delta-alist :test #'equal)))))
         (finish-reason (cond ((null choice) nil)
                              (t (cdr (assoc "finish_reason" choice :test #'equal))))))
    (cond
      ;; Normal text delta.
      ((and content (> (length content) 0))
       (ai-message-chunk :content content))
      ;; End-of-stream marker — surface finish_reason in metadata.
      (finish-reason
       (ai-message-chunk
        :content ""
        :response-metadata (list (cons :finish-reason finish-reason))))
      ;; Other deltas (role-only, tool-call partials) — drop in v0.1.
      (t nil))))

;;; ----------------------------------------------------------------------
;;; :invoke-impl and :stream-impl
;;; ----------------------------------------------------------------------

(defmethod (chat-openai :invoke-impl) (messages &rest config)
  (declare (ignore config))
  (let* ((url     (or base-url (openai-default-base-url)))
         (key     (resolve-api-key self "OPENAI_API_KEY"))
         (body    (build-openai-request
                   model messages tools max-tokens temperature nil response-format))
         (headers (list (cons "Authorization" (concatenate 'string "Bearer " key))))
         (response-bag (cond (poster (funcall poster url headers body))
                             (t (post-json url headers body)))))
    (parse-openai-response response-bag)))

(defmethod (chat-openai :stream-impl) (messages &rest config)
  (declare (ignore config))
  (let* ((url     (or base-url (openai-default-base-url)))
         (key     (resolve-api-key self "OPENAI_API_KEY"))
         (body    (build-openai-request
                   model messages tools max-tokens temperature t response-format))
         (headers (list (cons "Authorization" (concatenate 'string "Bearer " key))))
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

;;; ----------------------------------------------------------------------
;;; :with-structured-output — OpenAI native JSON Schema mode
;;;
;;; Returns a wrapping runnable: the chat-openai instance gets its
;;; response-format slot set; the result is piped through a
;;; bag-output-parser that the caller can configure with a coerce-fn.
;;; ----------------------------------------------------------------------

(defmethod (chat-openai :with-structured-output) (schema-name &key into)
  (let ((configured (send self :copy)))
    (setf (send configured :response-format) schema-name)
    (cond (into (pipe configured (bag-output-parser :into into)))
          (t   (pipe configured (bag-output-parser))))))

;;; ----------------------------------------------------------------------
;;; Constructor
;;; ----------------------------------------------------------------------

(defun chat-openai (&key (model "gpt-4o") temperature max-tokens
                         tools api-key base-url response-format
                         poster stream-poster)
  "Construct a chat-openai chat-model.  api-key falls back to the
OPENAI_API_KEY env var; base-url defaults to api.openai.com but can
be pointed at any OpenAI-compatible endpoint."
  (make-instance 'chat-openai
                 :model           model
                 :temperature     temperature
                 :max-tokens      max-tokens
                 :tools           tools
                 :api-key         api-key
                 :base-url        base-url
                 :response-format response-format
                 :poster          poster
                 :stream-poster   stream-poster))

;;; ----------------------------------------------------------------------
;;; Exports
;;; ----------------------------------------------------------------------

(export 'chat-openai)
(export 'openai-default-base-url)
(export 'build-openai-request)
(export 'build-openai-response-format)
(export 'parse-openai-response)
(export 'parse-openai-usage)
(export 'openai-frame-to-chunk)
(export 'zerop-or-nil)
