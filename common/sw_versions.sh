#!/usr/bin/env bash
# sw_versions.sh – Software version detection for memory allocator benchmarks
#
# Provides a single function: get_allocator_versions
#
# The function detects the current OS (RHEL/Debian/macOS) and queries the
# appropriate package manager to extract the installed version of each
# allocator's backing library:
#
#   PTMALLOC2_VERSION  – from glibc          (dnf / dpkg / sw_vers)
#   JEMALLOC_VERSION   – from jemalloc       (dnf / dpkg)
#   TCMALLOC_VERSION   – from gperftools-libs (dnf / dpkg)
#
# If a version cannot be determined, the variable is set to "NA" and a
# warning is logged to stderr. This function never exits non-zero; callers
# are guaranteed to get usable (if potentially "NA") values.
#
# Usage:
#   source common/sw_versions.sh
#   get_allocator_versions        # populates the three variables above
#   echo "$PTMALLOC2_VERSION"

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

_swver_log_warn() {
    echo "[WARNING] sw_versions: $*" >&2
}

# _query_dnf <package>
#   Returns the installed version via dnf/rpm, or empty string on failure.
_query_dnf() {
    local pkg="$1"
    local ver=""

    # Prefer rpm -q as it is instantaneous and doesn't hit the network.
    if command -v rpm &>/dev/null; then
        ver="$(rpm -q --queryformat '%{VERSION}' "$pkg" 2>/dev/null || true)"
        # rpm prints "package not installed" on failure – treat that as empty.
        if [[ "$ver" == *"not installed"* ]]; then
            ver=""
        fi
    fi

    # Fall back to dnf info if rpm gave nothing useful.
    if [[ -z "$ver" ]] && command -v dnf &>/dev/null; then
        ver="$(dnf info "$pkg" 2>/dev/null \
              | grep -i '^Version' \
              | head -1 \
              | cut -d':' -f2 \
              | tr -d ' \t' || true)"
    fi

    echo "$ver"
}

# _query_dpkg <package>
#   Returns the installed version via dpkg-query, or empty string on failure.
_query_dpkg() {
    local pkg="$1"
    local ver=""

    if command -v dpkg-query &>/dev/null; then
        ver="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)"
    fi

    # dpkg-query exits non-zero and prints nothing when the package is absent.
    echo "$ver"
}

# _resolve_version <os_type> <rhel_pkg> <debian_pkg> <description>
#   Queries the appropriate package manager based on $os_type and returns the
#   version string, or "NA" if it cannot be determined.
_resolve_version() {
    local os_type="$1"
    local rhel_pkg="$2"
    local debian_pkg="$3"
    local description="$4"
    local ver=""

    case "$os_type" in
        rhel)
            ver="$(_query_dnf "$rhel_pkg")"
            ;;
        debian)
            ver="$(_query_dpkg "$debian_pkg")"
            ;;
        macos)
            # glibc / gperftools / jemalloc are not native macOS packages.
            # Attempt Homebrew as a best-effort lookup.
            if command -v brew &>/dev/null; then
                ver="$(brew list --versions "$debian_pkg" 2>/dev/null \
                      | awk '{print $2}' || true)"
            fi
            ;;
        *)
            _swver_log_warn "Unsupported OS type '${os_type}' – cannot determine version for ${description}."
            ver=""
            ;;
    esac

    if [[ -z "$ver" ]]; then
        _swver_log_warn "Version of '${description}' could not be determined – reporting NA."
        echo "NA"
    else
        echo "$ver"
    fi
}

# ---------------------------------------------------------------------------
# Public function
# ---------------------------------------------------------------------------

# get_allocator_versions
#   Detects OS and populates:
#     PTMALLOC2_VERSION, JEMALLOC_VERSION, TCMALLOC_VERSION
#
#   Requires common/detect_os.sh to have been sourced (or will source it).
get_allocator_versions() {
    # Ensure OS_TYPE is available; source detect_os.sh if not already done.
    if [[ -z "${OS_TYPE:-}" ]]; then
        local _detect_script
        _detect_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/detect_os.sh"
        if [[ -f "$_detect_script" ]]; then
            # shellcheck source=./detect_os.sh
            source "$_detect_script"
        else
            _swver_log_warn "detect_os.sh not found at ${_detect_script} – OS type unknown."
            OS_TYPE="unknown"
        fi
    fi

    echo "[INFO]  Detecting allocator library versions (OS type: ${OS_TYPE}) ..."

    # ptmalloc2 is part of glibc.
    # RHEL package: glibc   |  Debian package: libc6
    PTMALLOC2_VERSION="$(_resolve_version "$OS_TYPE" "glibc" "libc6" "ptmalloc2 (glibc)")"

    # jemalloc
    # RHEL package: jemalloc  |  Debian package: libjemalloc-dev / libjemalloc2
    JEMALLOC_VERSION="$(_resolve_version "$OS_TYPE" "jemalloc" "libjemalloc2" "jemalloc")"
    # If the primary Debian package returned NA, try the dev package.
    if [[ "$JEMALLOC_VERSION" == "NA" && "$OS_TYPE" == "debian" ]]; then
        JEMALLOC_VERSION="$(_resolve_version "$OS_TYPE" "jemalloc" "libjemalloc-dev" "jemalloc (dev)")"
    fi

    # tcmalloc ships inside gperftools.
    # RHEL package: gperftools-libs  |  Debian package: libgoogle-perftools4
    TCMALLOC_VERSION="$(_resolve_version "$OS_TYPE" "gperftools-libs" "libgoogle-perftools4" "tcmalloc (gperftools-libs)")"
    # If the primary Debian package returned NA, try the dev package.
    if [[ "$TCMALLOC_VERSION" == "NA" && "$OS_TYPE" == "debian" ]]; then
        TCMALLOC_VERSION="$(_resolve_version "$OS_TYPE" "gperftools-libs" "google-perftools" "tcmalloc (google-perftools)")"
    fi

    export PTMALLOC2_VERSION JEMALLOC_VERSION TCMALLOC_VERSION
}
