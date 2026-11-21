#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "zf/pool.h"
#include "zf/env.h"
#include "zf/libm.h"

#include <pthread.h>
#include <stdatomic.h>

/* A hint that this core is spinning, so the others get the bus. Without it three spinning workers
 * slow the calling thread's own memory-bound work measurably. */
static inline void zf_cpu_relax(void) {
#if defined(__arm__) || defined(__aarch64__)
  __asm__ __volatile__("yield" ::: "memory");
#else
  __asm__ __volatile__("" ::: "memory");
#endif
}
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#if defined(__APPLE__)
#include "zf/darwin_compat.h"
#elif defined(_WIN32)
#define ZF_WIN32_AFFINITY 1
#include "zf/win32_compat.h"
#elif defined(__EMSCRIPTEN__)
/* WebAssembly: no affinity and no syscall(). The affinity calls fail, so the pool neither pins nor
 * follows a cpuset; its team is the thread count asked for. */
#define zf_gettid() ((int)gettid())
#define sched_getaffinity(pid, size, set) ((void)(pid), (void)(size), (void)(set), -1)
#define sched_setaffinity(pid, size, set) ((void)(pid), (void)(size), (void)(set), -1)
#undef CPU_COUNT
#define CPU_COUNT(s) zf_cpu_count(s)
static inline int zf_cpu_count(const cpu_set_t *s) {
  int n = 0;
  for (int c = 0; c < CPU_SETSIZE; ++c) n += CPU_ISSET(c, s) ? 1 : 0;
  return n;
}
#else
#include <sys/syscall.h>
#define zf_gettid() ((int)syscall(SYS_gettid))
#endif
#include <time.h>
#include <unistd.h>

/* The three atomics a barrier touches sit on their own cache lines.
 *
 * A chunk crosses about a thousand of these regions, and on the way through each one the calling
 * thread writes the cursor, the done count and the generation while three workers read the
 * generation and read-modify-write the cursor and the count. Sharing one line meant that traffic
 * ping-ponged through the cluster's L2 on every barrier. */
#define ZF_CACHE_LINE 64

typedef struct {
  atomic_int value;
  char pad[ZF_CACHE_LINE - sizeof(atomic_int)];
} ZfPadded;

/* A worker's own identity, so the core it takes is decided before it starts rather than raced for.
 * Racing on a shared counter put more than one worker on the same core, and with a spin wait that
 * is not slow but broken: a spinning worker holds the core against the thread it is waiting for. */
typedef struct {
  ZfPool *pool;
  int slot;
  atomic_int parked; /* set while it waits on park_cv for its slot to be wanted again */
} ZfWorker;

struct ZfPool {
  int threads;
  int spin_us;
  pthread_t *workers;
  ZfWorker *worker_args;
  int n_workers;

  pthread_mutex_t lock;
  pthread_cond_t wake;
  ZfPadded generation;   /* incremented once per submitted region */
  ZfPadded next_item;    /* shared work cursor */
  ZfPadded done_count;   /* workers that finished the current region */
  ZfPadded stop;
  ZfPadded sleepers;     /* workers parked on the condition variable rather than spinning */

  ZfRangeFn fn;
  void *context;
  int count;
  int grain;
  cpu_set_t allowed; /* the cores the team is spread over now */

  /* Following the cpuset. See pool_refresh. */
  ZfPadded active;       /* workers taking part in regions: slots 1..active */
  ZfPadded epoch;        /* bumped when `allowed` changes; a worker re-pins when it sees it move */
  pthread_cond_t park_cv;
  cpu_set_t user_mask;   /* a narrowing the process asked for itself (taskset), kept through moves */
  int adapt;
  unsigned runs;
  pthread_t sentinel;    /* never pinned, so its mask is the process's cpuset; see pool_refresh */
  atomic_int sentinel_tid;
  int pin;               /* pin the caller and the workers one to a core (zf_pool_create_pinned) */
  /* the calling threads this pool pinned (zf/pool.c pin_caller), restored when it is destroyed */
  int pinned_tids[8];
  int n_pinned;
};



/* One thread to a core, and it stays there.
 *
 * A chunk crosses about a thousand barriers, and a barrier costs whatever the slowest thread takes
 * to arrive. A thread the scheduler has just moved arrives with a cold level one cache and pays for
 * it at every one of those barriers, and two threads landing on the same core is worse still. The
 * The set of cores is read once, before anything is pinned, and passed down. Reading it per thread
 * does not work: a worker inherits the calling thread's mask, so once the caller has narrowed
 * itself to one core every worker sees a one core mask and they all end up together, spinning
 * against each other on a single core. Failing is harmless: the scheduler decides instead. */
/* How fast a core is, for putting the team on the fastest ones: the scheduler's cpu_capacity, or the
 * highest clock where that is missing, or 0 (then cores keep their index order).
 *
 * Index order was the rule, and on big.LITTLE phones cores 0 upwards are the little ones: a Galaxy
 * S21's four threads all went to its Cortex-A55s, an S24's and a Pixel 10's two of four to A520s,
 * and a barrier waits for the slowest thread. ONNX Runtime beat the engine on those phones and lost
 * on the ones without little cores (Snapdragon 8 Elite, Dimensity 9400). Placement changes no bits. */
