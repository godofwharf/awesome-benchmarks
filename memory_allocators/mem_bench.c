/*
 * mem_bench.c — Multi-threaded memory allocator benchmark
 *
 * Workloads
 * ---------
 *  frag  (fragmentation workload, default)
 *        Retains small (256 B) objects forever and immediately frees large
 *        (16 KiB) objects.  The interleaving of retained small blocks with
 *        transient large blocks induces heap fragmentation.
 *
 *  mixed (mixed object workload)
 *        Allocates objects whose size is drawn from a uniform distribution
 *        over [--obj_size_min, --obj_size_max].  Each allocation is
 *        independently retained or freed based on --obj_retention (0–100):
 *        a value of 100 retains every object; 0 frees every object
 *        immediately.
 *
 * RSS Accounting
 * --------------
 *  Both workloads write exactly min(obj_size, FRAG_TOUCH_SIZE) bytes into
 *  every allocation via memcpy before any free().  This memcpy — regardless
 *  of how many bytes it copies — causes the OS to fault in exactly one
 *  physical page per allocation.  The system page size is queried once at
 *  program start with sysconf(_SC_PAGESIZE) and stored in g_page_size.
 *
 *  rss_expected = (cumulative_alloc_pages - cumulative_freed_pages) * g_page_size
 *
 *  where:
 *    cumulative_alloc_pages  = number of malloc'd objects that were touched
 *                              (each contributes one page to RSS)
 *    cumulative_freed_pages  = number of those objects that were subsequently
 *                              freed (each frees one estimated page from RSS)
 *
 *  This gives a lower-bound on RSS: every touched page must be resident
 *  (assuming no swap).
 *
 *  rss_actual   = resident set size read from /proc/self/statm
 *  rss_bloat    = rss_actual - rss_expected  (must be >= 0)
 *  frag_pct     = rss_bloat / rss_actual * 100.0
 *
 *  If rss_actual < rss_expected the program aborts: this is a logic error
 *  (pages we wrote cannot be non-resident unless swapped out, which we treat
 *  as an invalid test environment).
 *
 * VSS Accounting
 * --------------
 *  VSS (virtual address space) columns reflect the sizes passed as arguments
 *  to malloc() and free() calls, i.e. the application-visible commitment
 *  before any allocator rounding or page granularity is applied.
 *
 *  vss_allocated = cumulative bytes requested via malloc() across all threads
 *  vss_freed     = cumulative bytes freed (original malloc size for each ptr)
 *
 *  These values are tracked in the per-thread tl_vss_allocated / tl_vss_freed
 *  accumulators and snapshotted into StatSnapshot::vss_allocated / vss_freed
 *  at each reporting interval.
 *
 *  Theoretical minimum RSS (frag workload):
 *    Each iteration retains one small object and frees one large object, so
 *    the net page count grows by exactly one page per iteration:
 *      theo_min_rss = total_iterations * g_page_size
 *
 * CLI reference
 * -------------
 *  ./membench [options]
 *
 *  -t, --threads  <n>     number of worker threads         (default 1)
 *  --duration   <s>       total run time in seconds        (default 60)
 *  --max_rss_target <MiB> stop once RSS reaches this limit (default 40% of system memory)
 *  --interval   <s>       reporting interval in seconds    (default 5)
 *  --workload   frag|mixed workload to run                 (default frag)
 *  --obj_size_min <bytes> minimum object size (mixed only) (default 64)
 *  --obj_size_max <bytes> maximum object size (mixed only) (default 65536)
 *  --obj_retention <0-100> retention probability % (mixed)(default 50)
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <pthread.h>
#include <unistd.h>
#include <string.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <time.h>
#include <errno.h>

/* ---- Fragmentation workload constants ---- */
#define FRAG_SMALL_SIZE   256
#define FRAG_LARGE_SIZE   (16 * 1024)
#define FRAG_TOUCH_SIZE   256   /* bytes written per allocation to fault one page */

/*
 * Fixed pattern copied into every allocation before use/free.
 * Using a compile-time constant avoids per-iteration heap allocation and
 * PRNG overhead while still producing a realistic, non-zero memory write.
 * 256 bytes = FRAG_SMALL_SIZE covers the entire small object and faults one
 * 4 KiB page of the large object — intentionally leaving the rest non-resident
 * to model real-world partial-use of large buffers.
 */
