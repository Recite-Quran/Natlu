/* The exact engine behind zf_tajweed.h: a context's engine files, and a stream that keeps every
 * head of the take.
 *
 * The heads come from zf/stream.h: log_probs through the chunk callback, the other eleven outputs
 * through zf_stream_last_output, already filled when the callback runs. Each chunk's rows are
 * appended to one growing array per head, so ZfTajweedHeads points at the whole take; at c16 a
 * chunk adds 8 rows at 40 ms and 16 at 20 ms. Nothing here touches a value: a caller reads the
 * engine's bits. Replaces engine_stub.c in builds that have the engine. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "internal.h"
#include "zf/stream.h"
#include "zf/vfs.h"
#include "zf_tajweed.h"

typedef struct {
  char model_path[1024];
  ZfStreamOptions opt;
  int advance; /* fbank frames per chunk, from the graph's metadata */
} TjEngine;

/* the heads, in ZfTajweedHeads order: name, frames at 20 ms (1) or 40 ms (0), values per frame */
static const struct { const char *name; int fine, cols; } kHeads[] = {
    {"log_probs", 0, 38},     {"inter1_log_probs", 0, 38}, {"inter4_log_probs", 0, 38},
    {"id_log_probs", 1, 38},  {"timing_log_probs", 1, 38}, {"gem", 1, 2},
    {"attr_tafkheem", 1, 3},  {"attr_ghunna", 1, 5},       {"attr_qalqalah", 1, 3},
    {"attr_face", 1, 4},      {"boundary", 1, 1},          {"conf", 1, 1},
};
enum { N_HEADS = (int)(sizeof kHeads / sizeof kHeads[0]) };

struct ZfTajweedStream {
  ZfTajweedModel *m;
  ZfStream *zs;
  ZfTajweedChunkCallback cb;
  void *user;
  float *buf[N_HEADS];
  int rows[2], cap[2]; /* frames kept at 40 ms and 20 ms */
  int have[N_HEADS];   /* the graph has this head */
  unsigned heads;       /* ZF_TAJWEED_HEAD_ bits computed (zf_tajweed_stream_set_heads) */
  ZfTajweedTop2 *top2;  /* the decoded layer, one per 40 ms frame of the take */
  int *greedy;
  int n_greedy, cap_greedy;
  int failed;
  char error[256];
};

/* "meta decode_chunk_len N" from the .zfg text, without opening a session */
static int zfg_advance(const char *zfg_path) {
  /* the in-memory file table first (files rebuilt from a CoreML build, zf/zfs.h), then the disk */
  unsigned char *mem = zf_vfs_copy(zfg_path, NULL);
  if (mem) {
    int v = 0;
    const char *p = (const char *)mem;
    while (p && *p) {
      if (!strncmp(p, "meta decode_chunk_len ", 22)) {
        v = atoi(p + 22);
        break;
      }
      if (!strncmp(p, "node ", 5)) break;
      p = strchr(p, '\n');
      if (p) ++p;
    }
    free(mem);
    return v;
  }
  FILE *f = fopen(zfg_path, "r");
  if (!f) return 0;
  char line[512];
  int v = 0;
  while (fgets(line, sizeof line, f)) {
    if (!strncmp(line, "meta decode_chunk_len ", 22)) {
      v = atoi(line + 22);
      break;
    }
    if (!strncmp(line, "node ", 5)) break;
  }
  fclose(f);
  return v;
}

int zf_tajweed__engine_open(ZfTajweedModel *m, const char *context_dir,
                            const ZfTajweedOpenOptions *o, const char **error) {
  TjEngine *e = (TjEngine *)calloc(1, sizeof *e);
  if (!e) {
    if (error) *error = "out of memory";
    return -1;
  }
  snprintf(e->model_path, sizeof e->model_path, "%s/model_engine2.onnx", context_dir);
  char zfg[1100];
  snprintf(zfg, sizeof zfg, "%s.zfg", e->model_path);
  e->advance = zfg_advance(zfg);
  if (e->advance <= 0) {
    free(e);
    if (error) *error = "the context folder has no engine graph (model_engine2.onnx.zfg)";
    return -1;
  }
  e->opt = zf_stream_default_options();
  e->opt.threads = o ? o->threads : 0;
  e->opt.sample_rate = o ? o->sample_rate : 0;
  e->opt.batch = o && o->batch > 1 ? o->batch : 1;
  e->opt.no_pin = o ? o->no_pin : zf_tajweed_open_default_options().no_pin;
  m->engine = e;
  m->chunk_ms = e->advance * 10;
  return 0;
}

void zf_tajweed__engine_close(ZfTajweedModel *m) {
  if (!m) return;
  free(m->engine);
  m->engine = NULL;
}

