;;;; composition_test.lisp — pipe, parallel, branch, passthrough.

(let ((suite (defsuite "composition" agent-suite)))

  ;; ---- passthrough -------------------------------------------------------

  (deftest "passthrough returns input unchanged" suite
    (assert-equal 7 (send (passthrough) :invoke 7))
    (assert-equal "hi" (send (passthrough) :invoke "hi")))

  ;; ---- pipe (runnable-sequence) -----------------------------------------

  (deftest "pipe of two runnables threads input forward" suite
    (let ((p (pipe (runnable-lambda (lambda (x) (* x 2)))
                   (runnable-lambda (lambda (x) (+ x 1))))))
      (assert-equal 7 (send p :invoke 3))))

  (deftest "pipe of three runnables composes left-to-right" suite
    (let ((p (pipe (runnable-lambda (lambda (x) (+ x 1)))
                   (runnable-lambda (lambda (x) (* x 10)))
                   (runnable-lambda (lambda (x) (- x 5))))))
      ;; (3+1)*10 - 5 = 35
      (assert-equal 35 (send p :invoke 3))))

  (deftest "pipe with passthrough is identity in that slot" suite
    (let ((p (pipe (passthrough)
                   (runnable-lambda (lambda (x) (* x 2))))))
      (assert-equal 8 (send p :invoke 4))))

  (deftest "empty pipe panics on :invoke" suite
    (assert-panic (send (pipe) :invoke 1)))

  (deftest "pipe :batch loops :invoke per input" suite
    (let ((p (pipe (runnable-lambda (lambda (x) (+ x 1)))
                   (runnable-lambda (lambda (x) (* x 2))))))
      (assert-equal '(4 6 8) (send p :batch '(1 2 3)))))

  (deftest "pipe fires chain events on outer sequence and inner steps" suite
    (let* ((h (make-instance 'recording-handler))
           (p (pipe (runnable-lambda (lambda (x) (+ x 1)))
                    (runnable-lambda (lambda (x) (* x 2))))))
      (send p :invoke 4 :callbacks (list h))
      ;; Outer sequence fires start+end; each of the 2 inner steps
      ;; fires start+end.  Total 6 events.
      (assert-equal 6 (length (send h :events)))))

  ;; ---- parallel (runnable-parallel) -------------------------------------

  (deftest "parallel runs each runnable on the same input" suite
    (let* ((double (runnable-lambda (lambda (x) (* x 2))))
           (square (runnable-lambda (lambda (x) (* x x))))
           (p (parallel (list (cons :double double) (cons :square square))))
           (result (send p :invoke 5)))
      (assert-equal 10 (cdr (assoc :double result)))
      (assert-equal 25 (cdr (assoc :square result)))))

  (deftest "parallel preserves alist key order in result" suite
    (let* ((p (parallel (list (cons :a (runnable-lambda (lambda (x) x)))
                              (cons :b (runnable-lambda (lambda (x) x)))
                              (cons :c (runnable-lambda (lambda (x) x))))))
           (result (send p :invoke 1))
           (keys nil))
      (dolist (pair result) (push (car pair) keys))
      (assert-equal '(:a :b :c) (nreverse keys))))

  (deftest "parallel with passthrough fans the input alongside transforms" suite
    ;; The classic RAG shape: (parallel `((:context . retriever)
    ;;                                    (:question . ,(passthrough))))
    (let* ((retriever (runnable-lambda (lambda (q)
                                         (concatenate 'string "docs-for:" q))))
           (p (parallel (list (cons :context  retriever)
                              (cons :question (passthrough)))))
           (result (send p :invoke "what is X")))
      (assert-equal "docs-for:what is X" (cdr (assoc :context result)))
      (assert-equal "what is X" (cdr (assoc :question result)))))

  (deftest "parallel propagates a child panic" suite
    (let ((p (parallel (list (cons :ok  (runnable-lambda (lambda (x) x)))
                             (cons :bad (runnable-lambda
                                         (lambda (x) (declare (ignore x))
                                           (panic "child failed"))))))))
      (assert-panic (send p :invoke 1))))

  ;; ---- branch (runnable-branch) -----------------------------------------

  (deftest "branch picks first matching predicate" suite
    (let ((b (branch (list
                       (list #'integerp (runnable-lambda
                                          (lambda (x) (* x 10))))
                       (list #'stringp  (runnable-lambda
                                          (lambda (x)
                                            (concatenate 'string "s:" x))))))))
      (assert-equal 30   (send b :invoke 3))
      (assert-equal "s:hi" (send b :invoke "hi"))))

  (deftest "branch falls through to default when no predicate matches" suite
    (let ((b (branch (list
                       (list #'stringp (runnable-lambda
                                         (lambda (x) (concatenate 'string "s:" x)))))
                     (runnable-lambda (lambda (x) (list :default x))))))
      (assert-equal '(:default 42) (send b :invoke 42))))

  (deftest "branch panics when nothing matches and no default" suite
    (let ((b (branch (list (list #'stringp (runnable-lambda
                                             (lambda (x) x)))))))
      (assert-panic (send b :invoke 42))))

  (deftest "branch :stream delegates to the chosen runnable" suite
    (let* ((b  (branch (list (list #'integerp
                                   (runnable-lambda (lambda (x) (* x 100)))))))
           (ch (send b :stream 5))
           (chunks nil))
      (range (lambda (v) (push v chunks)) ch)
      (assert-equal '(500) (nreverse chunks)))))
