;;;; openai_test.lisp — chat-openai provider, request/response, structured output.

(let ((suite (defsuite "openai" agent-suite)))

  ;; ---- request body construction ---------------------------------------

  (deftest "build-openai-request includes model" suite
    (let ((body (build-openai-request
                 "gpt-4o"
                 (list (human-message "hi"))
                 nil nil nil nil nil)))
      (assert-equal "gpt-4o" (send body :get "model"))))

  (deftest "build-openai-request honours max-tokens and temperature" suite
    (let ((body (build-openai-request
                 "gpt-4o" (list (human-message "x"))
                 nil 1024 0.5 nil nil)))
      (assert-equal 1024 (send body :get "max_tokens"))
      (assert-equal 0.5  (send body :get "temperature"))))

  (deftest "build-openai-request adds stream:true" suite
    (let ((body (build-openai-request
                 "gpt-4o" (list (human-message "x"))
                 nil nil nil t nil)))
      (assert-equal t (send body :get "stream"))))

  (deftest "build-openai-request omits stream when not streaming" suite
    (let ((body (build-openai-request
                 "gpt-4o" (list (human-message "x"))
                 nil nil nil nil nil)))
      (assert-nil (send body :get "stream"))))

  (deftest "build-openai-request includes messages in OpenAI shape" suite
    (let* ((body (build-openai-request
                  "gpt-4o"
                  (list (system-message "be brief")
                        (human-message  "what?"))
                  nil nil nil nil nil))
           (msgs (send body :get "messages")))
      (assert-equal 2 (length msgs))
      (assert-equal "system" (cdr (assoc "role" (car msgs) :test #'equal)))
      (assert-equal "user"   (cdr (assoc "role" (cadr msgs) :test #'equal)))))

  (deftest "build-openai-request serialises bound tools" suite
    (def-tool oa-add (a b) "add" (+ a b))
    (let* ((body  (build-openai-request
                   "gpt-4o" (list (human-message "x"))
                   (list oa-add) nil nil nil nil))
           (tools (send body :get "tools")))
      (assert-equal 1 (length tools))
      (assert-equal "function"
                    (cdr (assoc "type" (car tools) :test #'equal)))))

  (deftest "build-openai-request includes response_format when set" suite
    (let* ((body (build-openai-request
                  "gpt-4o" (list (human-message "x"))
                  nil nil nil nil 'answer-schema))
           (rf   (send body :get "response_format")))
      (assert-equal "json_schema"
                    (cdr (assoc "type" rf :test #'equal)))))

  ;; ---- response parsing -------------------------------------------------

  (deftest "parse-openai-response returns string content for text-only" suite
    (let* ((bag (read-fixture "openai" "invoke-text"))
           (msg (parse-openai-response bag)))
      (assert-equal "assistant" (message-role msg))
      (assert-equal t (stringp (send msg :content)))
      (assert-equal t (> (length (send msg :content)) 0))
      (assert-match "^chatcmpl-" (send msg :id))))

  (deftest "parse-openai-response includes response-metadata" suite
    (let* ((bag (read-fixture "openai" "invoke-text"))
           (msg (parse-openai-response bag)))
      (assert-match "^gpt-4o"
                    (cdr (assoc :model (send msg :response-metadata))))
      (assert-equal "stop"
                    (cdr (assoc :finish-reason (send msg :response-metadata))))))

  (deftest "parse-openai-response includes usage" suite
    (let* ((bag (read-fixture "openai" "invoke-text"))
           (msg (parse-openai-response bag)))
      (assert-equal t (numberp (cdr (assoc :input-tokens  (send msg :usage)))))
      (assert-equal t (numberp (cdr (assoc :output-tokens (send msg :usage)))))
      (assert-equal t (numberp (cdr (assoc :total-tokens  (send msg :usage)))))))

  (deftest "parse-openai-response with tool-calls returns block list" suite
    (let* ((bag    (read-fixture "openai" "invoke-with-tools"))
           (msg    (parse-openai-response bag))
           (blocks (send msg :content)))
      (assert-equal t (listp blocks))
      ;; finish_reason: tool_calls — at least one tool-use-block expected.
      (let ((tool-blocks nil))
        (dolist (b blocks)
          (when (typep b 'tool-use-block) (push b tool-blocks)))
        (assert-equal t (>= (length tool-blocks) 1)))))

  (deftest "parse-openai-response :tool-calls extracts the call" suite
    (let* ((bag   (read-fixture "openai" "invoke-with-tools"))
           (msg   (parse-openai-response bag))
           (calls (send msg :tool-calls)))
      (assert-equal t (>= (length calls) 1))
      (let ((call (car calls)))
        (assert-match "^call_" (send call :id))
        (assert-equal "calc-add" (send call :name))
        (assert-equal 17 (send (send call :input) :get "a"))
        (assert-equal 25 (send (send call :input) :get "b")))))

  ;; ---- frame -> chunk translation ---------------------------------------

  (deftest "openai-frame-to-chunk converts content delta" suite
    (let* ((bag   (make-bag "{choices: [{index: 0, delta: {content: hello}, finish_reason: null}]}"))
           (chunk (openai-frame-to-chunk (cons "message" bag))))
      (assert-equal "hello" (send chunk :content))))

  (deftest "openai-frame-to-chunk emits finish_reason on stop chunk" suite
    (let* ((bag   (make-bag "{choices: [{index: 0, delta: {}, finish_reason: stop}]}"))
           (chunk (openai-frame-to-chunk (cons "message" bag))))
      (assert-equal "stop"
                    (cdr (assoc :finish-reason (send chunk :response-metadata))))))

  (deftest "openai-frame-to-chunk returns nil for role-only delta" suite
    (let* ((bag   (make-bag "{choices: [{index: 0, delta: {role: assistant}, finish_reason: null}]}"))
           (chunk (openai-frame-to-chunk (cons "message" bag))))
      (assert-nil chunk)))

  ;; ---- end-to-end via recorded-poster -----------------------------------

  (deftest "chat-openai end-to-end invoke (replay)" suite
    (let* ((poster (recorded-poster "openai" "invoke-text"))
           (model  (chat-openai :model "gpt-4o"
                                :api-key (or (getenv "OPENAI_API_KEY") "test-key")
                                :poster poster))
           (msg    (send model :invoke "Hi")))
      (assert-equal "assistant" (message-role msg))
      (assert-equal t (stringp (send msg :content)))
      (assert-match "^chatcmpl-" (send msg :id))))

  (deftest "chat-openai end-to-end invoke with tools (replay)" suite
    (def-tool oa-calc-add (a b) "Add two ints." (+ a b))
    (let* ((poster (recorded-poster "openai" "invoke-with-tools"))
           (model  (send (chat-openai :model "gpt-4o"
                                      :api-key (or (getenv "OPENAI_API_KEY") "test-key")
                                      :poster poster)
                         :bind-tools (list oa-calc-add)))
           (msg    (send model :invoke "compute 17+25"))
           (calls  (send msg :tool-calls)))
      (assert-equal t (>= (length calls) 1))
      (assert-equal "calc-add" (send (car calls) :name))))

  ;; ---- :with-structured-output ------------------------------------------

  (deftest ":with-structured-output returns a runnable that parses JSON" suite
    (let* ((poster (recorded-poster "openai" "invoke-structured"))
           (model  (chat-openai :model "gpt-4o"
                                :api-key (or (getenv "OPENAI_API_KEY") "test-key")
                                :poster poster))
           (chain  (send model :with-structured-output 'answer-schema))
           (result (send chain :invoke "what is 6 times 7?")))
      ;; result is a bag (no :into specified).
      (assert-equal 42 (send result :get "answer"))
      (assert-equal "high" (send result :get "confidence"))))

  (deftest ":with-structured-output with :into coerces to instance" suite
    (let* ((poster (recorded-poster "openai" "invoke-structured"))
           (model  (chat-openai :model "gpt-4o"
                                :api-key (or (getenv "OPENAI_API_KEY") "test-key")
                                :poster poster))
           (chain  (send model :with-structured-output 'answer-schema
                         :into (lambda (bag)
                                 (cons (send bag :get "answer")
                                       (send bag :get "confidence")))))
           (result (send chain :invoke "compute that")))
      (assert-equal 42 (car result))
      (assert-equal "high" (cdr result))))

  ;; ---- response-format building -----------------------------------------

  (deftest "build-openai-response-format wraps in json_schema envelope" suite
    (let ((rf (build-openai-response-format 'my-schema)))
      (assert-equal "json_schema" (send rf :get "type"))
      (let ((js (send rf :get "json_schema")))
        (assert-equal "my-schema"
                      (cdr (assoc "name" js :test #'equal)))
        (assert-equal t (cdr (assoc "strict" js :test #'equal))))))

  ;; ---- constructor defaults ---------------------------------------------

  (deftest "chat-openai constructor defaults" suite
    (let ((m (chat-openai)))
      (assert-equal "gpt-4o" (send m :model))
      (assert-nil (send m :tools))
      (assert-nil (send m :response-format)))))