static long core_speed(int c) {
  /* per thread: workers of several pools may pin themselves at the same time */
  static _Thread_local long cache[CPU_SETSIZE];
  static _Thread_local int filled[CPU_SETSIZE];
  if (c < 0 || c >= CPU_SETSIZE) return 0;
#if defined(_WIN32)
  /* no sysfs: a rank from the processor's efficiency class and SMT position (zf/win32_compat.h) */
  (void)cache;
  (void)filled;
  return zf_win32_core_rank(c);
#endif
  if (!filled[c]) {
    long v = 0;
    char path[96];
    snprintf(path, sizeof path, "/sys/devices/system/cpu/cpu%d/cpu_capacity", c);
    FILE *f = fopen(path, "r");
    if (!f) {
      snprintf(path, sizeof path, "/sys/devices/system/cpu/cpu%d/cpufreq/cpuinfo_max_freq", c);
      f = fopen(path, "r");
    }
    if (f) {
      if (fscanf(f, "%ld", &v) != 1) v = 0;
      fclose(f);
    }
    cache[c] = v;
    filled[c] = 1;
  }
  return cache[c];
}

/* The allowed cores, fastest first (index order among equals). */
static int cores_by_speed(const cpu_set_t *allowed, int *out) {
  int n = 0;
  for (int c = 0; c < CPU_SETSIZE; ++c)
    if (CPU_ISSET(c, allowed)) out[n++] = c;
  for (int i = 1; i < n; ++i) { /* insertion sort, stable: a phone has at most a dozen cores */
    const int c = out[i];
    const long s = core_speed(c);
    int j = i - 1;
    while (j >= 0 && core_speed(out[j]) < s) {
      out[j + 1] = out[j];
      --j;
    }
    out[j + 1] = c;
  }
  return n;
}

int zf_pool_fast_cores(void) {
#if defined(__APPLE__)
  return zf_darwin_fast_cpus();
#endif
#if defined(__ANDROID__)
  /* Android: the phone's fast cores from its topology, not the calling thread's cpuset. An app in the
   * background (or with the screen off) runs in a cpuset of a couple of small cores, so counting the
   * caller's mask made a stream created there keep 1 or 2 threads for its whole life, also after the
   * app came to the front. Every core's capacity (or maximum clock) is readable in sysfs whatever the
   * cpuset; the pool's team follows the cpuset it runs in (pool_refresh, team_for), so asking for the
   * phone's fast cores never puts more spinning threads than cores on a small cpuset. At most 4: the
   * engine was tuned on 4 cores, and a fifth adds almost nothing (docs/costmodel.md). The team size
   * changes no bit. Falls back to the cpuset when sysfs says nothing. */
  {
    long ncpu = sysconf(_SC_NPROCESSORS_CONF);
    if (ncpu > CPU_SETSIZE) ncpu = CPU_SETSIZE;
    long top = 0;
    for (int c = 0; c < ncpu; ++c)
      if (core_speed(c) > top) top = core_speed(c);
    if (top > 0) {
      int n = 0;
      for (int c = 0; c < ncpu; ++c)
        if (10 * core_speed(c) >= 7 * top) ++n;
      return n < 1 ? 1 : n > 4 ? 4 : n;
    }
  }
#endif
  cpu_set_t allowed;
  if (sched_getaffinity(0, sizeof allowed, &allowed) != 0) return 1;
  long top = 0;
  for (int c = 0; c < CPU_SETSIZE; ++c)
    if (CPU_ISSET(c, &allowed) && core_speed(c) > top) top = core_speed(c);
  int n = 0;
  for (int c = 0; c < CPU_SETSIZE; ++c)
    if (CPU_ISSET(c, &allowed) && 10 * core_speed(c) >= 7 * top) ++n;
  return n > 0 ? n : 1;
}

/* The calling threads' own masks, process wide.
 *
 * A pool pins the thread that creates it (and any thread that later runs it) to one core. That pin
 * used to outlive the pool: destroy joined the workers and left the caller on its one core, so the
 * next pool made on that thread read a one-core mask, sized its team to it and ran every take after
 * the first on one engine thread (DELIVERY, Alcatel 1, foreground: SDK RTF 0.777 against 0.24; the
 * CLI keeps one stream and never showed it). So each pinned thread's mask from before any pin is kept
 * here with a count of the pools that pinned it: a pool sizes its team from that mask, not from the
 * pin, and the last pool to let go of the thread puts the mask back. Placement changes no bit. */
typedef struct {
  int tid, refs;
  cpu_set_t original;
} ZfPinnedThread;
static pthread_mutex_t g_pinned_lock = PTHREAD_MUTEX_INITIALIZER;
static ZfPinnedThread g_pinned[64];
static int g_n_pinned;

/* The process's cores, which a new pool's team is sized from: the main thread's mask on Linux and
 * Android (as it was before any pool pinned it, if one did), not the calling thread's, which an earlier
 * pool may have left on one core or the app may have narrowed for itself. On Windows and Darwin the
 * compat layer's sched_getaffinity already answers for the process; WebAssembly has none. */
