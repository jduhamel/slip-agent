;;;; vector-stores.lisp — vector-store abstract, in-memory impl, retriever.
;;;;
;;;; vector-store is the abstract base for any document index that
;;;; supports k-nearest-neighbour retrieval by cosine similarity.
;;;; in-memory-vector-store is a list-of-pairs implementation suitable
;;;; for tests and small corpora.
;;;;
;;;; vector-store-retriever is a runnable that wraps a vector-store
;;;; and an integer k; :invoke-impl returns the top-k documents for
;;;; a query string.  Fires :on-retriever-* events instead of
;;;; :on-chain-*.

;;; ----------------------------------------------------------------------
;;; vector-store abstract
;;; ----------------------------------------------------------------------

(defflavor vector-store ((embeddings nil)) ()
  :gettable-instance-variables
  :settable-instance-variables
  :initable-instance-variables
  :abstract-flavor
  (:documentation
   "Abstract vector-store base.  Concrete subclasses implement
:add-documents, :similarity-search, :as-retriever.  embeddings is
the embeddings instance used to vectorise both stored documents and
queries — both sides must use the same model for similarity to be
meaningful."))

(defmethod (vector-store :add-documents) (docs)
  (declare (ignore docs))
  (panic "vector-store :add-documents must be overridden"))

(defmethod (vector-store :similarity-search) (query &optional (k 4))
  (declare (ignore query k))
  (panic "vector-store :similarity-search must be overridden"))

(defmethod (vector-store :as-retriever) (&optional (k 4))
  "Default :as-retriever wraps the store in a vector-store-retriever
configured to return k documents."
  (make-instance 'vector-store-retriever :store self :k k))

;;; ----------------------------------------------------------------------
;;; in-memory-vector-store
;;; ----------------------------------------------------------------------

(defflavor in-memory-vector-store ((entries nil)) (vector-store)
  :gettable-instance-variables
  :settable-instance-variables
  :initable-instance-variables
  (:documentation
   "List-of-pairs vector store.  entries is a list of (document .
embedding-vector) cons cells.  Cosine-similarity search is O(n) over
the list — fine for tests and small corpora; production-scale use
should reach for a real index (faiss, qdrant, etc) via a downstream
plugin."))

(defmethod (in-memory-vector-store :add-documents) (docs)
  (let ((vectors (send embeddings :embed-documents
                       (let ((texts nil))
                         (dolist (d docs)
                           (push (send d :page-content) texts))
                         (nreverse texts))))
        (added   nil))
    (let ((doc-list  docs)
          (vec-list  vectors))
      (loop
        (when (or (null doc-list) (null vec-list)) (return nil))
        (let ((d (car doc-list)) (v (car vec-list)))
          (setq entries (cons (cons d v) entries))
          (push d added)
          (setq doc-list (cdr doc-list))
          (setq vec-list (cdr vec-list)))))
    (nreverse added)))

(defmethod (in-memory-vector-store :similarity-search) (query &optional (k 4))
  (let* ((query-vec (send embeddings :embed-query query))
         (scored    nil))
    (dolist (entry entries)
      (let* ((doc        (car entry))
             (doc-vec    (cdr entry))
             (similarity (cosine-similarity query-vec doc-vec)))
        (push (cons similarity doc) scored)))
    ;; Sort descending by similarity, then take the top k.
    (let ((sorted (sort scored (lambda (a b) (> (car a) (car b))))))
      (let ((result nil)
            (taken  0))
        (dolist (entry sorted)
          (when (< taken k)
            (push (cdr entry) result)
            (setq taken (1+ taken))))
        (nreverse result)))))

(defun cosine-similarity (a b)
  "Cosine similarity between two equal-length numeric vectors.
Returns 0 if either vector has zero norm."
  (let ((dot   0.0)
        (na    0.0)
        (nb    0.0)
        (a-list a)
        (b-list b))
    (loop
      (when (or (null a-list) (null b-list)) (return nil))
      (let ((av (car a-list)) (bv (car b-list)))
        (setq dot (+ dot (* av bv)))
        (setq na  (+ na  (* av av)))
        (setq nb  (+ nb  (* bv bv)))
        (setq a-list (cdr a-list))
        (setq b-list (cdr b-list))))
    (let ((denom (* (sqrt na) (sqrt nb))))
      (cond ((zerop denom) 0.0)
            (t (/ dot denom))))))

(defun in-memory-vector-store (&key embeddings documents)
  "Construct an in-memory-vector-store with the given embeddings
backend.  documents is an optional list of documents to add at
construction time."
  (let ((store (make-instance 'in-memory-vector-store :embeddings embeddings)))
    (when documents
      (send store :add-documents documents))
    store))

;;; ----------------------------------------------------------------------
;;; vector-store-retriever — runnable wrapper
;;; ----------------------------------------------------------------------

(defflavor vector-store-retriever ((store nil) (k 4)) (runnable)
  :gettable-instance-variables
  :settable-instance-variables
  :initable-instance-variables
  (:documentation
   "Runnable wrapper around a vector-store.  :invoke takes a query
string and returns the top-k documents.  Fires :on-retriever-start
/ :on-retriever-end / :on-retriever-error around the search."))

;; Override runnable :invoke to fire :on-retriever-* events.
(defmethod (vector-store-retriever :invoke) (input &rest config)
  (let ((handlers (getf config :callbacks)))
    (fire-event :on-retriever-start handlers self (list input) config)
    (recover err
      (progn
        (fire-event :on-retriever-error handlers self (list input err) config)
        (panic err))
      (let ((result (apply 'send self :invoke-impl input config)))
        (fire-event :on-retriever-end handlers self (list input result) config)
        result))))

(defmethod (vector-store-retriever :invoke-impl) (input &rest config)
  (declare (ignore config))
  (send store :similarity-search input k))

(defun vector-store-retriever (&key store (k 4))
  (make-instance 'vector-store-retriever :store store :k k))

(export 'in-memory-vector-store)
(export 'vector-store-retriever)
(export 'cosine-similarity)
