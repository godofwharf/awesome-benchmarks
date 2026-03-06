#!/usr/bin/env bash
# OS detection utility
#
# Detects the operating system / distribution and prints a normalised token:
#   macos   – macOS / OS X
#   debian  – Debian, Ubuntu, Linux Mint, Pop!_OS, …
#   rhel    – RHEL, CentOS, Fedora, Rocky, AlmaLinux, …
#
# Also exports:
#   OS_TYPE   – one of the tokens above
#   OS_NAME   – human-readable distro name  (e.g. "Ubuntu")
#   OS_VER    – version string              (e.g. "22.04")
#
# Usage (source or execute):
#   source scripts/detect_os.sh   → sets variables in the calling shell
#   ./scripts/detect_os.sh        → prints OS_TYPE to stdout

set -euo pipefail

# ---------------------------------------------------------------------------
# Detection logic
# ---------------------------------------------------------------------------

detect_os() {
    local kernel
    kernel="$(uname -s)"

    case "$kernel" in
        Darwin)
            OS_TYPE="macos"
            OS_NAME="macOS"
            OS_VER="$(sw_vers -productVersion 2>/dev/null || uname -r)"
            ;;
        Linux)
            # /etc/os-release is the modern standard (systemd era).
            if [[ -f /etc/os-release ]]; then
                # shellcheck source=/dev/null
                . /etc/os-release
                OS_NAME="${NAME:-Unknown}"
                OS_VER="${VERSION_ID:-unknown}"
                local id_lower
                id_lower="$(echo "${ID:-}" | tr '[:upper:]' '[:lower:]')"
                local id_like_lower
                id_like_lower="$(echo "${ID_LIKE:-}" | tr '[:upper:]' '[:lower:]')"

                case "$id_lower" in
                    debian|ubuntu|linuxmint|pop|elementary|kali|raspbian)
                        OS_TYPE="debian"
                        ;;
                    rhel|centos|fedora|rocky|almalinux|ol|scientific)
                        OS_TYPE="rhel"
                        ;;
                    *)
                        # Fall back to ID_LIKE
                        if echo "$id_like_lower" | grep -qE '\bdebian\b|\bubuntu\b'; then
                            OS_TYPE="debian"
                        elif echo "$id_like_lower" | grep -qE '\brhel\b|\bfedora\b|\bcentos\b'; then
                            OS_TYPE="rhel"
                        else
                            OS_TYPE="unknown"
                        fi
                        ;;
                esac

            # Older systems without /etc/os-release
            elif [[ -f /etc/redhat-release ]]; then
                OS_TYPE="rhel"
                OS_NAME="$(cat /etc/redhat-release)"
                OS_VER="unknown"
            elif [[ -f /etc/debian_version ]]; then
                OS_TYPE="debian"
                OS_NAME="Debian"
                OS_VER="$(cat /etc/debian_version)"
            else
                OS_TYPE="unknown"
                OS_NAME="Unknown Linux"
                OS_VER="unknown"
            fi
            ;;
        *)
            OS_TYPE="unsupported"
            OS_NAME="$kernel"
            OS_VER="$(uname -r)"
            ;;
    esac

    export OS_TYPE OS_NAME OS_VER
}

# ---------------------------------------------------------------------------
# When executed directly, print detected info and exit.
# When sourced, just run detection so the caller can use the variables.
# ---------------------------------------------------------------------------

detect_os

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    printf 'OS_TYPE=%s\nOS_NAME=%s\nOS_VER=%s\n' "$OS_TYPE" "$OS_NAME" "$OS_VER"
fi
