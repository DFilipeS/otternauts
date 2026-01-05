# ADR 008: Source Fetching and Build Pipeline

**Status:** Accepted  
**Date:** 2025-01-05

## Context

The current deployment flow assumes a pre-built container image exists. To complete the end-to-end flow described in the PRD ("git push → deployed"), Otturnaut needs to:

1. Fetch source code from a Git repository
2. Build a container image from the source
3. Deploy the built image using existing strategies

This ADR addresses:
- How source code is fetched and where it's stored
- How container images are built and tagged
- How authentication for private repositories works
- How the build pipeline integrates with the existing deployment flow

## Decision

### Build Pipeline Overview

The build pipeline transforms a Git repository into a deployable container image:

```
Git Repository → Clone → Build Image → Deploy
     │              │          │           │
     │              ▼          ▼           ▼
     │         Temp dir    otturnaut-     Existing
     │         (cleaned)   {app}:{id}     strategy
     │
     └── SSH key authentication
```

### Source Fetching

**Module:** `Otturnaut.Source.Git`

Clones a Git repository to a temporary directory:

```elixir
defmodule Otturnaut.Source.Git do
  @type clone_opts :: [
    ref: String.t(),           # Branch, tag, or commit (default: "main")
    depth: pos_integer() | nil # Shallow clone depth (default: 1)
  ]

  @doc "Clones a repository to a temporary directory"
  @spec clone(repo_url :: String.t(), opts :: clone_opts()) ::
    {:ok, path :: String.t()} | {:error, term()}

  @doc "Cleans up a cloned repository"
  @spec cleanup(path :: String.t()) :: :ok
end
```

**Key decisions:**

- **Temporary storage** — Source is cloned to a temp directory and cleaned up after the image is built. No persistent source cache.
- **Shallow clones** — Default depth of 1 to minimize transfer time and disk usage.
- **Fresh clone each deploy** — No incremental fetching. Simpler, avoids stale state issues.

### Authentication

**Public repositories** require no authentication:

```elixir
# HTTPS URL - works out of the box
Source.Git.clone("https://github.com/user/public-app.git")
```

**Private repositories** use SSH key authentication:

```elixir
# SSH URL with explicit key
Source.Git.clone("git@github.com:user/private-app.git",
  ssh_key: "/home/otturnaut/.otturnaut/keys/deploy_abc123"
)
```

**SSH key management:**

- Keys are stored in `~/.otturnaut/keys/` with strict permissions
- Keys are cleaned up after use (per-deployment lifecycle)
- Mission Control provisions keys to outposts (out of scope for this ADR)

**Security considerations (private repos only):**

| Concern | Mitigation |
|---------|------------|
| File permissions | Keys written with `0600` mode; SSH rejects "permissions too open" |
| Logging | Never log key contents; redact paths in verbose output |
| Cleanup | Delete keys in `try/after` block, even on build failure |
| Process environment | Use `GIT_SSH_COMMAND` env var, avoid shell interpolation |

**Key lifecycle:**

```
1. Mission Control sends key to Otturnaut (future: secure channel)
2. Otturnaut writes key to ~/.otturnaut/keys/{key_id} with 0600
3. Clone uses key via GIT_SSH_COMMAND="ssh -i /path/to/key -o StrictHostKeyChecking=accept-new"
4. Key deleted immediately after clone (success or failure)
```

**Phase 1:** Public repos work immediately. For private repos, rely on system SSH configuration or pre-provisioned keys.

**Future:** Mission Control provisions and manages deploy keys with automatic cleanup.

### Image Building

Uses the existing `Runtime.build_image/3` callback:

```elixir
# Already implemented in Otturnaut.Runtime.Docker
Runtime.build_image(context_path, tag, opts)
```

**Image tagging convention:**

```
otturnaut-{app_id}:{deploy_id}
```

Examples:
- `otturnaut-myapp:abc123`
- `otturnaut-api:def456`

This matches the container naming convention (`otturnaut-{app_id}-{deploy_id}`) for consistency.

### Build Orchestration

**Module:** `Otturnaut.Build`

Orchestrates the full build pipeline:

