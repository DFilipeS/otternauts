# ADR 009: Reliable Deployments with Reactor

**Status:** Accepted
**Date:** 2026-01-07
**Supersedes:** None
**Related:** ADR 006 (Deployment Flow and State Management)

## Context

The current deployment flow (ADR 006) can leave orphaned resources when failures occur mid-deployment:

| Failure Point | Orphaned Resources |
|---------------|-------------------|
| After `start_container`, before `switch_route` | Running container consuming port |
| After `switch_route`, before `stop_old` | Old container still running |
| After `allocate_port`, before `start_container` | Reserved port with no container |
| During `git clone` or `build` | Temporary files, partial images |

The current rollback mechanism in `BlueGreen.rollback/3` is:
1. **Manual** — Caller must explicitly call rollback after failure
2. **Best-effort** — No guarantee all resources are cleaned up
3. **Not atomic** — Partial rollback can leave inconsistent state

### Key Questions

1. How do we guarantee cleanup of all resources on failure?
2. How do we keep the agent simple and stateless?

### Considered Alternatives

**Full persistence stack (Ecto + Oban + Reactor):**
- Adds SQLite database to the agent
- Oban for async job execution with persistence
- Reactor for saga pattern

This was rejected for Phase 1 because:
- The agent should remain stateless — Mission Control owns persistent state
- Async execution isn't needed for "single app, single server" scope
- Adds ~5MB to release size and operational complexity
- Job persistence belongs in Mission Control, not the agent

**Simple try/rescue with manual cleanup:**
- No new dependencies
- Hand-roll cleanup logic in each strategy

This works but is error-prone:
- Easy to forget cleanup steps
- Undo must run in reverse order
- Each step's undo needs access to its result
- Error handling in undo itself needs care

## Decision

### Use Reactor for Saga Pattern

Use [Reactor](https://github.com/ash-project/reactor) to implement the saga pattern without persistence:

- Each deployment step is a `Reactor.Step` with `run/3` and `undo/4` callbacks
- On failure, Reactor automatically calls `undo` on all completed steps in reverse order
- Steps declare dependencies, enabling correct ordering
- No database required — runs synchronously in-process

```
┌─────────────────────────────────────────────────────────────────┐
│                    BlueGreenReactor                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Step 1: FetchSource                                            │
│    run:  Clone git repo to temp directory                       │
│    undo: Remove temp directory                                  │
│                                                                 │
│  Step 2: BuildArtifact                                          │
│    run:  Build image/release                                    │
│    undo: Remove built artifact                                  │
│                                                                 │
│  Step 3: LoadPreviousState                                      │
│    run:  Query AppState for current deployment                  │
│    undo: (none — read-only)                                     │
│                                                                 │
│  Step 4: AllocatePort                                           │
│    run:  PortManager.allocate()                                 │
│    undo: PortManager.release(port)                              │
│                                                                 │
│  Step 5: StartContainer                                         │
│    run:  Start container on allocated port                      │
│    undo: Stop and remove container                              │
│                                                                 │
│  Step 6: HealthCheck                                            │
│    run:  Verify container is healthy                            │
│    undo: (none — read-only)                                     │
│                                                                 │
│  Step 7: SwitchRoute                                            │
│    run:  Update Caddy route to new port                         │
│    undo: Restore previous route OR remove new route             │
│                                                                 │
│  Step 8: Cleanup                                                │
│    run:  Stop old container, release old port                   │
│    undo: (none — cleanup is best-effort)                        │
│                                                                 │
│  Step 9: UpdateAppState                                         │
│    run:  AppState.put(app_id, new_state)                        │
│    undo: AppState.put(app_id, previous_state)                   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

On failure at any step:
  ← undo runs automatically in reverse order
  ← all resources cleaned up
  ← old deployment remains live
```

### Synchronous Execution

Deployments run synchronously — the caller blocks until completion. This is appropriate for Phase 1:

- Single app, single server scope
- Mission Control can manage timeouts and retries
- No need for job persistence in the agent

```elixir
# Mission Control triggers deployment
case Otturnaut.Deployment.execute(deployment, Strategy.BlueGreen) do
  {:ok, result} -> # Success
  {:error, reason} -> # Failed, resources cleaned up automatically
end
```

### Future: Async Execution

When async execution is needed (Phase 2+), add Oban to **Mission Control**, not the agent:

```
┌──────────────────┐     ┌─────────────────┐     ┌──────────────────┐
│  Mission Control │     │  Otturnaut      │     │  Reactor         │
│  (Oban job)      │────▶│  (sync call)    │────▶│  (saga pattern)  │
└──────────────────┘     └─────────────────┘     └──────────────────┘
        │                                                │
   Owns job                                        Auto-rollback
   persistence                                     on failure
```

This keeps the agent simple and stateless while Mission Control handles:
- Job persistence across restarts
- Retry policies
- Concurrency control
- Progress tracking

### Preserve Strategy Abstraction

Keep the `Strategy` behaviour from ADR 006:

```elixir
defmodule Otturnaut.Deployment.Strategy.BlueGreen do
  @behaviour Otturnaut.Deployment.Strategy

  @impl true
  def execute(deployment, context, opts) do
    Reactor.run(Otturnaut.Deployment.Reactors.BlueGreen, %{
      deployment: deployment,
      context: context,
      opts: opts
    })
  end

  @impl true
  def rollback(_deployment, _context, _opts) do
    # Reactor handles rollback automatically via undo callbacks
    # This is only called for manual rollback requests
    :ok
  end
end
```

## Consequences

### Benefits

- **Automatic cleanup** — No orphaned resources on failure
- **Declarative steps** — Clear separation of run/undo logic
- **Correct ordering** — Undo runs in reverse order automatically
- **Testability** — Each step can be tested in isolation
- **No persistence overhead** — Agent remains stateless
- **Extensibility** — New strategies are new Reactor compositions

### Trade-offs

- **New dependency** — Reactor library added to the agent
- **Learning curve** — Team needs to understand Reactor's model
- **Synchronous only** — Caller blocks during deployment (acceptable for Phase 1)

### Step Implementation Pattern

```elixir
defmodule Otturnaut.Deployment.Steps.AllocatePort do
  use Reactor.Step

  @impl true
  def run(%{context: context}, _, _) do
    case context.port_manager.allocate() do
      {:ok, port} -> {:ok, port}
      {:error, reason} -> {:error, {:port_allocation_failed, reason}}
    end
  end

  @impl true
  def undo(port, %{context: context}, _, _) do
    context.port_manager.release(port)
    :ok
  end
end
```

## Module Structure

```
lib/otturnaut/
├── deployment/
│   ├── deployment.ex              # execute/2 entry point
│   ├── strategy.ex                # Strategy behaviour
│   ├── strategy/
│   │   └── blue_green.ex          # Delegates to Reactor
│   ├── reactors/
│   │   └── blue_green.ex          # Reactor definition
│   └── steps/
│       ├── fetch_source.ex
│       ├── build_artifact.ex
│       ├── load_previous_state.ex
│       ├── allocate_port.ex
│       ├── start_container.ex
│       ├── health_check.ex
│       ├── switch_route.ex
│       ├── cleanup.ex
│       └── update_app_state.ex
```

## Related

- **ADR 006** — Deployment Flow and State Management (defines the steps being made reliable)
- **ADR 008** — Source Fetching and Build Pipeline (defines fetch/build steps)
