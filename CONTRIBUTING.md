# Contributing to Cortex

## The One Rule

**No instance-specific content in this repo. Ever.**

Cortex is the engine. It knows nothing about what runs on top of it — no company names, no user data, no domain configurations, no deployment details. Contributions that improve the engine are welcome. Contributions that leak information about a specific deployment are not.

Read [AGENTS.md](AGENTS.md) for the full boundary definition.

## What We Accept

### Code Contributions

- **New adapters.** LLM adapters (new providers, local model support), persistence adapters (new backends), input adapters (new human interface types). Each adapter implements a behaviour and is self-contained.
- **Engine improvements.** Router logic, signal handling, trace collection, supervision patterns, backpressure, performance. Anything that makes the core engine better for all instances.
- **Tests.** Unit tests, integration tests, property tests. All using synthetic data and placeholder domains.
- **Documentation.** Architecture explanations, adapter guides, deployment guides. Generic, not instance-specific.

### Design Contributions

- **Substrate protocol proposals.** If your experience running a Cortex instance reveals that a protocol needs updating, open an issue describing: which protocol, current behavior, proposed change, and the generic reason (not your specific use case).
- **Architecture proposals.** New patterns, new components, structural changes. Open an issue first. Discuss before building.
- **Open question resolutions.** The implementation plan has open questions. If you have a strong opinion backed by experience, share it.

### Bug Reports

- Describe the behavior, expected vs actual. Include the Cortex version and Elixir/OTP version.
- **Do NOT include** your domain configuration, system prompts, signal content, API keys, or any data from your instance. Reproduce with synthetic data if possible.

## What We Don't Accept

- Pull requests that reference specific companies, people, or deployments
- Configuration files from running instances
- System prompts, domain names, or signal content from real deployments
- Test data derived from real usage
- "Here's how we use Cortex at [company]" in code comments or docs

If your contribution can't be described without referencing your specific deployment, it belongs in your instance's repo, not here.

## How to Contribute

1. Fork the repo
2. Create a branch (`feature/new-persistence-adapter`, `fix/router-batch-delay`)
3. Write code + tests (synthetic data only)
4. Open a PR with a clear description of what changed and why
5. Respond to review feedback

For Substrate protocol changes, open an issue first. These affect all instances and need discussion before implementation.

## Code Style

- Follow standard Elixir conventions (`mix format`, `mix credo`)
- Write typespecs for public functions
- Write `@moduledoc` and `@doc` for public modules and functions
- Use `@behaviour` declarations for adapter implementations
- Keep GenServer callbacks focused — delegate complex logic to pure functions

## License

By contributing, you agree that your contributions will be licensed under the MIT License.