/* The resampler (zf/resample.h) at every input rate, without a model.
 *
 * Every SDK resamples the microphone's audio to 16 kHz with this before the model sees it, so its
 * output is part of what "the same bits on every device" means. Checked per rate:
 *   - n input samples give exactly ceil(n * 16000 / rate) outputs, and max_out(0) is what finish writes;
 *   - any chunking of the input (random sizes, one sample at a time) is byte for byte one push, and so
 *     is a second run after a reset;
 *   - 16 kHz is passed through untouched;
 *   - silence in is silence out, and an input scaled by 2 gives exactly the output scaled by 2 (every
 *     output is one float dot product, and a power of two scales it without rounding);
 *   - a constant input comes out at the same level (the passband is flat to 0.01 dB);
 *   - a push with too little room consumes nothing, and a push after finish is refused;
 *   - the output for the fixed test signal has the fingerprint written below, which is the same on
 *     every compiler and core (the signal is made of integers, the filter is scalar IEEE arithmetic). */
#include <stdlib.h>
#include <string.h>

#include "zf/resample.h"
#include "zf_test.h"

static const int kRates[] = {8000, 11025, 16000, 22050, 24000, 32000, 44100, 48000};
/* FNV-1a over the float32 output for zf_test_signal(rate / 2 samples, 440 Hz, 1234.5 Hz, seed = rate) */
static const uint64_t kFingerprint[] = {0xcff49b6a19d42b85ull, 0x452490a9c416de38ull, 0x85a0eebf86be6e9bull,
                                        0x9227f1c20912ffddull, 0x6851e4a936110f79ull, 0xd69b1d399820d367ull,
                                        0xe2f8ce4d9b129c8dull, 0x567acb44c8dcf0e8ull};
#define NRATES ((int)(sizeof kRates / sizeof kRates[0]))

/* One run over x in the given chunk sizes (sizes NULL: one push); returns the output length or -1. */
static long run(ZfResampler *r, const float *x, int n, const int *sizes, float *out) {
  long got = 0;
  int at = 0, k = 0;
  while (at < n) {
    int c = sizes ? sizes[k++] : n;
    if (c > n - at) c = n - at;
    const int room = zf_resampler_max_out(r, c);
    const int w = zf_resampler_push(r, x + at, c, out + got, room);
    if (w < 0 || w > room) return -1;
    got += w;
    at += c;
  }
  const int room = zf_resampler_max_out(r, 0);
  const int w = zf_resampler_finish(r, out + got, room);
  if (w != room) return -1; /* max_out(r, 0) is exactly what finish writes */
  return got + w;
}

static void one_rate(int rate, uint64_t fingerprint) {
  const int n = rate / 2;
  float *x = (float *)malloc((size_t)n * sizeof(float));
  int *sizes = (int *)malloc((size_t)n * sizeof(int));
  ZfResampler *r = zf_resampler_create(rate);
  CHECK(x && sizes && r);
  if (!x || !sizes || !r) return;
  const int cap = zf_resampler_max_out(r, n);
  float *ref = (float *)malloc((size_t)cap * sizeof(float)), *y = (float *)malloc((size_t)cap * sizeof(float));
  CHECK(ref && y);
  if (!ref || !y) return;
  zf_test_signal(x, n, rate, 440.0, 1234.5, (uint32_t)rate);

  const long m = run(r, x, n, NULL, ref);
  CHECK(m == ((long)n * 16000 + rate - 1) / rate);
  if (rate == 16000) CHECK(m == n && !memcmp(ref, x, (size_t)n * sizeof(float)));
  const uint64_t h = zf_test_fnv(ZF_TEST_FNV0, ref, (size_t)(m > 0 ? m : 0) * sizeof(float));
  printf("resample %5d: %ld samples, fingerprint %016llx\n", rate, m, (unsigned long long)h);
  CHECK(h == fingerprint);

  /* chunkings: three random patterns, then one sample at a time */
  for (int t = 0; t < 4; ++t) {
    uint32_t s = 777u + (uint32_t)t;
    for (int i = 0; i < n; ++i) {
      const uint32_t u = zf_test_lcg(&s) >> 8;
      sizes[i] = t == 3 ? 1 : (u & 3) == 0 ? 1 : (u & 4) ? 1 + (int)((u >> 3) % 64) : 1 + (int)((u >> 3) % 5000);
    }
    zf_resampler_reset(r);
    const long mm = run(r, x, n, sizes, y);
    CHECK(mm == m);
    CHECK(mm == m && !memcmp(y, ref, (size_t)m * sizeof(float)));
  }

  /* too little room: -1 and nothing consumed, so the same push with room gives the same output */
  zf_resampler_reset(r);
  CHECK(zf_resampler_push(r, x, n, y, 0) == -1);
  const int w = zf_resampler_push(r, x, n, y, cap);
  CHECK(w >= 0 && w <= cap);
  if (w >= 0) {
    const int room = zf_resampler_max_out(r, 0);
    CHECK(room >= 0 && w + room <= cap);
    if (room > 0) CHECK(zf_resampler_finish(r, y + w, room - 1) == -1); /* one short: nothing changes */
    const int tail = zf_resampler_finish(r, y + w, room);
    CHECK(tail == room && w + tail == m && !memcmp(y, ref, (size_t)m * sizeof(float)));
  }
  /* after a finish, a push and a second finish are refused until the reset */
  CHECK(zf_resampler_push(r, x, 1, y, cap) == -1);
  CHECK(zf_resampler_finish(r, y, cap) == -1);

  /* an empty stream: nothing to finish */
  zf_resampler_reset(r);
  CHECK(zf_resampler_max_out(r, 0) == 0 && zf_resampler_finish(r, y, 0) == 0);

  /* twice the input is exactly twice the output */
  for (int i = 0; i < n; ++i) x[i] *= 2.0f;
  zf_resampler_reset(r);
  CHECK(run(r, x, n, NULL, y) == m);
  int scaled = 1;
  for (long i = 0; i < m; ++i) scaled &= y[i] == 2.0f * ref[i];
  CHECK(scaled);

  /* silence in, silence out */
  memset(x, 0, (size_t)n * sizeof(float));
  zf_resampler_reset(r);
  CHECK(run(r, x, n, NULL, y) == m);
  int silent = 1;
  for (long i = 0; i < m; ++i) silent &= y[i] == 0.0f;
  CHECK(silent);

  /* a constant comes out at the same level once the filter has filled (and before it empties) */
  for (int i = 0; i < n; ++i) x[i] = 0.5f;
  zf_resampler_reset(r);
  CHECK(run(r, x, n, NULL, y) == m);
  int level = 1;
  for (long i = 1000; i < m - 1000; ++i) level &= y[i] > 0.499f && y[i] < 0.501f;
  CHECK(m > 2000 && level);

  zf_resampler_destroy(r);
  free(x);
  free(sizes);
  free(ref);
  free(y);
}

int main(void) {
  static const int others[] = {0, 1, 12000, 16001, 96000, -8000};
  for (int i = 0; i < (int)(sizeof others / sizeof others[0]); ++i) CHECK(zf_resampler_create(others[i]) == NULL);
  for (int i = 0; i < NRATES; ++i) one_rate(kRates[i], kFingerprint[i]);
  zf_resampler_destroy(NULL);
  return zf_test_done("resample");
}
