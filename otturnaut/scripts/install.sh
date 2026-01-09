#!/usr/bin/env bash
set -euo pipefail

readonly INSTALL_DIR="/opt/otturnaut"
readonly OTTURNAUT_USER="otturnaut"
readonly GITHUB_REPO="DFilipeS/otternauts"
readonly SYSTEMD_DIR="/etc/systemd/system"

# Default values
VERSION="latest"
NODE_NAME=""
COOKIE=""
MISSION_CONTROL=""
CONTAINER_RUNTIME=""

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Install Otturnaut agent on this server.

Required options:
    --node-name NAME        Erlang node name (e.g., otturnaut@outpost1.example.com)
    --cookie SECRET         Erlang distribution cookie
    --mission-control HOST  Mission Control hostname

Optional options:
    --version VERSION       Otturnaut version to install (default: latest)
    --container-runtime RT  Install container runtime: docker or podman
    --help                  Show this help message

Example:
    $0 --node-name otturnaut@outpost1.example.com \\
       --cookie secret_cookie \\
       --mission-control mc.example.com
EOF
    exit 1
}

log() {
    echo "==> $1"
}

error() {
    echo "ERROR: $1" >&2
    exit 1
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root"
    fi
}

detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)
            echo "x86_64"
            ;;
        aarch64|arm64)
            echo "aarch64"
            ;;
        *)
            error "Unsupported architecture: $arch"
            ;;
    esac
}

detect_distro() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo "$ID"
    else
        error "Cannot detect Linux distribution"
    fi
}

create_user() {
    if id "$OTTURNAUT_USER" &>/dev/null; then
        log "User $OTTURNAUT_USER already exists"
    else
        log "Creating system user $OTTURNAUT_USER"
        useradd --system --shell /usr/sbin/nologin --home-dir "$INSTALL_DIR" "$OTTURNAUT_USER"
    fi
}

get_latest_version() {
    curl -fsSL "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" | \
        grep '"tag_name"' | \
        sed -E 's/.*"tag_name": *"([^"]+)".*/\1/'
}

download_release() {
    local version="$1"
    local arch="$2"

    if [[ "$version" == "latest" ]]; then
        log "Fetching latest version..."
        version=$(get_latest_version)
        log "Latest version: $version"
    fi

    local filename="otturnaut-linux-${arch}.tar.gz"
    local url="https://github.com/${GITHUB_REPO}/releases/download/${version}/${filename}"
    local tmp_file="/tmp/${filename}"

    log "Downloading Otturnaut $version for $arch..."
    curl -fsSL -o "$tmp_file" "$url" || error "Failed to download release from $url"

    log "Extracting to $INSTALL_DIR..."
    mkdir -p "$INSTALL_DIR"
    tar -xzf "$tmp_file" -C "$INSTALL_DIR" --strip-components=1
    rm -f "$tmp_file"

    chown -R "$OTTURNAUT_USER:$OTTURNAUT_USER" "$INSTALL_DIR"
}

configure_caddy() {
    log "Configuring Caddy..."

    local caddy_bin="$INSTALL_DIR/bin/caddy"
    if [[ ! -f "$caddy_bin" ]]; then
        error "Caddy binary not found at $caddy_bin"
    fi

    log "Setting capabilities on Caddy binary..."
    setcap 'cap_net_bind_service=+ep' "$caddy_bin"

    mkdir -p "$INSTALL_DIR/etc/caddy"
    mkdir -p "$INSTALL_DIR/data/caddy"
    chown -R "$OTTURNAUT_USER:$OTTURNAUT_USER" "$INSTALL_DIR/etc/caddy"
    chown -R "$OTTURNAUT_USER:$OTTURNAUT_USER" "$INSTALL_DIR/data/caddy"

    if [[ ! -f "$INSTALL_DIR/etc/caddy/Caddyfile" ]]; then
        log "Creating initial Caddyfile..."
        cat > "$INSTALL_DIR/etc/caddy/Caddyfile" <<EOF
{
    admin localhost:2019
}
EOF
        chown "$OTTURNAUT_USER:$OTTURNAUT_USER" "$INSTALL_DIR/etc/caddy/Caddyfile"
    fi
}

