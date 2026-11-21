#include "zf/layer.h"
#include "zf/env.h"

#include <math.h>
#include <stddef.h>
#include <time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "zf/block.h"
#include "zf/conv.h"
#include "zf/dot.h"

#include "zf/neon.h"

#define ZF_QUERY_DIM 32
#define ZF_POS_DIM 4
#define ZF_VALUE_DIM 12
#define ZF_MASK_SCORE (-1000.0f)
/* The most parallel tasks any region is split into, which is what the per-task buffers are sized
 * for. Four cores here; the headroom costs a few tens of kilobytes. */
#define ZF_MAX_TASKS 16

struct ZfLayer {
  int dim, heads, frames, left, na_dim, pos_width;
  float swoosh_l_offset; /* 4 (v3.1) or 1 (b8): what SwooshL subtracts before its softplus */
  int taps_causal, taps_chunk;

  ZfLinear saw_in, ff1_in, ff1_out, ff2_in, ff2_out, ff3_in, ff3_out;
  ZfLinear na_in, na_out, sa1_in, sa1_out, sa2_in, sa2_out;
  ZfLinear cm_in[2], cm_out[2];
  const int8_t *pos_weight;
  float pos_scale;
  const int32_t *pos_index;
  const float *cm_causal_w[2], *cm_causal_b[2], *cm_chunk_w[2], *cm_chunk_b[2], *cm_mask[2];
  /* At one frame a chunk the chunkwise convolution's mask is one constant per channel, and ONNX
   * Runtime's ConvMulFusion folds it into that convolution at load: weight * mask and bias * mask.
   * These are the folded copies, used only when frames == 1 (see conv_body). */
  float *cm_fold_w[2], *cm_fold_b[2];
  const float *norm_bias;
  float norm_scale;
  const float *bypass_scale, *bypass_mid_scale;

  ZfArena *arena_ref;   /* the block this layer draws scratch from */
  int arena_owned;      /* whether this layer created it */
  unsigned char *bound; /* the base the pointers below were computed from */
  size_t need;
  size_t slot[8], qbuf_off, acc_off, scales_off, qbuf_stride;
  float a_scale;
  int a_zp;
  /* One activation range per quantiser task, folded by the region that follows. */
  float qlo[ZF_MAX_TASKS], qhi[ZF_MAX_TASKS];
  float *orig, *work, *wide, *attn, *pos_raw, *conv, *conv_a, *conv_b;
  /* the caches, [left + frames, width] with the window at row zero, and their own allocation:
   * they are the only thing in a layer that survives a call */
  unsigned char *cache_block;
  size_t cache_bytes;
  float *kcat, *nacat, *vcat[2], *cconv[2];
  /* The window slides forward by one chunk's frames and the buffer holds an extra left context of
   * slack, so the rows are copied back to the front once every left_context / frames chunks
   * instead of every chunk. Every consumer still sees one contiguous [left + frames, width]
   * block, which is what the concatenation buffers used to be for. */
  int cache_base, cache_cap;
  float *kwin, *nawin, *vwin[2];
  int8_t *qbuf;
  int32_t *acc;
  float *scales;
  int max_n, max_k_pad;
  double stage_ms[ZF_LAYER_STAGES];
  double madds;
};

#if defined(ZF_STAGE_TIMERS) && ZF_STAGE_TIMERS
static double layer_now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec * 1e3 + (double)ts.tv_nsec / 1e6;
}
#endif

/* The per-stage timers cost more than they look. A chunk runs 272 linears, each dispatched as two
 * regions, so timing every region's start and end on every task is about 4900 clock_gettime calls
 * a chunk, and on this kernel that call is not always in the vDSO. The accumulators also sit in one
 * struct that four cores write, so each increment is a contended line. Both were being paid in
 * every run, not only when ZF_TRACE asked for the numbers.
 *
 * So they are compiled out by default and built back in with -DZF_STAGE_TIMERS=1 when a breakdown
 * is wanted. With them off ZF_NOW() folds to a constant and the differences fold away, which keeps
 * the timing variables live and the code identical in shape. */
#ifndef ZF_STAGE_TIMERS
#define ZF_STAGE_TIMERS 0
#endif
#if ZF_STAGE_TIMERS
#define ZF_NOW() layer_now_ms()
#define ZF_STAGE(lp, i, dt) ((lp)->stage_ms[i] += (dt))
#else
#define ZF_NOW() 0.0
#define ZF_STAGE(lp, i, dt) ((void)(dt))
#endif

static const char *const kLayerStages[ZF_LAYER_STAGES] = {
    "linears",  "scores",     "state",       "nonlin",     "value",   "conv",
    "lin_quant", "lin_gemm",  "conv_own",    "nonlin_own", "value_own", "elementwise",
    "cm_gate",  "cm_dw",      "cm_post",     "s8_gemm",    "s8_gemm_t",  "s8_swoosh",
    "sc_qk",    "sc_pos",     "sc_mask",     "sc_softmax"};

void zf_layer_stages(const ZfLayer *l, double *out_ms) {
  for (int i = 0; i < ZF_LAYER_STAGES; ++i) out_ms[i] = l ? l->stage_ms[i] : 0.0;
}

void zf_layer_reset_state(ZfLayer *l) {
  if (!l || !l->cache_block) return;
  memset(l->cache_block, 0, l->cache_bytes);
  l->cache_base = 0;
}

int zf_layer_cache_shape(const ZfLayer *l, int which, int *rows, int *cols) {
  if (!l || which < 0 || which > 5) return -1;
  const int widths[4] = {l->heads * ZF_QUERY_DIM, l->na_dim, l->heads * ZF_VALUE_DIM,
                         l->heads * ZF_VALUE_DIM};
  if (which < 4) {
    *rows = l->left;
    *cols = widths[which];
  } else {
    *rows = l->dim;
    *cols = l->taps_causal - 1;
  }
  return 0;
}

static float *row_cache(const ZfLayer *l, int which) {
  float *const bufs[4] = {l->kcat, l->nacat, l->vcat[0], l->vcat[1]};
  return bufs[which];
}

int zf_layer_cache_read(const ZfLayer *l, int which, float *out, size_t floats) {
  int rows = 0, cols = 0;
  if (zf_layer_cache_shape(l, which, &rows, &cols) || floats != (size_t)rows * cols || !l->cache_block)
    return -1;
  if (which < 4) memcpy(out, row_cache(l, which) + (size_t)l->cache_base * cols, floats * sizeof(float));
  else memcpy(out, l->cconv[which - 4], floats * sizeof(float));
  return 0;
}

int zf_layer_cache_write(ZfLayer *l, int which, const float *in, size_t floats) {
  int rows = 0, cols = 0;
  if (zf_layer_cache_shape(l, which, &rows, &cols) || floats != (size_t)rows * cols || !l->cache_block)
    return -1;
  if (which >= 4) {
    memcpy(l->cconv[which - 4], in, floats * sizeof(float));
    return 0;
  }
  /* the four row caches share one window position: bring all of them to the front first */
  if (l->cache_base) {
    for (int i = 0; i < 4; ++i) {
      int r = 0, c = 0;
      zf_layer_cache_shape(l, i, &r, &c);
      float *b = row_cache(l, i);
      memmove(b, b + (size_t)l->cache_base * c, (size_t)r * c * sizeof(float));
    }
    l->cache_base = 0;
  }
  memcpy(row_cache(l, which), in, floats * sizeof(float));
  return 0;
}

double zf_layer_madds(const ZfLayer *l) { return l ? l->madds : 0.0; }

void zf_layer_reset_stages(ZfLayer *l) {
  if (l) l->madds = 0.0;
  if (l) memset(l->stage_ms, 0, sizeof l->stage_ms);
}

const char *zf_layer_stage_name(int index) {
  return (index >= 0 && index < ZF_LAYER_STAGES) ? kLayerStages[index] : "?";
}

/* Every region below is split the same way: pick a task count no larger than the work, then let
 * the caller's threads run it. Measured on device, four cores gave the layer only 1.89 times the
 * throughput of one until these regions were split; the matmuls were already parallel, and what
 * was left serial was more than half the chunk. */
/* A threshold a benchmark can move, read once. Interleaved A/B is the only way to compare two of
 * these on this phone: absolute times drift by several milliseconds as it warms. */
static int zf_env_int(const char *name, int fallback) {
  const char *v = zf_getenv(name);
  return v ? atoi(v) : fallback;
}

/* Tasks per thread in a split region.
 *
 * One task a thread is the obvious choice and it is the wrong one on a four core phone with no
 * spare core. A chunk crosses 763 split regions, each ending in a join, and the join waits for the
 * slowest thread. With all four cores carrying the team there is no core left for the kernel, so
 * whenever the scheduler takes one of them the whole team waits at the next join for as long as it
 * is away. Measured on the caller: 3.7 ms of a chunk at three threads, 18.2 at four.
 *
 * Cutting the tasks smaller does not make a descheduled thread come back sooner, but it bounds what
 * it is holding. With one task a thread the team waits for a quarter of the region; with four tasks
 * a thread the other three finish the rest and wait only for the one small task that stalled. */
/* tasks a thread in a linear's region; a build can choose (tajweedformer-wasm: more, smaller items, so
 * a descheduled thread's share is picked up by the others) */
#ifndef ZF_TASK_MULT_DEFAULT
#define ZF_TASK_MULT_DEFAULT 1
#endif
static int task_mult(void) {
  static _Atomic int m = -1;
  if (m < 0) {
    m = zf_env_int("ZF_TASK_MULT", ZF_TASK_MULT_DEFAULT);
    if (m < 1) m = 1;
  }
  return m;
}

static int par_threads(const ZfParallel *par) {
  return (par && par->run && par->threads > 1) ? par->threads : 1;
}

/* One task a thread, deliberately, and it was worth checking because it looks like a mistake: the
 * pool claims work by an atomic cursor, so four tasks across four threads gives it nothing to
 * rebalance and every join waits on the unluckiest quarter. Multiplying the count here is slower.
 * Interleaved A/B at the 160 ms chunk, three reps, `ZF_TASK_MULT` over 1, 2, 3, 4 and 6:
 *
 *   mult    1       2       3       4       6
 *   chunk   41.40   42.56   42.50   43.66   42.81
 *           41.48   42.48   42.49   42.85   43.04
 *           41.55   42.25   42.81   42.85   43.08
 *
 * One task a thread wins all three reps by about a millisecond, and the join wait does not reliably
 * fall. The reason is that the region this would rebalance is not where the time is: the linears
 * dominate and they already claim in grains of four panels inside `zf_linear_s8_pool`, so the
 * cursor is doing its job there. What is left for `plan_tasks` are the small regions, and for those
 * the extra claims and the cache line they share cost more than the imbalance they remove. */
static int plan_tasks(const ZfParallel *par, int units) {
  int t = (par && par->run && par->threads > 1) ? par->threads : 1;
  if (t > units) t = units;
  return t < 1 ? 1 : t;
}

/* Regions that run on one thread are worth their full length at four, so they are timed apart:
 * fitting the one, two and four thread chunk times puts the serial part of a chunk at about 20 ms
 * of the 108, and this says which regions it is. `zf_serial_ms` is a whole-process total because a
 * layer's own share of it is too small to read. */
static double g_serial_ms = 0.0;

double zf_serial_ms(void) { return g_serial_ms; }

static void dispatch(const ZfParallel *par, void (*fn)(void *user, size_t index), int tasks,
                     void *user) {
  if (tasks > 1 && par && par->run) {
    par->run(par->ctx, fn, (size_t)tasks, user);
    return;
  }
#if ZF_STAGE_TIMERS
  const double t0 = layer_now_ms();
  fn(user, 0);
  g_serial_ms += layer_now_ms() - t0;
#else
  fn(user, 0); /* two clock reads a region were thousands a chunk on the single-threaded path */
#endif
}

static void slice_of(int total, int tasks, size_t index, int *begin, int *end) {
  *begin = (int)((size_t)total * index / (size_t)tasks);
  *end = (int)((size_t)total * (index + 1) / (size_t)tasks);
}

static size_t align_up(size_t v) { return (v + 63u) & ~(size_t)63u; }

struct ZfArena {
  unsigned char *block;
  size_t bytes;
  /* zf_layer_run_group: each chunk's own scratch, and the layer views that point into it */
  unsigned char *lanes;
  size_t lane_bytes;
  struct ZfLayer *views;
  int view_count;
};

ZfArena *zf_arena_create(void) { return (ZfArena *)calloc(1, sizeof(ZfArena)); }

void zf_arena_destroy(ZfArena *a) {
  if (!a) return;
  free(a->block);
  free(a->lanes);
  free(a->views);
  free(a);
}

