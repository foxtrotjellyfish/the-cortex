# Cortex V1 — Implementation Plan

**Status:** Pre-build. Challenger pass complete (2026-04-08). Architecture decisions locked in `DECISIONS.md`.

---

## Guiding Principles

1. **Small, working increments.** Each phase produces something that runs.
2. **The GenServer IS the agent.** Don't over-abstract. A domain agent is a GenServer with a system prompt, subscriptions, and an LLM adapter.
3. **Micro-transactions first.** Get one message → one LLM call → one output working before adding complexity.
4. **Traces from day one.** Every LLM call is logged from the first commit. Observability is not a Phase N add-on.
5. **Markdown is the universal language.** Signals carry markdown. Persistence adapters read and write markdown (among other formats). Any human or agent can inspect the state.

---

## Phase 1: Scaffold

Create the Phoenix application.

```bash
mix phx.new cortex --no-mailer --no-dashboard --database sqlite3
```

SQLite for lightweight local instances. Ecto abstraction makes migration to Postgres a config change.

**Core dependencies (updated after challenger pass DEC-001, DEC-002):**


| Package                    | Purpose                                                            | V1?                       |
| -------------------------- | ------------------------------------------------------------------ | ------------------------- |
| `phoenix` (~1.8)           | Web framework                                                      | Essential                 |
| `phoenix_live_view` (~1.0) | Admin dashboard (DEC-001: LiveView for engineering view)           | Essential                 |
| `phoenix_pubsub` (~2.1)    | Signal bus                                                         | Essential                 |
| `ecto_sqlite3` (~0.17)     | Default persistence                                                | Essential                 |
| `oban` (~2.19)             | Durable async jobs — uses `Oban.Engines.Lite` for SQLite (DEC-002) | Essential                 |
| `langchain` (~0.8)         | LLM adapter layer                                                  | Essential                 |
| `req` (~0.5)               | HTTP client                                                        | Essential                 |
| `jason` (~1.4)             | JSON encoding                                                      | Essential                 |
| `bandit` (~1.6)            | HTTP server (Phoenix 1.8 default)                                  | Essential                 |
| `telemetry_metrics` (~1.0) | Observability                                                      | Essential                 |
| `telemetry_poller` (~1.1)  | Periodic telemetry events                                          | Essential                 |
| `instructor_lite` (~1.2)   | Structured outputs                                                 | Deferrable (add Phase 4+) |


**Supervision tree:**

```
Cortex.Application
├── Cortex.Repo (Ecto)
├── Phoenix.PubSub (signal bus)
├── Cortex.Trace.Collector (trace storage)
├── Cortex.Domain.Supervisor (DynamicSupervisor for agents)
├── Cortex.Router (signal routing)
├── Oban (job queue)
├── CortexWeb.Telemetry
└── CortexWeb.Endpoint (Phoenix)
```

**Deliverable:** App boots. LiveView loads. PubSub running. No domain agents yet.

---

## Phase 2: Domain Agent GenServer

The core abstraction. A behaviour that all domain agents implement.

```elixir
defmodule Cortex.Domain.Agent do
  @callback domain_name() :: atom()
  @callback system_prompt(state :: map()) :: String.t()
  @callback subscriptions() :: [String.t()]
end
```

**State struct:**

```elixir
%{
  domain: :example,
  system_prompt_template: "You are the example domain agent...",
  subscriptions: ["example", "system"],
  adapter: Cortex.LLM.Adapters.LangChain,
  adapter_config: %{model: "claude-sonnet-4", provider: :anthropic},
  persistence: [{Cortex.Persistence.Adapters.Git, path: "./workspace"}]
}
```

`Cortex.Domain.Supervisor` is a `DynamicSupervisor` that spawns agents from configuration.

**Deliverable:** Can start a domain agent, subscribe to PubSub topics, receive signals. LLM calls stubbed.

---

## Phase 3: Signal Bus + Router Agent

**Signal struct:**

```elixir
%Cortex.Signal{
  id: uuid,
  source: :example,        # which domain produced this
  content: "...",           # markdown
  priority: :normal,        # :urgent | :normal | :low
  metadata: %{parent_trace_id: uuid, timestamp: datetime}
}
```

**Router GenServer:** Domain agents hand output to the Router via `Cortex.Router.route/1`. The Router decides:

- Which existing topics should receive this signal?
- Does a new topic need to be created?
- Should this go back to the source for follow-up?
- Should this be batched?
- Should this be discarded?

