#!/usr/bin/env bash
# run.sh – Memory allocator benchmark runner
#
# What this script does:
#   1. Resolves paths relative to the repository root so it can be invoked
#      from any working directory.
#   2. Sources common/linux_hw_info.sh and prints full system/HW details.
#   3. Sources common/sw_versions.sh and prints the installed version of each
#      allocator library (ptmalloc2/glibc, jemalloc, tcmalloc/gperftools-libs).
#      Versions that cannot be determined are reported as NA; the run continues.
#   4. Validates that every non-default allocator's .so file is present before
#      starting any benchmark run.
#   5. Runs membench under `perf record` for each allocator, with verbose
#      progress logging.
#   6. Saves perf record data and perf script output to   perf/<name>_<t>t/
#   7. Saves the full benchmark stdout (raw membench output) to             out/
#   8. Tees all script output (the summary table + log lines) to both the
#      console and out/benchmark_<timestamp>.log
#
# Usage: run.sh [options]
#
#   -t, --threads      <n>        number of worker threads          (default 4)
#   --duration         <s>        total run time per benchmark (s)  (default 30)
#   --max_rss_target   <MiB>      stop once RSS reaches this limit   (default 40% of system memory)
#   --workload         frag|mixed workload to pass to membench       (default frag)
#   --obj_size_min     <bytes>    min object size; mixed only        (default 64)
#   --obj_size_max     <bytes>    max object size; mixed only        (default 65536)
#   --obj_retention    <0-100>    retention probability %; mixed only(default 50)
#
# All flags except -t/--threads are forwarded verbatim to membench.

set -euo pipefail

NUM_VCORES=$(nproc)

# ---------------------------------------------------------------------------
# Transparent Huge Page (THP) helpers – tcmalloc only
#
# thp_set   – saves current kernel THP settings and applies the values that
#             are optimal for tcmalloc's large-span allocations:
#               enabled       → always          (use THPs system-wide)
#               defrag        → defer+madvise   (promote on madvise; defer
#                                                background compaction)
#               max_ptes_none → 0               (khugepaged never fills a
#                                                region unless all pages are
#                                                already huge; "none" in the
#                                                sense that no non-huge PTEs
#                                                are tolerated)
#
# thp_restore – writes the values that were saved by thp_set back to the
#               kernel knobs.  Safe to call even if thp_set never ran (the
#               saved variables will be empty and the writes are skipped).
#
# An EXIT trap calls thp_restore so the originals are always reinstated,
# even when the script exits early with a non-zero status.
# ---------------------------------------------------------------------------

THP_ENABLED_PATH="/sys/kernel/mm/transparent_hugepage/enabled"
THP_DEFRAG_PATH="/sys/kernel/mm/transparent_hugepage/defrag"
THP_MAX_PTES_NONE_PATH="/sys/kernel/mm/transparent_hugepage/khugepaged/max_ptes_none"

_SAVED_THP_ENABLED=""
_SAVED_THP_DEFRAG=""
_SAVED_THP_MAX_PTES_NONE=""

thp_set() {
    # Require root – writing to /sys requires elevated privileges.
    if [[ $EUID -ne 0 ]]; then
        echo "[WARNING] THP tuning requires root privileges (current EUID=${EUID}). Skipping THP configuration."
        return 0
    fi

    # Check that all three sysfs knobs exist before touching any of them.
    local missing=0
    for p in "$THP_ENABLED_PATH" "$THP_DEFRAG_PATH" "$THP_MAX_PTES_NONE_PATH"; do
        if [[ ! -f "$p" ]]; then
            echo "[WARNING] THP knob not found: ${p}. Skipping THP configuration."
            missing=1
        fi
    done
    [[ $missing -ne 0 ]] && return 0

    # Capture current values before making any changes.
    # The 'enabled' and 'defrag' files show the active token surrounded by
    # brackets, e.g. "[madvise] always never".  Extract only the bracketed word.
    _SAVED_THP_ENABLED="$(awk 'match($0, /\[([^\]]+)\]/, a) { print a[1] }' "$THP_ENABLED_PATH")"
    _SAVED_THP_DEFRAG="$(awk 'match($0, /\[([^\]]+)\]/, a) { print a[1] }' "$THP_DEFRAG_PATH")"
    _SAVED_THP_MAX_PTES_NONE="$(cat "$THP_MAX_PTES_NONE_PATH")"

    echo "[$(date '+%H:%M:%S')] THP: saving current values:"
    echo "  ${THP_ENABLED_PATH}       = ${_SAVED_THP_ENABLED}"
    echo "  ${THP_DEFRAG_PATH}        = ${_SAVED_THP_DEFRAG}"
    echo "  ${THP_MAX_PTES_NONE_PATH} = ${_SAVED_THP_MAX_PTES_NONE}"

    # Apply tcmalloc-optimal settings.
    echo "always"        > "$THP_ENABLED_PATH"
    echo "defer+madvise" > "$THP_DEFRAG_PATH"
    echo "0"             > "$THP_MAX_PTES_NONE_PATH"

    echo "[$(date '+%H:%M:%S')] THP: applied settings:"
    echo "  enabled       → always"
    echo "  defrag        → defer+madvise"
    echo "  max_ptes_none → 0 (no non-huge PTEs tolerated)"
}