static void bind_arena(ZfLayer *l);

/* Grow the arena to at least `bytes`. The contents are scratch, so a grow throws them away. */
static int arena_reserve(ZfArena *a, size_t bytes) {
  if (a->bytes >= bytes) return 1;
  unsigned char *block = (unsigned char *)calloc(1, bytes);
  if (!block) return 0;
  free(a->block);
  a->block = block;
  a->bytes = bytes;
  return 1;
}

/* Whether to read the weights with SDOT. On by default wherever the instruction exists; ZF_DOT can
 * turn it off, and turning it on where the instruction does not exist takes the portable path, which
 * is slow but exercises exactly this wiring so the arrangement can be tested without the hardware.
 */
static int layer_use_dot(void) {
  static _Atomic int mode = -1;
  if (mode < 0) {
    const char *v = zf_getenv("ZF_DOT");
    mode = v ? atoi(v) : zf_dot_available();
  }
  return mode;
}

static int load_linear(ZfWeights *w, const char *prefix, ZfLinear *out) {
  char name[64];
  size_t count = 0;
  snprintf(name, sizeof name, "%s.shape", prefix);
  const int32_t *shape = zf_weights_s32(w, name, &count);
  if (!shape || count < 2) return 0;
  out->w.k = shape[0];
  out->w.n = shape[1];
  out->w.k_pad = (out->w.k + ZF_S8_K_GROUP - 1) / ZF_S8_K_GROUP * ZF_S8_K_GROUP;
  out->w.n_blocks = (out->w.n + ZF_S8_UNIT_BLOCK - 1) / ZF_S8_UNIT_BLOCK;
  snprintf(name, sizeof name, "%s.packed", prefix);
  out->w.packed = zf_weights_s8(w, name, &count);
  snprintf(name, sizeof name, "%s.rowsums", prefix);
  out->w.row_sums = zf_weights_s32(w, name, &count);
  snprintf(name, sizeof name, "%s.scale", prefix);
  out->scale = zf_weights_f32(w, name, &count);
  out->scale_count = (int)count;
  snprintf(name, sizeof name, "%s.bias", prefix);
  out->bias = zf_weights_f32(w, name, &count);
  if (!out->w.packed || !out->w.row_sums || !out->scale) return 0;
  if (layer_use_dot()) {
    snprintf(name, sizeof name, "%s.packed", prefix);
    out->dot = zf_weights_convert_to_dot(w, name, out->w.n, out->w.k);
  }
  return 1;
}

/* Point every scratch slot at the arena's current block. Called at create and again whenever a
 * later, larger layer has moved the block out from under this one. */
static void bind_arena(ZfLayer *l) {
  unsigned char *base = l->arena_ref->block;
  float **slots[] = {&l->orig, &l->work,   &l->wide,   &l->attn,
                     &l->pos_raw, &l->conv, &l->conv_a, &l->conv_b};
  for (size_t i = 0; i < sizeof slots / sizeof slots[0]; ++i)
    *slots[i] = (float *)(base + l->slot[i]);
  l->qbuf = (int8_t *)(base + l->qbuf_off);
  l->acc = (int32_t *)(base + l->acc_off);
  l->scales = (float *)(base + l->scales_off);
  l->bound = base;
}

ZfLayer *zf_layer_create(ZfWeights *w, int index, int frames, int left_context,
                         const char **error) {
  return zf_layer_create_in(w, index, frames, left_context, NULL, error);
}

ZfLayer *zf_layer_create_in(ZfWeights *w, int index, int frames, int left_context,
                            ZfArena *shared, const char **error) {
  return zf_layer_create_over(w, NULL, index, frames, left_context, shared, error);
}

ZfLayer *zf_layer_create_over(ZfWeights *w, const ZfWeights *frame_w, int index, int frames,
                              int left_context, ZfArena *shared, const char **error) {
  const char *why = "unknown";
  ZfLayer *l = (ZfLayer *)calloc(1, sizeof(ZfLayer));
  if (!l) {
    if (error) *error = "out of memory";
    return NULL;
  }
  l->arena_ref = shared;
  if (!l->arena_ref) {
    l->arena_ref = zf_arena_create();
    l->arena_owned = 1;
    if (!l->arena_ref) {
      free(l);
      if (error) *error = "out of memory";
      return NULL;
    }
  }
  l->frames = frames;
  l->left = left_context;
  char p[64];
  size_t count = 0;
#define LOAD(field, suffix)                                    \
  do {                                                         \
    snprintf(p, sizeof p, "L%02d." suffix, index);              \
    if (!load_linear(w, p, &l->field)) {                        \
      why = "L" suffix " is missing from the weight file";       \
      goto fail;                                                \
    }                                                           \
  } while (0)
  LOAD(saw_in, "saw_in");
  LOAD(ff1_in, "ff1_in");
  LOAD(ff1_out, "ff1_out");
  LOAD(ff2_in, "ff2_in");
  LOAD(ff2_out, "ff2_out");
  LOAD(ff3_in, "ff3_in");
  LOAD(ff3_out, "ff3_out");
  LOAD(na_in, "na_in");
  LOAD(na_out, "na_out");
  LOAD(sa1_in, "sa1_in");
  LOAD(sa1_out, "sa1_out");
  LOAD(sa2_in, "sa2_in");
  LOAD(sa2_out, "sa2_out");
  LOAD(cm_in[0], "cm1_in");
  LOAD(cm_out[0], "cm1_out");
  LOAD(cm_in[1], "cm2_in");
  LOAD(cm_out[1], "cm2_out");
#undef LOAD

  l->dim = l->saw_in.w.k;
  /* the attention linear produces, per head, a query, a key and a position vector */
  l->heads = l->saw_in.w.n / (2 * ZF_QUERY_DIM + ZF_POS_DIM);
  l->na_dim = l->na_in.w.n / 3;
  if (l->heads <= 0 || l->heads * (2 * ZF_QUERY_DIM + ZF_POS_DIM) != l->saw_in.w.n) {
    why = "the attention linear's width does not divide into heads";
    goto fail;
  }

  /* the tensors that depend on the chunk length come from the chunk's own file when there is one */
#define FRAME_W(name) (frame_w && zf_weights_find(frame_w, name) ? frame_w : w)
  snprintf(p, sizeof p, "L%02d.pos.weight", index);
  const ZfTensor *pos = zf_weights_find(FRAME_W(p), p);
  l->pos_weight = zf_weights_s8(FRAME_W(p), p, &count);
  snprintf(p, sizeof p, "L%02d.pos.scale", index);
  const float *ps = zf_weights_f32(FRAME_W(p), p, &count);
  snprintf(p, sizeof p, "L%02d.pos.index", index);
  l->pos_index = zf_weights_s32(FRAME_W(p), p, &count);
  if (!pos || !l->pos_weight || !ps || !l->pos_index) {
    why = "the position weight or its gather index is missing";
    goto fail;
  }
  l->pos_scale = ps[0];
  l->pos_width = pos->dims[3]; /* [heads, 1, pos_dim, width] */

  for (int i = 0; i < 2; ++i) {
    const char *which = i == 0 ? "cm1" : "cm2";
    snprintf(p, sizeof p, "L%02d.%s_causal.weight", index, which);
    const ZfTensor *cw = zf_weights_find(w, p);
    l->cm_causal_w[i] = zf_weights_f32(w, p, &count);
    snprintf(p, sizeof p, "L%02d.%s_causal.bias", index, which);
    l->cm_causal_b[i] = zf_weights_f32(w, p, &count);
    snprintf(p, sizeof p, "L%02d.%s_chunk.weight", index, which);
    const ZfTensor *kw = zf_weights_find(w, p);
    l->cm_chunk_w[i] = zf_weights_f32(w, p, &count);
    snprintf(p, sizeof p, "L%02d.%s_chunk.bias", index, which);
    l->cm_chunk_b[i] = zf_weights_f32(w, p, &count);
    snprintf(p, sizeof p, "L%02d.%s.mask", index, which);
    l->cm_mask[i] = zf_weights_f32(FRAME_W(p), p, &count);
    if (!cw || !kw || !l->cm_causal_w[i] || !l->cm_chunk_w[i] || !l->cm_mask[i]) {
      why = "a convolution module's depthwise weights are missing";
      goto fail;
    }
    l->taps_causal = cw->dims[1];
    l->taps_chunk = kw->dims[1];
  }

#undef FRAME_W

  /* One frame a chunk (the deepest stack at 160 ms): ONNX Runtime sees the mask as [channels, 1], a
   * per-channel constant after the chunkwise convolution, and ConvMulFusion folds it into the
   * convolution's weight and bias, each multiplied once in float32 at session load. The chunk is
   * then x * (w * m) + b * m where the graph as written gives (x * w + b) * m, which differs in the
   * last place. Longer chunks give a mask that varies along time, which no fusion can fold. */
  if (frames == 1) {
    const int D0 = l->saw_in.w.k, K = l->taps_chunk;
    for (int i = 0; i < 2; ++i) {
      l->cm_fold_w[i] = (float *)malloc((size_t)D0 * K * sizeof(float));
      l->cm_fold_b[i] = (float *)malloc((size_t)D0 * sizeof(float));
      if (!l->cm_fold_w[i] || !l->cm_fold_b[i]) {
        why = "out of memory";
        goto fail;
      }
      for (int c = 0; c < D0; ++c) {
        const float m = l->cm_mask[i][c];
        for (int k = 0; k < K; ++k)
          l->cm_fold_w[i][(size_t)c * K + k] = l->cm_chunk_w[i][(size_t)c * K + k] * m;
        l->cm_fold_b[i][c] = l->cm_chunk_b[i][c] * m;
      }
    }
  }

  snprintf(p, sizeof p, "L%02d.norm.bias", index);
  l->norm_bias = zf_weights_f32(w, p, &count);
  snprintf(p, sizeof p, "L%02d.norm.scale", index);
  const float *ns = zf_weights_f32(w, p, &count);
  snprintf(p, sizeof p, "L%02d.bypass.scale", index);
  l->bypass_scale = zf_weights_f32(w, p, &count);
  snprintf(p, sizeof p, "L%02d.bypass_mid.scale", index);
  l->bypass_mid_scale = zf_weights_f32(w, p, &count);
  if (!l->norm_bias || !ns || !l->bypass_scale || !l->bypass_mid_scale) {
    why = "the norm or a bypass scale is missing";
    goto fail;
  }
  l->norm_scale = ns[0];
  l->swoosh_l_offset = 4.0f;

  /* the arena, sized for the widest thing each buffer has to hold */
  const int D = l->dim, T = frames, H = l->heads, S = left_context + frames, NA = l->na_dim;
  const ZfLinear *all[] = {&l->saw_in, &l->ff1_in, &l->ff1_out, &l->ff2_in, &l->ff2_out,
                           &l->ff3_in, &l->ff3_out, &l->na_in,  &l->na_out, &l->sa1_in,
                           &l->sa1_out, &l->sa2_in, &l->sa2_out, &l->cm_in[0], &l->cm_out[0],
                           &l->cm_in[1], &l->cm_out[1]};
  for (size_t i = 0; i < sizeof all / sizeof all[0]; ++i) {
    if (all[i]->w.n > l->max_n) l->max_n = all[i]->w.n;
    if (all[i]->w.k_pad > l->max_k_pad) l->max_k_pad = all[i]->w.k_pad;
  }
  const size_t sizes[] = {
      (size_t)T * D * sizeof(float),                 /* orig */
      (size_t)T * D * sizeof(float),                 /* work */
      (size_t)T * l->max_n * sizeof(float),          /* wide */
      (size_t)H * T * S * sizeof(float),             /* attn */
      (size_t)H * T * l->pos_width * sizeof(float),  /* pos_raw */
      /* conv: rows padded to a multiple of four floats so each channel's row is sixteen byte
       * aligned for the depthwise, plus four floats of slack because a four wide output block
       * computes all four lanes even when fewer are wanted and so reads past the window */
      (size_t)D * ((((T + l->taps_causal - 1) + 3) & ~3) + 4) * sizeof(float),
      (size_t)D * T * sizeof(float),                 /* conv_a */
      (size_t)D * T * sizeof(float),                 /* conv_b */
  };
  l->need = 0;
  for (size_t i = 0; i < sizeof sizes / sizeof sizes[0]; ++i) {
    l->slot[i] = l->need;
    l->need += align_up(sizes[i]);
  }
  /* one activation buffer per task: the quantiser runs inside the matmul's own region now */
  l->qbuf_off = l->need;
  l->qbuf_stride = align_up((size_t)T * l->max_k_pad);
  l->need += l->qbuf_stride;
  l->acc_off = l->need;
  l->need += align_up((size_t)T * l->max_n * sizeof(int32_t));
  l->scales_off = l->need;
  l->need += align_up((size_t)l->max_n * sizeof(float));

  if (!arena_reserve(l->arena_ref, l->need)) {
    why = "cannot allocate the layer arena";
    goto fail;
  }
  bind_arena(l);

  {
    const int keep = l->taps_causal - 1;
    const size_t widths[5] = {(size_t)H * ZF_QUERY_DIM, (size_t)NA, (size_t)H * ZF_VALUE_DIM,
                              (size_t)H * ZF_VALUE_DIM, 0};
    l->cache_cap = left_context + S; /* one window plus a left context of slack */
    size_t off[6];
    size_t total = 0;
    for (int i = 0; i < 4; ++i) {
      off[i] = total;
      total += align_up((size_t)l->cache_cap * widths[i] * sizeof(float));
    }
    for (int i = 0; i < 2; ++i) {
      off[4 + i] = total;
      total += align_up((size_t)D * keep * sizeof(float));
    }
    l->cache_block = (unsigned char *)calloc(1, total);
    if (!l->cache_block) {
      why = "cannot allocate the layer caches";
      goto fail;
    }
    l->cache_bytes = total;
    l->kcat = (float *)(l->cache_block + off[0]);
    l->nacat = (float *)(l->cache_block + off[1]);
    l->vcat[0] = (float *)(l->cache_block + off[2]);
    l->vcat[1] = (float *)(l->cache_block + off[3]);
    l->cconv[0] = (float *)(l->cache_block + off[4]);
    l->cconv[1] = (float *)(l->cache_block + off[5]);
  }
  if (error) *error = NULL;
  return l;

fail:
  zf_layer_destroy(l);
  if (error) *error = why;
  return NULL;
}

