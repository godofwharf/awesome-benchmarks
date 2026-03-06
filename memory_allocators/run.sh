#!/bin/bash

# Configuration
BINARY="./membench"
DURATION=30
THREADS=(4 8 12)
# Define allocators with their display name and their LD_PRELOAD path
# Leave the path empty for the default ptmalloc2
ALLOCATORS=("ptmalloc2:" "tcmalloc:/usr/lib64/libtcmalloc.so.4" "jemalloc:/usr/lib64/libjemalloc.so.2")

# 1. Compile the code with -O3
echo "Compiling $BINARY with -O3..."
gcc -O3 -pthread membench.c -o $BINARY

echo "Starting Benchmark Suite..."
echo "--------------------------------------------------------------------------------"
printf "%-12s %-10s %-15s %-10s\n" "Allocator" "Threads" "Rate (MiB/s)" "Frag %"
echo "--------------------------------------------------------------------------------"

for alloc_entry in "${ALLOCATORS[@]}"; do
    # Split the entry into name and path
    IFS=":" read -r name path <<< "$alloc_entry"

    for t in "${THREADS[@]}"; do
        # Construct the LD_PRELOAD string if a path exists
        PRELOAD_CMD=""
        if [ -n "$path" ]; then
            # Check if library exists before running
            if [ ! -f "$path" ]; then
                echo "Warning: $path not found, skipping $name"
                continue
            fi
            PRELOAD_CMD="LD_PRELOAD=$path"
        fi

        # 2. Run benchmark with perf record
        # We capture the output to a temp file to parse the last line
        RAW_OUT="raw_output_${name}_${t}t.txt"

        # Execute: env vars + perf + binary
        eval "NUM_THREADS=$t $PRELOAD_CMD perf record -F 99 -g -o perf.data -- $BINARY $DURATION > $RAW_OUT 2>&1"

        # 3. Convert perf data to script file and change permissions
        PERF_FILE="/tmp/${name}_${t}t.perf"
        perf script -i perf.data -F +pid > "$PERF_FILE"
        chmod 755 "$PERF_FILE"

        # 4. Capture the last line of the benchmark report
        # The last line contains: Time, Used, Rate, RSS, Bloat, Frag%
        LAST_LINE=$(tail -n 1 "$RAW_OUT")

        # Extract Rate (3rd column) and Frag% (6th column)
        # Note: awk indices depend on the formatting of your C program output
        RATE=$(echo "$LAST_LINE" | awk '{print $3}')
        FRAG=$(echo "$LAST_LINE" | awk '{print $6}')

        printf "%-12s %-10s %-15s %-10s\n" "$name" "$t" "$RATE" "$FRAG"

        # Cleanup temporary files
        rm -f perf.data "$RAW_OUT"
    done
done

echo "--------------------------------------------------------------------------------"
echo "Benchmark complete. .perf files are located in /tmp/"
