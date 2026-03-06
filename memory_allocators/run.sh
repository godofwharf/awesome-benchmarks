#!/usr/bin/env bash
# run.sh – Memory allocator benchmark runner
#
# What this script does:
#   1. Resolves paths relative to the repository root so it can be invoked
#      from any working directory.
#   2. Sources common/linux_hw_info.sh and prints full system/HW details.
#   3. Validates that every non-default allocator's .so file is present before
#      starting any benchmark run.
#   4. Runs membench under `perf record` for each (allocator, thread-count)
#      combination, with verbose progress logging.
#   5. Saves perf record data and perf script output to   perf/<name>_<t>t/
#   6. Saves the full benchmark stdout (raw membench output) to             out/
#   7. Tees all script output (the summary table + log lines) to both the
#      console and out/benchmark_<timestamp>.log

set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Resolve repository root and script-relative paths
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMMON_DIR="${REPO_ROOT}/common"

# ---------------------------------------------------------------------------
# 1. Configuration
# ---------------------------------------------------------------------------

BINARY="${SCRIPT_DIR}/membench"
DURATION=30
THREADS=(4 8 12)

# Each entry is  "display_name:/path/to/lib.so"
# Leave the path component empty for the system default (ptmalloc2).
ALLOCATORS=(
    "ptmalloc2:"
    "tcmalloc:/usr/lib64/libtcmalloc.so.4"
    "jemalloc:/usr/lib64/libjemalloc.so.2"
)

# ---------------------------------------------------------------------------
# 2. Output directories (relative to the caller's working directory)
# ---------------------------------------------------------------------------

TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
OUT_DIR="$(pwd)/out"
PERF_DIR="$(pwd)/perf"

mkdir -p "$OUT_DIR" "$PERF_DIR"

# Main log file – tee will duplicate every line here AND to stdout/stderr
LOG_FILE="${OUT_DIR}/benchmark_${TIMESTAMP}.log"

# ---------------------------------------------------------------------------
# 3. Tee: redirect all subsequent output through tee so it goes to both the
#    console and the log file.  We reopen stdout on fd 3, then replace stdout
#    with a tee subprocess that writes to the log file.
# ---------------------------------------------------------------------------

exec > >(tee -a "$LOG_FILE") 2>&1

# ---------------------------------------------------------------------------
# 4. Source the hardware-info helper and print system context
# ---------------------------------------------------------------------------

if [[ -f "${COMMON_DIR}/linux_hw_info.sh" ]]; then
    # shellcheck source=../common/linux_hw_info.sh
    source "${COMMON_DIR}/linux_hw_info.sh"
    print_linux_hw_info
else
    echo "[WARNING] ${COMMON_DIR}/linux_hw_info.sh not found – skipping HW info."
fi

# ---------------------------------------------------------------------------
# 5. Compile
# ---------------------------------------------------------------------------

echo "[$(date '+%H:%M:%S')] Compiling ${BINARY} with -O3 ..."
gcc -O3 -pthread "${SCRIPT_DIR}/membench.c" -o "$BINARY"
echo "[$(date '+%H:%M:%S')] Compilation successful."

# ---------------------------------------------------------------------------
# 6. Pre-flight: verify all required allocator .so files exist
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
# 7. Benchmark configuration summary
# ---------------------------------------------------------------------------