thp_restore() {
    # Nothing to restore if thp_set was never called or was skipped.
    if [[ -z "$_SAVED_THP_ENABLED" && -z "$_SAVED_THP_DEFRAG" && -z "$_SAVED_THP_MAX_PTES_NONE" ]]; then
        return 0
    fi

    if [[ $EUID -ne 0 ]]; then
        echo "[WARNING] THP restore requires root privileges (current EUID=${EUID}). Cannot restore THP settings."
        return 0
    fi

    echo "[$(date '+%H:%M:%S')] THP: restoring original values:"
    echo "  enabled       → ${_SAVED_THP_ENABLED}"
    echo "  defrag        → ${_SAVED_THP_DEFRAG}"
    echo "  max_ptes_none → ${_SAVED_THP_MAX_PTES_NONE}"

    [[ -f "$THP_ENABLED_PATH"       ]] && echo "$_SAVED_THP_ENABLED"       > "$THP_ENABLED_PATH"
    [[ -f "$THP_DEFRAG_PATH"        ]] && echo "$_SAVED_THP_DEFRAG"        > "$THP_DEFRAG_PATH"
    [[ -f "$THP_MAX_PTES_NONE_PATH" ]] && echo "$_SAVED_THP_MAX_PTES_NONE" > "$THP_MAX_PTES_NONE_PATH"

    # Clear saved state so a second call is a no-op.
    _SAVED_THP_ENABLED=""
    _SAVED_THP_DEFRAG=""
    _SAVED_THP_MAX_PTES_NONE=""

    echo "[$(date '+%H:%M:%S')] THP: original values restored."
}

# Ensure THP settings are always reinstated on any exit (normal or error).
trap thp_restore EXIT

# ===========================================================================
# Allocator tunables
#
# Uncomment and adjust any variable below to override the allocator default.
# All variables are exported so they are visible to child processes (membench
# and any LD_PRELOAD'd allocator library).
# ===========================================================================

# ---------------------------------------------------------------------------
# ptmalloc2 (glibc) tunables
# ---------------------------------------------------------------------------

# MALLOC_TOP_PAD_  (default: 131072 = 128 KiB)
#   Extra bytes added to each sbrk(2) call when growing the heap, and the
#   amount of free space preserved at the top after trimming.  Raising this
#   reduces sbrk call frequency at the cost of more resident virtual memory.
#   NOTE: setting this variable disables glibc's dynamic mmap-threshold
#   adjustment.  The value used (10 MiB) improves ptmalloc2 throughput by
#   ~30-40% in allocation-heavy benchmarks.
export MALLOC_TOP_PAD_=10485760

# MALLOC_TRIM_THRESHOLD_  (default: 131072 = 128 KiB)
#   Minimum amount of free memory at the top of the heap before free(3) calls
#   sbrk(2) to release it back to the OS.  Raise to reduce trim syscalls;
#   set to -1 to disable trimming entirely.
# Setting MALLOC_TRIM_THRESHOLD to the same value as MALLOC_TOP_PAD_
export MALLOC_TRIM_THRESHOLD_=10485760

# MALLOC_MMAP_THRESHOLD_  (default: 131072 = 128 KiB, auto-grows up to ~32 MiB)
#   Allocations >= this size use mmap(2) instead of the brk heap.  mmap'd
#   blocks are returned to the OS immediately on free but cannot be reused
#   from the free list.  Raise to keep more allocations on the heap (better
#   reuse, lower RSS churn); lower to release large blocks immediately.
#   NOTE: setting this variable disables dynamic threshold adjustment.
# export MALLOC_MMAP_THRESHOLD_=1048576     # 1 MiB

# MALLOC_MMAP_MAX_  (default: 65536)
#   Maximum number of simultaneous mmap(2) allocations.  Set to 0 to disable
#   mmap entirely and use brk only.
# export MALLOC_MMAP_MAX_=65536

# MALLOC_ARENA_MAX  (default: 0 = auto, derived from MALLOC_ARENA_TEST x CPUs)
#   Hard cap on the number of malloc arenas.  More arenas reduce lock
#   contention across threads but increase per-arena memory overhead and
#   fragmentation.  Set equal to thread count for maximum parallel throughput.
export MALLOC_ARENA_MAX=${NUM_VCORES}

# MALLOC_ARENA_TEST  (default: 2 on 32-bit, 8 on 64-bit)
#   Number of arenas to create before the arena cap is computed (typically
#   2-8x CPU count).  Only consulted when MALLOC_ARENA_MAX=0.
# export MALLOC_ARENA_TEST=8

