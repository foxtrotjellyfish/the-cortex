# Decision Log

Architectural decisions with full context. Each entry captures *why* we chose what we chose, so future sessions don't re-litigate settled questions.

---

## Format

```
### DEC-NNN: [Short Title]
**Date:** YYYY-MM-DD
**Status:** Decided | Implemented | Revisited | Superseded by DEC-NNN
**Area:** Architecture | UI | Dependencies | Data Model | ...

**Context:** What came up and why it needed a decision.

**Options considered:**
- **Option A** — [tradeoffs]
- **Option B** — [tradeoffs]

**Decision:** What we chose and the core reasoning.

**Consequences:** What this means going forward — costs, lock-in, follow-up work.
```

---

## Decisions

### DEC-001: Hybrid UI — LiveView Dashboard + API for Chat Clients
**Date:** 2026-04-08
**Status:** Decided
**Area:** UI | Architecture

**Context:** Cortex has two distinct UI surfaces: (1) an admin dashboard showing real-time agent state, signal flow, and traces, and (2) a human relay chat interface that feels like talking to one mind. The original plan used Phoenix LiveView for both. A challenger pass (9 subagents, 2 waves) tested this assumption against the team's experience building an astrology app with Phoenix API + React Native (Expo).

**Options considered:**
- **LiveView for everything** — Single codebase, single deployment, maximum BEAM integration. But: poor mobile WebSocket resilience, no push notifications, no offline capability, LLM code generation quality for LiveView is weaker than React. The astrology app team had already documented this: "agent/LLM support for LiveView is weak. Past attempts burned tokens and produced subpar results."
- **React/React Native for everything** — Best LLM code generation support, native mobile, rich component ecosystem. But: the admin dashboard benefits deeply from zero-gap BEAM integration (PubSub → LiveView is native, no serialization layer). Building a full API for dashboard state is weeks of work that LiveView eliminates.
- **Hybrid: LiveView for dashboard + API for chat** — Each surface uses the technology that fits its requirements. The dashboard is an engineering tool used on laptops; LiveView is ideal. The chat is a conversational product used on phones; native mobile with push notifications is essential.

**Decision:** Hybrid split. LiveView for the admin dashboard. Phoenix Channels API + React Native (Expo) for the human relay chat. The chat API surface is narrow (~4 REST endpoints + 1 Phoenix Channel). The React Native app lives in a separate repo and consumes the API.

**Consequences:**
- Two UI codebases: Phoenix LiveView (in this repo) and React Native (separate repo).
- The API module in Phoenix is small (~500 LOC) and stable — it exposes message send, session management, and a WebSocket channel.
- Dashboard gets the deepest possible BEAM integration (PubSub → DOM diff, no serialization).
- Chat gets genuine mobile UX (push notifications, offline history, session portability).
- The co-founder pattern (Phoenix API + React Native + Expo + Fly.io) is reusable infrastructure.
- SSE (Server-Sent Events) is a viable alternative to Channels for chat streaming — simpler for the asymmetric pattern. Consider for V1, upgrade to Channels if bidirectional needs emerge.

---

### DEC-002: Oban with SQLite for Durable Job Queue
**Date:** 2026-04-08
**Status:** Decided
**Area:** Dependencies | Architecture

**Context:** The V1 plan included Oban for durable async processing. The builder challenged this — Elixir's OTP already provides GenServer, Task.Supervisor, and PubSub. A hand-rolled queue is ~200-400 lines and integrates more tightly with Cortex's trace system. The challenger pass surfaced a factual correction: Oban now has official SQLite support via `Oban.Engines.Lite` (not just Postgres).

**Options considered:**
- **Oban Core + Oban.Engines.Lite (SQLite)** — Free, battle-tested, SQLite-compatible. Gives persistence, retries, concurrency limits, telemetry, scheduling out of the box. 15,000 LOC you don't maintain. The public API is simple (worker + `Oban.insert/1` + config).
- **Hand-rolled GenServer queue** — ~200-400 LOC. Tighter trace integration (job lifecycle events in the same Trace Collector pipeline). No external dep. LLM-understandable (any model can read 200 lines). But: you own every edge case (graceful shutdown, stuck job rescue, uniqueness constraints, crash recovery).
- **LOAT-as-queue (convergence path)** — The LOAT could subsume job persistence: signals are beams, job state = presence/absence of completion beams. Elegant but experimental. Process mailboxes provide the queuing; LOAT provides the persistence.

