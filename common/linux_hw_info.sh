#!/usr/bin/env bash
# linux_hw_info.sh – Print detailed Linux hardware and system configuration.
#
# Covers:
#   - OS / distro identity      (/etc/os-release)
#   - Kernel version            (uname -r)
#   - glibc version             (ldd --version)
#   - Memory summary            (/proc/meminfo)
#   - CPU topology              (lscpu, /proc/cpuinfo, /sys/devices/system/cpu)
#     • processor description, vendor, model
#     • physical / logical core counts
#     • Hyper-Threading status
#     • C-state availability
#     • Turbo / Boost status     (intel_pstate / amd_pstate / cpufreq)
#     • Frequency scaling driver
#     • Active performance governor
#     • Energy-performance bias  (x86_energy_perf_policy / EPB sysfs)
#   - System clock source       (/sys/devices/system/clocksource)
#   - Hypervisor / virtualisation details
#   - NUMA topology             (numactl / lscpu)
#
# Usage (source or execute):
#   source common/linux_hw_info.sh   → defines print_linux_hw_info() in the caller
#   ./common/linux_hw_info.sh        → runs print_linux_hw_info() and exits
#
# The script is intentionally non-fatal: missing sysfs files or absent tools
# are reported as "N/A" rather than aborting the caller.

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

_hw_section() { printf '\n=== %s ===\n' "$*"; }
_hw_field()   { printf '  %-38s %s\n' "$1:" "$2"; }
_hw_raw()     { printf '  %s\n' "$*"; }
_hw_na()      { echo "N/A"; }

# Read a sysfs file, return its trimmed content or "N/A".
_sysfs_read() {
    local f="$1"
    if [[ -r "$f" ]]; then
        tr -d '[:space:]' < "$f"
    else
        _hw_na
    fi
}

# ---------------------------------------------------------------------------
# Individual section printers
# ---------------------------------------------------------------------------

_print_os_info() {
    _hw_section "Operating System"

    if [[ -f /etc/os-release ]]; then
        while IFS='=' read -r key val; do
            # Strip surrounding quotes
            val="${val%\"}"
            val="${val#\"}"
            case "$key" in
                PRETTY_NAME) _hw_field "Distribution"     "$val" ;;
                VERSION)     _hw_field "Version"          "$val" ;;
                ID)          _hw_field "ID"               "$val" ;;
                ID_LIKE)     _hw_field "ID_LIKE"          "$val" ;;
            esac
        done < /etc/os-release
    else
        _hw_field "Distribution" "N/A (/etc/os-release not found)"
    fi

    _hw_field "Kernel"  "$(uname -r)"
    _hw_field "Machine" "$(uname -m)"

    # glibc
    local glibc_ver
    glibc_ver=$(ldd --version 2>/dev/null | head -n1 | awk '{print $NF}')
    _hw_field "glibc version" "${glibc_ver:-N/A}"
}

_print_memory_info() {
    _hw_section "Memory"

    if [[ -f /proc/meminfo ]]; then
        local total avail swap_total swap_free huge_total huge_free huge_size
        total=$(awk '/^MemTotal:/{printf "%.1f GiB", $2/1048576}' /proc/meminfo)
        avail=$(awk '/^MemAvailable:/{printf "%.1f GiB", $2/1048576}' /proc/meminfo)
        swap_total=$(awk '/^SwapTotal:/{printf "%.1f GiB", $2/1048576}' /proc/meminfo)
        swap_free=$(awk '/^SwapFree:/{printf "%.1f GiB", $2/1048576}' /proc/meminfo)
        huge_total=$(awk '/^HugePages_Total:/{print $2}' /proc/meminfo)
        huge_free=$(awk '/^HugePages_Free:/{print $2}' /proc/meminfo)
        huge_size=$(awk '/^Hugepagesize:/{printf "%s kB", $2}' /proc/meminfo)

        _hw_field "Total RAM"            "${total:-N/A}"
        _hw_field "Available RAM"        "${avail:-N/A}"
        _hw_field "Swap total"           "${swap_total:-N/A}"
        _hw_field "Swap free"            "${swap_free:-N/A}"
        _hw_field "HugePages total"      "${huge_total:-N/A}"
        _hw_field "HugePages free"       "${huge_free:-N/A}"
        _hw_field "HugePage size"        "${huge_size:-N/A}"
    else
        _hw_field "Memory info" "N/A (/proc/meminfo not found)"
    fi
}

