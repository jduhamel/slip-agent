;;;; embeddings/base.lisp — abstract embeddings flavor.
;;;;
;;;; Subclasses (fake-embeddings, openai-embeddings, voyage-embeddings)
;;;; implement :embed-query and :embed-documents.  Both are runnables;
;;;; :invoke-impl aliases :embed-query so embeddings compose with pipe.

(defflavor embeddings () (runnable)
  :abstract-flavor
  (:documentation
   "Abstract parent of all embeddings backends.  Concrete subclasses
override :embed-query (string -> vector) and :embed-documents
(list-of-strings -> list-of-vectors).  :invoke-impl maps to
:embed-query so an embeddings instance can be piped."))

(defmethod (embeddings :embed-query) (text)
  (declare (ignore text))
  (panic "embeddings :embed-query must be overridden by a concrete subclass"))

(defmethod (embeddings :embed-documents) (texts)
  ;; Default :embed-documents loops :embed-query.  Real backends with
  ;; batch endpoints (OpenAI, Voyage) override this for fewer round-
  ;; trips and a single usage charge.
  (let ((result nil))
    (dolist (text texts)
      (push (send self :embed-query text) result))
    (nreverse result)))

(defmethod (embeddings :invoke-impl) (input &rest config)
  (declare (ignore config))
  (send self :embed-query input))

(export 'embeddings)
