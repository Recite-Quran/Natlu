/* zf_stream: see zf/stream.h. The same session, state carry and decoder as bench/accel/zf_set.c,
 * behind a push interface, with the front end's prefetch scheduled from the arriving frames. */
#include "zf/stream.h"

#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#if defined(_WIN32)
#include "zf/win32_compat.h" /* setenv */
#endif

#include "onnxruntime_c_api.h"
#include "zf/env.h"
#include "zf/fbank.h"
#include "zf/resample.h"
#include "zf/sha256.h"
#include "zf/vfs.h"
#include "zf/zfs.h"
#include "zf/layer.h"
#include "zf/ort_ops.h"

#define BINS 80

struct ZfStream {
  const OrtApi *ort;
  OrtEnv *env;
  OrtSessionOptions *opts;
  ZfSession *zs; /* the ops' kernels: pool, weights, layers, front end; this stream's alone */
  OrtSession *session;
  OrtMemoryInfo *mem;
  size_t n_in, n_out;
  char **in_names, **out_names;
  int64_t **in_shapes;
  size_t *in_dims;
  ONNXTensorElementDataType *in_types;
  void **state;
  size_t *state_bytes;
  OrtValue **in_vals, **out_vals;
  int x_index, logits_index;
  ZfChunkCallback on_chunk;
  void *user;
  int window, advance, vocab, lead, complete_runs;
  float *pending; /* frames received and not yet consumed, oldest first */
  int n_pending, cap_pending, prefetched;
  float *last_logp;
  int last_frames;
  long long chunks;
  ZfDecoder *decoder;
  ZfFbank *fbank;
  float *feat;  /* fbank output scratch */
  int feat_cap; /* in frames */
  /* Phonemes decoded and not yet handed to the caller, oldest first. A push hands over what fits
   * in the caller's buffer and keeps the rest here; nothing the decoder emits is ever dropped. */
  ZfToken *queue;
  int q_head, q_len, q_cap;
  ZfToken *chunk_tokens; /* one chunk's decode, at most its frame count */
  int chunk_tokens_cap;
  ZfStatus last_error;
  const char *last_message;
  int sample_rate;
  char weights_sha[65]; /* hex; empty until known */
  struct StateEntry *states; /* the carried state by name, built on first use */
  int n_states;
  long long pos_frames;      /* a position imported before the decoder existed */
  int pos_prev, pos_pending;
  ZfResampler *rs;       /* the input to 16 kHz, when the audio comes at another rate */
  float *rs_buf;
  int rs_cap;
  int batch; /* chunks run together (ZfStreamOptions.batch); 1 runs each as it completes */
  float *bx; /* the queued windows, [batch][window][BINS] */
  int nb;    /* windows queued */
  /* The outputs a Run asks for: log_probs, every new_<state> with its input, and the evidence taps
   * when there is an evidence callback. An output the stream does not know is never asked for. */
  const char **req_names;
  int *req_input; /* the input a new_<state> carries into, or -1 */
  size_t n_req;
  int req_logp, req_tap[4];
  OrtValue **bouts; /* a batch's outputs, [chunk][n_req] */
  /* evidence (ZfStreamOptions.on_evidence) */
  ZfEvidenceCallback on_evidence;
  float *ev_lse;
  int ev_lse_cap;
  float *ev_samples;  /* 16 kHz samples not yet handed to a chunk, the first at ev_base */
  long long ev_base;  /* in samples since the reset */
  int ev_n, ev_cap;
  float ev_floor;     /* the running noise floor's power, -1 before the first 10 ms */
  int blank;          /* the graph's blank_id, or -1 for the vocabulary's last id */
  /* Every other output the graph has (V4's tajweed heads: inter1_log_probs, timing_log_probs,
   * gem, ...): asked for on every Run and kept for the last chunk, by name. */
  struct ExtraOut {
    const char *name;
    int req;           /* index into req_names, -1 while not asked for */
    int on;            /* asked for (zf_stream_select_outputs); all are by default */
    float *data;       /* the last chunk's values */
    int rows, cols, cap;
  } *extra;
  int n_extra;
};

#define ZF_FLUSH_SAMPLES 16800

/* the evidence taps a graph may carry (tools/zftaps.py), in ZfEvidence's order */
static const char *const kTapNames[4] = {"tap_stack0", "tap_stack1", "tap_enc", "tap_logits"};
enum { TAP_STACK0, TAP_STACK1, TAP_ENC, TAP_LOGITS };

static int fail(ZfStream *s, ZfStatus code, const char *message);
static void hex32(const unsigned char d[32], char out[65]);

ZfStreamOptions zf_stream_default_options(void) {
  ZfStreamOptions o = {sizeof(ZfStreamOptions), NULL, NULL, 0, 1, 0, 0, 1, NULL, 0, ZF_NO_PIN_DEFAULT};
  return o;
}

static int take(const OrtApi *ort, OrtStatus *st, const char **error, const char *what) {
  if (!st) return 1;
  static char msg[512];
  snprintf(msg, sizeof msg, "%s: %s", what, ort->GetErrorMessage(st));
  ort->ReleaseStatus(st);
  if (error) *error = msg;
  return 0;
}

static int meta_int(const OrtApi *ort, OrtModelMetadata *md, OrtAllocator *alloc, const char *key) {
  char *val = NULL;
  OrtStatus *st = ort->ModelMetadataLookupCustomMetadataMap(md, alloc, key, &val);
  if (st) {
    ort->ReleaseStatus(st);
    return 0;
  }
  if (!val) return 0;
  const int v = atoi(val);
  alloc->Free(alloc, val);
  return v > 0 ? v : 0;
}

void zf_stream_destroy(ZfStream *s) {
  if (!s) return;
  const OrtApi *ort = s->ort;
  for (size_t i = 0; i < s->n_in; ++i) {
    if (s->state) free(s->state[i]);
    if (s->in_shapes) free(s->in_shapes[i]);
  }
  free(s->state);
  free(s->state_bytes);
  free(s->in_shapes);
  free(s->in_dims);
  free(s->in_types);
  free(s->in_vals);
  free(s->out_vals);
  OrtAllocator *alloc = NULL;
  if (ort && !ort->GetAllocatorWithDefaultOptions(&alloc) && alloc) {
    for (size_t i = 0; s->in_names && i < s->n_in; ++i)
      if (s->in_names[i]) alloc->Free(alloc, s->in_names[i]);
    for (size_t o = 0; s->out_names && o < s->n_out; ++o)
      if (s->out_names[o]) alloc->Free(alloc, s->out_names[o]);
  }
  free(s->in_names);
  free(s->out_names);
  free(s->req_names);
  free(s->req_input);
  free(s->bouts);
  free(s->ev_lse);
  free(s->ev_samples);
  free(s->pending);
  free(s->bx);
  free(s->queue);
  free(s->chunk_tokens);
  zf_resampler_destroy(s->rs);
  free(s->states);
  free(s->rs_buf);
  free(s->last_logp);
  for (int e = 0; e < s->n_extra; ++e) free(s->extra[e].data);
  free(s->extra);
  zf_decoder_destroy(s->decoder);
  zf_fbank_destroy(s->fbank);
  free(s->feat);
  if (ort) {
    if (s->mem) ort->ReleaseMemoryInfo(s->mem);
    if (s->session) ort->ReleaseSession(s->session);
    if (s->opts) ort->ReleaseSessionOptions(s->opts);
    zf_ort_session_destroy(s->zs); /* after the ORT session whose kernels used it */
    if (s->env) ort->ReleaseEnv(s->env);
  }
  free(s);
}

