#!/usr/bin/env bash
set -euo pipefail

# Build script for Otturnaut release packages
# Creates tar.gz archives for distribution via GitHub releases

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
readonly VERSION="${VERSION:-0.1.0}"
readonly OTTURNAUT_DIR="otturnaut-${VERSION}"

usage() {
    cat <<EOF
Usage: $0 <ARCH>

Build a release package for Otturnaut.

Arguments:
    ARCH    Target architecture: x86_64 or aarch64

Environment Variables:
    VERSION    Release version (default: 0.1.0)
    MIX_ENV    Mix environment (default: prod)

Example:
    $0 x86_64
    VERSION=0.1.0 $0 aarch64
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

get_caddy_url() {
    local arch="$1"
    case "$arch" in
        x86_64)
            echo "https://github.com/caddyserver/caddy/releases/download/v2.10.2/caddy_2.10.2_linux_amd64.tar.gz"
            ;;
        aarch64)
            echo "https://github.com/caddyserver/caddy/releases/download/v2.10.2/caddy_2.10.2_linux_arm64.tar.gz"
            ;;
        *)
            error "Unsupported architecture: $arch"
            ;;
    esac
}

build_elixir_release() {
    log "Building Elixir release..."

    cd "$PROJECT_ROOT"

    # Ensure release is fresh
    rm -rf "_build/${MIX_ENV}/rel/otturnaut"

    # Build release
    mix release --overwrite
}

download_caddy() {
    local arch="$1"
    local output_dir="$2"
    local caddy_url

    caddy_url=$(get_caddy_url "$arch")

    log "Downloading Caddy for $arch..."
    curl -fsSL "$caddy_url" | tar -xz -C "$output_dir" caddy
}

package_release() {
    local arch="$1"
    local build_dir="$PROJECT_ROOT/_build/release_pkg"
    local output_file="$PROJECT_ROOT/otturnaut-linux-${arch}.tar.gz"

    log "Packaging release for $arch..."

    # Clean build directory
    rm -rf "$build_dir"
    mkdir -p "$build_dir/$OTTURNAUT_DIR"

    # Copy Elixir release
    log "Copying Elixir release..."
    cp -r "_build/${MIX_ENV}/rel/otturnaut/"* "$build_dir/$OTTURNAUT_DIR/"

    # Download and place Caddy binary in bin directory
    log "Downloading and placing Caddy binary..."
    mkdir -p "$build_dir/$OTTURNAUT_DIR/bin"
    download_caddy "$arch" "$build_dir/$OTTURNAUT_DIR/bin"

    # Set executable permissions
    chmod +x "$build_dir/$OTTURNAUT_DIR/bin/caddy"
    chmod +x "$build_dir/$OTTURNAUT_DIR/bin/otturnaut"

    # Create tar.gz archive
    log "Creating tar.gz archive..."
    cd "$build_dir"
    tar -czf "$output_file" "$OTTURNAUT_DIR"

    # Cleanup
    cd "$PROJECT_ROOT"
    rm -rf "$build_dir"

    log "Created: $output_file"
}

main() {
    if [[ $# -ne 1 ]]; then
        usage
    fi

    local arch="$1"

    case "$arch" in
        x86_64|aarch64)
            ;;
        *)
            error "Invalid architecture: $arch. Must be x86_64 or aarch64"
            ;;
    esac

    log "Building Otturnaut v${VERSION} for ${arch}"

    # Default MIX_ENV to prod if not set
    export MIX_ENV="${MIX_ENV:-prod}"

    build_elixir_release
    package_release "$arch"

    log "Build complete!"
}

main "$@"