#if defined(__linux__)
#define ZF_PROCESS_ID() ((int)getpid())
#else
#define ZF_PROCESS_ID() 0
#endif
static int process_mask(cpu_set_t *out) {
  const int pid = ZF_PROCESS_ID();
  int found = 0;
  pthread_mutex_lock(&g_pinned_lock);
  for (int i = 0; i < g_n_pinned && pid > 0; ++i)
    if (g_pinned[i].tid == pid) {
      *out = g_pinned[i].original;
      found = 1;
    }
  pthread_mutex_unlock(&g_pinned_lock);
  if (found) return 0;
  return sched_getaffinity(pid, sizeof *out, out);
}

/* Records that `pool` pins the calling thread (its original mask kept the first time any pool does),
 * then pins it. A thread the pool cannot record (its list or the table full) is not pinned. */
static void pin_to_core(const cpu_set_t *allowed, int slot);
static void pin_caller(ZfPool *pool) {
  const int tid = zf_gettid();
  int known = 0;
  for (int i = 0; i < pool->n_pinned; ++i) known |= pool->pinned_tids[i] == tid;
  if (!known) {
    if (pool->n_pinned >= (int)(sizeof pool->pinned_tids / sizeof *pool->pinned_tids)) return;
    pthread_mutex_lock(&g_pinned_lock);
    int at = -1;
    for (int i = 0; i < g_n_pinned; ++i)
      if (g_pinned[i].tid == tid) at = i;
    if (at < 0 && g_n_pinned < (int)(sizeof g_pinned / sizeof *g_pinned)) {
      cpu_set_t now;
      if (sched_getaffinity(0, sizeof now, &now) == 0) {
        at = g_n_pinned++;
        g_pinned[at].tid = tid;
        g_pinned[at].refs = 0;
        g_pinned[at].original = now;
      }
    }
    if (at >= 0) g_pinned[at].refs++;
    pthread_mutex_unlock(&g_pinned_lock);
    if (at < 0) return;
    pool->pinned_tids[pool->n_pinned++] = tid;
  }
  pin_to_core(&pool->allowed, 0);
}

/* The pool lets go of the threads it pinned; a thread no pool holds any more gets its mask back. */
static void unpin_callers(ZfPool *pool) {
  const int me = zf_gettid();
  pthread_mutex_lock(&g_pinned_lock);
  for (int k = 0; k < pool->n_pinned; ++k) {
    for (int i = 0; i < g_n_pinned; ++i) {
      if (g_pinned[i].tid != pool->pinned_tids[k]) continue;
      if (--g_pinned[i].refs <= 0) {
        /* the calling thread directly; another thread of the process by its id where the platform
         * allows it (Linux, Android) */
        sched_setaffinity(g_pinned[i].tid == me ? 0 : g_pinned[i].tid, sizeof g_pinned[i].original,
                          &g_pinned[i].original);
        g_pinned[i] = g_pinned[--g_n_pinned];
      }
      break;
    }
  }
  pool->n_pinned = 0;
  pthread_mutex_unlock(&g_pinned_lock);
}

static void pin_to_core(const cpu_set_t *allowed, int slot) {
  int order[CPU_SETSIZE];
  const int count = cores_by_speed(allowed, order);
  if (count <= 1) return;
  cpu_set_t one;
  CPU_ZERO(&one);
  CPU_SET(order[slot % count], &one);
  sched_setaffinity(0, sizeof one, &one);
}

/* After this many rounds of the join spin, offer the core to the scheduler. Zero means never.
 *
 * This defaulted to 64 on the following argument: seventy per cent of the join wait on four cores
 * sat in single waits longer than a millisecond, the longest 7.7 ms and about eight a chunk, which
 * looked like the scheduler taking one of four cores away for a timeslice. A waiting thread has
 * nothing to lose by offering its core up, so it should yield rather than hold it.
 *
 * The diagnosis was wrong. Those multi-millisecond waits were a launcher app holding a third of a
 * core; with the screen off the join wait falls to 1.6-2.4 ms and the long tail goes with it. What
 * the threshold actually buys, once there is no such interloper, is syscalls: it is read by the
 * WORKERS' idle spin as well as by the caller's join, and a spin round is two acquire loads and a
 * YIELD hint, so 64 rounds is a few microseconds. A worker idle for milliseconds a chunk then
 * yields thousands of times, three workers more so, and the kernel entry and exit is charged to
 * cores the team is waiting for.
 *
 * Interleaved sweep on chunk_ms_min, four reps, quiet device, tokens identical at every setting:
 *
 *   rounds     0        8       64      512
 *           79.45    80.35    80.37    79.89
 *           79.45    80.56    80.35    79.48
 *           79.35    80.50    80.46    79.50
 *           79.74    80.71    80.51    79.70
 *
 * Never yielding wins every rep by about a millisecond, and pool_wait_ms falls from 43-102 to
 * 30-40. 512 is nearly as good, which is the same result read from the other end: what costs is
 * the number of yields, not whether the option exists. The env override stays so zf_yield2.sh can
 * re-run this on another device, where a core-stealing neighbour may well change the answer. */
static int zf_join_yield_rounds(void) {
  static _Atomic int rounds = -1;
  if (rounds < 0) {
    const char *v = zf_getenv("ZF_JOIN_YIELD");
    rounds = v ? atoi(v) : 0;
    if (rounds < 0) rounds = 0;
  }
  return rounds;
}

