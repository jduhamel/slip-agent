;;;; chat-history_test.lisp — in-memory message history.

(let ((suite (defsuite "chat-history" agent-suite)))

  (deftest "in-memory-chat-message-history starts empty" suite
    (let ((h (in-memory-chat-message-history)))
      (assert-equal 0 (length (send h :messages)))))

  (deftest "seed messages list at construction" suite
    (let ((h (in-memory-chat-message-history
              :messages (list (system-message "be brief")
                              (human-message  "hi")))))
      (assert-equal 2 (length (send h :messages)))))

  (deftest ":add-message appends a single message" suite
    (let ((h (in-memory-chat-message-history)))
      (send h :add-message (human-message "first"))
      (send h :add-message (human-message "second"))
      (let ((msgs (send h :messages)))
        (assert-equal 2 (length msgs))
        (assert-equal "first"  (message-text (car msgs)))
        (assert-equal "second" (message-text (cadr msgs))))))

  (deftest ":add-messages appends a batch in order" suite
    (let ((h (in-memory-chat-message-history)))
      (send h :add-messages (list (human-message "a")
                                  (human-message "b")
                                  (human-message "c")))
      (let ((msgs (send h :messages)))
        (assert-equal 3 (length msgs))
        (assert-equal "a" (message-text (car msgs)))
        (assert-equal "c" (message-text (caddr msgs))))))

  (deftest ":clear empties the history" suite
    (let ((h (in-memory-chat-message-history)))
      (send h :add-message (human-message "x"))
      (send h :add-message (human-message "y"))
      (send h :clear)
      (assert-equal 0 (length (send h :messages)))))

  (deftest ":messages returns a copy (mutation does not leak back)" suite
    (let ((h (in-memory-chat-message-history)))
      (send h :add-message (human-message "original"))
      (let ((snapshot (send h :messages)))
        ;; Replace the snapshot — should not affect the history.
        (setq snapshot nil)
        (declare (ignore snapshot))
        (assert-equal 1 (length (send h :messages))))))

  (deftest "abstract base panics on :add-message without override" suite
    (defflavor bare-history () (base-chat-message-history))
    (let ((h (make-instance 'bare-history)))
      (assert-panic (send h :add-message (human-message "x")))
      (assert-panic (send h :messages))
      (assert-panic (send h :clear))))

  (deftest "concurrent appends via run+mutex remain consistent" suite
    ;; Smoke test the mutex protection — fire ten goroutines each
    ;; appending a message, then verify the total count.
    (let ((h  (in-memory-chat-message-history))
          (ch (make-channel 10)))
      (dotimes (i 10)
        (run
          (progn
            (send h :add-message (human-message "x"))
            (channel-push ch t))))
      ;; Wait for all 10 to signal.
      (dotimes (i 10) (channel-pop ch))
      (assert-equal 10 (length (send h :messages))))))
