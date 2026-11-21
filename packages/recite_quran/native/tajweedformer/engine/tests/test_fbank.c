/* The fbank (zf/fbank.h) without a model: frame counts, streaming, the floor, and a fingerprint.
 *
 * These 80 log mel energies per 10 ms are the model's input, computed from 16 kHz audio by every SDK.
 * Checked:
 *   - n samples give (n + 80) / 160 frames in all (kaldi's count with snip_edges off), for lengths on
 *     both sides of a frame boundary;
 *   - any chunking of the audio (random sizes, one sample at a time) gives the same bits as one call,
 *     and so does a second run after a reset;
 *   - a call with too little room is refused and consumes nothing;
 *   - silence gives the floor in every bin: log(FLT_EPSILON), the nearest float to ln 2^-23;
 *   - the features of the fixed test signal have the fingerprint written below, which is the same on
 *     every compiler and core (the signal is made of integers; the fbank is scalar IEEE arithmetic
 *     with tables for every constant and the engine's own logf). */
#include <stdlib.h>
#include <string.h>

#include "zf/fbank.h"
#include "zf_test.h"

/* FNV-1a over the float32 features of zf_test_signal(32000 samples, 16 kHz, 220 Hz, 1730.25 Hz, seed 16000) */
#define FBANK_FINGERPRINT 0x32753e3bb16b116bull
#define N 32000

/* One run over x in the given chunk sizes (sizes NULL: one call); returns the frames or -1. */
static int run(ZfFbank *f, const float *x, int n, const int *sizes, float *out) {
  int got = 0, at = 0, k = 0;
  while (at < n) {
    int c = sizes ? sizes[k++] : n;
    if (c > n - at) c = n - at;
    const int w = zf_fbank_accept(f, x + at, c, out + (size_t)got * ZF_FBANK_BINS, zf_fbank_max_frames(c));
    if (w < 0) return -1;
    got += w;
    at += c;
  }
  const int w = zf_fbank_finish(f, out + (size_t)got * ZF_FBANK_BINS, zf_fbank_max_frames(0));
  return w < 0 ? -1 : got + w;
}

int main(void) {
  CHECK(ZF_FBANK_BINS == 80 && ZF_FBANK_SHIFT == 160);
  float *x = (float *)malloc(N * sizeof(float));
  int *sizes = (int *)malloc(N * sizeof(int));
  const size_t cap = (size_t)(N / ZF_FBANK_SHIFT + 8) * ZF_FBANK_BINS;
  float *ref = (float *)malloc(cap * sizeof(float)), *y = (float *)malloc(cap * sizeof(float));
  ZfFbank *f = zf_fbank_create();
  CHECK(x && sizes && ref && y && f);
  if (!x || !sizes || !ref || !y || !f) return zf_test_done("fbank");
  zf_test_signal(x, N, 16000, 220.0, 1730.25, 16000u);

  /* the frame count, at lengths around a frame boundary */
  static const int lens[] = {1, 79, 80, 81, 159, 160, 239, 240, 241, 400, 15999, 16000, 16080, N};
  for (int i = 0; i < (int)(sizeof lens / sizeof lens[0]); ++i) {
    zf_fbank_reset(f);
    CHECK(run(f, x, lens[i], NULL, y) == (lens[i] + 80) / 160);
  }
  /* no audio at all: no frame */
  zf_fbank_reset(f);
  CHECK(zf_fbank_finish(f, y, zf_fbank_max_frames(0)) == 0);

  zf_fbank_reset(f);
  const int frames = run(f, x, N, NULL, ref);
  CHECK(frames == 200);
  const size_t bytes = (size_t)(frames > 0 ? frames : 0) * ZF_FBANK_BINS * sizeof(float);
  const uint64_t h = zf_test_fnv(ZF_TEST_FNV0, ref, bytes);
  printf("fbank: %d frames, fingerprint %016llx\n", frames, (unsigned long long)h);
  CHECK(h == FBANK_FINGERPRINT);

  /* chunkings: three random patterns, then one sample at a time; and a fresh fbank */
  for (int t = 0; t < 4; ++t) {
    uint32_t s = 4242u + (uint32_t)t;
    for (int i = 0; i < N; ++i) {
      const uint32_t u = zf_test_lcg(&s) >> 8;
      sizes[i] = t == 3 ? 1 : (u & 3) == 0 ? 1 : (u & 4) ? 1 + (int)((u >> 3) % 64) : 1 + (int)((u >> 3) % 3000);
    }
    zf_fbank_reset(f);
    const int got = run(f, x, N, sizes, y);
    CHECK(got == frames);
    CHECK(got == frames && !memcmp(y, ref, bytes));
  }
  ZfFbank *g = zf_fbank_create();
  CHECK(g != NULL);
  if (g) {
    const int got = run(g, x, N, NULL, y);
    CHECK(got == frames && !memcmp(y, ref, bytes));
    zf_fbank_destroy(g);
  }

  /* too little room: -1 and nothing consumed */
  zf_fbank_reset(f);
  CHECK(zf_fbank_accept(f, x, N, y, zf_fbank_max_frames(N) - 1) == -1);
  int got = zf_fbank_accept(f, x, N, y, zf_fbank_max_frames(N));
  CHECK(got >= 0);
  if (got >= 0) {
    const int tail = zf_fbank_finish(f, y + (size_t)got * ZF_FBANK_BINS, zf_fbank_max_frames(0));
    CHECK(got + tail == frames && !memcmp(y, ref, bytes));
  }
  /* after a finish, accept is refused until the reset */
  CHECK(zf_fbank_accept(f, x, 160, y, zf_fbank_max_frames(160)) == -1);

  /* silence: every bin of every frame is the floor */
  memset(x, 0, N * sizeof(float));
  zf_fbank_reset(f);
  got = run(f, x, N, NULL, y);
  CHECK(got == frames);
  int floor_everywhere = 1;
  for (size_t i = 0; i < (size_t)(got > 0 ? got : 0) * ZF_FBANK_BINS; ++i) floor_everywhere &= y[i] == -0x1.fe2804p+3f;
  CHECK(floor_everywhere);

  zf_fbank_destroy(f);
  zf_fbank_destroy(NULL);
  free(x);
  free(sizes);
  free(ref);
  free(y);
  return zf_test_done("fbank");
}
