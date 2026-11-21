/* Darwin (iOS, macOS) stand-ins for the Linux scheduling calls the pool uses.
 *
 * Darwin has no way to pin a thread to a core, and no cpusets to follow. Placement changes no bits
 * (the engine's arithmetic is the same on whichever core a task runs), so the affinity calls become
 * a fixed mask of the performance cores and a quality-of-service request, and the pool's cpuset
 * tracking sees a mask that never moves. */
#ifndef ZF_DARWIN_COMPAT_H
#define ZF_DARWIN_COMPAT_H
#if defined(__APPLE__)
#include <pthread.h>
#include <stdint.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/types.h>

#define CPU_SETSIZE 64
typedef struct { uint64_t bits; } cpu_set_t;
#define CPU_ZERO(s) ((s)->bits = 0)
#define CPU_SET(c, s) ((s)->bits |= (1ull << (unsigned)(c)))
#define CPU_ISSET(c, s) (((s)->bits >> (unsigned)(c)) & 1ull)
#define CPU_COUNT(s) __builtin_popcountll((s)->bits)
#define CPU_AND(d, a, b) ((d)->bits = (a)->bits & (b)->bits)
#define CPU_EQUAL(a, b) ((a)->bits == (b)->bits)

/* The performance cores (hw.perflevel0), else every core: what "0 threads" means, the same rule as
 * the Android build's "0 threads means the fast cores". */
static inline int zf_darwin_fast_cpus(void) {
  int n = 0;
  size_t len = sizeof n;
  if (sysctlbyname("hw.perflevel0.logicalcpu", &n, &len, NULL, 0) != 0 || n < 1) {
    len = sizeof n;
    if (sysctlbyname("hw.logicalcpu", &n, &len, NULL, 0) != 0 || n < 1) n = 1;
  }
  return n > CPU_SETSIZE ? CPU_SETSIZE : n;
}

static inline int zf_darwin_all_cpus(void) {
  int n = 0;
  size_t len = sizeof n;
  if (sysctlbyname("hw.logicalcpu", &n, &len, NULL, 0) != 0 || n < 1) n = 1;
  return n > CPU_SETSIZE ? CPU_SETSIZE : n;
}

/* Every core may be used (the performance cores are what zf_pool_fast_cores reports, and so what
 * a thread count of 0 means); a caller asking for more threads than that gets efficiency cores. */
static inline int sched_getaffinity(int pid, size_t size, cpu_set_t *set) {
  (void)pid;
  (void)size;
  CPU_ZERO(set);
  const int n = zf_darwin_all_cpus();
  for (int c = 0; c < n; ++c) CPU_SET(c, set);
  return 0;
}

/* No pinning on Darwin: ask for the highest QoS, which is what steers a thread to a P core. */
static inline int sched_setaffinity(int pid, size_t size, const cpu_set_t *set) {
  (void)pid;
  (void)size;
  (void)set;
  pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
  return 0;
}

static inline int zf_gettid(void) {
  uint64_t tid = 0;
  pthread_threadid_np(NULL, &tid);
  return (int)(tid & 0x7fffffff) | 1;
}
#endif
#endif