void zf_layer_destroy(ZfLayer *l) {
  if (!l) return;
  for (int i = 0; i < 2; ++i) {
    free(l->cm_fold_w[i]);
    free(l->cm_fold_b[i]);
  }
  free(l->cache_block);
  if (l->arena_owned) zf_arena_destroy(l->arena_ref);
  free(l);
}

int zf_layer_dim(const ZfLayer *l) { return l ? l->dim : 0; }

int zf_layer_set_swoosh_l_offset(ZfLayer *l, float offset) {
  if (!l || (offset != 4.0f && offset != 1.0f)) return -1;
  l->swoosh_l_offset = offset;
  return 0;
}

int zf_layer_heads(const ZfLayer *l) { return l ? l->heads : 0; }

/* ---------------------------------------------------------------- the linear */

/* One parallel region per linear, quantiser included.
 *
 * The activation's scale is the whole block's range, so quantising it used to be two regions with
 * a barrier between them, and the matmul a third: three barriers for each of the 272 linears a
 * chunk. A barrier is not the pool's one microsecond of dispatch, it is however long the slowest
 * of four threads takes to arrive after memory-bound work, and that measured about eighteen. The
 * quantiser's stage timer read 9.9 ms a chunk for about 0.3 ms of arithmetic.
 *
 * So every task scans the block and quantises it into its own buffer. The scan and the write are
 * repeated once per thread instead of shared, which is about 0.8 ms a chunk of extra arithmetic,
 * and every task derives the same scale from the same values in the same order, so the integers
 * are exactly the ones the shipped graph's DynamicQuantizeLinear produces. Two barriers a linear
 * go away. */
static FILE *zf_dump_file(void);

typedef struct {
  ZfLayer *l;
  const ZfLinear *lin;
  const float *x; /* the activation, row major [m, k] or column major [k, m] */
  int m, tasks, swoosh, cols_in;
  float *y;
} LinearJob;

/* The activation's range, one task to a row band.
 *
 * This used to live inside quant_task, where every task scanned the WHOLE block and then wrote
 * only its own rows, on the argument that a read-only replication beats a barrier. The
 * replication is the one item in the cost model that does not get four times faster on four
 * cores: the region's wall time held one entire scan plus a quarter of the write. Measured by
 * lin_quant's thread time against thread count, 40.00 core-ms at one thread and 69.43 at four
 * over eight chunks, which separates the two parts: the scan is 1.23 core-ms a chunk replicated
 * per task and the write 3.77 split, so the wall was 1.23 + 0.94 and splitting the scan makes it
 * 0.31 + 0.94.
 *
 * Exact by construction rather than by argument: zf_quantize_range_rows already seeds lo and hi
 * at 0.0f, reduces each row on its own, and folds the rows with scalar `<` and `>`. Splitting the
 * row loop across tasks and folding the partials the same way leaves every comparison that
 * happens today happening, in the same grouping, including the vector reduction's treatment of a
 * signed zero, which is inside a row either way. */
static void qrange_task(void *user, size_t index) {
  const LinearJob *j = (const LinearJob *)user;
  const ZfWeightsS8 *w = &j->lin->w;
  const double t0 = ZF_NOW();
  int r0 = 0, r1 = 0;
  slice_of(j->m, j->tasks, index, &r0, &r1);
  float lo = 0.0f, hi = 0.0f;
  if (r0 < r1) zf_quantize_range_rows(j->x, w->k, &lo, &hi, r0, r1);
  j->l->qlo[index] = lo;
  j->l->qhi[index] = hi;
  ZF_STAGE(j->l, 6, ZF_NOW() - t0);
}

/* Fold the bands' ranges, then write this task's own rows of the shared buffer.
 *
 * Writing a private copy per task instead, which would remove this region's barrier too, costs
 * four times the writes over 881 thousand values a chunk, and measured worse than the barrier. */
static void quant_task(void *user, size_t index) {
  LinearJob jl = *(const LinearJob *)user;
  const int self_range = jl.tasks < 0; /* run_group_linear: scan the whole range here */
  if (self_range) jl.tasks = -jl.tasks;
  const LinearJob *j = &jl;
  const ZfWeightsS8 *w = &j->lin->w;
  const double t0 = ZF_NOW();
  float lo = 0.0f, hi = 0.0f, scale = 0.0f;
  int zp = 0, r0 = 0, r1 = 0;
  if (self_range) {
    zf_quantize_range_rows(j->x, w->k, &lo, &hi, 0, j->m);
  } else if (j->cols_in) {
    /* Only the convolution module's output linear reads columns, and zf_quantize_range_cols has
     * no row range to split, so these two a layer keep the whole scan. */
    zf_quantize_range_cols(j->x, w->k, j->m, j->m, &lo, &hi);
  } else {
    for (int t = 0; t < j->tasks; ++t) {
      if (j->l->qlo[t] < lo) lo = j->l->qlo[t];
      if (j->l->qhi[t] > hi) hi = j->l->qhi[t];
    }
  }
  zf_quantize_params(lo, hi, &scale, &zp);
  if (index == 0) {
    j->l->a_scale = scale;
    j->l->a_zp = zp;
    if (j->lin->scale_count == 1) j->l->scales[0] = scale * j->lin->scale[0];
    else
      for (int u = 0; u < j->lin->scale_count; ++u) j->l->scales[u] = scale * j->lin->scale[u];
  }
  slice_of(j->m, j->tasks, index, &r0, &r1);
  if (r0 < r1) {
    if (j->cols_in) {
      zf_quantize_write_cols(j->x, w->k, j->m, w->k_pad, j->l->qbuf, scale, zp, r0, r1);
    } else {
      zf_quantize_write_rows(j->x, w->k, w->k_pad, j->l->qbuf, scale, zp, r0, r1);
    }
  }
  ZF_STAGE(j->l, 6, ZF_NOW() - t0);
}

/* What this task owns: a range of output units and their combined scales. Returns zero when the
 * split left this task nothing to do. */
typedef struct {
  int8_t *a;
  float a_scale;
  int a_zp;
  int block0, block1, j0, j1;
} LinearSlice;

static int linear_blocks(const LinearJob *j, int block0, int block1, LinearSlice *out) {
  const ZfWeightsS8 *w = &j->lin->w;
  out->block0 = block0;
  out->block1 = block1;
  if (out->block0 >= out->block1) return 0;
  out->j0 = out->block0 * ZF_S8_UNIT_BLOCK;
  out->j1 = out->block1 * ZF_S8_UNIT_BLOCK;
  if (out->j1 > w->n) out->j1 = w->n;
  out->a = j->l->qbuf;
  out->a_scale = j->l->a_scale;
  out->a_zp = j->l->a_zp;
  return 1;
}

static int linear_slice(const LinearJob *j, size_t index, LinearSlice *out) {
  const int nb = j->lin->w.n_blocks;
  return linear_blocks(j, (int)((size_t)nb * index / (size_t)j->tasks),
                       (int)((size_t)nb * (index + 1) / (size_t)j->tasks), out);
}

static FILE *zf_dump_file(void);

static void linear_range(const LinearJob *j, const LinearSlice *tp);
static void linear_task(void *user, size_t index) {
  const LinearJob *j = (const LinearJob *)user;
  LinearSlice t;
  if (linear_slice(j, index, &t)) linear_range(j, &t);
}
static void linear_range(const LinearJob *j, const LinearSlice *tp) {
  const ZfWeightsS8 *w = &j->lin->w;
  const LinearSlice t = *tp;
  const double t0 = ZF_NOW();
  /* This task's own tile, packed: its columns of every row, end to end. The tasks' ranges are
   * disjoint and in order, so tile t starts at j0 * m in the same allocation the slab used, and a
   * task's few kilobytes stay in level one cache instead of being scattered down a 55 kilobyte
   * slab at the row stride of the whole linear. */
  if (j->lin->dot) {
    /* the dot kernel writes the whole row, so it takes the slab rather than a packed tile */
    zf_linear_s8_dot_range(t.a, j->m, w->k_pad, w, t.a_zp, j->l->acc, w->n, t.block0, t.block1);
    zf_dequantize_range(j->l->acc, j->m, w->n, j->l->scales, j->lin->scale_count, j->lin->bias,
                        j->y, w->n, t.j0, t.j1);
  } else {
    /* This task's own tile, packed: its columns of every row, end to end, then scaled into the
     * shared result in one pass.
     *
     * The microkernel can scale in its epilogue and store float directly, which is what the front
     * end's convolutions do and what saves them 0.70 ms. Here it costs 0.62 ms instead, measured
     * six times out of six, and the reason is the shape of the write rather than the amount of
     * work. A task owns a range of output columns, not whole rows, so storing float straight into
     * the result writes a stripe down a wide row: at both ends of the stripe it shares a cache line
     * with the neighbouring task, and four cores then pass those lines back and forth for every row
     * of every one of a chunk's 272 linears. Accumulating into a private tile first keeps the
     * task's few kilobytes to itself, and the scaling pass that follows reads and writes it
     * contiguously. The front end has no such problem because its tasks own whole pixel rows. */
    const int cols = t.j1 - t.j0;
    int32_t *tile = j->l->acc + (size_t)t.j0 * j->m;
    {
      zf_linear_s8_tile(t.a, j->m, w->k_pad, w, t.a_zp, tile, cols, t.block0, t.block1, t.j0);
      zf_dequantize_tile(tile, j->m, cols, j->l->scales, j->lin->scale_count, j->lin->bias, j->y,
                         w->n, t.j0);
    }
  }
  const double t2 = ZF_NOW();
  ZF_STAGE(j->l, 15, t2 - t0);
  if (j->swoosh) {
    /* fused into the same pass, so the activation is never written and read back */
    for (int i = 0; i < j->m; ++i) {
      float *row = j->y + (size_t)i * w->n + t.j0;
      if (j->swoosh == 1) zf_swoosh_l_at(row, row, (size_t)(t.j1 - t.j0), j->l->swoosh_l_offset);
      else zf_swoosh_r(row, row, (size_t)(t.j1 - t.j0));
    }
    ZF_STAGE(j->l, 17, ZF_NOW() - t2);
  }
}

