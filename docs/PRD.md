# Otternauts — Product Requirements Document

> **Status:** Draft  
> **Last Updated:** 2025-12-27  
> **Author:** Daniel

---

## Theme & Branding

**Otternauts** is a crew of space otters running a launch facility and mission control. The mascot is **Otto**, the lead otturnaut who coordinates missions from the control plane.

### Terminology Mapping

| System Concept | Theme Equivalent                   |
| -------------- | ---------------------------------- |
| Control plane  | Mission Control (where Otto works) |
| Agent          | Otturnaut stationed at an outpost  |
| Server         | Outpost / Station                  |
| Application    | Spacecraft / Vessel                |
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

> Launch successful! Your spacecraft is now in orbit.

**Error messages (friendly, helpful):**

> The otternauts couldn't reach your outpost. Is the station still online? Check that port 22 is accessible.

**Empty states:**

> No spacecraft launched yet. Ready for your first mission?

**Loading states:**

> Otto is preparing the launch sequence...

### Guidelines

- **Clarity first** — Never sacrifice understanding for theme. Technical accuracy matters.
- **Use theme for personality, not jargon** — The themed terms should make things friendlier, not more confusing.
- **Keep it light** — The tone is playful and encouraging, never frustrating or condescending.
- **Consistent but not forced** — Not every sentence needs an otter reference. Use the theme where it adds warmth or clarity.

---

## Vision

A lightweight, open-source platform for deploying and managing web applications across servers. Built with Elixir to minimise resource overhead and leverage native distribution capabilities.

**Open source core, with optional managed hosting as the monetisation path.**

---

## Problem Statement

### The Current Landscape

Self-hosted deployment platforms like Coolify and Dokploy have gained popularity as alternatives to expensive PaaS offerings. They promise the ease of Heroku with the control of self-hosting. However, they share common limitations:

1. **Resource overhead** — These platforms consume significant server resources just for orchestration. A PHP runtime plus Redis plus PostgreSQL (Coolify) or a Node.js runtime plus PostgreSQL (Dokploy) can easily consume 500MB+ of RAM before deploying a single application.

2. **Container-only deployment** — Both assume Docker as the runtime. Users wanting Podman (for rootless containers) or bare-metal deployments have limited or no options.

3. **Documentation gaps** — Both projects suffer from incomplete documentation, particularly lacking practical examples for common use cases.

4. **Dependency complexity** — External services (Redis, PostgreSQL) increase operational burden and failure modes.

### Why Elixir?

The BEAM virtual machine offers unique advantages for orchestration software:

- **Lightweight processes** — Handle thousands of concurrent connections (to servers, log streams, webhooks) with minimal memory
- **Native distribution** — Built-in clustering and RPC between nodes, eliminating the need for external message brokers
- **Fault tolerance** — Supervisor trees provide self-healing capabilities essential for infrastructure tooling
- **Single runtime** — Background jobs, caching, and real-time features without Redis or external queues
- **Long-running connections** — Excellent support for WebSockets and persistent connections

### Target Users

**Primary:** Individual developers and small teams deploying applications to VPS instances (Hetzner, OVH, DigitalOcean, Linode) who want:

- Simple deployment workflow (git push → deployed)
- Automatic HTTPS
- Low resource consumption on their servers
- Visibility into what's running

**Secondary:** Teams outgrowing basic VPS deployments but not ready for Kubernetes complexity.

---

## Core Principles

### 1. Minimal Footprint

The orchestrator should consume as few resources as possible. Target: control plane + agent combined under 100MB RAM.

### 2. Container-First

All deployments run as containers (Docker or Podman). This simplifies the deployment model, ensures consistent behavior across environments, and aligns with modern practices. See [ADR 011](adr/011-containerized-deployment.md) for the rationale behind this decision.

### 3. Excellent Documentation

Make documentation a differentiator. Every feature should have clear examples. Common workflows should be thoroughly documented.

### 4. Progressive Complexity

Simple things should be simple. A basic deployment shouldn't require understanding the full system. Advanced features are available but not forced.

### 5. Operational Simplicity

Minimise external dependencies. Prefer embedded solutions (SQLite over PostgreSQL, Oban over external job queues) where they meet requirements.

---

## Architecture Overview

The system consists of two components:

### Control Plane

A web application providing:

- Dashboard for managing servers and applications
- API for CI/CD integration
- Deployment orchestration
- Configuration and secrets management