static int zf_pool_always_wake(void) {
  static _Atomic int on = -1;
  if (on < 0) {
    const char *v = zf_getenv("ZF_POOL_ALWAYS_WAKE");
    on = v && atoi(v);
  }
  return on;
}

static int zf_pool_pinning(void) {
  static _Atomic int mode = -1;
  if (mode < 0) {
    const char *v = zf_getenv("ZF_PIN");
    mode = v ? atoi(v) : 1;
  }
  return mode;
}

/* The cores the process's cpuset gives it, from the cpuset file, or 0 if that cannot be read. Used
 * once, at creation, to tell a taskset narrowing (kept) from the cpuset itself. An app cannot read
 * these files under SELinux, and then there is no narrowing to keep. cgroup v1 as Android mounts it
 * (/dev/cpuset, noprefix). */
static int read_cpuset(cpu_set_t *out) {
  FILE *f = fopen("/proc/self/cgroup", "r");
  if (!f) return 0;
  char line[512], dir[400] = {0};
  int found = 0;
  while (!found && fgets(line, sizeof line, f)) {
    const char *p = strstr(line, ":cpuset:");
    if (!p) continue;
    p += 8;
    const size_t n = strcspn(p, "\r\n");
    if (n + 1 > sizeof dir) break;
    memcpy(dir, p, n);
    dir[n] = 0;
    found = 1;
  }
  fclose(f);
  if (!found) return 0;
  char path[512];
  const char *sep = (dir[0] && strcmp(dir, "/")) ? "/" : "";
  snprintf(path, sizeof path, "/dev/cpuset%s%scpus", strcmp(dir, "/") ? dir : "", sep);
  f = fopen(path, "r");
  if (!f) {
    snprintf(path, sizeof path, "/dev/cpuset%s%scpuset.cpus", strcmp(dir, "/") ? dir : "", sep);
    f = fopen(path, "r");
  }
  if (!f) return 0;
  char list[256];
  const int ok = fgets(list, sizeof list, f) != NULL;
  fclose(f);
  if (!ok) return 0;
  CPU_ZERO(out);
  for (const char *s = list; *s && *s != '\n';) {
    char *end;
    const long a = strtol(s, &end, 10);
    if (end == s) break;
    long b = a;
    s = end;
    if (*s == '-') {
      b = strtol(s + 1, &end, 10);
      s = end;
    }
    for (long c = a; c <= b && c < CPU_SETSIZE; ++c) CPU_SET((int)c, out);
    if (*s == ',') ++s;
  }
  return CPU_COUNT(out) > 0;
}

static int zf_pool_adapting(void) {
  static _Atomic int on = -1;
  if (on < 0) {
    const char *v = zf_getenv("ZF_POOL_ADAPT");
    on = v ? atoi(v) : 1;
  }
  return on;
}

/* Asleep for the pool's lifetime; it exists only to be the one thread nothing pins. */
static void *sentinel_main(void *arg) {
  ZfPool *pool = (ZfPool *)arg;
  /* it inherited its creator's mask, which a pool alive on the same thread may have pinned to one
   * core: start from the process's cores (pool->allowed), so the kernel then keeps it equal to the
   * cpuset through every move */
  sched_setaffinity(0, sizeof pool->allowed, &pool->allowed);
  pthread_mutex_lock(&pool->lock);
  atomic_store_explicit(&pool->sentinel_tid, zf_gettid(), memory_order_release);
  while (!atomic_load_explicit(&pool->stop.value, memory_order_acquire))
    pthread_cond_wait(&pool->park_cv, &pool->lock);
  pthread_mutex_unlock(&pool->lock);
  return NULL;
}

static int team_for(const ZfPool *pool, const cpu_set_t *cores) {
  const int n = CPU_COUNT(cores);
  int want = (pool->threads < n ? pool->threads : n) - 1;
  if (want > pool->n_workers) want = pool->n_workers;
  return want < 0 ? 0 : want;
}

/* Follow the cpuset: as many threads as it has cores, one to a core.
 *
 * Android moves an app between cpusets as it changes state: top-app has every core, background has
 * a couple of small ones (cores 2-3 at 416 MHz on the Alcatel). The team was sized and pinned once,
 * at start, so after a move four threads that spin at every barrier shared two cores and a chunk
 * crawled: 0 clips in 75 s on the Alcatel, against 4.4 s a clip in front. The move also wipes the
 * pins, since the kernel resets every moved thread's mask to the new cpuset.
 *
 * Where the cores are now: the sentinel's mask. It is never pinned, so the kernel keeps it equal to
 * the cpuset through every move; the pinned threads cannot say it (they report their pin), and an
 * app cannot read the cpuset files. One syscall, about once a chunk.
 *
 * Called by the calling thread between regions, so no worker is inside one. Tokens do not depend
 * on the team size (the work is claimed from a shared cursor and every range computes the same
 * bits whoever runs it), so this changes the speed and nothing else. */