**Decision:** Use Oban Core with `Oban.Engines.Lite`. Wrap behind a thin `Cortex.Queue` module so the adapter can be swapped if needed.

**Rationale:**
- Oban + SQLite works. No Postgres required.
- Core Oban is free and open source. No Pro keys needed for V1 features.
- The hand-roll estimate of "200 lines" is optimistic — production-quality is 400-500 lines with retry logic, concurrency limiting, crash recovery, graceful shutdown, and test helpers.
- Oban's Elixir telemetry events integrate cleanly with the Trace Collector via subscription.
- The LOAT convergence path remains viable as a V2 experiment — Oban doesn't prevent it.

**Consequences:**
- `oban ~> 2.19` in `mix.exs`. Config: `engine: Oban.Engines.Lite, repo: Cortex.Repo`.
- Oban Pro is explicitly excluded. If Pro features are needed later, evaluate against hand-rolling.
- Queue config: `signals: 5, traces: 2, maintenance: 1` (concurrency limits per queue).
- The `Cortex.Queue.enqueue/4` wrapper provides the adapter boundary for future swaps.
- Oban migrations run alongside Cortex's own Ecto migrations.

---

### DEC-003: LOAT Informs the Data Model, Not a Separate Store (V1)
**Date:** 2026-04-08
**Status:** Decided
**Area:** Data Model | Architecture

**Context:** The Ledger of All Things (LOAT) — a one-table, two-type (pier/beam), append-only, observer-indexed data model — is a core concept in the project's lineage. A challenger pass explored whether LOAT should be: (a) a persistence adapter alongside Git/SQLite, (b) the unified persistence/signaling/tracing layer, or (c) deferred entirely. An adversarial skeptic review tested whether LOAT adds genuine value over existing tools (graph databases, event sourcing, CRDTs).

**The LOAT's genuine strengths (confirmed by skeptic):**
- Beams as first-class nodes (same table, same schema) is a real modeling win over standard property graphs.
- Observer-indexed, beam-level privacy is structurally different from simple multi-tenancy.
- The fractal recursion (beams targeting beams) without RDF's reification ceremony.
- The append-only constraint as physical/philosophical position.

**The LOAT's limits (confirmed by skeptic):**
- One table for everything means workloads compete for the same indexes. Traces need time-series access, jobs need queue semantics, knowledge needs graph traversal.
- Merkle tree federation is not new — it's Git/CouchDB/IPFS.
- "Observer-indexed" is access control with a philosophy degree. The code is `WHERE observer IN (...)`.
- LOAT is a protocol spec and interchange format, not a novel database engine.

**Decision:** The LOAT informs the Cortex data model — traces are piers, signals are beams, Ecto schemas reflect this vocabulary. But SQLite/Ecto remains the storage engine. The LOAT is not a separate persistence adapter in V1.

**Consequences:**
- `%Trace{}` structs carry pier-like properties (UUID, timestamp, immutable, referenceable).
- `%Signal{}` structs carry beam-like properties (source ref, target ref, relationship type).
- The SQLite schema is structurally a LOAT, even if not named as such.
- A formal LOAT/0.1 protocol spec is committed to `plans/loat-v0.1-spec.md` as a reference document.
- LOAT as a persistence adapter (`Cortex.Persistence.Adapters.LOAT`) is a V2 experiment.
- LOAT federation (Merkle sync between instances) is V3+.
- The convergence path (signals-as-beams, traces-as-LOAT) remains the long-term architectural vision.

**Deferred:**
- LOAT as a `.loat` file format for portable knowledge graphs.
- LOAT as an MCP resource (agents query via Model Context Protocol).
- Content-addressed IDs (ULID or hash-based) for dedup across instances.
- CRDT overlay for conflict-free merge between instances.