Deployed as a container for easy installation.

### Agent

A lightweight process running on each managed server:

- Executes deployment commands (pulls images, runs containers)
- Manages the local reverse proxy (Caddy)
- Streams logs and metrics back to control plane
- Performs health checks

Both the agent (Otturnaut) and reverse proxy (Caddy) run as containers via Docker Compose. See [ADR 011](adr/011-containerized-deployment.md) for details.

### Communication

The control plane and agents communicate via Erlang's native distribution protocol, enabling real-time bidirectional communication without additional infrastructure.

### Reverse Proxy

Each server runs Caddy as the reverse proxy, providing:

- Automatic HTTPS via Let's Encrypt
- Dynamic configuration via API (no restarts needed)
- Simple, single-binary installation

### Request Routing

User requests flow through Caddy on each outpost:

```
User Request (myapp.com)
         │
         ▼
┌─────────────────────────────────────────────┐
│              Outpost (Server)               │
│                                             │
│  ┌───────────────────────────────────────┐  │
│  │         Caddy (:80/:443)              │  │
│  │                                       │  │
│  │  myapp.com     → localhost:3000       │  │
│  │  api.myapp.com → localhost:4000       │  │
│  │  other.dev     → localhost:8080       │  │
│  │                                       │  │
│  │  + Automatic SSL for all domains      │  │
│  └───────────────────────────────────────┘  │
│              │        │        │            │
│              ▼        ▼        ▼            │
│          ┌──────┐ ┌──────┐ ┌──────┐         │
│          │App 1 │ │App 2 │ │App 3 │         │
│          │:3000 │ │:4000 │ │:8080 │         │
│          └──────┘ └──────┘ └──────┘         │
│                                             │
│  ┌───────────────────────────────────────┐  │
│  │  Otturnaut (Agent)                    │  │
│  │  - Configures Caddy routes via API    │  │
│  │  - Manages application lifecycle      │  │
│  │  - Reports to Mission Control         │  │
│  └───────────────────────────────────────┘  │
└─────────────────────────────────────────────┘
```

**How it works:**

1. User's DNS points their domain to the outpost's IP address
2. Request arrives at Caddy on port 80/443
3. Caddy matches the `Host` header to a configured route
4. Caddy proxies to the application's internal port
5. Response returns through Caddy to the user

**Route configuration:**

When an application is deployed, the Otturnaut:

1. Starts the application on an available internal port
2. Calls Caddy's admin API to register the domain → port mapping
3. Caddy automatically obtains/renews SSL certificates

**Implementation note:**

Caddy routes use `127.0.0.1` explicitly instead of `localhost` for upstream connections. This avoids IPv4/IPv6 resolution issues—`localhost` may resolve to `::1` (IPv6) on some systems, while containers typically bind to IPv4 only.

**User responsibility:**

DNS configuration is handled by the user. They must point their domain to the outpost's IP address. The UI should provide clear guidance:

> 🦦 **Otto says:** Point your domain to `203.0.113.42` (A record) and we'll handle the rest!

**Future consideration (multi-server):**

Load balancing across multiple outposts is out of scope for Phase 1. Options to explore later:

- DNS-based routing (user manages)
- Designated entry-point outpost that proxies to others
- Integration with external load balancers (Cloudflare, etc.)

---

## Feature Roadmap

### Phase 1: Foundation (Proof of Concept)

**Goal:** Deploy a web application to a server with automatic HTTPS.

**User Story:** As a developer, I can add my server, connect a Git repository, and have my application running with a valid SSL certificate within minutes.

**Scope:**

- Register a server (provide SSH access)
- Define an application (Git repository, build command, start command, domain)
- Trigger deployment manually or via Git webhook
- Automatic HTTPS certificate provisioning
- Basic health checking
- Dashboard showing server and application status

**Out of Scope:** Multiple apps per server, database management, advanced monitoring.

### Phase 2: Multi-Application & Configuration

**Goal:** Run multiple applications with proper configuration management.

**Scope:**

- Multiple applications per server
- Environment variables (build-time and runtime)
- Encrypted secrets storage
- Deployment history and rollback
- Real-time log viewing

### Phase 3: Database Management

**Goal:** First-class support for database provisioning and backups.

**Scope:**

- PostgreSQL and MySQL provisioning
- Automated backup scheduling
- Backup storage to S3-compatible services
- One-click restore

### Phase 4: Multi-Server & Observability

