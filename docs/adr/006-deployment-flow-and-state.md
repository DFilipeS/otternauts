# ADR 006: Deployment Flow and State Management

**Status:** Accepted
**Date:** 2025-12-29

## Context

Otturnaut needs to deploy applications to outposts with zero downtime, support multiple runtimes (Docker, Podman, systemd), and recover gracefully from agent restarts.

Key questions addressed:
1. How do deployments flow from request to running application?
2. How do we achieve zero-downtime deployments?
3. Where does state live and how do we recover it?
4. How do we support multiple deployment strategies and runtimes?

## Decision

### Deployment Flow (Blue-Green)

Zero-downtime deployments use a blue-green strategy:

1. **Clone** — Fetch source code from git repository
2. **Build** — Build artifact (docker build, mix release, etc.)
3. **Allocate port** — Get available port from port manager
4. **Start new** — Start new container/service on allocated port
5. **Health check** — Verify new version is healthy
6. **Switch route** — Update Caddy to point to new port (instant)
7. **Stop old** — Stop previous container/service
8. **Release port** — Return old port to pool

```
Old container (port 10001) ──── Caddy routes here
        │
        │   Deploy triggered
        │
        ▼
New container starts (port 10002)
        │
        │   Health check passes
        │
        ▼
Caddy switches to port 10002 ◄── Instant cutover
        │
        │
        ▼
Old container stopped, port 10001 released
```

**Failure handling:** If any step before "switch route" fails, the old version remains live. We stop the new container, release the allocated port, and report failure. Users experience no downtime.

### State Management

The agent is **stateless by design**. No local persistence required.

| State Type | Source of Truth | Recovery Method |
|------------|-----------------|-----------------|
| Desired state (what should run) | Mission Control | Query on connect |
| Actual state (what is running) | Runtime (Docker/systemd) | Query on startup |
| Runtime state (ports, in-progress) | ETS (in-memory) | Rebuild from above |

#### On Agent Startup

```elixir
def recover_state(runtime) do
  # 1. Query runtime for containers/services matching our pattern
  running = runtime.list_apps()

  # 2. Extract port mappings
  ports_in_use = extract_ports(running)

  # 3. Populate ETS with discovered state
  populate_runtime_state(running, ports_in_use)

  # 4. When Mission Control connects, reconcile desired vs actual
end
```

#### Naming Convention

All managed containers/services follow a naming pattern for discovery:

| Runtime | Name Format | Example |
|---------|-------------|---------|
| Docker | `otturnaut-{app_id}-{deploy_id}` | `otturnaut-myapp-abc123` |
| Podman | `otturnaut-{app_id}-{deploy_id}` | `otturnaut-myapp-abc123` |
| systemd | `otturnaut-{app_id}.service` | `otturnaut-myapp.service` |

This allows the agent to identify its managed resources after restart.

#### Mid-Deployment Crash Recovery

If the agent crashes during deployment:
- New container may be running but route not configured
- On restart, detect orphaned containers (running but not in desired state)
- Clean up orphans or let Mission Control re-trigger deployment

### Port Management

Dynamic port allocation from a configurable range:

```elixir
defmodule Otturnaut.PortManager do
  # Configuration: port range (e.g., 10000-20000)

  def allocate() :: {:ok, port} | {:error, :exhausted}
  def release(port) :: :ok
  def in_use?(port) :: boolean()
  def list_allocated() :: [port]
end
```

Port state is rebuilt on startup by querying the runtime for active port mappings.

For containers, the internal port stays constant (e.g., 3000), only the host port changes:

```bash
docker run -p 10042:3000 myapp   # Host 10042 → Container 3000
```

### Health Checks

Extensible health check system, starting simple:

```elixir
defmodule Otturnaut.HealthCheck do
  @type check_type :: :running | :http | :tcp

  # Phase 1: Container/process is running
  def check(%{type: :running, target: container_or_service})

  # Future: HTTP endpoint responds
  def check(%{type: :http, url: url, expected_status: 200})

  # Future: TCP port accepts connections (for databases)
  def check(%{type: :tcp, host: host, port: port})
end
```

Phase 1 uses `:running` check only. Applications can specify HTTP health checks in their configuration for future use.

### Deployment Strategies (Extensible)

Strategy pattern allows adding new deployment methods:

```elixir
defmodule Otturnaut.Deployment.Strategy do
  @callback execute(deployment, current_state, opts) :: {:ok, new_state} | {:error, term}
  @callback rollback(deployment, state, opts) :: {:ok, state} | {:error, term}
end

defmodule Otturnaut.Deployment.Strategy.BlueGreen do
  @behaviour Otturnaut.Deployment.Strategy
  # Current implementation: start new, switch, stop old
end

# Future strategies
defmodule Otturnaut.Deployment.Strategy.Canary do
  @behaviour Otturnaut.Deployment.Strategy
  # Route percentage of traffic to new version
end

defmodule Otturnaut.Deployment.Strategy.Rolling do
  @behaviour Otturnaut.Deployment.Strategy
  # For multi-instance deployments
end
```

### Runtime Abstraction

Support multiple runtimes through a common interface:

```elixir
defmodule Otturnaut.Runtime do
  @callback list_apps() :: [app_state]
  @callback start(app, opts) :: {:ok, id} | {:error, term}
  @callback stop(id) :: :ok | {:error, term}
  @callback status(id) :: :running | :stopped | :unknown
  @callback get_port_mapping(id) :: {:ok, port} | {:error, term}
end

defmodule Otturnaut.Runtime.Docker do
  @behaviour Otturnaut.Runtime
  # docker ps, docker run, docker stop, etc.
end

defmodule Otturnaut.Runtime.Podman do
  @behaviour Otturnaut.Runtime
  # Same CLI as Docker, largely compatible
end

defmodule Otturnaut.Runtime.Systemd do
  @behaviour Otturnaut.Runtime
  # systemctl, unit file management
end
```

Phase 1 implements Docker only, with the interface ready for others.

## Consequences

### Benefits

- **Zero downtime** — Blue-green ensures old version serves traffic until new is verified
- **Stateless agent** — Simple recovery, no persistence to manage
- **Extensible** — New strategies and runtimes can be added without redesign
- **Resilient** — Agent restart doesn't lose knowledge of running apps

### Trade-offs

- **Mission Control dependency** — Agent needs Mission Control for desired state (acceptable, they work together)
- **Naming convention required** — Must follow pattern for discovery to work
- **Runtime query on startup** — Slight delay while discovering state

### Future Enhancements

- Canary deployments (traffic splitting)
- Rolling deployments (multi-instance)
- Podman and systemd runtime implementations
- HTTP and TCP health checks
- Deployment history and rollback to previous versions

## Module Structure

```
lib/otturnaut/
├── deployment/
│   ├── deployment.ex           # Deployment struct and orchestration
│   ├── strategy.ex             # Strategy behaviour
│   └── strategy/
│       └── blue_green.ex       # Blue-green implementation
├── runtime/
│   ├── runtime.ex              # Runtime behaviour
│   └── docker.ex               # Docker implementation
├── port_manager.ex             # Port allocation
├── health_check.ex             # Health checking
└── app_state.ex                # App state management (ETS)
```