Routing is **programmatic** — pattern matching, routing table, keyword matching. No LLM call in the common case. Unknown/ambiguous signals go to an `"unsorted"` topic.

**Deliverable:** Agent completes work → Router broadcasts to topics → receiving agents pick up signals.

---

## Phase 4: LLM Adapter Layer

```elixir
defmodule Cortex.LLM.Adapter do
  @callback call(prompt :: String.t(), input :: String.t(), config :: map()) ::
    {:ok, Response.t()} | {:error, term()}
end
```

**Implementations:**


| Adapter     | Mechanism                         | Use case                                     |
| ----------- | --------------------------------- | -------------------------------------------- |
| `LangChain` | API calls via `langchain` library | Cloud models (Anthropic, OpenAI, Gemini)     |
| `Ollama`    | HTTP to local Ollama instance     | Self-hosted models                           |
| `CLIPort`   | Erlang Port wrapping a CLI tool   | IDE-hosted agents (cursor-agent, claude CLI) |


**Micro-transaction struct:** Captures domain, system prompt, input, adapter, model, output, outcome (`:completed` / `:needs_followup` / `:discarded` / `:escalated`), signals emitted, persistence changes, and full trace.

**Deliverable:** One LLM call through the adapter. Full trace captured.

---

## Phase 5: Persistence Adapter Layer

```elixir
defmodule Cortex.Persistence.Adapter do
  @callback read(path :: String.t(), opts :: keyword()) :: {:ok, String.t()} | {:error, term()}
  @callback append(path :: String.t(), content :: String.t(), opts :: keyword()) :: :ok | {:error, term()}
  @callback list(prefix :: String.t(), opts :: keyword()) :: {:ok, [String.t()]} | {:error, term()}
end
```

No `write/3` exists. Only `append/3`. The Accumulation protocol is enforced at the behaviour level.

**Implementations:**


| Adapter  | Write strategy                    | Best for                           |
| -------- | --------------------------------- | ---------------------------------- |
| `Git`    | Batch commits on timer or trigger | Human-readable, version-controlled |
| `SQLite` | Immediate atomic writes           | Local queryability                 |
| `JSONL`  | Append to log file                | Simplest possible persistence      |


Each domain agent configures one or multiple adapters. Redundancy by design.

**Deliverable:** Domain agents read/append through configurable persistence.

---

## Phase 6: Trace Collector

GenServer that receives traces from all domain agents. ETS for hot queries. Ecto for durable storage.

Every micro-transaction is logged: domain, system prompt, input, model, adapter, output, outcome, cost, duration, signals emitted, persistence changes.

**Deliverable:** Every LLM call is logged. Queryable by domain, time, outcome.

---

## Phase 7: End-to-End (First Domain)

Wire everything together with a concrete domain agent. A simple "echo" agent that receives any signal, assesses it, processes via LLM, writes to persistence, emits a trace, and sends a signal back through the Router.

**Deliverable:** Full micro-transaction lifecycle working end-to-end.

---

## Phase 8: Oban Queue (DEC-002 — use Oban with SQLite)

Oban Core with `Oban.Engines.Lite` — official SQLite support, no Postgres required. Core is free and open source. Pro features (Smart Engine, Workflows) are paid and not needed for V1.

Config:

```elixir
config :cortex, Oban,
  engine: Oban.Engines.Lite,
  repo: Cortex.Repo,
  queues: [signals: 5, traces: 2, maintenance: 1]
```

Wrap behind `Cortex.Queue.enqueue/4` for adapter flexibility.

**Deliverable:** Signals survive engine restarts. Failed jobs retry with backoff. Queue concurrency limits prevent LLM API rate-limit saturation. Queue is inspectable via LiveView dashboard.

---

## Phase 9: LiveView Dashboard (DEC-001 — LiveView for engineering view)

The admin/engineering view. LiveView is the right choice here — PubSub → LiveView is native, zero serialization, deeply integrated with BEAM state.

- Running domain agents (name, status, message count, last activity)
- Real-time signal flow (live PubSub stream)
- Trace viewer (click a domain → see its micro-transactions)
- Agent detail (system prompt, subscriptions, adapter config)
- Oban queue status (pending, running, failed jobs)

Consider `live_svelte` for rich interactive visualizations (signal flow graphs, trace waterfalls) if LiveView's DOM diffing fights complex graphics.

