/* The C runtime's <time.h> plus clock_gettime(CLOCK_MONOTONIC), over QueryPerformanceCounter, for
 * a Windows build against the Microsoft C runtime (see pthread.h here). Timing only. Needs a
 * compiler with #include_next (clang). */
#ifndef ZF_MSVC_TIME_H
#define ZF_MSVC_TIME_H
#include_next <time.h>
#ifndef CLOCK_MONOTONIC
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
typedef int clockid_t;
#define CLOCK_REALTIME 0
#define CLOCK_MONOTONIC 1
static inline int clock_gettime(clockid_t id, struct timespec *ts) {
  if (id == CLOCK_REALTIME) return timespec_get(ts, TIME_UTC) == TIME_UTC ? 0 : -1;
  LARGE_INTEGER f, c;
  QueryPerformanceFrequency(&f);
  QueryPerformanceCounter(&c);
  ts->tv_sec = (time_t)(c.QuadPart / f.QuadPart);
  ts->tv_nsec = (long)((c.QuadPart % f.QuadPart) * 1000000000LL / f.QuadPart);
  return 0;
}
#endif
#endif
