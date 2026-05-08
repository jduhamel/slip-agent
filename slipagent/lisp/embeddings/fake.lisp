;;;; embeddings/fake.lisp — deterministic embeddings for tests.
;;;;
;;;; Hashes the input string into a fixed-dim vector.  Same string
;;;; always produces the same vector; similar strings produce similar
;;;; vectors (per-character contribution to dimension i % dim).
;;;;
;;;; Not a meaningful semantic embedding — just enough to exercise the
;;;; vector-store machinery offline.  D11 tests use this; users
;;;; writing their own agent tests can use it for hermetic RAG.

(defflavor fake-embeddings ((dim 384)) (embeddings)
  :gettable-instance-variables
  :settable-instance-variables
  :initable-instance-variables
  (:documentation
   "Deterministic embeddings that hash strings into a fixed-dim
vector.  Same string -> same vector; different strings -> different
vectors with similarity proportional to character overlap."))

(defmethod (fake-embeddings :embed-query) (text)
  (fake-embed-string text dim))

(defmethod (fake-embeddings :embed-documents) (texts)
  (let ((result nil))
    (dolist (text texts)
      (push (fake-embed-string text dim) result))
    (nreverse result)))

(defun fake-embed-string (text dim)
  "Return a dim-dimensional vector representing text.  Each character
adds 1.0 to position (char-code mod dim); the resulting vector is
L2-normalized so cosine similarity is well-behaved."
  (let ((vec (make-list dim :initial-element 0.0)))
    (dotimes (i (length text))
      (let* ((c   (char text i))
             (idx (mod (char-code c) dim)))
        (setf (nth idx vec) (+ (nth idx vec) 1.0))))
    (l2-normalize vec)))

(defun l2-normalize (vec)
  "Return vec scaled so its L2 norm is 1.0 (or unchanged if norm is 0)."
  (let ((sumsq 0.0))
    (dolist (v vec)
      (setq sumsq (+ sumsq (* v v))))
    (let ((norm (sqrt sumsq)))
      (cond ((zerop norm) vec)
            (t (let ((result nil))
                 (dolist (v vec)
                   (push (/ v norm) result))
                 (nreverse result)))))))

(defun fake-embeddings (&key (dim 384))
  "Construct a fake-embeddings instance."
  (make-instance 'fake-embeddings :dim dim))

(export 'fake-embeddings)
(export 'fake-embed-string)
(export 'l2-normalize)
