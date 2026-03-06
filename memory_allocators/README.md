# memory_allocators

Benchmarks **ptmalloc2**, **tcmalloc**, and **jemalloc** under high concurrency and an
allocation-heavy workload designed to stress fragmentation behaviour.

---

## Objective

Measure and compare the performance of general-purpose memory allocators when subjected
to **high-concurrency, allocation-heavy workloads with bimodal allocation patterns** —
conditions that are representative of real server workloads and that are known to induce
heap fragmentation.

Specifically, the benchmark answers:

- Which allocator sustains the highest **allocation throughput** (MiB/s) as thread count
  scales from 4 to 12?
- Which allocator exhibits the least **heap fragmentation** under a mixed retained /
  short-lived allocation pattern?
- How does each allocator's throughput and fragmentation profile change as concurrency
  increases?

### Why bimodal allocation patterns?

The workload combines two allocation classes that appear together in many real
applications (web servers, databases, runtimes):

| Class | Size | Lifetime | Models |
|---|---|---|---|
| Small, retained | 256 B | Lives for the duration of the benchmark | Active working-set objects: cache entries, session state, live data structures |
| Large, transient | 16 KiB | Allocated and immediately freed | Request buffers, temporary serialisation scratch space, I/O staging areas |

This mixture stresses the allocator in two distinct ways simultaneously:

1. **Contention** — many threads compete for the heap at high frequency.
2. **Fragmentation** — the interleaving of long-lived small objects with short-lived
   large objects tends to leave holes in the heap that a poor allocator cannot reclaim,
   driving RSS above the true live-set size.

---

## Allocators

| Allocator | Version source | Injection method |
|---|---|---|
| **ptmalloc2** | glibc (system default) | None — the default allocator; no `LD_PRELOAD` |
| **tcmalloc** | Google gperftools | `LD_PRELOAD=/usr/lib64/libtcmalloc.so.4` |
| **jemalloc** | Meta jemalloc | `LD_PRELOAD=/usr/lib64/libjemalloc.so.2` |

All three allocators are exercised against the **same binary** (`membench`). The
allocator is selected purely at runtime via `LD_PRELOAD`, so no recompilation is needed
between runs.

---

## Files

| File | Purpose |
|---|---|
| `mem_bench.c` | Multi-threaded C workload; reports throughput and fragmentation per interval |
| `setup.sh` | Detects the OS and installs all required dependencies |
| `run.sh` | Compiles `mem_bench.c` and drives the full allocator × thread-count matrix |

---

## Workload details (`mem_bench.c`)

### Parameters

| Parameter | Default | How to override |
|---|---|---|
| Benchmark duration | 60 s | First CLI argument: `./membench <seconds>` |
| Thread count | 1 | Environment variable: `NUM_THREADS=<n>` |
| Reporting interval | 5 s | Hardcoded |

### Per-thread loop

```
loop until duration elapsed:
    malloc(256 B)          # retained — never freed; grows the live working set
    malloc(16 KiB)
    free(16 KiB ptr)       # immediately released; leaves potential holes in the heap
```

### Metrics reported

Every 5 seconds, the benchmark samples `/proc/self/statm` for RSS and aggregates
across all threads:

| Column | Formula | What it captures |
|---|---|---|
| `Time(s)` | `interval * interval_index` | Elapsed wall-clock time |
| `Used(MiB)` | `(cumulative allocated − cumulative freed) / 1 MiB` | True live heap size |
| `Rate(MiB/s)` | `bytes allocated this interval / MiB / interval seconds` | Allocation throughput |
| `RSS(MiB)` | From `/proc/self/statm` × page size | Physical memory held by the process |
| `Bloat(MiB)` | `RSS − Used` | Memory the OS holds beyond the live set |
| `Frag %` | `Bloat / RSS × 100` | Fragmentation proxy — lower is better |

`run.sh` reads the **final-interval row** of each run to produce the summary table.

---

## Quick start

```bash
# 1. Install dependencies (once per machine)
bash memory_allocators/setup.sh

# Dry-run: see which installer would be invoked without making changes
bash memory_allocators/setup.sh --dry-run

# 2. Run the full benchmark matrix
bash memory_allocators/run.sh
```

The benchmark runs 9 combinations (3 allocators × 3 thread counts) and prints a
summary table similar to:

```
Allocator   | Threads | Rate (MiB/s) | Frag %
------------|---------|--------------|-------
ptmalloc2   |       4 |       1024.3 |  18.2
ptmalloc2   |       8 |       1891.7 |  22.4
ptmalloc2   |      12 |       2103.5 |  27.1
tcmalloc    |       4 |       1487.2 |   6.3
...
```

---

## Interpreting results

- **Rate (MiB/s):** Higher is better. Large gaps between allocators at high thread
  counts reveal contention in the allocator's internal arena or lock design.
- **Frag %:** Lower is better. A rising fragmentation percentage as threads increase
  indicates that the allocator's size-class or bin design struggles to recombine freed
  large blocks when many threads are simultaneously dirtying the heap with small
  retained objects.
- **Cross-allocator comparison:** ptmalloc2 is the baseline. tcmalloc and jemalloc use
  per-thread or per-CPU caches to reduce lock contention; their advantage typically
  grows with thread count.
