# ADR 001: Process Management Delegation

**Status:** Accepted
**Date:** 2025-12-28

## Context

The Otturnaut agent runs on each managed server (outpost) and is responsible for deploying and managing applications. A key design question is how the agent should manage running application processes.

Two approaches were considered:

1. **Direct process supervision** — Otturnaut spawns applications via Erlang Ports and supervises them directly, handling crashes, restarts, and log capture within the BEAM.

2. **Delegation to system tools** — Otturnaut issues commands to Docker, Podman, or systemd, which handle process lifecycle, crash recovery, and log management.

## Decision

We will **delegate process management to Docker, Podman, or systemd**.

Otturnaut acts as an orchestrator that:

- Executes deployment steps (clone, build, start)
- Queries status from the container runtime or init system
- Streams logs on demand
- Configures Caddy routes

It does not hold long-running Ports open to application processes.

## Consequences

### Benefits

- **Leverage battle-tested tools** — Docker, Podman, and systemd have mature process supervision, restart policies, resource limits, and log management.
- **Simpler agent** — Otturnaut doesn't need to reimplement process supervision; it focuses on orchestration.
- **Container-agnostic by design** — The same command-execution pattern works for Docker, Podman, or native systemd services.
- **Crash isolation** — A misbehaving application can't affect the Otturnaut process directly.

### Drawbacks

- **External dependency** — Requires Docker/Podman or systemd to be available and correctly configured on the outpost.
- **Less control** — We rely on external tools' behaviour for restarts and health checks rather than implementing custom logic.

### Implications

- Otturnaut needs modules for executing commands and parsing their output
- Log streaming is on-demand (open `docker logs -f` when requested) rather than continuous
- Health checks may poll `docker inspect` or `systemctl status` rather than maintaining persistent connections

## Future Considerations

This decision may be revisited when we address:

- **Persistent log storage** — Continuous streaming to a central bucket may change the on-demand model
- **Telemetry collection** — Metrics may require persistent connections or polling strategies
