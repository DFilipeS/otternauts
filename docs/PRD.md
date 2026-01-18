# Otternauts — Product Requirements Document

> **Status:** Draft
> **Last Updated:** 2026-01-18
> **Author:** Daniel

---

## Theme & Branding

**Otternauts** is a crew of space otters running a launch facility and mission control. The mascot is **Otto**, the lead otturnaut who coordinates missions from the control plane.

### Terminology Mapping

| System Concept | Theme Equivalent                   |
| -------------- | ---------------------------------- |
| Control plane  | Mission Control (where Otto works) |
| Server         | Outpost / Station                  |
| Application    | Spacecraft / Vessel                |
| Stack          | Fleet (group of spacecraft)        |
| Deployment     | Launch                             |
| Health check   | Telemetry                          |
| Logs           | Transmissions / Comms              |
| SSL/HTTPS      | Shields                            |
| Rollback       | Return to base                     |

### Documentation Voice

The documentation should have personality while remaining clear and useful. Otto and the otternauts can appear in:

**Tips and hints:**

> 🦦 **Otto says:** Don't forget to configure your SSH keys before adding an outpost!

**Success messages:**

> Launch successful! Your fleet is now in orbit.

**Error messages (friendly, helpful):**

> The otternauts couldn't reach your outpost. Is the station still online? Check that port 22 is accessible.

**Empty states:**

> No fleets launched yet. Ready for your first mission?

**Loading states:**

> Otto is preparing the launch sequence...

### Guidelines

- **Clarity first** — Never sacrifice understanding for theme. Technical accuracy matters.
- **Use theme for personality, not jargon** — The themed terms should make things friendlier, not more confusing.
- **Keep it light** — The tone is playful and encouraging, never frustrating or condescending.
- **Consistent but not forced** — Not every sentence needs an otter reference. Use the theme where it adds warmth or clarity.

---

## Vision

A lightweight, open-source platform for deploying and managing containerized applications across servers using Docker Swarm. Provides a clean web UI and declarative configuration files for defining multi-container deployments.

**Open source core, with optional managed hosting as the monetisation path.**

---

## Problem Statement

### The Current Landscape

Container orchestration exists on a spectrum:

1. **Docker Compose** — Simple, single-server only, no HA
2. **Docker Swarm** — Multi-server, built into Docker, but CLI-only and aging docs
3. **Kubernetes** — Powerful but complex, overkill for small-to-medium deployments
4. **Managed PaaS** — Easy but expensive and vendor lock-in

Platforms like Coolify and Dokploy try to simplify things but:

- Still resource-heavy (500MB+ before your first app)
- Documentation gaps
- Limited multi-server story

### The Opportunity

Docker Swarm is underrated. It provides:

- Multi-server orchestration built into Docker
- Overlay networking (containers talk across hosts)
- Service discovery (DNS-based)
- Load balancing (built-in)
- Rolling updates

But it lacks:

- A nice UI for visibility and operations
- Declarative config files (Compose works but limited)
- Git-ops workflow support
- Good onboarding/docs

**Otternauts fills this gap** — a clean UI and declarative workflow on top of Swarm.

### Why Elixir?

The BEAM virtual machine offers unique advantages:

- **Lightweight processes** — Handle thousands of concurrent connections with minimal memory
- **Native distribution** — Built-in clustering and RPC between nodes
- **Fault tolerance** — Supervisor trees provide self-healing capabilities
- **Single runtime** — Background jobs, caching, and real-time features without Redis
- **Long-running connections** — Excellent WebSocket support for real-time UI

### Target Users

**Primary:** Individual developers and small teams deploying applications to VPS instances who want:

- Multi-container applications (web + db + cache)
- Multi-server deployments with HA
- Simple declarative configuration
- Clean UI for visibility and operations
- Low operational overhead

**Secondary:** Teams wanting Swarm's simplicity with better tooling than the CLI.

---

## Core Principles

### 1. Docker Swarm as Foundation

Use Swarm for the hard problems (networking, discovery, load balancing). Don't reinvent orchestration.

### 2. Declarative Configuration

Define deployments in YAML files that live in your repository. Changes = commits.

### 3. Excellent Documentation

