;;;; messages_test.lisp — D1 message and content-block coverage.

(let ((suite (defsuite "messages" agent-suite)))

  ;; ---- constructors ------------------------------------------------------

  (deftest "human-message string content" suite
    (let ((m (human-message "hi")))
      (assert-equal "hi" (send m :content))
      (assert-equal "user" (message-role m))))

  (deftest "system-message string content" suite
    (let ((m (system-message "be brief")))
      (assert-equal "be brief" (send m :content))
      (assert-equal "system" (message-role m))))

  (deftest "ai-message defaults to empty string content" suite
    (let ((m (ai-message)))
      (assert-equal "" (send m :content))
      (assert-equal "assistant" (message-role m))))

  (deftest "ai-message with response-metadata and usage" suite
    (let ((m (ai-message :content "ok"
                         :response-metadata '((:model . "claude-test"))
                         :usage '((:input-tokens . 7)))))
      (assert-equal "ok" (send m :content))
      (assert-equal "claude-test"
                    (cdr (assoc :model (send m :response-metadata))))
      (assert-equal 7 (cdr (assoc :input-tokens (send m :usage))))))

  (deftest "tool-message captures tool-call-id" suite
    (let ((m (tool-message "42" "call_xyz")))
      (assert-equal "42" (send m :content))
      (assert-equal "call_xyz" (send m :tool-call-id))
      (assert-equal "tool" (message-role m))))

  (deftest "function-message captures name" suite
    (let ((m (function-message "{\"x\":1}" "old_fn")))
      (assert-equal "old_fn" (send m :name))
      (assert-equal "function" (message-role m))))

  ;; ---- content blocks ---------------------------------------------------

  (deftest "text-block stores text" suite
    (let ((b (text-block "hello")))
      (assert-equal "hello" (send b :text))))

  (deftest "tool-use-block stores id, name, input bag" suite
    (let* ((args (make-bag "{a:1, b:2}"))
           (b (tool-use-block :id "call_1" :name "calc" :input args)))
      (assert-equal "call_1" (send b :id))
      (assert-equal "calc" (send b :name))
      (assert-equal 1 (send (send b :input) :get "a"))))

  (deftest "tool-result-block defaults is-error nil" suite
    (let ((b (tool-result-block :tool-use-id "x" :content "ok")))
      (assert-nil (send b :is-error))
      (assert-equal "x" (send b :tool-use-id))
      (assert-equal "ok" (send b :content))))

  (deftest "reasoning-block carries text and signature" suite
    (let ((b (reasoning-block :text "thinking..." :signature "sig123")))
      (assert-equal "thinking..." (send b :text))
      (assert-equal "sig123" (send b :signature))))

  (deftest "unknown-content-block preserves raw bag" suite
    (let* ((raw (make-bag "{type: server_tool_use, name: web_search}"))
           (b (unknown-content-block "server_tool_use" raw)))
      (assert-equal "server_tool_use" (send b :block-type))
      (assert-equal "web_search" (send (send b :raw) :get "name"))))

  ;; ---- ai-message :tool-calls method ------------------------------------

  (deftest "ai-message :tool-calls returns nil for string content" suite
    (let ((m (ai-message :content "just text")))
      (assert-nil (send m :tool-calls))))

  (deftest "ai-message :tool-calls extracts tool-use-blocks" suite
    (let* ((b1 (tool-use-block :id "1" :name "calc" :input (make-bag "{a:1}")))
           (b2 (tool-use-block :id "2" :name "search" :input (make-bag "{q:hi}")))
           (m (ai-message :content (list (text-block "let me check") b1 b2))))
      (let ((calls (send m :tool-calls)))
        (assert-equal 2 (length calls))
        (assert-equal "calc" (send (car calls) :name))
        (assert-equal "search" (send (cadr calls) :name)))))

  (deftest "ai-message :tool-calls ignores non-tool-use blocks" suite
    (let* ((m (ai-message :content (list (text-block "a")
                                         (reasoning-block :text "thinking")
                                         (text-block "b")))))
      (assert-nil (send m :tool-calls))))

  ;; ---- message-text helper ----------------------------------------------

  (deftest "message-text passes string content through" suite
    (assert-equal "hi" (message-text (human-message "hi"))))

  (deftest "message-text concatenates text-blocks, ignores others" suite
    (let ((m (ai-message :content (list (text-block "hello ")
                                        (reasoning-block :text "private thoughts")
                                        (text-block "world")))))
      (assert-equal "hello world" (message-text m))))

  (deftest "message-text returns empty string for blockless ai-message" suite
    (let ((m (ai-message :content (list (tool-use-block :id "x" :name "n")))))
      (assert-equal "" (message-text m))))

  ;; ---- concat-chunks -----------------------------------------------------

  (deftest "concat-chunks joins string deltas" suite
    (let* ((c1 (ai-message-chunk :content "Hel"))
           (c2 (ai-message-chunk :content "lo, "))
           (c3 (ai-message-chunk :content "world."))
           (final (concat-chunks (list c1 c2 c3))))
      (assert-equal "Hello, world." (send final :content))))

  (deftest "concat-chunks preserves last response-metadata and usage" suite
    (let* ((c1 (ai-message-chunk :content "a"))
           (c2 (ai-message-chunk :content "b"
                                 :response-metadata '((:stop-reason . "end_turn"))
                                 :usage '((:output-tokens . 12))))
           (final (concat-chunks (list c1 c2))))
      (assert-equal "end_turn"
                    (cdr (assoc :stop-reason (send final :response-metadata))))
      (assert-equal 12
                    (cdr (assoc :output-tokens (send final :usage))))))

  (deftest "concat-chunks with empty list returns empty ai-message" suite
    (let ((final (concat-chunks nil)))
      (assert-equal "" (send final :content))))

  ;; ---- OpenAI wire format -----------------------------------------------

  (deftest "message->bag for human-message" suite
    (let* ((m (human-message "hi"))
           (b (message->bag m)))
      (assert-equal "user" (send b :get "role"))
      (assert-equal "hi" (send b :get "content"))))

  (deftest "message->bag for system-message" suite
    (let* ((m (system-message "be brief"))
           (b (message->bag m)))
      (assert-equal "system" (send b :get "role"))
      (assert-equal "be brief" (send b :get "content"))))

  (deftest "message->bag for assistant with text only omits tool_calls" suite
    (let* ((m (ai-message :content "ok"))
           (b (message->bag m)))
      (assert-equal "assistant" (send b :get "role"))
      (assert-equal "ok" (send b :get "content"))
      (assert-nil (send b :get "tool_calls"))))

  (deftest "message->bag emits OpenAI tool_calls array for tool-use" suite
    ;; Nested values inside a bag come back as native Lisp alists when
    ;; read via :get, so we navigate with assoc.  The wire format
    ;; (bag-write) still produces correct JSON.
    (let* ((tu (tool-use-block :id "call_1" :name "calc" :input (make-bag "{a:2, b:3}")))
           (m  (ai-message :content (list (text-block "let me add") tu)))
           (b  (message->bag m))
           (calls (send b :get "tool_calls")))
      (assert-equal "let me add" (send b :get "content"))
      (assert-equal 1 (length calls))
      (let* ((entry (car calls))
             (fn    (cdr (assoc "function" entry :test #'equal))))
        (assert-equal "call_1" (cdr (assoc "id" entry :test #'equal)))
        (assert-equal "function" (cdr (assoc "type" entry :test #'equal)))
        (assert-equal "calc" (cdr (assoc "name" fn :test #'equal))))))

  (deftest "message->bag emits tool_call_id for tool-message" suite
    (let* ((m (tool-message "5" "call_1"))
           (b (message->bag m)))
      (assert-equal "tool" (send b :get "role"))
      (assert-equal "5" (send b :get "content"))
      (assert-equal "call_1" (send b :get "tool_call_id"))))

  ;; ---- bag->message round-trip -----------------------------------------

  (deftest "bag->message round-trips human-message" suite
    (let* ((orig (human-message "hello"))
           (round (bag->message (message->bag orig))))
      (assert-equal "user" (message-role round))
      (assert-equal "hello" (send round :content))))

  (deftest "bag->message round-trips system-message" suite
    (let* ((orig (system-message "rules"))
           (round (bag->message (message->bag orig))))
      (assert-equal "system" (message-role round))
      (assert-equal "rules" (send round :content))))

  (deftest "bag->message round-trips tool-message" suite
    (let* ((orig (tool-message "42" "call_xyz"))
           (round (bag->message (message->bag orig))))
      (assert-equal "tool" (message-role round))
      (assert-equal "42" (send round :content))
      (assert-equal "call_xyz" (send round :tool-call-id))))

  (deftest "bag->message round-trips assistant text-only" suite
    (let* ((orig (ai-message :content "answer"))
           (round (bag->message (message->bag orig))))
      (assert-equal "assistant" (message-role round))
      (assert-equal "answer" (send round :content))))

  (deftest "bag->message reconstructs tool-use-blocks from tool_calls" suite
    (let* ((tu    (tool-use-block :id "call_1" :name "calc"
                                  :input (make-bag "{a:2, b:3}")))
           (orig  (ai-message :content (list (text-block "computing") tu)))
           (round (bag->message (message->bag orig)))
           (calls (send round :tool-calls)))
      (assert-equal 1 (length calls))
      (assert-equal "call_1" (send (car calls) :id))
      (assert-equal "calc" (send (car calls) :name))
      (assert-equal 2 (send (send (car calls) :input) :get "a"))
      (assert-equal 3 (send (send (car calls) :input) :get "b")))))