static const char g_fill_pattern[FRAG_TOUCH_SIZE] = {
    [0 ... (FRAG_TOUCH_SIZE - 1)] = 0xAB
};

/* ---- Workload IDs ---- */
typedef enum {
    WORKLOAD_FRAG  = 0,
    WORKLOAD_MIXED = 1
} WorkloadType;

/* ---- Structures ---- */

typedef struct StatSnapshot {
    int    interval_index;
    size_t rss_allocated;   /* cumulative page-size bytes counted for malloc'd+touched objects */
    size_t rss_freed;       /* cumulative page-size bytes subtracted when those objects are freed */
    size_t vss_allocated;   /* cumulative bytes passed as size argument to malloc() */
    size_t vss_freed;       /* cumulative bytes passed as size argument to free()'d objects */
    size_t iterations;      /* total loop iterations in this interval (across this thread) */
    struct StatSnapshot* next;
} StatSnapshot;

typedef struct ThreadData {
    int          thread_idx;
    size_t       iterations;      /* total loop iterations executed by this thread */
    StatSnapshot* snapshots_head;
    struct ThreadData* next;
} ThreadData;

/* One slot per interval, filled by the main monitor thread */
typedef struct {
    double actual_rss_mb;   /* RSS read from /proc/self/statm          */
} GlobalMonitor;

/* ---- Global config (set once before threads start) ---- */
static int          g_num_threads    = 1;
static int          g_duration       = 60;
static int          g_interval       = 5;
static WorkloadType g_workload       = WORKLOAD_FRAG;
static size_t       g_obj_size_min   = 64;
static size_t       g_obj_size_max   = 65536;
static int          g_obj_retention  = 50;   /* 0-100 % */
static double       g_max_rss_target_mb = 0.0;

/*
 * System page size, queried once at program start via sysconf(_SC_PAGESIZE).
 * Each memcpy of FRAG_TOUCH_SIZE bytes (256 B) into a freshly malloc'd object
 * causes the OS to fault in exactly one physical page.  We therefore use
 * g_page_size — not the number of bytes actually written — as the RSS
 * contribution per allocation, and as the estimated RSS freed per free() call.
 */
static size_t g_page_size = 4096;   /* overwritten in main() */

static double detect_default_max_rss_target_mb(void) {
    long phys_pages = sysconf(_SC_PHYS_PAGES);

    if (phys_pages <= 0 || g_page_size == 0) return 0.0;

    return ((double)phys_pages * (double)g_page_size * 0.40) / (1024.0 * 1024.0);
}

/* ---- Global state ---- */
static atomic_bool      keep_allocating   = true;
static ThreadData*      global_stats_head = NULL;
static pthread_mutex_t  stats_mutex       = PTHREAD_MUTEX_INITIALIZER;

/* ---- Thread-local accounting (no lock on hot path) ---- */
/*
 * tl_rss_allocated: cumulative pages faulted in by malloc+memcpy, expressed
 *                   in bytes (each allocation contributes g_page_size bytes).
 * tl_rss_freed:     estimated pages returned on free(), expressed in bytes
 *                   (each free() contributes g_page_size bytes).
 * Together they form the expected RSS lower-bound for this thread.
 *
 * tl_vss_allocated: cumulative bytes passed as the size argument to malloc().
 * tl_vss_freed:     cumulative bytes passed as the size argument to free()'d
 *                   objects (i.e. the original malloc size for each freed ptr).
 * These reflect the application-visible virtual address space commitment.
 */
static __thread size_t tl_rss_allocated = 0;
static __thread size_t tl_rss_freed     = 0;
static __thread size_t tl_vss_allocated = 0;
static __thread size_t tl_vss_freed     = 0;
static __thread size_t tl_iterations    = 0;

/* ---- PRNG (xorshift64, per-thread seeded from thread index) ---- */
static __thread uint64_t tl_rng_state = 0;

static inline uint64_t xorshift64(void) {
    tl_rng_state ^= tl_rng_state << 13;
    tl_rng_state ^= tl_rng_state >> 7;
    tl_rng_state ^= tl_rng_state << 17;
    return tl_rng_state;
}

/* Random integer in [lo, hi] inclusive */
static inline size_t rand_range_size(size_t lo, size_t hi) {
    if (lo >= hi) return lo;
    return lo + (size_t)(xorshift64() % (hi - lo + 1));
}