static void pool_refresh(ZfPool *pool) {
  cpu_set_t now;
  const int tid = atomic_load_explicit(&pool->sentinel_tid, memory_order_acquire);
  if (tid <= 0 || sched_getaffinity(tid, sizeof now, &now) != 0) return;
  CPU_AND(&now, &now, &pool->user_mask);
  if (CPU_COUNT(&now) == 0) return;
  if (CPU_EQUAL(&now, &pool->allowed)) {
    /* Same cores, but a move away and back between two looks leaves the same set with every pin
     * wiped. The calling thread's own mask tells: pinned, it is one core. */
    cpu_set_t mine;
    if (!pool->pin || CPU_COUNT(&now) <= 1 ||
        sched_getaffinity(0, sizeof mine, &mine) != 0 || CPU_COUNT(&mine) <= 1)
      return;
  }
  const int old = atomic_load_explicit(&pool->active.value, memory_order_relaxed);
  const int want = team_for(pool, &now);
  pthread_mutex_lock(&pool->lock);
  pool->allowed = now;
  atomic_store_explicit(&pool->active.value, want, memory_order_seq_cst);
  atomic_fetch_add_explicit(&pool->epoch.value, 1, memory_order_seq_cst);
  pthread_cond_broadcast(&pool->park_cv);
  pthread_mutex_unlock(&pool->lock);
  if (pool->pin) pin_caller(pool);
  /* A parked worker takes the current generation as seen when it leaves the park, so the next
   * region must not be submitted before it has. One that never parked needs nothing: it reads
   * `active` after the next generation, and that store came first. */
  for (int i = old; i < want; ++i)
    while (atomic_load_explicit(&pool->worker_args[i].parked, memory_order_acquire)) zf_cpu_relax();
}

/* How long the calling thread spends at the join, over the whole process.
 *
 * The linear regions scale 2.93 times on four cores while the kernel inside them holds the same
 * rate per core it reaches on one, so about 17 ms of a chunk is threads not working. This says
 * whether that is the caller waiting at the join, which is skew, or something else. Two clock reads
 * a region, and a region is about 100 us. */
/* Diagnostic timings, per calling thread: several pools may run at once, one per stream, and the
 * thread that runs a stream is the one that reads its numbers. */
static _Thread_local double g_wait_ms = 0.0;
static _Thread_local double g_wait_count = 0.0;
static _Thread_local double g_region_ms = 0.0;
/* Where the join wait goes: a mean of 30 us a region could be every region skewed a little or a
 * few regions stalled for a long time, and the two want opposite fixes. */
static _Thread_local double g_wait_hist[5]; /* < 10 us, < 50, < 200, < 1000, above */
static _Thread_local double g_wait_max = 0.0;

double zf_pool_wait_ms(void) { return g_wait_ms; }
double zf_pool_region_ms(void) { return g_region_ms; }
double zf_pool_wait_max_us(void) { return g_wait_max; }
void zf_pool_wait_hist(double *out5) {
  for (int i = 0; i < 5; ++i) out5[i] = g_wait_hist[i];
}
double zf_pool_wait_count(void) { return g_wait_count; }
void zf_pool_wait_reset(void) { g_wait_ms = 0.0; g_wait_count = 0.0; g_region_ms = 0.0; }

/* ZF_POOL_TIMERS: the three clock reads a region, compiled out by default.
 *
 * zf_pool_run read the clock at entry, at the join and at the end, and a chunk crosses about 900
 * regions, so this was some 2700 clock_gettime calls a chunk in the shipping path to populate
 * numbers only the bench prints. On this kernel that call is not always in the vDSO, and the
 * comment in worker_main already records what contention on it costs. The region counter stays
 * unconditional, being one relaxed increment, so pool_regions still reports without the clocks.
 *
 * Build the profiling binary with -DZF_POOL_TIMERS=1 to get pool_wait_ms and the histogram back. */
#ifndef ZF_POOL_TIMERS
#define ZF_POOL_TIMERS 0
#endif

#if ZF_POOL_TIMERS
static double pool_now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec * 1e3 + (double)ts.tv_nsec / 1e6;
}
#define ZF_POOL_NOW() pool_now_ms()
#else
#define ZF_POOL_NOW() 0.0
#endif

#if ZF_POOL_TIMERS
/* ZF_POOL_REPORT: where a chunk's idle core time goes, by region. Each region is keyed by a tag,
 * the real work function (the bridge the custom ops go through passes its own caller's), and gets
 * its wall time, the time every thread spent inside tasks, and the caller's wait at the join. Idle
 * core time is threads x wall - busy. Profiling builds only; printed at exit, symbolise the
 * offsets against the binary. */
