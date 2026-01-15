# Otternauts

A lightweight, open-source platform for deploying and managing web applications across servers. Built with Elixir.

## Ways of Working

**Do not jump straight to implementation.** Before writing any code:

1. **Discuss the approach first** — When asked to build a feature or solve a problem, start by discussing the design, tradeoffs, and options. Ask clarifying questions if needed.

2. **Propose a plan** — Outline what you intend to build, which modules/files will be involved, and how they'll interact. Wait for approval before coding.

3. **Small steps** — Implement in small increments. After each step, pause to verify the approach is correct before continuing.

4. **Ask, don't assume** — If something is unclear or there are multiple valid approaches, ask rather than picking one silently.

5. **Reference the PRD** — For context on features and architecture, read `docs/PRD.md`. Ensure implementation aligns with the documented vision.

### When I say

| I say...                     | You should...                                       |
| ---------------------------- | --------------------------------------------------- |
| "Let's discuss X"            | Talk through options, don't write code yet          |
| "What do you think about X?" | Share opinions and tradeoffs, ask questions         |
| "Implement X" or "Build X"   | Propose a plan first, then implement after approval |
| "Just do it" or "Go ahead"   | Proceed with implementation                         |

## Plan Mode

- Make the plan extremely concise. Sacrifice grammar for the sake of concision.
- At the end of each plan, give me a list of unresolved questions to answer, if any.

### Testing Philosophy

Follow the testing pyramid strictly:

```
        /\
       /  \      E2E (few)
      /----\
     /      \    Integration (some)
    /--------\
   /          \  Unit (most)
  /____________\
```

- **Unit tests (most)** — Test individual functions and modules in isolation. Fast, focused, easy to debug. This should be the majority of tests.
- **Integration tests (some)** — Test module interactions, database operations, context functions. Fewer than unit tests.
- **End-to-end tests (few)** — Test full user flows through LiveView or the complete system. These are slow and brittle—use sparingly.

**Decision rule:** Before writing a test, ask "Can I test this at a lower level?" If yes, do that instead.

**Coverage target:** 100% code coverage. Run `mix test --cover` to check.

**When implementing features:**

1. Write unit tests for the core logic first
2. Add integration tests only where module boundaries matter
3. Add E2E tests only for critical user journeys

**Mock modules in tests:**

- Define mock modules at the **test module level**, not inside `describe` blocks or individual tests
- Modules defined inside tests get redefined on each run, causing warnings with `--warnings-as-errors`
- Use dependency injection (passing modules as options) for testability
- For external dependencies that can't be injected (like Erlang's `Port`), create thin wrapper modules and use `mimic` to mock them
- **Prefer process dictionary for test-local state over named Agents** to keep tests async-safe
  - Use `Process.put/get` for mock state that's isolated per test
  - Avoid named processes (e.g., `Agent.start_link(fn -> ... end, name: __MODULE__)`) which require `async: false`
  - See `test/otturnaut/deployment_test.exs` "undeploy/3" tests and `test/otturnaut/deployment/strategy/blue_green_test.exs` for good examples

## Documentation

- **[docs/PRD.md](docs/PRD.md)** — Product Requirements Document with full context on goals, architecture, and roadmap

## Project Structure

This is a poncho-style Elixir project:

```
otternauts/
├── mission_control/     # Phoenix app - control plane, dashboard, API
├── otturnaut/           # Elixir app - agent running on managed servers
└── docs/
    └── PRD.md
```

## Key Concepts

- **Mission Control** — The control plane (Phoenix app) where users manage servers and deployments
- **Otturnaut** — Agent process running on each managed server, executes deployments and reports back
- **Outpost** — A managed server with an Otturnaut installed
- **Otto** — The mascot otter, used in documentation and UI copy for personality

## Tech Stack

- **Elixir** — Core language for both Mission Control and Otturnaut
- **Phoenix + LiveView** — Control plane web interface
- **Ash Framework** — Data modeling, actions, and policies for Mission Control (not used in Otturnaut)
- **SQLite + Oban** — Database and background jobs (no external dependencies)
- **Caddy** — Reverse proxy on each outpost (automatic HTTPS)
- **Erlang Distribution** — Communication between Mission Control and Otternauts

### Framework Usage

| Component       | Frameworks               | Notes                                               |
| --------------- | ------------------------ | --------------------------------------------------- |
| Mission Control | Phoenix, Ash, AshPhoenix | Data layer, business logic, UI                      |
| Otturnaut       | Plain OTP                | GenServers, Supervisors, Tasks—no data layer needed |

## Development Guidelines

- Follow the Elixir expert skill in `.claude/skills/elixir-expert/SKILL.md`
- Poncho projects over umbrellas
- Explicit configuration over magic/auto-detection
- Testing pyramid: unit tests > integration tests > e2e tests
- Read the PRD before implementing features for full context

## Current Phase

**Phase 1: Foundation (PoC)** — Deploy a single application to a single server with automatic HTTPS.

Starting point: Build the Otturnaut (agent) first, then Mission Control.