/* Random integer in [0, 99] */
static inline int rand_pct(void) {
    return (int)(xorshift64() % 100);
}

/* ---- Helpers ---- */

static void check_thp(void) {
    FILE* fp = fopen("/sys/kernel/mm/transparent_hugepage/enabled", "r");
    if (fp) {
        char buf[256];
        if (fgets(buf, sizeof(buf), fp)) printf("THP State: %s", buf);
        fclose(fp);
    }
}

/*
 * Returns current process RSS in KiB by reading /proc/self/statm.
 * Field layout: size  rss  shared  text  lib  data  dt
 * 'rss' is in pages; multiply by page size to get bytes.
 */
static long get_rss_kb(void) {
    long rss_pages = 0;
    FILE* fp = fopen("/proc/self/statm", "r");
    if (!fp) return 0;
    if (fscanf(fp, "%*s %ld", &rss_pages) != 1) { fclose(fp); return 0; }
    fclose(fp);
    return (rss_pages * sysconf(_SC_PAGESIZE)) / 1024;
}

/* ---- Per-thread snapshot helper ---- */

static void record_snapshot(StatSnapshot** head, StatSnapshot** tail,
                             int interval_idx) {
    StatSnapshot* snp = malloc(sizeof(StatSnapshot));
    if (!snp) return;
    snp->interval_index = interval_idx;
    snp->rss_allocated  = tl_rss_allocated;
    snp->rss_freed      = tl_rss_freed;
    snp->vss_allocated  = tl_vss_allocated;
    snp->vss_freed      = tl_vss_freed;
    snp->iterations     = tl_iterations;
    snp->next           = NULL;

    if (!*head) *head = snp;
    else        (*tail)->next = snp;
    *tail = snp;
}

static void commit_thread_data(int thread_idx, size_t iterations, StatSnapshot* head) {
    ThreadData* td = malloc(sizeof(ThreadData));
    if (!td) return;
    td->thread_idx      = thread_idx;
    td->iterations      = iterations;
    td->snapshots_head  = head;

    pthread_mutex_lock(&stats_mutex);
    td->next            = global_stats_head;
    global_stats_head   = td;
    pthread_mutex_unlock(&stats_mutex);
}

/* ================================================================
 * Workload A — Fragmentation workload
 *
 * Retain every small (256 B) allocation; immediately free every
 * large (16 KiB) allocation.  The interleaving of long-lived small
 * blocks with freed large blocks fragments the heap.
 *
 * Both objects receive a memcpy of FRAG_TOUCH_SIZE (256 B) before
 * any free().  This faults one 4 KiB page per allocation into
 * physical memory so that RSS reflects actual residency.  The
 * remaining pages of the large object are left non-resident,
 * modelling real-world partial use of large buffers.  A fixed fill
 * pattern is used (no PRNG, no heap allocation) to keep the write
 * overhead predictable and minimal relative to malloc/free cost.
 * ================================================================ */
static void* worker_frag(void* arg) {
    int thread_idx = *(int*)arg;
    free(arg);

    /* Seed per-thread PRNG (not needed for frag, but consistent) */
    tl_rng_state = (uint64_t)(uintptr_t)&thread_idx ^ (uint64_t)time(NULL)
                   ^ (uint64_t)thread_idx * 6364136223846793005ULL;

    StatSnapshot* local_head = NULL;
    StatSnapshot* local_tail = NULL;
    int   current_interval   = 0;
    time_t start_time        = time(NULL);

    while (atomic_load(&keep_allocating)) {
        tl_iterations++;

        /* Small — retained; write fill pattern to fault exactly one page into RSS */
        void* s = malloc(FRAG_SMALL_SIZE);
        if (s) {
            memcpy(s, g_fill_pattern, FRAG_TOUCH_SIZE);
            tl_rss_allocated += FRAG_TOUCH_SIZE;   /* one page faulted per allocation */
            tl_vss_allocated += FRAG_SMALL_SIZE;   /* bytes requested from allocator  */
        }

        /* Large — write fill pattern to fault one page, then free to induce fragmentation */
        void* l = malloc(FRAG_LARGE_SIZE);
        if (l) {
            memcpy(l, g_fill_pattern, FRAG_TOUCH_SIZE);
            tl_vss_allocated += FRAG_LARGE_SIZE;   /* bytes requested from allocator  */
            free(l);
            tl_vss_freed += FRAG_LARGE_SIZE;       /* bytes freed (large object)       */
        }

        time_t now = time(NULL);
        if (now - start_time >= (time_t)(current_interval + 1) * g_interval) {
            record_snapshot(&local_head, &local_tail, current_interval);
            current_interval++;
        }
    }

    commit_thread_data(thread_idx, tl_iterations, local_head);
    return NULL;
}