#include <dlfcn.h>
#include <stdio.h>
typedef struct {
  const void *tag;
  double calls, wall_ms, busy_ms, wait_ms, tasks;
} ZfRegionStat;
static _Thread_local ZfRegionStat g_rs[128];
static _Thread_local int g_rs_n = 0;
static _Thread_local const void *g_tag = NULL;
static _Atomic long long g_busy_ns = 0;
static double rs_now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec * 1e3 + (double)ts.tv_nsec / 1e6;
}
static void rs_print(void) {
  double idle_total = 0.0;
  for (int i = 0; i < g_rs_n; ++i) idle_total += g_rs[i].wall_ms * 4.0 - g_rs[i].busy_ms;
  fprintf(stderr, "pool report: offset calls wall_ms busy_ms wait_ms tasks/call idle_core_ms\n");
  for (int i = 0; i < g_rs_n; ++i) {
    Dl_info d;
    const unsigned long off = dladdr(g_rs[i].tag, &d) && d.dli_fbase
                                  ? (unsigned long)((const char *)g_rs[i].tag - (const char *)d.dli_fbase)
                                  : 0;
    fprintf(stderr, "region 0x%lx %.0f %.2f %.2f %.2f %.1f %.2f\n", off, g_rs[i].calls,
            g_rs[i].wall_ms, g_rs[i].busy_ms, g_rs[i].wait_ms, g_rs[i].tasks / g_rs[i].calls,
            g_rs[i].wall_ms * 4.0 - g_rs[i].busy_ms);
  }
  fprintf(stderr, "pool report: idle core ms total %.2f\n", idle_total);
}
static ZfRegionStat *rs_slot(const void *tag) {
  for (int i = 0; i < g_rs_n; ++i)
    if (g_rs[i].tag == tag) return &g_rs[i];
  if (g_rs_n == 0 && zf_getenv("ZF_POOL_REPORT")) atexit(rs_print);
  if (g_rs_n == 128) return NULL;
  g_rs[g_rs_n].tag = tag;
  return &g_rs[g_rs_n++];
}
#endif

void zf_pool_set_tag(const void *tag) {
#if ZF_POOL_TIMERS
  g_tag = tag;
#else
  (void)tag;
#endif
}

static void run_claimed_work(ZfPool *pool) {
#if ZF_POOL_TIMERS
  const double b0 = rs_now_ms();
#endif
  for (;;) {
    const int begin = atomic_fetch_add_explicit(&pool->next_item.value, pool->grain, memory_order_relaxed);
    if (begin >= pool->count) break;
    int end = begin + pool->grain;
    if (end > pool->count) end = pool->count;
    pool->fn(pool->context, begin, end);
  }
#if ZF_POOL_TIMERS
  atomic_fetch_add(&g_busy_ns, (long long)((rs_now_ms() - b0) * 1e6));
#endif
}

static void *worker_main(void *arg) {
  ZfWorker *self = (ZfWorker *)arg;
  ZfPool *pool = self->pool;
  int epoch = atomic_load_explicit(&pool->epoch.value, memory_order_acquire);
  if (pool->pin) pin_to_core(&pool->allowed, self->slot);
  else sched_setaffinity(0, sizeof pool->allowed, &pool->allowed); /* not its creator's pin: every core */
  (void)zf_fp_enter(); /* a worker only ever runs engine tasks, so it keeps ARMv7's NEON mode */
  int seen = 0;
  for (;;) {
    /* Spin for a short while so back-to-back kernels in one chunk do not pay a futex round trip,
     * then sleep so an idle engine costs nothing between chunks. The spin reads the generation and
     * yields; it checks the clock only every 256 rounds, because calling clock_gettime on every
     * round made the serial code on the calling thread nearly three times slower: three cores
     * hammering the same line and the same vDSO page starve whatever else wants the bus. */
    /* The clock is only read once the spin has already gone 256 rounds without work, so the
     * common case, where the next region is submitted immediately, reads it not at all. Reading it
     * up front cost four vDSO calls on every one of a chunk's thousand barriers. */
    struct timespec t0;
    int have_t0 = 0;
    const int yield_after = zf_join_yield_rounds();
    int generation = atomic_load_explicit(&pool->generation.value, memory_order_acquire);
    for (unsigned round = 0; generation == seen; ++round) {
      if (atomic_load_explicit(&pool->stop.value, memory_order_acquire)) break;
      zf_cpu_relax();
      generation = atomic_load_explicit(&pool->generation.value, memory_order_acquire);
      if (generation != seen) break;
      if (yield_after && (round & 63u) == 63u) sched_yield();
      if ((round & 255u) == 255u) {
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        if (!have_t0) {
          t0 = now;
          have_t0 = 1;
          continue;
        }
        const double us = (double)(now.tv_sec - t0.tv_sec) * 1e6 +
                          (double)(now.tv_nsec - t0.tv_nsec) / 1e3;
        if (us > pool->spin_us) break;
      }
    }
    if (generation == seen && !atomic_load_explicit(&pool->stop.value, memory_order_acquire)) {
      pthread_mutex_lock(&pool->lock);
      /* Announce the sleep before the last look at the generation. Both this and the submitter's
       * increment-then-read are sequentially consistent, so either this thread sees the new
       * region or the submitter sees a sleeper and broadcasts, and it can only broadcast after
       * taking the lock, which this thread holds until cond_wait releases it. */
      atomic_fetch_add_explicit(&pool->sleepers.value, 1, memory_order_seq_cst);
      while (atomic_load_explicit(&pool->generation.value, memory_order_seq_cst) == seen &&
             !atomic_load_explicit(&pool->stop.value, memory_order_acquire)) {
        pthread_cond_wait(&pool->wake, &pool->lock);
      }
      atomic_fetch_sub_explicit(&pool->sleepers.value, 1, memory_order_seq_cst);
      pthread_mutex_unlock(&pool->lock);
      generation = atomic_load_explicit(&pool->generation.value, memory_order_acquire);
    }
    if (atomic_load_explicit(&pool->stop.value, memory_order_acquire)) return NULL;
    seen = generation;
    /* Not wanted for this region: the cpuset has fewer cores than the team. Park off the spin
     * entirely, since spinning is exactly what hurt, and do not count towards the join. The
     * decision is retaken under the lock because pool_refresh changes `active` only under it. */
    if (self->slot > atomic_load_explicit(&pool->active.value, memory_order_seq_cst)) {
      pthread_mutex_lock(&pool->lock);
      if (self->slot > atomic_load_explicit(&pool->active.value, memory_order_seq_cst)) {
        atomic_store_explicit(&self->parked, 1, memory_order_relaxed);
        while (self->slot > atomic_load_explicit(&pool->active.value, memory_order_seq_cst) &&
               !atomic_load_explicit(&pool->stop.value, memory_order_acquire))
          pthread_cond_wait(&pool->park_cv, &pool->lock);
        seen = atomic_load_explicit(&pool->generation.value, memory_order_seq_cst);
        atomic_store_explicit(&self->parked, 0, memory_order_release);
      }
      /* else refresh wanted it back before it parked; `seen` is the region it sat out, and the
       * next region cannot finish without it, so it cannot miss one */
      pthread_mutex_unlock(&pool->lock);
      continue;
    }
    {
      const int e = atomic_load_explicit(&pool->epoch.value, memory_order_acquire);
      if (e != epoch) {
        epoch = e;
        if (pool->pin) pin_to_core(&pool->allowed, self->slot);
      }
    }
    run_claimed_work(pool);
    atomic_fetch_add_explicit(&pool->done_count.value, 1, memory_order_release);
  }
}