/* What each Run asks for, in req_names order: log_probs, every new_<state> (with the input it carries
 * into), the evidence taps when there is an evidence callback, and the other outputs (V4's heads)
 * that are switched on. zf_rt computes only the nodes these need (accel/src/zf_rt.c, the live set),
 * so a head nobody asked for costs nothing, and one asked for costs exactly its own nodes. `first`
 * collects the other outputs into `extra`, all on, which is the 1.x behaviour. */
static void build_requests(ZfStream *s, int first) {
  s->n_req = 0;
  for (int k = 0; k < 4; ++k) s->req_tap[k] = -1;
  int e = 0;
  for (size_t o = 0; o < s->n_out; ++o) {
    const char *name = s->out_names[o];
    int input = -1, tap = -1, is_tap = 0;
    if (!strncmp(name, "new_", 4))
      for (size_t i = 0; i < s->n_in; ++i)
        if (!strcmp(name + 4, s->in_names[i])) input = (int)i;
    for (int k = 0; k < 4; ++k)
      if (!strcmp(name, kTapNames[k])) {
        is_tap = 1;
        if (s->on_evidence) tap = k;
      }
    if ((int)o != s->logits_index && input < 0 && !is_tap && strncmp(name, "new_", 4) != 0) {
      struct ExtraOut *x = &s->extra[first ? s->n_extra++ : e];
      ++e;
      if (first) {
        x->name = name;
        x->on = 1;
      }
      x->req = -1;
      if (!x->on) continue;
      x->req = (int)s->n_req;
      s->req_input[s->n_req] = -1;
      s->req_names[s->n_req++] = name;
      continue;
    }
    if ((int)o != s->logits_index && input < 0 && tap < 0) continue;
    if ((int)o == s->logits_index) s->req_logp = (int)s->n_req;
    if (tap >= 0) s->req_tap[tap] = (int)s->n_req;
    s->req_input[s->n_req] = input;
    s->req_names[s->n_req++] = name;
  }
}

int zf_stream_select_outputs(ZfStream *s, const char *const *names, int n) {
  if (!s || (n > 0 && !names)) return -1;
  if (s->nb) return -1; /* queued chunks run with what they were queued with: flush first */
  for (int e = 0; e < s->n_extra; ++e) {
    int on = n < 0;
    for (int i = 0; i < n && !on; ++i) on = names[i] && !strcmp(names[i], s->extra[e].name);
    s->extra[e].on = on;
  }
  for (int i = 0; i < n; ++i) { /* an unknown name is the caller's mistake, said so */
    int known = 0;
    for (int e = 0; e < s->n_extra && !known; ++e) known = !strcmp(names[i], s->extra[e].name);
    if (!known) return -1;
  }
  build_requests(s, 0);
  return 0;
}

int zf_stream_output_selected(const ZfStream *s, const char *name) {
  if (!s || !name) return 0;
  for (int e = 0; e < s->n_extra; ++e)
    if (!strcmp(s->extra[e].name, name)) return s->extra[e].on;
  return 0;
}