Make documentation a differentiator. Every feature should have clear examples.

### 4. Progressive Complexity

Simple things should be simple. A basic deployment shouldn't require understanding Swarm internals.

### 5. Operational Simplicity

Minimal external dependencies. SQLite + Oban for the control plane.

---

## Tech Stack

| Component       | Choice             | Rationale                                              |
| --------------- | ------------------ | ------------------------------------------------------ |
| Web framework   | Phoenix + LiveView | Real-time UI, Elixir ecosystem                         |
| Data layer      | Ash Framework      | Declarative resources, actions, policies               |
| Database        | SQLite             | Simple, no external deps, sufficient for control plane |
| Background jobs | Oban               | Reliable, persistent, Elixir-native                    |
| Server comms    | SSH + Docker CLI   | Simpler than Docker API; stack deploy is CLI-only      |
| SSH library     | TBD                | Evaluate Erlang :ssh or wrapper library                |

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│              Mission Control (Phoenix)                  │
│                                                         │
│  ┌─────────────┐  ┌──────────────┐  ┌───────────────┐   │
│  │   Web UI    │  │  Config API  │  │  SSH Client   │   │
│  │  (LiveView) │  │  (REST/WS)   │  │  (Docker CLI) │   │
│  └─────────────┘  └──────────────┘  └───────────────┘   │
│                                                         │
│  ┌─────────────┐  ┌──────────────┐                      │
│  │   SQLite    │  │    Oban      │                      │
│  │  (config,   │  │   (jobs)     │                      │
│  │   history)  │  │              │                      │
│  └─────────────┘  └──────────────┘                      │
└─────────────────────────────────────────────────────────┘
                         │
                         │ SSH (port 22)
                         │
         ┌───────────────┼───────────────┐
         ▼               ▼               ▼
    ┌─────────┐     ┌─────────┐     ┌─────────┐
    │Server 1 │◄───►│Server 2 │◄───►│Server 3 │
    │(manager)│     │(manager)│     │(worker) │
    └─────────┘     └─────────┘     └─────────┘
         └───────────────┴───────────────┘
                   Docker Swarm Cluster
```

### Control Plane (Mission Control)

A Phoenix web application providing:

- **Dashboard** — View servers, stacks, services, containers
- **Stack Management** — Deploy, update stacks
- **Configuration** — Parse and validate YAML deployment files
- **Real-time** — Live logs, status updates via WebSocket

Communicates with Swarm manager nodes via SSH, executing Docker CLI commands.

### Why SSH + Docker CLI (Not Docker API)

Docker's remote API does **not** support `docker stack deploy` — that's a CLI-only feature. To deploy stacks via API, we'd need to build our own Compose→Swarm translation engine (parsing compose files, creating services/networks/volumes individually, handling diffs and updates).

For Phase 1, SSH + Docker CLI is simpler and more reliable:

- `docker stack deploy -c compose.yml <stack>` handles all the complexity
- `docker service ls`, `docker service logs` for status and logs
- No TLS certificate management required
- Same commands users can run manually to debug

We can revisit Docker API for specific operations (real-time container stats, etc.) in later phases if needed.

### Swarm Cluster

The actual infrastructure running your applications:

- **Manager nodes** — Run Swarm control plane, can also run containers
- **Worker nodes** — Run containers only
- All nodes run Docker with Swarm mode enabled
- Overlay networking connects containers across hosts

### No Custom Agent (Initially)

Unlike v1, we start without a custom agent on each server. The control plane connects via SSH to run Docker commands. We can add agents later if needed for:

- Metrics collection
- Log aggregation
- Server health monitoring beyond Docker's capabilities

### Ingress Layer

Traffic routing is handled by Traefik deployed as a Swarm service:

```
Internet
    │
    ▼ (ports 80/443)
┌─────────────────────────────────────────────────────────┐
│  Traefik (Swarm service, 1 replica on a manager)        │
│  - Listens on 80/443 (ingress mode → any node works)    │
│  - Routes by domain → service                           │
│  - Auto-discovers via Swarm labels                      │
│  - Handles Let's Encrypt certs                          │
└─────────────────────────────────────────────────────────┘
    │ overlay network (traefik-public)
    ├──────────────┬──────────────┐
    ▼              ▼              ▼
