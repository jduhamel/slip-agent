# slip-agent — implementation plan

## Context

Re-implement LangChain's externally visible Python API as a Slip plugin (`slip-agent`), written primarily in Slip Lisp on top of Slip's existing Go-backed primitives. End state: a user can `(require :slip-agent)` and get message types, prompts, runnables, tools, three chat-model providers (Anthropic, OpenAI, Ollama), three embeddings providers (OpenAI, Voyage, fake), an in-memory vector store, callbacks, a recording test harness, and a `create-agent` entry point that runs a tool-calling loop with optional structured output.

**Stance:** inspired-by, not a port. Same concepts and workflows; spelled in Slip-idiomatic forms (macros where Python uses decorators, channels where Python uses async, plists where Python uses kwargs). Names match LangChain where they're industry-standard concepts (`human-message`, `chat-prompt-template`, `vector-store`, `create-agent`); Pythonisms get dropped or replaced.

Source-of-truth for the upstream surface: `/Users/joe/Dev/slip/external/langchain/libs/langchain_v1/` and `libs/core/`. Ignore `libs/langchain/` (frozen "langchain-classic") and partner integrations beyond the three providers above.

## Locked design decisions

| # | Decision |
| --- | --- |
| Object system | **Flavors** (`pkg/flavors`). Precedent: `pkg/net`'s `http-client-flavor`. |
| Method dispatch | `(send obj :method args)`. Composition helpers (`pipe`, `parallel`, `branch`) are free functions, not methods. |
| Method names | Plain (`:invoke`, `:stream`, `:batch`, `:bind-tools`, `:embed-query`). No `:agent-` prefix. |
| Runnable surface | `:invoke`, `:stream`, `:batch`. Plus `runnable-lambda`, `pipe`, `parallel`, `branch` as free functions. |
| Config plumbing | Plist `&key` arguments threaded through `:invoke`/`:stream`/`:batch`. Forward-unknown helper for wrappers. |
| Streaming | `:stream` returns a `gi:channel` of `ai-message-chunk` instances; close = end. Producer goroutine inside `:stream`. Consumer uses `gi:range` or explicit `(channel-pop)` loop. `:invoke` and `:stream` are both abstract per provider — distinct request bodies, no faked streaming-from-non-streaming. |
| Message content | `content` is string OR list of content blocks. Block flavors: `text-block`, `image-block`, `tool-use-block`, `tool-result-block`, `reasoning-block`, `redacted-reasoning-block`, `unknown-content-block` (catch-all). `(message-text msg)` collapses to string. |
| Tool calls | Computed lazily via `(send msg :tool-calls)` from content blocks. Not stored. |
| Streaming chunks | Distinct `ai-message-chunk` flavor with `(concat-chunks chunks)` → final `ai-message`. |
| Tool macro | `(def-tool name (a b) "Description." [:schema 'struct-name] body)`. Defun-shaped; schema optional; lambda-list binding inside body. |
| Tool args schema | `defstruct` (`(defstruct calc-args (a 0 :type integer :doc "..."))`). Same struct doubles as response-format type for structured output. |
| Tool registry | Package-local `agent::*tools*` hash (powers REPL discoverability + completion). `create-agent` requires explicit `:tools` list. |
| Agent loop bound | `:max-iterations` default 25, **panic on overrun** (TODO post-0.1: revisit soft-return-with-truncated-marker). |
| Multiple tool calls | `:parallel-tool-calls` keyword, default serial; opt-in parallel via `gi:routine` + `gi:channel`. |
| Tool error handling | `:on-tool-error` keyword, default `:return-as-message`; alternative `:raise`. |
| Structured output | `:response-format 'struct-name` — uses synthetic terminal tool on Anthropic/Ollama; native `response_format: json_schema` on OpenAI; parses to `defstruct` instance via `bag-output-parser`. |
| Reasoning support | **Level A only**: agent loop replays full content-block list verbatim (preserves any reasoning/unknown blocks). No explicit `:thinking-budget`/`:reasoning-effort` keyword in v0.1. |
| Callback firing | **Explicit dispatch in abstract templates**: `:invoke` is concrete on the base flavor, fires `:on-X-start`, calls `:invoke-impl`, fires `:on-X-end`. Subclasses override `:invoke-impl`. Same shape for `:stream`/`:batch`. |
| Callback events (v0.1) | 13 events: chat-model `:on-llm-start/-end/-error/-new-token`; tool `:on-tool-start/-end/-error`; retriever `:on-retriever-start/-end/-error`; chain `:on-chain-start/-end/-error`. |
| Callback handler errors | `*callback-error-mode*` dynamic var, default `:swallow` (warn via `cl:warn`). Alt: `:propagate`. |
| Provider scope | Chat: Anthropic + OpenAI + Ollama + `fake-chat-model` (publicly exported test fixture). Embeddings: OpenAI + Voyage + `fake-embeddings`. |
| Provider features | Text + tools + streaming + vision + Anthropic prompt caching + OpenAI `response_format: json_schema`. |
| Plugin layout | Mongo pattern. `slipagent/` Go subdir, `slipagent/lisp/` embedded via `//go:embed`, `slip-agent/test/` outside the Go package. |
| Slip package | Name `slip-agent`, nickname `agent`. Conservative export — entry points only; internal flavor names are `agent::`-qualified for subclassers. |
| Tests | Lisp `.lisp` files using `pkg/test`'s `defsuite`. One test file per source file. Recording harness under `test/recorder.lisp` intercepts `net:http-client-flavor` for fixture record/replay. Fixtures committed to `test/fixtures/<provider>/`. |
| Live API tests | Gated behind `agent::*live-tests*` + provider env vars. CI runs fixtures only; release-cut + `make test-live` run live. |

