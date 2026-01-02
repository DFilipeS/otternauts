# ADR 007: Application Undeployment

**Status:** Accepted
**Date:** 2026-01-01

## Context

Otturnaut can deploy applications using blue-green strategy and rollback failed deployments. However, there's no way to fully remove a deployed application when it's no longer needed.

Current rollback only cleans up partial deployments (new container, allocated port) but doesn't remove complete deployments.

## Decision

Add undeploy functionality as a standalone function `Deployment.undeploy/3` that removes all resources for a deployed application.

### Design Rationale

**Standalone function over strategy callback:**
- Undeploy doesn't vary by deployment strategy
- All deployments undeploy the same way (stop container, remove routes, release port)
- Simplifies future strategy implementations

**Idempotency:**
- Missing resources treated as success
- Can be safely re-run if process is interrupted
- Provides predictable behavior for users and automation

## Undeploy Flow

1. Retrieve app state (container name, port, domains)
2. Stop container/service via runtime
3. Remove container/service via runtime
4. Remove Caddy routes (if domains configured)
5. Release allocated port
6. Clear application state

## Consequences

### Benefits

- Complete cleanup of all application resources
- Idempotent operation (safe to run multiple times)
- Progress notifications for visibility
- Consistent with existing context pattern

### Trade-offs

- Undeploy is not strategy-aware (not a limitation — doesn't need to be)
- Partial cleanup possible if critical error occurs early in flow

### Implications

- No changes to strategy behavior required
- Mission Control can offer "undeploy" action to users
- Works with all future runtimes through runtime abstraction

## Example Usage

```elixir
context = %{
  runtime: Otturnaut.Runtime.Docker,
  app_state: Otturnaut.AppState,
  port_manager: Otturnaut.PortManager,
  caddy: Otturnaut.Caddy
}

# Undeploy with progress notifications
:ok = Deployment.undeploy("myapp", context, subscriber: self())

# Idempotent - safe to run again
:ok = Deployment.undeploy("myapp", context)
```

## Comparison to Rollback

| Aspect | Rollback | Undeploy |
|---------|-----------|-----------|
| Purpose | Clean up failed deployment | Remove deployed application |
| Scope | New container + allocated port | All resources for app |
| Called by | Strategy after failure | User/Mission Control explicitly |
| Restores old route | Yes | No (removes all routes) |
