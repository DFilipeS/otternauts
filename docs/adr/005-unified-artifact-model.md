# ADR 005: Unified Artifact Model

**Status:** Accepted
**Date:** 2025-12-29

## Context

Otternauts needs to support deploying applications to servers. A key design question is how to handle the **build** and **deployment** phases, especially considering:

1. **Container vs non-containerized deployments** — Docker/Podman images vs compiled binaries or bundled applications
2. **Single vs multi-server deployments** — Building once and deploying to many servers
3. **Build location** — Building on the deploy server, a dedicated build server, or externally via CI/CD

Traditional approaches separate these concerns:
- Container registries for Docker images
- Artifact storage (S3, etc.) for binaries and bundles
- Different workflows for each type

## Decision

We adopt a **unified artifact model** that treats all deployable units as artifacts, regardless of their type.

### Core Insight

A Docker image is essentially a compressed archive (layers + manifest). Container registries are servers that store and serve these archives with additional features. We can export/import images without a registry:

```bash
# Export image to file
docker save myapp:latest > myapp.tar

# Import on another server
docker load < myapp.tar
```

This means container images and other artifacts (compiled binaries, application bundles) can be treated uniformly as **files to be distributed**.

### Artifact Model

```elixir
# Artifact source - where does the deployable artifact come from?
artifact:
  | {:build, %{repo: url, ref: string, command: string}}  # Build locally from source
  | {:fetch, url}                                          # Download pre-built artifact
  | {:registry, image_ref}                                 # Pull from container registry (future)

# Runtime - how is the artifact executed?
runtime:
  | {:docker, opts}      # docker load (if needed) + docker run
  | {:podman, opts}      # podman equivalent
  | {:systemd, opts}     # extract + run as systemd service
```

### Deployment Flow

**Local build (Phase 1):**
```
git clone → build command → artifact → run
```

**Distributed deployment (future):**
```
Build Server                    Deploy Servers
     │                               │
     │  git clone                    │
     │  build                        │
     │  save artifact                │
     │  upload/serve                 │
     │         │                     │
     │         └──── artifact URL ───┤
     │                               │
     │                          fetch artifact
     │                          load/extract
     │                          run
```

### Artifact Storage Options

The artifact URL can point to various locations:

| Storage | URL Example | Use Case |
|---------|-------------|----------|
| Build server directly | `http://build-server:8000/artifacts/myapp.tar` | Simple, no external deps |
| Shared storage (S3) | `https://s3.example.com/myapp.tar` | Production, durability |
| Primary outpost | `http://primary-outpost/artifacts/myapp.tar` | Multi-server, one builds |
| Container registry | `registry.io/myapp:v1.2.3` | Standard Docker workflow |

## Consequences

### Benefits

- **Unified model** — Same conceptual flow for containers and non-containerized apps
- **Flexibility** — No lock-in to registries or specific storage
- **Air-gapped friendly** — Works without external registry access
- **Incremental complexity** — Start simple (local builds), add distribution later
- **Multi-server ready** — Build once, deploy many without requiring registry

### Trade-offs

- **No layer deduplication** — Full artifact transfer each time (vs registry's incremental pulls)
- **Larger transfers** — Especially for container images with many layers
- **No registry features** — Tags, vulnerability scanning, etc. require external registry

These trade-offs are acceptable for most use cases. Users who need registry optimizations can use external registries via the `{:registry, ...}` source type.

### Future Extensions

The model supports adding these without architectural changes:

1. **Container registry support** — Add as another artifact source type
2. **Dedicated build servers** — Any outpost can be designated build-only
3. **Artifact caching** — Cache artifacts on outposts to avoid re-downloads
4. **Built-in artifact storage** — Mission Control could host artifact storage
5. **Parallel deploys** — Build once, trigger deploys to multiple outposts simultaneously

## Phase 1 Scope

For Phase 1, we implement the simplest path:

- **Artifact source:** Local build only (`{:build, ...}`)
- **Runtime:** Docker only (`{:docker, ...}`)
- **Storage:** None needed (build and run on same server)

This validates the core deployment flow while keeping the door open for the full model.

## Example Deployment Configuration

```elixir
%Deployment{
  id: "myapp-production",

  artifact: {:build, %{
    repo: "https://github.com/user/myapp",
    ref: "main",
    command: "docker build -t myapp ."
  }},

  runtime: {:docker, %{
    image: "myapp",
    port: 3000,
    env: %{"NODE_ENV" => "production"}
  }},

  domains: ["myapp.com", "www.myapp.com"],

  health_check: %{
    path: "/health",
    interval_seconds: 30
  }
}
```

Future multi-server deployment:

```elixir
%Deployment{
  id: "myapp-production",

  # Pre-built artifact from CI/CD
  artifact: {:fetch, "https://artifacts.example.com/myapp-v1.2.3.tar"},

  runtime: {:docker, %{
    port: 3000
  }},

  # Deploy to multiple outposts
  targets: ["server-a", "server-b", "server-c"],

  domains: ["myapp.com"]
}
```