ZfStream *zf_stream_create(const char *model_path, const ZfStreamOptions *options,
                           const char **error) {
  /* read only as much of the caller's options as its header had; the rest keep their defaults */
  ZfStreamOptions opt = zf_stream_default_options();
  if (options) {
    size_t n = options->struct_size ? options->struct_size : sizeof opt;
    if (n > sizeof opt) n = sizeof opt;
    memcpy(&opt, options, n);
    opt.struct_size = sizeof opt;
  }
  if (opt.chunk_ms != 0 && opt.chunk_ms != 160 && opt.chunk_ms != 320 && opt.chunk_ms != 480) {
    if (error) *error = "chunk_ms must be 0 (the model's own), 160, 320 or 480";
    return NULL;
  }
  /* another chunk length runs its own graph, MODEL.c<ms>.onnx next to MODEL.onnx, when there is
   * one; the model's own length is the graph at model_path, checked once its geometry is read */
  char chunk_path[1024];
  if (opt.chunk_ms && model_path) {
    const char *dot = strrchr(model_path, '.');
    const int stem = dot && !strchr(dot, '/') ? (int)(dot - model_path) : (int)strlen(model_path);
    snprintf(chunk_path, sizeof chunk_path, "%.*s.c%d.onnx", stem, model_path, opt.chunk_ms);
    char zfg[1100];
    snprintf(zfg, sizeof zfg, "%s.zfg", chunk_path);
    unsigned char *mem = zf_vfs_copy(zfg, NULL);
    FILE *probe = mem ? NULL : fopen(zfg, "rb");
    /* a byte read, not the open alone: without a file system (Emscripten's FILESYSTEM=0, the
     * wasm/ build) fopen succeeds on any path, and the model's own length would ask for a graph
     * that is not there */
    if (mem || (probe && fgetc(probe) != EOF)) model_path = chunk_path;
    free(mem);
    if (probe) fclose(probe);
  }
  ZfStream *s = (ZfStream *)calloc(1, sizeof *s);
  if (!s) {
    if (error) *error = "out of memory";
    return NULL;
  }
  s->ort = OrtGetApiBase()->GetApi(ORT_API_VERSION);
  const OrtApi *ort = s->ort;
  if (!ort) {
    if (error) *error = "runtime API version unsupported";
    free(s);
    return NULL;
  }
  s->lead = opt.prefetch_lead < 0 ? 0 : opt.prefetch_lead;
  s->batch = opt.batch > 1 ? (opt.batch > 64 ? 64 : opt.batch) : 1;
  s->complete_runs = opt.complete_runs ? 1 : 0;
  s->sample_rate = opt.sample_rate ? opt.sample_rate : 16000;
  if (opt.sample_rate && opt.sample_rate != 16000) {
    s->rs = zf_resampler_create(opt.sample_rate);
    if (!s->rs) {
      if (error) *error = "unsupported sample rate";
      free(s);
      return NULL;
    }
  }
  s->on_chunk = opt.on_chunk;
  s->on_evidence = opt.on_evidence;
  s->user = opt.user;
  /* The exact engine: the front end's convolutions in fp32 and ONNX Runtime's summation order, the
   * configuration every conformance fingerprint is taken in. A release build is always in it (see
   * zf/env.h); a development build reads the switches from the environment, and a caller that set
   * them itself keeps its choice. */
#if !(defined(ZF_RELEASE) && ZF_RELEASE)
  setenv("ZF_FE_F32", "1", 0);
  setenv("ZF_CONV_ORT", "1", 0);
#endif

  /* the weight files the graph names sit next to it */
  char dir[1024];
  snprintf(dir, sizeof dir, "%s", model_path);
  char *slash = strrchr(dir, '/');
  if (slash) *slash = 0;
  else dir[0] = 0;
  if (!take(ort, ort->CreateEnv(ORT_LOGGING_LEVEL_ERROR, "zf", &s->env), error, "env") ||
      !take(ort, ort->CreateSessionOptions(&s->opts), error, "options") ||
      !take(ort, ort->SetIntraOpNumThreads(s->opts, 1), error, "options") ||
      !take(ort, ort->SetInterOpNumThreads(s->opts, 1), error, "options") ||
      !take(ort, zf_ort_register_session_pinned(ort, s->opts, opt.threads, !opt.no_pin, &s->zs), error, "register")) {
    zf_stream_destroy(s);
    return NULL;
  }
  zf_ort_session_set_weights_dir(s->zs, dir);
  if (!take(ort, ort->CreateSession(s->env, model_path, s->opts, &s->session), error, "session") ||
      !take(ort, ort->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &s->mem), error,
            "memory")) {
    zf_stream_destroy(s);
    return NULL;
  }

  OrtAllocator *alloc = NULL;
  if (!take(ort, ort->GetAllocatorWithDefaultOptions(&alloc), error, "allocator") ||
      !take(ort, ort->SessionGetInputCount(s->session, &s->n_in), error, "inputs") ||
      !take(ort, ort->SessionGetOutputCount(s->session, &s->n_out), error, "outputs")) {
    zf_stream_destroy(s);
    return NULL;
  }
  s->in_names = (char **)calloc(s->n_in, sizeof(char *));
  s->out_names = (char **)calloc(s->n_out, sizeof(char *));
  s->in_vals = (OrtValue **)calloc(s->n_in, sizeof(OrtValue *));
  s->out_vals = (OrtValue **)calloc(s->n_out, sizeof(OrtValue *));
  s->in_shapes = (int64_t **)calloc(s->n_in, sizeof(int64_t *));
  s->in_dims = (size_t *)calloc(s->n_in, sizeof(size_t));
  s->in_types = (ONNXTensorElementDataType *)calloc(s->n_in, sizeof(ONNXTensorElementDataType));
  s->state = (void **)calloc(s->n_in, sizeof(void *));
  s->state_bytes = (size_t *)calloc(s->n_in, sizeof(size_t));
  if (!s->in_names || !s->out_names || !s->in_vals || !s->out_vals || !s->in_shapes ||
      !s->in_dims || !s->in_types || !s->state || !s->state_bytes) {
    if (error) *error = "out of memory";
    zf_stream_destroy(s);
    return NULL;
  }
  s->x_index = s->logits_index = -1;
  for (size_t i = 0; i < s->n_in; ++i) {
    OrtTypeInfo *ti = NULL;
    const OrtTensorTypeAndShapeInfo *si = NULL;
    if (!take(ort, ort->SessionGetInputName(s->session, i, alloc, &s->in_names[i]), error, "input") ||
        !take(ort, ort->SessionGetInputTypeInfo(s->session, i, &ti), error, "input") ||
        !take(ort, ort->CastTypeInfoToTensorInfo(ti, &si), error, "input") ||
        !take(ort, ort->GetTensorElementType(si, &s->in_types[i]), error, "input") ||
        !take(ort, ort->GetDimensionsCount(si, &s->in_dims[i]), error, "input")) {
      if (ti) ort->ReleaseTypeInfo(ti);
      zf_stream_destroy(s);
      return NULL;
    }
    s->in_shapes[i] = (int64_t *)calloc(s->in_dims[i] ? s->in_dims[i] : 1, sizeof(int64_t));
    take(ort, ort->GetDimensions(si, s->in_shapes[i], s->in_dims[i]), NULL, "");
    ort->ReleaseTypeInfo(ti);
    size_t elems = 1;
    for (size_t d = 0; d < s->in_dims[i]; ++d) {
      if (s->in_shapes[i][d] <= 0) s->in_shapes[i][d] = 1;
      elems *= (size_t)s->in_shapes[i][d];
    }
    s->state_bytes[i] = elems * (s->in_types[i] == ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64 ? 8 : 4);
    s->state[i] = calloc(1, s->state_bytes[i]);
    if (!s->state[i]) {
      if (error) *error = "out of memory";
      zf_stream_destroy(s);
      return NULL;
    }
    if (!strcmp(s->in_names[i], "x")) s->x_index = (int)i;
  }
  for (size_t o = 0; o < s->n_out; ++o) {
    if (!take(ort, ort->SessionGetOutputName(s->session, o, alloc, &s->out_names[o]), error,
              "output")) {
      zf_stream_destroy(s);
      return NULL;
    }
    if (!strcmp(s->out_names[o], "log_probs")) s->logits_index = (int)o;
  }
  {
    OrtModelMetadata *md = NULL;
    if (take(ort, ort->SessionGetModelMetadata(s->session, &md), NULL, "")) {
      s->window = meta_int(ort, md, alloc, "T");
      s->advance = meta_int(ort, md, alloc, "decode_chunk_len");
      /* blank_id: a number (0 for V4) or "last" (v3.x, b8): the vocabulary's last id */
      char *bv = NULL;
      s->blank = -1;
      OrtStatus *bst = ort->ModelMetadataLookupCustomMetadataMap(md, alloc, "blank_id", &bv);
      if (bst) ort->ReleaseStatus(bst);
      else if (bv) {
        if (bv[0] >= '0' && bv[0] <= '9') s->blank = atoi(bv);
        alloc->Free(alloc, bv);
      }
      ort->ReleaseModelMetadata(md);
    }
  }
  if (s->x_index < 0 || s->logits_index < 0 || s->window <= 0 || s->advance <= 0 ||
      s->advance > s->window) {
    if (error) *error = "the graph lacks x, log_probs, T or decode_chunk_len";
    zf_stream_destroy(s);
    return NULL;
  }
  if (opt.chunk_ms && s->advance * 10 != opt.chunk_ms) {
    if (error) *error = "the model has no graph for this chunk length (MODEL.c<ms>.onnx)";
    zf_stream_destroy(s);
    return NULL;
  }
  /* what each Run asks for; anything else the graph outputs is ignored */
  s->req_names = (const char **)calloc(s->n_out, sizeof(char *));
  s->req_input = (int *)calloc(s->n_out, sizeof(int));
  if (!s->req_names || !s->req_input) {
    if (error) *error = "out of memory";
    zf_stream_destroy(s);
    return NULL;
  }
  for (int k = 0; k < 4; ++k) s->req_tap[k] = -1;
  s->extra = (struct ExtraOut *)calloc(s->n_out, sizeof *s->extra);
  if (!s->extra) {
    if (error) *error = "out of memory";
    zf_stream_destroy(s);
    return NULL;
  }
  build_requests(s, 1);
  s->cap_pending = 4 * s->window;
  s->pending = (float *)malloc((size_t)s->cap_pending * BINS * sizeof(float));
  if (!s->pending) {
    if (error) *error = "out of memory";
    zf_stream_destroy(s);
    return NULL;
  }
  s->fbank = zf_fbank_create();
  if (!s->fbank) {
    if (error) *error = "cannot start the fbank";
    zf_stream_destroy(s);
    return NULL;
  }
  zf_stream_reset(s);
  if (error) *error = NULL;
  return s;
}

void zf_stream_reset(ZfStream *s) {
  if (!s) return;
  for (size_t i = 0; i < s->n_in; ++i) memset(s->state[i], 0, s->state_bytes[i]);
  zf_ort_session_reset(s->zs);
  if (s->decoder) zf_decoder_reset(s->decoder);
  s->n_pending = 0;
  s->q_head = s->q_len = 0;
  s->pos_pending = 0;
  s->last_error = ZF_OK;
  s->last_message = NULL;
  s->prefetched = 0;
  s->last_frames = 0;
  s->chunks = 0;
  s->nb = 0;
  s->ev_base = 0;
  s->ev_n = 0;
  s->ev_floor = -1.0f;
  if (s->fbank) zf_fbank_reset(s->fbank);
  if (s->rs) zf_resampler_reset(s->rs);
}

int zf_stream_window(const ZfStream *s) { return s ? s->window : 0; }
long long zf_stream_chunks(const ZfStream *s) { return s ? s->chunks : 0; }
int zf_stream_advance(const ZfStream *s) { return s ? s->advance : 0; }

const float *zf_stream_last_log_probs(const ZfStream *s, int *frames, int *vocab) {
  if (frames) *frames = s ? s->last_frames : 0;
  if (vocab) *vocab = s ? s->vocab : 0;
  return s && s->last_frames ? s->last_logp : NULL;
}

int zf_stream_output_count(const ZfStream *s) { return s ? s->n_extra : 0; }