/* ================================================================
 * Workload B — Mixed object workload
 *
 * Object size drawn uniformly from [g_obj_size_min, g_obj_size_max].
 * Retention decision: keep with probability g_obj_retention / 100.
 *
 * Every allocation is touched with min(obj_sz, FRAG_TOUCH_SIZE) bytes
 * from g_fill_pattern before the retention decision.  This ensures the
 * OS faults the page into physical memory whether the object is kept or
 * freed immediately, matching the policy used by worker_frag.
 * ================================================================ */

static void* worker_mixed(void* arg) {
    int thread_idx = *(int*)arg;
    free(arg);

    /* Seed per-thread PRNG */
    tl_rng_state = (uint64_t)(uintptr_t)&thread_idx ^ (uint64_t)time(NULL)
                   ^ (uint64_t)thread_idx * 6364136223846793005ULL;

    StatSnapshot* local_head = NULL;
    StatSnapshot* local_tail = NULL;
    int   current_interval   = 0;
    time_t start_time        = time(NULL);

    while (atomic_load(&keep_allocating)) {
        tl_iterations++;

        /* Uniform random object size in [min, max] */
        size_t obj_sz = rand_range_size(g_obj_size_min, g_obj_size_max);

        void* p = malloc(obj_sz);
        if (!p) continue;

        /*
         * Touch the allocation before the retention decision so that the OS
         * faults the page(s) into physical memory regardless of whether the
         * object is kept or freed.  We copy min(obj_sz, FRAG_TOUCH_SIZE) bytes
         * from the fixed fill pattern: this covers the entire object when it is
         * smaller than FRAG_TOUCH_SIZE (≤ 256 B) and faults one 4 KiB page for
         * larger objects — the same bounded-write policy used by worker_frag.
         *
         * Regardless of how many bytes were written, the memcpy causes the OS
         * to fault in exactly one physical page per allocation.  We therefore
         * use g_page_size — not the number of bytes written — as the RSS
         * contribution for both alloc and free accounting.
         */
        size_t touch = obj_sz < FRAG_TOUCH_SIZE ? obj_sz : FRAG_TOUCH_SIZE;
        memcpy(p, g_fill_pattern, touch);
        tl_rss_allocated += touch;
        tl_vss_allocated += obj_sz;   /* bytes requested from allocator */

        /* Retention decision */
        if (rand_pct() >= g_obj_retention) {
            /* Discard immediately */
            free(p);
            tl_rss_freed += touch;   /* one page freed per free() call */
            tl_vss_freed += obj_sz;  /* bytes freed (original malloc size) */
        }

        time_t now = time(NULL);
        if (now - start_time >= (time_t)(current_interval + 1) * g_interval) {
            record_snapshot(&local_head, &local_tail, current_interval);
            current_interval++;
        }
    }

    commit_thread_data(thread_idx, tl_iterations, local_head);
    return NULL;
}

/* ================================================================
 * Reporting
 * ================================================================ */

