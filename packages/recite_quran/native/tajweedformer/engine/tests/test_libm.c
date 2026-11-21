/* The engine's own expf, logf and powf (zf/libm.h): exact values, and one fingerprint per function.
 *
 * The engine carries these so that the LogSoftmax of every head, BiasNorm's power and the fbank's log
 * are the same bits on every core, whatever the platform's libm does. Checked here without a model:
 * the values that are exact in floating point, a few whose correctly rounded result is known (the
 * hex literals below are the nearest floats to e, ln 2, 1/e and ln of the fbank's floor), and a
 * fingerprint of each function over a sweep of inputs that are exact in float. A core that rounds
 * differently anywhere in the sweep changes the fingerprint. */
#include <float.h>
#include <string.h>

#include "zf/libm.h"
#include "zf_test.h"

int main(void) {
  CHECK(zf_libm_expf(0.0f) == 1.0f);
  CHECK(zf_libm_logf(1.0f) == 0.0f);
  CHECK(zf_libm_powf(4.0f, -0.5f) == 0.5f);
  CHECK(zf_libm_powf(16.0f, -0.5f) == 0.25f);
  CHECK(zf_libm_powf(2.0f, 10.0f) == 1024.0f);
  CHECK(zf_libm_powf(7.25f, 0.0f) == 1.0f);
  CHECK(zf_libm_powf(1.0f, -0.5f) == 1.0f);

  CHECK(zf_libm_expf(1.0f) == 0x1.5bf0a8p+1f);            /* e */
  CHECK(zf_libm_expf(-1.0f) == 0x1.78b564p-2f);           /* 1 / e */
  CHECK(zf_libm_logf(2.0f) == 0x1.62e43p-1f);             /* ln 2 */
  CHECK(zf_libm_logf(FLT_EPSILON) == -0x1.fe2804p+3f);    /* ln 2^-23, the fbank's floor */
  CHECK(zf_libm_logf(0.5f) == -0x1.62e43p-1f);

  /* expf over [-32, 32) in steps of 1/64, logf over (0, 64] in steps of 1/64, and x^-0.5 (the
   * engine's only powf call) over the same inputs */
  uint64_t he = ZF_TEST_FNV0, hl = ZF_TEST_FNV0, hp = ZF_TEST_FNV0;
  for (int i = 0; i < 4096; ++i) {
    const float e = zf_libm_expf((float)(i - 2048) / 64.0f);
    const float l = zf_libm_logf((float)(i + 1) / 64.0f);
    const float p = zf_libm_powf((float)(i + 1) / 64.0f, -0.5f);
    he = zf_test_fnv(he, &e, sizeof e);
    hl = zf_test_fnv(hl, &l, sizeof l);
    hp = zf_test_fnv(hp, &p, sizeof p);
  }
  printf("expf %016llx logf %016llx powf %016llx\n", (unsigned long long)he, (unsigned long long)hl,
         (unsigned long long)hp);
  CHECK(he == 0x029744ee6cc25458ull);
  CHECK(hl == 0x53592fc00f9b56f7ull);
  CHECK(hp == 0xf31b7dac6cce00daull);
  return zf_test_done("libm");
}