/* The same, writing the result transposed: the convolution module wants one row per channel. */
static void linear_t_range(const LinearJob *j, const LinearSlice *tp);
static void linear_t_task(void *user, size_t index) {
  const LinearJob *j = (const LinearJob *)user;
  LinearSlice t;
  if (linear_slice(j, index, &t)) linear_t_range(j, &t);
}
static void linear_t_range(const LinearJob *j, const LinearSlice *tp) {
  const ZfWeightsS8 *w = &j->lin->w;
  const LinearSlice t = *tp;
  const double t0 = ZF_NOW();
  if (j->lin->dot) {
    zf_linear_s8_dot_range(t.a, j->m, w->k_pad, w, t.a_zp, j->l->acc, w->n, t.block0, t.block1);
    zf_dequantize_range_t(j->l->acc, j->m, w->n, j->l->scales, j->lin->scale_count, j->lin->bias,
                          j->y, j->m, t.j0, t.j1);
  } else {
    const int cols = t.j1 - t.j0;
    int32_t *tile = j->l->acc + (size_t)t.j0 * j->m;
    zf_linear_s8_tile(t.a, j->m, w->k_pad, w, t.a_zp, tile, cols, t.block0, t.block1, t.j0);
    zf_dequantize_tile_t(tile, j->m, cols, j->l->scales, j->lin->scale_count, j->lin->bias, j->y,
                         j->m, t.j0);
  }
  /* the transposed linears were the one part of the region with no timer of their own, which left
   * 26 core-ms a chunk of real work looking like unexplained overhead */
  ZF_STAGE(j->l, 16, ZF_NOW() - t0);
}

/* ZF_DUMP_LAYER: every linear's int32 accumulator and its dequantised output, in execution order.
 *
 * The layers agree with the graph to about 4e-06 with exact input, and the question this answers is
 * which operation inside the layer that 4e-06 comes from. The graph exposes the same two tensors per
 * linear -- MatMul_output_0_output_quantized is the int32 and MatMul_output_0 is it scaled -- so a
 * matching pair says the integer path is exact and the float epilogue is not, or the reverse.
 *
 * Records: int32 index, int32 m, int32 n, int32 acc_bytes, the int32 accumulator, int32 out_bytes,
 * the fp32 output. Written only when the variable is set. */
static FILE *zf_dump_file(void) {
  static FILE *f = NULL;
  static _Atomic int tried = 0;
  if (!tried) {
    tried = 1;
    const char *p = zf_getenv("ZF_DUMP_LAYER");
    if (p) f = fopen(p, "wb");
  }
  return f;
}

static void zf_dump_linear(int index, int m, int n, const int32_t *acc, const float *y, int ldy) {
  FILE *f = zf_dump_file();
  if (!f) return;
  const int32_t hdr[3] = {index, m, n};
  fwrite(hdr, sizeof(int32_t), 3, f);
  int32_t nb = (int32_t)((size_t)m * n * sizeof(int32_t));
  fwrite(&nb, 4, 1, f);
  for (int i = 0; i < m; ++i) fwrite(acc + (size_t)i * n, sizeof(int32_t), (size_t)n, f);
  nb = (int32_t)((size_t)m * n * sizeof(float));
  fwrite(&nb, 4, 1, f);
  for (int i = 0; i < m; ++i) fwrite(y + (size_t)i * ldy, sizeof(float), (size_t)n, f);
  fflush(f);
}

/* The activation's quantisation for one linear, leaving `job` ready for the product's tasks. */
static void linear_prepare(ZfLayer *l, const ZfLinear *lin, const float *x, int m, float *y,
                           int swoosh, int cols_in, const ZfParallel *par,
                           LinearJob *out, int *defer_qtasks) {
  l->madds += (double)m * (double)lin->w.n * (double)lin->w.k;
  int tasks = par_threads(par);
  if (tasks > 1) tasks *= task_mult();
  if (tasks > lin->w.n_blocks) tasks = lin->w.n_blocks;
  if (tasks > ZF_MAX_TASKS) tasks = ZF_MAX_TASKS;
  if (tasks < 1) tasks = 1;
  LinearJob job = {l, lin, x, m, tasks, swoosh, cols_in, y};
  int qtasks = tasks > m ? m : tasks;
  if (qtasks < 1) qtasks = 1;
  job.tasks = qtasks;
  /* The range first, one band a task, then the fold and the write. The extra dispatch costs about
   * 0.77 us against the whole scan's replication it removes.
   *
   * Refuted: doing both on the calling thread when the block is small. The pool report shows these
   * two regions at 46 and 82 per cent busy, but serial measured worse at every threshold tried
   * (chunk minimum 78.5 ms with the regions, 79.0 at 2048 values, 80.4 at 4096, 82.6 at 16384):
   * the idle cores cost less than one core doing all of it. */
  /* ZF_QUANT_SERIAL=N: blocks of at most N values are ranged and quantised on the calling thread,
   * two barriers a linear fewer. The note above holds on the Alcatel. On Apple cores it reverses
   * where it matters: a live stream's chunk arrives with the cores clocked down and six threads to
   * wake, and there, on an iPhone 15 Pro Max, three interleaved rounds gave 13.07, 13.05, 12.31 ms
   * serial against 13.42, 13.82, 14.11 with the regions; back to back on two P cores it costs about
   * 0.1 ms (6.37 against 6.26). So Apple defaults to serial, everything else to the regions. The
   * integers are the same either way (see qrange_task). */
  static _Atomic int serial_max = -1;
  if (serial_max < 0) {
    const char *v = zf_getenv("ZF_QUANT_SERIAL");
#if defined(__APPLE__)
    serial_max = v ? atoi(v) : 1 << 30;
#else
    serial_max = v ? atoi(v) : 0;
#endif
  }
  if (defer_qtasks) {
    /* the caller runs the range and the write, with other chunks' in the same regions */
    *defer_qtasks = (long)m * lin->w.k <= serial_max ? 1 : qtasks;
  } else if ((long)m * lin->w.k <= serial_max) {
    job.tasks = 1;
    if (!cols_in) qrange_task(&job, 0);
    quant_task(&job, 0);
  } else {
    if (!cols_in) dispatch(par, qrange_task, qtasks, &job);
    dispatch(par, quant_task, qtasks, &job);
  }
  job.tasks = tasks;
  *out = job;
}

static void run_one(ZfLayer *l, const ZfLinear *lin, const float *x, int m, float *y, int swoosh,
                    int cols_in, void (*fn)(void *, size_t), const ZfParallel *par) {
  const double t_start = ZF_NOW();
  LinearJob job;
  linear_prepare(l, lin, x, m, y, swoosh, cols_in, par, &job, NULL);
  dispatch(par, fn, job.tasks, &job);
  if (zf_dump_file() && fn == linear_task) {
    static _Atomic int seq = 0;
    /* ZF_DUMP_ONE selects a single linear by its position in the layer's execution order, because
     * dumping all seventeen is eight megabytes and this phone's USB link does not survive a pull
     * that size. One linear is about fifty kilobytes. */
    static _Atomic int only = -2;
    if (only == -2) {
      const char *v = zf_getenv("ZF_DUMP_ONE");
      only = v ? atoi(v) : -1;
    }
    if (only < 0 || seq == only) zf_dump_linear(seq, m, lin->w.n, l->acc, y, lin->w.n);
    ++seq;
  }
  const double t_end = ZF_NOW();
  ZF_STAGE(l, 7, t_end - t_start);
  ZF_STAGE(l, 0, t_end - t_start);
}

static void run_linear(ZfLayer *l, const ZfLinear *lin, const float *x, int m, float *y,
                       int swoosh, const ZfParallel *par) {
  run_one(l, lin, x, m, y, swoosh, 0, linear_task, par);
}

/* x is [m, k] as usual; y comes out [n, m]. */
static void run_linear_to_cols(ZfLayer *l, const ZfLinear *lin, const float *x, int m, float *y,
                               const ZfParallel *par) {
  run_one(l, lin, x, m, y, 0, 0, linear_t_task, par);
}

/* xT is [k, m] at row stride m; y comes out [m, n] as usual. */
static void run_linear_from_cols(ZfLayer *l, const ZfLinear *lin, const float *xT, int m, float *y,
                                 const ZfParallel *par) {
  run_one(l, lin, xT, m, y, 0, 1, linear_task, par);
}

/* --------------------------------------------------------------- small parts */

static void add_into(float *dst, const float *src, size_t n) {
  size_t i = 0;
#if ZF_NEON_AVAILABLE
  for (; i + 4 <= n; i += 4)
    vst1q_f32(dst + i, vaddq_f32(vld1q_f32(dst + i), vld1q_f32(src + i)));
#endif
  for (; i < n; ++i) dst[i] += src[i];
}

/* out[m][n] = sum_s a[m][s] * b[s][n], b's rows strided.
 *
 * Three things make this fast enough to matter, because it is the float32 attention product and the
 * obvious loop ran at a quarter of a product a cycle.
 *
 * The accumulators stay in registers for the whole sum, in a tile of four rows by eight columns.
 * Writing it with the accumulators in memory costs a load, a store and a multiply-add per four
 * products.
 *
 * The weights reach the multiplier from a register lane, not from a general register. A scalar
 * broadcast has to cross from the integer side, which on this in-order core stalls about eight
 * cycles on the critical path of every term.
 *
 * And the terms that contribute are found once per tile rather than tested per column block. The
 * masked keys are exactly zero after the softmax, and with a 256 frame left context most of the
 * window is padding until the stream has run long enough to fill it, so the saving is large early
 * and free later. The order of the surviving terms is unchanged, so the result is bit for bit what
 * the straightforward loop produced. */
#define ZF_NN_MAX_S 512

static void matmul_nn_one(const float *a, int lda, const float *b, int ldb, int m, int n, int s,
                          float *out, int ldc);

static int zf_nn_ort(void) {
  static _Atomic int on = -1;
  if (on < 0) {
    const char *v = zf_getenv("ZF_CONV_ORT");
    on = v && atoi(v);
  }
  return on;
}

/* matmul_nn in MLAS's k strides.
 *
 * The body sums every k straight through, which is MLAS's order only when its stride covers the
 * whole depth. It does for the attention values (N = 12, stride 1024) and does not for the
 * nonlinear attention (N = 144 at S = 280: 128 + 128 + 24; N = 192 at S = 140: 128 + 12), so the
 * caller passes the stride zf_mlas_stride_k gives for ONNX Runtime's own N, which is the full
 * width, not this task's slice of it.
 *
 * Each stride is summed from +0.0 by the body into a scratch and folded into `out` in order, the
 * first stored rather than added, which is what MLAS does with C. Rows are independent, so the
 * scratch is filled a band of rows at a time. The fold is done in NEON even for the last few
 * columns, because MLAS's fold is, and on ARMv7 only NEON flushes denormals. */
#define ZF_NN_PART 4096

static void matmul_nn(const float *a, int lda, const float *b, int ldb, int m, int n, int s,
                      float *out, int ldc, int kblock) {
  if (!zf_nn_ort() || kblock <= 0 || s <= kblock || n > ZF_NN_PART) {
    matmul_nn_one(a, lda, b, ldb, m, n, s, out, ldc);
    return;
  }
  matmul_nn_one(a, lda, b, ldb, m, n, kblock, out, ldc);
  float part[ZF_NN_PART];
  const int band = ZF_NN_PART / n;
  for (int kb = kblock; kb < s; kb += kblock) {
    const int len = (s - kb < kblock) ? s - kb : kblock;
    for (int i0 = 0; i0 < m; i0 += band) {
      const int rows = (m - i0 < band) ? m - i0 : band;
      matmul_nn_one(a + (size_t)i0 * lda + kb, lda, b + (size_t)kb * ldb, ldb, rows, n, len, part,
                    n);
      for (int r = 0; r < rows; ++r) {
        float *o = out + (size_t)(i0 + r) * ldc;
        const float *q = part + (size_t)r * n;
        int j = 0;
#if ZF_NEON_AVAILABLE
        for (; j + 4 <= n; j += 4) vst1q_f32(o + j, vaddq_f32(vld1q_f32(o + j), vld1q_f32(q + j)));
        for (; j < n; ++j)
          o[j] = vgetq_lane_f32(vaddq_f32(vdupq_n_f32(o[j]), vdupq_n_f32(q[j])), 0);
#else
        for (; j < n; ++j) o[j] += q[j];
#endif
      }
    }
  }
}

