;;;; callbacks_test.lisp — base-callback-handler dispatch and error modes.

;;; A handler that records every event it sees as (event-key . args).
(defflavor recording-handler ((events nil)) (base-callback-handler)
  :gettable-instance-variables
  :settable-instance-variables
  :initable-instance-variables
  (:documentation
   "Test handler that captures every event into the events slot."))

(defmethod (recording-handler :on-chain-start) (runnable input &rest config)
  (declare (ignore runnable config))
  (push (cons :on-chain-start input) events))

(defmethod (recording-handler :on-chain-end) (runnable input output &rest config)
  (declare (ignore runnable config))
  (push (cons :on-chain-end (list input output)) events))

(defmethod (recording-handler :on-chain-error) (runnable input condition &rest config)
  (declare (ignore runnable config))
  (push (cons :on-chain-error (list input condition)) events))

;;; A deliberately-broken handler that always panics.
(defflavor broken-handler () (base-callback-handler))

(defmethod (broken-handler :on-chain-start) (runnable input &rest config)
  (declare (ignore runnable input config))
  (panic "boom"))

(let ((suite (defsuite "callbacks" agent-suite)))

  (deftest "fire-event with no handlers is a no-op" suite
    ;; Fire with empty handlers list — should not panic, should return nil.
    (assert-nil (fire-event :on-chain-start nil "receiver" '("input") nil)))

  (deftest "fire-event dispatches to base no-op handlers without error" suite
    (let ((h (make-instance 'base-callback-handler)))
      (assert-nil (fire-event :on-chain-start (list h)
                              "receiver" '("input") nil))))

  (deftest "recording-handler captures :on-chain-start" suite
    (let ((h (make-instance 'recording-handler)))
      (fire-event :on-chain-start (list h) "receiver" '("hello") nil)
      (let ((events (send h :events)))
        (assert-equal 1 (length events))
        (assert-equal :on-chain-start (car (car events)))
        (assert-equal "hello" (cdr (car events))))))

  (deftest "fire-event dispatches to multiple handlers in order" suite
    (let ((h1 (make-instance 'recording-handler))
          (h2 (make-instance 'recording-handler)))
      (fire-event :on-chain-start (list h1 h2) "r" '("x") nil)
      (assert-equal 1 (length (send h1 :events)))
      (assert-equal 1 (length (send h2 :events)))))

  (deftest "swallow mode: panicking handler does not abort dispatch" suite
    ;; Default *callback-error-mode* is :swallow.  A broken handler
    ;; should not prevent later handlers from receiving the event.
    (let ((broken (make-instance 'broken-handler))
          (good   (make-instance 'recording-handler)))
      (fire-event :on-chain-start (list broken good) "r" '("y") nil)
      (assert-equal 1 (length (send good :events)))))

  (deftest "propagate mode: panicking handler aborts dispatch" suite
    (let ((broken (make-instance 'broken-handler))
          (good   (make-instance 'recording-handler))
          (saved-mode *callback-error-mode*))
      (setq *callback-error-mode* :propagate)
      (assert-panic
        (fire-event :on-chain-start (list broken good) "r" '("y") nil))
      (setq *callback-error-mode* saved-mode)
      ;; good should not have been reached
      (assert-equal 0 (length (send good :events))))))
