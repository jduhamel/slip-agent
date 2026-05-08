# slip-agent

LangChain-style agent toolkit for [Slip](https://github.com/ohler55/slip).

`slip-agent` re-implements the externally visible LangChain Python API in Slip Lisp: messages, runnables, tools, prompts, output parsers, three chat-model providers (Anthropic, OpenAI, Ollama), three embeddings providers (OpenAI, Voyage, fake), an in-memory vector store with retriever, callbacks, and a `create-agent` entry point that runs a tool-calling loop with optional structured output.

It's not a port — it's a Slip-idiomatic re-implementation of the same workflows.  See [PLAN.md](PLAN.md) for the design decisions and the v0.2 deferred list, and [SLIP-FOOTGUNS.md](SLIP-FOOTGUNS.md) for Slip-vs-CL gotchas surfaced during development.

## Install

```bash
cd plugins
git clone https://github.com/jduhamel/slip-agent.git
cd slip-agent
make build           # produces agent.so
```

The Makefile assumes the slip-agent checkout lives next to a slip checkout, with `replace github.com/ohler55/slip => ../..` in `go.mod`.

## Quickstart

```lisp
(require 'agent "plugins/slip-agent")

;; --- Single-turn chat -------------------------------------------------

(let ((model (init-chat-model "anthropic:claude-haiku-4-5")))
  (send model :invoke "What is the capital of France?"))

;; --- Tool-calling agent -----------------------------------------------

(let ()
  (def-tool calc-add (a b) "Adds two numbers." (+ a b))
  (def-tool calc-mul (a b) "Multiplies two numbers." (* a b))

  (let* ((model (init-chat-model "anthropic:claude-haiku-4-5"))
         (agent (create-agent
                 :model         model
                 :tools         (list calc-add calc-mul)
                 :system-prompt "You are a calculator.")))
    (send agent :invoke "What is (17 + 25) * 2?")))

;; --- Streaming --------------------------------------------------------

(let* ((model (init-chat-model "anthropic:claude-haiku-4-5"))
       (ch    (send model :stream "Tell me a story in one sentence.")))
  (range (lambda (chunk) (format t "~A" (send chunk :content))) ch))

;; --- RAG with in-memory vector store ----------------------------------

(let* ((emb       (fake-embeddings))     ;; or (openai-embeddings ...)
       (store     (in-memory-vector-store
                   :embeddings emb
                   :documents (list (document "Paris is the capital of France.")
                                    (document "Berlin is the capital of Germany."))))
       (retriever (send store :as-retriever 1))
       (model     (init-chat-model "anthropic:claude-haiku-4-5"))
       (chain     (pipe (parallel (list (cons :context  retriever)
                                        (cons :question (passthrough))))
                        (runnable-lambda
                         (lambda (alist)
                           (format nil "Context: ~A~%Q: ~A"
                                   (send (car (cdr (assoc :context alist))) :page-content)
                                   (cdr (assoc :question alist)))))
                        model
                        (string-output-parser))))
  (send chain :invoke "What is the capital of France?"))
```

Five runnable examples are in [`examples/`](examples).  Each works offline (with `fake-chat-model`) and against the real API when the relevant env var is set.

## Concept map (Python LangChain ↔ slip-agent)

| Python LangChain | slip-agent |
| --- | --- |
| `from langchain.chat_models import init_chat_model` | `(init-chat-model "...")` |
| `model.invoke(messages)` | `(send model :invoke messages)` |
| `model.stream(messages)` | `(send model :stream messages)` (returns a `gi:channel`) |
| `model.bind_tools([...])` | `(send model :bind-tools (list ...))` |
| `HumanMessage("hi")` | `(human-message "hi")` |
| `AIMessage(content="...")` | `(ai-message :content "...")` |
| `SystemMessage("rules")` | `(system-message "rules")` |
| `ToolMessage("ok", tool_call_id="x")` | `(tool-message "ok" "x")` |
| `@tool def calc(a, b): ...` | `(def-tool calc (a b) "..." ...)` |
| `RunnableLambda(fn)` | `(runnable-lambda fn)` |
| `r1 | r2 | r3` | `(pipe r1 r2 r3)` |
| `RunnableParallel({"a": r1, "b": r2})` | `(parallel (list (cons :a r1) (cons :b r2)))` |
| `StrOutputParser()` | `(string-output-parser)` |
| `JsonOutputParser()` | `(json-output-parser)` |
| `PydanticOutputParser(pydantic_object=X)` | `(bag-output-parser :into (lambda (b) ...))` |
| `ChatPromptTemplate.from_messages([...])` | `(chat-prompt-template-from-messages '(...))` |
| `MessagesPlaceholder("history")` | `(messages-placeholder :history)` |
| `InMemoryVectorStore(embeddings)` | `(in-memory-vector-store :embeddings ...)` |
| `vs.as_retriever(k=4)` | `(send vs :as-retriever 4)` |
| `Document(page_content="...", metadata={...})` | `(document "..." :metadata '(...))` |
| `BaseChatMessageHistory.add_message(m)` | `(send history :add-message m)` |
| `BaseCallbackHandler` | `base-callback-handler` (subclass and override) |
| `create_agent(model=..., tools=..., system_prompt=...)` | `(create-agent :model ... :tools ... :system-prompt ...)` |
| `agent.invoke(input)` | `(send agent :invoke input)` |
| `response_format=MyPydanticModel` | `:response-format 'my-defstruct :response-into (lambda (b) ...)` |

## Make targets

| Target | Effect |
| --- | --- |
| `make build` | Compile the `agent.so` plugin (`-buildmode=plugin`). |
| `make test` | Run the Lisp test suite in **replay** mode against committed fixtures.  Hermetic — no API keys required.  This is what CI runs. |
| `make test-live` | Same suite, every test pointed at the live provider.  Requires `AGENT_LIVE_TESTS=1` plus `ANTHROPIC_API_KEY`/`OPENAI_API_KEY` etc.  Run before a release cut. |
| `make refresh-fixtures` | Make real HTTP calls and overwrite each `test/fixtures/<provider>/*.json` with the captured response.  Same env-var requirements as `test-live`.  Commit any resulting fixture deltas. |
| `make clean` | Remove the `.so`. |

## Test count

260 tests across 13 suites: messages, callbacks, runnable, composition, prompts, output-parsers, tools, chat-models, anthropic, openai, ollama, init-chat-model, documents, chat-history, embeddings, vector-stores, agents.

## v0.1 scope

In: chat-anthropic + prompt-caching, chat-openai + native structured-output, chat-ollama, fake-chat-model.  Three embeddings providers.  In-memory vector store with retriever.  Tool calling via `def-tool`.  Agent loop with parallel tool-calls, configurable error handling, max-iterations, response-format on both native and synthetic-respond paths.  Level A reasoning preservation across loop replay.

Out (deferred to v0.2+): Level B reasoning support (`:thinking-budget` / `:reasoning-effort` keywords), full LangChain `astream_events` v2 protocol, soft-return on max-iterations, Anthropic server-side tools, OpenAI logprobs, LangSmith tracing, async/await beyond channel streaming, document loaders beyond in-memory lists, vector memory and summary memory, real defstruct introspection for tool argument coercion.  See [PLAN.md](PLAN.md#out-of-scope-for-v01--deferred-to-v02) for the full list with day-cost estimates.

## Acknowledgements

`slip-agent` follows LangChain's [Python framework](https://github.com/langchain-ai/langchain) for its concept names and workflow shapes.  Slip-idiomatic implementation throughout.

Slip is © Peter Ohler.  slip-agent is © Joe Duhamel.

## License

MIT
