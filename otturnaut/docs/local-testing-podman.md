# Local End-to-End Testing with Podman

This guide walks through deploying your personal website locally using the containerized Otturnaut agent, simulating a real deployment scenario.

## Prerequisites

1. **Podman installed** - `podman --version`
2. **Docker Compose** (or podman-compose) - `podman compose version`
3. **SSH key** for cloning private repos
4. **Repository** with a Dockerfile

## 1. Enable Podman Socket

Podman's API socket must be running for the REST API to work.

```bash
# Rootless Podman (recommended)
systemctl --user start podman.socket
systemctl --user enable podman.socket  # Auto-start on login

# Verify
systemctl --user status podman.socket
ls -la ${XDG_RUNTIME_DIR}/podman/podman.sock
```

## 2. Build the Otturnaut Image

```bash
cd otturnaut

# Build the dev image
podman build -t otturnaut:dev .
```

## 3. Configure Environment

```bash
# Required: Your user ID for rootless Podman socket path
export HOST_UID=$(id -u)
```

## 4. Set Up SSH Keys

Copy your deploy key to the data directory (mounted at `/data` inside the container):

```bash
mkdir -p tmp/data/ssh
cp ~/.ssh/id_ed25519 tmp/data/ssh/
chmod 600 tmp/data/ssh/id_ed25519
```

## 5. Start the Stack

```bash
podman compose -f docker-compose.dev.yml up -d
```

Verify containers are running:

```bash
podman compose -f docker-compose.dev.yml ps
podman compose -f docker-compose.dev.yml logs otturnaut
podman compose -f docker-compose.dev.yml logs caddy
```

