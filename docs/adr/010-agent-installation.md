# ADR 010: Agent Installation

**Status:** Accepted
**Date:** 2026-01-09
**Supersedes:** None
**Related:** ADR 003 (Setup and Provisioning)

## Context

The Otturnaut agent needs to be installed on target servers (outposts). For Phase 1, this will be done manually by running a setup script. Later, Mission Control will SSH into servers and run the same script automatically.

### Key Questions

1. How do we distribute the agent binary?
2. What user/permissions model should we use?
3. How does the agent bind to privileged ports (80/443) without running as root?
4. How does the agent know which Mission Control to connect to?

### Considered Alternatives

**Install Erlang/Elixir on target, run from source:**
- Requires maintaining Erlang/Elixir versions on each server
- Larger footprint, more moving parts
- Complicates upgrades

Rejected: Too much operational overhead.

**Docker container for the agent:**
- Adds Docker as a dependency
- Conflicts with "container-agnostic" principle
- Networking complexity for Erlang distribution

Rejected: Adds unnecessary dependency and complexity.

**Mix release downloaded from GitHub Releases:**
- Self-contained binary with bundled BEAM runtime
- No runtime dependencies on target
- Simple versioning via GitHub releases
- Easy to upgrade (download new release, restart)

Selected: Simplest approach with minimal dependencies.

## Decision

### Distribution via GitHub Releases

Otturnaut is built as a Mix release and published to GitHub Releases:

- Release tag format: `otturnaut-v{VERSION}` (e.g., `otturnaut-v0.1.0`)
- Asset naming: `otturnaut-{OS}-{ARCH}.tar.gz`
  - `otturnaut-linux-x86_64.tar.gz`
  - `otturnaut-linux-aarch64.tar.gz`

The install script downloads the appropriate release for the current architecture.

### Dedicated System User

Create an `otturnaut` system user with minimal privileges:

```bash
useradd --system --shell /usr/sbin/nologin --home-dir /opt/otturnaut otturnaut
```

Both the Otturnaut agent and Caddy run as this user. This follows least privilege:
- No login shell
- No home directory access needed
- Cannot sudo or escalate

Only the setup script runs as root, and only for:
- Creating the system user
- Installing packages (Caddy)
- Setting capabilities on binaries
- Creating systemd unit files

### Caddy Bundled in Release

Caddy is bundled inside the Otturnaut release tarball rather than downloaded separately during installation:

```
otturnaut-linux-x86_64.tar.gz
├── bin/
│   ├── otturnaut          # Agent executable
│   └── caddy              # Caddy executable (bundled)
├── lib/                   # Erlang/Elixir libraries
└── releases/              # Release metadata
```

This approach provides:
- **Single artifact** — One download, simpler installation
- **Version compatibility** — Otturnaut and Caddy versions are tested together
- **Air-gapped support** — Works in environments without internet access
- **Isolation** — Doesn't conflict with any system-wide Caddy installation
- **Scoped permissions** — Only this specific binary has capabilities

### Caddy Port Binding via Capabilities

Instead of running Caddy as root, use Linux capabilities:

```bash
setcap 'cap_net_bind_service=+ep' /opt/otturnaut/bin/caddy
```

This allows Caddy to bind to ports 80 and 443 while running as the unprivileged `otturnaut` user. The capability is granted only to the Otturnaut-managed Caddy binary, not system-wide.

### Configuration via Environment Variables

The agent receives configuration through environment variables set in the systemd unit:

| Variable | Purpose |
|----------|---------|
| `RELEASE_NODE` | Erlang node name (e.g., `otturnaut@outpost1.example.com`) |
| `RELEASE_COOKIE` | Erlang distribution cookie for Mission Control connection |
| `MISSION_CONTROL_HOST` | Hostname of Mission Control to connect to |

Example systemd unit snippet:

```ini
[Service]
User=otturnaut
Group=otturnaut
Environment=RELEASE_NODE=otturnaut@outpost1.example.com
Environment=RELEASE_COOKIE=secret_cookie_here
Environment=MISSION_CONTROL_HOST=mc.example.com
ExecStart=/opt/otturnaut/bin/otturnaut start
```

### Service Management via systemd

Both services are managed by systemd with Otturnaut-specific unit files:

- `otturnaut.service` — The agent process
- `otturnaut-caddy.service` — Reverse proxy (dedicated to Otturnaut)

Using a separate `otturnaut-caddy.service` (rather than the system `caddy.service`) ensures:
- No conflict with any system-wide Caddy installation
- Clear ownership — Otturnaut manages its own Caddy lifecycle
- Independent configuration in `/opt/otturnaut/etc/caddy/`

The Otturnaut service depends on Caddy being available:

```ini
[Unit]
After=network.target otturnaut-caddy.service
Wants=otturnaut-caddy.service
```

### Installation Directory Structure

```
/opt/otturnaut/
├── bin/
│   ├── otturnaut          # Agent release executable
│   └── caddy              # Caddy executable
├── lib/                   # Erlang/Elixir libraries
├── releases/              # Release metadata
├── etc/
│   └── caddy/
│       └── Caddyfile      # Caddy configuration
└── data/                  # Runtime data (apps, artifacts)
    ├── apps/              # Deployed applications
    └── artifacts/         # Build artifacts
```

### Install Script Flow

The `install.sh` script performs these steps:

1. **Verify root** — Script must run as root
2. **Detect architecture** — x86_64 or aarch64
3. **Create user** — `otturnaut` system user if not exists
4. **Download release** — From GitHub Releases for detected arch (includes Caddy)
5. **Extract** — To `/opt/otturnaut`, set ownership
6. **Configure Caddy** — Set capabilities on bundled binary, create config directories
7. **Create systemd units** — For both services
8. **Enable and start** — Both services

The script is idempotent — safe to re-run for upgrades or reconfiguration.

### Script Parameters

```bash
curl -fsSL https://raw.githubusercontent.com/.../install.sh | bash -s -- \
  --node-name otturnaut@outpost1.example.com \
  --cookie SECRET_COOKIE \
  --mission-control mc.example.com \
  --version v0.1.0  # optional, defaults to latest
  --container-runtime podman  # optional, installs podman or docker
```

### Container Runtime (Optional)

The script does not install a container runtime by default, following the "container-agnostic" principle. Users can optionally request one:

- `--container-runtime docker` — Installs Docker via official repository
- `--container-runtime podman` — Installs Podman via distro packages

If the user only plans to deploy native applications, no container runtime is needed.

## Consequences

### Benefits

- **No runtime dependencies** — Mix release bundles everything
- **Least privilege** — Agent runs as unprivileged user
- **Simple upgrades** — Download new release, restart service
- **Idempotent** — Script can be re-run safely
- **Standard tooling** — systemd for service management

### Trade-offs

- **GitHub dependency** — Releases hosted on GitHub (can migrate later)
- **Two architectures only** — x86_64 and aarch64 (covers most VPS)
- **Linux only** — No macOS/Windows support (not needed for servers)

### Security Considerations

- Erlang cookie must be kept secret (passed as script argument, not in URL)
- Script should verify checksums of downloaded releases (future enhancement)
- Consider HTTPS-only for script download

## Future Enhancements

- **Checksum verification** — Verify release tarball integrity
- **Mission Control initiated install** — SSH into server, run script automatically
- **Self-update** — Agent can update itself when Mission Control requests
- **Multiple Mission Control support** — Connect to backup/failover control planes
