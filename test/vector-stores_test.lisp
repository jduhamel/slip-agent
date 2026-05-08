;;;; vector-stores_test.lisp — in-memory store + retriever.

;;; Recording handler for retriever events.
(defflavor recording-handler-retriever ((events nil)) (base-callback-handler)
  :gettable-instance-variables
  :settable-instance-variables
  :initable-instance-variables)

(defmethod (recording-handler-retriever :on-retriever-start) (r query &rest config)
  (declare (ignore r config))
  (push (cons :on-retriever-start query) events))

(defmethod (recording-handler-retriever :on-retriever-end) (r query docs &rest config)
  (declare (ignore r config))
  (push (cons :on-retriever-end (list query (length docs))) events))

(defmethod (recording-handler-retriever :on-retriever-error) (r query condition &rest config)
  (declare (ignore r query config))
  (push (cons :on-retriever-error condition) events))

(let ((suite (defsuite "vector-stores" agent-suite)))

  ;; ---- cosine-similarity ------------------------------------------------

  (deftest "cosine-similarity of identical vectors is 1.0" suite
    (assert-equal 1.0 (cosine-similarity '(1.0 0.0) '(1.0 0.0))))

  (deftest "cosine-similarity of orthogonal vectors is 0.0" suite
    (assert-equal 0.0 (cosine-similarity '(1.0 0.0) '(0.0 1.0))))

  (deftest "cosine-similarity of opposite vectors is -1.0" suite
    (assert-equal -1.0 (cosine-similarity '(1.0 0.0) '(-1.0 0.0))))

  (deftest "cosine-similarity returns 0 on zero-norm input" suite
    (assert-equal 0.0 (cosine-similarity '(0.0 0.0) '(1.0 1.0))))

  ;; ---- in-memory-vector-store -------------------------------------------

  (deftest "empty store returns no results" suite
    (let* ((emb   (fake-embeddings))
           (store (in-memory-vector-store :embeddings emb)))
      (assert-equal 0 (length (send store :similarity-search "anything")))))

  (deftest ":add-documents returns the documents added" suite
    (let* ((emb   (fake-embeddings))
           (store (in-memory-vector-store :embeddings emb))
           (docs  (list (document "alpha") (document "beta")))
           (added (send store :add-documents docs)))
      (assert-equal 2 (length added))))

  (deftest ":similarity-search returns up to k documents" suite
    (let* ((emb   (fake-embeddings))
           (store (in-memory-vector-store
                   :embeddings emb
                   :documents (list (document "alpha")
                                    (document "beta")
                                    (document "gamma")
                                    (document "delta")
                                    (document "epsilon")))))
      (let ((results (send store :similarity-search "alpha" 3)))
        (assert-equal 3 (length results)))))

  (deftest ":similarity-search ranks exact match first" suite
    ;; With fake-embeddings, a query identical to one of the stored
    ;; documents will score 1.0 against that doc and lower elsewhere,
    ;; so it should come back as #1.
    (let* ((emb   (fake-embeddings))
           (store (in-memory-vector-store
                   :embeddings emb
                   :documents (list (document "the quick brown fox")
                                    (document "completely unrelated text here")
                                    (document "another distinct entry")))))
      (let ((results (send store :similarity-search "the quick brown fox" 1)))
        (assert-equal 1 (length results))
        (assert-equal "the quick brown fox"
                      (send (car results) :page-content)))))

  (deftest ":similarity-search default k is 4" suite
    (let* ((emb   (fake-embeddings))
           (store (in-memory-vector-store
                   :embeddings emb
                   :documents (list (document "a") (document "b")
                                    (document "c") (document "d")
                                    (document "e") (document "f")))))
      (assert-equal 4 (length (send store :similarity-search "x")))))

  (deftest ":similarity-search preserves document metadata" suite
    (let* ((emb   (fake-embeddings))
           (store (in-memory-vector-store
                   :embeddings emb
                   :documents (list (document "doc-text"
                                              :metadata '((:src . "wiki")))))))
      (let ((result (car (send store :similarity-search "x"))))
        (assert-equal "wiki" (cdr (assoc :src (send result :metadata)))))))

  ;; ---- vector-store-retriever -------------------------------------------

  (deftest ":as-retriever returns a runnable" suite
    (let* ((emb   (fake-embeddings))
           (store (in-memory-vector-store :embeddings emb))
           (r     (send store :as-retriever)))
      (assert-equal t (typep r 'vector-store-retriever))
      (assert-equal t (typep r 'runnable))))

  (deftest "retriever :invoke returns top-k documents" suite
    (let* ((emb   (fake-embeddings))
           (store (in-memory-vector-store
                   :embeddings emb
                   :documents (list (document "first")
                                    (document "second")
                                    (document "third"))))
           (r     (send store :as-retriever 2)))
      (assert-equal 2 (length (send r :invoke "first")))))

  (deftest "retriever fires :on-retriever-start and :on-retriever-end" suite
    (let* ((emb   (fake-embeddings))
           (store (in-memory-vector-store
                   :embeddings emb
                   :documents (list (document "x") (document "y"))))
           (r     (send store :as-retriever 1))
           (h     (make-instance 'recording-handler-retriever)))
      (send r :invoke "x" :callbacks (list h))
      (let ((events (nreverse (send h :events))))
        (assert-equal 2 (length events))
        (assert-equal :on-retriever-start (car (car events)))
        (assert-equal :on-retriever-end   (car (cadr events))))))

  (deftest "retriever does NOT fire :on-chain-* events" suite
    (let* ((emb   (fake-embeddings))
           (store (in-memory-vector-store
                   :embeddings emb
                   :documents (list (document "x"))))
           (r     (send store :as-retriever))
           (h     (make-instance 'recording-handler)))
      (send r :invoke "x" :callbacks (list h))
      (assert-nil (send h :events))))

  ;; ---- end-to-end RAG composition ---------------------------------------

  (deftest "retriever pipes into a runnable-lambda for RAG fan-out" suite
    ;; The classic RAG shape — retriever feeds context into a chain.
    (let* ((emb   (fake-embeddings))
           (store (in-memory-vector-store
                   :embeddings emb
                   :documents (list (document "the answer is 42")
                                    (document "purple monkey dishwasher"))))
           (chain (pipe (send store :as-retriever 1)
                        (runnable-lambda
                         (lambda (docs)
                           (send (car docs) :page-content))))))
      (assert-equal "the answer is 42"
                    (send chain :invoke "the answer is 42")))))