## Day-by-day

Each day ends with a green Lisp test file and a runnable demo at the REPL. Tests live in `slip-agent/test/<name>_test.lisp`.

### D1 — Plugin scaffolding + messages + content blocks

Files: `main.go`, `go.mod`, `Makefile`, `slipagent/pkg.go`, `slipagent/lisp.go`, `slipagent/lisp/messages.lisp`, `test/tests.lisp`, `test/messages_test.lisp`.

- Go scaffolding mirroring `plugins/slip-mongo`: `main.go` blank-imports `slipagent`; `pkg.go` defines `var Pkg = slip.Package{Name: "slip-agent", Nicknames: []string{"agent"}, …}`, `init()` runs `Pkg.Initialize` then the `Use` chain (`cl`, `gi`, `bag`, `flavors`, `clos`, `generic`, `net`), then `loadLisp()`, then `slip.UserPkg.Use(&Pkg)`.
- `lisp.go` uses `//go:embed lisp` and an ordered file list (dependency-bottom-up).
- `messages.lisp`: `base-message` abstract; `human-message`, `system-message`, `tool-message` (with `tool-call-id`), `function-message` (with `name`), `ai-message` (with `response-metadata`, content-blocks), `ai-message-chunk`.
- Content blocks (in `messages.lisp` to keep load order simple): `text-block`, `image-block`, `tool-use-block` (with `id`, `name`, `input`), `tool-result-block` (with `tool-use-id`, `content`, `is-error`), `reasoning-block` (with `text`, `signature`), `redacted-reasoning-block` (with `data`), `unknown-content-block` (catch-all with raw bag).
- Helpers: `(message-text msg)` (concat all text blocks or return string), `(send msg :tool-calls)` (walk content blocks for tool-use-blocks), `(concat-chunks list)` → `ai-message`.
- Wire-format conversion: `(message->bag msg)` and `(bag->message bag :role role)` for OpenAI-style; Anthropic format uses content-block list directly.
- **Demo:** `(require :slip-agent)` loads cleanly. `(human-message "hi")` returns an instance. `(message-text (ai-message :content (list (text-block "a") (text-block "b"))))` → `"ab"`.

### D2 — Runnable protocol + callbacks foundation

Files: `slipagent/lisp/callbacks.lisp`, `slipagent/lisp/runnable.lisp`, `test/callbacks_test.lisp`, `test/runnable_test.lisp`.

- `callbacks.lisp`: `base-callback-handler` flavor with no-op methods for all 13 events. `*callback-error-mode*` dynamic var (default `:swallow`). `(fire-event event-key handlers receiver &rest data)` helper that dispatches sequentially with error-mode handling.
- `runnable.lisp`: `runnable` abstract flavor. Concrete `:invoke`/`:stream`/`:batch` template methods that:
  1. Extract `:callbacks` and other config from the `&key` plist.
  2. Fire `:on-X-start`.
  3. Call `:invoke-impl`/`:stream-impl`/`:batch-impl` (subclass duty), wrapping in a panic-recover that fires `:on-X-error` and re-raises.
  4. Fire `:on-X-end`.