_print_cpu_info() {
    _hw_section "CPU"

    # Basic lscpu fields (works on most Linux systems)
    local cpu_name vendor family model step sockets cores_per_socket threads_per_core \
          total_logical total_physical

    if command -v lscpu &>/dev/null; then
        cpu_name=$(lscpu 2>/dev/null | awk -F': ' '/^Model name/{gsub(/^[[:space:]]+/,"",$2); print $2; exit}')
        vendor=$(lscpu 2>/dev/null | awk -F': ' '/^Vendor ID/{gsub(/^[[:space:]]+/,"",$2); print $2; exit}')
        sockets=$(lscpu 2>/dev/null | awk -F': ' '/^Socket\(s\)/{gsub(/^[[:space:]]+/,"",$2); print $2; exit}')
        cores_per_socket=$(lscpu 2>/dev/null | awk -F': ' '/^Core\(s\) per socket/{gsub(/^[[:space:]]+/,"",$2); print $2; exit}')
        threads_per_core=$(lscpu 2>/dev/null | awk -F': ' '/^Thread\(s\) per core/{gsub(/^[[:space:]]+/,"",$2); print $2; exit}')
        total_logical=$(lscpu 2>/dev/null | awk -F': ' '/^CPU\(s\):/{gsub(/^[[:space:]]+/,"",$2); print $2; exit}')

        _hw_field "Model name"           "${cpu_name:-N/A}"
        _hw_field "Vendor"               "${vendor:-N/A}"
        _hw_field "Sockets"              "${sockets:-N/A}"
        _hw_field "Cores per socket"     "${cores_per_socket:-N/A}"
        _hw_field "Threads per core"     "${threads_per_core:-N/A}"
        _hw_field "Total logical CPUs"   "${total_logical:-N/A}"

        # Total physical cores
        if [[ -n "$sockets" && -n "$cores_per_socket" ]]; then
            total_physical=$(( sockets * cores_per_socket ))
            _hw_field "Total physical cores" "$total_physical"
        fi

        # Hyper-Threading
        if [[ "${threads_per_core:-1}" -gt 1 ]]; then
            _hw_field "Hyper-Threading"  "Enabled (${threads_per_core} threads/core)"
        else
            _hw_field "Hyper-Threading"  "Disabled"
        fi

        # CPU max/min MHz
        local max_mhz min_mhz
        max_mhz=$(lscpu 2>/dev/null | awk -F': ' '/^CPU max MHz/{gsub(/^[[:space:]]+/,"",$2); print $2; exit}')
        min_mhz=$(lscpu 2>/dev/null | awk -F': ' '/^CPU min MHz/{gsub(/^[[:space:]]+/,"",$2); print $2; exit}')
        _hw_field "CPU max MHz"  "${max_mhz:-N/A}"
        _hw_field "CPU min MHz"  "${min_mhz:-N/A}"

        # L1/L2/L3 caches
        local l1d l1i l2 l3
        l1d=$(lscpu 2>/dev/null | awk -F': ' '/^L1d cache/{gsub(/^[[:space:]]+/,"",$2); print $2; exit}')
        l1i=$(lscpu 2>/dev/null | awk -F': ' '/^L1i cache/{gsub(/^[[:space:]]+/,"",$2); print $2; exit}')
        l2=$(lscpu  2>/dev/null | awk -F': ' '/^L2 cache/{gsub(/^[[:space:]]+/,"",$2); print $2; exit}')
        l3=$(lscpu  2>/dev/null | awk -F': ' '/^L3 cache/{gsub(/^[[:space:]]+/,"",$2); print $2; exit}')
        _hw_field "L1d cache"  "${l1d:-N/A}"
        _hw_field "L1i cache"  "${l1i:-N/A}"
        _hw_field "L2 cache"   "${l2:-N/A}"
        _hw_field "L3 cache"   "${l3:-N/A}"
    else
        # Fallback to /proc/cpuinfo
        _hw_field "Model name" "$(awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null || echo N/A)"
        _hw_field "lscpu"      "not available – output above may be incomplete"
    fi

    # ----- Frequency scaling driver -----
    local freq_driver
    freq_driver=$(_sysfs_read /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver)
    _hw_field "Freq scaling driver"  "$freq_driver"

    # ----- Governor (cpu0 as representative) -----
    local governor
    governor=$(_sysfs_read /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
    _hw_field "Freq scaling governor"  "$governor"

    # ----- Intel pstate / Turbo Boost -----
    local turbo_status="N/A"
    if [[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
        local no_turbo
        no_turbo=$(_sysfs_read /sys/devices/system/cpu/intel_pstate/no_turbo)
        if [[ "$no_turbo" == "1" ]]; then
            turbo_status="Disabled (intel_pstate)"
        else
            turbo_status="Enabled (intel_pstate)"
        fi
    elif [[ -f /sys/devices/system/cpu/cpufreq/boost ]]; then
        local boost
        boost=$(_sysfs_read /sys/devices/system/cpu/cpufreq/boost)
        if [[ "$boost" == "1" ]]; then
            turbo_status="Enabled (cpufreq boost)"
        else
            turbo_status="Disabled (cpufreq boost)"
        fi
    elif [[ -f /sys/devices/system/cpu/amd_pstate/status ]]; then
        turbo_status="AMD pstate: $(_sysfs_read /sys/devices/system/cpu/amd_pstate/status)"
    fi
    _hw_field "Turbo / Boost"  "$turbo_status"

    # ----- Energy-Performance Bias (EPB) -----
    local epb="N/A"
    # Kernel 5.17+ exposes per-cpu EPB via sysfs
    if [[ -f /sys/devices/system/cpu/cpu0/power/energy_perf_bias ]]; then
        epb=$(_sysfs_read /sys/devices/system/cpu/cpu0/power/energy_perf_bias)
    elif command -v x86_energy_perf_policy &>/dev/null; then
        epb=$(x86_energy_perf_policy --read 2>/dev/null | awk '/cpu0/{print $NF}' || echo "N/A")
    fi
    _hw_field "Energy-performance bias (EPB)"  "$epb"

    # ----- C-states -----
    _print_cstate_info
}

_print_cstate_info() {
    local cstate_dir="/sys/devices/system/cpu/cpu0/cpuidle"
    if [[ -d "$cstate_dir" ]]; then
        printf '  %-38s\n' "C-states (cpu0):"
        for state_dir in "$cstate_dir"/state*/; do
            [[ -d "$state_dir" ]] || continue
            local cstate_name cstate_latency cstate_disabled
            cstate_name=$(     _sysfs_read "${state_dir}name")
            cstate_latency=$(  _sysfs_read "${state_dir}latency")
            cstate_disabled=$( _sysfs_read "${state_dir}disable")
            local status="enabled"
            [[ "$cstate_disabled" == "1" ]] && status="disabled"
            printf '    %-10s latency=%-6s us  %s\n' \
                "$cstate_name" "$cstate_latency" "$status"
        done
    else
        _hw_field "C-states" "N/A (cpuidle sysfs not available)"
    fi
}

_print_clock_source() {
    _hw_section "Clock Source"

    local cs_dir="/sys/devices/system/clocksource/clocksource0"
    if [[ -d "$cs_dir" ]]; then
        _hw_field "Current"   "$(_sysfs_read ${cs_dir}/current_clocksource)"
        local available
        available=$(cat "${cs_dir}/available_clocksource" 2>/dev/null | tr ' ' ',')
        _hw_field "Available" "${available:-N/A}"
    else
        _hw_field "Clock source info" "N/A (sysfs not available)"
    fi
}

_print_hypervisor_info() {
    _hw_section "Hypervisor / Virtualisation"

    # systemd-detect-virt is the most reliable tool when present
    if command -v systemd-detect-virt &>/dev/null; then
        local virt
        virt=$(systemd-detect-virt 2>/dev/null || echo "none")
        _hw_field "Detected virtualisation" "$virt"
    fi

    # DMI / CPUID-level hypervisor flag
    local hv_flag="no"
    grep -qw "hypervisor" /proc/cpuinfo 2>/dev/null && hv_flag="yes"
    _hw_field "Hypervisor flag in cpuinfo" "$hv_flag"

    # dmesg / kernel messages about hypervisor (best-effort)
    if [[ -r /proc/sys/kernel/dmesg_restrict ]] && \
       [[ "$( cat /proc/sys/kernel/dmesg_restrict 2>/dev/null )" == "0" ]]; then
        local hv_msg
        hv_msg=$(dmesg 2>/dev/null | grep -i "hypervisor\|VMware\|KVM\|Xen\|VirtualBox" \
                 | head -n 3 | sed 's/^/    /')
        if [[ -n "$hv_msg" ]]; then
            printf '  dmesg hypervisor hints:\n%s\n' "$hv_msg"
        fi
    fi

    # DMI product name (works bare-metal and inside some VMs)
    if [[ -r /sys/class/dmi/id/product_name ]]; then
        _hw_field "DMI product name" "$(cat /sys/class/dmi/id/product_name 2>/dev/null)"
    fi
    if [[ -r /sys/class/dmi/id/sys_vendor ]]; then
        _hw_field "DMI system vendor" "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)"
    fi
}

_print_numa_info() {
    _hw_section "NUMA Topology"

    if command -v numactl &>/dev/null; then
        numactl --hardware 2>/dev/null | sed 's/^/  /'
    elif command -v lscpu &>/dev/null; then
        local numa_nodes
        numa_nodes=$(lscpu 2>/dev/null | awk -F': ' '/^NUMA node\(s\)/{gsub(/^[[:space:]]+/,"",$2); print $2; exit}')
        _hw_field "NUMA node(s)" "${numa_nodes:-N/A}"
        # Print per-node CPU lists from lscpu
        lscpu 2>/dev/null | grep -E '^NUMA node[0-9]+ CPU' | while IFS='=' read -r key val; do
            _hw_field "  $key" "$val"
        done
    elif [[ -d /sys/devices/system/node ]]; then
        local node_count
        node_count=$(ls -d /sys/devices/system/node/node* 2>/dev/null | wc -l)
        _hw_field "NUMA nodes (sysfs)" "$node_count"
    else
        _hw_field "NUMA info" "N/A (numactl/lscpu not available)"
    fi
}

# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

print_linux_hw_info() {
    printf '################################################################################\n'
    printf '#                  Linux Hardware & System Configuration                       #\n'
    printf '#                  Captured: %-43s#\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
    printf '################################################################################\n'

    _print_os_info
    _print_memory_info
    _print_cpu_info
    _print_clock_source
    _print_hypervisor_info
    _print_numa_info

    printf '\n################################################################################\n\n'
}

# ---------------------------------------------------------------------------
# When executed directly, print info and exit.
# When sourced, just define the function – the caller decides when to invoke it.
# ---------------------------------------------------------------------------

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    print_linux_hw_info
fi