static int grow(ZfTajweedStream *s, int fine, int add) {
  const int need = s->rows[fine] + add;
  if (need <= s->cap[fine]) return 0;
  int cap = s->cap[fine] ? s->cap[fine] : 256;
  while (cap < need) cap *= 2;
  for (int h = 0; h < N_HEADS; ++h) {
    if (kHeads[h].fine != fine || !(s->heads & (1u << h))) continue;
    float *p = (float *)realloc(s->buf[h], (size_t)cap * kHeads[h].cols * sizeof(float));
    if (!p) return -1;
    s->buf[h] = p;
  }
  if (!fine) {
    ZfTajweedTop2 *t = (ZfTajweedTop2 *)realloc(s->top2, (size_t)cap * sizeof *t);
    if (!t) return -1;
    s->top2 = t;
  }
  s->cap[fine] = cap;
  return 0;
}

static void fill(const ZfTajweedStream *s, int from40, int from20, int n40, int n20,
                 ZfTajweedHeads *h) {
  memset(h, 0, sizeof *h);
  h->n40 = n40;
  h->n20 = n20;
  h->vocab = ZF_TAJWEED_VOCAB;
  const float **slot[N_HEADS] = {&h->log_probs,     &h->inter1_log_probs, &h->inter4_log_probs,
                                 &h->id_log_probs,  &h->timing_log_probs, &h->gem,
                                 &h->attr_tafkheem, &h->attr_ghunna,      &h->attr_qalqalah,
                                 &h->attr_face,     &h->boundary,         &h->conf};
  for (int k = 0; k < N_HEADS; ++k) {
    if (!s->have[k] || !s->buf[k]) continue;
    const int from = kHeads[k].fine ? from20 : from40;
    *slot[k] = s->buf[k] + (size_t)from * kHeads[k].cols;
  }
}

static void on_chunk(void *user, const float *lp, int frames, int vocab) {
  ZfTajweedStream *s = (ZfTajweedStream *)user;
  if (s->failed) return;
  if (vocab != ZF_TAJWEED_VOCAB) {
    s->failed = 1;
    snprintf(s->error, sizeof s->error, "the engine graph's vocabulary is %d, not 38", vocab);
    return;
  }
  const int fine_frames = 2 * frames;
  if (grow(s, 0, frames) || grow(s, 1, fine_frames)) {
    s->failed = 1;
    snprintf(s->error, sizeof s->error, "out of memory");
    return;
  }
  const int at40 = s->rows[0], at20 = s->rows[1];
  for (int k = 0; k < N_HEADS; ++k) {
    const int rows = kHeads[k].fine ? fine_frames : frames;
    const int at = kHeads[k].fine ? at20 : at40;
    const float *src = lp;
    int r = frames, c = vocab;
    if (!(s->heads & (1u << k))) {
      s->have[k] = 0; /* not asked for, so not computed */
      continue;
    }
    if (k > 0) src = zf_stream_last_output(s->zs, kHeads[k].name, &r, &c);
    if (!src) {
      s->have[k] = 0;
      continue;
    }
    if (r != rows || c != kHeads[k].cols) {
      s->failed = 1;
      snprintf(s->error, sizeof s->error, "head %s is [%d, %d], expected [%d, %d]", kHeads[k].name, r, c,
               rows, kHeads[k].cols);
      return;
    }
    s->have[k] = 1;
    memcpy(s->buf[k] + (size_t)at * kHeads[k].cols, src, (size_t)rows * kHeads[k].cols * sizeof(float));
  }
  zf_tajweed_top2(lp, frames, vocab, s->top2 + at40);
  s->rows[0] += frames;
  s->rows[1] += fine_frames;
  if (s->cb) {
    ZfTajweedHeads h;
    fill(s, at40, at20, frames, fine_frames, &h);
    s->cb(s->user, &h);
  }
}

ZfTajweedStream *zf_tajweed_stream_create(ZfTajweedModel *m, const char **error) {
  if (!m || !m->engine) {
    if (error) *error = "the model was opened without the engine (load_engine 0)";
    return NULL;
  }
  TjEngine *e = (TjEngine *)m->engine;
  ZfTajweedStream *s = (ZfTajweedStream *)calloc(1, sizeof *s);
  if (!s) {
    if (error) *error = "out of memory";
    return NULL;
  }
  s->m = m;
  ZfStreamOptions opt = e->opt;
  opt.on_chunk = on_chunk;
  opt.user = s;
  s->zs = zf_stream_create(e->model_path, &opt, error);
  if (!s->zs) {
    free(s);
    return NULL;
  }
  if (zf_stream_output_count(s->zs) < N_HEADS - 1) {
    zf_stream_destroy(s->zs);
    free(s);
    if (error) *error = "the engine graph lacks the tajweed heads (not a V4 graph)";
    return NULL;
  }
  if (zf_tajweed_stream_set_heads(s, ZF_TAJWEED_HEADS_DEFAULT)) {
    zf_stream_destroy(s->zs);
    free(s);
    if (error) *error = "the engine graph lacks one of the default heads";
    return NULL;
  }
  return s;
}

int zf_tajweed_stream_set_heads(ZfTajweedStream *s, unsigned heads) {
  if (!s || s->rows[0] > 0) return -1;
  heads = (heads & ZF_TAJWEED_HEADS_ALL) | ZF_TAJWEED_HEAD_LOG_PROBS;
  const char *names[N_HEADS];
  int n = 0;
  for (int k = 1; k < N_HEADS; ++k)
    if (heads & (1u << k)) names[n++] = kHeads[k].name;
  if (zf_stream_select_outputs(s->zs, names, n)) return -1;
  s->heads = heads;
  /* the take is empty: drop every kept array, and the next chunk sizes the asked-for ones together */
  s->cap[0] = s->cap[1] = 0;
  for (int k = 0; k < N_HEADS; ++k) {
    free(s->buf[k]);
    s->buf[k] = NULL;
  }
  return 0;
}

