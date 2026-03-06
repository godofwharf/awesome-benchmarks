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
 *  expected_rss = cumulative_allocated - cumulative_freed   (from thread counters)
 *  actual_rss   = resident set size read from /proc/self/statm
 *  rss_bloat    = actual_rss - expected_rss
 *  frag_pct     = rss_bloat / actual_rss * 100.0
 *
 * CLI reference
 * -------------
 *  ./membench [options]
 *
 *  -t, --threads  <n>     number of worker threads         (default 1)
 *  --duration   <s>       total run time in seconds        (default 60)
 *  --interval   <s>       reporting interval in seconds    (default 5)
 *  --workload   frag|mixed workload to run                 (default frag)
 *  --obj_size_min <bytes> minimum object size (mixed only) (default 64)
 *  --obj_size_max <bytes> maximum object size (mixed only) (default 65536)
 *  --obj_retention <0-100> retention probability % (mixed)(default 50)
 */

#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <unistd.h>
#include <string.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <time.h>

/* ---- Fragmentation workload constants ---- */
#define FRAG_SMALL_SIZE  256
#define FRAG_LARGE_SIZE  (16 * 1024)

/* ---- Workload IDs ---- */
typedef enum {
    WORKLOAD_FRAG  = 0,
    WORKLOAD_MIXED = 1
} WorkloadType;

/* ---- Structures ---- */

typedef struct StatSnapshot {
    int    interval_index;
    size_t allocated;   /* cumulative bytes malloc'd by this thread */
    size_t freed;       /* cumulative bytes free'd   by this thread */
    struct StatSnapshot* next;
} StatSnapshot;

typedef struct ThreadData {
    int          thread_idx;
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

/* ---- Global state ---- */
static atomic_bool      keep_allocating   = true;
static ThreadData*      global_stats_head = NULL;
static pthread_mutex_t  stats_mutex       = PTHREAD_MUTEX_INITIALIZER;

/* ---- Thread-local accounting (no lock on hot path) ---- */
static __thread size_t tl_allocated = 0;
static __thread size_t tl_freed     = 0;

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
    snp->allocated      = tl_allocated;
    snp->freed          = tl_freed;
    snp->next           = NULL;

    if (!*head) *head = snp;
    else        (*tail)->next = snp;
    *tail = snp;
}

static void commit_thread_data(int thread_idx, StatSnapshot* head) {
    ThreadData* td = malloc(sizeof(ThreadData));
    if (!td) return;
    td->thread_idx      = thread_idx;
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
        /* Small — retained */
        void* s = malloc(FRAG_SMALL_SIZE);
        if (s) tl_allocated += FRAG_SMALL_SIZE;

        /* Large — immediately freed */
        void* l = malloc(FRAG_LARGE_SIZE);
        if (l) {
            tl_allocated += FRAG_LARGE_SIZE;
            free(l);
            tl_freed += FRAG_LARGE_SIZE;
        }

        time_t now = time(NULL);
        if (now - start_time >= (time_t)(current_interval + 1) * g_interval) {
            record_snapshot(&local_head, &local_tail, current_interval);
            current_interval++;
        }
    }

    commit_thread_data(thread_idx, local_head);
    return NULL;
}

/* ================================================================
 * Workload B — Mixed object workload
 *
 * Object size drawn uniformly from [g_obj_size_min, g_obj_size_max].
 * Retention decision: keep with probability g_obj_retention / 100.
 * ================================================================ */

/*
 * A simple resizable pool that holds live (retained) pointers so that
 * retained objects remain reachable throughout the benchmark.  We use
 * a per-thread pool to avoid cross-thread locking on the hot path.
 */
#define POOL_INITIAL_CAP 4096

typedef struct {
    void**  ptrs;
    size_t  len;
    size_t  cap;
} PtrPool;

static int pool_init(PtrPool* p) {
    p->ptrs = malloc(POOL_INITIAL_CAP * sizeof(void*));
    if (!p->ptrs) return -1;
    p->len = 0;
    p->cap = POOL_INITIAL_CAP;
    return 0;
}

static int pool_push(PtrPool* p, void* ptr) {
    if (p->len == p->cap) {
        size_t new_cap = p->cap * 2;
        void** tmp = realloc(p->ptrs, new_cap * sizeof(void*));
        if (!tmp) return -1;
        p->ptrs = tmp;
        p->cap  = new_cap;
    }
    p->ptrs[p->len++] = ptr;
    return 0;
}

static void pool_free_all(PtrPool* p) {
    for (size_t i = 0; i < p->len; i++) free(p->ptrs[i]);
    free(p->ptrs);
    p->ptrs = NULL;
    p->len  = 0;
    p->cap  = 0;
}

