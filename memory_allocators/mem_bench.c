#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>
#include <unistd.h>
#include <string.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <time.h>

#define SMALL_SIZE 256
#define LARGE_SIZE (16 * 1024)

// --- Structures ---
typedef struct StatSnapshot {
    int interval_index;
    size_t allocated;
    size_t freed;
    struct StatSnapshot* next;
} StatSnapshot;

typedef struct ThreadData {
    int thread_idx;
    StatSnapshot* snapshots_head;
    struct ThreadData* next;
} ThreadData;

// To store process-wide RSS history
typedef struct {
    double rss_mb;
} GlobalMonitor;

// --- Global Config & State ---
int g_num_threads = 1;
int g_duration = 60;
int g_interval = 5;

atomic_bool keep_allocating = true;
ThreadData* global_stats_head = NULL;
pthread_mutex_t stats_mutex = PTHREAD_MUTEX_INITIALIZER;

// Thread-local counters
__thread size_t tl_allocated = 0;
__thread size_t tl_freed = 0;

// --- Helpers ---
void check_thp() {
    FILE* fp = fopen("/sys/kernel/mm/transparent_hugepage/enabled", "r");
    if (fp) {
        char buf[256];
        if (fgets(buf, sizeof(buf), fp)) printf("THP State: %s", buf);
        fclose(fp);
    }
}

long get_rss_kb() {
    long rss_pages = 0;
    FILE* fp = fopen("/proc/self/statm", "r");
    if (!fp) return 0;
    if (fscanf(fp, "%*s %ld", &rss_pages) != 1) { fclose(fp); return 0; }
    fclose(fp);
    return (rss_pages * sysconf(_SC_PAGESIZE)) / 1024;
}

// --- Worker Thread ---
void* memory_worker(void* arg) {
    int thread_idx = *(int*)arg;
    free(arg);

    StatSnapshot* local_head = NULL;
    StatSnapshot* local_tail = NULL;
    int current_interval = 0;
    time_t start_time = time(NULL);

    while (atomic_load(&keep_allocating)) {
        void* s = malloc(SMALL_SIZE);
        if (s) tl_allocated += SMALL_SIZE;

        void* l = malloc(LARGE_SIZE);
        if (l) {
            tl_allocated += LARGE_SIZE;
            free(l);
            tl_freed += LARGE_SIZE;
        }

        time_t now = time(NULL);
        if (now - start_time >= (current_interval + 1) * g_interval) {
            StatSnapshot* snp = malloc(sizeof(StatSnapshot));
            snp->interval_index = current_interval;
            snp->allocated = tl_allocated;
            snp->freed = tl_freed;
            snp->next = NULL;

            if (!local_head) local_head = snp;
            else local_tail->next = snp;
            local_tail = snp;
            current_interval++;
        }
    }

    ThreadData* td = malloc(sizeof(ThreadData));
    td->thread_idx = thread_idx;
    td->snapshots_head = local_head;

    pthread_mutex_lock(&stats_mutex);
    td->next = global_stats_head;
    global_stats_head = td;
    pthread_mutex_unlock(&stats_mutex);
    return NULL;
}

// --- Main Analysis ---
void generate_final_report(GlobalMonitor* history) {
    int num_intervals = g_duration / g_interval;
    size_t* agg_alloc = calloc(num_intervals, sizeof(size_t));
    size_t* agg_freed = calloc(num_intervals, sizeof(size_t));

    printf("\n=== AGGREGATED BENCHMARK REPORT ===\n");
    printf("%-8s %-12s %-12s %-12s %-12s %-10s\n",
           "Time(s)", "Used(MiB)", "Rate(MiB/s)", "RSS(MiB)", "Bloat(MiB)", "Frag %");

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

    size_t prev_alloc = 0;
    for (int i = 0; i < num_intervals; i++) {
        double used_mb = (double)(agg_alloc[i] - agg_freed[i]) / (1024 * 1024);
        double rate = (double)(agg_alloc[i] - prev_alloc) / (1024 * 1024) / g_interval;
        double rss_mb = history[i].rss_mb;
        double bloat_mb = rss_mb - used_mb;

        // Frag % calculation: ((RSS - Used) / RSS) * 100
        double frag_perc = (rss_mb > 0) ? (bloat_mb / rss_mb) * 100.0 : 0;

        printf("%-8d %-12.2f %-12.2f %-12.2f %-12.2f %-10.2f%%\n",
               (i + 1) * g_interval, used_mb, rate, rss_mb, bloat_mb, frag_perc);

        prev_alloc = agg_alloc[i];
    }

    free(agg_alloc);
    free(agg_freed);
}

int main(int argc, char** argv) {
    if (argc > 1) g_duration = atoi(argv[1]);

    char* env_t = getenv("NUM_THREADS");
    if (env_t) g_num_threads = atoi(env_t);

    int num_intervals = g_duration / g_interval;
    GlobalMonitor* history = malloc(sizeof(GlobalMonitor) * num_intervals);

    printf("Starting MemBench CLI\n");
    check_thp();
    printf("Config: Threads=%d, Duration=%ds, Interval=%ds\n", g_num_threads, g_duration, g_interval);
    printf("----------------------------------------------------------------------\n");

    pthread_t threads[g_num_threads];
    for (int i = 0; i < g_num_threads; i++) {
        int* id = malloc(sizeof(int));
        *id = i;
        pthread_create(&threads[i], NULL, memory_worker, id);
    }

    // Main Monitor & Live Update
    for (int i = 0; i < num_intervals; i++) {
        sleep(g_interval);
        double current_rss = (double)get_rss_kb() / 1024;
        history[i].rss_mb = current_rss;
        printf("[Live] Interval %d/%d | RSS: %.2f MiB\n", i+1, num_intervals, current_rss);
    }

    atomic_store(&keep_allocating, false);
    for (int i = 0; i < g_num_threads; i++) pthread_join(threads[i], NULL);

    generate_final_report(history);

    free(history);
    return 0;
}
