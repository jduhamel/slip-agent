;;;; chat-models_test.lisp — chat-model abstract + fake-chat-model.

;;; Recording handler for :on-llm-* events.
(defflavor recording-handler-llm ((events nil)) (base-callback-handler)
  :gettable-instance-variables
  :settable-instance-variables
  :initable-instance-variables)

(defmethod (recording-handler-llm :on-llm-start) (model messages &rest config)
  (declare (ignore model config))
  (push (cons :on-llm-start messages) events))

(defmethod (recording-handler-llm :on-llm-end) (model response &rest config)
  (declare (ignore model config))
  (push (cons :on-llm-end response) events))

(defmethod (recording-handler-llm :on-llm-error) (model messages condition &rest config)
  (declare (ignore model messages config))
  (push (cons :on-llm-error condition) events))

(defmethod (recording-handler-llm :on-llm-new-token) (model token &rest config)
  (declare (ignore model config))
  (push (cons :on-llm-new-token token) events))

(let ((suite (defsuite "chat-models" agent-suite)))

  ;; ---- normalize-messages ------------------------------------------------

  (deftest "normalize-messages wraps a string in a human-message" suite
    (let ((msgs (normalize-messages "hi")))
      (assert-equal 1 (length msgs))
      (assert-equal "user" (message-role (car msgs)))
      (assert-equal "hi" (message-text (car msgs)))))

  (deftest "normalize-messages wraps a single message in a list" suite
    (let* ((m    (system-message "rules"))
           (msgs (normalize-messages m)))
      (assert-equal 1 (length msgs))
      (assert-equal "system" (message-role (car msgs)))))

  (deftest "normalize-messages passes a list through" suite
    (let* ((orig (list (system-message "x") (human-message "y")))
           (msgs (normalize-messages orig)))
      (assert-equal 2 (length msgs))))

  (deftest "normalize-messages panics on bad input" suite
    (assert-panic (normalize-messages 42)))

  ;; ---- fake-chat-model invoke -------------------------------------------

  (deftest "fake-chat-model returns scripted responses in order" suite
    (let* ((m (fake-chat-model
               :scripted-responses (list (ai-message :content "first")
                                         (ai-message :content "second")))))
      (assert-equal "first"  (message-text (send m :invoke "ignored")))
      (assert-equal "second" (message-text (send m :invoke "ignored")))))

  (deftest "fake-chat-model panics when scripted responses exhausted" suite
    (let ((m (fake-chat-model
              :scripted-responses (list (ai-message :content "only")))))
      (send m :invoke "first call")
      (assert-panic (send m :invoke "overrun"))))

  (deftest "fake-chat-model carries response-metadata and usage" suite
    (let* ((m (fake-chat-model
               :scripted-responses (list
                                    (ai-message
                                     :content "ok"
                                     :response-metadata '((:model . "fake-1"))
                                     :usage '((:input-tokens . 4))))))
           (r (send m :invoke "x")))
      (assert-equal "fake-1"
                    (cdr (assoc :model (send r :response-metadata))))
      (assert-equal 4
                    (cdr (assoc :input-tokens (send r :usage))))))

  ;; ---- fake-chat-model streaming ----------------------------------------

  (deftest "fake-chat-model :stream chunks character by character" suite
    (let* ((m   (fake-chat-model
                 :scripted-responses (list (ai-message :content "abc"))))
           (ch  (send m :stream "ignored"))
           (chunks nil))
      (range (lambda (c) (push c chunks)) ch)
      ;; 3 chars + 1 final metadata-carrying chunk.
      (assert-equal 4 (length chunks))
      (let ((concat (concat-chunks (nreverse chunks))))
        (assert-equal "abc" (send concat :content)))))

  ;; ---- :bind-tools -------------------------------------------------------

  (deftest ":bind-tools returns a fresh instance with tools set" suite
    (def-tool t-add (a b) "add" (+ a b))
    (let* ((m1 (fake-chat-model
                :scripted-responses (list (ai-message :content "x"))))
           (m2 (send m1 :bind-tools (list t-add))))
      (assert-nil  (send m1 :tools))
      (assert-equal 1 (length (send m2 :tools)))))

  (deftest ":bind-tools does not mutate the original instance" suite
    (def-tool t-x (a) "noop" a)
    (let* ((m1 (fake-chat-model
                :scripted-responses (list (ai-message :content "y"))))
           (m2 (send m1 :bind-tools (list t-x))))
      (declare (ignore m2))
      ;; m1's tools must remain unset.
      (assert-nil (send m1 :tools))))

  (deftest ":bind-tools preserves model, scripted-responses, etc." suite
    (let* ((responses (list (ai-message :content "kept")))
           (m1 (fake-chat-model :model "fake-test"
                                :scripted-responses responses))
           (m2 (send m1 :bind-tools nil)))
      (assert-equal "fake-test" (send m2 :model))
      (assert-equal "kept"
                    (message-text (send m2 :invoke "x")))))

  ;; ---- callback firing --------------------------------------------------

  (deftest ":invoke fires :on-llm-start and :on-llm-end" suite
    (let* ((h (make-instance 'recording-handler-llm))
           (m (fake-chat-model
               :scripted-responses (list (ai-message :content "ok")))))
      (send m :invoke "hi" :callbacks (list h))
      (let ((events (nreverse (send h :events))))
        (assert-equal 2 (length events))
        (assert-equal :on-llm-start (car (car events)))
        (assert-equal :on-llm-end   (car (cadr events))))))

  (deftest ":invoke does NOT fire :on-chain-* events" suite
    (let* ((h (make-instance 'recording-handler))
           (m (fake-chat-model
               :scripted-responses (list (ai-message :content "ok")))))
      (send m :invoke "hi" :callbacks (list h))
      ;; recording-handler captures :on-chain-*.  Should be empty.
      (assert-nil (send h :events))))

  (deftest ":stream fires :on-llm-new-token per chunk" suite
    (let* ((h (make-instance 'recording-handler-llm))
           (m (fake-chat-model
               :scripted-responses (list (ai-message :content "ab"))))
           (ch (send m :stream "x" :callbacks (list h))))
      (range (lambda (c) (declare (ignore c)) nil) ch)
      ;; Events expected: :on-llm-start, :on-llm-new-token x 3
      ;; (2 chars + 1 final metadata chunk), :on-llm-end.
      (let ((events (nreverse (send h :events))))
        (assert-equal :on-llm-start (car (car events)))
        (assert-equal :on-llm-end   (car (car (last events))))
        ;; Token events should match chunk count.
        (let ((token-count 0))
          (dolist (evt events)
            (when (eq (car evt) :on-llm-new-token)
              (setq token-count (1+ token-count))))
          (assert-equal 3 token-count)))))

  ;; ---- :invoke-impl is abstract on chat-model ---------------------------

  (deftest "abstract chat-model :invoke-impl panics if instantiated" suite
    ;; Cannot make-instance an abstract flavor directly, so test by
    ;; defining a bare subclass that doesn't override :invoke-impl.
    (defflavor bare-chat () (chat-model))
    (let ((m (make-instance 'bare-chat :model "bare")))
      (assert-panic (send m :invoke "x"))))

  ;; ---- :with-structured-output stub -------------------------------------

  (deftest ":with-structured-output panics in v0.1 D7 (lands in D12)" suite
    (let ((m (fake-chat-model
              :scripted-responses (list (ai-message :content "x")))))
      (assert-panic (send m :with-structured-output 'some-struct))))

  ;; ---- composition ------------------------------------------------------

  (deftest "fake-chat-model pipes with prompt and parser cleanly" suite
    (let* ((prompt (chat-prompt-template-from-messages
                    '((:human "{q}"))))
           (model  (fake-chat-model
                    :scripted-responses (list (ai-message :content "answer: 42"))))
           (parser (string-output-parser))
           (chain  (pipe prompt model parser)))
      (assert-equal "answer: 42"
                    (send chain :invoke '((:q . "what?")))))))
