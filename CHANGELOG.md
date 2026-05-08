# Changelog

## [0.1.0] — 2026-05-08

Initial release.

### Added

#### Foundation
- Plugin scaffolding mirroring the slip-* plugin pattern (Go entry, embedded Lisp under `slipagent/lisp/`, Lisp tests under `test/`).
- 13 message and content-block flavors: `human-message`, `system-message`, `ai-message`, `ai-message-chunk`, `tool-message`, `function-message`, plus content blocks `text-block`, `image-block`, `tool-use-block`, `tool-result-block`, `reasoning-block`, `redacted-reasoning-block`, `unknown-content-block` (catch-all for round-tripping unrecognised provider blocks).
- OpenAI-shape wire format conversion via `message->bag` and `bag->message`; `concat-chunks` merges streaming deltas into a final `ai-message`.

#### Runnable protocol
- Abstract `runnable` flavor with concrete `:invoke`/`:stream`/`:batch` template methods that dispatch to subclass-supplied `:invoke-impl`/`:stream-impl`/`:batch-impl`.
- `runnable-lambda` for lifting any one-arg Lisp function into a runnable.
- Composition via `pipe`, `parallel` (concurrent fan-out using `gi:run` + 1-cap channels), `branch` (predicate-driven selection), and `passthrough`.

#### Callbacks
- `base-callback-handler` flavor with no-op methods for 13 v0.1 events: chain (`:on-chain-start`/`-end`/`-error`), llm (`:on-llm-start`/`-end`/`-error`/`-new-token`), tool (`:on-tool-start`/`-end`/`-error`), retriever (`:on-retriever-start`/`-end`/`-error`).
- `*callback-error-mode*` dynamic var (default `:swallow`) controls whether a panicking handler aborts the dispatch chain.

#### Prompts and parsers
- `prompt-template` (single string with `{name}` substitution) and `chat-prompt-template` (list of role-keyed message templates) plus `messages-placeholder` for splice points.
- `string-output-parser`, `json-output-parser` (with `strip-json-fences` for the common ```` ```json ```` wrapper), and `bag-output-parser` (JSON parse + optional `:into` lambda for caller-supplied bag→instance coercion).

#### Tools
- `base-tool` flavor extending runnable; overrides `:invoke` to fire `:on-tool-*` events.
- `def-tool` macro generates a defun + defparameter binding the same symbol to both a callable function (Slip Lisp-2) and a tool instance.
- Tool input normalises any of: bag, JSON string, alist with keyword or string keys, or nil.
- `tool->openai-spec` and `tool->anthropic-spec` produce JSON Schema-shaped specs for both providers.

#### Chat models
- `chat-model` abstract template that fires `:on-llm-*` events.
- `:bind-tools` returns a fresh instance via `:copy` (subclasses override `:copy` to carry their own slots).
- `chat-anthropic` — full Messages API: prompt caching, vision, streaming via SSE, every documented content-block type plus an unknown-content-block catch-all.  **Level A reasoning support enforced**: agent-loop replay carries the full content-block list verbatim, including reasoning blocks with their cryptographic signatures.
- `chat-openai` — Chat Completions API with native structured output via `response_format: json_schema`.
- `chat-ollama` — thin chat-openai subclass pointed at localhost:11434.
- `fake-chat-model` — deterministic test fixture with scripted ai-message responses; exported so users can write hermetic agent tests.
- `init-chat-model "provider:model"` constructor with prefix inference (claude- → anthropic, gpt-/o1-/o3-/o4- → openai, llama/mistral/qwen/gemma → ollama).

#### HTTP / SSE / recording
- `post-json` and `post-json-stream` helpers around `net:http-client-flavor`.
- Generic SSE parser handling both Anthropic (`event:`+`data:`) and OpenAI (`data:`-only with `[DONE]`) framing.
- Test recording harness with `:replay` (default), `:record`, and `:live` modes driven by `AGENT_TEST_MODE` and `AGENT_LIVE_TESTS` env vars.  `make refresh-fixtures` captures real responses to disk for hermetic future runs.

#### Embeddings and vector stores
- `embeddings` abstract flavor.
- `fake-embeddings` (deterministic char-bucket hash, L2-normalised), `openai-embeddings` (text-embedding-3-small default), `voyage-embeddings` (voyage-3 default; reuses OpenAI's response parser).
- `in-memory-vector-store` (list of (document . embedding) pairs, cosine similarity) with `:as-retriever` returning a runnable that fires `:on-retriever-*` events.
- `document` flavor with page-content + metadata.

#### Chat history
- `base-chat-message-history` abstract; `in-memory-chat-message-history` with mutex-protected `:add-message`/`:add-messages`/`:messages`/`:clear`.

#### Agent
- `create-agent` returns a runnable that runs a tool-calling loop.
- Configurable: `:max-iterations` (default 25, panics on overrun), `:parallel-tool-calls` (default serial; opt-in goroutine-per-call), `:on-tool-error` (`:return-as-message` default — wraps panic as errored tool-message; `:raise` for debug), `:response-format` (defstruct symbol or schema bag), `:response-into` (one-arg coercion lambda).
- Native structured output on chat-openai/chat-ollama via the model's `response-format` slot; synthetic-respond fallback on chat-anthropic and others (appends a virtual `respond_with_final_answer` tool, terminates on its call).
- Unknown tool names produce error tool-messages rather than panicking — graceful degradation.

#### Tests
- 260 tests across 13 suites.  All pass in replay mode (the default `make test` path).  Real-API capture validated against the live Anthropic Messages API.

### Known limitations

See [PLAN.md "Out of scope for v0.1 — deferred to v0.2+"](PLAN.md#out-of-scope-for-v01--deferred-to-v02) for the full list with day-cost estimates.  Headline items:

- No `:thinking-budget` / `:reasoning-effort` keyword (Level A reasoning round-trip works, but enabling extended thinking on the request needs Level B work).
- Tool argument coercion is string-typed in v0.1 — defstruct introspection lands in v0.2.
- Soft-return on max-iterations not implemented; current behaviour is panic.
- No LangGraph state graphs, no LangSmith tracing, no async/await beyond channel-based streaming.