static void matmul_nn_one(const float *a, int lda, const float *b, int ldb, int m, int n, int s,
                          float *out, int ldc) {
#if ZF_NEON_AVAILABLE
  int16_t idx[ZF_NN_MAX_S];
#endif
  int i = 0;
#if ZF_NEON_AVAILABLE
  for (; s <= ZF_NN_MAX_S && i + 4 <= m; i += 4) {
    const float *a0 = a + (size_t)i * lda;
    const float *a1 = a0 + lda, *a2 = a1 + lda, *a3 = a2 + lda;
    float *o0 = out + (size_t)i * ldc;
    int count = 0;
    for (int p = 0; p < s; ++p)
      if (a0[p] != 0.0f || a1[p] != 0.0f || a2[p] != 0.0f || a3[p] != 0.0f)
        idx[count++] = (int16_t)p;
    int j = 0;
    for (; j + 8 <= n; j += 8) {
      float32x4_t c00 = vdupq_n_f32(0.0f), c01 = c00, c10 = c00, c11 = c00;
      float32x4_t c20 = c00, c21 = c00, c30 = c00, c31 = c00;
      for (int q = 0; q < count; ++q) {
        const int p = idx[q];
        float32x4_t av = vld1q_dup_f32(a0 + p);
        av = vld1q_lane_f32(a1 + p, av, 1);
        av = vld1q_lane_f32(a2 + p, av, 2);
        av = vld1q_lane_f32(a3 + p, av, 3);
        const float32x2_t vl = vget_low_f32(av), vh = vget_high_f32(av);
        const float *brow = b + (size_t)p * ldb + j;
        const float32x4_t b0 = vld1q_f32(brow), b1 = vld1q_f32(brow + 4);
        c00 = vmlaq_lane_f32(c00, b0, vl, 0);
        c01 = vmlaq_lane_f32(c01, b1, vl, 0);
        c10 = vmlaq_lane_f32(c10, b0, vl, 1);
        c11 = vmlaq_lane_f32(c11, b1, vl, 1);
        c20 = vmlaq_lane_f32(c20, b0, vh, 0);
        c21 = vmlaq_lane_f32(c21, b1, vh, 0);
        c30 = vmlaq_lane_f32(c30, b0, vh, 1);
        c31 = vmlaq_lane_f32(c31, b1, vh, 1);
      }
      vst1q_f32(o0 + j, c00);
      vst1q_f32(o0 + j + 4, c01);
      vst1q_f32(o0 + ldc + j, c10);
      vst1q_f32(o0 + ldc + j + 4, c11);
      vst1q_f32(o0 + 2 * (size_t)ldc + j, c20);
      vst1q_f32(o0 + 2 * (size_t)ldc + j + 4, c21);
      vst1q_f32(o0 + 3 * (size_t)ldc + j, c30);
      vst1q_f32(o0 + 3 * (size_t)ldc + j + 4, c31);
    }
    for (; j + 4 <= n; j += 4) {
      float32x4_t c0 = vdupq_n_f32(0.0f), c1 = c0, c2 = c0, c3 = c0;
      for (int q = 0; q < count; ++q) {
        const int p = idx[q];
        float32x4_t av = vld1q_dup_f32(a0 + p);
        av = vld1q_lane_f32(a1 + p, av, 1);
        av = vld1q_lane_f32(a2 + p, av, 2);
        av = vld1q_lane_f32(a3 + p, av, 3);
        const float32x2_t vl = vget_low_f32(av), vh = vget_high_f32(av);
        const float32x4_t bv = vld1q_f32(b + (size_t)p * ldb + j);
        c0 = vmlaq_lane_f32(c0, bv, vl, 0);
        c1 = vmlaq_lane_f32(c1, bv, vl, 1);
        c2 = vmlaq_lane_f32(c2, bv, vh, 0);
        c3 = vmlaq_lane_f32(c3, bv, vh, 1);
      }
      vst1q_f32(o0 + j, c0);
      vst1q_f32(o0 + ldc + j, c1);
      vst1q_f32(o0 + 2 * (size_t)ldc + j, c2);
      vst1q_f32(o0 + 3 * (size_t)ldc + j, c3);
    }
    for (; j < n; ++j)
      for (int r = 0; r < 4; ++r) {
        float acc = 0.0f;
        for (int q = 0; q < count; ++q) {
          const int p = idx[q];
          acc += a0[(size_t)r * lda + p] * b[(size_t)p * ldb + j];
        }
        o0[(size_t)r * ldc + j] = acc;
      }
  }
#endif
  for (; i < m; ++i) {
    const float *arow = a + (size_t)i * lda;
    float *orow = out + (size_t)i * ldc;
    int j = 0;
#if ZF_NEON_AVAILABLE
    for (; j + 8 <= n; j += 8) {
      float32x4_t c0 = vdupq_n_f32(0.0f), c1 = c0;
      for (int p = 0; p < s; ++p) {
        const float32x2_t v = vld1_dup_f32(arow + p);
        if (vget_lane_f32(v, 0) == 0.0f) continue;
        const float *brow = b + (size_t)p * ldb + j;
        c0 = vmlaq_lane_f32(c0, vld1q_f32(brow), v, 0);
        c1 = vmlaq_lane_f32(c1, vld1q_f32(brow + 4), v, 0);
      }
      vst1q_f32(orow + j, c0);
      vst1q_f32(orow + j + 4, c1);
    }
    for (; j + 4 <= n; j += 4) {
      float32x4_t c0 = vdupq_n_f32(0.0f);
      for (int p = 0; p < s; ++p) {
        const float32x2_t v = vld1_dup_f32(arow + p);
        if (vget_lane_f32(v, 0) == 0.0f) continue;
        c0 = vmlaq_lane_f32(c0, vld1q_f32(b + (size_t)p * ldb + j), v, 0);
      }
      vst1q_f32(orow + j, c0);
    }
#endif
    for (; j < n; ++j) {
      float acc = 0.0f;
      for (int p = 0; p < s; ++p) acc += arow[p] * b[(size_t)p * ldb + j];
      orow[j] = acc;
    }
  }
}

/* The attention scores, in one pass per head and frame block.
 *
 * A row of scores is a query against the key cache, plus the position term through its own small
 * integer matmul and the fixed gather the graph applies, then the key padding mask, then a softmax.
 * These were four regions with four barriers between them, and each was small enough that the
 * barrier cost as much as the arithmetic; the row also went to memory and came back three times.
 * Now one task owns a block of rows from the query to the softmax and the row stays in cache. */
typedef struct {
  ZfLayer *l;
  const float *key_pad;
  int saw_n, T, S, tasks, tblock;
  float pos_scale;
  int pos_zp;
} ScoreJob;

static void score_slice(void *user, size_t index) {
  const ScoreJob *j = (const ScoreJob *)user;
  ZfLayer *l = j->l;
  const int H = l->heads, Q = ZF_QUERY_DIM, P = ZF_POS_DIM, W = l->pos_width;
  const int T = j->T, S = j->S, blocks = (T + j->tblock - 1) / j->tblock;
  int unit0, unit1;
  slice_of(H * blocks, j->tasks, index, &unit0, &unit1);
  for (int unit = unit0; unit < unit1; ++unit) {
    const int h = unit / blocks, blk = unit % blocks;
    const int t0 = blk * j->tblock;
    int t1 = t0 + j->tblock;
    if (t1 > T) t1 = T;
    if (t0 >= t1) continue;
    float *rows = l->attn + ((size_t)h * T + t0) * S;

    /* The query against the whole key window.
     *
     * This runs at 0.16 products a cycle, about five times off what its instruction count implies,
     * and the two obvious causes are not it: the query rows are strided by the attention linear's
     * full width, 272 floats, and copying them contiguous first changed nothing, and neither did
     * prefetching. Recorded rather than explained. */
    const double tq = ZF_NOW();
    zf_matmul_nt_f32(l->wide + (size_t)t0 * j->saw_n + (size_t)h * Q, j->saw_n,
                     l->kwin + (size_t)h * Q, H * Q, t1 - t0, S, Q, rows, S);
    const double tp = ZF_NOW();
    ZF_STAGE(l, 18, tp - tq);

    /* The position term: a four by width integer matmul a frame, then the graph's gather.
     *
     * Written as a scalar triple loop this was about seven milliseconds of single-core time a
     * chunk, half the whole score region, for 2.2M multiply-adds. The weight is contiguous along
     * the width, so four taps times a scalar accumulate four outputs at a time. */
    const int8_t *weight = l->pos_weight + (size_t)h * P * W;
    for (int t = t0; t < t1; ++t) {
      const int8_t *p = l->qbuf + (size_t)t * H * P + (size_t)h * P;
      float *raw = l->pos_raw + ((size_t)h * T + t) * W;
      int col = 0;
#if ZF_NEON_AVAILABLE
      const float32x4_t vscale = vdupq_n_f32(j->pos_scale);
      /* eight columns at a time: vld1_s8 needs only byte alignment, which is all a row of int8
       * weights at an arbitrary column offset can promise */
      for (; col + 8 <= W; col += 8) {
        int32x4_t acc0 = vdupq_n_s32(0), acc1 = acc0;
        for (int c = 0; c < P; ++c) {
          const int32_t av = (int32_t)p[c] + 128 - j->pos_zp;
          const int16x8_t wv = vmovl_s8(vld1_s8(weight + (size_t)c * W + col));
          acc0 = vmlaq_n_s32(acc0, vmovl_s16(vget_low_s16(wv)), av);
          acc1 = vmlaq_n_s32(acc1, vmovl_s16(vget_high_s16(wv)), av);
        }
        vst1q_f32(raw + col, vmulq_f32(vcvtq_f32_s32(acc0), vscale));
        vst1q_f32(raw + col + 4, vmulq_f32(vcvtq_f32_s32(acc1), vscale));
      }
#endif
      for (; col < W; ++col) {
        int32_t sum = 0;
        for (int c = 0; c < P; ++c)
          sum += ((int32_t)p[c] + 128 - j->pos_zp) * (int32_t)weight[(size_t)c * W + col];
        raw[col] = (float)sum * j->pos_scale;
      }
      const int32_t *idx = l->pos_index + ((size_t)h * T + t) * S;
      float *dst = l->attn + ((size_t)h * T + t) * S;
      for (int s = 0; s < S; ++s) dst[s] += raw[idx[s]];
      const double tm0 = ZF_NOW();
      if (j->key_pad)
        for (int s = 0; s < S; ++s)
          if (j->key_pad[s] != 0.0f) dst[s] = ZF_MASK_SCORE;
      ZF_STAGE(l, 20, ZF_NOW() - tm0);
    }
    const double ts0 = ZF_NOW();
    ZF_STAGE(l, 19, ts0 - tp); /* the position term and its gather, mask included */
    zf_softmax_rows_f32(rows, t1 - t0, S);
    ZF_STAGE(l, 21, ZF_NOW() - ts0);
  }
}

/* The elementwise tails: a residual add, the final norm and the two bypasses, each one pass over
 * [frames, dim].
 *
 * These stay on the calling thread. A layer's widest is 24 by 192, about 55 kilobytes of traffic,
 * which one core finishes in roughly twenty microseconds; splitting it cost more than that. What a
 * region costs to split here is not the pool's dispatch, which is about a microsecond measured on
 * its own, but the skew between four threads arriving at the next barrier after memory-bound work,
 * and that is tens of microseconds whatever the region's size. */
/* Swept on device: 128 beats 512 and 2048 by about 0.1 ms, three reps in four. The dispatch costs
 * 0.77 us and the deep stacks hand these passes 1536 values, so the old threshold left them on one
 * thread for no reason. */
/* Read once, not per call. As a macro this expanded to zf_env_int inside `tail`, which a chunk
 * calls 176 times, so every one of them walked the environment array looking for a variable that
 * is almost never set. */
static size_t zf_tail_split_min(void) {
  static _Atomic size_t v = (size_t)-1;
  if (v == (size_t)-1) v = (size_t)zf_env_int("ZF_TAIL_SPLIT_MIN", 128);
  return v;
}
typedef struct {
  float *dst;
  const float *a, *b;
  const float *bias;
  const float *weight;
  float scale;
  int rows, dim, tasks, kind; /* 0 add into dst, 1 bias then norm, 2 bypass */
} TailJob;

static void tail_slice(void *user, size_t index) {
  const TailJob *j = (const TailJob *)user;
  int r0, r1;
  slice_of(j->rows, j->tasks, index, &r0, &r1);
  if (r0 >= r1) return;
  const size_t off = (size_t)r0 * j->dim;
  const int rows = r1 - r0;
  if (j->kind == 0) add_into(j->dst + off, j->a + off, (size_t)rows * j->dim);
  else if (j->kind == 1) zf_bias_norm(j->a + off, rows, j->dim, j->bias, j->scale, j->dst + off);
  else zf_bypass(j->a + off, j->b + off, rows, j->dim, j->weight, j->dst + off);
}

/* ZF_GROUP_TAIL_SERIAL: a lockstep group's tail of at most this many values runs on the calling
 * thread (a region costs more than the adds), default 65536 */
static long zf_group_tail_serial(void) {
  static long v = -1;
  if (v < 0) v = zf_env_int("ZF_GROUP_TAIL_SERIAL", 65536);
  return v;
}

static void tail_plan(const ZfParallel *par, TailJob *job, int rows, int dim) {
  job->rows = rows;
  job->dim = dim;
  job->tasks = (size_t)rows * (size_t)dim >= zf_tail_split_min() ? plan_tasks(par, rows) : 1;
  if (job->tasks < 1) job->tasks = 1;
}