```elixir
defmodule Otturnaut.Build do
  @type build_config :: %{
    repo_url: String.t(),
    ref: String.t(),
    dockerfile: String.t(),        # Default: "Dockerfile"
    build_args: %{String.t() => String.t()}  # Optional, default: %{}
  }

  @doc """
  Builds a container image from a Git repository.

  1. Clone repository to temp directory
  2. Build image using Dockerfile
  3. Clean up temp directory
  4. Return image tag
  """
  @spec run(app_id :: String.t(), deploy_id :: String.t(), config :: build_config(), opts :: keyword()) ::
    {:ok, image_tag :: String.t()} | {:error, term()}
end
```

**Build flow:**

```
1. Create temp directory
2. Clone repo (shallow, specific ref)
3. Build image with tag otturnaut-{app_id}:{deploy_id}
4. Clean up temp directory (always, even on failure)
5. Return {:ok, image_tag} or {:error, reason}
```

### Extended Deployment Configuration

The `Deployment` struct gains source configuration:

```elixir
%Deployment{
  app_id: "myapp",
  container_port: 3000,

  # Option A: Pre-built image (existing)
  image: "myapp:latest",

  # Option B: Build from source (new)
  source: %{
    repo_url: "git@github.com:user/myapp.git",
    ref: "main",
    dockerfile: "Dockerfile",
    build_args: %{"MIX_ENV" => "prod"}  # optional
  }
}
```

**Validation:** Exactly one of `image` or `source` must be provided.

### Integration with Deployment Flow

The deployment flow (ADR 006) is extended:

```
Before (image-based):
  Allocate port → Start container → Health check → Switch route → Stop old

After (source-based):
  Clone → Build → Allocate port → Start container → Health check → Switch route → Stop old → Cleanup
```

The build step runs **before** port allocation. If the build fails, no resources are allocated.

### Streaming Build Output

Build progress streams to Mission Control via the existing `Command` async execution:

```elixir
{:ok, pid} = Build.run(app_id, deploy_id, config, subscriber: mission_control_pid)

# Mission Control receives:
# {:command_output, pid, {:stdout, "Step 1/10 : FROM elixir:1.19"}}
# {:command_output, pid, {:stdout, "Step 2/10 : WORKDIR /app"}}
# ...
# {:build_complete, pid, {:ok, "otturnaut-myapp:abc123"}}
# or
# {:build_complete, pid, {:error, reason}}
```

### No Build Caching (Phase 1)

- Old images are not automatically cleaned up
- Rollback requires re-building from the previous ref
- Image cleanup is a future enhancement

## Consequences

### Benefits

- **Complete end-to-end flow** — From git push to running application
- **Simple model** — Fresh clone + build each time, no cache invalidation complexity
- **Streaming output** — Users see build progress in real-time
- **Consistent naming** — Image tags follow same pattern as container names

### Trade-offs

- **Slower deploys** — No caching means full clone + build each time
- **Manual key setup** — Phase 1 requires users to configure SSH keys on outposts
- **No rollback cache** — Rolling back requires rebuilding (acceptable for Phase 1)

### Future Considerations

**Concurrent builds:** Only one build per app should run at a time to ensure consistency. For Phase 1, Mission Control is responsible for not triggering concurrent deploys. Future: implement a per-app deployment queue in Otturnaut.

**Disk cleanup:** Old images accumulate over time. Future: automatic pruning of images older than N days, or keep only the last N images per app.

**Git submodules:** Not supported in Phase 1. Future: add `--recurse-submodules` flag support.

### Future Enhancements

- Per-app deployment queue (serialize concurrent requests)
- Automatic image cleanup/pruning
- Git submodule support
- Build caching (layer caching, source caching)
- Mission Control managed deploy keys
- Build artifact storage for faster rollbacks
- Support for other build methods (Nixpacks, buildpacks)

## Module Structure

```
lib/otturnaut/
├── source/
│   ├── source.ex           # Source behaviour (future: support other VCS)
│   └── git.ex              # Git implementation
├── build.ex                # Build orchestration
├── deployment/
│   └── ...                 # Existing deployment modules
└── ...
```

## Resolved Questions

1. **SSH key storage location** — `~/.otturnaut/keys/` with strict permissions (`0600`). Keys are cleaned up after use.
2. **Build timeout** — 10 minutes default, configurable per-app in future.
3. **Dockerfile location** — Configurable via `dockerfile` option (default: `"Dockerfile"` in repo root).
