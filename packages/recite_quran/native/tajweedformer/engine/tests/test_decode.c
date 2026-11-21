/* The greedy CTC decoder (zf/decode.h) on log-probs with known answers.
 *
 * This is the function under every greedy transcript the SDKs show (zf_tajweed_stream_greedy reads the
 * tokens zf_stream took from it). The rows are written by hand: the winning entry is 0 (posterior
 * exactly 1), the runner-up -1, the rest -4, so the expected tokens, frames, runner-ups and run
 * lengths are known without running anything, and the posteriors are exact in terms of the engine's
 * own expf. Checked: repeats collapse, blanks are dropped, a repeat after a blank is a new token, a
 * tie goes to the lower id, a run that crosses a push is one token, complete-runs mode holds a token
 * until its run ends, and a stream handed over at a position continues with the same tokens. */
#include <string.h>

#include "zf/decode.h"
#include "zf/libm.h"
#include "zf_test.h"

#define V 5
#define BLANK 0

/* one row: `best` at 0, `second` at -1, everything else at -4 */
static void row(float *r, int best, int second) {
  for (int v = 0; v < V; ++v) r[v] = -4.0f;
  r[second] = -1.0f;
  r[best] = 0.0f;
}

/*                    frame:  0  1  2  3  4  5  6  7  8  9 10 */
static const int kBest[] = {0, 2, 2, 0, 2, 3, 3, 3, 0, 0, 1};
static const int kSecond[] = {1, 0, 3, 2, 4, 2, 0, 1, 3, 4, 0};
#define T ((int)(sizeof kBest / sizeof kBest[0]))
/* what greedy CTC must give: token, the frame that emitted it, its run length, its last frame */
static const int kTok[] = {2, 2, 3, 1}, kFrame[] = {1, 4, 5, 10}, kRun[] = {2, 1, 3, 1}, kEnd[] = {2, 4, 7, 10};
#define N ((int)(sizeof kTok / sizeof kTok[0]))

int main(void) {
  float lp[T * V];
  for (int f = 0; f < T; ++f) row(lp + f * V, kBest[f], kSecond[f]);
  const float p1 = zf_libm_expf(0.0f), p2 = zf_libm_expf(-1.0f), p4 = zf_libm_expf(-4.0f);
  CHECK(p1 == 1.0f);

  CHECK(zf_decoder_create(0, 0) == NULL);
  CHECK(zf_decoder_create(V, -1) == NULL);
  CHECK(zf_decoder_create(V, V) == NULL);

  ZfDecoder *d = zf_decoder_create(V, BLANK);
  CHECK(d != NULL);
  if (!d) return zf_test_done("decode");
  ZfToken out[T];

  /* one push */
  int n = zf_decoder_push(d, lp, T, out, T);
  CHECK(n == N);
  for (int i = 0; i < n && i < N; ++i) {
    CHECK(out[i].token == kTok[i]);
    CHECK(out[i].frame == kFrame[i]);
    CHECK(out[i].runner_up == kSecond[kFrame[i]]);
    CHECK(out[i].prob == p1);
    CHECK(out[i].margin == p1 - p2);
    /* the blank's posterior at the emitting frame: the runner-up there, or one of the rest */
    CHECK(out[i].blank == (kSecond[kFrame[i]] == BLANK ? p2 : p4));
    CHECK(out[i].run == 1 && out[i].end_frame == kFrame[i] && out[i].complete == 0);
    CHECK(out[i].peak_prob == p1 && out[i].peak_margin == p1 - p2);
  }
  CHECK(zf_decoder_frames(d) == T);
  long long frames = -1;
  int prev = -1;
  zf_decoder_position(d, &frames, &prev);
  CHECK(frames == T && prev == 1);

  /* every split into two pushes gives the same tokens and frames: a run that crosses the split is
   * one token */
  for (int cut = 1; cut < T; ++cut) {
    zf_decoder_reset(d);
    ZfToken a[T];
    int na = zf_decoder_push(d, lp, cut, a, T);
    na += zf_decoder_push(d, lp + cut * V, T - cut, a + na, T - na);
    CHECK(na == N);
    for (int i = 0; i < na && i < N; ++i) CHECK(a[i].token == kTok[i] && a[i].frame == kFrame[i]);
  }

  /* one frame at a time, with the run of the last token read back as it grows */
  zf_decoder_reset(d);
  int run = -1, got = 0;
  float peak = -1.0f;
  CHECK(zf_decoder_refine(d, &run, &peak) == 0);
  for (int f = 0; f < T; ++f) {
    ZfToken t;
    const int k = zf_decoder_push(d, lp + f * V, 1, &t, 1);
    CHECK(k == 0 || k == 1);
    if (k == 1 && got < N) {
      CHECK(t.token == kTok[got] && t.frame == kFrame[got]);
      ++got;
    }
    if (f == 7) { /* the third token's run is frames 5, 6 and 7 */
      CHECK(zf_decoder_refine(d, &run, &peak) == 1);
      CHECK(run == 3 && peak == p1);
    }
    if (f == 8) CHECK(zf_decoder_refine(d, &run, &peak) == 0); /* a blank ended it */
  }
  CHECK(got == N);

  /* complete runs: a token leaves when its run has ended, with the run's length and last frame */
  zf_decoder_reset(d);
  zf_decoder_set_complete_runs(d, 1);
  n = zf_decoder_push(d, lp, T, out, T);
  CHECK(n == N - 1); /* the last token's run has not ended yet */
  ZfToken last;
  CHECK(zf_decoder_flush(d, &last, 1) == 1);
  CHECK(zf_decoder_flush(d, &last, 1) == 0);
  if (n == N - 1) out[n++] = last;
  for (int i = 0; i < n && i < N; ++i) {
    CHECK(out[i].token == kTok[i] && out[i].frame == kFrame[i]);
    CHECK(out[i].run == kRun[i] && out[i].end_frame == kEnd[i] && out[i].complete == 1);
  }
  zf_decoder_set_complete_runs(d, 0);

  /* a stream handed over after frame 4 (its argmax was 2): frames and the collapse rule carry on */
  zf_decoder_reset(d);
  zf_decoder_set_position(d, 5, 3);
  n = zf_decoder_push(d, lp + 5 * V, T - 5, out, T);
  CHECK(n == 1); /* frames 5 to 7 repeat the 3 the position said was already emitted */
  if (n == 1) CHECK(out[0].token == 1 && out[0].frame == 10);
  zf_decoder_reset(d);
  zf_decoder_set_position(d, 5, 2);
  n = zf_decoder_push(d, lp + 5 * V, T - 5, out, T);
  CHECK(n == 2);
  if (n == 2) CHECK(out[0].token == 3 && out[0].frame == 5 && out[1].token == 1 && out[1].frame == 10);

  /* a tie goes to the lower id, and the other one is the runner-up */
  zf_decoder_reset(d);
  float tie[V] = {-3.0f, -2.0f, -0.5f, -0.5f, -2.0f};
  n = zf_decoder_push(d, tie, 1, out, T);
  CHECK(n == 1);
  if (n == 1) CHECK(out[0].token == 2 && out[0].runner_up == 3 && out[0].margin == 0.0f);

  /* nothing to do */
  CHECK(zf_decoder_push(d, lp, 0, out, T) == 0);
  CHECK(zf_decoder_push(NULL, lp, T, out, T) == 0);
  zf_decoder_destroy(d);
  return zf_test_done("decode");
}
