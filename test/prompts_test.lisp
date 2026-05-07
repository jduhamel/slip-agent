;;;; prompts_test.lisp — prompt-template, chat-prompt-template, placeholders.

(let ((suite (defsuite "prompts" agent-suite)))

  ;; ---- prompt-template ---------------------------------------------------

  (deftest "prompt-template substitutes a single variable" suite
    (let ((p (prompt-template "Hello, {name}!")))
      (assert-equal "Hello, world!"
                    (send p :invoke '((:name . "world"))))))

  (deftest "prompt-template substitutes multiple variables" suite
    (let ((p (prompt-template "{greeting}, {name}!")))
      (assert-equal "Hi, Joe!"
                    (send p :invoke '((:greeting . "Hi") (:name . "Joe"))))))

  (deftest "prompt-template handles trailing literal text after substitution" suite
    (let ((p (prompt-template "{x} and that's all.")))
      (assert-equal "yes and that's all."
                    (send p :invoke '((:x . "yes"))))))

  (deftest "prompt-template handles leading literal text before substitution" suite
    (let ((p (prompt-template "starts here: {x}")))
      (assert-equal "starts here: end"
                    (send p :invoke '((:x . "end"))))))

  (deftest "prompt-template with no substitutions passes the string through" suite
    (let ((p (prompt-template "no variables here")))
      (assert-equal "no variables here"
                    (send p :invoke nil))))

  (deftest "prompt-template panics on missing key" suite
    (let ((p (prompt-template "Hello, {name}!")))
      (assert-panic (send p :invoke '((:other . "x"))))))

  (deftest "prompt-template panics on unmatched open brace" suite
    (let ((p (prompt-template "Hello, {name")))
      (assert-panic (send p :invoke '((:name . "world"))))))

  (deftest "prompt-template :format does not require :invoke ceremony" suite
    (let ((p (prompt-template "Value: {v}")))
      (assert-equal "Value: 42"
                    (send p :format '((:v . "42"))))))

  (deftest "prompt-template-from-template alias works" suite
    (let ((p (prompt-template-from-template "{x}")))
      (assert-equal "ok" (send p :invoke '((:x . "ok"))))))

  ;; ---- chat-prompt-template ---------------------------------------------

  (deftest "chat-prompt-template produces system + human messages" suite
    (let* ((p   (chat-prompt-template-from-messages
                 '((:system "You are a {role}.")
                   (:human  "{question}"))))
           (msgs (send p :invoke '((:role . "helper") (:question . "what?")))))
      (assert-equal 2 (length msgs))
      (assert-equal "system" (message-role (car msgs)))
      (assert-equal "You are a helper." (message-text (car msgs)))
      (assert-equal "user" (message-role (cadr msgs)))
      (assert-equal "what?" (message-text (cadr msgs)))))

  (deftest "chat-prompt-template :format-messages bypasses chain events" suite
    (let* ((p (chat-prompt-template-from-messages
               '((:human "{q}"))))
           (msgs (send p :format-messages '((:q . "ping")))))
      (assert-equal 1 (length msgs))
      (assert-equal "ping" (message-text (car msgs)))))

  (deftest "chat-prompt-template accepts :user as alias for :human" suite
    (let* ((p (chat-prompt-template-from-messages
               '((:user "{q}"))))
           (msgs (send p :invoke '((:q . "yo")))))
      (assert-equal "user" (message-role (car msgs)))))

  (deftest "chat-prompt-template accepts :ai as alias for :assistant" suite
    (let* ((p (chat-prompt-template-from-messages
               '((:ai "I'm thinking..."))))
           (msgs (send p :invoke nil)))
      (assert-equal "assistant" (message-role (car msgs)))))

  (deftest "chat-prompt-template panics on unknown role" suite
    (let ((p (chat-prompt-template-from-messages
              '((:wizard "I cast {spell}")))))
      (assert-panic (send p :invoke '((:spell . "fireball"))))))

  ;; ---- messages-placeholder ----------------------------------------------

  (deftest "messages-placeholder constructor returns the marker form" suite
    (assert-equal '(:placeholder :history)
                  (messages-placeholder :history)))

  (deftest "chat-prompt-template splices in a placeholder list" suite
    ;; Note: Slip's backquote does not substitute through a
    ;; dotted-cdr (`(:k . ,v) reads ,v as a literal), so user code
    ;; building input alists must use (cons :k v) explicitly when the
    ;; value is held in a variable.
    (let* ((history (list (human-message "earlier1")
                          (ai-message :content "earlier2")))
           (p       (chat-prompt-template-from-messages
                     `((:system "rules")
                       ,(messages-placeholder :history)
                       (:human "{q}"))))
           (msgs    (send p :invoke (list (cons :history history)
                                          (cons :q       "now")))))
      (assert-equal 4 (length msgs))
      (assert-equal "system" (message-role (car msgs)))
      (assert-equal "earlier1" (message-text (cadr msgs)))
      (assert-equal "earlier2" (message-text (caddr msgs)))
      (assert-equal "now" (message-text (cadddr msgs)))))

  (deftest "chat-prompt-template with empty placeholder list omits nothing" suite
    (let* ((p    (chat-prompt-template-from-messages
                  `((:system "rules")
                    ,(messages-placeholder :history)
                    (:human "{q}"))))
           (msgs (send p :invoke (list (cons :history nil)
                                       (cons :q       "go")))))
      (assert-equal 2 (length msgs))))

  (deftest "messages-placeholder panics on missing key" suite
    (let ((p (chat-prompt-template-from-messages
              `((:system "rules")
                ,(messages-placeholder :history)))))
      (assert-panic (send p :invoke nil))))

  ;; ---- composition with chain events ------------------------------------

  (deftest "prompt-template piped into a runnable-lambda fires events on both" suite
    (let* ((h      (make-instance 'recording-handler))
           (chain  (pipe (prompt-template "Hi, {n}!")
                         (runnable-lambda (lambda (s)
                                            (concatenate 'string s "?"))))))
      (assert-equal "Hi, Joe!?"
                    (send chain :invoke '((:n . "Joe")) :callbacks (list h)))
      ;; Outer sequence + 2 inner steps = 6 events.
      (assert-equal 6 (length (send h :events))))))
