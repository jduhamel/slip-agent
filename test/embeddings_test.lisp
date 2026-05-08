;;;; embeddings_test.lisp — fake, OpenAI, Voyage embeddings.

(let ((suite (defsuite "embeddings" agent-suite)))

  ;; ---- fake-embeddings --------------------------------------------------

  (deftest "fake-embeddings produces a fixed-dim vector" suite
    (let* ((emb (fake-embeddings))
           (vec (send emb :embed-query "hello")))
      (assert-equal 384 (length vec))))

  (deftest "fake-embeddings is deterministic" suite
    (let* ((emb (fake-embeddings))
           (a   (send emb :embed-query "hello"))
           (b   (send emb :embed-query "hello")))
      (assert-equal t (equal a b))))

  (deftest "fake-embeddings produces L2-normalized vectors" suite
    (let* ((emb (fake-embeddings))
           (vec (send emb :embed-query "the quick brown fox"))
           (sumsq 0.0))
      (dolist (v vec) (setq sumsq (+ sumsq (* v v))))
      ;; Norm should be very close to 1.0.
      (assert-equal t (and (> sumsq 0.99) (< sumsq 1.01)))))

  (deftest "fake-embeddings :embed-documents handles batch" suite
    (let* ((emb     (fake-embeddings))
           (vectors (send emb :embed-documents
                          (list "first" "second" "third"))))
      (assert-equal 3 (length vectors))
      (assert-equal 384 (length (car vectors)))))

  (deftest "fake-embeddings differ for different strings" suite
    (let* ((emb (fake-embeddings))
           (a   (send emb :embed-query "hello"))
           (b   (send emb :embed-query "goodbye")))
      (assert-equal t (not (equal a b)))))

  (deftest "fake-embeddings supports custom dim" suite
    (let* ((emb (fake-embeddings :dim 16))
           (vec (send emb :embed-query "x")))
      (assert-equal 16 (length vec))))

  ;; ---- openai-embeddings (replay) ---------------------------------------

  (deftest "openai-embeddings :embed-query returns the vector" suite
    (let* ((poster (recorded-poster "openai-embeddings" "embed-text"))
           (emb    (openai-embeddings :api-key "test" :poster poster))
           (vec    (send emb :embed-query "hello")))
      (assert-equal 5 (length vec))
      (assert-equal 0.1 (car vec))))

  (deftest "openai-embeddings :embed-documents preserves order" suite
    (let* ((poster (recorded-poster "openai-embeddings" "embed-batch"))
           (emb    (openai-embeddings :api-key "test" :poster poster))
           (vecs   (send emb :embed-documents (list "a" "b" "c"))))
      (assert-equal 3 (length vecs))
      ;; JSON float round-trip can introduce tiny precision drift
      ;; (0.7 -> 0.7000000000000001).  Use a tolerance.
      (assert-equal t (< (abs (- (car (car   vecs)) 0.1)) 0.001))
      (assert-equal t (< (abs (- (car (cadr  vecs)) 0.4)) 0.001))
      (assert-equal t (< (abs (- (car (caddr vecs)) 0.7)) 0.001))))

  (deftest "build-openai-embeddings-request unwraps single text" suite
    ;; OpenAI accepts both bare-string and array input; v0.1 sends a
    ;; bare string when there's only one to save bytes on the wire.
    (let ((body (build-openai-embeddings-request "text-embedding-3-small"
                                                 (list "hi"))))
      (assert-equal "hi" (send body :get "input"))))

  (deftest "build-openai-embeddings-request keeps array for batch" suite
    (let* ((body (build-openai-embeddings-request "text-embedding-3-small"
                                                  (list "a" "b")))
           (in   (send body :get "input")))
      (assert-equal t (listp in))
      (assert-equal 2 (length in))))

  (deftest "openai-embeddings :invoke-impl aliases to :embed-query" suite
    (let* ((poster (recorded-poster "openai-embeddings" "embed-text"))
           (emb    (openai-embeddings :api-key "test" :poster poster))
           (vec    (send emb :invoke "hello")))
      (assert-equal 5 (length vec))))

  ;; ---- voyage-embeddings (replay) ---------------------------------------

  (deftest "voyage-embeddings :embed-query returns the vector" suite
    (let* ((poster (recorded-poster "voyage-embeddings" "embed-text"))
           (emb    (voyage-embeddings :api-key "test" :poster poster))
           (vec    (send emb :embed-query "hello")))
      (assert-equal 4 (length vec))
      (assert-equal 0.11 (car vec))))

  (deftest "build-voyage-embeddings-request always uses array input" suite
    ;; Voyage rejects bare-string input — body.input must always be an
    ;; array.  Different from OpenAI.
    (let* ((body (build-voyage-embeddings-request "voyage-3" (list "hi")))
           (in   (send body :get "input")))
      (assert-equal t (listp in))
      (assert-equal 1 (length in))
      (assert-equal "hi" (car in))))

  (deftest "voyage-embeddings reuses OpenAI parser" suite
    ;; The Voyage and OpenAI response shapes are identical; verify
    ;; the parser is genuinely shared.
    (let ((bag (read-fixture "voyage-embeddings" "embed-text")))
      (let ((vecs (parse-openai-embeddings-response bag)))
        (assert-equal 1 (length vecs))
        (assert-equal 4 (length (car vecs))))))

  ;; ---- pipe composition -------------------------------------------------

  (deftest "fake-embeddings pipes as a runnable" suite
    ;; (pipe embeddings rl) — silly but exercises the runnable contract.
    (let* ((emb (fake-embeddings :dim 8))
           (chain (pipe emb (runnable-lambda #'length))))
      (assert-equal 8 (send chain :invoke "x")))))