┌───────┐    ┌───────┐    ┌───────┐
│ app1  │    │ app2  │    │ blog  │
│ :3000 │    │ :8080 │    │ :2368 │
└───────┘    └───────┘    └───────┘
   (internal only, no host ports)
```

**How it works:**

1. Traefik runs as a **single replica** pinned to a manager node (HA deferred)
2. Ports 80/443 published in **ingress mode** — Swarm routes traffic from any node to Traefik
3. Users point DNS to any node IP; Swarm routing mesh handles the rest
4. When a stack is deployed, control plane adds Traefik labels to services with `domains`
5. Traefik auto-discovers services and routes traffic by domain
6. SSL certificates provisioned automatically via Let's Encrypt (HTTP-01 challenge)

**Traefik is deployed once per cluster**, not per stack.

### Traefik Configuration Details

**Network:**

- Shared overlay network: `traefik-public`
- All services needing ingress attach to this network
- Stacks also get their own isolated network for internal communication

**Traefik stack (generated by Mission Control):**

```yaml
version: "3.8"
services:
  traefik:
    image: traefik:v3.0
    command:
      - --providers.docker.swarmMode=true
      - --providers.docker.exposedByDefault=false
      - --providers.docker.network=traefik-public
      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443
      - --certificatesresolvers.letsencrypt.acme.httpchallenge.entrypoint=web
      - --certificatesresolvers.letsencrypt.acme.email=${ACME_EMAIL}
      - --certificatesresolvers.letsencrypt.acme.storage=/acme/acme.json
    ports:
      - target: 80
        published: 80
        mode: ingress
      - target: 443
        published: 443
        mode: ingress
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - traefik-acme:/acme
    networks:
      - traefik-public
    deploy:
      replicas: 1
      placement:
        constraints:
          - node.role == manager
volumes:
  traefik-acme:
networks:
  traefik-public:
    driver: overlay
    attachable: true
```

**Service labels (added by Mission Control at deploy time):**

```yaml
deploy:
  labels:
    - traefik.enable=true
    - traefik.http.routers.myapp.rule=Host(`myapp.com`)
    - traefik.http.routers.myapp.entrypoints=websecure
    - traefik.http.routers.myapp.tls.certresolver=letsencrypt
    - traefik.http.services.myapp.loadbalancer.server.port=3000
```

**Let's Encrypt requirements:**

- Port 80 must be reachable from the internet (for HTTP-01 challenge)
- DNS must resolve to a cluster node IP **before** deployment
- Rate limits: 50 certs/domain/week — plan accordingly

**Phase 1 limitation:** Traefik is a singleton. If the node running Traefik dies, HTTPS ingress is unavailable until Swarm reschedules it to another manager. HA ingress (multiple replicas with shared ACME storage) is deferred to later phases.

---

## Deployment Model

### Stacks

A **stack** is a group of related services deployed together (like Docker Compose, but multi-server). Each stack:

- Has a unique name (used as namespace)
- Contains one or more services
- Has its own overlay network (isolated from other stacks)
- Is defined by a YAML configuration file

### Stack Definition Format

Stacks use **standard Docker Compose format** with optional `x-otternauts` extensions for convenience features. This means:

- Files work with `docker-compose up` locally
- Full Compose v3.8 syntax supported
- Our extensions are ignored by Docker CLI

```yaml
# docker-compose.yml (or any .yml file)
version: "3.8"

services:
  web:
    image: ghcr.io/myorg/myapp:latest
    deploy:
      replicas: 2
    x-otternauts:
      domains:
        - myapp.com
        - www.myapp.com
    environment:
      DATABASE_URL: postgres://db:5432/myapp
      REDIS_URL: redis://cache:6379
      API_KEY: ${API_KEY} # Resolved from Otternauts secrets
    depends_on:
      - db
      - cache

  db:
    image: postgres:16
    volumes:
      - db_data:/var/lib/postgresql/data
    environment:
      POSTGRES_DB: myapp
      POSTGRES_PASSWORD: ${DB_PASSWORD} # Resolved from Otternauts secrets

  cache:
    image: redis:7-alpine