int zf_stream_threads_active(const ZfStream *s) { return s ? zf_ort_session_team(s->zs) : 0; }

const char *zf_stream_output_name(const ZfStream *s, int index) {
  return s && index >= 0 && index < s->n_extra ? s->extra[index].name : NULL;
}

const float *zf_stream_last_output(const ZfStream *s, const char *name, int *rows, int *cols) {
  if (rows) *rows = 0;
  if (cols) *cols = 0;
  if (!s || !name || !s->last_frames) return NULL;
  for (int e = 0; e < s->n_extra; ++e)
    if (!strcmp(s->extra[e].name, name)) {
      if (!s->extra[e].on || !s->extra[e].rows) return NULL; /* not computed for the last chunk */
      if (rows) *rows = s->extra[e].rows;
      if (cols) *cols = s->extra[e].cols;
      return s->extra[e].data;
    }
  return NULL;
}

static int enqueue(ZfStream *s, const ZfToken *t, int n) {
  if (n <= 0) return 1;
  if (s->q_head > 0 && s->q_head + s->q_len + n > s->q_cap) {
    memmove(s->queue, s->queue + s->q_head, (size_t)s->q_len * sizeof(ZfToken));
    s->q_head = 0;
  }
  if (s->q_len + n > s->q_cap) {
    int cap = s->q_cap ? s->q_cap : 64;
    while (cap < s->q_len + n) cap *= 2;
    ZfToken *q = (ZfToken *)realloc(s->queue, (size_t)cap * sizeof(ZfToken));
    if (!q) return 0;
    s->queue = q;
    s->q_cap = cap;
  }
  memcpy(s->queue + s->q_head + s->q_len, t, (size_t)n * sizeof(ZfToken));
  s->q_len += n;
  return 1;
}

int zf_stream_pending(const ZfStream *s) { return s ? s->q_len : 0; }

int zf_stream_read(ZfStream *s, ZfToken *out, int max_out) {
  if (!s || max_out < 0 || (max_out && !out)) return -1;
  const int n = s->q_len < max_out ? s->q_len : max_out;
  memcpy(out, s->queue + s->q_head, (size_t)n * sizeof(ZfToken));
  s->q_head += n;
  s->q_len -= n;
  if (s->q_len == 0) s->q_head = 0;
  return n;
}

/* ---------------------------------------------------------------- evidence */

/* The upper edge in Hz of each of the fbank's 80 mel bins (20 to 7600 Hz, kaldi's mel scale),
 * rounded: a table rather than libm, so the statistic is the same on every device. */
static const short kMelUpperHz[BINS] = {
    65,   88,   112,  137,  163,  189,  217,  245,  274,  304,  334,  366,  399,  432,  467,  503,
    540,  578,  617,  657,  699,  742,  786,  831,  878,  926,  976,  1028, 1081, 1135, 1191, 1249,
    1309, 1371, 1434, 1500, 1567, 1636, 1708, 1782, 1858, 1936, 2017, 2100, 2186, 2274, 2366, 2460,
    2556, 2656, 2759, 2865, 2974, 3087, 3203, 3322, 3446, 3573, 3704, 3839, 3978, 4121, 4269, 4421,
    4578, 4740, 4906, 5078, 5255, 5438, 5626, 5820, 6019, 6225, 6437, 6656, 6881, 7114, 7353, 7600};

#define ZF_CLIP_LEVEL 0.99f
#define ZF_ZERO_RUN 16
#define ZF_BANDWIDTH_NATS 11.512925f /* 50 dB of power, in the fbank's natural log */
#define ZF_FLOOR_RISE 1.00695555f    /* 2^(1/100): the floor's power doubles at most once a second */

/* Samples at the 16 kHz the model reads, kept for the evidence until their chunk has run. */
static int keep_samples(ZfStream *s, const float *x, int n) {
  if (s->ev_n + n > s->ev_cap) {
    int cap = s->ev_cap ? s->ev_cap : 32768;
    while (cap < s->ev_n + n) cap *= 2;
    float *p = (float *)realloc(s->ev_samples, (size_t)cap * sizeof(float));
    if (!p) return 0;
    s->ev_samples = p;
    s->ev_cap = cap;
  }
  memcpy(s->ev_samples + s->ev_n, x, (size_t)n * sizeof(float));
  s->ev_n += n;
  return 1;
}

static void capture_stats(ZfStream *s, const float *x, int n, const float *window, ZfCaptureStats *c) {
  /* the bandwidth from the chunk's own frames, the first `advance` of its window */
  float mean[BINS], top = -1e30f;
  for (int b = 0; b < BINS; ++b) {
    float sum = 0.0f;
    for (int f = 0; f < s->advance; ++f) sum += window[(size_t)f * BINS + b];
    mean[b] = sum / (float)s->advance;
    if (mean[b] > top) top = mean[b];
  }
  for (int b = BINS - 1; b >= 0; --b)
    if (mean[b] >= top - ZF_BANDWIDTH_NATS) {
      c->bandwidth_hz = (float)kMelUpperHz[b];
      break;
    }
  if (!x || n <= 0) return;
  c->has_samples = 1;
  double sum = 0.0, sq = 0.0;
  int run = 0;
  for (int i = 0; i < n; ++i) {
    const float v = x[i], a = v < 0.0f ? -v : v;
    sum += v;
    sq += (double)v * v;
    if (a > c->peak) c->peak = a;
    c->clipped += a >= ZF_CLIP_LEVEL;
    run = v == 0.0f ? run + 1 : 0;
    if (run == ZF_ZERO_RUN) {
      ++c->zero_runs;
      c->zero_samples += ZF_ZERO_RUN;
    } else if (run > ZF_ZERO_RUN) {
      ++c->zero_samples;
    }
  }
  c->rms = (float)sqrt(sq / n);
  c->dc = (float)(sum / n);
  /* the running floor, 10 ms at a time: it falls at once and rises slowly */
  for (int at = 0; at + 160 <= n; at += 160) {
    double e = 0.0;
    for (int i = at; i < at + 160; ++i) e += (double)x[i] * x[i];
    const float p = (float)(e / 160.0);
    const float risen = s->ev_floor * ZF_FLOOR_RISE;
    s->ev_floor = s->ev_floor < 0.0f || p < risen ? p : risen;
  }
  c->noise_floor = s->ev_floor < 0.0f ? 0.0f : sqrtf(s->ev_floor);
}

/* A tap's data and its [rows, last dimension], or NULL when the graph does not carry it. */
static const float *tap_data(ZfStream *s, OrtValue **outs, int tap, int *rows, int *cols) {
  const OrtApi *ort = s->ort;
  *rows = *cols = 0;
  if (s->req_tap[tap] < 0) return NULL;
  OrtValue *v = outs[s->req_tap[tap]];
  float *data = NULL;
  OrtTensorTypeAndShapeInfo *ti = NULL;
  size_t rank = 0, count = 0;
  int64_t dims[8] = {0};
  if (ort->GetTensorMutableData(v, (void **)&data) || ort->GetTensorTypeAndShape(v, &ti)) return NULL;
  const int bad = ort->GetDimensionsCount(ti, &rank) != NULL || rank < 1 || rank > 8 ||
                  ort->GetDimensions(ti, dims, rank) != NULL ||
                  ort->GetTensorShapeElementCount(ti, &count) != NULL;
  ort->ReleaseTensorTypeAndShapeInfo(ti);
  if (bad || dims[rank - 1] <= 0) return NULL;
  *cols = (int)dims[rank - 1];
  *rows = (int)(count / (size_t)dims[rank - 1]);
  return data;
}