static void tail(const ZfParallel *par, TailJob *job, int rows, int dim) {
  job->rows = rows;
  job->dim = dim;
  job->tasks = (size_t)rows * (size_t)dim >= zf_tail_split_min() ? plan_tasks(par, rows) : 1;
  if (job->tasks < 1) job->tasks = 1;
  dispatch(par, tail_slice, job->tasks, job);
}

/* The convolution module, split over channels.
 *
 * Everything between the two linears is per channel and independent: the sigmoid gate, the
 * transpose into [channel, frame], the cache rotation, both depthwise convolutions, the constant
 * mask combine, the transpose back and SwooshR. The stage timer showed 36 ms a chunk here, about
 * 25 of it in these non-arithmetic passes, and on one thread. */
typedef struct {
  ZfLayer *l;
  int which, T, tasks, n;
  const float *frame_pad;
  float *cache;
} ConvJob;

/* The convolution buffer's row stride, rounded up so every channel's row starts on a sixteen byte
 * boundary. See the note on zf_conv_dw1d_f32: the depthwise reads each row once per tap, so the
 * rows' alignment is worth more than anything else about this buffer. */
static int conv_row_stride(int T, int keep) { return ((T + keep) + 3) & ~3; }

static void conv_body(const ConvJob *j, size_t index);

static void conv_pre(void *user, size_t index) {
  const ConvJob *j = (const ConvJob *)user;
  const double t_in = ZF_NOW();
  ZfLayer *l = j->l;
  const int D = l->dim, T = j->T, keep = l->taps_causal - 1;
  const int cstride = conv_row_stride(T, keep);
  int c0, c1;
  slice_of(D, j->tasks, index, &c0, &c1);
  /* Whether any frame is padding is a property of the chunk, not of the channel, and for a full
   * chunk the answer is no. Asking per channel per frame was 83 thousand scalar loads, compares and
   * branches a chunk to do nothing at all; asking once is T of them. */
  int pad_any = 0;
  if (j->frame_pad)
    for (int t = 0; t < T; ++t)
      if (j->frame_pad[t] != 0.0f) { pad_any = 1; break; }
  /* The gate for the whole band in one call. Per channel it was a call over three to twenty four
   * values, and three values do not reach the vector path, so the deep stacks were making about
   * seventeen thousand expf calls a chunk. In channel-major order the band is contiguous. */
  zf_sigmoid_f32(l->wide + (size_t)(D + c0) * T, l->wide + (size_t)(D + c0) * T,
                 (size_t)(c1 - c0) * T);
  for (int c = c0; c < c1; ++c) {
    const float *value = l->wide + (size_t)c * T;
    const float *gate = l->wide + (size_t)(D + c) * T;
    float *dst = l->conv + (size_t)c * cstride + keep;
    int t = 0;
#if ZF_NEON_AVAILABLE
    for (; t + 4 <= T; t += 4)
      vst1q_f32(dst + t, vmulq_f32(vld1q_f32(value + t), vld1q_f32(gate + t)));
#endif
    for (; t < T; ++t) dst[t] = value[t] * gate[t];
    if (pad_any)
      for (t = 0; t < T; ++t)
        if (j->frame_pad[t] != 0.0f) dst[t] = 0.0f;
  }
  /* the causal window's left edge comes from the cache, and the cache becomes this chunk's tail */
  for (int c = c0; c < c1; ++c)
    memcpy(l->conv + (size_t)c * cstride, j->cache + (size_t)c * keep,
           (size_t)keep * sizeof(float));
  for (int c = c0; c < c1; ++c)
    memcpy(j->cache + (size_t)c * keep, l->conv + (size_t)c * cstride + T,
           (size_t)keep * sizeof(float));
  ZF_STAGE(l, 12, ZF_NOW() - t_in);
  conv_body(j, index);
}

/* The rest of the module for the same band. This used to be a second region, but a task reads
 * only the channels it just wrote, so the barrier between them bought nothing. */
static void conv_body(const ConvJob *j, size_t index) {
  ZfLayer *l = j->l;
  const int D = l->dim, T = j->T, which = j->which;
  const int taps_c = l->taps_causal, taps_k = l->taps_chunk, keep = taps_c - 1;
  int c0, c1;
  slice_of(D, j->tasks, index, &c0, &c1);
  if (c0 >= c1) return;
  const double t_dw = ZF_NOW();
  /* causal: the whole window, no padding. chunkwise: this chunk only, padded both sides. */
  const int cstride = conv_row_stride(T, keep);
  zf_conv_dw1d_f32(l->conv, D, T + keep, cstride, l->cm_causal_w[which], taps_c, 1, 0,
                   l->cm_causal_b[which], l->conv_a, T, c0, c1);
  for (int c = c0; c < c1; ++c)
    memcpy(l->conv_b + (size_t)c * T, l->conv + (size_t)c * cstride + keep,
           (size_t)T * sizeof(float));
  const int fold = l->cm_fold_w[which] != NULL;
  zf_conv_dw1d_f32(l->conv_b, D, T, T, fold ? l->cm_fold_w[which] : l->cm_chunk_w[which], taps_k,
                   1, (taps_k - 1) / 2, fold ? l->cm_fold_b[which] : l->cm_chunk_b[which],
                   l->conv_b, T, c0, c1);
  const double t_post = ZF_NOW();
  ZF_STAGE(l, 13, t_post - t_dw);
  /* the graph computes chunkwise * constant + causal, then SwooshR over the same rows; at one
   * frame the constant is already in the chunkwise weights (see cm_fold_w) */
  if (fold) {
    for (int c = c0; c < c1; ++c) l->conv_a[c] += l->conv_b[c];
  } else {
    for (int c = c0; c < c1; ++c)
      for (int t = 0; t < T; ++t) {
        const size_t at = (size_t)c * T + t;
        l->conv_a[at] += l->conv_b[at] * l->cm_mask[which][at];
      }
  }
  zf_swoosh_r(l->conv_a + (size_t)c0 * T, l->conv_a + (size_t)c0 * T, (size_t)(c1 - c0) * T);
  ZF_STAGE(l, 14, ZF_NOW() - t_post);
}

static void conv_module(ZfLayer *l, int which, float *x, int T, const float *frame_pad,
                        float *cache, const ZfParallel *par) {
  const int D = l->dim;
  run_linear_to_cols(l, &l->cm_in[which], x, T, l->wide, par);
  ConvJob job = {l,      which,                 T,          plan_tasks(par, D / 16),
                 l->cm_in[which].w.n, frame_pad, cache};
  if (job.tasks < 1) job.tasks = 1;
  const double t0 = ZF_NOW();
  dispatch(par, conv_pre, job.tasks, &job);
  ZF_STAGE(l, 8, ZF_NOW() - t0);
  run_linear_from_cols(l, &l->cm_out[which], l->conv_a, T, l->conv_b, par);
  const double te = ZF_NOW();
  /* Every other residual in this layer goes through `tail`, which splits it; this one was written
   * before that helper existed and stayed on the calling thread. Serial time is the expensive kind
   * here: a millisecond of it wastes three more in cores that are spinning. */
  {
    TailJob job = {x, l->conv_b, NULL, NULL, NULL, 0.0f, 0, 0, 1, 0};
    tail(par, &job, T, D);
  }
  ZF_STAGE(l, 11, ZF_NOW() - te);
}

/* The attention product against the cached values, one task per head. */
typedef struct {
  ZfLayer *l;
  int T, S, width, tasks, pass;
} ValueJob;

static void value_slice(void *user, size_t index) {
  const ValueJob *j = (const ValueJob *)user;
  ZfLayer *l = j->l;
  const int V = ZF_VALUE_DIM;
  int b, e;
  slice_of(l->heads, j->tasks, index, &b, &e);
  for (int h = b; h < e; ++h)
    matmul_nn(l->attn + (size_t)h * j->T * j->S, j->S, l->vwin[j->pass] + (size_t)h * V, j->width,
              j->T, V,
              j->S, l->conv_b + (size_t)h * V, j->width, zf_mlas_stride_k(V, j->S));
}

/* Nonlinear attention: tanh and the gate per channel band, then the product over channel bands. */
typedef struct {
  ZfLayer *l;
  int T, S, NA, n, L, tasks;
  float *out;
} NonlinJob;

static void nonlin_product(const NonlinJob *j, size_t index);

static void nonlin_pre(void *user, size_t index) {
  const NonlinJob *j = (const NonlinJob *)user;
  ZfLayer *l = j->l;
  const int NA = j->NA, n = j->n;
  int c0, c1;
  slice_of(NA, j->tasks, index, &c0, &c1);
  if (c0 >= c1) return;
  for (int t = 0; t < j->T; ++t) {
    float *row = l->wide + (size_t)t * n;
    float *dst = l->nawin + (size_t)(j->L + t) * NA;
    zf_tanh_f32(row + c0, row + c0, (size_t)(c1 - c0));
    int c = c0;
#if ZF_NEON_AVAILABLE
    for (; c + 4 <= c1; c += 4)
      vst1q_f32(dst + c, vmulq_f32(vld1q_f32(row + NA + c), vld1q_f32(row + c)));
#endif
    for (; c < c1; ++c) dst[c] = row[NA + c] * row[c];
  }
  nonlin_product(j, index);
}

/* The product against the cached values, over the same channel band, in the same region. */
static void nonlin_product(const NonlinJob *j, size_t index) {
  ZfLayer *l = j->l;
  const int NA = j->NA, n = j->n;
  int c0, c1;
  slice_of(NA, j->tasks, index, &c0, &c1);
  if (c0 >= c1) return;
  matmul_nn(l->attn, j->S, l->nawin + c0, NA, j->T, c1 - c0, j->S, j->out + c0, NA,
            zf_mlas_stride_k(NA, j->S));
  for (int t = 0; t < j->T; ++t) {
    const float *row = l->wide + (size_t)t * n;
    float *dst = j->out + (size_t)t * NA;
    for (int c = c0; c < c1; ++c) dst[c] *= row[2 * NA + c];
  }
}