volumes:
  db_data:
```

### Otternauts Extensions (`x-otternauts`)

| Field                  | Description                                        |
| ---------------------- | -------------------------------------------------- |
| `x-otternauts.domains` | List of domains routed to this service via Traefik |

**How it works:**

1. User uploads/pastes Compose file
2. We parse `x-otternauts` extensions
3. We resolve `${VAR}` references from stored secrets
4. We add Traefik labels for domain routing
5. We deploy via `docker stack deploy`

### Standard Compose Fields We Use

| Field                              | Description                           |
| ---------------------------------- | ------------------------------------- |
| `services.<name>.image`            | Container image (required)            |
| `services.<name>.deploy.replicas`  | Number of instances                   |
| `services.<name>.deploy.placement` | Node constraints                      |
| `services.<name>.environment`      | Environment variables                 |
| `services.<name>.volumes`          | Volume mounts                         |
| `services.<name>.depends_on`       | Service dependencies                  |
| `services.<name>.ports`            | Port mappings (for non-HTTP services) |
| `volumes`                          | Named volume definitions              |
| `networks`                         | Custom network definitions            |

See [Docker Compose reference](https://docs.docker.com/compose/compose-file/) for full syntax.

### Secrets

Secrets are stored encrypted in the control plane database and injected at deployment time:

```yaml
services:
  web:
    environment:
      API_KEY: ${API_KEY} # Resolved from stored secrets
      DEBUG: "false" # Literal value
```

---

## Server Management

### Supported Operating Systems (Phase 1)

- Ubuntu 22.04 LTS, Ubuntu 24.04 LTS
- Debian 12 (Bookworm)

Other distros may work but are not tested.

### Adding Servers to the Swarm

When a user adds a server:

1. User provides: hostname/IP, SSH username, SSH private key
2. Control plane displays host key fingerprint for user verification (TOFU)
3. User confirms fingerprint; control plane stores it
4. Control plane runs preflight checks via SSH
5. Installs Docker if needed
6. Initializes Swarm (first server) or joins existing Swarm
7. Deploys Traefik (first server only)
8. Server appears in dashboard

**Preflight checks:**

- SSH reachable, key auth works
- Sudo works without password prompt (`sudo -n true`)
- Minimum disk space (5GB free)
- Required ports open between nodes (2377, 7946, 4789/udp)
- Detect existing Docker install and version

**SSH requirements:**

- Key-based authentication only (no passwords)
- User must have passwordless sudo access
- Ports 22 (SSH), 2377 (Swarm), 7946 (Swarm gossip), 4789/udp (overlay) open between servers

**Host key verification:**

Trust On First Use (TOFU) — display fingerprint to user on first connect. Store in database and verify on subsequent connections. Reject if fingerprint changes (potential MITM).

**Docker installation:**

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
```

**Swarm initialization (first server):**

```bash
docker swarm init --advertise-addr <server-ip>
```

**Swarm join (additional servers):**

```bash
docker swarm join --token <token> <manager-ip>:2377
```

Tokens retrieved from existing manager via `docker swarm join-token manager|worker`.

**Traefik deployment (first server):**

After Swarm init, deploy Traefik stack (see Traefik Configuration Details above).

### Swarm Topology

- First server becomes a manager (and the Swarm is created)
- Additional servers can be managers or workers
- Recommend: 3 managers for HA, rest as workers
- Control plane stores connection info for all managers (SSH failover)
- If primary manager is unreachable, try next manager in list

---

## Feature Roadmap

### Phase 1: Foundation

**Goal:** Deploy a multi-container stack to a Swarm cluster with HTTPS via web UI.

**Scope:**

- Add servers (creates/joins Swarm via SSH, with preflight checks and host key verification)
- Deploy Traefik as ingress (once per cluster)
- Create stacks from YAML configuration (Compose v3.8 with x-otternauts extensions)
- Deploy stacks to Swarm with domain routing (`docker stack deploy` via SSH)
- Automatic HTTPS via Let's Encrypt (HTTP-01 challenge)
- View stack/service/container status
- Basic log viewing (`docker service logs` via SSH)
- Manual deployment trigger
- Registry credentials (for private images)
- Single-user mode (no authentication, local install assumed)

