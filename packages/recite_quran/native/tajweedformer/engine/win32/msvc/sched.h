/* sched_yield for a Windows build against the Microsoft C runtime (see pthread.h here). */
#ifndef ZF_MSVC_SCHED_H
#define ZF_MSVC_SCHED_H
#include "pthread.h"
static inline int sched_yield(void) {
  SwitchToThread();
  return 0;
}
#endif
