/* See zf/resample.h. Output sample j sits at prototype index n = j * M + D (the prototype runs at
 * L * in_rate; its K * L - 1 taps are centred on D, a whole number), which puts it after input
 * sample m = n / L on polyphase row q = n % L: out[j] = sum over k of h[q + k * L] * in[m - k]. */
#include "zf/resample.h"

#include <limits.h>
#include <stdlib.h>
#include <string.h>

#include "resample_tables.h"

struct ZfResampler {
  int rate;
  int L, M;             /* 16000 / rate in lowest terms */
  const float *tab;     /* the prototype's stored rows, tk taps each (see resample_tables.h) */
  int tl, tk;           /* the prototype's own row count and taps a row */
  int stride;           /* L / tl: 2 where a half rate reads every other tap of a row */
  int taps;             /* tk / stride: taps an output sample takes */
  long long delay;      /* D, in prototype samples */
  float *buf;           /* input samples start .. start + len - 1 are buf[at .. at + len - 1] */
  int at, len, cap;
  long long start;      /* input index of buf[at] */
  long long received;   /* input samples so far */
  long long next;       /* output samples so far */
  int finished;
};

static int gcd(int a, int b) {
  while (b) {
    const int t = a % b;
    a = b;
    b = t;
  }
  return a;
}

ZfResampler *zf_resampler_create(int in_rate) {
  const float *tab;
  int tl, tk;
  switch (in_rate) {
    case 8000: tab = zf_rs_8; tl = ZF_RS_8_L; tk = ZF_RS_8_K; break;
    case 11025: tab = zf_rs_11025; tl = ZF_RS_11025_L; tk = ZF_RS_11025_K; break;
    case 16000: tab = NULL; tl = 1; tk = 1; break;
    case 22050: case 44100: tab = zf_rs_441; tl = ZF_RS_441_L; tk = ZF_RS_441_K; break;
    case 24000: case 48000: tab = zf_rs_48; tl = ZF_RS_48_L; tk = ZF_RS_48_K; break;
    case 32000: tab = zf_rs_32; tl = ZF_RS_32_L; tk = ZF_RS_32_K; break;
    default: return NULL;
  }
  ZfResampler *r = (ZfResampler *)calloc(1, sizeof *r);
  if (!r) return NULL;
  const int g = gcd(16000, in_rate);
  r->rate = in_rate;
  r->L = 16000 / g;
  r->M = in_rate / g;
  r->tab = tab;
  r->tl = tl;
  r->tk = tk;
  /* the prototype a rate uses must run at L * in_rate, at the full rate or the half rate, and a
   * half rate must take whole taps */
  if (r->L % tl || r->L / tl > 2 || tk % (r->L / tl) || (tl > 1 && tl % 2)) {
    free(r);
    return NULL;
  }
  r->stride = r->L / tl;
  r->taps = tk / r->stride;
  r->delay = ((long long)tk * tl - 2) / 2;
  zf_resampler_reset(r);
  if (tab && !r->buf) { /* reset could not allocate the history */
    free(r);
    return NULL;
  }
  return r;
}

void zf_resampler_destroy(ZfResampler *r) {
  if (!r) return;
  free(r->buf);
  free(r);
}

/* The input is zero before its start: taps - 1 zeros of history, so output 0 needs nothing else. */
void zf_resampler_reset(ZfResampler *r) {
  if (!r) return;
  r->received = 0;
  r->next = 0;
  r->finished = 0;
  if (!r->tab) return;
  if (!r->buf) {
    r->cap = 4096;
    while (r->cap < 2 * r->taps) r->cap *= 2;
    r->buf = (float *)malloc((size_t)r->cap * sizeof(float));
    if (!r->buf) return;
  }
  r->at = 0;
  r->len = r->taps - 1;
  memset(r->buf, 0, (size_t)r->len * sizeof(float));
  r->start = -(long long)(r->taps - 1);
}

/* Output samples there are in all once `samples` inputs have ended: ceil(samples * L / M). */
static long long total_out(const ZfResampler *r, long long samples) {
  return (samples * r->L + r->M - 1) / r->M;
}

/* Output samples whose inputs are all in, once `samples` inputs have arrived: those with
 * (j * M + D) / L < samples. */
