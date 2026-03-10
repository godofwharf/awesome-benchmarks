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
#   --workload         frag|mixed workload to pass to membench       (default frag)
#   --obj_size_min     <bytes>    min object size; mixed only        (default 64)
#   --obj_size_max     <bytes>    max object size; mixed only        (default 65536)
#   --obj_retention    <0-100>    retention probability %; mixed only(default 50)
#
# All flags except -t/--threads are forwarded verbatim to membench.

set -euo pipefail

# Setting top chunk padding for ptmalloc2 to reduce number of sbrk calls.
# Set it to 512m.
# This increases memory wastage but improves the performance of ptmalloc2 by atleast 30%-40%
export MALLOC_TOP_PAD_=536870912

# Set TCMALLOC_SKIP_SBRK to 1 to force tcmalloc to only use mmap
# export TCMALLOC_SKIP_SBRK=1

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
DURATION=30
WORKLOAD="frag"
OBJ_SIZE_MIN=""
OBJ_SIZE_MAX=""
OBJ_RETENTION=""

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
if [[ "$WORKLOAD" != "frag" && "$WORKLOAD" != "mixed" ]]; then
    echo "[ERROR] --workload must be 'frag' or 'mixed'." >&2; exit 1
fi

# Build the membench flags that will be forwarded on every invocation
BENCH_FLAGS=("--duration" "$DURATION" "--workload" "$WORKLOAD" "-t" "$THREADS")
[[ -n "$OBJ_SIZE_MIN"  ]] && BENCH_FLAGS+=("--obj_size_min"  "$OBJ_SIZE_MIN")
[[ -n "$OBJ_SIZE_MAX"  ]] && BENCH_FLAGS+=("--obj_size_max"  "$OBJ_SIZE_MAX")
[[ -n "$OBJ_RETENTION" ]] && BENCH_FLAGS+=("--obj_retention" "$OBJ_RETENTION")

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
echo ""

# ---------------------------------------------------------------------------
# 10. Run benchmarks
# ---------------------------------------------------------------------------

echo "[$(date '+%H:%M:%S')] Starting Benchmark Suite ..."
echo "================================================================================"
printf "%-14s %-12s %-16s %-10s\n" "Allocator" "Threads" "Rate (MiB/s)" "Frag %"
echo "================================================================================"

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

    # Parse summary line from membench output
    # Last data row columns: Time  Expected  Rate  RSS  Bloat  Frag%
    LAST_LINE=$(grep -E '^[0-9]' "$RAW_OUT" | tail -n 1)
    RATE=$(awk '{print $3}' <<< "$LAST_LINE")
    FRAG=$(awk '{print $6}' <<< "$LAST_LINE")

    printf "%-14s %-12s %-16s %-10s\n" "$name" "$THREADS" "$RATE" "$FRAG"

    echo "  [$(date '+%H:%M:%S')] ---- Run complete: ${name}/${THREADS}t  rate=${RATE} MiB/s  frag=${FRAG}% ----"
done

echo ""
echo "================================================================================"
echo "[$(date '+%H:%M:%S')] Benchmark suite complete."
echo "  Raw outputs  : ${OUT_DIR}/"
echo "  Perf data    : ${PERF_DIR}/"
echo "  Full log     : ${LOG_FILE}"
