#!/usr/bin/env bash
# macOS package installer using Homebrew
# Usage: ./macos_install.sh

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log()  { printf '[macos_install] %s\n' "$*"; }
warn() { printf '[macos_install] WARNING: %s\n' "$*" >&2; }

# Check whether a brew formula/cask is already installed.
is_brew_installed() {
    brew list --formula "$1" &>/dev/null 2>&1
}

# Ensure Homebrew itself is present; install it if not.
ensure_brew() {
    if command -v brew &>/dev/null; then
        log "Homebrew already installed: $(brew --version | head -1)"
        return
    fi
    log "Homebrew not found. Installing..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Add brew to PATH for Apple Silicon machines
    if [[ -f /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
}

# Install a formula if it is not already present.
install_if_missing() {
    local pkg="$1"
    local formula="${2:-$1}"   # optional override for the brew formula name

    if is_brew_installed "$formula"; then
        log "$pkg is already installed – skipping."
    else
        log "Installing $pkg ..."
        brew install "$formula"
        log "$pkg installed successfully."
    fi
}

# ---------------------------------------------------------------------------
# perf is a Linux kernel tool; it is not available natively on macOS.
# We use 'cargo-flamegraph' + 'dtrace' as a near-equivalent profiling pair,
# or simply warn the user. The run.sh script already guards missing tools.
# ---------------------------------------------------------------------------
handle_perf() {
    warn "'perf' is a Linux kernel tool and is not available on macOS."
    warn "Profiling alternatives on macOS:"
    warn "  - Instruments / xctrace  (Apple developer tools)"
    warn "  - cargo-flamegraph       (via cargo install flamegraph)"
    warn "  - DTrace                 (built-in)"
    warn "The benchmark's run.sh will fall back gracefully on macOS."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    log "=== macOS dependency installer ==="

    ensure_brew

    # gcc – brew installs the latest GCC (e.g. gcc@13); 'gcc' formula works too
    install_if_missing "gcc" "gcc"

    # gperftools ships tcmalloc on macOS
    install_if_missing "tcmalloc (via gperftools)" "gperftools"

    # jemalloc
    install_if_missing "jemalloc" "jemalloc"

    # hyperfine – command-line benchmarking tool
    install_if_missing "hyperfine" "hyperfine"

    # perf – Linux only
    handle_perf

    log "=== macOS installation complete ==="
}

main "$@"