static long long ready_out(const ZfResampler *r, long long samples) {
  const long long lim = samples * r->L - r->delay; /* j * M < lim */
  return lim > 0 ? (lim + r->M - 1) / r->M : 0;
}

int zf_resampler_max_out(const ZfResampler *r, int n) {
  if (!r || n < 0) return -1;
  if (!r->tab) return n;
  const long long m = total_out(r, r->received + n) - r->next;
  return m > INT_MAX ? INT_MAX : (int)m;
}

static int append(ZfResampler *r, const float *in, int n) {
  if (r->at + r->len + n > r->cap) {
    memmove(r->buf, r->buf + r->at, (size_t)r->len * sizeof(float));
    r->at = 0;
    if (r->len + n > r->cap) {
      int cap = r->cap;
      while (cap < r->len + n) {
        if (cap > INT_MAX / 2) return -1;
        cap *= 2;
      }
      float *b = (float *)realloc(r->buf, (size_t)cap * sizeof(float));
      if (!b) return -1;
      r->buf = b;
      r->cap = cap;
    }
  }
  if (in) memcpy(r->buf + r->at + r->len, in, (size_t)n * sizeof(float));
  else memset(r->buf + r->at + r->len, 0, (size_t)n * sizeof(float));
  r->len += n;
  return 0;
}

/* Outputs next .. until - 1, every input they need present; then the inputs no later output needs
 * are let go. */
static void emit(ZfResampler *r, long long until, float *out) {
  const int L = r->L, M = r->M, s = r->stride, tl = r->tl, tk = r->tk, half = tl / 2;
  for (long long j = r->next; j < until; ++j) {
    const long long n = j * M + r->delay;
    const long long m = n / L;
    const int q = (int)(n % L), row = q % tl, col = q / tl;
    /* h[q + k * L] is tap col + k * s of prototype row `row`. Rows 0 .. tl/2 - 1 are stored, then
     * row tl - 1; a row in between is row tl - 2 - row read backwards. */
    const float *h;
    int step = s;
    if (row < half) h = r->tab + (size_t)row * tk + col;
    else if (row == tl - 1) h = r->tab + (size_t)half * tk + col;
    else {
      h = r->tab + (size_t)(tl - 2 - row) * tk + (tk - 1 - col);
      step = -s;
    }
    const float *x = r->buf + r->at + (m - r->start);
    float acc = 0.0f;
    for (int k = 0; k < r->taps; ++k) acc += h[k * step] * x[-k];
    if (s == 2) acc *= 2.0f; /* half the taps of a filter normalised for twice the rows; exact */
    *out++ = acc;
  }
  r->next = until;
  const long long keep = (r->next * M + r->delay) / L - (r->taps - 1); /* oldest input still needed */
  if (keep > r->start) {
    int drop = (int)(keep - r->start);
    if (drop > r->len) drop = r->len;
    r->at += drop;
    r->len -= drop;
    r->start += drop;
  }
}

int zf_resampler_push(ZfResampler *r, const float *in, int n, float *out, int max_out) {
  if (!r || n < 0 || r->finished || (n && !in)) return -1;
  if (!r->tab) {
    if (max_out < n) return -1;
    if (n) memcpy(out, in, (size_t)n * sizeof(float));
    r->received += n;
    return n;
  }
  if (n == 0) return 0;
  const long long until = ready_out(r, r->received + n);
  const long long got = until - r->next;
  if (got > max_out || got > INT_MAX) return -1;
  if (append(r, in, n)) return -1;
  r->received += n;
  emit(r, until, out);
  return (int)got;
}

int zf_resampler_finish(ZfResampler *r, float *out, int max_out) {
  if (!r || r->finished) return -1;
  if (!r->tab) {
    r->finished = 1;
    return 0;
  }
  const long long until = total_out(r, r->received);
  const long long got = until - r->next;
  if (got > max_out) return -1;
  if (got > 0) {
    /* zeros after the end, as far as the last output reaches */
    const long long last = ((until - 1) * r->M + r->delay) / r->L;
    const long long have = r->start + r->len;
    if (last >= have && append(r, NULL, (int)(last - have + 1))) return -1;
    emit(r, until, out);
  }
  r->finished = 1;
  return (int)got;
}