# MALLOC_PERTURB_  (default: 0 = disabled)
#   When nonzero, fills allocated bytes with ~(value & 0xff) and freed bytes
#   with (value & 0xff) to catch use-after-free / uninitialised-read bugs.
#   Always keep at 0 in performance benchmarks.
# export MALLOC_PERTURB_=0

# ---------------------------------------------------------------------------
# tcmalloc (gperftools) tunables
# ---------------------------------------------------------------------------

# TCMALLOC_SKIP_SBRK  (default: false)
#   When 1, tcmalloc never calls sbrk(2) and obtains all memory via mmap(2).
#   Useful to isolate mmap-only behaviour or in environments where sbrk is
#   undesirable.
# export TCMALLOC_SKIP_SBRK=1

# TCMALLOC_MAX_TOTAL_THREAD_CACHE_BYTES  (default: 33554432 = 32 MiB)
#   Upper bound on the combined size of all per-thread caches.  Larger values
#   reduce trips to the central free list and lower lock contention, at the
#   cost of higher RSS.  Typical tuning range: 64 MiB - 512 MiB for highly
#   parallel benchmarks.
# export TCMALLOC_MAX_TOTAL_THREAD_CACHE_BYTES=33554432

# TCMALLOC_RELEASE_RATE  (default: 1.0, range: 0-10)
#   Rate at which free spans are returned to the kernel via madvise.  0 =
#   never release (maximises throughput); 10 = release aggressively (minimises
#   RSS).
# export TCMALLOC_RELEASE_RATE=1.0

# TCMALLOC_AGGRESSIVE_DECOMMIT  (default: false)
#   When 1, every freed span is immediately returned to the kernel instead of
#   being held in the page heap.  Reduces RSS at a ~2% CPU throughput cost.
# export TCMALLOC_AGGRESSIVE_DECOMMIT=0

# TCMALLOC_HEAP_LIMIT_MB  (default: 0 = no limit)
#   Hard cap on total page heap size in MiB.  When hit, tcmalloc attempts to
#   return free spans; if insufficient it OOMs.  Use to simulate memory-
#   constrained production environments.
# export TCMALLOC_HEAP_LIMIT_MB=0

# TCMALLOC_LARGE_ALLOC_REPORT_THRESHOLD  (default: 1073741824 = 1 GiB)
#   Allocations larger than this emit a stack trace to stderr.  Leave at the
#   default for clean benchmark output; lower to diagnose unexpectedly large
#   allocations.
# export TCMALLOC_LARGE_ALLOC_REPORT_THRESHOLD=1073741824

# TCMALLOC_SKIP_MMAP  (default: false)
#   When 1, tcmalloc never calls mmap(2) and uses sbrk(2) only.
# export TCMALLOC_SKIP_MMAP=0

# TCMALLOC_SAMPLE_PARAMETER  (default: 0 = sampling disabled)
#   Average byte interval between heap profile samples.  Leave at 0 in
#   throughput benchmarks; a value of 524288 (512 KiB) is reasonable for
#   profiling.
# export TCMALLOC_SAMPLE_PARAMETER=0

# ---------------------------------------------------------------------------
# jemalloc tunables  (all set via the MALLOC_CONF environment variable)
#
# Format: MALLOC_CONF="key:value,key:value,..."
# ---------------------------------------------------------------------------

# narenas  (default: 4 x CPU count)
#   Maximum number of arenas for automatic thread-arena multiplexing.  More
#   arenas improve multi-thread scalability by reducing lock contention;
#   fewer arenas reduce per-arena metadata overhead and cross-arena
#   fragmentation.  Set to thread count for maximum parallel throughput.
#
# background_thread  (default: false)
#   Enables internal background worker threads for asynchronous decay-based
#   purging.  Offloads purge latency from application threads.
#
# dirty_decay_ms  (default: 10000 = 10 s)
#   Milliseconds before unused dirty pages are purged via madvise.  0 =
#   purge immediately; -1 = never purge.  Raise or set -1 for maximum
#   throughput; lower to track RSS more closely.
#
# muzzy_decay_ms  (default: 10000 = 10 s)
#   Milliseconds before muzzy pages (MADV_FREE'd) are forcibly reclaimed via
#   MADV_DONTNEED.  0 = reclaim immediately; -1 = never reclaim.
#
# tcache  (default: true)
#   Enables per-thread caches for small and medium allocations, avoiding all
#   synchronisation on the fast path.  Disable only for no-cache baselines.
#
# tcache_max  (default: 32768 = 32 KiB)
#   Maximum size class cached per-thread.  Raise to cache larger objects and
#   improve throughput for medium allocations; lower to reduce per-thread
#   memory overhead.
#
# lg_extent_max_active_fit  (default: 6 = 64x ratio)
#   Log2 of the maximum ratio between a reused extent's size and the
#   requested allocation size.  Lower (e.g. 3-4) to reduce fragmentation.
#
# percpu_arena  (default: disabled; options: disabled|percpu|phycpu)
#   Binds threads to arenas by CPU.  "percpu" (one arena per logical CPU)
#   often gives the best throughput in NUMA-aware or CPU-pinned workloads.
#
# thp  (default: default; options: default|always|never)
#   Transparent huge page hint for user-facing memory.  "always" improves
#   TLB efficiency for large working sets at the cost of higher RSS.
#
# metadata_thp  (default: disabled; options: disabled|auto|always)
#   THP hint for jemalloc's own internal metadata.  "auto" enables THP for
#   metadata once it grows large.
#
# retain  (default: true on 64-bit Linux)
#   When true, jemalloc retains virtual memory for faster future reuse
#   instead of munmap(2)'ing it.  Set false to measure RSS more accurately.
#
export MALLOC_CONF="narenas:${NUM_VCORES},background_thread:true,dirty_decay_ms:10000,muzzy_decay_ms:10000,tcache:true,lg_extent_max_active_fit:6,percpu_arena:percpu,thp:default,metadata_thp:disabled,retain:true"