/* The chunk just decoded (s->chunks - 1) to the evidence callback. `window` is its input frames. */
static int give_evidence(ZfStream *s, OrtValue **outs, const float *logp, int frames, int vocab,
                         const float *window) {
  ZfEvidence e;
  memset(&e, 0, sizeof e);
  e.struct_size = sizeof e;
  e.chunk = s->chunks - 1;
  e.frames = frames;
  e.vocab = vocab;
  e.log_probs = logp;
  int rows = 0, cols = 0;
  const float *logits = tap_data(s, outs, TAP_LOGITS, &rows, &cols);
  if (logits && rows == frames && cols == vocab) {
    if (s->ev_lse_cap < frames) {
      float *p = (float *)realloc(s->ev_lse, (size_t)frames * sizeof(float));
      if (!p) return -1;
      s->ev_lse = p;
      s->ev_lse_cap = frames;
    }
    for (int t = 0; t < frames; ++t) s->ev_lse[t] = logits[(size_t)t * vocab] - logp[(size_t)t * vocab];
    e.logit_lse = s->ev_lse;
  }
  e.enc = tap_data(s, outs, TAP_ENC, &rows, &e.enc_dim);
  if (e.enc && rows != frames) e.enc = NULL, e.enc_dim = 0;
  e.stack0 = tap_data(s, outs, TAP_STACK0, &e.stack0_frames, &e.stack0_dim);
  e.stack1 = tap_data(s, outs, TAP_STACK1, &rows, &e.stack1_dim);
  if (e.stack1 && rows != frames) e.stack1 = NULL, e.stack1_dim = 0;
  /* the samples the chunk's advance stands for: [chunk x advance x 160, + advance x 160) */
  const int n = s->advance * 160;
  const long long start = e.chunk * (long long)n;
  if (s->ev_n > 0 && start >= s->ev_base && start + n <= s->ev_base + s->ev_n) {
    e.samples = s->ev_samples + (start - s->ev_base);
    e.n_samples = n;
  }
  capture_stats(s, e.samples, e.n_samples, window, &e.capture);
  s->on_evidence(s->user, &e);
  /* what this chunk's samples were, and anything before them, is no longer needed */
  const long long drop = start + n - s->ev_base;
  if (drop > 0) {
    const int d = drop < s->ev_n ? (int)drop : s->ev_n;
    memmove(s->ev_samples, s->ev_samples + d, (size_t)(s->ev_n - d) * sizeof(float));
    s->ev_n -= d;
    s->ev_base += drop;
  }
  return 0;
}

/* One chunk's outputs (in the order of req_names): the log-probs to the decoder, the queue and the
 * callbacks, and every new_<state> carried into <state>. `window` is the chunk's input frames.
 * Returns 0, or -1. */
static int consume_chunk(ZfStream *s, OrtValue **outs, const float *window) {
  const OrtApi *ort = s->ort;
  float *logp = NULL;
  OrtTensorTypeAndShapeInfo *li = NULL;
  int64_t ld[3] = {1, 0, 0};
  if (ort->GetTensorMutableData(outs[s->req_logp], (void **)&logp) ||
      ort->GetTensorTypeAndShape(outs[s->req_logp], &li))
    return -1;
  OrtStatus *ds = ort->GetDimensions(li, ld, 3);
  ort->ReleaseTensorTypeAndShapeInfo(li);
  if (ds) {
    ort->ReleaseStatus(ds);
    ld[1] = ld[2] = 0;
  }
  const int frames = (int)ld[1], vocab = (int)ld[2];
  if (!s->decoder) {
    s->vocab = vocab;
    /* blank is the graph's blank_id (0 for V4), else the vocabulary's last id (v3.x, b8) */
    s->decoder = zf_decoder_create(vocab, s->blank >= 0 ? s->blank : vocab - 1);
    if (s->pos_pending) zf_decoder_set_position(s->decoder, s->pos_frames, s->pos_prev);
    zf_decoder_set_complete_runs(s->decoder, s->complete_runs);
    s->last_logp = (float *)malloc((size_t)frames * vocab * sizeof(float));
  }
  if (!s->decoder || !s->last_logp || frames <= 0 || vocab != s->vocab) return -1;
  memcpy(s->last_logp, logp, (size_t)frames * vocab * sizeof(float));
  s->last_frames = frames;
  if (s->chunk_tokens_cap < frames) {
    ZfToken *t = (ZfToken *)realloc(s->chunk_tokens, (size_t)frames * sizeof(ZfToken));
    if (!t) return -1;
    s->chunk_tokens = t;
    s->chunk_tokens_cap = frames;
  }
  /* the other outputs, kept for zf_stream_last_output before anyone is called back */
  for (int e = 0; e < s->n_extra; ++e) {
    struct ExtraOut *x = &s->extra[e];
    if (x->req < 0) {
      x->rows = 0; /* not asked for: no value for this chunk */
      continue;
    }
    float *src = NULL;
    OrtTensorTypeAndShapeInfo *xi = NULL;
    size_t rank = 0, count = 0;
    int64_t dims[8] = {0};
    if (ort->GetTensorMutableData(outs[x->req], (void **)&src) ||
        ort->GetTensorTypeAndShape(outs[x->req], &xi))
      return -1;
    const int bad = ort->GetDimensionsCount(xi, &rank) != NULL || rank < 1 || rank > 8 ||
                    ort->GetDimensions(xi, dims, rank) != NULL ||
                    ort->GetTensorShapeElementCount(xi, &count) != NULL;
    ort->ReleaseTensorTypeAndShapeInfo(xi);
    if (bad) return -1;
    /* [1, T, C] is T rows of C; [1, T] is T rows of one */
    x->cols = rank >= 3 ? (int)dims[rank - 1] : 1;
    x->rows = x->cols > 0 ? (int)(count / (size_t)x->cols) : 0;
    if ((int)count > x->cap) {
      float *p = (float *)realloc(x->data, count * sizeof(float));
      if (!p) return -1;
      x->data = p;
      x->cap = (int)count;
    }
    memcpy(x->data, src, count * sizeof(float));
  }
  const int got = zf_decoder_push(s->decoder, logp, frames, s->chunk_tokens, frames);
  if (got < 0 || !enqueue(s, s->chunk_tokens, got)) return -1;
  ++s->chunks;
  if (s->on_chunk) s->on_chunk(s->user, logp, frames, vocab);
  if (s->on_evidence && give_evidence(s, outs, logp, frames, vocab, window) < 0) return -1;
  /* carry every new_<state> into <state> */
  for (size_t r = 0; r < s->n_req; ++r) {
    const int i = s->req_input[r];
    if (i < 0) continue;
    void *src = NULL;
    if (!ort->GetTensorMutableData(outs[r], &src)) memcpy(s->state[i], src, s->state_bytes[i]);
  }
  return 0;
}

/* The graph's inputs as values over the stream's state, the window `x` in place of its input. */
static int make_inputs(ZfStream *s, const float *x) {
  const OrtApi *ort = s->ort;
  memcpy(s->state[s->x_index], x, (size_t)s->window * BINS * sizeof(float));
  for (size_t i = 0; i < s->n_in; ++i) {
    OrtStatus *st = ort->CreateTensorWithDataAsOrtValue(s->mem, s->state[i], s->state_bytes[i],
                                                        s->in_shapes[i], s->in_dims[i],
                                                        s->in_types[i], &s->in_vals[i]);
    if (st) {
      ort->ReleaseStatus(st);
      return 0;
    }
  }
  return 1;
}

static void release_values(ZfStream *s, OrtValue **vals, size_t n) {
  for (size_t i = 0; i < n; ++i) {
    if (vals[i]) s->ort->ReleaseValue(vals[i]);
    vals[i] = NULL;
  }
}

