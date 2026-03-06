#!/usr/bin/env bash
# RHEL / CentOS / Fedora / Rocky / AlmaLinux package installer using yum/dnf
# Usage: sudo ./rhel_install.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log()  { printf '[rhel_install] %s\n' "$*"; }
warn() { printf '[rhel_install] WARNING: %s\n' "$*" >&2; }
die()  { printf '[rhel_install] ERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        die "This script must be run as root (use sudo)."
    fi
}

# Prefer dnf when available (RHEL 8+/Fedora), fall back to yum (RHEL 6/7).
PKG_MGR="yum"
command -v dnf &>/dev/null && PKG_MGR="dnf"

# Return 0 if the rpm package is installed.
is_rpm_installed() {
    rpm -q "$1" &>/dev/null
}

# Return 0 if the binary exists in PATH.
is_cmd_available() {
    command -v "$1" &>/dev/null
}

# Install a package if it is not already present.
install_if_missing() {
    local pkg="$1"

    if is_rpm_installed "$pkg"; then
        log "$pkg is already installed – skipping."
    else
        log "Installing $pkg ..."
        "$PKG_MGR" install -y "$pkg"
        log "$pkg installed successfully."
    fi
}

# ---------------------------------------------------------------------------
# Enable EPEL – many packages (jemalloc, gperftools, hyperfine) live there.
# ---------------------------------------------------------------------------
ensure_epel() {
    if is_rpm_installed "epel-release" || is_rpm_installed "epel-next-release"; then
        log "EPEL already enabled."
        return
    fi

    log "Enabling EPEL repository..."
    "$PKG_MGR" install -y epel-release || \
        "$PKG_MGR" install -y \
            "https://dl.fedoraproject.org/pub/epel/epel-release-latest-$(rpm -E '%{rhel}').noarch.rpm" || \
        warn "Could not enable EPEL automatically. Some packages may not be found."
}

# ---------------------------------------------------------------------------
# hyperfine is not in EPEL for all RHEL versions.
# Fall back to the GitHub release binary when the package is unavailable.
# ---------------------------------------------------------------------------
install_hyperfine() {
    if is_cmd_available hyperfine; then
        log "hyperfine is already installed: $(hyperfine --version)"
        return
    fi

    # Try the package manager first
    if "$PKG_MGR" list available hyperfine &>/dev/null 2>&1; then
        install_if_missing "hyperfine"
        return
    fi

    log "hyperfine not found in repos – installing from GitHub release..."
    local version="1.18.0"
    local arch
    arch=$(uname -m)   # x86_64 or aarch64
    local tar_url="https://github.com/sharkdp/hyperfine/releases/download/v${version}/hyperfine-v${version}-${arch}-unknown-linux-musl.tar.gz"
    local tmp_dir
    tmp_dir=$(mktemp -d /tmp/hyperfine_XXXXXX)

    if command -v curl &>/dev/null; then
        curl -fsSL "$tar_url" | tar -xz -C "$tmp_dir" --strip-components=1
    elif command -v wget &>/dev/null; then
        wget -qO- "$tar_url" | tar -xz -C "$tmp_dir" --strip-components=1
    else
        die "Neither curl nor wget is available. Cannot download hyperfine."
    fi

    install -m 755 "$tmp_dir/hyperfine" /usr/local/bin/hyperfine
    rm -rf "$tmp_dir"
    log "hyperfine installed to /usr/local/bin/hyperfine."
}

# ---------------------------------------------------------------------------
# perf – part of the linux-tools / kernel-tools package on RHEL.
# ---------------------------------------------------------------------------
install_perf() {
    if is_cmd_available perf; then
        log "perf is already installed."
        return
    fi

    log "Installing perf (kernel-tools / perf)..."
    # RHEL 8/9 ships 'perf' as a standalone package
    "$PKG_MGR" install -y perf 2>/dev/null || \
        "$PKG_MGR" install -y kernel-tools 2>/dev/null || \
        warn "Could not install perf. Ensure kernel-devel matches the running kernel."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    log "=== RHEL/CentOS/Fedora dependency installer (${PKG_MGR}) ==="

    require_root

    ensure_epel

    # Development tools (gcc, make, etc.)
    install_if_missing "gcc"
    # gcc-c++ is needed by some gperftools builds
    install_if_missing "gcc-c++"

    # perf
    install_perf

    # tcmalloc – provided by gperftools
    install_if_missing "gperftools"
    install_if_missing "gperftools-devel"

    # jemalloc
    install_if_missing "jemalloc"
    install_if_missing "jemalloc-devel"

    # hyperfine
    install_hyperfine

    log "=== RHEL/CentOS/Fedora installation complete ==="
}

main "$@"