create_systemd_units() {
    log "Creating systemd unit files..."

    cat > "$SYSTEMD_DIR/otturnaut-caddy.service" <<EOF
[Unit]
Description=Otturnaut Caddy Server
After=network.target

[Service]
Type=simple
User=$OTTURNAUT_USER
Group=$OTTURNAUT_USER
ExecStart=$INSTALL_DIR/bin/caddy run --config $INSTALL_DIR/etc/caddy/Caddyfile
ExecReload=$INSTALL_DIR/bin/caddy reload --config $INSTALL_DIR/etc/caddy/Caddyfile
Restart=on-failure
RestartSec=5

Environment=XDG_DATA_HOME=$INSTALL_DIR/data
Environment=XDG_CONFIG_HOME=$INSTALL_DIR/etc

[Install]
WantedBy=multi-user.target
EOF

    cat > "$SYSTEMD_DIR/otturnaut.service" <<EOF
[Unit]
Description=Otturnaut Agent
After=network.target otturnaut-caddy.service
Wants=otturnaut-caddy.service

[Service]
Type=simple
User=$OTTURNAUT_USER
Group=$OTTURNAUT_USER
ExecStart=$INSTALL_DIR/bin/otturnaut start
ExecStop=$INSTALL_DIR/bin/otturnaut stop
Restart=on-failure
RestartSec=5

Environment=RELEASE_NODE=$NODE_NAME
Environment=RELEASE_COOKIE=$COOKIE
Environment=MISSION_CONTROL_HOST=$MISSION_CONTROL
Environment=HOME=$INSTALL_DIR

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
}

enable_and_start_services() {
    log "Enabling and starting services..."

    systemctl enable otturnaut-caddy.service
    systemctl enable otturnaut.service

    systemctl start otturnaut-caddy.service
    systemctl start otturnaut.service
}

install_container_runtime() {
    local runtime="$1"
    local distro
    distro=$(detect_distro)

    case "$runtime" in
        docker)
            log "Installing Docker..."
            case "$distro" in
                ubuntu|debian)
                    apt-get update
                    apt-get install -y docker.io
                    ;;
                fedora)
                    dnf install -y docker
                    ;;
                centos|rhel|rocky|almalinux)
                    yum install -y docker
                    ;;
                *)
                    error "Unsupported distribution for Docker install: $distro"
                    ;;
            esac
            systemctl enable docker
            systemctl start docker
            usermod -aG docker "$OTTURNAUT_USER"
            ;;
        podman)
            log "Installing Podman..."
            case "$distro" in
                ubuntu|debian)
                    apt-get update
                    apt-get install -y podman
                    ;;
                fedora)
                    dnf install -y podman
                    ;;
                centos|rhel|rocky|almalinux)
                    yum install -y podman
                    ;;
                *)
                    error "Unsupported distribution for Podman install: $distro"
                    ;;
            esac
            ;;
        *)
            error "Unknown container runtime: $runtime"
            ;;
    esac
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --node-name)
                NODE_NAME="$2"
                shift 2
                ;;
            --cookie)
                COOKIE="$2"
                shift 2
                ;;
            --mission-control)
                MISSION_CONTROL="$2"
                shift 2
                ;;
            --version)
                VERSION="$2"
                shift 2
                ;;
            --container-runtime)
                CONTAINER_RUNTIME="$2"
                shift 2
                ;;
            --help|-h)
                usage
                ;;
            *)
                error "Unknown option: $1"
                ;;
        esac
    done

    if [[ -z "$NODE_NAME" ]]; then
        error "Missing required option: --node-name"
    fi
    if [[ -z "$COOKIE" ]]; then
        error "Missing required option: --cookie"
    fi
    if [[ -z "$MISSION_CONTROL" ]]; then
        error "Missing required option: --mission-control"
    fi
}

main() {
    parse_args "$@"

    log "Installing Otturnaut..."
    check_root

    local arch
    arch=$(detect_arch)
    log "Detected architecture: $arch"

    create_user
    download_release "$VERSION" "$arch"
    configure_caddy
    create_systemd_units
    enable_and_start_services

    if [[ -n "$CONTAINER_RUNTIME" ]]; then
        install_container_runtime "$CONTAINER_RUNTIME"
    fi

    log "Otturnaut installation complete!"
    log "Services status:"
    systemctl status otturnaut-caddy.service --no-pager || true
    systemctl status otturnaut.service --no-pager || true
}

main "$@"