unsigned zf_tajweed_stream_get_heads(const ZfTajweedStream *s) { return s ? s->heads : 0; }

/* top-K (API 3) over a kept head, computed now (nothing is ranked as chunks arrive) */
int zf_tajweed_stream_topk(const ZfTajweedStream *s, unsigned head, int k, int *ids, float *values_out,
                           float *margins, int max_frames) {
  if (!s || !ids || max_frames < 0) return -1;
  int h = -1;
  for (int i = 0; i < N_HEADS; ++i)
    if (head == (1u << i)) h = i;
  if (h < 0 || kHeads[h].cols < 2 || k < 1 || k > kHeads[h].cols || !s->have[h] || !s->buf[h]) return -1;
  const int frames = s->rows[kHeads[h].fine];
  const int n = frames < max_frames ? frames : max_frames;
  if (n > 0 && zf_tajweed_topk(s->buf[h], n, kHeads[h].cols, k, ids, values_out, margins) != n) return -1;
  return frames;
}

int zf_tajweed_stream_top2(const ZfTajweedStream *s, const ZfTajweedTop2 **out) {
  if (!s) return -1;
  if (out) *out = s->rows[0] ? s->top2 : NULL;
  return s->rows[0];
}

void zf_tajweed_stream_destroy(ZfTajweedStream *s) {
  if (!s) return;
  zf_stream_destroy(s->zs);
  for (int k = 0; k < N_HEADS; ++k) free(s->buf[k]);
  free(s->top2);
  free(s->greedy);
  free(s);
}

void zf_tajweed_stream_set_callback(ZfTajweedStream *s, ZfTajweedChunkCallback cb, void *user) {
  if (!s) return;
  s->cb = cb;
  s->user = user;
}

void zf_tajweed_stream_reset(ZfTajweedStream *s) {
  if (!s) return;
  zf_stream_reset(s->zs);
  s->rows[0] = s->rows[1] = 0;
  s->n_greedy = 0;
  s->failed = 0;
  s->error[0] = 0;
}

/* the phonemes the engine's decoder handed over, kept as the greedy transcript */
static int keep_tokens(ZfTajweedStream *s, const ZfToken *t, int n) {
  if (n <= 0) return 0;
  if (s->n_greedy + n > s->cap_greedy) {
    int cap = s->cap_greedy ? s->cap_greedy : 256;
    while (cap < s->n_greedy + n) cap *= 2;
    int *p = (int *)realloc(s->greedy, (size_t)cap * sizeof(int));
    if (!p) return -1;
    s->greedy = p;
    s->cap_greedy = cap;
  }
  for (int i = 0; i < n; ++i) s->greedy[s->n_greedy++] = t[i].token;
  return 0;
}

static int drain(ZfTajweedStream *s, int got, const ZfToken *buf) {
  if (got < 0) {
    const char *msg = NULL;
    zf_stream_last_error(s->zs, &msg);
    snprintf(s->error, sizeof s->error, "%s", msg ? msg : "engine error");
    return -1;
  }
  if (keep_tokens(s, buf, got)) return -1;
  ZfToken more[64];
  int n;
  while ((n = zf_stream_read(s->zs, more, 64)) > 0)
    if (keep_tokens(s, more, n)) return -1;
  return s->failed ? -1 : 0;
}

int zf_tajweed_stream_push_audio(ZfTajweedStream *s, const float *samples, int n) {
  if (!s || n < 0 || (n && !samples)) return -1;
  const long long before = zf_stream_chunks(s->zs);
  ZfToken buf[64];
  if (drain(s, zf_stream_push_audio(s->zs, samples, n, buf, 64), buf)) return -1;
  return (int)(zf_stream_chunks(s->zs) - before);
}

int zf_tajweed_stream_finish(ZfTajweedStream *s) {
  if (!s) return -1;
  const long long before = zf_stream_chunks(s->zs);
  ZfToken buf[64];
  if (drain(s, zf_stream_finish_audio(s->zs, buf, 64), buf)) return -1;
  return (int)(zf_stream_chunks(s->zs) - before);
}

int zf_tajweed_stream_heads(const ZfTajweedStream *s, ZfTajweedHeads *out) {
  if (!s || !out) return -1;
  fill(s, 0, 0, s->rows[0], s->rows[1], out);
  return s->rows[0];
}

int zf_tajweed_stream_greedy(const ZfTajweedStream *s, int *ids, int max) {
  if (!s) return -1;
  for (int i = 0; ids && i < s->n_greedy && i < max; ++i) ids[i] = s->greedy[i];
  return s->n_greedy;
}

const char *zf_tajweed_stream_last_error(const ZfTajweedStream *s) {
  return s && s->error[0] ? s->error : NULL;
}
