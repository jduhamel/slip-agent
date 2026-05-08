;;;; embeddings/voyage.lisp — Voyage AI embeddings provider.
;;;;
;;;; POST https://api.voyageai.com/v1/embeddings
;;;; Authorization: Bearer <key>
;;;; Body: {"model": "voyage-3", "input": ["text", ...]}
;;;; Response: {"object":"list","data":[{"object":"embedding","embedding":[...],"index":0}],"model":"...","usage":{"total_tokens":...}}
;;;;
;;;; Voyage's wire format is OpenAI-compatible enough that we reuse
;;;; the OpenAI parser; the differences are: input is always an array
;;;; (Voyage rejects bare strings), default model name, and the env
;;;; var name.

(defun voyage-embeddings-default-base-url ()
  "https://api.voyageai.com/v1/embeddings")

(defflavor voyage-embeddings
    ((model "voyage-3") (api-key nil) (base-url nil) (poster nil))
    (embeddings)
  :gettable-instance-variables
  :settable-instance-variables
  :initable-instance-variables
  (:documentation
   "Voyage AI embeddings provider.  api-key falls back to
VOYAGE_API_KEY; base-url defaults to api.voyageai.com.  Voyage
recommends voyage-3 for general-purpose, voyage-code-3 for code."))

(defmethod (voyage-embeddings :embed-query) (text)
  (car (send self :embed-documents (list text))))

(defmethod (voyage-embeddings :embed-documents) (texts)
  (let* ((url     (or base-url (voyage-embeddings-default-base-url)))
         (key     (resolve-api-key self "VOYAGE_API_KEY"))
         (body    (build-voyage-embeddings-request model texts))
         (headers (list (cons "Authorization"
                              (concatenate 'string "Bearer " key))))
         (response-bag (cond (poster (funcall poster url headers body))
                             (t (post-json url headers body)))))
    ;; Voyage's response shape matches OpenAI's exactly, so reuse the
    ;; parser.
    (parse-openai-embeddings-response response-bag)))

(defun build-voyage-embeddings-request (model texts)
  "Voyage requires input to always be an array, even for one text."
  (let ((body (make-bag "{}")))
    (bag-set body model "model")
    (bag-set body texts "input")
    body))

(defun voyage-embeddings (&key (model "voyage-3")
                               api-key base-url poster)
  (make-instance 'voyage-embeddings
                 :model    model
                 :api-key  api-key
                 :base-url base-url
                 :poster   poster))

(export 'voyage-embeddings)
(export 'voyage-embeddings-default-base-url)
(export 'build-voyage-embeddings-request)