**Goal:** Manage server fleets with comprehensive monitoring.

**Scope:**

- Multiple servers from single control plane
- Resource monitoring (CPU, memory, disk)
- Web-based terminal access
- Alerting (webhook, email)

### Phase 5: Production Hardening

**Goal:** Features required for serious production use.

**Scope:**

- Zero-downtime deployments
- Load balancing across instances
- Team access controls
- Audit logging
- API for automation

---

## Key User Workflows

### Adding a Server

1. User provides server hostname/IP and SSH credentials (or uploads key)
2. Control plane connects via SSH and installs the agent
3. Agent starts and establishes persistent connection to control plane
4. Server appears in dashboard as "connected"

### Deploying an Application

1. User creates application: name, Git repo, branch, build command, start command, domain(s)
2. Control plane triggers deployment via agent
3. Agent: clones repo → runs build → starts application → configures proxy
4. Control plane receives real-time progress updates
5. Application accessible via HTTPS at configured domain

### Viewing Logs

1. User clicks on running application
2. Dashboard opens real-time log stream
3. Logs flow from agent to control plane to browser with minimal latency

### Rolling Back

1. User views deployment history for application
2. User selects previous successful deployment
3. System re-deploys that version
4. Previous version is now running

---

## Success Criteria

### Proof of Concept

- Deploy a web application to a fresh VPS in under 10 minutes (including server setup)
- Valid HTTPS certificate automatically provisioned
- Combined memory usage (control plane + agent) under 100MB
- Real-time deployment progress visible in dashboard

### Version 1.0

- Stable enough for production side projects
- Comprehensive documentation with examples for common frameworks
- Manage 10+ servers reliably
- Community adoption indicators: GitHub stars, contributors, Discord/forum activity

---

## Open Questions

### Resolved

**Build strategies** — Explicit configuration required. No magic auto-detection or buildpacks. Users must provide their build and start commands. This keeps things predictable and debuggable.

**Domain** — otternauts.dev (and .sh, .com, .io) are available. Decision on which to use pending.

### Deferred

**Multi-tenancy** — Not yet clear how this should work. Considerations:

- User accounts for dashboard access
- Role-based permissions
- Team/organisation isolation

Using Ash Framework could make adding these features easier later without over-engineering now. Revisit after Phase 1.

**Log retention** — Unknown. Questions to answer:

- Store locally on each outpost or centralise?
- How much history?
- Rotation/cleanup strategy?

For Phase 1, real-time log streaming may be sufficient. Persistence can come later.

**Metrics backend** — Unknown. Options:

- Embedded storage (SQLite)
- Integration with existing tools (Prometheus, VictoriaMetrics)
- External services

For Phase 1, live metrics only (no persistence) is acceptable. Revisit when observability becomes a focus in Phase 4.

---

## Competitive Landscape

| Aspect                | This Project             | Coolify           | Dokploy       |
| --------------------- | ------------------------ | ----------------- | ------------- |
| Runtime overhead      | Target: <100MB           | ~500MB+           | ~400MB+       |
| Container support     | Docker, Podman           | Docker only       | Docker only   |
| External dependencies | None (embedded DB, jobs) | PostgreSQL, Redis | PostgreSQL    |
| Real-time updates     | Native (Erlang channels) | WebSocket         | WebSocket     |
| Multi-server          | Native clustering        | Manual setup      | Manual setup  |
| Auto HTTPS            | Yes (Caddy)              | Yes (Traefik)     | Yes (Traefik) |
| Open source           | Yes                      | Yes               | Yes           |

---

## Appendix: Inspiration & References

- **Coolify** — <https://coolify.io> — PHP-based, good feature breadth
- **Dokploy** — <https://dokploy.com> — TypeScript, cleaner UI
- **Kamal** — <https://kamal-deploy.org> — Ruby, Docker-focused, no web UI
- **CapRover** — <https://caprover.com> — Node.js, Docker swarm based

---

## Changelog

- **2026-01-14** — Changed to container-first approach: agent and Caddy run via Docker Compose, all app deployments are containerized (see [ADR 011](adr/011-containerized-deployment.md))
- **2025-12-27** — Added request routing architecture and diagram
- **2025-12-27** — Resolved open questions: explicit build config (no magic), domain available, deferred multi-tenancy/logs/metrics to later phases
- **2025-12-27** — Added project name (Otternauts), theme, and mascot (Otto)
- **2025-12-27** — Initial draft
