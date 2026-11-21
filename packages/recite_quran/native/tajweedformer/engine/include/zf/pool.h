/* Persistent worker pool. Threads are created once and then spin briefly before parking, so a
 * chunk's kernels can be split across cores without paying thread creation per call (which cost
 * 0.2 to 0.5 ms against calls of 1 to 6 ms in the benchmark). */
#ifndef ZF_POOL_H
#define ZF_POOL_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ZfPool ZfPool;

/* A task runs over a half-open range of work items; the pool splits [0, count) across workers. */
typedef void (*ZfRangeFn)(void *context, int begin, int end);

/* `threads` counts the calling thread too: threads = 4 creates 3 workers. */
ZfPool *zf_pool_create(int threads, int spin_microseconds);
/* The same with pinning chosen: 1 as zf_pool_create (one thread to a core), 0 for none (servers
 * running several streams at once; see pool.c). */
ZfPool *zf_pool_create_pinned(int threads, int spin_microseconds, int pin);

/* The default team: this process's fast cores, those with at least 70 per cent of the largest
 * capacity. A barrier waits for its slowest thread, so a slow core in the team costs more than it
 * adds. The cut is where every phone measured has its best team: Pixel 10 6.7 ms a chunk on its six
 * cores at 0.8, 17.8 ms on all eight; the Exynos 2600's cores at 0.64 of the top one make it worse
 * (6.4 ms on 4, 11.3 on 10); the Pixel 8a's at 0.71 and the S26's at 0.72 still help. */
int zf_pool_fast_cores(void);
void zf_pool_destroy(ZfPool *pool);
int zf_pool_threads(const ZfPool *pool);
/* The threads taking part in a region now: the calling thread and the workers of the active team
 * (which follows the process's cpuset, at most zf_pool_threads). For checks and diagnostics. */
int zf_pool_team(ZfPool *pool);

/* Time the calling thread spent at the join, and how many regions it joined, since the last reset.
 * This is the skew: the slowest task's overhang past the caller's own. */
double zf_pool_wait_ms(void);

/* Time the calling thread spent inside split regions at all. Chunk time minus this, minus the
 * front end's own regions, is the glue between them: code that runs on one thread while the rest
 * of the team spins. */
double zf_pool_region_ms(void);

/* The join wait split by how long it was: microseconds accumulated in the buckets
 * < 10 us, < 50 us, < 200 us, < 1 ms and above, and the longest single wait. */
void zf_pool_wait_hist(double *out5);
double zf_pool_wait_max_us(void);
double zf_pool_wait_count(void);
void zf_pool_wait_reset(void);

/* Run fn over [0, count) on all threads, returning once every item is done. The calling thread
 * takes a share, so a single-threaded pool runs fn inline with no synchronisation at all. */
void zf_pool_run(ZfPool *pool, ZfRangeFn fn, void *context, int count, int grain);
/* Profiling builds (ZF_POOL_TIMERS): name the next region by its real work function, for
 * ZF_POOL_REPORT. A no-op otherwise. */
void zf_pool_set_tag(const void *tag);

#ifdef __cplusplus
}
#endif
#endif /* ZF_POOL_H */