int zf_layer_run(ZfLayer *l, const float *src, int T, const float *key_pad,
                 const float *frame_pad, float *out, const ZfParallel *par) {
  if (!l || T != l->frames) return 0;
  if (l->bound != l->arena_ref->block) bind_arena(l);
  {
    const size_t b = (size_t)l->cache_base;
    l->kwin = l->kcat + b * (size_t)l->heads * ZF_QUERY_DIM;
    l->nawin = l->nacat + b * (size_t)l->na_dim;
    l->vwin[0] = l->vcat[0] + b * (size_t)l->heads * ZF_VALUE_DIM;
    l->vwin[1] = l->vcat[1] + b * (size_t)l->heads * ZF_VALUE_DIM;
  }
  const int D = l->dim, H = l->heads, Q = ZF_QUERY_DIM, V = ZF_VALUE_DIM;
  const int L = l->left, S = L + T, NA = l->na_dim;
  float *x = l->work;
  /* the two bypasses read the layer's input, and the caller's buffer is not written here, so it is
   * the source: copying it into the arena as well was another pass over every value */
  const float *orig = src;
  double te = ZF_NOW();
  memcpy(x, src, (size_t)T * D * sizeof(float));
  ZF_STAGE(l, 11, ZF_NOW() - te);

  /* attention weights, from the layer's input */
  run_linear(l, &l->saw_in, x, T, l->wide, 0, par);
  const int saw_n = l->saw_in.w.n;
  double ts = ZF_NOW();
  for (int t = 0; t < T; ++t)
    memcpy(l->kwin + (size_t)(L + t) * H * Q, l->wide + (size_t)t * saw_n + H * Q,
           (size_t)H * Q * sizeof(float));
  ZF_STAGE(l, 2, ZF_NOW() - ts);

  double tm = ZF_NOW();
  {
    /* the position vectors sit after the queries and keys, one per head */
    float *pos = l->conv_a; /* borrow a buffer: [T, H * pos_dim] */
    for (int t = 0; t < T; ++t)
      memcpy(pos + (size_t)t * H * ZF_POS_DIM,
             l->wide + (size_t)t * saw_n + 2 * H * Q, (size_t)H * ZF_POS_DIM * sizeof(float));
    float a_scale = 0.0f;
    int a_zp = 0;
    zf_dynamic_quantize_shifted(pos, (size_t)T * H * ZF_POS_DIM, l->qbuf, &a_scale, &a_zp);

    ScoreJob job = {l, key_pad, saw_n, T, S, 0, 1, a_scale * l->pos_scale, a_zp};
    /* enough tasks to fill the pool, in whole frames */
    while (job.tblock < T && H * ((T + job.tblock - 1) / job.tblock) > par_threads(par) * 2)
      job.tblock *= 2;
    job.tasks = plan_tasks(par, H * ((T + job.tblock - 1) / job.tblock));
    dispatch(par, score_slice, job.tasks, &job);
  }
  ZF_STAGE(l, 1, ZF_NOW() - tm);

  /* feed_forward1 */
  run_linear(l, &l->ff1_in, x, T, l->wide, 1, par);
  run_linear(l, &l->ff1_out, l->wide, T, l->conv_a, 0, par);
  te = ZF_NOW();
  {
    TailJob job = {x, l->conv_a, NULL, NULL, NULL, 0.0f, 0, 0, 0, 0};
    tail(par, &job, T, D);
  }
  ZF_STAGE(l, 11, ZF_NOW() - te);

  /* nonlinear attention, against head zero's weights */
  tm = ZF_NOW();
  run_linear(l, &l->na_in, x, T, l->wide, 0, par);
  {
    NonlinJob job = {l, T, S, NA, l->na_in.w.n, L, plan_tasks(par, NA / 16), l->conv_b};
    if (job.tasks < 1) job.tasks = 1;
    const double t0 = ZF_NOW();
    dispatch(par, nonlin_pre, job.tasks, &job);
    ZF_STAGE(l, 9, ZF_NOW() - t0);
    run_linear(l, &l->na_out, l->conv_b, T, l->conv_a, 0, par);
    te = ZF_NOW();
  {
    TailJob job = {x, l->conv_a, NULL, NULL, NULL, 0.0f, 0, 0, 0, 0};
    tail(par, &job, T, D);
  }
  ZF_STAGE(l, 11, ZF_NOW() - te);
  }
  ZF_STAGE(l, 3, ZF_NOW() - tm);

  /* the two value projections share this shape */
  for (int pass = 0; pass < 2; ++pass) {
    const ZfLinear *in = pass == 0 ? &l->sa1_in : &l->sa2_in;
    const ZfLinear *outp = pass == 0 ? &l->sa1_out : &l->sa2_out;
    float *vcat = l->vwin[pass];
    if (pass == 1) {
      /* between the two comes feed_forward2 and the middle bypass */
      run_linear(l, &l->ff2_in, x, T, l->wide, 1, par);
      run_linear(l, &l->ff2_out, l->wide, T, l->conv_a, 0, par);
      te = ZF_NOW();
  {
    TailJob job = {x, l->conv_a, NULL, NULL, NULL, 0.0f, 0, 0, 0, 0};
    tail(par, &job, T, D);
  }
  ZF_STAGE(l, 11, ZF_NOW() - te);
      TailJob mid = {x, x, orig, NULL, l->bypass_mid_scale, 0.0f, 0, 0, 0, 2};
      tail(par, &mid, T, D);
    }
    tm = ZF_NOW();
    run_linear(l, in, x, T, l->wide, 0, par);
    const int width = H * V;
    ts = ZF_NOW();
    for (int t = 0; t < T; ++t)
      memcpy(vcat + (size_t)(L + t) * width, l->wide + (size_t)t * width,
             (size_t)width * sizeof(float));
    ZF_STAGE(l, 2, ZF_NOW() - ts);
    {
      ValueJob job = {l, T, S, width, plan_tasks(par, H), pass};
      const double tv = ZF_NOW();
      dispatch(par, value_slice, job.tasks, &job);
      ZF_STAGE(l, 10, ZF_NOW() - tv);
    }
    run_linear(l, outp, l->conv_b, T, l->conv_a, 0, par);
    te = ZF_NOW();
  {
    TailJob job = {x, l->conv_a, NULL, NULL, NULL, 0.0f, 0, 0, 0, 0};
    tail(par, &job, T, D);
  }
  ZF_STAGE(l, 11, ZF_NOW() - te);
    ZF_STAGE(l, 4, ZF_NOW() - tm);
    tm = ZF_NOW();
    conv_module(l, pass, x, T, frame_pad, l->cconv[pass], par);
    ZF_STAGE(l, 5, ZF_NOW() - tm);
    tm = ZF_NOW();
    if (pass == 1) {
      run_linear(l, &l->ff3_in, x, T, l->wide, 1, par);
      run_linear(l, &l->ff3_out, l->wide, T, l->conv_a, 0, par);
      te = ZF_NOW();
  {
    TailJob job = {x, l->conv_a, NULL, NULL, NULL, 0.0f, 0, 0, 0, 0};
    tail(par, &job, T, D);
  }
  ZF_STAGE(l, 11, ZF_NOW() - te);
    }
  }

  /* slide the window on, and only when it would run off the end copy the context to the front */
  l->cache_base += T;
  if (l->cache_base + S > l->cache_cap) {
    const int w[4] = {H * Q, NA, H * ZF_VALUE_DIM, H * ZF_VALUE_DIM};
    float *buf[4] = {l->kcat, l->nacat, l->vcat[0], l->vcat[1]};
    for (int i = 0; i < 4; ++i)
      memmove(buf[i], buf[i] + (size_t)l->cache_base * w[i], (size_t)L * w[i] * sizeof(float));
    l->cache_base = 0;
  }

  te = ZF_NOW();
  {
    TailJob norm = {l->conv_a, x, NULL, l->norm_bias, NULL, l->norm_scale, 0, 0, 0, 1};
    tail(par, &norm, T, D);
    TailJob out_job = {out, l->conv_a, orig, NULL, l->bypass_scale, 0.0f, 0, 0, 0, 2};
    tail(par, &out_job, T, D);
  }
  ZF_STAGE(l, 11, ZF_NOW() - te);
  return 1;
}

/* ------------------------------------------------------------ chunks in lockstep */

/* zf_layer_run_group: G consecutive chunks through the layer, step by step.
 *
 * zf_layer_run over chunk 0, 1, ..., G-1 reads each linear's weights once per chunk, and with the
 * whole layer's weights (megabytes) passing through between two reads of the same linear, every
 * read comes from the last level of cache or memory. Here every step runs for all G chunks before
 * the next step, and each linear runs its weights a sub-block at a time against every chunk's rows,
 * so each sub-block is read from memory once per group and from the near cache for the other G-1.
 *
 * The arithmetic is the same operations on the same values. Each chunk has its own scratch (a copy
 * of the layer struct bound to its own buffers), its own activation range and scale, and its own
 * rows of every product; a linear's output for a given (row, unit) is the same computation however
 * the units are split, which is already true of the pooled split. What is shared are the caches,
 * and every cache a step reads was written by an earlier step of the same chunk or by the same or an
 * earlier step of an earlier chunk: the key, value and nonlinear windows are written and read inside
 * one step each, which runs chunk by chunk in order, and the convolution cache the same. The windows
 * sit side by side in the cache buffer, chunk b's starting b frames-widths after chunk 0's, exactly
 * where the sequential calls would have put them. */
typedef struct {
  const LinearJob *jobs;
  int G, tasks, sub, to_cols;
} GroupJob;
#define ZF_GROUP_MAX_X 64

static void group_task(void *user, size_t index) {
  const GroupJob *g = (const GroupJob *)user;
  const int nb = g->jobs[0].lin->w.n_blocks;
  const int b0 = (int)((size_t)nb * index / (size_t)g->tasks);
  const int b1 = (int)((size_t)nb * (index + 1) / (size_t)g->tasks);
  for (int s0 = b0; s0 < b1; s0 += g->sub) {
    const int s1 = s0 + g->sub < b1 ? s0 + g->sub : b1;
    for (int i = 0; i < g->G; ++i) {
      LinearSlice t;
      if (!linear_blocks(&g->jobs[i], s0, s1, &t)) continue;
      if (g->to_cols) linear_t_range(&g->jobs[i], &t);
      else linear_range(&g->jobs[i], &t);
    }
  }
}

/* How much of a linear's weights every chunk of a group runs over before the next sub-block: it has
 * to stay in the cache while all of them do. On the Alcatel's Cortex-A53 (512 KB of L2, shared with
 * the activations) half of it or less: QEMU's cache model of that hierarchy, 7 chunks in lockstep,
 * counted 91 MB of L2 misses a chunk without the lockstep, 55 MB with 512 KB sub-blocks, 41 MB with
 * 256 or 128 KB, 40 MB with 64 KB at 0.1% more instructions. Apple's cores and x86 have megabytes. */
#ifndef ZF_LANE_KB_DEFAULT
#if (defined(__arm__) || defined(__aarch64__)) && !defined(__APPLE__)
#define ZF_LANE_KB_DEFAULT 128
#else
#define ZF_LANE_KB_DEFAULT 512
#endif
#endif
static int group_sub_blocks(const ZfLinear *lin) {
  static int kb = -1;
  if (kb < 0) kb = zf_env_int("ZF_LANE_KB", ZF_LANE_KB_DEFAULT);
  const size_t block_bytes = (size_t)lin->w.k_pad * ZF_S8_UNIT_BLOCK;
  int sub = (int)(((size_t)kb << 10) / (block_bytes ? block_bytes : 1));
  sub &= ~15; /* whole 64-unit tiles */
  return sub < 16 ? 16 : sub;
}

#define ZF_GROUP_MAX 64

/* one linear for every chunk: x and y are each chunk's own buffer, at the same offset in its view */
/* One parallel region for the same step of every chunk: index i runs task i - start[b] of chunk b's
 * job. Used where the chunks' jobs are independent of each other; each job's own tasks are
 * unchanged, so the work is the same as running the chunks' regions one after another. */
typedef struct {
  void (*fn)(void *, size_t);
  void *job[ZF_GROUP_MAX];
  int start[ZF_GROUP_MAX + 1];
  int G;
} LaneJobs;

static void lanes_task(void *user, size_t index) {
  const LaneJobs *j = (const LaneJobs *)user;
  int b = 0;
  while ((int)index >= j->start[b + 1]) ++b;
  j->fn(j->job[b], index - (size_t)j->start[b]);
}

static void dispatch_lanes(const ZfParallel *par, void (*fn)(void *, size_t), void *jobs,
                           size_t stride, const int *tasks, int G) {
  LaneJobs lj;
  lj.fn = fn;
  lj.G = G;
  lj.start[0] = 0;
  for (int b = 0; b < G; ++b) {
    lj.job[b] = (unsigned char *)jobs + stride * (size_t)b;
    lj.start[b + 1] = lj.start[b] + tasks[b];
  }
  if (lj.start[G] > 1 && par && par->run) {
    dispatch(par, lanes_task, lj.start[G], &lj);
  } else {
    /* one thread: every index in order (dispatch alone would run index 0 only) */
    for (int i = 0; i < lj.start[G]; ++i) lanes_task(&lj, (size_t)i);
  }
}

static void run_group_linear(ZfLayer *views, int G, const ZfLinear *lin, size_t x_slot, size_t y_slot,
                             int m, int swoosh, int cols_in, int to_cols,
                             const ZfParallel *par) {
  LinearJob jobs[ZF_GROUP_MAX], qjobs[ZF_GROUP_MAX];
  int qtasks[ZF_GROUP_MAX];
  for (int i = 0; i < G; ++i) {
    ZfLayer *v = &views[i];
    const float *x = *(float **)((unsigned char *)v + x_slot);
    float *y = *(float **)((unsigned char *)v + y_slot);
    linear_prepare(v, lin, x, m, y, swoosh, cols_in, par, &jobs[i], &qtasks[i]);
    qjobs[i] = jobs[i];
    qjobs[i].tasks = qtasks[i];
  }
  /* With a pool: one region, each task scanning its chunk's whole range before writing its rows
   * (the range is a strict-compare fold from +0, the same however the rows are grouped), so the
   * range and the write do not need a barrier between them. One thread: the range, then the write. */
  if (!cols_in && par && par->run && par->threads > 1) {
    for (int i = 0; i < G; ++i) qjobs[i].tasks = -qtasks[i]; /* quant_task: scan the range itself */
    dispatch_lanes(par, quant_task, qjobs, sizeof qjobs[0], qtasks, G);
  } else {
    if (!cols_in) dispatch_lanes(par, qrange_task, qjobs, sizeof qjobs[0], qtasks, G);
    dispatch_lanes(par, quant_task, qjobs, sizeof qjobs[0], qtasks, G);
  }
  GroupJob g = {jobs, G, jobs[0].tasks, group_sub_blocks(lin), to_cols};
  if (par && par->run && par->threads > 1) {
    /* the group's product is the region worth balancing: ZF_GEMM_MULT items a thread (default 3),
     * so a thread that starts late or runs slow leaves only a small item for the others to wait on */
    static int gm = -1;
    if (gm < 0) gm = zf_env_int("ZF_GEMM_MULT", 3);
    int t = par->threads * (gm < 1 ? 1 : gm);
    if (t > lin->w.n_blocks) t = lin->w.n_blocks;
    if (t > g.tasks) g.tasks = t;
  }
  dispatch(par, group_task, g.tasks, &g);
}
#define GLIN(lin, xf, yf, sw, ci, tc) \
  run_group_linear(views, G, lin, offsetof(ZfLayer, xf), offsetof(ZfLayer, yf), T, sw, ci, tc, par)