echo "[$(date '+%H:%M:%S')] === Benchmark Configuration ==="
echo "  Binary        : ${BINARY}"
echo "  Duration      : ${DURATION} seconds per run"
echo "  Thread counts : ${THREADS[*]}"
echo "  Allocators    : $(IFS=','; echo "${ALLOCATORS[*]//:/  (}" | sed 's/  (/(/g')"
echo "  Output dir    : ${OUT_DIR}"
echo "  Perf dir      : ${PERF_DIR}"
echo "  Log file      : ${LOG_FILE}"
echo ""

# ---------------------------------------------------------------------------
# 8. Run benchmarks
# ---------------------------------------------------------------------------

echo "[$(date '+%H:%M:%S')] Starting Benchmark Suite ..."
echo "================================================================================"
printf "%-14s %-10s %-16s %-10s\n" "Allocator" "Threads" "Rate (MiB/s)" "Frag %"
echo "================================================================================"

for alloc_entry in "${ALLOCATORS[@]}"; do
    IFS=":" read -r name so_path <<< "$alloc_entry"

    # ---- Check .so presence (again – skip missing ones) ----
    PRELOAD_CMD=""
    if [[ -n "$so_path" ]]; then
        if [[ ! -f "$so_path" ]]; then
            echo "[$(date '+%H:%M:%S')] [SKIP] ${name}: library not found at ${so_path}"
            continue
        fi
        PRELOAD_CMD="LD_PRELOAD=${so_path}"
    fi

    for t in "${THREADS[@]}"; do
        echo ""
        echo "[$(date '+%H:%M:%S')] ---- Starting run: allocator=${name}  threads=${t} ----"
        echo "  Allocator    : ${name}"
        echo "  Threads      : ${t}"
        echo "  LD_PRELOAD   : ${so_path:-<none> (ptmalloc2)}"
        echo "  Duration     : ${DURATION}s"
        echo "  Binary       : ${BINARY}"

        # Paths for this run
        RAW_OUT="${OUT_DIR}/${name}_${t}t_${TIMESTAMP}.txt"
        RUN_PERF_DIR="${PERF_DIR}/${name}_${t}t"
        PERF_DATA="${RUN_PERF_DIR}/perf.data"
        PERF_SCRIPT_OUT="${RUN_PERF_DIR}/perf_script.txt"

        mkdir -p "$RUN_PERF_DIR"

        echo "  Raw output   : ${RAW_OUT}"
        echo "  Perf data    : ${PERF_DATA}"
        echo "  Perf script  : ${PERF_SCRIPT_OUT}"
        echo "  [$(date '+%H:%M:%S')] Executing perf record ..."

        # Execute: env vars + perf record + binary
        # stdout → raw output file (tee-d to console as well for visibility)
        eval "NUM_THREADS=${t} ${PRELOAD_CMD} \
            perf record -F 99 -g -o '${PERF_DATA}' -- \
            '${BINARY}' ${DURATION}" \
            > >(tee "$RAW_OUT") 2>&1 || {
            echo "  [WARNING] perf record exited non-zero for ${name}/${t}t – continuing."
        }

        echo "  [$(date '+%H:%M:%S')] perf record complete."

        # Convert perf data to annotated script file
        echo "  [$(date '+%H:%M:%S')] Running perf script ..."
        perf script -i "${PERF_DATA}" -F +pid > "${PERF_SCRIPT_OUT}" 2>&1 || {
            echo "  [WARNING] perf script failed for ${name}/${t}t."
        }
        chmod 755 "${PERF_SCRIPT_OUT}"
        echo "  [$(date '+%H:%M:%S')] perf script saved → ${PERF_SCRIPT_OUT}"

        # Parse summary line from membench output
        # The last line contains: Time  Used  Rate  RSS  Bloat  Frag%
        LAST_LINE=$(tail -n 1 "$RAW_OUT")
        RATE=$(awk '{print $3}' <<< "$LAST_LINE")
        FRAG=$(awk '{print $6}' <<< "$LAST_LINE")

        printf "%-14s %-10s %-16s %-10s\n" "$name" "$t" "$RATE" "$FRAG"

        echo "  [$(date '+%H:%M:%S')] ---- Run complete: ${name}/${t}t  rate=${RATE} MiB/s  frag=${FRAG}% ----"
    done
done

echo ""
echo "================================================================================"
echo "[$(date '+%H:%M:%S')] Benchmark suite complete."
echo "  Raw outputs  : ${OUT_DIR}/"
echo "  Perf data    : ${PERF_DIR}/"
echo "  Full log     : ${LOG_FILE}"
