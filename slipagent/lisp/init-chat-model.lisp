;;;; init-chat-model.lisp — provider-agnostic chat-model constructor.
;;;;
;;;; (init-chat-model "anthropic:claude-opus-4-7")  -> chat-anthropic
;;;; (init-chat-model "openai:gpt-4o")              -> chat-openai
;;;; (init-chat-model "ollama:llama3")              -> chat-ollama
;;;; (init-chat-model "claude-haiku-4-5")           -> chat-anthropic (prefix inferred)
;;;; (init-chat-model "gpt-4o")                     -> chat-openai (prefix inferred)
;;;;
;;;; Ambiguous bare names (e.g. "claude" alone) panic with a clear
;;;; message pointing at the explicit form.

(defun parse-model-spec (spec)
  "Return (cons provider-symbol model-string) for spec.  spec is
either provider:model (explicit) or just a model name (prefix-
inferred).  Panics on ambiguity."
  (let ((colon (position (char ":" 0) spec)))
    (cond
      ;; Explicit "provider:model"
      (colon
       (let ((provider (subseq spec 0 colon))
             (model    (subseq spec (1+ colon))))
         (cons (intern provider "keyword") model)))
      ;; Prefix-inferred
      (t
       (cons (infer-provider spec) spec)))))

(defun infer-provider (model-name)
  "Look at a bare model name and infer the provider.  Recognised
prefixes:
  claude-*    -> :anthropic
  gpt-*, o1-*, o3-*, o4-*  -> :openai
  llama*, mistral*, qwen*, gemma*  -> :ollama (heuristic)
Anything else panics — caller must use the explicit provider:model
form."
  (cond
    ((or (sse-line-prefix-p model-name "claude")
         (sse-line-prefix-p model-name "claude-"))
     :anthropic)
    ((or (sse-line-prefix-p model-name "gpt-")
         (sse-line-prefix-p model-name "o1-")
         (sse-line-prefix-p model-name "o3-")
         (sse-line-prefix-p model-name "o4-"))
     :openai)
    ((or (sse-line-prefix-p model-name "llama")
         (sse-line-prefix-p model-name "mistral")
         (sse-line-prefix-p model-name "qwen")
         (sse-line-prefix-p model-name "gemma"))
     :ollama)
    (t (panic
        (format nil
                "init-chat-model: cannot infer provider from ~A.  Use the explicit form, e.g. \"anthropic:~A\" or \"openai:~A\"."
                model-name model-name model-name)))))

(defun init-chat-model (spec &key model-provider temperature max-tokens
                                  api-key base-url)
  "Construct a chat-model instance from a string spec.  spec is
\"provider:model\" or a bare model name (with prefix-inferred
provider).  model-provider explicitly overrides the provider derived
from spec; the remaining keys are forwarded to the chosen
constructor."
  ;; If model-provider is given, skip parse-model-spec entirely so an
  ;; ambiguous bare name like \"x\" doesn't panic on inference.
  (let* ((colon-pos (position (char ":" 0) spec))
         (provider  (cond
                      (model-provider model-provider)
                      (colon-pos      (intern (subseq spec 0 colon-pos)
                                              "keyword"))
                      (t              (infer-provider spec))))
         (model     (cond
                      (colon-pos (subseq spec (1+ colon-pos)))
                      (t spec))))
    (cond
      ((eq provider :anthropic)
       (chat-anthropic :model model :temperature temperature
                       :max-tokens max-tokens :api-key api-key
                       :base-url base-url))
      ((eq provider :openai)
       (chat-openai :model model :temperature temperature
                    :max-tokens max-tokens :api-key api-key
                    :base-url base-url))
      ((eq provider :ollama)
       (chat-ollama :model model :temperature temperature
                    :max-tokens max-tokens :api-key api-key
                    :base-url base-url))
      ((eq provider :fake)
       (fake-chat-model :model model))
      (t (panic
          (format nil
                  "init-chat-model: unknown provider ~A (recognised: anthropic, openai, ollama, fake)"
                  provider))))))

(export 'init-chat-model)
(export 'parse-model-spec)
(export 'infer-provider)
