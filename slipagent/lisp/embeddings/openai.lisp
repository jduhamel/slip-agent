;;;; embeddings/openai.lisp — OpenAI embeddings provider.
;;;;
;;;; POST https://api.openai.com/v1/embeddings
;;;; Body: {"model": "text-embedding-3-small", "input": "..." | [...]}
;;;; Response: {"data": [{"embedding": [...], "index": 0}, ...], "model": "...", "usage": {...}}

(defun openai-embeddings-default-base-url ()
  "https://api.openai.com/v1/embeddings")

(defflavor openai-embeddings
    ((model "text-embedding-3-small") (api-key nil) (base-url nil)
     (poster nil))
    (embeddings)
  :gettable-instance-variables
  :settable-instance-variables
  :initable-instance-variables
  (:documentation
   "OpenAI embeddings provider.  api-key falls back to OPENAI_API_KEY;
base-url defaults to api.openai.com but can be overridden for
OpenAI-compatible endpoints.  poster is a test-injection seam."))

(defmethod (openai-embeddings :embed-query) (text)
  (car (send self :embed-documents (list text))))

(defmethod (openai-embeddings :embed-documents) (texts)
  (let* ((url     (or base-url (openai-embeddings-default-base-url)))
         (key     (resolve-api-key self "OPENAI_API_KEY"))
         (body    (build-openai-embeddings-request model texts))
         (headers (list (cons "Authorization"
                              (concatenate 'string "Bearer " key))))
         (response-bag (cond (poster (funcall poster url headers body))
                             (t (post-json url headers body)))))
    (parse-openai-embeddings-response response-bag)))

(defun build-openai-embeddings-request (model texts)
  (let ((body (make-bag "{}")))
    (bag-set body model "model")
    (cond ((= (length texts) 1)
           (bag-set body (car texts) "input"))
          (t (bag-set body texts "input")))
    body))

(defun parse-openai-embeddings-response (bag)
  "Pull the embedding vectors out of an OpenAI embeddings response,
preserving index order."
  (let ((data (send bag :get "data"))
        (result nil))
    (dolist (entry data)
      (push (cdr (assoc "embedding" entry :test #'equal)) result))
    (nreverse result)))

(defun openai-embeddings (&key (model "text-embedding-3-small")
                               api-key base-url poster)
  (make-instance 'openai-embeddings
                 :model    model
                 :api-key  api-key
                 :base-url base-url
                 :poster   poster))

(export 'openai-embeddings)
(export 'openai-embeddings-default-base-url)
(export 'build-openai-embeddings-request)
(export 'parse-openai-embeddings-response)