static void generate_final_report(GlobalMonitor* history, int num_intervals) {
    if (num_intervals <= 0) {
        printf("\n=== AGGREGATED BENCHMARK REPORT ===\n");
        printf("No reporting intervals were captured.\n");
        return;
    }

    size_t* agg_rss_alloc  = calloc(num_intervals, sizeof(size_t));
    size_t* agg_rss_freed  = calloc(num_intervals, sizeof(size_t));
    size_t* agg_vss_alloc  = calloc(num_intervals, sizeof(size_t));
    size_t* agg_vss_freed  = calloc(num_intervals, sizeof(size_t));
    size_t* agg_iterations = calloc(num_intervals, sizeof(size_t));

    if (!agg_rss_alloc || !agg_rss_freed || !agg_vss_alloc ||
        !agg_vss_freed || !agg_iterations) {
        fprintf(stderr, "OOM in generate_final_report\n");
        free(agg_rss_alloc); free(agg_rss_freed);
        free(agg_vss_alloc); free(agg_vss_freed);
        free(agg_iterations);
        return;
    }

    /* Aggregate per-interval alloc/free across all threads */
    size_t total_iterations = 0;
    ThreadData* curr_thread = global_stats_head;
    while (curr_thread) {
        total_iterations += curr_thread->iterations;
        StatSnapshot* curr_snp = curr_thread->snapshots_head;
        while (curr_snp) {
            if (curr_snp->interval_index < num_intervals) {
                agg_rss_alloc [curr_snp->interval_index] += curr_snp->rss_allocated;
                agg_rss_freed [curr_snp->interval_index] += curr_snp->rss_freed;
                agg_vss_alloc [curr_snp->interval_index] += curr_snp->vss_allocated;
                agg_vss_freed [curr_snp->interval_index] += curr_snp->vss_freed;
                agg_iterations[curr_snp->interval_index] += curr_snp->iterations;
            }
            curr_snp = curr_snp->next;
        }
        curr_thread = curr_thread->next;
    }

    if (g_workload == WORKLOAD_FRAG) {
        /*
         * In the frag workload every small object is retained and every large
         * object is freed immediately.  Each allocation's memcpy of
         * FRAG_TOUCH_SIZE bytes faults exactly one physical page.  The large
         * objects contribute zero net pages (allocated then freed).  The
         * theoretical minimum RSS is therefore one page per small allocation,
         * i.e. one page per iteration.
         */
        double theo_mb = ((double)total_iterations * (double)FRAG_TOUCH_SIZE) / (1024.0 * 1024.0);
        printf("\nTheoretical minimum RSS (frag): iterations=%zu, page_size=%zu B/iter => %.2f MiB\n",
               total_iterations, g_page_size, theo_mb);
    }

    printf("\n=== AGGREGATED BENCHMARK REPORT ===\n");
    printf("%-8s %-16s %-16s %-16s %-16s %-14s %-12s %-14s %-14s %-10s %-12s\n",
           "Time(s)", "VSS Alloc(MiB)", "VSS Freed(MiB)",
           "RSS Alloc(MiB)", "RSS Freed(MiB)",
           "RSS Expected", "Rate(MiB/s)", "RSS Actual",
           "RSS Bloat(MiB)", "Frag %", "Iterations");

    size_t prev_rss_alloc = 0;
    for (int i = 0; i < num_intervals; i++) {
        /*
         * rss_expected = (pages allocated − pages freed) * g_page_size
         *
         * Each memcpy of FRAG_TOUCH_SIZE bytes into a freshly malloc'd object
         * causes the OS to fault in exactly one physical page, so we count
         * g_page_size bytes per allocation rather than the raw touch-byte count.
         * The same unit is subtracted when the corresponding object is freed.
         *
         * This is a lower bound on RSS: every faulted page must be resident
         * (assuming no swap), so actual RSS must be >= expected RSS.
         * A negative bloat indicates swap activity or a bug — we abort.
         *
         * rss_bloat = rss_actual - rss_expected  (allocator overhead / fragmentation)
         * frag_pct  = rss_bloat / rss_actual * 100
         *
         * vss_allocated = cumulative bytes requested via malloc() across all threads
         * vss_freed     = cumulative bytes freed (original malloc sizes)
         * rss_alloc_mb  = cumulative touch-bytes charged at malloc time (RSS proxy)
         * rss_freed_mb  = cumulative touch-bytes credited at free time (RSS proxy)
         */
        double vss_alloc_mb  = (double)agg_vss_alloc[i]  / (1024.0 * 1024.0);
        double vss_freed_mb  = (double)agg_vss_freed[i]  / (1024.0 * 1024.0);
        double rss_alloc_mb  = (double)agg_rss_alloc[i]  / (1024.0 * 1024.0);
        double rss_freed_mb  = (double)agg_rss_freed[i]  / (1024.0 * 1024.0);
        double rss_expected  = (rss_alloc_mb - rss_freed_mb);
        double rate          = (double)(agg_rss_alloc[i] - prev_rss_alloc)   / (1024.0 * 1024.0) / g_interval;
        double rss_actual    = history[i].actual_rss_mb;
        double rss_bloat     = rss_actual - rss_expected;
        double frag_pct      = (rss_actual > 0.0) ? (rss_bloat / rss_actual) * 100.0 : 0.0;
        size_t iters         = agg_iterations[i];

        printf("%-8d %-16.2f %-16.2f %-16.2f %-16.2f %-14.2f %-12.2f %-14.2f %-14.2f %.2f%% %-12zu\n",
               (i + 1) * g_interval,
               vss_alloc_mb, vss_freed_mb,
               rss_alloc_mb, rss_freed_mb,
               rss_expected, rate, rss_actual, rss_bloat, frag_pct, iters);

        /* Sanity check: actual RSS must never be less than expected RSS.
         * Pages that were written via memcpy must be resident (no swap assumed).
         * A negative bloat indicates either a bug in touch-byte accounting or
         * that the system is swapping — both are invalid benchmark conditions. */
        if (rss_bloat < 0.0) {
            fprintf(stderr,
                    "\n[FATAL] Interval %d: RSS actual (%.2f MiB) < RSS expected (%.2f MiB).\n"
                    "        RSS Bloat = %.2f MiB — pages we wrote are not resident.\n"
                    "        This indicates swap activity or a bug in touch-byte accounting.\n"
                    "        Aborting benchmark.\n",
                    (i + 1) * g_interval, rss_actual, rss_expected, rss_bloat);
            free(agg_rss_alloc); free(agg_rss_freed);
            free(agg_vss_alloc); free(agg_vss_freed);
            free(agg_iterations);
            exit(1);
        }

        prev_rss_alloc = agg_rss_alloc[i];
    }

    free(agg_rss_alloc); free(agg_rss_freed);
    free(agg_vss_alloc); free(agg_vss_freed);
    free(agg_iterations);
}

