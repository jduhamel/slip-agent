;;;; agents_test.lisp — create-agent loop, tool dispatch, response-format.

(let ((suite (defsuite "agents" agent-suite)))

  ;; ---- single-turn (no tool calls) --------------------------------------

  (deftest "agent terminates on first turn when no tool calls" suite
    (let* ((m (fake-chat-model
               :scripted-responses
               (list (ai-message :content "the answer is 42"))))
           (a (create-agent :model m)))
      (let ((result (send a :invoke "what is 6 times 7?")))
        (assert-equal "the answer is 42" (message-text result)))))

  (deftest "agent prepends system-prompt to messages" suite
    (let* ((m (fake-chat-model
               :scripted-responses (list (ai-message :content "ok"))))
           (a (create-agent :model m
                            :system-prompt "You are a math tutor.")))
      (assert-equal "ok" (message-text (send a :invoke "go")))))

  ;; ---- tool dispatch -----------------------------------------------------

  (deftest "agent dispatches a single tool call and runs the loop" suite
    (def-tool ag-add (a b) "add" (+ a b))
    (let* ((tu (tool-use-block :id "1" :name "ag-add"
                               :input (make-bag "{a:17, b:25}")))
           (m  (fake-chat-model
                :scripted-responses
                (list
                 ;; Turn 1: model asks to call ag-add.
                 (ai-message :content (list (text-block "let me compute") tu))
                 ;; Turn 2: model returns the final answer.
                 (ai-message :content "the sum is 42"))))
           (a  (create-agent :model m :tools (list ag-add))))
      (let ((result (send a :invoke "what is 17+25?")))
        (assert-equal "the sum is 42" (message-text result)))))

  (deftest "agent dispatches multiple tool calls in one turn" suite
    (def-tool ag-double (n) "double" (* n 2))
    (def-tool ag-square (n) "square" (* n n))
    (let* ((c1 (tool-use-block :id "c1" :name "ag-double"
                               :input (make-bag "{n: 3}")))
           (c2 (tool-use-block :id "c2" :name "ag-square"
                               :input (make-bag "{n: 4}")))
           (m  (fake-chat-model
                :scripted-responses
                (list
                 (ai-message :content (list (text-block "compute both") c1 c2))
                 (ai-message :content "results 6 and 16"))))
           (a  (create-agent :model m :tools (list ag-double ag-square))))
      (let ((result (send a :invoke "do both")))
        (assert-equal "results 6 and 16" (message-text result)))))

  (deftest "agent supports parallel-tool-calls" suite
    (def-tool ag-pp1 (n) "p1" (* n 10))
    (def-tool ag-pp2 (n) "p2" (* n 100))
    (let* ((c1 (tool-use-block :id "p1" :name "ag-pp1" :input (make-bag "{n:2}")))
           (c2 (tool-use-block :id "p2" :name "ag-pp2" :input (make-bag "{n:3}")))
           (m  (fake-chat-model
                :scripted-responses
                (list
                 (ai-message :content (list c1 c2))
                 (ai-message :content "done"))))
           (a  (create-agent :model m :tools (list ag-pp1 ag-pp2)
                             :parallel-tool-calls t)))
      (assert-equal "done" (message-text (send a :invoke "go")))))

  ;; ---- error handling ---------------------------------------------------

  (deftest "agent on-tool-error :return-as-message wraps the panic" suite
    (def-tool ag-throws (x) "panics" (declare (ignore x)) (panic "kaboom"))
    (let* ((tu (tool-use-block :id "x" :name "ag-throws"
                               :input (make-bag "{x:1}")))
           (m  (fake-chat-model
                :scripted-responses
                (list (ai-message :content (list tu))
                      (ai-message :content "i caught the error"))))
           (a  (create-agent :model m :tools (list ag-throws))))
      ;; Loop should not panic; instead, append a tool-message with
      ;; is-error and continue.  Final answer comes back.
      (assert-equal "i caught the error" (message-text (send a :invoke "go")))))

  (deftest "agent on-tool-error :raise propagates the panic" suite
    (def-tool ag-throws-r (x) "panics" (declare (ignore x)) (panic "kaboom"))
    (let* ((tu (tool-use-block :id "x" :name "ag-throws-r"
                               :input (make-bag "{x:1}")))
           (m  (fake-chat-model
                :scripted-responses (list (ai-message :content (list tu)))))
           (a  (create-agent :model m :tools (list ag-throws-r)
                             :on-tool-error :raise)))
      (assert-panic (send a :invoke "go"))))

  (deftest "agent emits tool-message-with-error for unknown tool" suite
    ;; If the model invents a tool name that isn't bound, the loop
    ;; doesn't blow up — it appends an error tool-message and the
    ;; model gets a chance to recover.
    (let* ((tu (tool-use-block :id "x" :name "no-such-tool"
                               :input (make-bag "{}")))
           (m  (fake-chat-model
                :scripted-responses
                (list (ai-message :content (list tu))
                      (ai-message :content "oh well")))))
      (assert-equal "oh well"
                    (message-text (send (create-agent :model m) :invoke "go")))))

  ;; ---- max-iterations ----------------------------------------------------

  (deftest "agent panics when max-iterations is exceeded" suite
    (def-tool ag-noop (x) "noop" x)
    ;; Build a model that ALWAYS asks for a tool call and never
    ;; finishes — should hit the limit.
    (let* ((tu (tool-use-block :id "n" :name "ag-noop"
                               :input (make-bag "{x:1}")))
           ;; Provide more responses than max-iterations so we don't
           ;; run out of scripted responses.
           (responses (let ((r nil))
                        (dotimes (i 10)
                          (push (ai-message :content (list tu)) r))
                        r))
           (m  (fake-chat-model :scripted-responses responses))
           (a  (create-agent :model m :tools (list ag-noop)
                             :max-iterations 3)))
      (assert-panic (send a :invoke "go"))))

  ;; ---- response-format (synthetic-respond fallback) ---------------------

  (deftest "response-format on non-native provider intercepts respond tool" suite
    ;; fake-chat-model isn't a native-structured-output provider, so
    ;; the agent appends the synthetic respond tool.  The model "calls"
    ;; it with the structured args; the loop intercepts and returns.
    (let* ((respond-call (tool-use-block
                          :id "r" :name (synthetic-respond-tool-name)
                          :input (make-bag "{answer:42, confidence:high}")))
           (m  (fake-chat-model
                :scripted-responses
                (list (ai-message :content (list respond-call)))))
           (a  (create-agent :model m
                             :response-format 'answer-schema)))
      ;; Default :response-into is nil — result is the bag.
      (let ((result (send a :invoke "go")))
        (assert-equal 42 (send result :get "answer"))
        (assert-equal "high" (send result :get "confidence")))))

  (deftest "response-format with :response-into coerces to instance" suite
    (let* ((respond-call (tool-use-block
                          :id "r" :name (synthetic-respond-tool-name)
                          :input (make-bag "{answer: yes}")))
           (m  (fake-chat-model
                :scripted-responses
                (list (ai-message :content (list respond-call)))))
           (a  (create-agent :model m
                             :response-format 'answer-schema
                             :response-into
                             (lambda (bag) (cons :wrapped (send bag :get "answer"))))))
      (let ((result (send a :invoke "go")))
        (assert-equal :wrapped (car result))
        (assert-equal "yes" (cdr result)))))

  ;; ---- agent is a runnable -----------------------------------------------

  (deftest "agent is a runnable and pipes cleanly" suite
    (let* ((m (fake-chat-model
               :scripted-responses (list (ai-message :content "raw output"))))
           (a (create-agent :model m))
           (chain (pipe a (string-output-parser))))
      (assert-equal "raw output" (send chain :invoke "go"))))

  (deftest "agent fires :on-chain-* events around the whole loop" suite
    (let* ((m (fake-chat-model
               :scripted-responses (list (ai-message :content "x"))))
           (a (create-agent :model m))
           (h (make-instance 'recording-handler)))
      (send a :invoke "go" :callbacks (list h))
      (let ((events (nreverse (send h :events))))
        ;; agent-runnable inherits runnable's :invoke template, so
        ;; chain start/end fire around the whole loop.
        (assert-equal :on-chain-start (car (car events)))
        (assert-equal :on-chain-end   (car (car (last events))))))))
