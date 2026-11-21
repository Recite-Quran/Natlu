#ifndef ZF_ENV_H
#define ZF_ENV_H

/* The ZF_* run-time switches.
 *
 * A development build reads them from the environment, which is how the harnesses A/B a kernel, a
 * pool policy or an accuracy mode without rebuilding. A release build (ZF_RELEASE, which is what an
 * app links) ignores the environment entirely and runs the exact configuration: a stray variable in
 * a host app can then change neither a bit nor a timing. The two switches that define the exact
 * configuration read as set; every other switch reads as unset, which is each one's default. */

#include <stdlib.h>
#include <string.h>

#if defined(ZF_RELEASE) && ZF_RELEASE
#ifndef ZF_QUANT_DIVIDE
#define ZF_QUANT_DIVIDE 1
#elif !ZF_QUANT_DIVIDE
#error "a release build is the exact configuration, which quantises by dividing: ZF_QUANT_DIVIDE must be 1"
#endif
static inline const char *zf_getenv(const char *name) {
  return (!strcmp(name, "ZF_FE_F32") || !strcmp(name, "ZF_CONV_ORT")) ? "1" : NULL;
}
#else
static inline const char *zf_getenv(const char *name) { return getenv(name); }
#endif

#endif