static int ensure_cache_cap(ZfLayer *l, int cap) {
  if (l->cache_cap >= cap) return 1;
  const int D = l->dim, H = l->heads, NA = l->na_dim, keep = l->taps_causal - 1, L = l->left;
  const size_t widths[4] = {(size_t)H * ZF_QUERY_DIM, (size_t)NA, (size_t)H * ZF_VALUE_DIM,
                            (size_t)H * ZF_VALUE_DIM};
  size_t off[6], total = 0;
  for (int i = 0; i < 4; ++i) {
    off[i] = total;
    total += align_up((size_t)cap * widths[i] * sizeof(float));
  }
  for (int i = 0; i < 2; ++i) {
    off[4 + i] = total;
    total += align_up((size_t)D * keep * sizeof(float));
  }
  unsigned char *block = (unsigned char *)calloc(1, total);
  if (!block) return 0;
  float *old[4] = {l->kcat, l->nacat, l->vcat[0], l->vcat[1]};
  for (int i = 0; i < 4; ++i)
    memcpy(block + off[i], old[i] + (size_t)l->cache_base * widths[i],
           (size_t)L * widths[i] * sizeof(float));
  for (int i = 0; i < 2; ++i)
    memcpy(block + off[4 + i], l->cconv[i], (size_t)D * keep * sizeof(float));
  free(l->cache_block);
  l->cache_block = block;
  l->cache_bytes = total;
  l->cache_cap = cap;
  l->cache_base = 0;
  l->kcat = (float *)(block + off[0]);
  l->nacat = (float *)(block + off[1]);
  l->vcat[0] = (float *)(block + off[2]);
  l->vcat[1] = (float *)(block + off[3]);
  l->cconv[0] = (float *)(block + off[4]);
  l->cconv[1] = (float *)(block + off[5]);
  return 1;
}

static void cache_slide(ZfLayer *l) {
  const int H = l->heads, Q = ZF_QUERY_DIM, NA = l->na_dim, L = l->left;
  const int w[4] = {H * Q, NA, H * ZF_VALUE_DIM, H * ZF_VALUE_DIM};
  float *buf[4] = {l->kcat, l->nacat, l->vcat[0], l->vcat[1]};
  for (int i = 0; i < 4; ++i)
    memmove(buf[i], buf[i] + (size_t)l->cache_base * w[i], (size_t)L * w[i] * sizeof(float));
  l->cache_base = 0;
}

int zf_layer_run_group(ZfLayer *l, int G, const float *const *src, int T,
                       const float *const *key_pad, const float *const *frame_pad,
                       float *const *out, const ZfParallel *par) {
  if (!l || T != l->frames || G < 1) return 0;
  if (G == 1 || G > ZF_GROUP_MAX || zf_dump_file())
    {
      for (int b = 0; b < G; ++b)
        if (!zf_layer_run(l, src[b], T, key_pad ? key_pad[b] : NULL, frame_pad ? frame_pad[b] : NULL,
                          out[b], par))
          return 0;
      return 1;
    }
  const int D = l->dim, H = l->heads, Q = ZF_QUERY_DIM, V = ZF_VALUE_DIM;
  const int L = l->left, S = L + T, NA = l->na_dim;
  ZfArena *a = l->arena_ref;
  /* the caches: every chunk's window side by side */
  if (!ensure_cache_cap(l, 2 * L + G * T)) return 0;
  if (l->cache_base + L + G * T > l->cache_cap) cache_slide(l);
  /* each chunk's scratch and its view of the layer */
  const size_t need = align_up(l->need);
  if (a->lane_bytes < need * (size_t)G) {
    unsigned char *lanes = (unsigned char *)calloc((size_t)G, need);
    if (!lanes) return 0;
    free(a->lanes);
    a->lanes = lanes;
    a->lane_bytes = need * (size_t)G;
  }
  if (a->view_count < G) {
    ZfLayer *views = (ZfLayer *)calloc((size_t)G, sizeof(ZfLayer));
    if (!views) return 0;
    free(a->views);
    a->views = views;
    a->view_count = G;
  }
  ZfLayer *views = a->views;
  for (int b = 0; b < G; ++b) {
    ZfLayer *v = &views[b];
    *v = *l;
    unsigned char *base = a->lanes + need * (size_t)b;
    float **slots[] = {&v->orig, &v->work, &v->wide, &v->attn, &v->pos_raw, &v->conv, &v->conv_a,
                       &v->conv_b};
    for (size_t i = 0; i < sizeof slots / sizeof slots[0]; ++i) *slots[i] = (float *)(base + l->slot[i]);
    v->qbuf = (int8_t *)(base + l->qbuf_off);
    v->acc = (int32_t *)(base + l->acc_off);
    v->scales = (float *)(base + l->scales_off);
    v->bound = NULL;
    const size_t cb = (size_t)(l->cache_base + b * T);
    v->cache_base = (int)cb;
    v->kwin = l->kcat + cb * (size_t)H * Q;
    v->nawin = l->nacat + cb * (size_t)NA;
    v->vwin[0] = l->vcat[0] + cb * (size_t)H * V;
    v->vwin[1] = l->vcat[1] + cb * (size_t)H * V;
  }
#define EACH for (int b = 0; b < G; ++b)
#define VW (&views[b])
#define TAIL(...)                                  \
  do {                                             \
    TailJob job_ = {__VA_ARGS__};                  \
    tail(par, &job_, T, D);                        \
  } while (0)
  /* the same tail for every chunk, in one region */
#define TAILS(...)                                 \
  do {                                             \
    TailJob tj_[ZF_GROUP_MAX];                     \
    int tt_[ZF_GROUP_MAX];                         \
    EACH {                                         \
      TailJob job_ = {__VA_ARGS__};                \
      tail_plan(par, &job_, T, D);                 \
      tj_[b] = job_;                               \
      tt_[b] = job_.tasks;                         \
    }                                              \
    if ((long)G * T * D <= zf_group_tail_serial()) {  \
      /* a few microseconds of adds: cheaper here than a region's hand-off and join */ \
      EACH { tj_[b].tasks = 1; tail_slice(&tj_[b], 0); } \
    } else {                                       \
      dispatch_lanes(par, tail_slice, tj_, sizeof tj_[0], tt_, G); \
    }                                              \
  } while (0)

  EACH memcpy(VW->work, src[b], (size_t)T * D * sizeof(float));

  ScoreJob sjobs[ZF_GROUP_MAX];
  int stasks[ZF_GROUP_MAX];
  /* attention weights */
  GLIN(&l->saw_in, work, wide, 0, 0, 0);
  const int saw_n = l->saw_in.w.n;
  EACH {
    ZfLayer *v = VW;
    for (int t = 0; t < T; ++t)
      memcpy(v->kwin + (size_t)(L + t) * H * Q, v->wide + (size_t)t * saw_n + H * Q,
             (size_t)H * Q * sizeof(float));
    float *pos = v->conv_a;
    for (int t = 0; t < T; ++t)
      memcpy(pos + (size_t)t * H * ZF_POS_DIM, v->wide + (size_t)t * saw_n + 2 * H * Q,
             (size_t)H * ZF_POS_DIM * sizeof(float));
    float a_scale = 0.0f;
    int a_zp = 0;
    zf_dynamic_quantize_shifted(pos, (size_t)T * H * ZF_POS_DIM, v->qbuf, &a_scale, &a_zp);
    ScoreJob job = {v, key_pad ? key_pad[b] : NULL, saw_n, T, S, 0, 1, a_scale * l->pos_scale, a_zp};
    while (job.tblock < T && H * ((T + job.tblock - 1) / job.tblock) > par_threads(par) * 2)
      job.tblock *= 2;
    job.tasks = plan_tasks(par, H * ((T + job.tblock - 1) / job.tblock));
    sjobs[b] = job;
    stasks[b] = job.tasks;
  }
  /* every chunk's keys are in place: all the scores in one region */
  dispatch_lanes(par, score_slice, sjobs, sizeof sjobs[0], stasks, G);

  /* feed_forward1 */
  GLIN(&l->ff1_in, work, wide, 1, 0, 0);
  GLIN(&l->ff1_out, wide, conv_a, 0, 0, 0);
  TAILS(VW->work, VW->conv_a, NULL, NULL, NULL, 0.0f, 0, 0, 0, 0);

  /* nonlinear attention */
  GLIN(&l->na_in, work, wide, 0, 0, 0);
  EACH {
    ZfLayer *v = VW;
    NonlinJob job = {v, T, S, NA, l->na_in.w.n, L, plan_tasks(par, NA / 16), v->conv_b};
    if (job.tasks < 1) job.tasks = 1;
    dispatch(par, nonlin_pre, job.tasks, &job);
  }
  GLIN(&l->na_out, conv_b, conv_a, 0, 0, 0);
  TAILS(VW->work, VW->conv_a, NULL, NULL, NULL, 0.0f, 0, 0, 0, 0);

  for (int pass = 0; pass < 2; ++pass) {
    const ZfLinear *in = pass == 0 ? &l->sa1_in : &l->sa2_in;
    const ZfLinear *outp = pass == 0 ? &l->sa1_out : &l->sa2_out;
    if (pass == 1) {
      GLIN(&l->ff2_in, work, wide, 1, 0, 0);
      GLIN(&l->ff2_out, wide, conv_a, 0, 0, 0);
      TAILS(VW->work, VW->conv_a, NULL, NULL, NULL, 0.0f, 0, 0, 0, 0);
      TAILS(VW->work, VW->work, src[b], NULL, l->bypass_mid_scale, 0.0f, 0, 0, 0, 2);
    }
    GLIN(in, work, wide, 0, 0, 0);
    const int width = H * V;
    {
      ValueJob vjobs[ZF_GROUP_MAX];
      int vtasks[ZF_GROUP_MAX];
      EACH {
        ZfLayer *v = VW;
        for (int t = 0; t < T; ++t)
          memcpy(v->vwin[pass] + (size_t)(L + t) * width, v->wide + (size_t)t * width,
                 (size_t)width * sizeof(float));
        ValueJob job = {v, T, S, width, plan_tasks(par, H), pass};
        vjobs[b] = job;
        vtasks[b] = job.tasks;
      }
      /* every chunk's values are in place: all the products in one region */
      dispatch_lanes(par, value_slice, vjobs, sizeof vjobs[0], vtasks, G);
    }
    GLIN(outp, conv_b, conv_a, 0, 0, 0);
    TAILS(VW->work, VW->conv_a, NULL, NULL, NULL, 0.0f, 0, 0, 0, 0);

    /* the convolution module; its cache passes from chunk to chunk inside the one step */
    GLIN(&l->cm_in[pass], work, wide, 0, 0, 1);
    EACH {
      ZfLayer *v = VW;
      ConvJob job = {v, pass, T, plan_tasks(par, D / 16), l->cm_in[pass].w.n,
                     frame_pad ? frame_pad[b] : NULL, l->cconv[pass]};
      if (job.tasks < 1) job.tasks = 1;
      dispatch(par, conv_pre, job.tasks, &job);
    }
    GLIN(&l->cm_out[pass], conv_a, conv_b, 0, 1, 0);
    TAILS(VW->work, VW->conv_b, NULL, NULL, NULL, 0.0f, 0, 0, 1, 0);

    if (pass == 1) {
      GLIN(&l->ff3_in, work, wide, 1, 0, 0);
      GLIN(&l->ff3_out, wide, conv_a, 0, 0, 0);
      TAILS(VW->work, VW->conv_a, NULL, NULL, NULL, 0.0f, 0, 0, 0, 0);
    }
  }

  l->cache_base += G * T;
  if (l->cache_base + S > l->cache_cap) cache_slide(l);

  TAILS(VW->conv_a, VW->work, NULL, l->norm_bias, NULL, l->norm_scale, 0, 0, 0, 1);
  TAILS(out[b], VW->conv_a, src[b], NULL, l->bypass_scale, 0.0f, 0, 0, 0, 2);
#undef EACH
#undef VW
#undef TAIL
#undef TAILS
  return 1;
}