/* ================================================================
 * CLI parsing
 * ================================================================ */

static void print_usage(const char* prog) {
    printf("Usage: %s [options]\n\n", prog);
    printf("Options:\n");
    printf("  -t, --threads <n>        number of worker threads         (default %d)\n", g_num_threads);
    printf("  --duration    <s>        total run time in seconds        (default %d)\n", g_duration);
    printf("  --max_rss_target <MiB>   stop once RSS reaches this limit (default %.2f MiB; 40%% system memory)\n",
           g_max_rss_target_mb);
    printf("  --interval    <s>        reporting interval in seconds    (default %d)\n", g_interval);
    printf("  --workload    frag|mixed workload type                    (default frag)\n");
    printf("  --obj_size_min <bytes>   min object size (mixed only)     (default %zu)\n", g_obj_size_min);
    printf("  --obj_size_max <bytes>   max object size (mixed only)     (default %zu)\n", g_obj_size_max);
    printf("  --obj_retention <0-100>  retention probability %% (mixed)  (default %d)\n", g_obj_retention);
}

static void parse_args(int argc, char** argv) {
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            print_usage(argv[0]);
            exit(0);
        } else if ((strcmp(argv[i], "-t") == 0 || strcmp(argv[i], "--threads") == 0) && i + 1 < argc) {
            g_num_threads = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--duration") == 0 && i + 1 < argc) {
            g_duration = atoi(argv[++i]);
        } else if ((strcmp(argv[i], "--max_rss_target") == 0 || strcmp(argv[i], "--maxRSSTarget") == 0) && i + 1 < argc) {
            char* end = NULL;

            errno = 0;
            g_max_rss_target_mb = strtod(argv[++i], &end);
            if (errno != 0 || end == argv[i] || *end != '\0') {
                fprintf(stderr, "--max_rss_target must be a positive number of MiB\n");
                exit(1);
            }
        } else if (strcmp(argv[i], "--interval") == 0 && i + 1 < argc) {
            g_interval = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--workload") == 0 && i + 1 < argc) {
            ++i;
            if (strcmp(argv[i], "mixed") == 0)      g_workload = WORKLOAD_MIXED;
            else if (strcmp(argv[i], "frag") == 0)  g_workload = WORKLOAD_FRAG;
            else {
                fprintf(stderr, "Unknown workload '%s'. Choose frag or mixed.\n", argv[i]);
                exit(1);
            }
        } else if (strcmp(argv[i], "--obj_size_min") == 0 && i + 1 < argc) {
            g_obj_size_min = (size_t)atol(argv[++i]);
        } else if (strcmp(argv[i], "--obj_size_max") == 0 && i + 1 < argc) {
            g_obj_size_max = (size_t)atol(argv[++i]);
        } else if (strcmp(argv[i], "--obj_retention") == 0 && i + 1 < argc) {
            g_obj_retention = atoi(argv[++i]);
            if (g_obj_retention < 0)   g_obj_retention = 0;
            if (g_obj_retention > 100) g_obj_retention = 100;
        } else {
            fprintf(stderr, "Unknown argument: %s\n", argv[i]);
            fprintf(stderr, "Run with --help for usage.\n");
            exit(1);
        }
    }

    /* Validate */
    if (g_num_threads < 1) { fprintf(stderr, "--threads must be >= 1\n");  exit(1); }
    if (g_duration <= 0)   { fprintf(stderr, "--duration must be > 0\n");  exit(1); }
    if (g_max_rss_target_mb <= 0.0) {
        fprintf(stderr, "--max_rss_target must be > 0 MiB\n");
        exit(1);
    }
    if (g_interval <= 0)   { fprintf(stderr, "--interval must be > 0\n");  exit(1); }
    if (g_obj_size_min < 1) {
        fprintf(stderr, "--obj_size_min must be >= 1\n"); exit(1);
    }
    if (g_obj_size_max < g_obj_size_min) {
        fprintf(stderr, "--obj_size_max must be >= --obj_size_min\n"); exit(1);
    }
}