# ---------------------------------------------------------------------------
# 0. Resolve repository root and script-relative paths
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMMON_DIR="${REPO_ROOT}/common"

# ---------------------------------------------------------------------------
# 1. Defaults
# ---------------------------------------------------------------------------

BINARY="${SCRIPT_DIR}/membench"
THREADS=4
DURATION=60
WORKLOAD="frag"
OBJ_SIZE_MIN=""
OBJ_SIZE_MAX=""
OBJ_RETENTION=""
MAX_RSS_TARGET=""

# Each entry is  "display_name:/path/to/lib.so"
# Leave the path component empty for the system default (ptmalloc2).
ALLOCATORS=(
    "ptmalloc2:"
    "tcmalloc:/usr/lib64/libtcmalloc.so.4"
    "jemalloc:/usr/lib64/libjemalloc.so.2"
)

# ---------------------------------------------------------------------------
# 2. Parse arguments
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -t, --threads     <n>        number of worker threads          (default ${THREADS})
  --duration        <s>        total run time per benchmark (s)  (default ${DURATION})
  --max_rss_target  <MiB>      stop once RSS reaches this limit   (default auto: 40% of system memory)
  --workload        frag|mixed workload to pass to membench       (default ${WORKLOAD})
  --obj_size_min    <bytes>    min object size; mixed only        (default 64)
  --obj_size_max    <bytes>    max object size; mixed only        (default 65536)
  --obj_retention   <0-100>    retention probability %; mixed only(default 50)
  -h, --help                   show this help and exit
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--threads)
            THREADS="$2"; shift 2 ;;
        --duration)
            DURATION="$2"; shift 2 ;;
        --max_rss_target|--maxRSSTarget)
            MAX_RSS_TARGET="$2"; shift 2 ;;
        --workload)
            WORKLOAD="$2"; shift 2 ;;
        --obj_size_min)
            OBJ_SIZE_MIN="$2"; shift 2 ;;
        --obj_size_max)
            OBJ_SIZE_MAX="$2"; shift 2 ;;
        --obj_retention)
            OBJ_RETENTION="$2"; shift 2 ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            echo "[ERROR] Unknown argument: $1" >&2
            echo "Run with --help for usage." >&2
            exit 1 ;;
    esac
done

# Validate
if ! [[ "$THREADS"  =~ ^[0-9]+$ ]] || [[ "$THREADS"  -lt 1 ]]; then
    echo "[ERROR] --threads must be a positive integer." >&2; exit 1
fi
if ! [[ "$DURATION" =~ ^[0-9]+$ ]] || [[ "$DURATION" -lt 1 ]]; then
    echo "[ERROR] --duration must be a positive integer." >&2; exit 1
fi
if [[ -n "$MAX_RSS_TARGET" ]] && { ! [[ "$MAX_RSS_TARGET" =~ ^[0-9]+([.][0-9]+)?$ ]] || ! awk -v v="$MAX_RSS_TARGET" 'BEGIN { exit !(v > 0) }'; }; then
    echo "[ERROR] --max_rss_target must be a positive number of MiB." >&2; exit 1
fi
if [[ "$WORKLOAD" != "frag" && "$WORKLOAD" != "mixed" ]]; then
    echo "[ERROR] --workload must be 'frag' or 'mixed'." >&2; exit 1
fi

# Build the membench flags that will be forwarded on every invocation
BENCH_FLAGS=("--duration" "$DURATION" "--workload" "$WORKLOAD" "-t" "$THREADS")
[[ -n "$MAX_RSS_TARGET" ]] && BENCH_FLAGS=("--duration" "$DURATION" "--max_rss_target" "$MAX_RSS_TARGET" "--workload" "$WORKLOAD" "-t" "$THREADS")
[[ -n "$OBJ_SIZE_MIN"  ]] && BENCH_FLAGS+=("--obj_size_min"  "$OBJ_SIZE_MIN")
[[ -n "$OBJ_SIZE_MAX"  ]] && BENCH_FLAGS+=("--obj_size_max"  "$OBJ_SIZE_MAX")
[[ -n "$OBJ_RETENTION" ]] && BENCH_FLAGS+=("--obj_retention" "$OBJ_RETENTION")

