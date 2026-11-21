/* See zf/fbank.h. A port of kaldi-native-fbank's OnlineFbank for the one configuration the models
 * use; the comments name the kaldi-native-fbank function each piece reproduces. */
#include "zf/fbank.h"

#include <float.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "kiss_fftr.h"
#include "_kiss_fft_guts.h"
#include "zf/libm.h"
#include "fbank_tables.h"

/* kiss_fftr.c keeps this private; the layout is the version's own. */
struct kiss_fftr_state {
  kiss_fft_cfg substate;
  kiss_fft_cpx *tmpbuf;
  kiss_fft_cpx *super_twiddles;
};

struct ZfFbank {
  kiss_fftr_cfg cfg;
  float *rem;          /* waveform_remainder_ */
  int rem_n, rem_cap;
  long long offset;    /* waveform_offset_ */
  int frames;          /* frames produced so far */
  int finished;
};

static float bits(uint32_t u) {
  float f;
  memcpy(&f, &u, 4);
  return f;
}

ZfFbank *zf_fbank_create(void) {
  ZfFbank *f = (ZfFbank *)calloc(1, sizeof *f);
  if (!f) return NULL;
  f->cfg = kiss_fftr_alloc(ZF_FB_PADDED, 0, NULL, NULL);
  if (!f->cfg || f->cfg->substate->nfft != ZF_FB_NCFFT) {
    zf_fbank_destroy(f);
    return NULL;
  }
  /* the twiddles kissfft just took from this device's cos and sin, replaced by the tabled ones */
  for (int i = 0; i < ZF_FB_NCFFT; ++i) {
    f->cfg->substate->twiddles[i].r = bits(zf_fb_twiddles[2 * i]);
    f->cfg->substate->twiddles[i].i = bits(zf_fb_twiddles[2 * i + 1]);
  }
  for (int i = 0; i < ZF_FB_NCFFT / 2; ++i) {
    f->cfg->super_twiddles[i].r = bits(zf_fb_super_twiddles[2 * i]);
    f->cfg->super_twiddles[i].i = bits(zf_fb_super_twiddles[2 * i + 1]);
  }
  /* The factorisation the tables were made for. kissfft fills (radix, remaining length) pairs until
   * the remaining length is 1 and leaves the rest of the array as the allocator gave it, so only
   * the pairs it wrote are compared. */
  for (int i = 0; i + 1 < (int)(sizeof zf_fb_factors / sizeof zf_fb_factors[0]); i += 2) {
    if (f->cfg->substate->factors[i] != zf_fb_factors[i] ||
        f->cfg->substate->factors[i + 1] != zf_fb_factors[i + 1]) {
      zf_fbank_destroy(f);
      return NULL;
    }
    if (zf_fb_factors[i + 1] == 1) break;
  }
  return f;
}

void zf_fbank_destroy(ZfFbank *f) {
  if (!f) return;
  kiss_fftr_free(f->cfg);
  free(f->rem);
  free(f);
}

void zf_fbank_reset(ZfFbank *f) {
  if (!f) return;
  f->rem_n = 0;
  f->offset = 0;
  f->frames = 0;
  f->finished = 0;
}

int zf_fbank_max_frames(int n) { return n / ZF_FBANK_SHIFT + 3; }

/* FirstSampleOfFrame, snip_edges false */
static long long first_sample(int frame) {
  return (long long)ZF_FBANK_SHIFT * frame + ZF_FBANK_SHIFT / 2 - ZF_FB_WINDOW / 2;
}

/* NumFrames, snip_edges false */
static int num_frames(long long samples, int flush) {
  int n = (int)((samples + ZF_FBANK_SHIFT / 2) / ZF_FBANK_SHIFT);
  if (flush) return n;
  long long end = first_sample(n - 1) + ZF_FB_WINDOW;
  while (n > 0 && end > samples) {
    --n;
    end -= ZF_FBANK_SHIFT;
  }
  return n;
}

