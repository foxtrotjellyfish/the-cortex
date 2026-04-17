# The Cortex

**A nervous system for knowledge work.**

---

> **What this is:** A self-hosted orchestration engine — an Elixir/OTP application you clone and run on your own machine. Agents are OS-level processes (GenServers), not library calls. They're supervised, isolated, and independently restartable. The signal bus is IPC. The persistence layer is pluggable. No vendor cloud. No API keys to the engine itself. Your data never leaves your machine unless you tell it to.
>
> **What this is not:** Not a framework you `pip install`. Not a hosted platform you sign up for. Not another LangGraph / CrewAI / AutoGen — those are Python libraries for wiring LLM calls together within a single process. Cortex is closer to an **operating system** than a framework. Agents are long-lived processes with their own memory, their own lifecycle, and their own failure boundaries — the same model telecom switches have used since 1986.
>
> **The analogy:** If agent frameworks are **application libraries** (Rails, Django) and agent platforms are **cloud providers** (AWS, Heroku), then Cortex is **Linux** — the thing that runs underneath, that you own completely, and that doesn't care which applications you put on top or which cloud you don't use.
>
> Cortex enforces **[The Substrate](https://github.com/foxtrotjellyfish/the-substrate)** — a shared protocol layer (like POSIX for knowledge work) that makes your workspace portable across tools and models. Switch your LLM. Switch your IDE. The protocols survive.

Cortex is an Elixir/Phoenix engine where autonomous agents think in small, discrete pulses — not long conversations. Each agent owns one domain. Each pulse is one question to one model with one answer. Agents don't wait for each other. They send signals into the dark and trust the system to route them. The result feels like a single mind. Underneath, it's a thousand tiny decisions, each traceable, each replaceable, each independent.

You clone the repo. You configure your domains. The beehive starts.

## The Bet

Most AI systems are long conversations. A human opens a chat, types for an hour, and hopes the model remembers what happened at minute three. The context window fills. The model drifts. The human repeats themselves. The session ends and everything learned dies with it.

Cortex bets against this.

**One message in. One LLM call. One output. Done.** That's the atomic unit — a *micro-transaction*. Each one is bounded, traceable, and cheap. The agent reads what it needs from its domain's memory, composes a focused prompt, gets one answer, writes the result, and optionally sends a signal to other agents who might care. Then it goes back to sleep until the next message arrives.

No streaming. No multi-turn sessions. No waiting. The continuity that humans experience — the feeling of "talking to one mind" — is an illusion maintained by the Human Relay agent, which composes micro-transactions into conversation the same way your brain composes neural spikes into consciousness.

## The Architecture

```
Human (typing, speaking, uploading)
    ↓
Human Relay (domain agent — normalizes input, renders output)
    ↓
Router (decides where signals go — addressing, not thinking)
    ↓                    ↓                    ↓
Domain Agent         Domain Agent         Domain Agent
    ↓                    ↓                    ↓
LLM Adapter          LLM Adapter          LLM Adapter
(cloud API)          (local model)        (CLI tool)
    ↓                    ↓                    ↓
Persistence          Persistence          Persistence
(git + SQLite)       (Postgres)           (JSONL)
```

Every box is a GenServer — an Erlang/OTP process with its own mailbox, its own state, its own lifecycle. If one crashes, the supervisor restarts it. The others don't notice. This is what telecom switches have done since 1986. We're just running LLM calls where they used to run phone calls.

### Domain Agents

Each domain agent is a GenServer that follows one lifecycle:

**Idle → Receive → Process → Signal → Idle**

It subscribes to topics on the signal bus. When a signal arrives, it does the smallest possible unit of work: read context from its persistence layer, compose a prompt, call its LLM adapter, write the result, hand the output to the Router. The Router decides if anyone else should hear about it.

The agent doesn't know what other agents exist. It doesn't care. It finishes its work and goes quiet.

### The Router

The Router is deliberately unintelligent. It matches patterns, checks a routing table, and addresses envelopes. It does not reason about content. A router that thinks is an emperor. Cortex's router only delivers mail.

When the Router receives output from a domain agent, it decides: fan out to existing topics, create a new topic, send back for follow-up, batch with pending signals, or discard. New topics emerge organically when agents produce signals that don't match existing routes — the system grows new domains from pressure, not planning.

### LLM Adapters

The LLM adapter is a behaviour (interface) with pluggable implementations. One agent might use an API client. Another might shell out to a CLI tool via an Erlang Port. Another might hit a locally-hosted model. The domain agent doesn't know or care which. The contract: one prompt in, one response out, full trace metadata (model, tokens, cost, duration).

Cortex bets on interchangeable brains and stable nerves — the opposite of letting any single vendor own your nervous system.

### Persistence Adapters

Each domain agent configures its own persistence — one backend or many, simultaneously:

- **Git + Markdown** for human-readable, version-controlled knowledge
- **SQLite** for atomic local queries
- **Postgres** for shared, scalable storage
- **JSONL** for append-only simplicity
- **Encrypted storage** for compliance-sensitive domains

A single agent can write to git (for humans to read) AND SQLite (for machines to query) at the same time. Redundancy by design. The Accumulation protocol enforces append-only writes at the behaviour level — no adapter can overwrite history.

### The Human Relay

The Human Relay is a domain agent like any other. It subscribes to a `"human"` topic. When other agents want to surface something, they signal `"human"`. When the human types a message, the Relay normalizes it into a signal and hands it to the Router.

The Relay maintains conversational state to create the illusion of a long-running chat. But every turn is still a micro-transaction. The continuity is emergent from good state management, not a persistent LLM session. This means the conversation is portable — start on a laptop, continue on a phone, pick up on a different machine. The state lives in the Relay's persistence layer, not in any browser tab.

### Traces

Every micro-transaction is logged from day one. System prompt, input, model, adapter, output, outcome, cost, duration, signals emitted, persistence changes made. The Trace Collector stores everything in ETS (hot, in-memory) and optionally a durable store.

### Two Interfaces, One Engine

The **admin dashboard** (Phoenix LiveView) shows the beehive from above: running agents, real-time signal flow, trace history, agent detail. LiveView is deeply integrated with the BEAM runtime — agent state changes push to the browser with zero serialization.

The **human chat** is a Phoenix Channels API consumed by external clients. The chat interface lives in a separate repo (React Native / Expo for mobile, or any WebSocket client). This split reflects two different products: the dashboard is an engineering tool used on laptops; the chat is a conversational product used on phones. See `DECISIONS.md` DEC-001 for the full rationale.

## The Substrate

Underneath every domain agent, regardless of its role, runs the same protocol DNA — **[The Substrate](https://github.com/foxtrotjellyfish/the-substrate)**. Eight rules that every agent follows:

1. **Accumulation** — content is append-only. Never overwrite. Never consolidate without permission.
2. **Session Continuity** — every session produces a resumable handoff.
3. **Progressive Disclosure** — navigate in layers of increasing detail. Don't load everything.
4. **Agent Isolation** — specialized work in isolated contexts with scope boundaries.
5. **Learning Extraction** — experience becomes classified, reusable knowledge.
6. **Context Pressure** — preserve state before the context window fills.
7. **Temporal Anchoring** — every entry has a when and where.
8. **Feedback Loop** — the system teaches itself what matters.

The Substrate is not Cortex. The Substrate is the shared DNA. Cortex is the body that runs it. You can have many Cortex instances — personal, professional, experimental — each with different domains, different adapters, different content. They all share the same Substrate. When one instance improves a protocol, every instance benefits.

## Why Not...

**Why not long conversations?**
Cortex trades the comfort of one endless conversation for the inspectability of many small, replayable decisions. Long chats drift. Micro-transactions don't.

**Why not one agent that does everything?**
One agent that can do everything eventually does everything badly. Cortex splits "can" into "owns" and enforces it at process boundaries.

**Why not synchronous orchestration?**
Synchronous graphs optimize for legible control flow. Cortex optimizes for survival under delay and failure — the operating system problem, not the notebook problem.

**Why not lock into one AI tool?**
Tools change. Models change. Pricing changes. The adapter layer means Cortex doesn't care. Stable nerves, interchangeable brains.

**Why not one database?**
One database is a single point of semantic coupling. Each domain picks its own memory without sharing its schema.

**Why not a framework like LangGraph?**
OTP gives you semantics — supervision, isolation, and backpressure that still make sense when the hype cycle ends. Frameworks give you abstractions that expire.

## The Metaphor

Think of it as mycelium — a fungal network running underground, connecting separate trees through a shared protocol. Each hyphal tip (domain agent) probes its own patch of soil. Chemical signals (PubSub messages) propagate through the network without any tip needing to know the whole topology. When enough signal accumulates in one region, something fruits at the surface — a mushroom, a conversation, an insight.

Or think of it as a jazz ensemble. Each musician (agent) plays their own part. They share a harmonic language (the Substrate). Nobody stops the music to hold a committee meeting. The listener (the Human Relay) hears one piece. The players hear each other's signals and adjust. The music never stops.

Or think of your own mind. Each domain agent is a specialist fragment of the psyche — the career mind, the health mind, the creative mind. The Human Relay is the integrating function that turns a parliament of voices into a coherent narrative. Many minds inside, one voice out.

## Tech Stack

- **Elixir** / **Phoenix** — the body
- **OTP** (GenServer, Supervisor, PubSub) — the nervous system
- **LangChain Elixir** — LLM adapter layer (multi-provider)
- **InstructorLite** — structured outputs via Ecto schemas
- **Oban** — durable async job queue
- **Ecto** + SQLite / Postgres — trace storage, persistence adapter
- **Phoenix LiveView** — dashboard + human chat interface
- `**:telemetry`** — observability

## Status

Cortex is **pre-alpha**. The architecture is defined. A challenger pass (2026-04-08) locked key decisions. See `[DECISIONS.md](DECISIONS.md)` for the rationale, `[plans/](plans/)` for the implementation plan, and `[plans/loat-v0.1-spec.md](plans/loat-v0.1-spec.md)` for the knowledge protocol spec.

**What's validated so far:**

- Domain agent lifecycle (GenServer spawn → receive → process → signal → idle)
- PubSub signal routing between agents
- Graph-based fan-out / fan-in (Planner → N parallel Workers → Synthesizer)
- Shared memo store (SQLite) as inter-agent knowledge surface
- LLM adapters: Anthropic (cloud), Ollama (local), LlamaCpp (llama-server HTTP), Auto (smart fallback)
- OTP Port supervision of llama-server (crash recovery, health checks)
- Sub-second inference with quantized models on Apple Silicon; viable on constrained hardware
- Natural language decomposition outperforms JSON for sub-3B parameter models — the architecture handles structured coordination, not the model

## Why This Architecture

Recent research validates the bet Cortex makes. Multiple independent groups (ICLR 2025–2026, NeurIPS 2025, ICML 2025) have demonstrated that **structured collaboration between small models matches or exceeds monolithic large models** on standard benchmarks:

- **Coordination is a scaling axis.** Orchestrated ensembles of open-source models beat GPT-4o on evaluation benchmarks. The topology of inter-model communication matters as much as model choice.
- **OTP is uniquely suited.** The BEAM's lightweight processes, message passing, fault tolerance, and transparent distribution map directly onto multi-agent LLM orchestration. Cortex runs hundreds of concurrent agents in the memory footprint where Python frameworks struggle with ten.
- **The cascade pattern works.** Route easy tasks to small local models, escalate hard tasks to larger or cloud models. Production systems report 85% cost reduction at 95% quality maintenance. Cortex's pluggable adapter layer makes this a routing decision, not an architecture change.
- **Micro-transactions beat long conversations.** One message → one LLM call → one output. Each call is bounded, traceable, cheap, and independently supervised. No context window drift. No cascading failures. The continuity is emergent from good state management, not a persistent session.

The full research landscape — Mixture of Agents, FOCUS, Heterogeneous Swarms, model cascading, distributed inference on commodity hardware — converges on a thesis: the future isn't just bigger models, it's better orchestration of many models. OTP has been solving this class of problem since 1986.

## License

MIT