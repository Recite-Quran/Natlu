/* What every engine test shares: a counting CHECK, an FNV-1a fingerprint, and a test signal made of
 * integers only.
 *
 * The signal has no libm call and no rounding in it (every sample is an integer below 2^23 scaled by
 * a power of two), so it is the same bits on every compiler and core, and a fingerprint of what the
 * engine makes of it can be written down in the test. */
#ifndef ZF_TEST_H
#define ZF_TEST_H

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

static int zf_test_checks, zf_test_fails;

#define CHECK(cond)                                                              \
  do {                                                                           \
    ++zf_test_checks;                                                            \
    if (!(cond)) {                                                               \
      ++zf_test_fails;                                                           \
      fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond);   \
    }                                                                            \
  } while (0)

/* Prints the count and gives main's return value. */
static inline int zf_test_done(const char *name) {
  printf("%s: %d checks, %d failed\n", name, zf_test_checks, zf_test_fails);
  return zf_test_fails != 0;
}

#define ZF_TEST_FNV0 1469598103934665603ull
static inline uint64_t zf_test_fnv(uint64_t h, const void *data, size_t n) {
  const unsigned char *p = (const unsigned char *)data;
  for (size_t i = 0; i < n; ++i) h = (h ^ p[i]) * 1099511628211ull;
  return h;
}

static inline uint32_t zf_test_lcg(uint32_t *state) { return *state = *state * 1664525u + 1013904223u; }

/* A triangle wave from a 32-bit phase, as an integer in [-2^scale, 2^scale]. */
static inline int32_t zf_test_triangle(uint32_t phase, int scale) {
  int32_t v = (int32_t)(phase >> 8);                 /* 0 .. 2^24 - 1 */
  if (v >= (1 << 23)) v = (1 << 24) - v;             /* 0 .. 2^23 */
  return (v - (1 << 22)) >> (22 - scale);            /* -2^scale .. 2^scale */
}

/* n samples in (-1, 1): two triangle waves (f1 and f2 Hz at `rate`) and noise, exact in float. */
static inline void zf_test_signal(float *x, int n, int rate, double f1, double f2, uint32_t seed) {
  const uint32_t inc1 = (uint32_t)(f1 / rate * 4294967296.0), inc2 = (uint32_t)(f2 / rate * 4294967296.0);
  uint32_t ph1 = 0, ph2 = 0, s = seed;
  for (int i = 0; i < n; ++i, ph1 += inc1, ph2 += inc2) {
    const int32_t noise = (int32_t)(zf_test_lcg(&s) >> 12) - (1 << 19); /* -2^19 .. 2^19 - 1 */
    const int32_t num = zf_test_triangle(ph1, 21) + zf_test_triangle(ph2, 20) + noise;
    x[i] = (float)num * (1.0f / 8388608.0f);
  }
}

#endif /* ZF_TEST_H */
