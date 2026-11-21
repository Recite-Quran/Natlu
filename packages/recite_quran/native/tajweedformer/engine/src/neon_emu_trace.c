/* Diagnostic for zf/neon_emu.h built with ZFE_TRACE: which engine instructions hand NEON a value that
 * flush to zero changes. Each distinct call site is counted and printed at exit as an offset into
 * its image, for atos or addr2line. Empty in every other build. */
#if defined(ZFE_TRACE)
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define ZFE_SITES 4096
static struct { void *site; long count[5]; } g_sites[ZFE_SITES];
static int g_registered;

static void zfe_trace_dump(void) {
  for (int i = 0; i < ZFE_SITES; ++i) {
    if (!g_sites[i].site) continue;
    Dl_info info;
    uintptr_t off = (uintptr_t)g_sites[i].site;
    const char *image = "?";
    if (dladdr(g_sites[i].site, &info) && info.dli_fbase) {
      off -= (uintptr_t)info.dli_fbase;
      image = info.dli_fname;
    }
    fprintf(stderr, "zfe_flush site 0x%lx %s x4 %ld x2 %ld\n", (unsigned long)off, image,
            g_sites[i].count[4], g_sites[i].count[2]);
  }
}

void zfe_trace_flush(void *site, int kind) {
  if (!g_registered) {
    g_registered = 1;
    atexit(zfe_trace_dump);
  }
  size_t h = ((uintptr_t)site >> 2) % ZFE_SITES;
  while (g_sites[h].site && g_sites[h].site != site) h = (h + 1) % ZFE_SITES;
  g_sites[h].site = site;
  g_sites[h].count[kind]++;
}
#else
typedef int zfe_trace_unused;
#endif
