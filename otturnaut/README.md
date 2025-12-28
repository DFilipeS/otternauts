# Otturnaut

The Otturnaut is the agent component of [Otternauts](../docs/PRD.md) that runs on each managed server (outpost). It receives instructions from Mission Control and executes deployments locally.

## Responsibilities

| Responsibility | Description |
|----------------|-------------|
| **Deployment execution** | Clone repositories, build images/binaries, start applications |
| **Status reporting** | Query and report application state to Mission Control |
| **Log streaming** | Stream application logs on demand |
| **Proxy configuration** | Configure Caddy routes via its admin API |
| **Health checks** | Monitor application health and report issues |

## Architecture

Otturnaut is a plain OTP application — no frameworks, just GenServers, Supervisors, and Tasks.

### Key Design Decisions

- **Process management is delegated** — Applications run via Docker, Podman, or systemd. Otturnaut orchestrates but doesn't supervise processes directly. See [ADR 001](../docs/adr/001-process-management-delegation.md).

- **Command execution over long-running Ports** — Otturnaut executes short-lived commands (`git clone`, `docker build`, `docker run -d`) and interprets their results rather than holding Ports open.

- **On-demand log streaming** — Logs are streamed only when Mission Control requests them, not continuously buffered.

### Communication

Otturnaut connects to Mission Control via Erlang distribution, enabling:

- Real-time bidirectional communication
- RPC for triggering deployments
- Streaming updates during deployment progress

## Development

```bash
# Run tests
mix test

# Start interactive shell
iex -S mix
```

## Project Structure

```
lib/
├── otturnaut.ex              # Public API
└── otturnaut/
    └── application.ex        # OTP Application & Supervisor
```

*Structure will evolve as we build out functionality.*