extract_run_medians() {
    local raw_out="$1"

    awk '
    function sort_numeric(arr, n,    i, j, tmp) {
        for (i = 1; i <= n; i++) {
            for (j = i + 1; j <= n; j++) {
                if (arr[i] > arr[j]) {
                    tmp = arr[i]
                    arr[i] = arr[j]
                    arr[j] = tmp
                }
            }
        }
    }

    function median(arr, n,    mid) {
        sort_numeric(arr, n)
        if (n % 2 == 1) return sprintf("%.2f", arr[(n + 1) / 2])
        mid = n / 2
        return sprintf("%.2f", (arr[mid] + arr[mid + 1]) / 2.0)
    }

    /^[0-9]/ {
        row_count++
        rate_all[row_count] = $7 + 0
        frag = $10
        gsub(/%/, "", frag)
        frag_all[row_count] = frag + 0
    }

    END {
        start = 4
        kept = 0

        for (i = start; i <= row_count; i++) {
            kept++
            rates[kept] = rate_all[i]
            frags[kept] = frag_all[i]
        }

        if (kept == 0) exit 1

        printf "%s %s\n", median(rates, kept), median(frags, kept)
    }' "$raw_out"
}

# ---------------------------------------------------------------------------
# 3. Output directories (relative to the caller's working directory)
# ---------------------------------------------------------------------------

TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
OUT_DIR="$(pwd)/out"
PERF_DIR="$(pwd)/perf"

mkdir -p "$OUT_DIR" "$PERF_DIR"

# Main log file – tee will duplicate every line here AND to stdout/stderr
LOG_FILE="${OUT_DIR}/benchmark_${TIMESTAMP}.log"

# ---------------------------------------------------------------------------
# 4. Tee: redirect all subsequent output through tee so it goes to both the
#    console and the log file.
# ---------------------------------------------------------------------------

exec > >(tee -a "$LOG_FILE") 2>&1

# ---------------------------------------------------------------------------
# 5. Source the hardware-info helper and print system context
# ---------------------------------------------------------------------------

set +e
if [[ -f "${COMMON_DIR}/linux_hw_info.sh" ]]; then
    # shellcheck source=../common/linux_hw_info.sh
    source "${COMMON_DIR}/linux_hw_info.sh"
    print_linux_hw_info
else
    echo "[WARNING] ${COMMON_DIR}/linux_hw_info.sh not found – skipping HW info."
fi
set -e

# ---------------------------------------------------------------------------
# 6. Software versions
# ---------------------------------------------------------------------------

set +e
if [[ -f "${COMMON_DIR}/sw_versions.sh" ]]; then
    # shellcheck source=../common/sw_versions.sh
    source "${COMMON_DIR}/sw_versions.sh"
    get_allocator_versions
    echo "[$(date '+%H:%M:%S')] === Allocator Software Versions ==="
    echo "  ptmalloc2  (glibc)          : ${PTMALLOC2_VERSION}"
    echo "  jemalloc                    : ${JEMALLOC_VERSION}"
    echo "  tcmalloc   (gperftools-libs): ${TCMALLOC_VERSION}"
    echo ""
else
    echo "[WARNING] ${COMMON_DIR}/sw_versions.sh not found – skipping version info."
fi
set -e

# ---------------------------------------------------------------------------
# 7. Compile – renumbered; was 6 before sw_versions section was added
# ---------------------------------------------------------------------------

echo "[$(date '+%H:%M:%S')] Compiling ${BINARY} with -O3 ..."
gcc -O3 -pthread "${SCRIPT_DIR}/mem_bench.c" -o "$BINARY"
echo "[$(date '+%H:%M:%S')] Compilation successful."

# ---------------------------------------------------------------------------
# 8. Pre-flight: verify all required allocator .so files exist
# ---------------------------------------------------------------------------

echo ""
echo "[$(date '+%H:%M:%S')] === Pre-flight: Checking allocator availability ==="

MISSING_ALLOCS=()
for alloc_entry in "${ALLOCATORS[@]}"; do
    IFS=":" read -r name path <<< "$alloc_entry"
    if [[ -z "$path" ]]; then
        echo "  [OK]      ${name}  (system default – no .so required)"
    elif [[ -f "$path" ]]; then
        echo "  [OK]      ${name}  →  ${path}"
    else
        echo "  [MISSING] ${name}  →  ${path}  (will be SKIPPED)"
        MISSING_ALLOCS+=("$name")
    fi
done

