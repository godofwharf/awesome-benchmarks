#!/usr/bin/env bash
# Debian / Ubuntu package installer using apt
# Usage: sudo ./debian_install.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log()  { printf '[debian_install] %s\n' "$*"; }
warn() { printf '[debian_install] WARNING: %s\n' "$*" >&2; }
die()  { printf '[debian_install] ERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        die "This script must be run as root (use sudo)."
    fi
}

# Return 0 if the dpkg package is installed (any status that is 'ii').
is_dpkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "^install ok installed"
}

# Install a package if it is not already present.
install_if_missing() {
    local pkg="$1"

    if is_dpkg_installed "$pkg"; then
        log "$pkg is already installed – skipping."
    else
        log "Installing $pkg ..."
        apt-get install -y "$pkg"
        log "$pkg installed successfully."
    fi
}

# ---------------------------------------------------------------------------
# hyperfine is not in the standard Debian/Ubuntu repos on older releases.
# We install it from the GitHub release tarball when apt can't find it.
# ---------------------------------------------------------------------------
install_hyperfine() {
    if command -v hyperfine &>/dev/null; then
        log "hyperfine is already installed: $(hyperfine --version)"
        return
    fi

    # Try apt first (available in Ubuntu 22.10+ / Debian 12+)
    if apt-cache show hyperfine &>/dev/null 2>&1; then
        install_if_missing "hyperfine"
        return
    fi

    log "hyperfine not found in apt repos – installing from GitHub release..."
    local version="1.18.0"
    local arch
    arch=$(dpkg --print-architecture)
    local deb_url="https://github.com/sharkdp/hyperfine/releases/download/v${version}/hyperfine_${version}_${arch}.deb"
    local tmp_deb
    tmp_deb=$(mktemp /tmp/hyperfine_XXXXXX.deb)

    if command -v curl &>/dev/null; then
        curl -fsSL "$deb_url" -o "$tmp_deb"
    elif command -v wget &>/dev/null; then
        wget -q "$deb_url" -O "$tmp_deb"
    else
        die "Neither curl nor wget is available. Cannot download hyperfine."
    fi

    dpkg -i "$tmp_deb"
    rm -f "$tmp_deb"
    log "hyperfine installed successfully."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    log "=== Debian/Ubuntu dependency installer ==="

    require_root

    log "Updating apt package index..."
    apt-get update -y

    # Build tools
    install_if_missing "build-essential"   # provides gcc, make, etc.
    install_if_missing "gcc"

    # Linux perf
    # The package name varies by kernel version; try linux-tools-generic first.
    if is_dpkg_installed "linux-tools-generic" || command -v perf &>/dev/null; then
        log "perf is already installed – skipping."
    else
        log "Installing perf (linux-tools-generic)..."
        apt-get install -y linux-tools-generic linux-tools-common || \
            warn "Could not install linux-tools-generic. Try: apt-get install linux-tools-\$(uname -r)"
    fi

    # tcmalloc – provided by the google-perftools / libgoogle-perftools packages
    install_if_missing "libgoogle-perftools-dev"
    install_if_missing "google-perftools"

    # jemalloc
    install_if_missing "libjemalloc-dev"

    # hyperfine
    install_hyperfine

    log "=== Debian/Ubuntu installation complete ==="
}

main "$@"