/* ================================================================
 * main
 * ================================================================ */

int main(int argc, char** argv) {
    /* Query the OS page size once; used as the RSS unit per allocation/free */
    long ps = sysconf(_SC_PAGESIZE);
    if (ps > 0) g_page_size = (size_t)ps;

    g_max_rss_target_mb = detect_default_max_rss_target_mb();

    parse_args(argc, argv);

    int            num_intervals = g_duration / g_interval;
    GlobalMonitor* history       = malloc(sizeof(GlobalMonitor) * num_intervals);
    if (!history) { fprintf(stderr, "OOM allocating history\n"); return 1; }

    const char* workload_name =
        (g_workload == WORKLOAD_MIXED) ? "mixed object" : "fragmentation";

    printf("Starting MemBench CLI\n");
    check_thp();
    printf("Config: Threads=%d, Duration=%ds, Interval=%ds, Workload=%s, maxRSSTarget=%.2f MiB\n",
           g_num_threads, g_duration, g_interval, workload_name, g_max_rss_target_mb);
    if (g_workload == WORKLOAD_MIXED) {
        printf("  Object size: [%zu, %zu] bytes | Retention: %d%%\n",
               g_obj_size_min, g_obj_size_max, g_obj_retention);
    }
    printf("----------------------------------------------------------------------\n");


    pthread_t* threads = malloc(sizeof(pthread_t) * (size_t)g_num_threads);
    if (!threads) { fprintf(stderr, "OOM allocating thread handles\n"); return 1; }

    void* (*worker_fn)(void*) =
        (g_workload == WORKLOAD_MIXED) ? worker_mixed : worker_frag;

    for (int i = 0; i < g_num_threads; i++) {
        int* id = malloc(sizeof(int));
        if (!id) { fprintf(stderr, "OOM allocating thread id\n"); return 1; }
        *id = i;
        pthread_create(&threads[i], NULL, worker_fn, id);
    }

    /* Main monitor loop: sleep per interval, sample RSS, stop early on RSS limit */
    int intervals_captured = 0;
    bool stopped_by_rss_target = false;
    for (int i = 0; i < num_intervals; i++) {
        sleep((unsigned int)g_interval);
        double current_rss = (double)get_rss_kb() / 1024.0;
        history[intervals_captured].actual_rss_mb = current_rss;
        intervals_captured++;
        printf("[Live] Interval %d/%d | RSS: %.2f MiB\n",
               i + 1, num_intervals, current_rss);

        if (current_rss >= g_max_rss_target_mb) {
            printf("[Live] maxRSSTarget reached (%.2f MiB >= %.2f MiB) | requesting workers to stop\n",
                   current_rss, g_max_rss_target_mb);
            atomic_store(&keep_allocating, false);
            stopped_by_rss_target = true;
            break;
        }
    }

    if (!stopped_by_rss_target) atomic_store(&keep_allocating, false);
    for (int i = 0; i < g_num_threads; i++) pthread_join(threads[i], NULL);

    if (stopped_by_rss_target) {
        printf("Benchmark stopped early after %d interval(s) because maxRSSTarget was reached.\n",
               intervals_captured);
    }

    generate_final_report(history, intervals_captured);

    free(history);
    free(threads);
    return 0;
}
