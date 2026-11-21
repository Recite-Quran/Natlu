#include "zf/libm.h"
#include "zf/decode.h"

#include <math.h>
#include <stdlib.h>

struct ZfDecoder {
  int vocab, blank;
  int prev;            /* the previous frame's argmax, for CTC's collapse rule */
  long long frames;    /* frames consumed since the last reset */
  int last_run;        /* the current run's length, if it is still a real phoneme */
  float last_peak;     /* the highest posterior that run has reached */
  int have_last;
  int complete_runs;   /* hold each phoneme until its run ends */
  int holding;         /* a phoneme is held in `held` */
  ZfToken held;
};

ZfDecoder *zf_decoder_create(int vocab, int blank) {
  if (vocab <= 0 || blank < 0 || blank >= vocab) return NULL;
  ZfDecoder *d = (ZfDecoder *)calloc(1, sizeof(ZfDecoder));
  if (!d) return NULL;
  d->vocab = vocab;
  d->blank = blank;
  d->prev = blank; /* a stream starts as if the frame before it were blank */
  return d;
}

void zf_decoder_destroy(ZfDecoder *d) { free(d); }

void zf_decoder_reset(ZfDecoder *d) {
  if (!d) return;
  d->prev = d->blank;
  d->frames = 0;
  d->last_run = 0;
  d->last_peak = 0.0f;
  d->have_last = 0;
  d->holding = 0;
}

void zf_decoder_set_complete_runs(ZfDecoder *d, int on) {
  if (d) d->complete_runs = on ? 1 : 0;
}

int zf_decoder_flush(ZfDecoder *d, ZfToken *out, int max_out) {
  if (!d || !d->holding || !out || max_out < 1) return 0;
  d->held.complete = 1;
  out[0] = d->held;
  d->holding = 0;
  return 1;
}

long long zf_decoder_frames(const ZfDecoder *d) { return d ? d->frames : 0; }

void zf_decoder_position(const ZfDecoder *d, long long *frames, int *prev) {
  if (frames) *frames = d ? d->frames : 0;
  if (prev) *prev = d ? d->prev : 0;
}

void zf_decoder_set_position(ZfDecoder *d, long long frames, int prev) {
  if (!d) return;
  d->frames = frames;
  d->prev = prev >= 0 && prev < d->vocab ? prev : d->blank;
  d->have_last = 0;
  d->holding = 0;
}

int zf_decoder_refine(const ZfDecoder *d, int *run_out, float *peak_prob_out) {
  if (!d || !d->have_last) return 0;
  if (run_out) *run_out = d->last_run;
  if (peak_prob_out) *peak_prob_out = d->last_peak;
  return 1;
}

int zf_decoder_push(ZfDecoder *d, const float *log_probs, int frames, ZfToken *out, int max_out) {
  if (!d || !log_probs || frames <= 0) return 0;
  const int vocab = d->vocab, blank = d->blank;
  int emitted = 0;
  for (int f = 0; f < frames; ++f) {
    const float *row = log_probs + (size_t)f * vocab;
    /* The best and the runner-up in one pass. The margin between them is the part of a confidence
     * that says whether the model was choosing or guessing, and it costs one comparison. */
    int best = 0, second = -1;
    for (int v = 1; v < vocab; ++v) {
      if (row[v] > row[best]) {
        second = best;
        best = v;
      } else if (second < 0 || row[v] > row[second]) {
        second = v;
      }
    }

    if (best == d->prev) {
      /* the same argmax as the last frame: CTC collapses it, but the run it belongs to is still
       * growing, so keep the peak up to date for a caller that asked to refine */
      if (d->have_last && best != blank) {
        const float p = zf_libm_expf(row[best]);
        ++d->last_run;
        if (p > d->last_peak) d->last_peak = p;
        if (d->holding) {
          d->held.run = d->last_run;
          d->held.end_frame = (int)(d->frames + f);
          if (p > d->held.peak_prob) {
            d->held.peak_prob = p;
            d->held.peak_margin = p - (second >= 0 ? zf_libm_expf(row[second]) : 0.0f);
          }
        }
      }
      continue;
    }

    /* a different argmax ends the run of a held phoneme: it is complete now */
    if (d->holding && out && emitted < max_out) {
      d->held.complete = 1;
      out[emitted++] = d->held;
      d->holding = 0;
    }
    if (best != blank && out && emitted < max_out) {
      const float p = zf_libm_expf(row[best]);
      const float q = second >= 0 ? zf_libm_expf(row[second]) : 0.0f;
      ZfToken t;
      t.token = best;
      t.frame = (int)(d->frames + f);
      t.prob = p;
      t.margin = p - q;
      t.blank = zf_libm_expf(row[blank]);
      t.run = 1;
      t.runner_up = second;
      t.peak_prob = p;
      t.peak_margin = p - q;
      t.end_frame = t.frame;
      t.complete = 0;
      if (d->complete_runs) {
        d->held = t;
        d->holding = 1;
      } else {
        out[emitted++] = t;
      }
      d->have_last = 1;
      d->last_run = 1;
      d->last_peak = p;
    } else if (best == blank) {
      d->have_last = 0; /* the run ended without another phoneme to refine */
    }
    d->prev = best;
  }
  d->frames += frames;
  return emitted;
}