/* One chunk over the first `window` pending frames; its phonemes go to the queue. Returns 0, or -1. */
static int run_chunk(ZfStream *s) {
  const OrtApi *ort = s->ort;
  int written = -1;
  if (make_inputs(s, s->pending)) {
    OrtStatus *st = ort->Run(s->session, NULL, (const char *const *)s->in_names,
                             (const OrtValue *const *)s->in_vals, s->n_in, s->req_names, s->n_req,
                             s->out_vals);
    if (!st) written = consume_chunk(s, s->out_vals, s->pending);
    else ort->ReleaseStatus(st);
  }
  release_values(s, s->out_vals, s->n_req);
  release_values(s, s->in_vals, s->n_in);
  return written;
}

#if defined(ZF_RT_BATCH)
/* zf_rt.c: B consecutive windows through the graph node by node, the same bits as B Runs */
OrtStatus *zf_rt_run_batch(OrtSession *s, int B, const char *const *in_names,
                           const OrtValue *const *inputs, size_t n_in, const char *x_name,
                           const float *const *x_chunks, const char *const *out_names,
                           size_t n_out, OrtValue **outputs);
#endif

/* The queued windows, node by node (zf_rt_run_batch), then each chunk's outputs in order: the
 * same bits as running them one at a time, with every node's weights read once for the batch. */
static int run_batch(ZfStream *s) {
  if (s->nb == 0) return 0;
#if defined(ZF_RT_BATCH)
  const OrtApi *ort = s->ort;
  const int B = s->nb;
  const float *xs[64];
  if (B > 64) return -1;
  if (!s->bouts) {
    /* sized for every output, so selecting more later never outgrows it */
    s->bouts = (OrtValue **)malloc((size_t)s->batch * s->n_out * sizeof(OrtValue *));
    if (!s->bouts) return -1;
  }
  OrtValue **outs = s->bouts;
  for (int b = 0; b < B; ++b) xs[b] = s->bx + (size_t)b * s->window * BINS;
  if (!make_inputs(s, xs[0])) {
    release_values(s, s->in_vals, s->n_in);
    return -1;
  }
  memset(outs, 0, (size_t)B * s->n_req * sizeof(OrtValue *));
  OrtStatus *st = zf_rt_run_batch(s->session, B, (const char *const *)s->in_names,
                                  (const OrtValue *const *)s->in_vals, s->n_in,
                                  s->in_names[s->x_index], xs, s->req_names, s->n_req, outs);
  release_values(s, s->in_vals, s->n_in);
  int ok = 0;
  if (st) {
    ort->ReleaseStatus(st);
    ok = -1;
  } else {
    for (int b = 0; b < B && ok == 0; ++b) ok = consume_chunk(s, outs + (size_t)b * s->n_req, xs[b]);
  }
  release_values(s, outs, (size_t)B * s->n_req);
  s->nb = 0;
  return ok;
#else
  s->nb = 0;
  return -1;
#endif
}

static int push_frames(ZfStream *s, const float *frames, int n) {
  if (!s || n < 0 || (n && !frames)) return -1;
  const int push_frames = n;
  while (n > 0) {
    /* take as many frames as complete the current window, no more, so the prefetch point and the
     * chunk boundary are seen whatever size the caller's pushes are */
    int room = s->window - s->n_pending;
    if (room <= 0) room = 1;
    const int take_n = n < room ? n : room;
    memcpy(s->pending + (size_t)s->n_pending * BINS, frames, (size_t)take_n * BINS * sizeof(float));
    s->n_pending += take_n;
    frames += (size_t)take_n * BINS;
    n -= take_n;
    if (s->n_pending < s->window) {
      /* all but the last `lead` frames in, and more still to come: the front end runs now, on the
       * frames that have arrived, and the chunk only finishes it */
      /* The burst has to come shortly before the window completes: measured, 10 ms before is best,
       * 15 to 20 ms still helps, 30 ms is too early (the cores have cooled again). A caller pushing
       * 20 ms at a time never leaves the window exactly one frame short, so the burst also fires
       * when the next push of this size will complete the window, up to three frames early. */
      const int missing = s->window - s->n_pending;
      const int ahead = push_frames < 3 ? push_frames : 3;
      if (s->lead > 0 && s->batch <= 1 && !s->prefetched && n == 0 &&
          (missing <= s->lead || missing <= ahead)) {
        zf_ort_session_prefetch(s->zs, s->pending, s->window, s->n_pending);
        s->prefetched = 1;
      }
      continue;
    }
    if (s->batch > 1) {
      /* queue the window; the batch runs when full, at the end, or at zf_stream_flush */
      if (!s->bx) {
        s->bx = (float *)malloc((size_t)s->batch * s->window * BINS * sizeof(float));
        if (!s->bx) return -1;
      }
      memcpy(s->bx + (size_t)s->nb * s->window * BINS, s->pending,
             (size_t)s->window * BINS * sizeof(float));
      if (++s->nb == s->batch && run_batch(s) < 0) return -1;
    } else if (run_chunk(s) < 0) {
      return -1;
    }
    memmove(s->pending, s->pending + (size_t)s->advance * BINS,
            (size_t)(s->n_pending - s->advance) * BINS * sizeof(float));
    s->n_pending -= s->advance;
    s->prefetched = 0;
  }
  return 0;
}

/* What the caller's buffer can take of the queue; the rest stays queued. */
static int drain(ZfStream *s, ZfToken *out, int max_out) {
  if (!out || max_out <= 0) return 0;
  return zf_stream_read(s, out, max_out);
}

int zf_stream_push(ZfStream *s, const float *frames, int n, ZfToken *out, int max_out) {
  if (!s || max_out < 0 || n < 0 || (n && !frames)) return fail(s, ZF_ERR_ARGUMENT, "bad push arguments");
  if (push_frames(s, frames, n) < 0) return fail(s, ZF_ERR_ENGINE, "a chunk failed to run");
  return drain(s, out, max_out);
}

static int ensure_feat(ZfStream *s, int frames) {
  if (frames <= s->feat_cap) return 1;
  float *f = (float *)realloc(s->feat, (size_t)frames * BINS * sizeof(float));
  if (!f) return 0;
  s->feat = f;
  s->feat_cap = frames;
  return 1;
}

static int push_audio16(ZfStream *s, const float *samples, int n) {
  if (!s || n < 0 || (n && !samples)) return -1;
  /* in blocks, so the scratch stays small whatever the caller pushes */
  while (n > 0) {
    const int take_n = n < 16000 ? n : 16000;
    const int cap = zf_fbank_max_frames(take_n);
    if (!ensure_feat(s, cap)) return -1;
    if (s->on_evidence && !keep_samples(s, samples, take_n)) return -1;
    const int frames = zf_fbank_accept(s->fbank, samples, take_n, s->feat, cap);
    if (frames < 0) return -1;
    if (push_frames(s, s->feat, frames) < 0) return -1;
    samples += take_n;
    n -= take_n;
  }
  return 0;
}

/* Audio at the stream's rate: through the resampler first when it is not 16 kHz. */
static int push_audio(ZfStream *s, const float *samples, int n) {
  if (!s->rs) return push_audio16(s, samples, n);
  if (n < 0 || (n && !samples)) return -1;
  while (n > 0) {
    const int take_n = n < 4800 ? n : 4800;
    const int cap = zf_resampler_max_out(s->rs, take_n);
    if (cap > s->rs_cap) {
      float *b = (float *)realloc(s->rs_buf, (size_t)cap * sizeof(float));
      if (!b) return -1;
      s->rs_buf = b;
      s->rs_cap = cap;
    }
    const int got = zf_resampler_push(s->rs, samples, take_n, s->rs_buf, s->rs_cap);
    if (got < 0 || push_audio16(s, s->rs_buf, got) < 0) return -1;
    samples += take_n;
    n -= take_n;
  }
  return 0;
}

