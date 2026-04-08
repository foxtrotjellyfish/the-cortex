# Cortex — Agent Instructions

**If you are an AI agent working in this repository, read this file first.**

---

## What This Repo Is

Cortex is a standalone orchestration engine. It is a generic, domain-agnostic Elixir/Phoenix application that hosts autonomous domain agents as GenServers. It does not belong to any specific person, company, workspace, or deployment. It is the engine. Not the car.

## What You Know

You know about:

- **This repo.** The README, the implementation plan in `plans/`, and whatever code exists in `lib/`.
- **The Substrate.** The shared protocol layer at [foxtrotjellyfish/the-substrate](https://github.com/foxtrotjellyfish/the-substrate). Cortex enforces these eight protocols for all domain agents. You may reference, discuss, and propose changes to the Substrate.
- **The Elixir/OTP ecosystem.** GenServer, Supervisor, PubSub, Oban, Phoenix, LiveView, LangChain Elixir, Ecto — the tech stack described in the README.
- **The architecture.** Micro-transactions, domain agent lifecycle, Router, LLM adapters, persistence adapters, Human Relay, traces. All documented in the README and plan.

## What You Do NOT Know

You know **nothing** about:

- **Any instance running this engine.** Cortex may be deployed as a personal knowledge workspace, a corporate tool, an open-source experiment, or something that doesn't exist yet. You don't know which. You don't ask.
- **Any user's data, domains, or content.** The domains configured on a running Cortex instance — their names, their system prompts, their knowledge, their signals — are none of this repo's business.
- **Any company, person, or organization.** No employer names, no employee names, no product names, no deployment locations, no machine identifiers. If a contributor accidentally includes instance-specific details in a PR or issue, flag it for removal.
- **Any specific LLM provider relationship.** Cortex is adapter-agnostic. Don't assume Anthropic, OpenAI, or any specific provider. The adapter layer exists so that the engine doesn't need to care.

## Why This Boundary Exists

Cortex instances may run in environments with compliance requirements (HIPAA, SOC2, etc.), proprietary business data, or personal information that must never leak upstream. The boundary is simple:

**Information flows DOWN from Cortex to instances. Improvements flow UP from instances to Cortex. Content never flows up.**

```
Instance A (private)     Instance B (private)     Instance C (private)
     ↓ clones                 ↓ clones                 ↓ clones
     ↓                        ↓                        ↓
┌────────────────────────────────────────────────────────────┐
│                     CORTEX (the engine)                     │
│                                                            │
│  What flows UP:                                            │
│  - Bug fixes to engine code                                │
│  - New adapter implementations                             │
│  - Performance improvements                                │
│  - Substrate protocol proposals                            │
│  - Generic patterns (not instance-specific content)        │
│                                                            │
│  What NEVER flows up:                                      │
│  - Domain names, system prompts, or signal content         │
│  - User data, company data, or deployment details          │
│  - Machine identifiers, API keys, or credentials           │
│  - Anything that identifies the instance or its operator   │
└────────────────────────────────────────────────────────────┘
     ↓ subtree                                    
┌────────────────────────────────────────────────────────────┐
│                  THE SUBSTRATE (shared DNA)                 │
│                                                            │
│  What flows UP from Cortex:                                │
│  - Protocol refinements validated across multiple instances │
│  - New protocol proposals                                  │
│  - Corrections to protocol definitions                     │
│                                                            │
│  What NEVER flows up:                                      │
│  - Same rules as Cortex — no instance-specific content     │
└────────────────────────────────────────────────────────────┘
```

## How to Work in This Repo

1. **Stay generic.** When writing code, docs, or examples, use placeholder names (`"example"`, `"domain_a"`, `"research"`, `"operations"`). Never reference a real deployment.
2. **Think in interfaces.** Every component has a behaviour (Elixir interface). Domain agents implement `Cortex.Domain.Agent`. LLM adapters implement `Cortex.LLM.Adapter`. Persistence adapters implement `Cortex.Persistence.Adapter`. The engine provides the contracts. Instances provide the implementations.
3. **Propose changes to the Substrate carefully.** If your work reveals that a Substrate protocol needs updating, document the change as a proposal — what protocol, what the current definition says, what should change, and why. The Substrate is shared across all instances. Changes have wide blast radius.
4. **Test without real data.** Unit tests, integration tests, and examples should use synthetic data. No real system prompts, no real domain content, no real API keys.
5. **Flag leakage.** If you see instance-specific content in the codebase — a real company name in a test, a real API endpoint in config, a real domain name in a comment — flag it for removal. This is a security and privacy concern, not a style preference.

## If You're Coming From an Instance

If you're an agent working in a Cortex instance (a deployed workspace) and you want to contribute back to this repo:

1. **Abstract first.** Extract the generic pattern from your instance-specific work. "We found that the Router needs a batch delay for high-frequency signals" is good. "Our vocation domain sends too many signals to the finance domain" is instance-specific — abstract it.
2. **Strip context.** Before opening a PR or issue, remove all references to your instance's domains, users, companies, and data. If the improvement can't be described without instance-specific context, it probably belongs in your instance, not here.
3. **Propose, don't merge.** Substrate protocol changes and major architecture changes should be proposed as issues for discussion, not drive-by PRs. Multiple instances may be affected.
4. **Share the meta, not the data.** "We discovered that SQLite persistence doesn't handle concurrent domain agent writes well under load" is valuable. "Here's our database with 10,000 entries showing the problem" is not — synthesize the finding, share the pattern, keep the data.

