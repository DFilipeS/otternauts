# ADR 011: Containerized Agent and Infrastructure

**Status:** Accepted
**Date:** 2026-01-14
**Supersedes:** ADR 010 (Agent Installation)
**Related:** ADR 003 (Setup and Provisioning), ADR 004 (Caddy Integration)

## Context

ADR 010 established a native release distribution model: Mix releases downloaded from GitHub Releases, installed as binaries with systemd units. During v0.1.0 testing, we encountered a fundamental problem.

### The Problem

The Otturnaut release built on one machine failed to start on Ubuntu 24.04 due to OpenSSL version mismatch. Elixir releases link against system libraries (OpenSSL, glibc) at build time. When the target machine has different library versions, the release fails to load.

### Options Considered

**Option 1: Per-distro builds**
Build separate releases for each supported distro (Ubuntu 24.04, Ubuntu 22.04, Debian 12, etc.) in matching CI environments.

- Pros: Keeps native binary simplicity
- Cons: Increases build complexity, limits supported distros, requires installer to detect and download correct variant

Rejected: Adds ongoing maintenance burden and artificially limits target platforms.

**Option 2: Static linking / bundled libraries**
Build OTP against bundled OpenSSL, ship libraries alongside release.

- Pros: Single artifact works everywhere
- Cons: Complex build pipeline, larger artifacts, potential security issues with bundled libs

Rejected: Too complex for Phase 1.

**Option 3: Containerize the agent**
Run Otturnaut and Caddy as containers via Docker Compose.

- Pros: Predictable runtime, single artifact, works on any Linux with Docker/Podman
- Cons: Requires container runtime on every outpost

This option was initially rejected in ADR 010 because it conflicted with the "container-agnostic" principle.

### Changed Assumption

After further analysis, we decided to **drop support for non-containerized application deployments**. All user applications will be deployed as containers.

This changes the calculus significantly:

- Docker/Podman is already required on every outpost for deploying user apps
- Requiring it for the agent adds no new dependency
- The "container-agnostic" principle was about user choice for their apps, not infrastructure

## Decision

### Containerized Infrastructure

Both Otturnaut and Caddy run as containers, managed via Docker Compose.

```yaml
services:
  otturnaut:
    image: ghcr.io/otternauts/otturnaut:${VERSION:-latest}
    restart: unless-stopped
    network_mode: host
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - otturnaut_data:/data
    environment:
      - RELEASE_NODE=${NODE_NAME}
      - RELEASE_COOKIE=${COOKIE}
      - MISSION_CONTROL_HOST=${MISSION_CONTROL}

  caddy:
    image: caddy:2-alpine
    restart: unless-stopped
    network_mode: host
    volumes:
      - caddy_data:/data
      - caddy_config:/config

volumes:
  otturnaut_data:
  caddy_data:
  caddy_config:
```

### Key Design Decisions

**Host networking for both containers:**

- Erlang distribution requires predictable networking (no NAT/port mapping)
- Caddy needs to bind ports 80/443 directly
- Agent talks to Caddy admin API at `127.0.0.1:2019`
- Simplifies configuration significantly

**Docker socket mounting:**

- Agent needs to manage user application containers
- Mount `/var/run/docker.sock` (or Podman equivalent)
- This grants root-equivalent access, but a native agent would need the same privileges

**Persistent volumes:**

- `otturnaut_data`: Agent state, credentials, deployment data
- `caddy_data`: TLS certificates (must survive restarts)
- `caddy_config`: Caddy configuration

**No systemd units required:**

- Docker Compose with `restart: unless-stopped` handles:
  - Restart on crash
  - Start on boot (when Docker daemon starts)
- Upgrades: `docker compose pull && docker compose up -d`

### Installation Flow

1. SSH into outpost (manually for Phase 1, automated later)
2. Ensure Docker/Podman is installed
3. Create `/opt/otturnaut/docker-compose.yml` with configuration
4. Run `docker compose up -d`

The install script becomes simpler:

- No binary downloads
- No architecture detection
- No capability setting
- No systemd unit creation

### Container-Only Application Deployments

With this change, we're explicitly dropping support for non-containerized application deployments:

- All user applications must provide a container image or Dockerfile
- The agent deploys applications by pulling images and running containers
- No more "clone repo → build → run binary" flow for native apps

This simplifies the deployment model and aligns with modern practices.

## Consequences

### Benefits

- **No library compatibility issues** — Container includes exact runtime dependencies
- **Simpler distribution** — One image per version, works everywhere
- **Consistent behavior** — Same container runs identically on any Linux
- **Easier upgrades** — `docker compose pull && docker compose up -d`
- **Simpler installer** — No architecture detection, no binary downloads

### Trade-offs

- **Requires container runtime** — Docker or Podman must be installed
- **Drops native app support** — Users must containerize their applications
- **Socket access security** — Agent has root-equivalent access (same as native)

### Security Model

The security posture is unchanged from ADR 010:

- Compromised agent = compromised host (was true for native agent too)
- The agent needs privileged access to manage containers and Caddy
- Socket mounting vs native root access is an implementation detail

For enhanced security, consider rootless Podman in future iterations.

## Future Enhancements

- **Rootless Podman support** — Reduce privilege requirements
- **Multi-architecture images** — Build for linux/amd64 and linux/arm64
- **Health checks** — Add Docker health checks for both services
- **Resource limits** — Configure memory/CPU limits in compose file
