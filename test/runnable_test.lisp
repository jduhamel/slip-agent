;;;; runnable_test.lisp — runnable, runnable-lambda, and event firing.

(let ((suite (defsuite "runnable" agent-suite)))

  ;; ---- runnable-lambda ---------------------------------------------------

  (deftest "runnable-lambda :invoke calls the wrapped function" suite
    (let ((r (runnable-lambda (lambda (x) (+ x 1)))))
      (assert-equal 6 (send r :invoke 5))))

  (deftest "runnable-lambda :invoke with string transformation" suite
    (let ((r (runnable-lambda (lambda (s) (concatenate 'string s "!")))))
      (assert-equal "hi!" (send r :invoke "hi"))))

  (deftest "runnable-lambda ignores config plist" suite
    (let ((r (runnable-lambda (lambda (x) x))))
      (assert-equal 7 (send r :invoke 7 :tags '(:debug) :metadata '((a . 1))))))

  ;; ---- :batch default ----------------------------------------------------

  (deftest "default :batch loops :invoke-impl over inputs" suite
    (let ((r (runnable-lambda (lambda (x) (* x 2)))))
      (assert-equal '(2 4 6) (send r :batch '(1 2 3)))))

  (deftest ":batch with empty list returns empty list" suite
    (let ((r (runnable-lambda (lambda (x) x))))
      (assert-nil (send r :batch nil))))

  ;; ---- :stream default ---------------------------------------------------

  (deftest "default :stream returns a channel with a single chunk" suite
    (let* ((r  (runnable-lambda (lambda (x) (* x 10))))
           (ch (send r :stream 4))
           (chunks nil))
      (range (lambda (v) (push v chunks)) ch)
      (assert-equal '(40) (nreverse chunks))))

  ;; ---- callback firing through :invoke ----------------------------------

  (deftest ":invoke fires :on-chain-start and :on-chain-end" suite
    (let* ((h (make-instance 'recording-handler))
           (r (runnable-lambda (lambda (x) (+ x 100)))))
      (assert-equal 105 (send r :invoke 5 :callbacks (list h)))
      (let ((events (nreverse (send h :events))))
        (assert-equal 2 (length events))
        (assert-equal :on-chain-start (car (car events)))
        (assert-equal :on-chain-end   (car (cadr events)))
        ;; :on-chain-end carries (list input output)
        (let ((end-data (cdr (cadr events))))
          (assert-equal 5   (car end-data))
          (assert-equal 105 (cadr end-data))))))

  (deftest ":invoke fires :on-chain-error and re-raises on panic" suite
    (let* ((h (make-instance 'recording-handler))
           (r (runnable-lambda (lambda (x) (declare (ignore x))
                                 (panic "tool died")))))
      (assert-panic (send r :invoke 1 :callbacks (list h)))
      (let ((events (nreverse (send h :events))))
        ;; Expect start then error; no end.
        (assert-equal 2 (length events))
        (assert-equal :on-chain-start (car (car events)))
        (assert-equal :on-chain-error (car (cadr events))))))

  (deftest ":batch fires chain events once per :batch call" suite
    (let* ((h (make-instance 'recording-handler))
           (r (runnable-lambda (lambda (x) (* x 3)))))
      (send r :batch '(1 2 3) :callbacks (list h))
      (let ((events (nreverse (send h :events))))
        ;; Default :batch-impl loops :invoke-impl, NOT :invoke — so
        ;; the per-element :invoke template does not run.  Only the
        ;; outer :batch fires events.
        (assert-equal 2 (length events))
        (assert-equal :on-chain-start (car (car events)))
        (assert-equal :on-chain-end   (car (cadr events))))))

  (deftest ":stream fires :on-chain-start synchronously and :on-chain-end after drain" suite
    (let* ((h  (make-instance 'recording-handler))
           (r  (runnable-lambda (lambda (x) (* x 2))))
           (ch (send r :stream 21 :callbacks (list h))))
      ;; Drain the channel.
      (range (lambda (v) (declare (ignore v)) nil) ch)
      ;; After drain, both events should be recorded.  Order: start
      ;; fires synchronously inside :stream; end fires from the
      ;; producer routine after the channel closes.
      (let ((events (nreverse (send h :events))))
        (assert-equal 2 (length events))
        (assert-equal :on-chain-start (car (car events)))
        (assert-equal :on-chain-end   (car (cadr events)))))))