**Out of Scope:**

- CI/CD integration (Phase 4)
- Encrypted secrets management (Phase 2 — Phase 1 uses plain environment variables)
- Deployment history and rollback (Phase 2)
- Multi-user authentication and permissions (deferred)
- Volume backups (Phase 3+)

### Phase 2: Configuration & Secrets

**Goal:** Proper secrets management and deployment history.

**Scope:**

- Encrypted secrets storage
- Secret injection at deploy time
- Environment variable management
- Deployment history with diff view
- Rollback to previous versions

### Phase 3: Observability

**Goal:** Visibility into what's happening.

**Scope:**

- Real-time log streaming (aggregated across replicas)
- Resource metrics (CPU, memory per service)
- Deployment notifications (webhook, email)
- Alerting on service failures

### Phase 4: Git Integration

**Goal:** GitOps workflow.

**Scope:**

- Connect Git repositories
- Auto-deploy on push (webhook)
- Deploy from specific commits/tags
- PR preview environments
- Build images from Dockerfile (optional, vs pre-built images)

---

## Key User Workflows

### Adding Your First Server

1. User provides server hostname, SSH username, and private key
2. Control plane displays host key fingerprint for verification
3. User confirms; control plane runs preflight checks
4. Control plane installs Docker, initializes Swarm, deploys Traefik
5. Server appears as "Swarm Manager" in dashboard

### Adding Additional Servers

1. User provides server details
2. User chooses: manager or worker role
3. Control plane joins server to existing Swarm
4. Server appears in dashboard with role indicator

### Deploying a Stack

1. User creates new stack, pastes YAML configuration
2. Control plane validates configuration (checks supported keys, image references)
3. User clicks "Deploy"
4. Control plane uploads compose file to manager, runs `docker stack deploy` via SSH
5. Dashboard shows deployment status (polling `docker service ls`)
6. Services start, health checks pass, stack is "running"

### Updating a Stack

1. User edits stack configuration (or uploads new YAML)
2. Control plane shows diff from current state
3. User clicks "Deploy"
4. Swarm performs rolling update
5. Old containers drain, new containers start

### Viewing Logs

1. User clicks on a service
2. Dashboard shows aggregated logs from all replicas
3. Logs stream in real-time
4. User can filter by replica, time range, search

### Rolling Back (Phase 2)

1. User views deployment history
2. User selects previous version
3. Clicks "Rollback"
4. System re-deploys that configuration

---

## Data Model

### Core Entities (Phase 1)

**Cluster**

- `id` — Primary key
- `name` — User-friendly name
- `swarm_id` — Docker Swarm cluster ID
- `acme_email` — Email for Let's Encrypt notifications
- `traefik_status` — deployed / pending / failed
- `created_at`, `updated_at`

Note: Phase 1 assumes a single cluster. Multi-cluster support may come later.

**Server**

- `id` — Primary key
- `cluster_id` — Foreign key to Cluster
- `name` — User-friendly name
- `hostname` — Hostname or IP address
- `ssh_user` — SSH username
- `ssh_private_key` — Encrypted private key
- `ssh_port` — SSH port (default 22)
- `host_key_fingerprint` — Stored after TOFU verification
- `swarm_role` — manager / worker
- `swarm_node_id` — Docker Swarm node ID
- `os` — Detected OS (e.g., "Ubuntu 24.04")
- `docker_version` — Detected Docker version
- `status` — pending / provisioning / ready / failed / unreachable
- `last_error` — Last error message (if failed)
- `last_seen_at` — Last successful connection
- `created_at`, `updated_at`

**Stack**

- `id` — Primary key
- `cluster_id` — Foreign key to Cluster
- `name` — Stack name (used as Docker stack name)
- `configuration` — Current YAML configuration
- `status` — pending / deploying / running / failed / stopped
- `last_deployed_at` — When last deployment completed
- `created_at`, `updated_at`

**RegistryCredential**

- `id` — Primary key
- `cluster_id` — Foreign key to Cluster (or null for global)
- `registry_url` — Registry URL (e.g., "ghcr.io", "docker.io")
- `username` — Registry username
- `password` — Encrypted password/token
- `created_at`, `updated_at`

