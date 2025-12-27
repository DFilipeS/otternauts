# Otternauts

A lightweight, open-source platform for deploying and managing web applications across servers. Built with Elixir.

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

| Component | Frameworks | Notes |
|-----------|------------|-------|
| Mission Control | Phoenix, Ash, AshPhoenix | Data layer, business logic, UI |
| Otturnaut | Plain OTP | GenServers, Supervisors, Tasks—no data layer needed |

## Development Guidelines

- Follow the Elixir expert skill in `/mnt/skills/user/elixir-expert/SKILL.md`
- Poncho projects over umbrellas
- Explicit configuration over magic/auto-detection
- Testing pyramid: unit tests > integration tests > e2e tests
- Read the PRD before implementing features for full context

## Current Phase

**Phase 1: Foundation (PoC)** — Deploy a single application to a single server with automatic HTTPS.

Starting point: Build the Otturnaut (agent) first, then Mission Control.
