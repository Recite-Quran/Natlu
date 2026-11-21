/* The slice of POSIX threads the engine and its harnesses use, over Win32, for a Windows build
 * against the Microsoft C runtime (clang targeting x86_64-pc-windows-msvc). MinGW-w64 builds use
 * winpthreads instead and never see this directory (engine/CMakeLists.txt). Threads, mutexes,
 * condition variables and once: scheduling only, no arithmetic. */
#ifndef ZF_MSVC_PTHREAD_H
#define ZF_MSVC_PTHREAD_H
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <process.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct zf_pthread *pthread_t;
typedef struct { int unused; } pthread_attr_t;
typedef SRWLOCK pthread_mutex_t;
typedef struct { int unused; } pthread_mutexattr_t;
typedef CONDITION_VARIABLE pthread_cond_t;
typedef struct { int unused; } pthread_condattr_t;
typedef INIT_ONCE pthread_once_t;

#define PTHREAD_MUTEX_INITIALIZER SRWLOCK_INIT
#define PTHREAD_COND_INITIALIZER CONDITION_VARIABLE_INIT
#define PTHREAD_ONCE_INIT INIT_ONCE_STATIC_INIT

struct zf_pthread {
  HANDLE handle;
  void *(*fn)(void *);
  void *arg;
  void *ret;
};

static unsigned __stdcall zf_pthread_trampoline(void *p) {
  struct zf_pthread *t = (struct zf_pthread *)p;
  t->ret = t->fn(t->arg);
  return 0;
}

static inline int pthread_create(pthread_t *out, const pthread_attr_t *attr, void *(*fn)(void *),
                                 void *arg) {
  (void)attr;
  struct zf_pthread *t = (struct zf_pthread *)calloc(1, sizeof *t);
  if (!t) return 12; /* ENOMEM */
  t->fn = fn;
  t->arg = arg;
  t->handle = (HANDLE)_beginthreadex(NULL, 0, zf_pthread_trampoline, t, 0, NULL);
  if (!t->handle) {
    free(t);
    return 11; /* EAGAIN */
  }
  *out = t;
  return 0;
}

static inline int pthread_join(pthread_t t, void **ret) {
  if (WaitForSingleObject(t->handle, INFINITE) != WAIT_OBJECT_0) return 22; /* EINVAL */
  CloseHandle(t->handle);
  if (ret) *ret = t->ret;
  free(t);
  return 0;
}

static inline int pthread_mutex_init(pthread_mutex_t *m, const pthread_mutexattr_t *a) {
  (void)a;
  InitializeSRWLock(m);
  return 0;
}
static inline int pthread_mutex_destroy(pthread_mutex_t *m) {
  (void)m;
  return 0;
}
static inline int pthread_mutex_lock(pthread_mutex_t *m) {
  AcquireSRWLockExclusive(m);
  return 0;
}
static inline int pthread_mutex_unlock(pthread_mutex_t *m) {
  ReleaseSRWLockExclusive(m);
  return 0;
}

static inline int pthread_cond_init(pthread_cond_t *c, const pthread_condattr_t *a) {
  (void)a;
  InitializeConditionVariable(c);
  return 0;
}
static inline int pthread_cond_destroy(pthread_cond_t *c) {
  (void)c;
  return 0;
}
static inline int pthread_cond_wait(pthread_cond_t *c, pthread_mutex_t *m) {
  return SleepConditionVariableSRW(c, m, INFINITE, 0) ? 0 : 22;
}
static inline int pthread_cond_signal(pthread_cond_t *c) {
  WakeConditionVariable(c);
  return 0;
}
static inline int pthread_cond_broadcast(pthread_cond_t *c) {
  WakeAllConditionVariable(c);
  return 0;
}

static BOOL CALLBACK zf_pthread_once_cb(PINIT_ONCE once, PVOID fn, PVOID *ctx) {
  (void)once;
  (void)ctx;
  void (*f)(void);
  memcpy(&f, &fn, sizeof f);
  f();
  return TRUE;
}
static inline int pthread_once(pthread_once_t *once, void (*fn)(void)) {
  void *p;
  memcpy(&p, &fn, sizeof p);
  return InitOnceExecuteOnce(once, zf_pthread_once_cb, p, NULL) ? 0 : 22;
}

#endif