### Deferred Entities (Phase 2+)

**Deployment** (Phase 2 — deployment history)

- `id`, `stack_id`
- `configuration` — Snapshot of YAML at deploy time
- `version` — Incrementing version number
- `deployed_at`, `deployed_by`
- `status` — pending / running / failed / rolled_back

**Secret** (Phase 2 — encrypted secrets management)

- `id`, `name`, `stack_id` (optional)
- `encrypted_value`
- `created_at`, `updated_at`

### Security: Credential Encryption

All sensitive fields (SSH private keys, registry passwords) are encrypted at rest using application-level encryption. The encryption key is stored as an environment variable, not in the database.

On first run, if no encryption key exists, Mission Control generates one and prompts the user to save it securely. Without this key, backups are useless.

---

## Failure Modes & Recovery

### Server Onboarding Failures

| Failure                | User-Facing Message                                                                                                             | Recovery                              |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------- |
| SSH connection refused | "Cannot connect to server. Check that SSH is running on port 22 and the firewall allows connections."                           | Verify server is reachable, port open |
| SSH auth failed        | "Authentication failed. Verify the username and private key are correct."                                                       | Re-check credentials                  |
| Host key mismatch      | "Server fingerprint has changed! This could indicate a security issue. If you reinstalled the server, remove it and add again." | Remove server, re-add                 |
| Sudo requires password | "Passwordless sudo is required. Configure /etc/sudoers.d/otternauts for the SSH user."                                          | Fix sudoers config                    |
| Docker install failed  | "Docker installation failed. Check server logs for details."                                                                    | Show logs, allow retry                |
| Swarm init failed      | "Swarm initialization failed. The server may already be part of a swarm."                                                       | Offer to leave existing swarm         |
| Swarm join failed      | "Could not join swarm. Check that ports 2377, 7946, 4789/udp are open between servers."                                         | Port checklist, retry                 |
| Traefik deploy failed  | "Ingress deployment failed."                                                                                                    | Show error, allow retry               |

### Deployment Failures

| Failure                | User-Facing Message                                       | Recovery                                      |
| ---------------------- | --------------------------------------------------------- | --------------------------------------------- |
| Invalid compose syntax | "Configuration error: [details]"                          | Show validation errors before deploy          |
| Image pull failed      | "Failed to pull image [image]: [error]"                   | Check registry credentials, image exists      |
| Service won't schedule | "Service [name] cannot start: no nodes match constraints" | Show placement constraints, node availability |
| Health check failing   | "Service [name] is unhealthy"                             | Show health check logs                        |

### Let's Encrypt Failures

| Failure            | User-Facing Message                                                                                 | Recovery                         |
| ------------------ | --------------------------------------------------------------------------------------------------- | -------------------------------- |
| DNS not configured | "Cannot obtain certificate for [domain]: DNS does not resolve to a cluster node"                    | Check DNS A record               |
| Port 80 blocked    | "Cannot obtain certificate: HTTP challenge failed. Ensure port 80 is accessible from the internet." | Check firewall                   |
| Rate limit hit     | "Let's Encrypt rate limit reached. Try again in [time]."                                            | Wait, or use staging for testing |

### Runtime Failures

| Failure                           | Behavior                                       | Recovery                  |
| --------------------------------- | ---------------------------------------------- | ------------------------- |
| Manager node unreachable          | Try next manager in list                       | Automatic failover        |
| All managers unreachable          | Cluster marked "unreachable" in UI             | Manual intervention       |
| Traefik node dies                 | Swarm reschedules to another manager           | Automatic (may take ~30s) |
| Control plane restarts mid-deploy | Oban job resumes on restart (idempotent steps) | Automatic                 |

---

## Operational Concerns

### Control Plane Backup

**What to back up:**

1. SQLite database (`~/.otternauts/mission_control.db` or configured path)
2. Encryption key (environment variable `OTTERNAUTS_SECRET_KEY`)

**How:**

```bash
# Stop the app for consistent backup (or use SQLite online backup)
sqlite3 mission_control.db ".backup backup.db"
```

**Frequency:** Daily minimum for active use.