int zf_stream_push_audio(ZfStream *s, const float *samples, int n, ZfToken *out, int max_out) {
  if (!s || max_out < 0 || n < 0 || (n && !samples)) return fail(s, ZF_ERR_ARGUMENT, "bad push arguments");
  if (push_audio(s, samples, n) < 0) return fail(s, ZF_ERR_ENGINE, "a chunk failed to run");
  return drain(s, out, max_out);
}

int zf_stream_finish_audio(ZfStream *s, ZfToken *out, int max_out) {
  if (!s || max_out < 0) return -1;
  /* the resampler's tail first, then the flush the models are decoded with, at 16 kHz */
  if (s->rs) {
    const int cap = zf_resampler_max_out(s->rs, 0);
    if (cap > s->rs_cap) {
      float *b = (float *)realloc(s->rs_buf, (size_t)cap * sizeof(float));
      if (!b) return -1;
      s->rs_buf = b;
      s->rs_cap = cap;
    }
    const int got = zf_resampler_finish(s->rs, s->rs_buf, s->rs_cap);
    if (got < 0 || push_audio16(s, s->rs_buf, got) < 0) return -1;
  }
  static const float zeros[1200] = {0};
  for (int left = ZF_FLUSH_SAMPLES; left > 0;) {
    const int n = left < 1200 ? left : 1200;
    if (push_audio16(s, zeros, n) < 0) return -1;
    left -= n;
  }
  const int cap = zf_fbank_max_frames(0);
  if (!ensure_feat(s, cap)) return -1;
  const int frames = zf_fbank_finish(s->fbank, s->feat, cap);
  if (frames < 0 || push_frames(s, s->feat, frames) < 0) return -1;
  return zf_stream_finish(s, out, max_out);
}

int zf_stream_flush(ZfStream *s, ZfToken *out, int max_out) {
  if (!s || max_out < 0) return -1;
  if (run_batch(s) < 0) return fail(s, ZF_ERR_ENGINE, "a chunk failed to run");
  return drain(s, out, max_out);
}

int zf_stream_finish(ZfStream *s, ZfToken *out, int max_out) {
  if (!s || max_out < 0) return -1;
  /* any chunks still queued for a batch */
  if (run_batch(s) < 0) return fail(s, ZF_ERR_ENGINE, "a chunk failed to run");
  ZfToken held;
  if (s->decoder && zf_decoder_flush(s->decoder, &held, 1) == 1 && !enqueue(s, &held, 1)) return -1;
  return drain(s, out, max_out);
}

/* The whole of a file, malloc'd, or NULL. */
static unsigned char *slurp(const char *path, size_t *size) {
  /* a file held in memory (zf/vfs.h) first, as every loader looks */
  unsigned char *mem = zf_vfs_copy(path, size);
  if (mem) return mem;
  FILE *f = fopen(path, "rb");
  if (!f) return NULL;
  fseek(f, 0, SEEK_END);
  const long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  unsigned char *p = n > 0 ? (unsigned char *)malloc((size_t)n) : NULL;
  if (p && fread(p, 1, (size_t)n, f) != (size_t)n) {
    free(p);
    p = NULL;
  }
  fclose(f);
  if (p) *size = (size_t)n;
  return p;
}

ZfStream *zf_stream_create_from_coreml(const char *mlmodelc, const char *sidecar,
                                       const ZfStreamOptions *options, const char **error) {
  static int seq = 0;
  char path[1024], prefix[64], model[128];
  snprintf(path, sizeof path, "%s/weights/weight.bin", mlmodelc);
  size_t wlen = 0, zlen = 0;
  unsigned char *w = slurp(path, &wlen);
  unsigned char *z = sidecar ? slurp(sidecar, &zlen) : NULL;
  if (!w || !z) {
    free(w);
    free(z);
    if (error) *error = !w ? "cannot read the CoreML model's weights/weight.bin" : "cannot read the engine sidecar";
    return NULL;
  }
  snprintf(prefix, sizeof prefix, "zfmem:%d", __atomic_add_fetch(&seq, 1, __ATOMIC_RELAXED));
  const int files = zf_zfs_materialize(w, wlen, z, zlen, prefix, error);
  free(w);
  if (files < 0) {
    free(z);
    return NULL;
  }
  unsigned char digest[32];
  const int have_digest = zf_zfs_file_digest(z, zlen, "layers.zfw", digest) == 0;
  free(z);
  snprintf(model, sizeof model, "%s/model_engine2.onnx", prefix);
  ZfStream *s = zf_stream_create(model, options, error);
  if (s && have_digest) hex32(digest, s->weights_sha);
  /* the engine holds its own copies now */
  zf_vfs_remove_prefix(prefix);
  return s;
}

/* ---------------------------------------------------------------- carried state by name */

typedef struct StateEntry {
  char name[48];
  int kind; /* 0 a layer cache, 1 a graph state, 2 the position */
  int layer, which, input;
  int64_t dims[8];
  int rank, is_int64;
  size_t bytes;
} StateEntry;

static const char *const kCacheNames[6] = {"cached_key", "cached_nonlin_attn", "cached_val1",
                                           "cached_val2", "cached_conv1", "cached_conv2"};

static int build_states(ZfStream *s) {
  if (s->states) return s->n_states;
  const int layers = zf_ort_session_layer_count(s->zs);
  const int cap = layers * 6 + (int)s->n_in + 1;
  StateEntry *t = (StateEntry *)calloc((size_t)cap, sizeof(StateEntry));
  if (!t) return -1;
  int n = 0;
  for (int i = 0; i < layers; ++i) {
    ZfLayer *l = zf_ort_session_layer(s->zs, i);
    if (!l) continue;
    for (int w = 0; w < 6; ++w) {
      int rows = 0, cols = 0;
      if (zf_layer_cache_shape(l, w, &rows, &cols)) continue;
      StateEntry *e = &t[n++];
      snprintf(e->name, sizeof e->name, "%s_%d", kCacheNames[w], i);
      e->kind = 0;
      e->layer = i;
      e->which = w;
      if (w == 1) { e->rank = 4; e->dims[0] = 1; e->dims[1] = 1; e->dims[2] = rows; e->dims[3] = cols; }
      else if (w >= 4) { e->rank = 3; e->dims[0] = 1; e->dims[1] = rows; e->dims[2] = cols; }
      else { e->rank = 3; e->dims[0] = rows; e->dims[1] = 1; e->dims[2] = cols; }
      e->bytes = (size_t)rows * cols * sizeof(float);
    }
  }
  for (size_t i = 0; i < s->n_in; ++i) {
    if ((int)i == s->x_index) continue;
    StateEntry *e = &t[n++];
    snprintf(e->name, sizeof e->name, "%s", s->in_names[i]);
    e->kind = 1;
    e->input = (int)i;
    e->rank = (int)(s->in_dims[i] < 8 ? s->in_dims[i] : 8);
    for (int d = 0; d < e->rank; ++d) e->dims[d] = s->in_shapes[i][d];
    e->is_int64 = s->in_types[i] == ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64;
    e->bytes = s->state_bytes[i];
  }
  StateEntry *e = &t[n++];
  snprintf(e->name, sizeof e->name, "zf_position");
  e->kind = 2;
  e->rank = 1;
  e->dims[0] = 3;
  e->is_int64 = 1;
  e->bytes = 3 * sizeof(int64_t);
  s->states = t;
  s->n_states = n;
  return n;
}