/* ExtractWindow + ProcessWindow + FbankComputer::Compute for one frame */
static void one_frame(ZfFbank *f, int frame, float *out) {
  float w[ZF_FB_PADDED];
  memset(w, 0, sizeof w);
  const long long start = first_sample(frame);
  const int ws = (int)(start - f->offset), dim = f->rem_n;
  if (ws >= 0 && ws + ZF_FB_WINDOW <= dim) {
    memcpy(w, f->rem + ws, ZF_FB_WINDOW * sizeof(float));
  } else {
    for (int s = 0; s < ZF_FB_WINDOW; ++s) {
      int k = s + ws;
      while (k < 0 || k >= dim) k = k < 0 ? -k - 1 : 2 * dim - 1 - k;
      w[s] = f->rem[k];
    }
  }
  /* RemoveDcOffset */
  float sum = 0;
  for (int i = 0; i != ZF_FB_WINDOW; ++i) sum += w[i];
  const float mean = sum / ZF_FB_WINDOW;
  for (int i = 0; i != ZF_FB_WINDOW; ++i) w[i] -= mean;
  /* Preemphasize, coefficient 0.97 as a float */
  const float pre = 0.97f;
  for (int i = ZF_FB_WINDOW - 1; i > 0; --i) w[i] -= pre * w[i - 1];
  w[0] -= pre * w[0];
  /* FeatureWindowFunction::Apply */
  for (int k = 0; k != ZF_FB_WINDOW; ++k) w[k] *= bits(zf_fb_window[k]);
  /* Rfft::Compute (forward) */
  kiss_fft_cpx spec[ZF_FB_PADDED / 2 + 1];
  kiss_fftr(f->cfg, w, spec);
  float p[ZF_FB_PADDED];
  p[0] = spec[0].r;
  p[1] = spec[ZF_FB_PADDED / 2].r;
  for (int i = 1; i < ZF_FB_PADDED / 2; ++i) {
    p[2 * i] = spec[i].r;
    p[2 * i + 1] = spec[i].i;
  }
  /* ComputePowerSpectrum */
  const float first = p[0] * p[0], last = p[1] * p[1];
  for (int i = 1; i < ZF_FB_PADDED / 2; ++i) {
    const float re = p[i * 2], im = p[i * 2 + 1];
    p[i] = re * re + im * im;
  }
  p[0] = first;
  p[ZF_FB_PADDED / 2] = last;
  /* MelBanks::Compute, then the log with its floor */
  int at = 0;
  for (int b = 0; b < ZF_FB_BINS; ++b) {
    float e = 0;
    for (int k = 0; k != zf_fb_mel_len[b]; ++k) e += bits(zf_fb_mel_weight[at + k]) * p[k + zf_fb_mel_offset[b]];
    at += zf_fb_mel_len[b];
    out[b] = zf_libm_logf(e > FLT_EPSILON ? e : FLT_EPSILON);
  }
}

/* OnlineGenericBaseFeature::ComputeFeatures */
static int compute(ZfFbank *f, float *out, int max_frames) {
  const int want = num_frames(f->offset + f->rem_n, f->finished);
  if (want - f->frames > max_frames) return -1;
  int n = 0;
  for (int frame = f->frames; frame < want; ++frame) one_frame(f, frame, out + (size_t)n++ * ZF_FBANK_BINS);
  f->frames = want;
  const long long discard = first_sample(want) - f->offset;
  if (discard > 0) {
    if (discard >= f->rem_n) {
      f->offset += f->rem_n;
      f->rem_n = 0;
    } else {
      memmove(f->rem, f->rem + discard, (size_t)(f->rem_n - discard) * sizeof(float));
      f->rem_n -= (int)discard;
      f->offset += discard;
    }
  }
  return n;
}

int zf_fbank_accept(ZfFbank *f, const float *samples, int n, float *out, int max_frames) {
  if (!f || n < 0 || f->finished) return -1;
  if (n == 0) return 0;
  if (max_frames < zf_fbank_max_frames(n)) return -1;
  if (f->rem_n + n > f->rem_cap) {
    int cap = f->rem_cap ? f->rem_cap : 4096;
    while (cap < f->rem_n + n) cap *= 2;
    float *r = (float *)realloc(f->rem, (size_t)cap * sizeof(float));
    if (!r) return -1;
    f->rem = r;
    f->rem_cap = cap;
  }
  memcpy(f->rem + f->rem_n, samples, (size_t)n * sizeof(float));
  f->rem_n += n;
  return compute(f, out, max_frames);
}

int zf_fbank_finish(ZfFbank *f, float *out, int max_frames) {
  if (!f) return -1;
  f->finished = 1;
  if (f->rem_n == 0) return 0; /* ExtractWindow needs a non-empty remainder */
  return compute(f, out, max_frames);
}