if [[ ${#MISSING_ALLOCS[@]} -gt 0 ]]; then
    echo ""
    echo "[WARNING] The following allocators are not installed and will be skipped:"
    for m in "${MISSING_ALLOCS[@]}"; do
        echo "          - $m"
    done
fi
echo ""

# ---------------------------------------------------------------------------
# 9. Benchmark configuration summary
# ---------------------------------------------------------------------------

echo "[$(date '+%H:%M:%S')] === Benchmark Configuration ==="
echo "  Binary        : ${BINARY}"
echo "  Duration      : ${DURATION}s per run"
echo "  maxRSSTarget  : ${MAX_RSS_TARGET:-auto (40% of system memory, resolved by membench)}"
echo "  Threads       : ${THREADS}"
echo "  Workload      : ${WORKLOAD}"
if [[ "$WORKLOAD" == "mixed" ]]; then
    echo "  Obj size min  : ${OBJ_SIZE_MIN:-64 (default)}"
    echo "  Obj size max  : ${OBJ_SIZE_MAX:-65536 (default)}"
    echo "  Obj retention : ${OBJ_RETENTION:-50 (default)}%"
fi
echo "  Output dir    : ${OUT_DIR}"
echo "  Perf dir      : ${PERF_DIR}"
echo "  Log file      : ${LOG_FILE}"
echo "  membench flags: ${BENCH_FLAGS[*]}"
echo "  Summary stats : median of report rows after skipping first 3 iterations"
echo ""

# ---------------------------------------------------------------------------
# 10. Run benchmarks
# ---------------------------------------------------------------------------

echo "[$(date '+%H:%M:%S')] Starting Benchmark Suite ..."
echo "================================================================================"
printf "%-14s %-12s %-16s %-10s\n" "Allocator" "Threads" "Rate (MiB/s)" "Frag %"
echo "================================================================================"

# Arrays to accumulate results for the post-run comparison summary.
RESULT_NAMES=()
RESULT_RATES=()
RESULT_FRAGS=()

for alloc_entry in "${ALLOCATORS[@]}"; do
    IFS=":" read -r name so_path <<< "$alloc_entry"

    # ---- Check .so presence (skip missing ones) ----
    PRELOAD_ENV=()
    if [[ -n "$so_path" ]]; then
        if [[ ! -f "$so_path" ]]; then
            echo "[$(date '+%H:%M:%S')] [SKIP] ${name}: library not found at ${so_path}"
            continue
        fi
        PRELOAD_ENV=("env" "LD_PRELOAD=${so_path}")
    fi

    echo ""
    echo "[$(date '+%H:%M:%S')] ---- Starting run: allocator=${name}  threads=${THREADS} ----"
    echo "  Allocator    : ${name}"
    echo "  Threads      : ${THREADS}"
    echo "  LD_PRELOAD   : ${so_path:-<none> (ptmalloc2)}"
    echo "  Duration     : ${DURATION}s"
    echo "  Binary       : ${BINARY}"

    # Apply THP settings optimised for tcmalloc before this run begins.
    # thp_restore is called after the run (and also on any early exit via the
    # EXIT trap registered at the top of the script).
    if [[ "$name" == "tcmalloc" ]]; then
        thp_set
    fi

    # Paths for this run
    RAW_OUT="${OUT_DIR}/${name}_${THREADS}t_${TIMESTAMP}.txt"
    RUN_PERF_DIR="${PERF_DIR}/${name}_${THREADS}t"
    PERF_DATA="${RUN_PERF_DIR}/perf.data"
    PERF_SCRIPT_OUT="${RUN_PERF_DIR}/perf_script.txt"

    mkdir -p "$RUN_PERF_DIR"

    echo "  Raw output   : ${RAW_OUT}"
    echo "  Perf data    : ${PERF_DATA}"
    echo "  Perf script  : ${PERF_SCRIPT_OUT}"
    echo "  [$(date '+%H:%M:%S')] Executing perf record ..."

    # Execute: optional LD_PRELOAD env + perf record + binary + forwarded flags
    "${PRELOAD_ENV[@]}" \
        perf record -F 99 -g -o "${PERF_DATA}" -- \
        "${BINARY}" "${BENCH_FLAGS[@]}" \
        > >(tee "$RAW_OUT") 2>&1 || {
        echo "  [WARNING] perf record exited non-zero for ${name}/${THREADS}t – continuing."
    }

    echo "  [$(date '+%H:%M:%S')] perf record complete."

    # Convert perf data to annotated script file
    echo "  [$(date '+%H:%M:%S')] Running perf script ..."
    perf script -i "${PERF_DATA}" -F +pid > "${PERF_SCRIPT_OUT}" 2>&1 || {
        echo "  [WARNING] perf script failed for ${name}/${THREADS}t."
    }
    chmod 755 "${PERF_SCRIPT_OUT}"
    echo "  [$(date '+%H:%M:%S')] perf script saved → ${PERF_SCRIPT_OUT}"

    # Restore THP settings to their original values now that the tcmalloc run
    # is finished.  For all other allocators this is a no-op.
    if [[ "$name" == "tcmalloc" ]]; then
        thp_restore
    fi

    # Parse summary metrics from the AGGREGATED BENCHMARK REPORT.
    # The report columns (11 total):
    #   $1  Time(s)
    #   $2  VSS Alloc(MiB)
    #   $3  VSS Freed(MiB)
    #   $4  RSS Alloc(MiB)
    #   $5  RSS Freed(MiB)
    #   $6  RSS Expected(MiB)
    #   $7  Rate(MiB/s)        ← allocation throughput
    #   $8  RSS Actual(MiB)
    #   $9  RSS Bloat(MiB)
    #   $10 Frag %             ← printed as "N.NN%" (no space before %)
    #   $11 Iterations
    if MEDIAN_METRICS="$(extract_run_medians "$RAW_OUT")"; then
        read -r RATE FRAG <<< "$MEDIAN_METRICS"
    else
        echo "  [WARNING] Could not extract median summary metrics for ${name}/${THREADS}t."
        RATE="NA"
        FRAG="NA"
    fi

    printf "%-14s %-12s %-16s %-10s\n" "$name" "$THREADS" "$RATE" "$FRAG"

    echo "  [$(date '+%H:%M:%S')] ---- Run complete: ${name}/${THREADS}t  rate=${RATE} MiB/s  frag=${FRAG}% ----"

    # Accumulate for the final comparison summary.
    RESULT_NAMES+=("$name")
    RESULT_RATES+=("$RATE")
    RESULT_FRAGS+=("$FRAG")
done

echo ""
echo "================================================================================"
echo "[$(date '+%H:%M:%S')] Benchmark suite complete."
echo "  Raw outputs  : ${OUT_DIR}/"
echo "  Perf data    : ${PERF_DIR}/"
echo "  Full log     : ${LOG_FILE}"

# ---------------------------------------------------------------------------
# 11. Post-run comparison summary
# ---------------------------------------------------------------------------

if [[ ${#RESULT_NAMES[@]} -eq 0 ]]; then
    echo ""
    echo "[WARNING] No allocator runs completed – skipping comparison summary."
else
    echo ""
    echo "================================================================================"
    echo "[$(date '+%H:%M:%S')] === Allocator Comparison Summary (median after warm-up) ==="
    echo "================================================================================"
    printf "%-14s %-20s %-14s\n" "Allocator" "Alloc Rate (MiB/s)" "Frag %"
    echo "--------------------------------------------------------------------------------"
    for i in "${!RESULT_NAMES[@]}"; do
        printf "%-14s %-20s %-14s\n" \
            "${RESULT_NAMES[$i]}" "${RESULT_RATES[$i]}" "${RESULT_FRAGS[$i]}"
    done
    echo "--------------------------------------------------------------------------------"

    # Find the winner for each metric using awk for floating-point comparison.
    BEST_RATE_NAME=$(
        awk -v n="${#RESULT_NAMES[@]}" \
            -v names="$(IFS='|'; echo "${RESULT_NAMES[*]}")" \
            -v rates="$(IFS='|'; echo "${RESULT_RATES[*]}")" \
        'BEGIN {
            split(names, nArr, "|")
            split(rates, rArr, "|")
            best = -1; bestName = "N/A"
            for (i = 1; i <= n; i++) {
                v = rArr[i] + 0
                if (v > best) { best = v; bestName = nArr[i] }
            }
            print bestName
        }'
    )

    BEST_FRAG_NAME=$(
        awk -v n="${#RESULT_NAMES[@]}" \
            -v names="$(IFS='|'; echo "${RESULT_NAMES[*]}")" \
            -v frags="$(IFS='|'; echo "${RESULT_FRAGS[*]}")" \
        'BEGIN {
            split(names, nArr, "|")
            split(frags, fArr, "|")
            best = 1e18; bestName = "N/A"
            for (i = 1; i <= n; i++) {
                v = fArr[i] + 0
                if (v < best) { best = v; bestName = nArr[i] }
            }
            print bestName
        }'
    )

    echo ""
    echo "  Best allocation rate : ${BEST_RATE_NAME}"
    echo "  Best (lowest) frag % : ${BEST_FRAG_NAME}"
    echo "================================================================================"

    # -----------------------------------------------------------------------
    # Head-to-head confusion matrices — one per metric.
    #
    # Layout: rows = challenger, columns = baseline.
    # Read a cell as: "how does the ROW allocator compare to the COL allocator?"
    #
    # Cell formula:
    #   rate matrix:  (row_rate - col_rate) / |col_rate| * 100
    #   frag matrix:  (row_frag - col_frag) / |col_frag| * 100
    #                 falls back to absolute diff when col_frag == 0
    #
    # Sign convention:
    #   rate  +N% → row is N% faster   (better)
    #   rate  -N% → row is N% slower   (worse)
    #   frag  +N% → row has N% more fragmentation  (worse)
    #   frag  -N% → row has N% less fragmentation  (better)
    #
    # Cell width is derived at runtime from the widest value that will actually
    # appear, so columns stay aligned regardless of the magnitude of the numbers.
    # Diagonal cells show "--" (self-comparison is undefined).
    # -----------------------------------------------------------------------

    # ---- Matrix 1: Allocation Rate ----
    echo ""
    echo "[$(date '+%H:%M:%S')] === H2H Matrix 1/2: Allocation Rate  (row_rate / col_rate - 1) ==="
    echo "  +N% → row is faster  |  -N% → row is slower"
    echo ""

    awk -v n="${#RESULT_NAMES[@]}" \
        -v names="$(IFS='|'; echo "${RESULT_NAMES[*]}")" \
        -v vals="$(IFS='|'; echo "${RESULT_RATES[*]}")" \
    'BEGIN {
        split(names, N, "|")
        split(vals,  V, "|")

        # Pre-compute every cell string so we know the true max width.
        for (i = 1; i <= n; i++)
            for (j = 1; j <= n; j++) {
                if (i == j) {
                    cell[i,j] = "--"
                } else {
                    vi = V[i] + 0; vj = V[j] + 0
                    d  = (vj != 0) ? (vi - vj) / (vj < 0 ? -vj : vj) * 100 : 0
                    sg = (d >= 0) ? "+" : ""
                    cell[i,j] = sprintf("%s%.2f%%", sg, d)
                }
            }

        # Row-label width: longest name + 2, min 12
        lw = 12
        for (i = 1; i <= n; i++) { l = length(N[i]) + 2; if (l > lw) lw = l }

        # Cell width: widest cell string + 2 padding each side, and wide enough
        # for the column header; minimum 10
        cw = 10
        for (i = 1; i <= n; i++) {
            l = length(N[i]) + 4; if (l > cw) cw = l   # header fits
            for (j = 1; j <= n; j++) {
                l = length(cell[i,j]) + 4; if (l > cw) cw = l
            }
        }

        # Header
        printf "%-*s", lw, "ROW \\ COL"
        for (j = 1; j <= n; j++) {
            lpad = int((cw - length(N[j])) / 2)
            rpad = cw - length(N[j]) - lpad
            printf "%*s%s%*s", lpad, "", N[j], rpad, ""
        }
        printf "\n"

        sep = ""; for (k = 0; k < lw + cw * n; k++) sep = sep "-"; print sep

        for (i = 1; i <= n; i++) {
            printf "%-*s", lw, N[i]
            for (j = 1; j <= n; j++) {
                lpad = int((cw - length(cell[i,j])) / 2)
                rpad = cw - length(cell[i,j]) - lpad
                printf "%*s%s%*s", lpad, "", cell[i,j], rpad, ""
            }
            printf "\n"
        }
        print sep
    }'

    # ---- Matrix 2: Fragmentation % ----
    echo ""
    echo "[$(date '+%H:%M:%S')] === H2H Matrix 2/2: Fragmentation %%  (row_frag / col_frag - 1) ==="
    echo "  +N% → row has more fragmentation (worse)  |  -N% → row has less fragmentation (better)"
    echo ""

    awk -v n="${#RESULT_NAMES[@]}" \
        -v names="$(IFS='|'; echo "${RESULT_NAMES[*]}")" \
        -v vals="$(IFS='|'; echo "${RESULT_FRAGS[*]}")" \
    'BEGIN {
        split(names, N, "|")
        split(vals,  V, "|")

        for (i = 1; i <= n; i++)
            for (j = 1; j <= n; j++) {
                if (i == j) {
                    cell[i,j] = "--"
                } else {
                    vi = V[i] + 0; vj = V[j] + 0
                    if (vj != 0)
                        d = (vi - vj) / (vj < 0 ? -vj : vj) * 100
                    else
                        d = vi - vj   # absolute diff when baseline is zero
                    sg = (d >= 0) ? "+" : ""
                    cell[i,j] = sprintf("%s%.2f%%", sg, d)
                }
            }

        lw = 12
        for (i = 1; i <= n; i++) { l = length(N[i]) + 2; if (l > lw) lw = l }

        cw = 10
        for (i = 1; i <= n; i++) {
            l = length(N[i]) + 4; if (l > cw) cw = l
            for (j = 1; j <= n; j++) {
                l = length(cell[i,j]) + 4; if (l > cw) cw = l
            }
        }

        printf "%-*s", lw, "ROW \\ COL"
        for (j = 1; j <= n; j++) {
            lpad = int((cw - length(N[j])) / 2)
            rpad = cw - length(N[j]) - lpad
            printf "%*s%s%*s", lpad, "", N[j], rpad, ""
        }
        printf "\n"

        sep = ""; for (k = 0; k < lw + cw * n; k++) sep = sep "-"; print sep

        for (i = 1; i <= n; i++) {
            printf "%-*s", lw, N[i]
            for (j = 1; j <= n; j++) {
                lpad = int((cw - length(cell[i,j])) / 2)
                rpad = cw - length(cell[i,j]) - lpad
                printf "%*s%s%*s", lpad, "", cell[i,j], rpad, ""
            }
            printf "\n"
        }
        print sep
    }'

    echo "================================================================================"
fi