> **Note:** Caddy runs on port 8080/8443 in dev mode (rootless Podman can't bind 80/443).

## 6. Connect to IEx Console

```bash
podman compose -f docker-compose.dev.yml exec otturnaut bin/otturnaut remote
```

This opens an interactive Elixir shell inside the running container.

## 7. Run the End-to-End Test

Inside the IEx console:

### Step 1: Build the Image

```elixir
alias Otturnaut.Build
alias Otturnaut.Runtime.Podman

socket = "/var/run/container.sock"

# Build configuration
app_id = "mywebsite"
build_config = %{
  repo_url: "git@github.com:your-username/your-website.git",
  ref: "main",
  ssh_key: "/data/ssh/id_ed25519"
}

# Build the image (clones repo, builds container, cleans up source)
{:ok, image_tag} = Build.run(app_id, build_config,
  runtime: Podman,
  runtime_opts: [socket: socket]
)

IO.puts("Built image: #{image_tag}")
```

### Step 2: Deploy with Blue-Green Strategy

```elixir
alias Otturnaut.Deployment
alias Otturnaut.Deployment.Strategy.BlueGreen

# Create deployment configuration
deployment = Deployment.new(%{
  app_id: app_id,
  image: image_tag,
  container_port: 3000,                    # Port app listens on inside container
  env: %{"PORT" => "3000"},
  domains: ["myapp.localhost"],            # Domain for Caddy routing
  runtime: Podman,
  runtime_opts: [socket: socket]
})

# Execute blue-green deployment
# This will: allocate port, start container, health check, configure Caddy route
case Deployment.execute(deployment, BlueGreen) do
  {:ok, completed} ->
    IO.puts("✓ Deployed successfully!")
    IO.puts("  Container: #{completed.container_name}")
    IO.puts("  Port: #{completed.port}")
    IO.puts("  Domain: myapp.localhost")

  {:error, reason, _failed} ->
    IO.puts("✗ Deployment failed: #{inspect(reason)}")
end
```

### Step 3: Verify Deployment

```elixir
# Check container status
{:ok, status} = Podman.status(deployment.container_name, socket: socket)
IO.puts("Container status: #{status}")

# Check Caddy routes
alias Otturnaut.Caddy
{:ok, routes} = Caddy.list_routes()
IO.inspect(routes, label: "Caddy routes")
```

## 8. Access the Web Page

Add to `/etc/hosts` (once):
```bash
echo "127.0.0.1 myapp.localhost" | sudo tee -a /etc/hosts
```

Then access:
```bash
# Via Caddy (production-like)
curl http://myapp.localhost

# Or with Host header
curl -H "Host: myapp.localhost" http://localhost
```

## 9. Cleanup (Undeploy)

The `Deployment.undeploy/1` function handles all cleanup automatically:

```elixir
# Undeploy removes: Caddy route, stops container, removes container, releases port
:ok = Deployment.undeploy(deployment)

IO.puts("✓ Undeployed successfully!")
```

Exit IEx with `Ctrl+\` or type `:init.stop()`.

Stop the stack:

```bash
podman compose -f docker-compose.dev.yml down
```

## Complete Test Script

Save as `test_e2e.exs` in the otturnaut directory:

```elixir
# test_e2e.exs
# Run with: bin/otturnaut eval "Code.eval_file(\"test_e2e.exs\")"

alias Otturnaut.Build
alias Otturnaut.Deployment
alias Otturnaut.Deployment.Strategy.BlueGreen
alias Otturnaut.Runtime.Podman

# Configuration from environment
socket = System.get_env("CONTAINER_SOCKET", "/var/run/container.sock")
ssh_key = System.get_env("SSH_KEY", "/data/ssh/id_ed25519")
repo_url = System.get_env("REPO_URL") || raise "Set REPO_URL env var"
domain = System.get_env("DOMAIN", "myapp.localhost")
container_port = String.to_integer(System.get_env("CONTAINER_PORT", "3000"))

app_id = "e2e-test"

IO.puts("=== Otturnaut E2E Test ===")
IO.puts("Repo: #{repo_url}")
IO.puts("Domain: #{domain}")

# Step 1: Build
IO.puts("\n[1/3] Building image...")
build_config = %{
  repo_url: repo_url,
  ref: "main",
  ssh_key: ssh_key
}

{:ok, image_tag} = Build.run(app_id, build_config,
  runtime: Podman,
  runtime_opts: [socket: socket]
)
IO.puts("✓ Built: #{image_tag}")

# Step 2: Deploy
IO.puts("\n[2/3] Deploying with blue-green strategy...")
deployment = Deployment.new(%{
  app_id: app_id,
  image: image_tag,
  container_port: container_port,
  env: %{"PORT" => to_string(container_port)},
  domains: [domain],
  runtime: Podman,
  runtime_opts: [socket: socket]
})

case Deployment.execute(deployment, BlueGreen) do
  {:ok, completed} ->
    IO.puts("✓ Deployed!")
    IO.puts("  Container: #{completed.container_name}")
    IO.puts("  Port: #{completed.port}")

    # Step 3: Verify
    IO.puts("\n[3/3] Verifying...")
    Process.sleep(2000)

    IO.puts("\n=== Test Complete ===")
    IO.puts("Access: http://#{domain}")
    IO.puts("\nTo undeploy, run in IEx:")
    IO.puts("  Deployment.undeploy(deployment)")

  {:error, reason, _failed} ->
    IO.puts("✗ Deployment failed: #{inspect(reason)}")
    exit(:deployment_failed)
end
```

Run from host:

```bash
sudo podman compose -f docker-compose.dev.yml exec \
  -e REPO_URL="git@github.com:your-username/your-site.git" \
  -e DOMAIN="myapp.localhost" \
  otturnaut bin/otturnaut eval 'Code.eval_file("test_e2e.exs")'
```

## Troubleshooting

### "socket not found" or connection refused

The Podman socket isn't mounted correctly. Check:

```bash
# Is the socket running?
systemctl --user status podman.socket

# Is HOST_UID set correctly?
echo $HOST_UID  # Should match $(id -u)

# Check the socket path exists
ls -la ${XDG_RUNTIME_DIR}/podman/podman.sock
```

### "permission denied" on socket

The socket permissions don't allow access. For rootless Podman, ensure the container user can access it:

```bash
# Check socket permissions
ls -la ${XDG_RUNTIME_DIR}/podman/podman.sock
```

### SSH authentication fails

```bash
# Test SSH key works from host first
ssh -i ~/.ssh/id_ed25519 -T git@github.com

# List available keys in container
podman compose -f docker-compose.dev.yml exec otturnaut ls -la /data/ssh/

# Check key is readable
podman compose -f docker-compose.dev.yml exec otturnaut head -1 /data/ssh/id_ed25519
```

### Build fails with "Dockerfile not found"

Ensure Dockerfile exists in the repo root, or specify the path:

```elixir
Podman.build_image(source_dir, tag, socket: socket, dockerfile: "docker/Dockerfile")
```

### Container starts but HTTP fails

```bash
# Check container logs
podman logs <container_name>

# Verify port mapping
podman port <container_name>

# Test from inside otturnaut container
podman compose -f docker-compose.dev.yml exec otturnaut \
  curl -s http://localhost:8080
```