ZfPool *zf_pool_create(int threads, int spin_microseconds) {
  return zf_pool_create_pinned(threads, spin_microseconds, 1);
}

/* `pin` 0: neither the calling thread nor the workers are pinned; the scheduler places them. One
 * stream per device wants the pins (a barrier waits for its slowest thread, and a moved thread
 * arrives with a cold cache). A server running many one-thread streams wants them off: every
 * stream's calling thread was pinned to the same fastest core, so eight streams shared one core
 * (NATIVE, 14900KF: 13.8x real time pinned against 55.6x unpinned). Unlike ZF_PIN=0 this works in
 * release builds, which read no environment. */
ZfPool *zf_pool_create_pinned(int threads, int spin_microseconds, int pin) {
  if (threads < 1) threads = 1;
  ZfPool *pool = (ZfPool *)calloc(1, sizeof(ZfPool));
  if (!pool) return NULL;
  pool->pin = pin && zf_pool_pinning();
  pool->threads = threads;
  pool->spin_us = spin_microseconds;
  atomic_store(&pool->generation.value, 0);
  atomic_store(&pool->next_item.value, 0);
  atomic_store(&pool->done_count.value, 0);
  atomic_store(&pool->stop.value, 0);
  atomic_store(&pool->sleepers.value, 0);
  pthread_mutex_init(&pool->lock, NULL);
  pthread_cond_init(&pool->wake, NULL);
  pthread_cond_init(&pool->park_cv, NULL);
  pool->n_workers = threads - 1;
  /* the process's cores, not the creating thread's mask (process_mask) */
  const int have_mask = process_mask(&pool->allowed) == 0;
  const int pinning = pool->pin && have_mask;
  /* A mask narrower than the cpuset is the process's own choice (taskset) and is kept through every
   * move; one equal to it, or a cpuset that cannot be read (an app), narrows nothing. */
  cpu_set_t cs;
  CPU_ZERO(&pool->user_mask);
  for (int c = 0; c < CPU_SETSIZE; ++c) CPU_SET(c, &pool->user_mask);
  if (have_mask && read_cpuset(&cs) && !CPU_EQUAL(&cs, &pool->allowed)) pool->user_mask = pool->allowed;
  atomic_store(&pool->sentinel_tid, 0);
  pool->adapt = zf_pool_adapting() && have_mask && pool->n_workers > 0 &&
                pthread_create(&pool->sentinel, NULL, sentinel_main, pool) == 0;
  if (pool->adapt)
    while (atomic_load_explicit(&pool->sentinel_tid, memory_order_acquire) == 0) sched_yield();
  atomic_store(&pool->epoch.value, 0);
  if (pool->n_workers > 0) {
    pool->workers = (pthread_t *)calloc((size_t)pool->n_workers, sizeof(pthread_t));
    pool->worker_args = (ZfWorker *)calloc((size_t)pool->n_workers, sizeof(ZfWorker));
    if (!pool->workers || !pool->worker_args) {
      free(pool->workers);
      free(pool->worker_args);
      free(pool);
      return NULL;
    }
    for (int i = 0; i < pool->n_workers; ++i) {
      pool->worker_args[i].pool = pool;
      pool->worker_args[i].slot = i + 1; /* the calling thread keeps slot zero */
      atomic_store(&pool->worker_args[i].parked, 0);
      if (pthread_create(&pool->workers[i], NULL, worker_main, &pool->worker_args[i]) != 0) {
        pool->n_workers = i;
        break;
      }
    }
  }
  /* More threads than the cores it may use is the case that broke (spinning threads sharing a
   * core), so the team starts at the core count, as pool_refresh keeps it. */
  atomic_store(&pool->active.value, pool->adapt ? team_for(pool, &pool->allowed) : pool->n_workers);
  /* the calling thread last, so the workers inherited the full mask */
  if (pinning) pin_caller(pool);
  return pool;
}