static void* worker_mixed(void* arg) {
    int thread_idx = *(int*)arg;
    free(arg);

    /* Seed per-thread PRNG */
    tl_rng_state = (uint64_t)(uintptr_t)&thread_idx ^ (uint64_t)time(NULL)
                   ^ (uint64_t)thread_idx * 6364136223846793005ULL;

    PtrPool pool;
    if (pool_init(&pool) != 0) return NULL;

    StatSnapshot* local_head = NULL;
    StatSnapshot* local_tail = NULL;
    int   current_interval   = 0;
    time_t start_time        = time(NULL);

    while (atomic_load(&keep_allocating)) {
        /* Uniform random object size in [min, max] */
        size_t obj_sz = rand_range_size(g_obj_size_min, g_obj_size_max);

        void* p = malloc(obj_sz);
        if (!p) continue;
        tl_allocated += obj_sz;

        /* Retention decision */
        if (rand_pct() < g_obj_retention) {
            /* Retain: push into pool so the object stays live */
            if (pool_push(&pool, p) != 0) {
                /* Pool expansion failed — free to avoid leak */
                free(p);
                tl_freed += obj_sz;
            }
        } else {
            /* Discard immediately */
            free(p);
            tl_freed += obj_sz;
        }

        time_t now = time(NULL);
        if (now - start_time >= (time_t)(current_interval + 1) * g_interval) {
            record_snapshot(&local_head, &local_tail, current_interval);
            current_interval++;
        }
    }

    /* Free all retained objects before exiting */
    pool_free_all(&pool);

    commit_thread_data(thread_idx, local_head);
    return NULL;
}

/* ================================================================
 * Reporting
 * ================================================================ */

static void generate_final_report(GlobalMonitor* history) {
    int     num_intervals = g_duration / g_interval;
    size_t* agg_alloc     = calloc(num_intervals, sizeof(size_t));
    size_t* agg_freed     = calloc(num_intervals, sizeof(size_t));

    if (!agg_alloc || !agg_freed) {
        fprintf(stderr, "OOM in generate_final_report\n");
        free(agg_alloc); free(agg_freed);
        return;
    }

    /* Aggregate per-interval alloc/free across all threads */
    ThreadData* curr_thread = global_stats_head;
    while (curr_thread) {
        StatSnapshot* curr_snp = curr_thread->snapshots_head;
        while (curr_snp) {
            if (curr_snp->interval_index < num_intervals) {
                agg_alloc[curr_snp->interval_index] += curr_snp->allocated;
                agg_freed[curr_snp->interval_index] += curr_snp->freed;
            }
            curr_snp = curr_snp->next;
        }
        curr_thread = curr_thread->next;
    }

    printf("\n=== AGGREGATED BENCHMARK REPORT ===\n");
    printf("%-8s %-14s %-12s %-12s %-14s %-10s\n",
           "Time(s)", "Expected(MiB)", "Rate(MiB/s)", "RSS(MiB)",
           "Bloat(MiB)", "Frag %");

    size_t prev_alloc = 0;
    for (int i = 0; i < num_intervals; i++) {
        /*
         * expected_rss = cumulative bytes still live (allocated but not freed)
         * actual_rss   = RSS read from /proc/self/statm at this interval
         * rss_bloat    = actual_rss - expected_rss
         *   (positive: allocator holds more memory than the live set needs)
         * frag_pct     = rss_bloat / actual_rss * 100
         */
        double expected_mb = (double)(agg_alloc[i] - agg_freed[i]) / (1024.0 * 1024.0);
        double rate        = (double)(agg_alloc[i] - prev_alloc)   / (1024.0 * 1024.0) / g_interval;
        double actual_rss  = history[i].actual_rss_mb;
        double bloat_mb    = actual_rss - expected_mb;
        double frag_pct    = (actual_rss > 0.0) ? (bloat_mb / actual_rss) * 100.0 : 0.0;

        printf("%-8d %-14.2f %-12.2f %-12.2f %-14.2f %.2f%%\n",
               (i + 1) * g_interval,
               expected_mb, rate, actual_rss, bloat_mb, frag_pct);

        prev_alloc = agg_alloc[i];
    }

    free(agg_alloc);
    free(agg_freed);
}

/* ================================================================
 * CLI parsing
 * ================================================================ */

static void print_usage(const char* prog) {
    printf("Usage: %s [options]\n\n", prog);
    printf("Options:\n");
    printf("  -t, --threads <n>        number of worker threads         (default %d)\n", g_num_threads);
    printf("  --duration    <s>        total run time in seconds        (default %d)\n", g_duration);
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
    parse_args(argc, argv);

    int            num_intervals = g_duration / g_interval;
    GlobalMonitor* history       = malloc(sizeof(GlobalMonitor) * num_intervals);
    if (!history) { fprintf(stderr, "OOM allocating history\n"); return 1; }

    const char* workload_name =
        (g_workload == WORKLOAD_MIXED) ? "mixed object" : "fragmentation";

    printf("Starting MemBench CLI\n");
    check_thp();
    printf("Config: Threads=%d, Duration=%ds, Interval=%ds, Workload=%s\n",
           g_num_threads, g_duration, g_interval, workload_name);
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

    /* Main monitor loop: sleep per interval, sample RSS */
    for (int i = 0; i < num_intervals; i++) {
        sleep((unsigned int)g_interval);
        double current_rss = (double)get_rss_kb() / 1024.0;
        history[i].actual_rss_mb = current_rss;
        printf("[Live] Interval %d/%d | RSS: %.2f MiB\n",
               i + 1, num_intervals, current_rss);
    }

    atomic_store(&keep_allocating, false);
    for (int i = 0; i < g_num_threads; i++) pthread_join(threads[i], NULL);

    generate_final_report(history);

    free(history);
    free(threads);
    return 0;
}
