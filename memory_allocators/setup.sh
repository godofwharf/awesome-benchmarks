#!/usr/bin/env bash
# setup.sh – Top-level setup script for the memory-allocator benchmark suite.
#
# Detects the operating system, then delegates to the appropriate
# OS-specific installer inside the common/ directory (repo root sibling):
#
#   common/detect_os.sh    – OS detection
#   common/macos_install.sh  – macOS  (Homebrew)
#   common/debian_install.sh – Debian/Ubuntu (apt)
#   common/rhel_install.sh   – RHEL/CentOS/Fedora (yum/dnf)
#
# Usage:
#   ./setup.sh            # installs dependencies for the current OS
#   ./setup.sh --dry-run  # prints which installer would be called, then exits

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve the directory containing this script so it can be run from anywhere.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPTS_DIR="${REPO_ROOT}/common"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log()  { printf '[setup] %s\n' "$*"; }
warn() { printf '[setup] WARNING: %s\n' "$*" >&2; }
die()  { printf '[setup] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --dry-run   Detect the OS and print which installer would run, then exit.
  -h, --help  Show this help message.
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $arg" ;;
    esac
done

# ---------------------------------------------------------------------------
# Source the OS detection utility (sets OS_TYPE, OS_NAME, OS_VER).
# ---------------------------------------------------------------------------

detect_os_script="${SCRIPTS_DIR}/detect_os.sh"
[[ -f "$detect_os_script" ]] || die "detect_os.sh not found at: $detect_os_script"

# shellcheck source=../common/detect_os.sh
source "$detect_os_script"

log "Detected OS: ${OS_NAME} ${OS_VER} (type: ${OS_TYPE})"

# ---------------------------------------------------------------------------
# Dispatch to the correct OS-specific installer.
# ---------------------------------------------------------------------------

case "$OS_TYPE" in
    macos)
        INSTALLER="${SCRIPTS_DIR}/macos_install.sh"
        NEED_SUDO=false
        ;;
    debian)
        INSTALLER="${SCRIPTS_DIR}/debian_install.sh"
        NEED_SUDO=true
        ;;
    rhel)
        INSTALLER="${SCRIPTS_DIR}/rhel_install.sh"
        NEED_SUDO=true
        ;;
    unknown|unsupported)
        die "Unsupported OS '${OS_NAME}'. Please install dependencies manually:
  - gcc
  - perf (linux-perf / perf_events)
  - tcmalloc (gperftools / libgoogle-perftools)
  - jemalloc
  - hyperfine"
        ;;
esac

[[ -f "$INSTALLER" ]] || die "Installer not found: $INSTALLER"

if $DRY_RUN; then
    SUDO_PREFIX=""
    $NEED_SUDO && SUDO_PREFIX="sudo "
    log "[dry-run] Would execute: ${SUDO_PREFIX}${INSTALLER}"
    exit 0
fi

# Make sure the installer is executable.
chmod +x "$INSTALLER"

# ---------------------------------------------------------------------------
# Run the installer (with sudo when required on Linux).
# ---------------------------------------------------------------------------

if $NEED_SUDO; then
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        # Already root – run directly.
        bash "$INSTALLER"
    elif command -v sudo &>/dev/null; then
        log "Requesting elevated privileges (sudo) for package installation..."
        sudo bash "$INSTALLER"
    else
        die "This installer requires root privileges but 'sudo' is not available.
Run this script as root: su -c 'bash ${INSTALLER}'"
    fi
else
    bash "$INSTALLER"
fi

log "Setup complete. You can now run the benchmark with: bash run.sh"
