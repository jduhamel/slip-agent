;;;; init-chat-model_test.lisp — provider:model parsing and dispatch.

(let ((suite (defsuite "init-chat-model" agent-suite)))

  ;; ---- parse-model-spec --------------------------------------------------

  (deftest "parse-model-spec splits provider:model" suite
    (let ((parsed (parse-model-spec "anthropic:claude-opus-4-7")))
      (assert-equal :anthropic (car parsed))
      (assert-equal "claude-opus-4-7" (cdr parsed))))

  (deftest "parse-model-spec handles model containing colons" suite
    ;; Only the FIRST colon is the provider separator; the rest is
    ;; the model name (some providers use colons in version tags).
    (let ((parsed (parse-model-spec "ollama:llama3:8b")))
      (assert-equal :ollama (car parsed))
      (assert-equal "llama3:8b" (cdr parsed))))

  (deftest "parse-model-spec falls back to prefix inference" suite
    (let ((parsed (parse-model-spec "claude-opus-4-7")))
      (assert-equal :anthropic (car parsed))
      (assert-equal "claude-opus-4-7" (cdr parsed))))

  ;; ---- infer-provider ---------------------------------------------------

  (deftest "infer-provider detects claude- prefix" suite
    (assert-equal :anthropic (infer-provider "claude-opus-4-7"))
    (assert-equal :anthropic (infer-provider "claude-haiku-4-5")))

  (deftest "infer-provider detects gpt-/o1-/o3-/o4- prefixes" suite
    (assert-equal :openai (infer-provider "gpt-4o"))
    (assert-equal :openai (infer-provider "gpt-5"))
    (assert-equal :openai (infer-provider "o1-preview"))
    (assert-equal :openai (infer-provider "o3-mini"))
    (assert-equal :openai (infer-provider "o4-foo")))

  (deftest "infer-provider detects ollama-style prefixes" suite
    (assert-equal :ollama (infer-provider "llama3"))
    (assert-equal :ollama (infer-provider "mistral-7b"))
    (assert-equal :ollama (infer-provider "qwen2.5"))
    (assert-equal :ollama (infer-provider "gemma2:9b")))

  (deftest "infer-provider panics on ambiguous bare name" suite
    (assert-panic (infer-provider "some-random-model")))

  ;; ---- init-chat-model dispatch -----------------------------------------

  (deftest "init-chat-model returns chat-anthropic for explicit anthropic:" suite
    (let ((m (init-chat-model "anthropic:claude-opus-4-7" :api-key "x")))
      (assert-equal t (typep m 'chat-anthropic))
      (assert-equal "claude-opus-4-7" (send m :model))))

  (deftest "init-chat-model returns chat-openai for explicit openai:" suite
    (let ((m (init-chat-model "openai:gpt-4o" :api-key "x")))
      (assert-equal t (typep m 'chat-openai))
      (assert-equal "gpt-4o" (send m :model))))

  (deftest "init-chat-model returns chat-ollama for explicit ollama:" suite
    (let ((m (init-chat-model "ollama:llama3")))
      (assert-equal t (typep m 'chat-ollama))
      (assert-equal "llama3" (send m :model))))

  (deftest "init-chat-model returns fake-chat-model for fake:" suite
    (let ((m (init-chat-model "fake:test")))
      (assert-equal t (typep m 'fake-chat-model))
      (assert-equal "test" (send m :model))))

  (deftest "init-chat-model with bare claude-* infers anthropic" suite
    (let ((m (init-chat-model "claude-opus-4-7" :api-key "x")))
      (assert-equal t (typep m 'chat-anthropic))))

  (deftest "init-chat-model with bare gpt-4o infers openai" suite
    (let ((m (init-chat-model "gpt-4o" :api-key "x")))
      (assert-equal t (typep m 'chat-openai))))

  (deftest "init-chat-model honours :model-provider override" suite
    ;; Ambiguous name "x" would normally panic, but the override
    ;; bypasses inference.
    (let ((m (init-chat-model "x" :model-provider :anthropic :api-key "x")))
      (assert-equal t (typep m 'chat-anthropic))
      (assert-equal "x" (send m :model))))

  (deftest "init-chat-model forwards temperature and max-tokens" suite
    (let ((m (init-chat-model "anthropic:claude-haiku-4-5"
                              :api-key "x"
                              :temperature 0.3
                              :max-tokens 256)))
      (assert-equal 0.3 (send m :temperature))
      (assert-equal 256 (send m :max-tokens))))

  (deftest "init-chat-model panics on unknown provider" suite
    (assert-panic (init-chat-model "wizard:some-model"))))