**Deliverable:** Open browser, see all agents and their activity in real time.

---

## Phase 10: Human Relay + Chat API (DEC-001 — API for chat clients)

The Human Relay is a domain agent that bridges humans and the hive. The chat interface is NOT LiveView — it's a Phoenix Channels API consumed by external clients (React Native app in a separate repo, or any WebSocket client).

**API surface (narrow):**

- `POST /api/chat` — send a message
- `GET /api/sessions` — list sessions
- `POST /api/sessions` — new session
- `GET /api/sessions/:id` — session history
- Channel `chat:session_id` — real-time responses, typing indicators

**Properties:**

- Maintains conversational state for continuity illusion (each turn is still a micro-transaction)
- Session portability — state lives in Relay's persistence, not any browser/app
- Multi-modal input — typing, speech-to-text, file upload, normalized to signals
- Separate from the dashboard — simple API, clean contract

**Chat client (separate repo):** React Native (Expo) mobile app consuming this API. Reuses the co-founder pattern (Phoenix API + Expo + Tailscale + Fly.io). Push notifications via Expo. Offline message history via local storage.

**Alternative for V1:** SSE (Server-Sent Events) instead of full Channels for the streaming response pattern. Simpler for the asymmetric "human sends short, system streams long" flow. Upgrade to Channels if bidirectional needs emerge.

**Deliverable:** A human can chat with the system from any client. Messages route through the hive. Responses feel continuous. Session transfers between devices.

---

## Phase 11: Multi-Domain Configuration

Configure a Cortex instance with multiple domain agents from a config file. Each domain specifies: name, system prompt, subscriptions, LLM adapter, persistence adapters, routing rules.

**Deliverable:** Configurable multi-domain engine. Add a domain by adding config, not code.

---

## Phase 12: Deployment

Mix release + systemd service for self-hosted deployment. Environment config for API keys, workspace paths, git credentials.

**Deliverable:** Cortex running on a server. Accessible via browser. Processing signals continuously.

---

## Deferred (V2+)

- **LOAT persistence adapter** — implement `Cortex.Persistence.Adapters.LOAT` using the LOAT/0.1 spec (`plans/loat-v0.1-spec.md`). Test alongside Git/SQLite adapters. (DEC-003)
- **Signals-as-beams convergence** — refactor signal bus so emitting a signal creates a LOAT beam. PubSub becomes notification over beam creation.
- **Traces-as-LOAT convergence** — refactor trace collector to create LOAT piers/beams. Unifies engine cognition with domain knowledge.
- Slack / messaging platform adapters as alternative Human Relay interfaces
- A2A protocol (Agent-to-Agent) for cross-instance discovery and communication
- Qdrant integration for semantic search over traces
- Multi-model routing (dynamic model selection per signal complexity)
- Contextual bandit (learn which adapter+model combos succeed per domain)
- Hot code upgrade (BEAM's killer feature — update domain agents without stopping the engine)
- Cross-instance bridge (limited PubSub between Cortex instances)

## Deferred (V3+)

- **LOAT federation** — Merkle tree sync between Cortex instances. Delta exchange. Compliance fencing.
- **`.loat` file format** — portable knowledge graphs as gzip'd JSONL bundles with manifest.
- **LOAT as MCP resource** — agents query the LOAT through Model Context Protocol.
- **Content-addressed IDs** — ULID or hash-based, for dedup across instances.
- **CRDT overlay** — G-Set/2P-Set merge for conflict-free federation.

---

## Open Questions (Partially Resolved)

1. ~~**Domain config format.**~~ **Resolved (challenger pass):** Elixir config (`config/domains.exs`), runtime-loaded. Markdown config as V2 idea (reuse agent role files). Runtime-configurable via LiveView admin is Phase 11.
2. ~~**Router intelligence.**~~ **Resolved (challenger pass):** Programmatic only in V1. Pattern match + routing table. LLM-assisted routing is a V2 experiment.
3. ~~**Backpressure.**~~ **Resolved (DEC-002):** Oban queue limits. `queue: :signals, limit: 5` is the first backpressure valve.
4. **The Human Relay's model.** Still open. Might justify a more capable model for synthesis. Or micro-transactions with a fast model might be good enough. The adapter layer makes this a config choice.
5. **Substrate integration.** Still open. Git subtree is the current plan for `foxtrotjellyfish/the-substrate`.