**Restore:** Copy backup.db to production path, ensure encryption key is set.

### Traefik ACME State

The `traefik-acme` volume contains Let's Encrypt certificates and account info. If lost:

- Certificates will be re-requested (rate limits may apply)
- Back up this volume if you have many domains

### Upgrades

**Mission Control upgrades:**

1. Stop the running instance
2. Run database migrations (`mix ecto.migrate`)
3. Start new version

**Traefik upgrades:**

- Update image version in Traefik stack
- Re-deploy via Mission Control (rolling update)

**Docker version requirements:**

- Minimum: Docker 24.0+
- Servers with older Docker should be upgraded before adding to cluster

### Known Phase 1 Limitations

- **Single Traefik replica** — If the node running Traefik dies, ingress is down until Swarm reschedules it (~30s)
- **No deployment history** — Cannot rollback to previous configurations
- **No encrypted secrets** — Environment variables stored in plain YAML (encrypted at rest in DB)
- **Single-user** — No authentication; assumes trusted local access
- **SSH-based operations** — Requires SSH connectivity to all servers from control plane

---

## Success Criteria

### Phase 1 Complete

- Deploy a 3-service stack (web + db + cache) to a 2-server Swarm
- See all services running in dashboard
- View logs from any service
- Under 15 minutes from fresh servers to running stack

### Version 1.0

- Stable for production side projects
- Comprehensive documentation
- Manage 10+ servers, 20+ stacks reliably
- Community indicators: GitHub stars, contributors

---

## Open Questions

### Resolved

**YAML format** — Standard Docker Compose v3.8 with `x-otternauts` extensions. Compatible with `docker-compose` CLI for local testing.

**Ingress** — Traefik, deployed as Swarm service (single replica on manager). Auto-discovers services via labels, handles Let's Encrypt via HTTP-01.

**Private registries** — Included in Phase 1. Store credentials in control plane, pass to Swarm at deploy time via `--with-registry-auth`.

**Build from source** — Deferred to Phase 4 (Git Integration). Phase 1 uses pre-built images only.

**Stack deployment mechanism** — SSH + Docker CLI. Docker's remote API does not support `docker stack deploy` (CLI-only feature). Using SSH keeps Phase 1 simple.

**Traefik topology** — Single replica pinned to a manager, with ports published in ingress mode. HA ingress deferred.

**Deployment history** — Out of scope for Phase 1. Re-deploying overwrites current state.

### Deferred

**Multi-tenancy** — Teams, permissions, isolation. Revisit after Phase 1.

**Volume backups** — Phase 3+.

**Custom agents** — Start without agents on servers (SSH to run Docker commands). Revisit if we need metrics, log aggregation, or server health monitoring beyond what Docker provides.

**SSH library** — Need to evaluate Erlang `:ssh` or wrapper library. Research during implementation.

**HA Ingress** — Multiple Traefik replicas require shared ACME storage (distributed volume or KV store). Deferred.

---

## Competitive Landscape

| Aspect             | Otternauts   | Portainer   | Coolify          |
| ------------------ | ------------ | ----------- | ---------------- |
| Orchestrator       | Docker Swarm | Swarm/K8s   | Docker (single)  |
| Multi-server       | Yes (native) | Yes         | Limited          |
| Declarative config | Yes (YAML)   | No          | No               |
| Git integration    | Planned      | No          | Yes              |
| Resource overhead  | Low (Elixir) | Medium (Go) | High (PHP+Redis) |
| Open source        | Yes          | Partial     | Yes              |

---

## Appendix: References

- **Docker Swarm Docs** — https://docs.docker.com/engine/swarm/
- **Portainer** — https://www.portainer.io/ — Swarm/K8s UI
- **Coolify** — https://coolify.io — Self-hosted PaaS
- **Kamal** — https://kamal-deploy.org — Docker deploy tool

---

## Changelog

- **2026-01-18** — Addressed review feedback: SSH+CLI for deployments (not Docker API), detailed Traefik config, failure modes, operational concerns, expanded data model, security considerations
- **2026-01-17** — Major pivot: Docker Swarm-based architecture, declarative YAML configs, no custom agent initially
- **2026-01-17** — Previous approach archived as PRD-v1.md