static StateEntry *find_state(ZfStream *s, const char *name) {
  if (!s || !name || build_states(s) < 0) return NULL;
  for (int i = 0; i < s->n_states; ++i)
    if (!strcmp(s->states[i].name, name)) return &s->states[i];
  return NULL;
}

int zf_stream_state_count(ZfStream *s) { return s ? build_states(s) : -1; }

int zf_stream_state_info(ZfStream *s, int index, const char **name, int64_t dims[8], int *rank,
                         int *is_int64) {
  if (!s || build_states(s) < 0 || index < 0 || index >= s->n_states) return -1;
  const StateEntry *e = &s->states[index];
  if (name) *name = e->name;
  if (dims) memcpy(dims, e->dims, sizeof e->dims);
  if (rank) *rank = e->rank;
  if (is_int64) *is_int64 = e->is_int64;
  return 0;
}

int zf_stream_export_state(ZfStream *s, const char *name, void *out, size_t bytes) {
  StateEntry *e = find_state(s, name);
  if (!e || !out || bytes != e->bytes) return fail(s, ZF_ERR_ARGUMENT, "unknown state or wrong size");
  /* chunks queued for a batch run first: the state handed over is the one after them */
  if (run_batch(s) < 0) return fail(s, ZF_ERR_ENGINE, "a chunk failed to run");
  if (e->kind == 0)
    return zf_layer_cache_read(zf_ort_session_layer(s->zs, e->layer), e->which, (float *)out,
                               bytes / sizeof(float));
  if (e->kind == 1) {
    memcpy(out, s->state[e->input], bytes);
    return 0;
  }
  long long frames = s->pos_frames;
  int prev = s->pos_prev;
  if (s->decoder) zf_decoder_position(s->decoder, &frames, &prev);
  else if (!s->pos_pending) {
    frames = 0;
    prev = s->blank >= 0 ? s->blank : (s->vocab > 0 ? s->vocab - 1 : -1);
  }
  const int64_t v[3] = {s->chunks, frames, prev};
  memcpy(out, v, sizeof v);
  return 0;
}

int zf_stream_import_state(ZfStream *s, const char *name, const void *in, size_t bytes) {
  StateEntry *e = find_state(s, name);
  if (!e || !in || bytes != e->bytes) return fail(s, ZF_ERR_ARGUMENT, "unknown state or wrong size");
  /* chunks queued for a batch run on the state they were pushed under, not the imported one */
  if (run_batch(s) < 0) return fail(s, ZF_ERR_ENGINE, "a chunk failed to run");
  if (e->kind == 0)
    return zf_layer_cache_write(zf_ort_session_layer(s->zs, e->layer), e->which, (const float *)in,
                                bytes / sizeof(float));
  if (e->kind == 1) {
    memcpy(s->state[e->input], in, bytes);
    /* the front end's cache also lives in its kernel, for the prefetch; a size match says this is it */
    if (!e->is_int64) zf_ort_session_set_frontend_state(s->zs, (const float *)in, bytes / sizeof(float));
    s->prefetched = 0;
    return 0;
  }
  int64_t v[3];
  memcpy(v, in, sizeof v);
  s->chunks = v[0];
  s->pos_frames = v[1];
  s->pos_prev = (int)v[2];
  s->pos_pending = 1;
  /* audio pushed from here on is the next chunk's: the evidence's samples restart there */
  s->ev_base = s->chunks * (long long)s->advance * 160;
  s->ev_n = 0;
  if (s->decoder) zf_decoder_set_position(s->decoder, s->pos_frames, s->pos_prev);
  return 0;
}

/* ---------------------------------------------------------------- errors and model info */

static int fail(ZfStream *s, ZfStatus code, const char *message) {
  if (s) {
    s->last_error = code;
    s->last_message = message;
  }
  return -1;
}

ZfStatus zf_stream_last_error(const ZfStream *s, const char **message) {
  if (message) *message = s && s->last_message ? s->last_message : "";
  return s ? s->last_error : ZF_ERR_ARGUMENT;
}

static void hex32(const unsigned char d[32], char out[65]) {
  static const char *x = "0123456789abcdef";
  for (int i = 0; i < 32; ++i) {
    out[2 * i] = x[d[i] >> 4];
    out[2 * i + 1] = x[d[i] & 15];
  }
  out[64] = 0;
}

static void meta_string(ZfStream *s, const char *key, char *out, size_t size) {
  out[0] = 0;
  const OrtApi *ort = s->ort;
  OrtModelMetadata *md = NULL;
  OrtAllocator *alloc = NULL;
  if (ort->SessionGetModelMetadata(s->session, &md) || !md) return;
  if (!ort->GetAllocatorWithDefaultOptions(&alloc) && alloc) {
    char *val = NULL;
    OrtStatus *st = ort->ModelMetadataLookupCustomMetadataMap(md, alloc, key, &val);
    if (st) ort->ReleaseStatus(st);
    else if (val) {
      snprintf(out, size, "%s", val);
      alloc->Free(alloc, val);
    }
  }
  ort->ReleaseModelMetadata(md);
}

int zf_stream_model_info(ZfStream *s, ZfModelInfo *out) {
  /* a caller built before the appended fields has room for these and no more */
  return zf_stream_model_info_sized(s, out, offsetof(ZfModelInfo, backend));
}

static int model_info_full(ZfStream *s, ZfModelInfo *out);

int zf_stream_model_info_sized(ZfStream *s, ZfModelInfo *out, size_t size) {
  if (!s || !out || size == 0) return fail(s, ZF_ERR_ARGUMENT, "no stream or no info to fill");
  ZfModelInfo full;
  const int r = model_info_full(s, &full);
  memcpy(out, &full, size < sizeof full ? size : sizeof full);
  return r;
}

static int model_info_full(ZfStream *s, ZfModelInfo *out) {
  memset(out, 0, sizeof *out);
  out->backend = ZF_BACKEND_EXACT_CPU;
  out->chunk_ms = s->advance * 10;
  const OrtApi *ort = s->ort;
  /* the vocabulary is the log-probs' last dimension */
  OrtTypeInfo *ti = NULL;
  const OrtTensorTypeAndShapeInfo *si = NULL;
  size_t rank = 0;
  int64_t dims[8] = {0};
  if (!ort->SessionGetOutputTypeInfo(s->session, (size_t)s->logits_index, &ti) &&
      !ort->CastTypeInfoToTensorInfo(ti, &si) && !ort->GetDimensionsCount(si, &rank) && rank > 0 &&
      rank <= 8 && !ort->GetDimensions(si, dims, rank))
    out->vocab = (int)dims[rank - 1];
  if (ti) ort->ReleaseTypeInfo(ti);
  out->blank = s->blank >= 0 ? s->blank : (out->vocab > 0 ? out->vocab - 1 : -1);
  out->window = s->window;
  out->advance = s->advance;
  out->layers = zf_ort_session_layer_count(s->zs);
  out->left_context = zf_ort_session_left_context(s->zs);
  out->sample_rate = s->sample_rate;
  meta_string(s, "model_type", out->model_type, sizeof out->model_type);
  meta_string(s, "version", out->version, sizeof out->version);
  if (!s->weights_sha[0]) { /* the layers' file, hashed on first ask */
    char buf[2048];
    const char *path = zf_ort_session_weights_file(s->zs, buf, sizeof buf);
    size_t n = 0;
    unsigned char *data = path[0] ? slurp(path, &n) : NULL;
    if (data) {
      unsigned char d[32];
      zf_sha256(data, n, d);
      hex32(d, s->weights_sha);
      free(data);
    }
  }
  memcpy(out->weights_sha256, s->weights_sha, sizeof out->weights_sha256);
  return 0;
}