void zf_pool_destroy(ZfPool *pool) {
  if (!pool) return;
  pthread_mutex_lock(&pool->lock);
  atomic_store_explicit(&pool->stop.value, 1, memory_order_release);
  pthread_cond_broadcast(&pool->wake);
  pthread_cond_broadcast(&pool->park_cv);
  pthread_mutex_unlock(&pool->lock);
  for (int i = 0; i < pool->n_workers; ++i) pthread_join(pool->workers[i], NULL);
  if (pool->adapt) pthread_join(pool->sentinel, NULL);
  unpin_callers(pool);
  pthread_mutex_destroy(&pool->lock);
  pthread_cond_destroy(&pool->wake);
  pthread_cond_destroy(&pool->park_cv);
  free(pool->workers);
  free(pool->worker_args);
  free(pool);
}

int zf_pool_threads(const ZfPool *pool) { return pool ? pool->threads : 1; }

int zf_pool_team(ZfPool *pool) {
  if (!pool || pool->n_workers == 0) return 1;
  return atomic_load_explicit(&pool->active.value, memory_order_relaxed) + 1;
}

void zf_pool_run(ZfPool *pool, ZfRangeFn fn, void *context, int count, int grain) {
  if (count <= 0) return;
  if (!pool || pool->n_workers == 0) {
    fn(context, 0, count);
    return;
  }
  /* About once a chunk (a chunk is some 900 regions): two small file reads, next to ~80 ms. */
  if (pool->adapt && (pool->runs++ & 1023u) == 0) pool_refresh(pool);
  const int active = atomic_load_explicit(&pool->active.value, memory_order_relaxed);
  if (active == 0) {
    fn(context, 0, count);
    return;
  }
  if (grain < 1) grain = 1;
  const double t_region = ZF_POOL_NOW();
  pool->fn = fn;
  pool->context = context;
  pool->count = count;
  pool->grain = grain;
  atomic_store_explicit(&pool->next_item.value, 0, memory_order_relaxed);
  atomic_store_explicit(&pool->done_count.value, 0, memory_order_relaxed);
  /* Wake only what is asleep. Inside a chunk the workers are spinning, not parked, and on bionic
   * pthread_cond_broadcast is a futex system call whether or not anyone waits: with the lock around
   * it that was two atomics and a syscall on the calling thread at each of a chunk's ~900 region
   * starts, every one on the critical path. The generation is the signal; the broadcast is only for
   * a worker that spun out and parked (see worker_main for why this cannot lose a wake-up).
   * ZF_POOL_ALWAYS_WAKE=1 puts the unconditional broadcast back, for timing. */
  atomic_fetch_add_explicit(&pool->generation.value, 1, memory_order_seq_cst);
  if (zf_pool_always_wake() ||
      atomic_load_explicit(&pool->sleepers.value, memory_order_seq_cst) > 0) {
    pthread_mutex_lock(&pool->lock);
    pthread_cond_broadcast(&pool->wake);
    pthread_mutex_unlock(&pool->lock);
  }

  run_claimed_work(pool); /* the calling thread takes its share */

  /* Workers only have the tail of the range left, so spinning here is shorter than parking. But
   * this line is one the workers are writing, and reading it on every round bounces it through the
   * cluster's cache while the thread that is still working wants the bus for its weight stream. So
   * back off between reads: the wait grows by a few idle instructions and the traffic falls by that
   * factor. */
  const double t_join = ZF_POOL_NOW();
  const int yield_after = zf_join_yield_rounds();
  int rounds = 0;
  while (atomic_load_explicit(&pool->done_count.value, memory_order_acquire) < active) {
    for (int b = 0; b < 16; ++b) zf_cpu_relax();
    if (yield_after && ++rounds >= yield_after) {
      rounds = 0;
      sched_yield();
    }
  }
  const double t_done = ZF_POOL_NOW();
  {
    const double us = (t_done - t_join) * 1e3;
    const int b = us < 10.0 ? 0 : us < 50.0 ? 1 : us < 200.0 ? 2 : us < 1000.0 ? 3 : 4;
    g_wait_hist[b] += us;
    if (us > g_wait_max) g_wait_max = us;
  }
  g_wait_ms += t_done - t_join;
  g_region_ms += t_done - t_region;
  g_wait_count += 1.0;
#if ZF_POOL_TIMERS
  {
    ZfRegionStat *r = rs_slot(g_tag ? g_tag : (const void *)fn);
    if (r) {
      r->calls += 1.0;
      r->wall_ms += t_done - t_region;
      r->busy_ms += (double)atomic_exchange(&g_busy_ns, 0) / 1e6;
      r->wait_ms += t_done - t_join;
      r->tasks += (double)count;
    }
    g_tag = NULL;
  }
#endif
}
