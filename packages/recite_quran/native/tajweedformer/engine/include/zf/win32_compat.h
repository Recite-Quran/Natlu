/* Native Windows stand-ins for the Linux calls the engine and its harnesses use.
 *
 * The Windows host build is MinGW-w64 (GCC or clang, posix threads: winpthreads gives pthread.h,
 * sched_yield and clock_gettime). What is missing is the Linux affinity API, gettid and setenv.
 * As on Darwin (zf/darwin_compat.h), placement changes no bits: the affinity calls become the
 * process's affinity mask and SetThreadAffinityMask on the calling thread, and the pool's cpuset
 * tracking sees a mask that never moves. Only the first 64 logical processors (one processor
 * group) are used. Include it with ZF_WIN32_AFFINITY defined for the affinity calls (pool.c);
 * without, it is only setenv and needs no <windows.h>. */
#ifndef ZF_WIN32_COMPAT_H
#define ZF_WIN32_COMPAT_H
#if defined(_WIN32)
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* POSIX setenv over the CRT's environment, which is what getenv reads. */
static inline int zf_win32_setenv(const char *name, const char *value, int overwrite) {
  if (!overwrite && getenv(name)) return 0;
  return _putenv_s(name, value) == 0 ? 0 : -1;
}
#define setenv(name, value, overwrite) zf_win32_setenv((name), (value), (overwrite))

/* The affinity part needs <windows.h>; only the pool asks for it (ZF_WIN32_AFFINITY). */
#if defined(ZF_WIN32_AFFINITY)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
/* GetLogicalProcessorInformationEx is Windows 7's */
#if defined(_WIN32_WINNT) && _WIN32_WINNT < 0x0601
#error "zf/win32_compat.h: build with _WIN32_WINNT=0x0601 (Windows 7) or later"
#endif
#include <windows.h>

#define CPU_SETSIZE 64
typedef struct { uint64_t bits; } cpu_set_t;
#define CPU_ZERO(s) ((s)->bits = 0)
#define CPU_SET(c, s) ((s)->bits |= (1ull << (unsigned)(c)))
#define CPU_ISSET(c, s) (((s)->bits >> (unsigned)(c)) & 1ull)
#define CPU_COUNT(s) __builtin_popcountll((s)->bits)
#define CPU_AND(d, a, b) ((d)->bits = (a)->bits & (b)->bits)
#define CPU_EQUAL(a, b) ((a)->bits == (b)->bits)

/* The process's mask, whatever thread is asked about (Windows cannot read another thread's mask
 * without a handle to it; the pool asks only about its own threads). */
static inline int sched_getaffinity(int pid, size_t size, cpu_set_t *set) {
  (void)pid;
  (void)size;
  DWORD_PTR proc = 0, sys = 0;
  if (!GetProcessAffinityMask(GetCurrentProcess(), &proc, &sys) || proc == 0) return -1;
  set->bits = (uint64_t)proc;
  return 0;
}

/* The calling thread only, as the pool uses it (pid 0). */
static inline int sched_setaffinity(int pid, size_t size, const cpu_set_t *set) {
  (void)size;
  if (pid != 0 || set->bits == 0) return -1;
  return SetThreadAffinityMask(GetCurrentThread(), (DWORD_PTR)set->bits) != 0 ? 0 : -1;
}

static inline int zf_gettid(void) { return (int)(GetCurrentThreadId() & 0x7fffffff) | 1; }

/* A rank for a logical processor, for the pool's fastest-first order (pool.c's core_speed): on a
 * hybrid CPU the performance cores (higher EfficiencyClass) first, and on each core its first
 * hardware thread before its SMT sibling, so a team of n threads gets n physical cores while there
 * are enough. Every SMT sibling ranks below every first thread. 0 if Windows cannot say. */
static inline long zf_win32_core_rank(int cpu) {
  static long rank[CPU_SETSIZE];
  static volatile LONG done = 0;
  if (cpu < 0 || cpu >= CPU_SETSIZE) return 0;
  if (!done) {
    long r[CPU_SETSIZE] = {0};
    DWORD len = 0;
    GetLogicalProcessorInformationEx(RelationProcessorCore, NULL, &len);
    unsigned char *buf = len ? (unsigned char *)malloc(len) : NULL;
    if (buf && GetLogicalProcessorInformationEx(RelationProcessorCore,
                                                (PSYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX)buf, &len)) {
      for (DWORD off = 0; off < len;) {
        const SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX *e =
            (const SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX *)(buf + off);
        if (e->Size == 0) break;
        if (e->Relationship == RelationProcessorCore && e->Processor.GroupCount >= 1 &&
            e->Processor.GroupMask[0].Group == 0) {
          /* EfficiencyClass is the byte after Flags (Windows 10; older headers call it Reserved) */
          const long cls = ((const BYTE *)&e->Processor)[1];
          const uint64_t mask = (uint64_t)e->Processor.GroupMask[0].Mask;
          int first = 1;
          for (int c = 0; c < CPU_SETSIZE; ++c) {
            if (!((mask >> c) & 1ull)) continue;
            /* first threads: 2 + 2 * class; SMT siblings: 1, below every first thread */
            r[c] = first ? 2 + 2 * cls : 1;
            first = 0;
          }
        }
        off += e->Size;
      }
    }
    free(buf);
    memcpy(rank, r, sizeof rank);
    InterlockedExchange(&done, 1);
  }
  return rank[cpu];
}
#endif /* ZF_WIN32_AFFINITY */
#endif
#endif