- Default `:batch-impl` loops `:invoke-impl` over inputs.
- Default `:stream-impl` returns a 1-element channel from `:invoke-impl`.
- `runnable-lambda` flavor wrapping a Lisp function; its `:invoke-impl` calls the function.
- `(forward-config plist known-keys)` helper for wrappers.
- **Demo:** `(send (runnable-lambda :func #'1+) :invoke 5)` → `6`. With a recording handler, the same call fires `:on-chain-start` and `:on-chain-end` events.

### D3 — Composition (pipe, parallel, branch)

Files: `slipagent/lisp/composition.lisp`, `test/composition_test.lisp`.

- `runnable-sequence` flavor with a `:steps` slot. `:invoke-impl` threads input forward; `:stream-impl` only streams the last step (earlier steps invoke fully first). Fires chain events around the whole sequence.
- `runnable-parallel` flavor with an `:alist` slot. `:invoke-impl` spawns one `gi:routine` per child, joins via channels, returns an alist of results in alist order. Children share the same `:callbacks` list.
- `runnable-branch` flavor with `:cases` (list of `(predicate runnable)`) + `:default`. `:invoke-impl` evaluates predicates against the input until one matches.
- `passthrough` runnable (returns input unchanged) for use inside `parallel`.
- Free functions: `(pipe r1 r2 r3 …)`, `(parallel alist)`, `(branch cases default)`.
- **Demo:** RAG-shape composition working: `(pipe (parallel `((:context . ,retriever) (:question . ,(passthrough)))) prompt model parser)` (verified end-to-end at D12; D3 verifies the shape with stubs).

### D4 — Prompts

Files: `slipagent/lisp/prompts.lisp`, `test/prompts_test.lisp`.

- `prompt-template` flavor (single string with `{name}` placeholders). `:format` substitutes; `:invoke-impl` returns `prompt-value` instance.
- `chat-prompt-template` flavor (list of `(role-keyword template-string-or-placeholder)` pairs). `:format-messages` returns a list of message instances; `:invoke-impl` returns same as a `prompt-value`.
- `messages-placeholder` — placeholder that splices in a list of messages from the input alist.
- Constructors: `(prompt-template-from-template "...")`, `(chat-prompt-template-from-messages '((:system "...") (:human "...")))`.
- Error on missing keys (panic, not silent empty string).

### D5 — Output parsers

Files: `slipagent/lisp/output-parsers.lisp`, `test/output-parsers_test.lisp`.

- `output-parser` abstract (extends `runnable`). `:parse` is the subclass duty; default `:invoke-impl` extracts `content` from an `ai-message`-like input and calls `:parse`.
- `string-output-parser` — returns the string content (collapses content blocks via `message-text`).
- `json-output-parser` — calls `bag-parse`. Panics on parse failure.
- `bag-output-parser` — parses bag, then coerces into a `defstruct` instance specified at construction (`:into 'calc-args`). Reused by D12 for `:response-format`.

### D6 — Tools + def-tool macro

Files: `slipagent/lisp/tools.lisp`, `test/tools_test.lisp`.

- `base-tool` flavor with `name`, `description`, `args-schema`, `func` slots. `:invoke-impl` extracts args from input bag, coerces (typed schema only), calls `func`. Fires tool events.
- `structured-tool` — synonym for `base-tool` with `:schema` set. (LangChain distinguishes these; we don't need to.)
- `def-tool` macro:
  - Lambda-list-shaped: `(def-tool name (a b c) "docstring" [:schema 'struct-name] body…)`.
  - Generates a `make-instance 'base-tool` form. With `:schema`, slot order in the struct must match lambda-list order — macro asserts at expansion time.
  - Without `:schema`, all args treated as `:any` type; bag values pass through unmodified.
  - Registers the resulting tool in `agent::*tools*` keyed by name; returns the tool instance bound to the symbol `name`.
- Schema-to-JSON-schema converters: `(tool->openai-spec t)` and `(tool->anthropic-spec t)`. Walks `defstruct` slot definitions for types and docs.
- **Demo:** `(def-tool calc (a b) "Adds two integers." (+ a b))` then `(send calc :invoke (bag-from-json "{\"a\":1,\"b\":2}"))` → `3`.

### D7 — Chat-model abstract + recording harness + fake-chat-model + HTTP/SSE primitives

Files: `slipagent/lisp/http-helpers.lisp`, `slipagent/lisp/sse.lisp`, `slipagent/lisp/chat-models.lisp`, `slipagent/lisp/fake-chat-model.lisp`, `test/recorder.lisp`, `test/chat-models_test.lisp`.

- `http-helpers.lisp`: `(agent::post-json url headers body)` wrapping `net:http-client-flavor` `:post`, returning a parsed bag.
- `sse.lisp`: `(stream-sse-events response channel)` reads `(send response :body)` line by line, parses `data: …` frames into bags, pushes onto the channel, closes on `[DONE]` or stream end. Pure Lisp.
- `chat-models.lisp`: `chat-model` abstract (extends `runnable`). Slots: `model`, `temperature`, `max-tokens`, `tools`, `api-key`, `base-url`. `:bind-tools` returns a copy with tools set. `:with-structured-output 'struct-name` returns a wrapping runnable that pipes through `bag-output-parser`. `:invoke-impl`/`:stream-impl` are abstract.
- `fake-chat-model.lisp`: `fake-chat-model` flavor with `:scripted-responses` slot — a list of `ai-message` instances returned in order. Used by every D12 agent test and exposed publicly so users can write hermetic tests.
- `test/recorder.lisp` (~40 lines): wraps `net:http-client-flavor`'s POST with a `*test-mode*` dispatch — `:record` writes request+response to `test/fixtures/<provider>/<test-name>.json`; `:replay` reads from disk; `:live` passes through. Uses dynamic binding so each test selects its mode.

### D8 — Anthropic provider

Files: `slipagent/lisp/providers/anthropic.lisp`, `test/anthropic_test.lisp`, `test/fixtures/anthropic/*.json`.

- `chat-anthropic` extends `chat-model`. `:invoke-impl` builds Anthropic request body (system extracted from messages, tools serialized via `tool->anthropic-spec`, content blocks mapped per Anthropic's schema), POSTs to `https://api.anthropic.com/v1/messages`, parses response content blocks into `ai-message`. **All content-block types preserved verbatim, including `unknown-content-block` for any future block type.** This is the Level A reasoning-support guarantee.
- Prompt caching: `:cache-control t` keyword on the chat-model OR per-message annotation. Adds `cache_control: {type: "ephemeral"}` to the appropriate content blocks per Anthropic's caching rules.
- `:stream-impl` POSTs with `stream: true`, uses `stream-sse-events` to push parsed `content_block_delta` events, accumulates them into `ai-message-chunk` instances on a channel.
- Env var: `ANTHROPIC_API_KEY` via `gi:getenv`.
- Recorded fixtures for: text-only invoke, invoke-with-tools, invoke-with-vision, multi-chunk stream, streaming-with-tool-use, prompt-caching round-trip.

### D9 — OpenAI provider + Ollama + structured outputs

Files: `slipagent/lisp/providers/openai.lisp`, `slipagent/lisp/providers/ollama.lisp`, `test/openai_test.lisp`, `test/ollama_test.lisp`, `test/fixtures/openai/*.json`, `test/fixtures/ollama/*.json`.

- `chat-openai` extends `chat-model`. POSTs to `https://api.openai.com/v1/chat/completions`. Tool calls under `choices[0].message.tool_calls`; chunk events under `choices[0].delta`. Vision via `image_url` content parts.
- Structured outputs: `:response-format` keyword on `:invoke` plumbs through to `response_format: {type: "json_schema", json_schema: …}` natively. Schema generated from `defstruct` slots.
- `chat-ollama` extends `chat-openai` with `:base-url` defaulting to `http://localhost:11434/v1`. Overrides for OpenAI-compat quirks (some models reject system role, etc.).
- Env var: `OPENAI_API_KEY` for OpenAI; Ollama needs no key.
- Recorded fixtures for both providers.

### D10 — init-chat-model + documents + chat-history

Files: `slipagent/lisp/init-chat-model.lisp`, `slipagent/lisp/documents.lisp`, `slipagent/lisp/chat-history.lisp`, `test/init-chat-model_test.lisp`, `test/documents_test.lisp`, `test/chat-history_test.lisp`.

- `init-chat-model.lisp`: `(init-chat-model spec &key model-provider …)` parses `"provider:model"`, falls back to prefix inference (`"claude-*"` → anthropic, `"gpt-*"`/`"o1-*"`/`"o3-*"` → openai). Ambiguous strings (`"claude"` alone) panic with a clear error.
- `documents.lisp`: `document` flavor with `page-content` and `metadata` slots.
- `chat-history.lisp`: `base-chat-message-history` abstract; `in-memory-chat-message-history` with mutex protection via `gi:make-mutex`. Methods: `:add-message`, `:add-messages`, `:messages`, `:clear`.

### D11 — Embeddings + vector store + retriever

Files: `slipagent/lisp/embeddings/base.lisp`, `slipagent/lisp/embeddings/fake.lisp`, `slipagent/lisp/embeddings/openai.lisp`, `slipagent/lisp/embeddings/voyage.lisp`, `slipagent/lisp/vector-stores.lisp`, `test/embeddings_test.lisp`, `test/vector-stores_test.lisp`, `test/fixtures/openai-embeddings/*`, `test/fixtures/voyage-embeddings/*`.

- `embeddings` abstract flavor (extends `runnable`). Methods: `:embed-documents (list-of-strings)`, `:embed-query (string)`. `:invoke-impl` aliases to `:embed-query`.
- `fake-embeddings` — deterministic SHA-256-based 384-dim vector. No network.
- `openai-embeddings` — `text-embedding-3-small` by default. POSTs to `/v1/embeddings`.
- `voyage-embeddings` — `voyage-3` by default. POSTs to `https://api.voyageai.com/v1/embeddings`. Env: `VOYAGE_API_KEY`.
- `vector-store` abstract: `:add-documents`, `:similarity-search`, `:as-retriever`.
- `in-memory-vector-store` — list of `(document . embedding)` tuples; cosine similarity in pure Lisp.
- `vector-store-retriever` (extends `runnable`). `:invoke-impl` returns top-k documents; fires `:on-retriever-start`/`-end`/`-error`.

### D12 — create-agent

Files: `slipagent/lisp/agents.lisp`, `test/agents_test.lisp`.

- `(create-agent &key model tools system-prompt max-iterations parallel-tool-calls on-tool-error response-format)` returns a runnable.
  - Defaults: `max-iterations` 25, `parallel-tool-calls` nil, `on-tool-error` `:return-as-message`, `response-format` nil.
  - With `response-format` non-nil and provider supports native (OpenAI): pass through to chat-model. Otherwise: append a synthetic terminal tool whose `args-schema` is the response-format struct; system prompt amended to instruct the model to call this tool when answering.
- Loop:
  1. Initial messages: optional system + user input (string → wrapped in `human-message`).
  2. `(send (send model :bind-tools tools) :invoke messages :callbacks …)`.
  3. **Replay rule:** when appending the assistant message back to the history for the next turn, preserve the full `content` (string OR full content-blocks list). This is the Level A reasoning-support guarantee — no reconstruction from `text + tool_calls`.
  4. If no tool-calls: terminate. Result is the `ai-message`, or the parsed `defstruct` if `response-format` was native, or the synthetic-tool's args parsed via `bag-output-parser` if synthetic.
  5. Otherwise: dispatch tool calls (serial or parallel via `gi:routine`), append `tool-message` for each. Tool panics: per `on-tool-error`, either re-raise or append a tool-message with the error text and continue.
  6. Decrement iteration counter; if zero, panic `agent-max-iterations-exceeded`.
- `:stream-impl` mirrors but yields chunks for each LLM step (not for tool calls).
- Tests use `fake-chat-model` with scripted tool-call responses; tool dispatch verified with a `def-tool`'d adder; max-iterations panic verified; `response-format` round-trip verified.

### D13 — Examples + README + polish + v0.1.0

Files: `examples/01-chat.lisp`, `examples/02-streaming.lisp`, `examples/03-tool-agent.lisp`, `examples/04-rag.lisp`, `examples/05-structured-output.lisp`, `README.md`, `CHANGELOG.md`.

- `01-chat.lisp` — single-turn `init-chat-model` + `:invoke`.
- `02-streaming.lisp` — `gi:range` consumption of `:stream` channel.
- `03-tool-agent.lisp` — calculator tool via `def-tool` + `create-agent`.
- `04-rag.lisp` — load documents into `in-memory-vector-store` via `openai-embeddings`, retriever piped into a chat model.
- `05-structured-output.lisp` — `:response-format` returning a `defstruct` instance.
- `README.md` — install, quickstart, mapping table (Python ↔ Slip), pointer to PLAN.md and the deferred list.
- `CHANGELOG.md` — v0.1.0 entry.
- Final pass: `make` (build plugin), `make test` (Lisp suite, fixtures only), `make test-live` (gated, with API keys), root `make test-plugins` (plugin-load smoke).
- Tag `v0.1.0`.

## Out of scope for v0.1 — deferred to v0.2+

| Item | Day-cost when picked up |
| --- | --- |
| Reasoning support **Level B** — explicit `:thinking-budget` (Anthropic) / `:reasoning-effort` (OpenAI), thinking-delta streaming, signature preservation as a first-class API | ~0.7 day |
| Soft-return-with-truncated-marker on `:max-iterations` overrun (alternative to panic) | ~0.2 day |
| Anthropic server-side tools (web search, code execution) | ~0.5 day |
| OpenAI logprobs surface | ~0.3 day |
| Full LangChain `astream_events` v2 protocol with the structured event taxonomy | ~1 day |
| Callback events: `:on-text`, `:on-agent-action`, `:on-agent-finish`, `:on-custom-event`, `:on-chat-model-start` (separate from `:on-llm-start`) | ~0.3 day |
| LangGraph state graphs / checkpointers | weeks (separate plugin: slip-graph) |
| LangSmith tracing protocol | ~2 days |
| Async/await semantics beyond channel-based streaming | n/a — Slip has no async; all "async" is channel-based by design |
| Pydantic-specific schema features (`Field`, validators, computed fields) | ~0.5 day on top of `defstruct` |
| `langchain-classic` legacy surface (`libs/langchain/`) | won't ship — frozen upstream |
| Document loaders (file, URL, Notion, S3, etc.) | downstream plugins |
| Memory beyond message history (vector memory, summary memory) | ~1 day |
| `with-retry` / `with-fallbacks` runnable wrappers | ~0.5 day |
| Token-counting utilities and cost reporting | ~0.5 day |

## Verification

End-to-end smoke test that should work after D13:

```lisp
(require :slip-agent)
(use-package :agent)

(def-tool calc (a b)
  "Adds two integers."
  (+ a b))

(let* ((model (init-chat-model "anthropic:claude-opus-4-7"))
       (agent (create-agent :model model
                            :tools (list calc)
                            :system-prompt "You answer math problems by calling the calc tool.")))
  (send agent :invoke "What is 17 plus 25?"))
;; => #<ai-message content="17 + 25 = 42">
```

Plus the four other example files (D13) running cleanly.

## File layout at v0.1.0

```
slip-agent/
├── PLAN.md
├── README.md
├── CHANGELOG.md
├── LICENSE
├── Makefile
├── go.mod
├── main.go
├── slipagent/
│   ├── pkg.go
│   ├── lisp.go
│   └── lisp/
│       ├── messages.lisp
│       ├── callbacks.lisp
│       ├── runnable.lisp
│       ├── composition.lisp
│       ├── prompts.lisp
│       ├── output-parsers.lisp
│       ├── tools.lisp
│       ├── http-helpers.lisp
│       ├── sse.lisp
│       ├── chat-models.lisp
│       ├── fake-chat-model.lisp
│       ├── providers/
│       │   ├── anthropic.lisp
│       │   ├── openai.lisp
│       │   └── ollama.lisp
│       ├── init-chat-model.lisp
│       ├── documents.lisp
│       ├── chat-history.lisp
│       ├── embeddings/
│       │   ├── base.lisp
│       │   ├── fake.lisp
│       │   ├── openai.lisp
│       │   └── voyage.lisp
│       ├── vector-stores.lisp
│       └── agents.lisp
├── test/
│   ├── tests.lisp
│   ├── recorder.lisp
│   ├── fixtures/
│   │   ├── anthropic/
│   │   ├── openai/
│   │   ├── ollama/
│   │   ├── openai-embeddings/
│   │   └── voyage-embeddings/
│   ├── messages_test.lisp
│   ├── callbacks_test.lisp
│   ├── runnable_test.lisp
│   ├── composition_test.lisp
│   ├── prompts_test.lisp
│   ├── output-parsers_test.lisp
│   ├── tools_test.lisp
│   ├── chat-models_test.lisp
│   ├── anthropic_test.lisp
│   ├── openai_test.lisp
│   ├── ollama_test.lisp
│   ├── init-chat-model_test.lisp
│   ├── documents_test.lisp
│   ├── chat-history_test.lisp
│   ├── embeddings_test.lisp
│   ├── vector-stores_test.lisp
│   └── agents_test.lisp
└── examples/
    ├── 01-chat.lisp
    ├── 02-streaming.lisp
    ├── 03-tool-agent.lisp
    ├── 04-rag.lisp
    └── 05-structured-output.lisp
```
