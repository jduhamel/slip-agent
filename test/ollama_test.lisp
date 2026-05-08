;;;; ollama_test.lisp — chat-ollama (OpenAI-compatible localhost provider).

(let ((suite (defsuite "ollama" agent-suite)))

  (deftest "chat-ollama defaults to localhost ollama endpoint" suite
    (let ((m (chat-ollama)))
      (assert-equal "llama3" (send m :model))
      ;; base-url is nil on construction; the default is supplied at
      ;; :invoke-impl time via ollama-default-base-url.
      (assert-match "http://localhost:11434"
                    (ollama-default-base-url))))

  (deftest "chat-ollama is-a chat-openai (inherits behaviour)" suite
    (let ((m (chat-ollama)))
      (assert-equal t (typep m 'chat-ollama))
      (assert-equal t (typep m 'chat-openai))
      (assert-equal t (typep m 'chat-model))))

  (deftest "chat-ollama :copy preserves ollama type" suite
    (let* ((m1 (chat-ollama :model "mistral"))
           (m2 (send m1 :bind-tools nil)))
      (assert-equal "mistral" (send m2 :model))
      (assert-equal t (typep m2 'chat-ollama))))

  (deftest "chat-ollama end-to-end invoke uses OpenAI parser (replay)" suite
    ;; Reuse the OpenAI fixture — the wire format is the same.
    (let* ((poster (recorded-poster "openai" "invoke-text"))
           (model  (chat-ollama :model "llama3"
                                :base-url "http://example/v1/chat/completions"
                                :poster poster))
           (msg    (send model :invoke "hi")))
      (assert-equal "assistant" (message-role msg))
      (assert-equal t (stringp (send msg :content)))))

  (deftest "chat-ollama works without an api-key on localhost" suite
    ;; resolve-api-key would panic on no slot + no env, but
    ;; chat-ollama's :invoke-impl skips the resolve and uses a dummy
    ;; bearer.
    (let* ((poster (recorded-poster "openai" "invoke-text"))
           (model  (chat-ollama :model "llama3" :poster poster)))
      (assert-equal "assistant"
                    (message-role (send model :invoke "hi"))))))
