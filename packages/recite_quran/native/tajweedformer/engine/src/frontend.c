#include "zf/frontend.h"
#include "zf/env.h"

#include "zf/neon.h"

#include <stdio.h>
#include <time.h>
#include <stdlib.h>
#include <string.h>

#include "zf/block.h"
#include "zf/conv.h"
#include "zf/kernels.h"
#include "zf/layout.h"

#define ZF_FE_CONVS 5
#define ZF_FE_BINS 80

struct ZfFrontEnd {
  const ZfWeights *w;
  int max_frames;
  int swoosh_l; /* the ConvNeXt's SwooshL: ZF_SWOOSH_L, or ZF_SWOOSH_L1 for a model at offset 1 */

  ZfConvS8 conv[ZF_FE_CONVS]; /* conv0, conv1, conv2, pointwise1, pointwise2 */
  /* The same five convolutions' weights in fp32, when the weight file carries them.
   *
   * The deployed graph runs these in fp32 and the int8 path is a 3.64 per cent approximation of it,
   * which is the sole cause of the engine's token divergence from the published model. With these
   * the front end reproduces the graph exactly. NULL when the file predates them, in which case the
   * int8 path runs as before. */
  const float *conv_w32[ZF_FE_CONVS];
  float *rows32; /* fp32 im2col scratch, pixels * k floats */
  const float *dw_weight;
  const float *dw_bias;
  int dw_channels, dw_kh, dw_kw, dw_pad;

  ZfWeightsS8 out_linear;
  const float *out_scale;
  int out_scale_count;
  const float *out_bias;
  const float *norm_bias;
  float norm_scale;

  unsigned char *arena;
  size_t arena_bytes;
  int8_t *qin;
  int8_t *rows;
  int32_t *acc;
  float *buf0;  /* conv0 output  */
  float *buf1;  /* conv1 output  */
  float *bufu;  /* conv2 output, the residual source */
  float *bufcat;
  float *bufdw;
  float *bufwide;
  float *bufpw2;
  float *flat;
  int8_t *flat_q;
  int32_t *out_acc;
  float *out_f32;
  float *scales;
  double stage_ms[ZF_FE_STAGES];
  /* ZF_CONV_ORT: the residual pw2 is fused with, offered by the caller for one call, and whether
   * the fp32 path took it (in which case the separate residual pass must not add it again). */
  const float *fused_resid;
  int fused_resid_stride;
  int fused_done;
  /* The previous call's input window, for fe_reuse_rows. prev_frames is 0 when the previous call
   * did not leave all three fp32 convolutions' outputs whole in buf0, buf1 and bufu. */
  float *prev_x;
  int prev_frames;

  /* Progress through the current window, so a stream can run the front end while the window's
   * audio is still arriving (zf_frontend_prefetch). pv frames of it have been seen (a copy is in
   * prog_x); d[i] leading rows of conv i are done, ddw of the depthwise, dpw of both pointwise
   * convolutions. Every row is computed by the same functions over the same inputs as a whole-window
   * run, in bands, so the bits do not depend on where the bands fall. */
  float *prog_x, *prog_state;
  int pv, win_frames, d[3], ddw, dpw, all_fused;
  float *band_in, *band_out;
};

static double now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec * 1e3 + (double)ts.tv_nsec / 1e6;
}

static int fe_f32_convs(void) {
  static _Atomic int on = -1;
  if (on < 0) {
    const char *v = zf_getenv("ZF_FE_F32");
    on = v ? atoi(v) : 0;
  }
  return on;
}

/* Which of the five convolutions run in fp32, one bit each: conv0, conv1, conv2, pw1, pw2.
 *
 * ZF_FE_F32=1 means all five, which is what it has always meant. ZF_FE_F32_MASK overrides it with
 * a bitmask so a single convolution can be moved to fp32 on its own, which is what attributes the
 * front end's 3.64 per cent relative error to a particular one rather than to the group. */
static int fe_f32_mask(void) {
  static _Atomic int mask = -1;
  if (mask < 0) {
    const char *v = zf_getenv("ZF_FE_F32_MASK");
    mask = v ? atoi(v) : (fe_f32_convs() ? (1 << ZF_FE_CONVS) - 1 : 0);
  }
  return mask;
}

static int fe_ort_fuse(void) {
  static _Atomic int on = -1;
  if (on < 0) {
    const char *v = zf_getenv("ZF_CONV_ORT");
    on = v && atoi(v);
  }
  return on;
}

static int fe_conv_is_f32(int idx) {
  return idx >= 0 && idx < ZF_FE_CONVS && ((fe_f32_mask() >> idx) & 1);
}

static const char *const kStageNames[ZF_FE_STAGES] = {
    "conv0", "conv1", "conv2", "swoosh", "cache", "depthwise", "pointwise", "out",
    "conv_quantize", "conv_im2col", "conv_gemm", "conv_dequantize",
    /* the two pointwise convolutions on their own: they are 46 per cent of the front end for
     * 3.7M of its 78.4M multiply-adds, so the split says which part of them that is */
    "pw_quant", "pw_gemm", "pw_scales",
    /* conv_dequantize used to time the swoosh as well as the dequantise, and in the pixel-major
     * branch it timed ONLY the swoosh, because that branch fuses the scaling into the microkernel's
     * epilogue and no int32 ever reaches memory. Reading it as a dequantise cost overstates what
     * moving these convolutions to fp32 would save, since fp32 still needs the activation. */
    "conv_swoosh"};

void zf_frontend_stages(const ZfFrontEnd *fe, double *out_ms) {
  for (int i = 0; i < ZF_FE_STAGES; ++i) out_ms[i] = fe ? fe->stage_ms[i] : 0.0;
}

void zf_frontend_reset_stages(ZfFrontEnd *fe) {
  if (fe) memset(fe->stage_ms, 0, sizeof fe->stage_ms);
}

const char *zf_frontend_stage_name(int index) {
  return (index >= 0 && index < ZF_FE_STAGES) ? kStageNames[index] : "?";
}

static size_t align_up(size_t v) { return (v + 63u) & ~(size_t)63u; }

/* `reorder_k` asks for the weight's k axis to be (dy, dx, channel), which is the order a gather
 * from a pixel-major input produces. It happens once, on the tensor in the loaded file, and the
 * weight file itself keeps the canonical order. */
static int conv_from_weights(ZfWeights *w, const char *prefix, ZfConvS8 *c, int reorder_k) {
  char name[64];
  size_t count = 0;
  snprintf(name, sizeof name, "%s.shape", prefix);
  const int32_t *s = zf_weights_s32(w, name, &count);
  if (!s || count < 8) return 0;
  c->out_channels = s[0];
  c->in_channels = s[1];
  c->kh = s[2];
  c->kw = s[3];
  c->stride_h = s[4];
  c->stride_w = s[5];
  c->pad_top = s[6];
  c->pad_bottom = s[6];
  c->pad_left = s[7];
  c->pad_right = s[7];
  snprintf(name, sizeof name, "%s.packed", prefix);
  c->weights.packed = zf_weights_s8(w, name, &count);
  snprintf(name, sizeof name, "%s.rowsums", prefix);
  c->weights.row_sums = zf_weights_s32(w, name, &count);
  snprintf(name, sizeof name, "%s.scale", prefix);
  c->scale = zf_weights_f32(w, name, &count);
  c->scale_count = (int)count;
  snprintf(name, sizeof name, "%s.bias", prefix);
  c->bias = zf_weights_f32(w, name, &count);
  if (!c->weights.packed || !c->weights.row_sums || !c->scale) return 0;
  if (reorder_k) {
    snprintf(name, sizeof name, "%s.packed", prefix);
    if (!zf_weights_reorder_conv_k(w, name, c->out_channels, c->in_channels * c->kh * c->kw,
                                   c->in_channels, c->kh, c->kw))
      return 0;
  }
  c->weights.n = c->out_channels;
  c->weights.k = c->in_channels * c->kh * c->kw;
  c->weights.k_pad = (c->weights.k + ZF_S8_K_GROUP - 1) / ZF_S8_K_GROUP * ZF_S8_K_GROUP;
  c->weights.n_blocks = (c->weights.n + ZF_S8_UNIT_BLOCK - 1) / ZF_S8_UNIT_BLOCK;
  return 1;
}

/* The chain of shapes for a given input length, which the arena and the caller both need. */
typedef struct {
  int h0, w0, h1, w1, h2, w2, hout;
} Shapes;

static Shapes plan_shapes(const ZfFrontEnd *fe, int frames) {
  Shapes s;
  s.h0 = zf_conv_out_h(&fe->conv[0], frames);
  s.w0 = zf_conv_out_w(&fe->conv[0], ZF_FE_BINS);
  s.h1 = zf_conv_out_h(&fe->conv[1], s.h0);
  s.w1 = zf_conv_out_w(&fe->conv[1], s.w0);
  s.h2 = zf_conv_out_h(&fe->conv[2], s.h1);
  s.w2 = zf_conv_out_w(&fe->conv[2], s.w1);
  s.hout = s.h2 + 3 - fe->dw_kh + 1; /* three cached rows in front, no padding in time */
  return s;
}

int zf_frontend_out_frames(const ZfFrontEnd *fe, int frames) {
  return plan_shapes(fe, frames).hout;
}

int zf_frontend_state_floats(const ZfFrontEnd *fe) {
  const Shapes s = plan_shapes(fe, fe->max_frames);
  return fe->dw_channels * 3 * s.w2;
}

int zf_frontend_out_channels(const ZfFrontEnd *fe) { return fe->out_linear.n; }

static int build_arena(ZfFrontEnd *fe, const char **error) {
  const Shapes s = plan_shapes(fe, fe->max_frames);
  const int c0 = fe->conv[0].out_channels, c1 = fe->conv[1].out_channels;
  const int c2 = fe->conv[2].out_channels, cw = fe->conv[3].out_channels;

  size_t qin_bytes = (size_t)ZF_FE_BINS * fe->max_frames;
  size_t rows_bytes = 0, acc_elems = 0;
  const int pixels[ZF_FE_CONVS] = {s.h0 * s.w0, s.h1 * s.w1, s.h2 * s.w2, s.hout * s.w2,
                                   s.hout * s.w2};
  for (int i = 0; i < ZF_FE_CONVS; ++i) {
    const size_t in_elems = (size_t)fe->conv[i].in_channels *
                            (i == 0 ? (size_t)fe->max_frames * ZF_FE_BINS
                                    : (i == 1 ? (size_t)s.h0 * s.w0
                                              : (i == 2 ? (size_t)s.h1 * s.w1
                                                        : (size_t)s.hout * s.w2)));
    if (in_elems > qin_bytes) qin_bytes = in_elems;
    const size_t r = (size_t)pixels[i] * fe->conv[i].weights.k_pad;
    if (r > rows_bytes) rows_bytes = r;
    const size_t a = (size_t)pixels[i] * fe->conv[i].out_channels;
    if (a > acc_elems) acc_elems = a;
  }

  size_t rows32_elems = 0;
  for (int i = 0; i < ZF_FE_CONVS; ++i) {
    const size_t r = (size_t)pixels[i] * ((size_t)fe->conv[i].in_channels * fe->conv[i].kh *
                                             fe->conv[i].kw + fe->conv[i].out_channels);
    if (r > rows32_elems) rows32_elems = r;
  }

  const size_t f_buf0 = (size_t)c0 * s.h0 * s.w0;
  const size_t f_buf1 = (size_t)c1 * s.h1 * s.w1;
  const size_t f_bufu = (size_t)c2 * s.h2 * s.w2;
  const size_t f_cat = (size_t)c2 * (s.h2 + 3) * s.w2;
  const size_t f_dw = (size_t)c2 * s.hout * s.w2;
  const size_t f_wide = (size_t)cw * s.hout * s.w2;
  const size_t f_flat = (size_t)s.hout * fe->out_linear.k_pad;
  const size_t f_out = (size_t)s.hout * fe->out_linear.n;

  size_t total = 0;
  total += align_up(qin_bytes);
  total += align_up(rows_bytes);
  total += align_up(acc_elems * sizeof(int32_t));
  total += align_up(rows32_elems * sizeof(float));
  int max_scales = fe->out_linear.n;
  for (int i = 0; i < ZF_FE_CONVS; ++i)
    if (fe->conv[i].out_channels > max_scales) max_scales = fe->conv[i].out_channels;
  total += align_up(f_buf0 * sizeof(float));
  total += align_up(f_buf1 * sizeof(float));
  total += align_up(f_bufu * sizeof(float));
  total += align_up(f_cat * sizeof(float));
  total += align_up(f_dw * sizeof(float));
  total += align_up(f_wide * sizeof(float));
  total += align_up(f_dw * sizeof(float)); /* pw2 */
  total += align_up(f_flat * sizeof(float));
  total += align_up(f_flat);               /* flat, quantised */
  total += align_up(f_out * sizeof(int32_t));
  total += align_up(f_out * sizeof(float));
  total += align_up((size_t)max_scales * sizeof(float));

  fe->arena = (unsigned char *)calloc(1, total);
  if (!fe->arena) {
    if (error) *error = "cannot allocate the front-end arena";
    return 0;
  }
  fe->arena_bytes = total;
  unsigned char *p = fe->arena;
#define TAKE(field, type, elems)                     \
  do {                                               \
    fe->field = (type *)p;                            \
    p += align_up((size_t)(elems) * sizeof(type));    \
  } while (0)
  fe->qin = (int8_t *)p;
  p += align_up(qin_bytes);
  fe->rows = (int8_t *)p;
  p += align_up(rows_bytes);
  TAKE(acc, int32_t, acc_elems);
  TAKE(rows32, float, rows32_elems);
  TAKE(buf0, float, f_buf0);
  TAKE(buf1, float, f_buf1);
  TAKE(bufu, float, f_bufu);
  TAKE(bufcat, float, f_cat);
  TAKE(bufdw, float, f_dw);
  TAKE(bufwide, float, f_wide);
  TAKE(bufpw2, float, f_dw);
  TAKE(flat, float, f_flat);
  fe->flat_q = (int8_t *)p;
  p += align_up(f_flat);
  TAKE(out_acc, int32_t, f_out);
  TAKE(out_f32, float, f_out);
  TAKE(scales, float, max_scales);
#undef TAKE
  return 1;
}

int zf_frontend_set_swoosh_l_offset(ZfFrontEnd *fe, float offset) {
  if (!fe || (offset != 4.0f && offset != 1.0f)) return -1;
  fe->swoosh_l = offset == 1.0f ? ZF_SWOOSH_L1 : ZF_SWOOSH_L;
  return 0;
}

ZfFrontEnd *zf_frontend_create(ZfWeights *w, int max_frames, const char **error) {
  const char *why = "unknown";
  ZfFrontEnd *fe = (ZfFrontEnd *)calloc(1, sizeof(ZfFrontEnd));
  if (!fe) {
    if (error) *error = "out of memory";
    return NULL;
  }
  fe->w = w;
  fe->max_frames = max_frames;
  fe->prev_x = (float *)malloc((size_t)max_frames * ZF_FE_BINS * sizeof(float));
  fe->prog_x = (float *)malloc((size_t)max_frames * ZF_FE_BINS * sizeof(float));
  if (!fe->prev_x || !fe->prog_x) {
    why = "out of memory";
    goto fail;
  }
  static const char *const names[ZF_FE_CONVS] = {"conv0", "conv1", "conv2", "pw1", "pw2"};
  for (int i = 0; i < ZF_FE_CONVS; ++i) {
    /* conv1 and conv2 read a pixel-major input, so their k axis is permuted to match */
    if (!conv_from_weights(w, names[i], &fe->conv[i], i == 1 || i == 2)) {
      why = "a front-end convolution is missing from the weight file";
      goto fail;
    }
  }
  /* The fp32 form of the same five, when the file carries it. Optional on purpose: a weight file
   * built before tools/zfw.py emitted these still loads and still runs the int8 path. */
  for (int i = 0; i < ZF_FE_CONVS; ++i) {
    char n32[64];
    size_t n32_count = 0;
    snprintf(n32, sizeof n32, "%s.w32", names[i]);
    const float *w32 = zf_weights_f32(w, n32, &n32_count);
    const size_t want = (size_t)fe->conv[i].out_channels * fe->conv[i].in_channels *
                        fe->conv[i].kh * fe->conv[i].kw;
    fe->conv_w32[i] = (w32 && n32_count == want) ? w32 : NULL;
    /* conv1 and conv2 read a pixel-major input, so their fp32 k axis is permuted to match the
     * gather, exactly as the int8 path permutes its packed weight.
     *
     * ZF_CONV_ORT wants the opposite: ONNX stores the weight as (channel, dy, dx) and that is the
     * order MLAS sums in, so under that switch the weight is left exactly as the file holds it and
     * im2col does the strided gather instead. Permuting here and summing sequentially would still
     * be the wrong sum, which is what an earlier round measured and misread. */
    {
      const char *ort_order = zf_getenv("ZF_CONV_ORT");
      if (fe->conv_w32[i] && (i == 1 || i == 2) && !(ort_order && atoi(ort_order)) &&
          !zf_weights_reorder_conv_k_f32(w, n32, fe->conv[i].out_channels, fe->conv[i].in_channels,
                                         fe->conv[i].kh, fe->conv[i].kw))
        fe->conv_w32[i] = NULL;
    }
  }
  /* Say so when an fp32 convolution was asked for and the file cannot supply it.
   *
   * The fallback above is deliberate, so an older weight file still runs, but it is silent, and a
   * silent fallback here is the worst kind: the caller asked for the exact front end, gets the int8
   * one, and every number it then reports is the int8 number wearing an fp32 label. The repository's
   * own lab/data/zf/frontend.zfw is such a file -- 34 tensors, no .w32, 643,780 bytes against the
   * 1,194,308 of one built by tools/zfw.py -- so this is a live trap, not a hypothetical. */
  for (int i = 0; i < ZF_FE_CONVS; ++i) {
    if (fe_conv_is_f32(i) && !fe->conv_w32[i]) {
      fprintf(stderr,
              "zf: %s asked for in fp32 but the weight file has no %s.w32; running it in int8. "
              "Rebuild the weight file with tools/zfw.py.\n",
              names[i], names[i]);
    }
  }
  size_t count = 0;
  const ZfTensor *dw = zf_weights_find(w, "dw.weight");
  fe->dw_weight = zf_weights_f32(w, "dw.weight", &count);
  fe->dw_bias = zf_weights_f32(w, "dw.bias", &count);
  if (!dw || !fe->dw_weight || !fe->dw_bias) {
    why = "the depthwise weights are missing";
    goto fail;
  }
  fe->dw_channels = dw->dims[0];
  fe->dw_kh = dw->dims[2];
  fe->dw_kw = dw->dims[3];
  fe->dw_pad = (fe->dw_kw - 1) / 2;

  const ZfTensor *shape = zf_weights_find(w, "out.shape");
  fe->out_linear.packed = zf_weights_s8(w, "out.packed", &count);
  fe->out_linear.row_sums = zf_weights_s32(w, "out.rowsums", &count);
  fe->out_scale = zf_weights_f32(w, "out.scale", &count);
  fe->out_scale_count = (int)count;
  if (!shape || !fe->out_linear.packed || !fe->out_linear.row_sums || !fe->out_scale) {
    why = "the output linear is missing from the weight file";
    goto fail;
  }
  fe->out_linear.k = ((const int32_t *)shape->data)[0];
  fe->out_linear.n = ((const int32_t *)shape->data)[1];
  fe->out_linear.k_pad = (fe->out_linear.k + ZF_S8_K_GROUP - 1) / ZF_S8_K_GROUP * ZF_S8_K_GROUP;
  fe->out_linear.n_blocks = (fe->out_linear.n + ZF_S8_UNIT_BLOCK - 1) / ZF_S8_UNIT_BLOCK;
  fe->out_bias = zf_weights_f32(w, "out.bias", &count);
  fe->norm_bias = zf_weights_f32(w, "out_norm.bias", &count);
  const float *norm_scale = zf_weights_f32(w, "out_norm.scale", &count);
  if (!fe->norm_bias || !norm_scale) {
    why = "the output norm is missing from the weight file";
    goto fail;
  }
  fe->norm_scale = norm_scale[0];
  if (!build_arena(fe, error)) {
    zf_frontend_destroy(fe);
    return NULL;
  }
  {
    /* band scratch for the incremental path: the widest channel count by the tallest band */
    const Shapes ms = plan_shapes(fe, max_frames);
    int ch = fe->dw_channels;
    for (int i = 0; i < ZF_FE_CONVS; ++i)
      if (fe->conv[i].out_channels > ch) ch = fe->conv[i].out_channels;
    const size_t floats = (size_t)ch * (size_t)(ms.h2 + 3 + fe->dw_kh) * (size_t)ms.w2;
    fe->band_in = (float *)malloc(floats * sizeof(float));
    fe->band_out = (float *)malloc(floats * sizeof(float));
    fe->prog_state = (float *)malloc((size_t)zf_frontend_state_floats(fe) * sizeof(float));
    if (!fe->band_in || !fe->band_out || !fe->prog_state) {
      zf_frontend_destroy(fe);
      if (error) *error = "out of memory";
      return NULL;
    }
  }
  if (error) *error = NULL;
  return fe;

fail:
  zf_frontend_destroy(fe);
  if (error) *error = why;
  return NULL;
}

void zf_frontend_destroy(ZfFrontEnd *fe) {
  if (!fe) return;
  free(fe->prev_x);
  free(fe->prog_x);
  free(fe->band_in);
  free(fe->band_out);
  free(fe->prog_state);
  free(fe->arena);
  free(fe);
}

/* ------------------------------------------------------------------- running */

typedef struct {
  const ZfConvS8 *c;
  const int8_t *qin;
  int8_t *rows_out;
  int h, w;
  int8_t pad_value;
  int tasks;
  int in_pixel_major; /* the input is one row per pixel, so k is (dy, dx, channel) */
} Im2colTask;

static void im2col_slice(void *user, size_t index) {
  const Im2colTask *t = (const Im2colTask *)user;
  const int out_h = zf_conv_out_h(t->c, t->h);
  const int begin = (int)((size_t)out_h * index / (size_t)t->tasks);
  const int end = (int)((size_t)out_h * (index + 1) / (size_t)t->tasks);
  if (begin >= end) return;
  if (t->in_pixel_major)
    zf_conv_im2col_rows_pm(t->c, t->qin, t->h, t->w, t->pad_value, t->rows_out, begin, end);
  else
    zf_conv_im2col_rows(t->c, t->qin, t->h, t->w, t->pad_value, t->rows_out, begin, end);
}

typedef struct {
  const ZfConvS8 *c;
  const int8_t *rows;
  int32_t *acc;
  float *out;
  int pixels;
  float a_scale;
  int a_zero_point;
  int tasks;
  int by_pixel;
  int out_pixel_major; /* leave the result as one row per pixel instead of transposing to NCHW */
  int swoosh;          /* -1 none, else a ZF_SWOOSH_* variant: applied to this task's own output */
  ZfFrontEnd *fe;
} ConvTask;

/* Split by output pixels when there are many, by output channels when there are few.
 *
 * Splitting a wide convolution by channel gives each thread a quarter of the columns of one
 * accumulator slab, so all four walk the whole slab with a stride: the 1x1 convolutions here have
 * 456 pixels by 384 channels, 700 KB, which is larger than this chip's L2. Splitting by pixel
 * gives each thread a contiguous block of rows instead. */
static void conv_slice(void *user, size_t index) {
  ConvTask *t = (ConvTask *)user;
  const int channels = t->c->out_channels;
  if (t->by_pixel) {
    const int p0 = (int)((size_t)t->pixels * index / (size_t)t->tasks);
    const int p1 = (int)((size_t)t->pixels * (index + 1) / (size_t)t->tasks);
    if (p0 >= p1) return;
    const int8_t *rows = t->rows + (size_t)p0 * t->c->weights.k_pad;
    int32_t *acc = t->acc + (size_t)p0 * channels;
    if (t->out_pixel_major) {
      /* A pixel-major result is scaled in place, one row per pixel at the accumulator's own
       * stride, which is exactly what the microkernel's epilogue does. So the int32 never reaches
       * memory here either: conv_dequantize was 27 per cent of the front end. */
      float *dst = t->out + (size_t)p0 * channels;
      zf_linear_s8_f32_range(rows, p1 - p0, t->c->weights.k_pad, &t->c->weights, t->a_zero_point,
                             acc, t->fe->scales, t->c->scale_count, t->c->bias, dst, channels, 0,
                             t->c->weights.n_blocks);
      const double t0 = now_ms();
      if (t->swoosh >= 0) zf_swoosh_fe(dst, dst, (size_t)(p1 - p0) * channels, t->swoosh);
      t->fe->stage_ms[15] += now_ms() - t0;
      return;
    }
    zf_linear_s8_range(rows, p1 - p0, t->c->weights.k_pad, &t->c->weights, t->a_zero_point, acc,
                       channels, 0, t->c->weights.n_blocks);
    {
      /* this thread's pixels, all channels: the transpose into NCHW, one block of rows at a time,
       * which still wants the int32 slab to transpose from */
      const double t0 = now_ms();
      zf_conv_dequantize_pixels(t->c, acc, t->pixels, p1 - p0, p0, t->a_scale, t->out);
      const double t1 = now_ms();
      t->fe->stage_ms[11] += t1 - t0;
      if (t->swoosh >= 0)
        zf_conv_swoosh_channels(t->pixels, p1 - p0, p0, t->out, 0, channels, t->swoosh);
      t->fe->stage_ms[15] += now_ms() - t1;
    }
    return;
  }
  const int blocks = t->c->weights.n_blocks;
  const int begin = (int)((size_t)blocks * index / (size_t)t->tasks);
  const int end = (int)((size_t)blocks * (index + 1) / (size_t)t->tasks);
  if (begin >= end) return;
  zf_linear_s8_range(t->rows, t->pixels, t->c->weights.k_pad, &t->c->weights, t->a_zero_point,
                     t->acc, channels, begin, end);
  const int j0 = begin * ZF_S8_UNIT_BLOCK;
  int j1 = end * ZF_S8_UNIT_BLOCK;
  if (j1 > channels) j1 = channels;
  const double t0 = now_ms();
  zf_conv_dequantize_channels(t->c, t->acc, t->pixels, t->a_scale, t->out, j0, j1);
  if (t->swoosh >= 0)
    zf_conv_swoosh_channels(t->pixels, t->pixels, 0, t->out, j0, j1, t->swoosh);
  t->fe->stage_ms[11] += now_ms() - t0;
}

/* The two 1x1 convolutions of the ConvNeXt block, which are matmuls over 456 rows.
 *
 * A 1x1 gather is exactly the transpose from NCHW to one row per pixel, so it fuses into the
 * quantiser, and when the previous convolution already left its result one row per pixel there is
 * nothing to gather at all. Between them sits only SwooshL, which does not care about the layout.
 * Together that removes two full passes over the 175 thousand element hidden activation, which the
 * stage timer had at a third of this block's time. */
typedef struct {
  ZfFrontEnd *fe;
  const ZfConvS8 *c;
  const float *in;
  int pixels, k, in_pixel_major, tasks;
  float scale;
  int zero_point;
  float lo[8], hi[8];
} Q1Task;

static void q1_scan(void *user, size_t index) {
  Q1Task *t = (Q1Task *)user;
  /* the input is [k, pixels] or [pixels, k]; either way the range is over every value, and
   * splitting along the outer axis gives each task a contiguous span */
  const int rows = t->in_pixel_major ? t->pixels : t->k;
  const int len = t->in_pixel_major ? t->k : t->pixels;
  const int b = (int)((size_t)rows * index / (size_t)t->tasks);
  const int e = (int)((size_t)rows * (index + 1) / (size_t)t->tasks);
  if (b < e) zf_quantize_range_rows(t->in, len, &t->lo[index], &t->hi[index], b, e);
}

static void q1_write(void *user, size_t index) {
  const Q1Task *t = (const Q1Task *)user;
  const int b = (int)((size_t)t->pixels * index / (size_t)t->tasks);
  const int e = (int)((size_t)t->pixels * (index + 1) / (size_t)t->tasks);
  if (b >= e) return;
  if (t->in_pixel_major)
    zf_quantize_write_rows(t->in, t->k, t->c->weights.k_pad, t->fe->rows, t->scale,
                           t->zero_point, b, e);
  else
    zf_conv_quantize_pixels(t->c, t->in, t->pixels, t->scale, t->zero_point, t->fe->rows, b, e);
}

/* The residual, then the transpose into the output linear's row layout.
 *
 * Two regions rather than one, and they cannot be merged. The residual is per channel, but the
 * gather's outer index is a row of the transposed result, which reads every channel, so a task that
 * did both would read channels its neighbours had not written yet. The barrier between them is
 * what makes the second pass see the first. */
typedef struct {
  ZfFrontEnd *fe;
  ZfGather gather;
  int channels, rows, width, h2, tasks, phase;
} TailPass;

static void tail_pass_slice(void *user, size_t index) {
  TailPass *p = (TailPass *)user;
  if (p->phase == 0) {
    const int c0 = (int)((long long)p->channels * index / p->tasks);
    const int c1 = (int)((long long)p->channels * (index + 1) / p->tasks);
    for (int c = c0; c < c1; ++c) {
      float *dst = p->fe->bufpw2 + (size_t)c * p->rows * p->width;
      const float *src = p->fe->bufu + (size_t)c * p->h2 * p->width;
      const int n = p->rows * p->width;
      int i = 0;
#if ZF_NEON_AVAILABLE
      for (; i + 4 <= n; i += 4)
        vst1q_f32(dst + i, vaddq_f32(vld1q_f32(dst + i), vld1q_f32(src + i)));
#endif
      for (; i < n; ++i) dst[i] += src[i];
    }
    return;
  }
  const int64_t o0 = (int64_t)((long long)p->gather.outer * index / p->tasks);
  const int64_t o1 = (int64_t)((long long)p->gather.outer * (index + 1) / p->tasks);
  if (o0 < o1) zf_gather_run(&p->gather, p->fe->bufpw2, p->fe->flat, o0, o1);
}

/* The two pointwise convolutions in fp32.
 *
 * A 1x1 convolution needs no gather at all when its input is already one row of channels per pixel:
 * the im2col IS the input. When it is NCHW it has to be transposed first, which is the only copy
 * here. Either way the product is zf_matmul_nt_f32 against the fp32 weight, exactly as the dense
 * path does, and the result is transposed back out when the caller wanted NCHW. */
/* The swoosh over a block, split across the pool.
 *
 * The int8 path applies its activation inside the tasks that produced the block, so it is threaded
 * for free. The fp32 path produced its block through a threaded matmul and then ran the activation
 * on the calling thread, which measured 7.65 ms of the pointwise pair's 20.2: a quarter of the
 * whole fp32 front end, spent single-threaded for no reason. */
typedef struct {
  float *x;
  size_t n;
  int variant, tasks;
} SwooshJob;

static void swoosh_slice(void *user, size_t index) {
  const SwooshJob *j = (const SwooshJob *)user;
  const size_t b = j->n * index / (size_t)j->tasks;
  const size_t e = j->n * (index + 1) / (size_t)j->tasks;
  if (b >= e) return;
  zf_swoosh_fe(j->x + b, j->x + b, e - b, j->variant);
}

static void run_swoosh(float *x, size_t n, int variant, const ZfParallel *par) {
  int tasks = (par && par->run && par->threads > 1 && n >= 4096) ? par->threads : 1;
  SwooshJob j = {x, n, variant, tasks};
  if (tasks > 1) par->run(par->ctx, swoosh_slice, (size_t)tasks, &j);
  else swoosh_slice(&j, 0);
}

/* The swoosh over the same rows of every channel of an NCHW output, split by channel. */
typedef struct {
  float *x;
  size_t count, plane, first;
  int variant, channels, tasks;
} SwooshRowsTask;

static void swoosh_rows_slice(void *user, size_t index) {
  const SwooshRowsTask *t = (const SwooshRowsTask *)user;
  const int c0 = (int)((size_t)t->channels * index / (size_t)t->tasks);
  const int c1 = (int)((size_t)t->channels * (index + 1) / (size_t)t->tasks);
  for (int ch = c0; ch < c1; ++ch) {
    float *p = t->x + (size_t)ch * t->plane + t->first;
    zf_swoosh_fe(p, p, t->count, t->variant);
  }
}

typedef struct {
  ZfFrontEnd *fe;
  const ZfConvS8 *c;
  const float *w32;
  const float *rows;
  float *dst;
  int pixels, k, n, tasks;
  int accumulate;
} Pw32Task;

/* Refuted: blocking the rows so a block stays in L1 across the sweep of columns.
 *
 * zf_matmul_nt_f32 is column-group outer and row inner, so the FIRST operand is re-read for every
 * group of four columns: for the pointwise convolutions that is 240 rows by 96 groups by 512 bytes,
 * 11.8 MB, and this device reads 1.89 GB/s. That arithmetic predicted the whole 12.7 ms the matmul
 * costs, so blocking the rows looked like the fix. It changes nothing, 12.9 ms against 12.7. The
 * reason is that 123 KB of first operand fits the shared L2, so those re-reads were never going to
 * DRAM and the 1.89 GB/s figure did not apply to them. */
/* Split by output COLUMNS rather than by pixels.
 *
 * By pixels, every thread walks the whole weight matrix: 196 KB in fp32 for the wider pointwise,
 * read four times over. Measured, that threads at 1.55x rather than 4x, which is most of the 6.9 ms
 * the pointwise pair costs over int8. By column each thread reads its own quarter of the weight and
 * they share one copy of the activations.
 *
 * Both n are multiples of four, 384 and 128, so every slice stays on the tile's fast path; the
 * boundaries are rounded down to four anyway, and the last task takes the remainder. */
static void pw32_slice(void *user, size_t index) {
  const Pw32Task *t = (const Pw32Task *)user;
  int j0 = (int)(((size_t)t->n * index / (size_t)t->tasks) & ~(size_t)3);
  int j1 = (index + 1 == (size_t)t->tasks)
               ? t->n
               : (int)(((size_t)t->n * (index + 1) / (size_t)t->tasks) & ~(size_t)3);
  if (j0 >= j1) return;
  /* Refuted: blocking these rows so a block stays in L1 across the sweep of columns.
   *
   * The tile is column-group outer and row inner, so the activations are re-read once per group of
   * four columns, and by column each thread walks all the rows: for the wider pointwise that is 24
   * groups over 123 KB, about 3 MB a thread. Blocking to roughly 16 KB should read them once a
   * block instead. Measured, with the code confirmed to run this time: pw_gemm 7.545 ms against
   * 7.556, pointwise 12.877 against 12.942. Nothing. Whatever holds this to 1.92x of four threads,
   * it is not the activations' reuse distance. */
#if ZF_NEON_AVAILABLE
  if (t->accumulate) {
    zf_matmul_nt_seq_acc_f32(t->rows, t->k, t->w32 + (size_t)j0 * t->k, t->k, t->pixels, j1 - j0,
                             t->k, t->dst + j0, t->n);
    return;
  }
#endif
  zf_matmul_nt4x4_f32(t->rows, t->k, t->w32 + (size_t)j0 * t->k, t->k, t->pixels, j1 - j0, t->k,
                      t->dst + j0, t->n);
}

/* The two moves around the matmul, and the bias.
 *
 * The matmul between them was threaded and these were not, so they ran on the calling thread while
 * three cores waited: 0.85 ms for the transpose in and 2.42 ms for the bias and the transpose out,
 * 3.27 ms of a chunk, which is a quarter of the whole serial budget a thread sweep attributes to a
 * chunk. Neither reorders any arithmetic, so splitting them cannot move a bit. */
typedef struct {
  const float *in;
  const float *dst;
  const float *bias;
  float *rows32;
  float *out;
  int pixels, k, n, tasks;
  const float *resid;
  int resid_stride;
} PwMoveTask;

/* By pixel, because a task then owns whole rows of k channels and a row is k * 4 bytes, which for
 * both pointwise widths is a multiple of the cache line: no two tasks touch the same line. */
static void pw32_in_slice(void *user, size_t index) {
  const PwMoveTask *t = (const PwMoveTask *)user;
  const int pa = (int)((size_t)t->pixels * index / (size_t)t->tasks);
  const int pb = (int)((size_t)t->pixels * (index + 1) / (size_t)t->tasks);
  if (pa >= pb) return;
  const int B = 16;
  for (int c0 = 0; c0 < t->k; c0 += B) {
    const int c1 = (c0 + B < t->k) ? c0 + B : t->k;
    for (int p0 = pa; p0 < pb; p0 += B) {
      const int p1 = (p0 + B < pb) ? p0 + B : pb;
      for (int ch = c0; ch < c1; ++ch) {
        const float *plane = t->in + (size_t)ch * t->pixels;
        float *d = t->rows32 + ch;
        for (int p = p0; p < p1; ++p) d[(size_t)p * t->k] = plane[p];
      }
    }
  }
}

/* By output channel, with the bias folded into the move.
 *
 * Folding is free and exact: the old code stored o[j] + bias[j] into a float and the transpose then
 * copied that float, so adding during the move is the same single rounded fp32 addition. The no-bias
 * case keeps its own loop rather than adding a zero, because -0.0f + 0.0f is +0.0f and that would
 * be a changed bit. */
static void pw32_out_slice(void *user, size_t index) {
  const PwMoveTask *t = (const PwMoveTask *)user;
  const int ja = (int)((size_t)t->n * index / (size_t)t->tasks);
  const int jb = (int)((size_t)t->n * (index + 1) / (size_t)t->tasks);
  if (ja >= jb) return;
  const int B = 16;
  for (int j0 = ja; j0 < jb; j0 += B) {
    const int j1 = (j0 + B < jb) ? j0 + B : jb;
    for (int p0 = 0; p0 < t->pixels; p0 += B) {
      const int p1 = (p0 + B < t->pixels) ? p0 + B : t->pixels;
      for (int j = j0; j < j1; ++j) {
        float *plane = t->out + (size_t)j * t->pixels;
        const float *src = t->dst + j;
        if (t->bias) {
          const float b = t->bias[j];
          for (int p = p0; p < p1; ++p) plane[p] = src[(size_t)p * t->n] + b;
        } else {
          for (int p = p0; p < p1; ++p) plane[p] = src[(size_t)p * t->n];
        }
      }
    }
  }
}

/* The pixel-major case has no transpose out, so the bias is applied where it lies, by row. */
static void pw32_bias_slice(void *user, size_t index) {
  const PwMoveTask *t = (const PwMoveTask *)user;
  const int pa = (int)((size_t)t->pixels * index / (size_t)t->tasks);
  const int pb = (int)((size_t)t->pixels * (index + 1) / (size_t)t->tasks);
  if (pa >= pb) return;
  for (int p = pa; p < pb; ++p) {
    float *o = t->out + (size_t)p * t->n;
    for (int j = 0; j < t->n; ++j) o[j] += t->bias[j];
  }
}

/* Same threshold as the activation: below it the barrier costs more than the work. */
/* The residual, NCHW, into the pixel-major matmul output it will be accumulated onto. */
static void pw32_resid_slice(void *user, size_t index) {
  const PwMoveTask *t = (const PwMoveTask *)user;
  const int ja = (int)((size_t)t->n * index / (size_t)t->tasks);
  const int jb = (int)((size_t)t->n * (index + 1) / (size_t)t->tasks);
  float *dst = (float *)t->dst;
  for (int j = ja; j < jb; ++j) {
    const float *src = t->resid + (size_t)j * t->resid_stride;
    for (int p = 0; p < t->pixels; ++p) dst[(size_t)p * t->n + j] = src[p];
  }
}

static void pw32_move(const ZfParallel *par, void (*fn)(void *, size_t), PwMoveTask *t,
                      size_t values) {
  int tasks = (par && par->run && par->threads > 1 && values >= 4096) ? par->threads : 1;
  if (tasks < 1) tasks = 1;
  t->tasks = tasks;
  if (tasks > 1) par->run(par->ctx, fn, (size_t)tasks, t);
  else fn(t, 0);
}

static void run_conv_1x1_f32(ZfFrontEnd *fe, const ZfConvS8 *c, const float *w32, const float *in,
                             int pixels, int in_pixel_major, int out_pixel_major, float *out,
                             int swoosh, const ZfParallel *par) {
  const int k = c->in_channels, n = c->out_channels;
  const double t0 = now_ms();
  const float *rows = in;
  double tstage = now_ms();
  if (!in_pixel_major) {
    /* NCHW to one row of channels per pixel, in 16x16 blocks.
     *
     * The obvious loop writes down a column at stride k, which for 128 channels is a 512 byte
     * stride and a cache line touched per value. Blocking keeps both sides inside a few lines: this
     * transpose and its twin below were about 20 ms of the 24.6 the pointwise pair cost, far more
     * than the multiplication between them, which is the same trap the int8 path documents. */
    PwMoveTask t = {in, NULL, NULL, fe->rows32, NULL, pixels, k, n, 1, NULL, 0};
    pw32_move(par, pw32_in_slice, &t, (size_t)pixels * (size_t)k);
    rows = fe->rows32;
  }
  fe->stage_ms[12] += now_ms() - tstage; /* transpose in */
  tstage = now_ms();
  float *dst = out_pixel_major ? out : fe->rows32 + (size_t)pixels * k;
  int tasks = (par && par->run && par->threads > 1) ? par->threads : 1;
  if (tasks > n / 4) tasks = n / 4;
  if (tasks < 1) tasks = 1;
  /* ZF_CONV_ORT: on ARM, ONNX Runtime fuses pointwise_conv2 with the residual Add after it
   * (ConvAddActivationFusion; on x86 the NCHWc transformer takes the node first, which is why no
   * x86 trace ever showed it). Its Conv kernel copies the residual into the output and runs MLAS
   * with beta = 1, so every k stride is added onto the residual and the bias comes last:
   *     (((residual + blk0) + blk1) + blk2) + bias      not      (((blk0 + blk1) + blk2) + bias) + residual
   * Exposing the convolution's output as a graph output blocks the fusion, which is why the
   * instrumented trace graph agreed with the unfused form and the deployed graph did not. */
  const int fuse = fe->fused_resid && !out_pixel_major;
  if (fuse) {
    PwMoveTask r = {NULL, dst, NULL, NULL, NULL, pixels, k, n, 1, fe->fused_resid,
                    fe->fused_resid_stride};
    pw32_move(par, pw32_resid_slice, &r, (size_t)pixels * (size_t)n);
    fe->fused_done = 1;
  }
  Pw32Task t = {fe, c, w32, rows, dst, pixels, k, n, tasks, fuse};
  if (tasks > 1) par->run(par->ctx, pw32_slice, (size_t)tasks, &t);
  else pw32_slice(&t, 0);
  fe->stage_ms[13] += now_ms() - tstage; /* the matmul alone */
  tstage = now_ms();

  if (!out_pixel_major) {
    /* One pass, threaded: the bias rides along with the transpose. */
    PwMoveTask t = {NULL, dst, c->bias, NULL, out, pixels, k, n, 1, NULL, 0};
    pw32_move(par, pw32_out_slice, &t, (size_t)pixels * (size_t)n);
  } else if (c->bias) {
    PwMoveTask t = {NULL, NULL, c->bias, NULL, dst, pixels, k, n, 1, NULL, 0};
    pw32_move(par, pw32_bias_slice, &t, (size_t)pixels * (size_t)n);
  }
  fe->stage_ms[14] += now_ms() - tstage; /* bias and the transpose out */
  (void)t0;

  if (swoosh >= 0) {
    const double t1 = now_ms();
    run_swoosh(out, (size_t)pixels * n, swoosh, par);
    fe->stage_ms[15] += now_ms() - t1;
  }
}

static void run_conv_1x1(ZfFrontEnd *fe, const ZfConvS8 *c, const float *in, int pixels,
                         int in_pixel_major, int out_pixel_major, float *out, int swoosh,
                         const ZfParallel *par) {
  {
    const int idx = (int)(c - fe->conv);
    if (fe_conv_is_f32(idx) && fe->conv_w32[idx]) {
      run_conv_1x1_f32(fe, c, fe->conv_w32[idx], in, pixels, in_pixel_major, out_pixel_major, out,
                       swoosh, par);
      return;
    }
  }
  double t = now_ms();
  Q1Task q;
  memset(&q, 0, sizeof q);
  q.fe = fe;
  q.c = c;
  q.in = in;
  q.pixels = pixels;
  q.k = c->in_channels;
  q.in_pixel_major = in_pixel_major;
  q.tasks = (par && par->run && par->threads > 1) ? par->threads : 1;
  if (q.tasks > 8) q.tasks = 8;
  if (q.tasks > 1) {
    par->run(par->ctx, q1_scan, (size_t)q.tasks, &q);
    float lo = 0.0f, hi = 0.0f;
    for (int i = 0; i < q.tasks; ++i) {
      if (q.lo[i] < lo) lo = q.lo[i];
      if (q.hi[i] > hi) hi = q.hi[i];
    }
    zf_quantize_params(lo, hi, &q.scale, &q.zero_point);
    par->run(par->ctx, q1_write, (size_t)q.tasks, &q);
  } else {
    q1_scan(&q, 0);
    zf_quantize_params(q.lo[0], q.hi[0], &q.scale, &q.zero_point);
    q1_write(&q, 0);
  }
  fe->stage_ms[8] += now_ms() - t;
  fe->stage_ms[12] += now_ms() - t;

  const double t_sc = now_ms();
  for (int j = 0; j < c->out_channels; ++j)
    fe->scales[j] = q.scale * (c->scale_count == 1 ? c->scale[0] : c->scale[j]);
  int tasks = (par && par->run && par->threads > 1) ? par->threads : 1;
  if (tasks > pixels) tasks = pixels;
  ConvTask task = {c,     fe->rows, fe->acc, out,             pixels, q.scale, q.zero_point,
                   tasks, 1,        out_pixel_major, swoosh, fe};
  fe->stage_ms[14] += now_ms() - t_sc;
  t = now_ms();
  if (tasks > 1)
    par->run(par->ctx, conv_slice, (size_t)tasks, &task);
  else
    conv_slice(&task, 0);
  fe->stage_ms[10] += now_ms() - t;
  fe->stage_ms[13] += now_ms() - t;
}

/* ZF_FE_F32: run the front end's dense convolutions in fp32 rather than int8.
 *
 * The deployed graph runs them in fp32. Running them in int8 measures as a 3.64 per cent relative
 * error against the graph, and bisecting the rewrite pass by pass showed that error is the SOLE
 * cause of the engine's token divergence from the published model: the fused encoder layers, which
 * are the project's largest speed win, are near exact on their own. With these five in fp32 a numpy
 * model of this arithmetic reproduces the graph's front end to 0.000000 mean error.
 *
 * It is close to free because of what it removes as well as what it costs. The int8 path pays to
 * quantise the activations, and to turn int32 accumulators back into floats, before it can use a
 * cheaper multiply; measured on the case those are 1.21, 0.88 and 2.28 core-ms against 18.2 for the
 * two GEMMs. fp32 pays about a third more per multiply-add and none of the rest. The weights are
 * four times the bytes, but these five convolutions are 137 thousand weights against the 63 MB a
 * chunk streams, so that is under one per cent of the memory. */
static void run_conv_f32(ZfFrontEnd *fe, const ZfConvS8 *c, const float *w32, const float *in,
                         int h, int w, float *out, int swoosh, int in_pixel_major,
                         int out_pixel_major, int oy_start, const ZfParallel *par);

typedef struct {
  ZfFrontEnd *fe;
  const ZfConvS8 *c;
  const float *w32;
  const float *in;
  float *out;
  int h, w, tasks, in_pm, out_pm;
  int oy_start;
} ConvF32Task;

static void conv_f32_slice(void *user, size_t index) {
  const ConvF32Task *t = (const ConvF32Task *)user;
  const int rows = zf_conv_out_h(t->c, t->h) - t->oy_start;
  const int y0 = t->oy_start + (int)((size_t)rows * index / (size_t)t->tasks);
  const int y1 = t->oy_start + (int)((size_t)rows * (index + 1) / (size_t)t->tasks);
  if (y0 >= y1) return;
  zf_conv_f32(t->c, t->w32, t->in, t->h, t->w, t->fe->rows32, t->out, t->in_pm, t->out_pm, y0, y1);
}

/* One convolution in fp32, split by output row like the int8 path. The NCHW-output case threads
 * too: its bands are disjoint in pixel index, so each writes its own region of the transpose
 * scratch. */
static void run_conv_f32(ZfFrontEnd *fe, const ZfConvS8 *c, const float *w32, const float *in,
                         int h, int w, float *out, int swoosh, int in_pixel_major,
                         int out_pixel_major, int oy_start, const ZfParallel *par) {
  const int out_h = zf_conv_out_h(c, h);
  const int out_w = zf_conv_out_w(c, w);
  const int rows = out_h - oy_start;
  const double t0 = now_ms();
  int tasks = (par && par->run && par->threads > 1 && rows >= 4) ? par->threads : 1;
  if (tasks > rows) tasks = rows;
  ConvF32Task task = {fe, c, w32, in, out, h, w, tasks, in_pixel_major, out_pixel_major,
                      oy_start};
  if (tasks > 1) par->run(par->ctx, conv_f32_slice, (size_t)tasks, &task);
  else conv_f32_slice(&task, 0);
  fe->stage_ms[10] += now_ms() - t0;

  /* Only the rows computed here: rows below oy_start were carried over already activated. */
  if (swoosh >= 0) {
    const double t1 = now_ms();
    const size_t plane = (size_t)rows * out_w;
    if (out_pixel_major || oy_start == 0) {
      run_swoosh(out + (size_t)oy_start * out_w * c->out_channels, plane * c->out_channels,
                 swoosh, par);
    } else {
      SwooshRowsTask st = {out, plane, (size_t)out_h * out_w, (size_t)oy_start * out_w, swoosh,
                           c->out_channels, 1};
      st.tasks = (par && par->run && par->threads > 1) ? par->threads : 1;
      if (st.tasks > 1) par->run(par->ctx, swoosh_rows_slice, (size_t)st.tasks, &st);
      else swoosh_rows_slice(&st, 0);
    }
    fe->stage_ms[15] += now_ms() - t1;
  }
}

static void run_conv(ZfFrontEnd *fe, const ZfConvS8 *c, const float *in, int h, int w, float *out,
                     int swoosh, int in_pixel_major, int out_pixel_major, int oy_start,
                     const ZfParallel *par) {
  /* `c` always points into fe->conv, so its index gives the matching fp32 weight. The fp32 path
   * produces a pixel-major result, so it stands in only where the caller wanted one. */
  {
    const int idx = (int)(c - fe->conv);
    if (fe_conv_is_f32(idx) && fe->conv_w32[idx]) {
      run_conv_f32(fe, c, fe->conv_w32[idx], in, h, w, out, swoosh, in_pixel_major,
                   out_pixel_major, oy_start, par);
      return;
    }
  }
  const size_t in_count = (size_t)c->in_channels * h * w;
  float a_scale = 0.0f;
  int a_zp = 0;
  double t = now_ms();
  zf_dynamic_quantize_shifted(in, in_count, fe->qin, &a_scale, &a_zp);
  fe->stage_ms[8] += now_ms() - t;
  t = now_ms();
  {
    const int out_h = zf_conv_out_h(c, h);
    int tasks = (par && par->run && par->threads > 1 && out_h >= 8) ? par->threads : 1;
    if (tasks > out_h) tasks = out_h;
    Im2colTask it = {c, fe->qin, fe->rows, h, w, (int8_t)(a_zp - 128), tasks, in_pixel_major};
    if (tasks > 1)
      par->run(par->ctx, im2col_slice, (size_t)tasks, &it);
    else
      im2col_slice(&it, 0);
  }
  fe->stage_ms[9] += now_ms() - t;
  const int pixels = zf_conv_out_h(c, h) * zf_conv_out_w(c, w);
  int tasks = (par && par->run && par->threads > 1) ? par->threads : 1;
  const int by_pixel = pixels >= 64;
  if (!by_pixel && tasks > c->weights.n_blocks) tasks = c->weights.n_blocks;
  if (by_pixel && tasks > pixels) tasks = pixels;
  /* The pixel-major scaling reads the combined scales from the front end, where the transposing
   * form derives them per channel group itself, so they have to be there before the dispatch. */
  if (out_pixel_major)
    for (int j = 0; j < c->out_channels; ++j)
      fe->scales[j] = a_scale * (c->scale_count == 1 ? c->scale[0] : c->scale[j]);
  ConvTask task = {c,     fe->rows, fe->acc,          out,    pixels, a_scale, a_zp,
                   tasks, by_pixel, out_pixel_major, swoosh, fe};
  t = now_ms();
  if (tasks > 1)
    par->run(par->ctx, conv_slice, (size_t)tasks, &task);
  else
    conv_slice(&task, 0);
  fe->stage_ms[10] += now_ms() - t;
}


typedef struct {
  ZfFrontEnd *fe;
  const float *in;
  float *out;
  int h, w, out_h, out_w;
  int tasks;
} DwTask;

static void dw_slice(void *user, size_t index) {
  const DwTask *t = (const DwTask *)user;
  const ZfFrontEnd *fe = t->fe;
  const int c0 = (int)((size_t)fe->dw_channels * index / (size_t)t->tasks);
  const int c1 = (int)((size_t)fe->dw_channels * (index + 1) / (size_t)t->tasks);
  if (c0 >= c1) return;
  zf_conv_dw2d_f32(t->in, fe->dw_channels, t->h, t->w, fe->dw_weight, fe->dw_kh, fe->dw_kw, 1, 1,
                   0, fe->dw_pad, fe->dw_bias, t->out, t->out_h, t->out_w, c0, c1);
}

typedef struct {
  ZfFrontEnd *fe;
  int rows;
  int a_zero_point;
  float a_scale;
  int tasks;
} OutTask;

static void out_slice(void *user, size_t index) {
  const OutTask *t = (const OutTask *)user;
  ZfFrontEnd *fe = t->fe;
  const int blocks = fe->out_linear.n_blocks;
  const int begin = (int)((size_t)blocks * index / (size_t)t->tasks);
  const int end = (int)((size_t)blocks * (index + 1) / (size_t)t->tasks);
  if (begin >= end) return;
  zf_linear_s8_range(fe->flat_q, t->rows, fe->out_linear.k_pad, &fe->out_linear,
                     t->a_zero_point, fe->out_acc, fe->out_linear.n, begin, end);
  const int j0 = begin * ZF_S8_UNIT_BLOCK;
  int j1 = end * ZF_S8_UNIT_BLOCK;
  if (j1 > fe->out_linear.n) j1 = fe->out_linear.n;
  zf_dequantize_range(fe->out_acc, t->rows, fe->out_linear.n, fe->scales, fe->out_scale_count,
                      fe->out_bias, fe->out_f32, fe->out_linear.n, j0, j1);
}

/* ZF_FE_DUMP=<prefix>: write every stage's output of every call to <prefix>_<call>.bin, as
 * length-prefixed named records (the ZF_DUMP layout), so the front end can be compared against
 * ONNX Runtime's own tensors stage by stage. Diagnostic only; nothing reads it back. Each name
 * carries its layout: "pm" is one row of channels per pixel, "nchw" is a channel to a plane. */
static void fe_dump(FILE *f, const char *name, const float *p, size_t count) {
  if (!f) return;
  const int32_t nl = (int32_t)strlen(name), nb = (int32_t)(count * sizeof(float));
  fwrite(&nl, 4, 1, f);
  fwrite(name, 1, (size_t)nl, f);
  fwrite(&nb, 4, 1, f);
  fwrite(p, sizeof(float), count, f);
}

static FILE *fe_dump_open(void) {
  static _Atomic int call = 0;
  const char *prefix = zf_getenv("ZF_FE_DUMP");
  if (!prefix) return NULL;
  char path[512];
  snprintf(path, sizeof path, "%s_%03d.bin", prefix, call++);
  return fopen(path, "wb");
}

/* Rows of conv0, conv1 and conv2 that the previous window already computed.
 *
 * Streaming windows overlap: 61 frames advancing 48, so the first 13 input frames of a window are
 * the last 13 of the one before, and every convolution row whose receptive field lies inside them
 * is the same function of the same numbers. That is 11 of conv0's 59 rows, 5 of conv1's 29 and 3
 * of conv2's 27, recomputed every chunk to the same bits. In fp32 a row depends on nothing else:
 * the GEMM's order is per output, fixed by k, and no scale is taken over the tensor (which is why
 * the int8 path, whose dynamic quantisation spans the whole input, cannot do this).
 *
 * The advance is not a parameter of the op, but the depthwise cache already assumes it: the next
 * window's conv2 row 0 is this one's row hout. So the input shift is hout times the three
 * convolutions' time strides, and nothing rests on that assumption: the overlap is reused only if
 * the input frames it came from are byte-identical to the previous call's. A caller that seeks,
 * resets or feeds some other window simply recomputes everything.
 *
 * On return keep[i] is the number of leading rows of conv i's output already in place. Returns
 * whether this call leaves all three outputs whole in fp32 for the next call to use. */
static int fe_reuse_rows(ZfFrontEnd *fe, const float *x, int frames, int valid, const Shapes *s,
                         int keep[3]) {
  static _Atomic int on = -1;
  if (on < 0) {
    const char *v = zf_getenv("ZF_FE_REUSE");
    on = v ? atoi(v) : 1;
  }
  keep[0] = keep[1] = keep[2] = 0;
  if (!on) return 0;
  for (int i = 0; i < 3; ++i) {
    const ZfConvS8 *c = &fe->conv[i];
    if (!fe_conv_is_f32(i) || !fe->conv_w32[i]) return 0;
    if (c->pad_top || c->pad_bottom) return 0; /* a padded edge row would not be the same row */
  }
  const int hs[3] = {s->h0, s->h1, s->h2};
  int shift = s->hout; /* in conv2's output rows */
  int sh[3];
  for (int i = 2; i >= 0; --i) {
    sh[i] = shift; /* in conv i's output rows */
    shift *= fe->conv[i].stride_h;
  }
  /* shift is now in input frames */
  if (fe->prev_frames != frames || shift <= 0 || shift >= frames) return 1;
  /* the overlap must be entirely among the frames seen so far, or it cannot be checked */
  if (valid < frames - shift) return 1;
  if (memcmp(x, fe->prev_x + (size_t)shift * ZF_FE_BINS,
             (size_t)(frames - shift) * ZF_FE_BINS * sizeof(float)) != 0)
    return 1;
  for (int i = 0; i < 3; ++i)
    if (sh[i] >= hs[i]) return 1;
  for (int i = 0; i < 3; ++i) keep[i] = hs[i] - sh[i];
  /* the overlap to the front of each output, in that output's layout */
  const size_t r0 = (size_t)s->w0 * fe->conv[0].out_channels;
  const size_t r1 = (size_t)s->w1 * fe->conv[1].out_channels;
  memmove(fe->buf0, fe->buf0 + (size_t)sh[0] * r0, (size_t)keep[0] * r0 * sizeof(float));
  memmove(fe->buf1, fe->buf1 + (size_t)sh[1] * r1, (size_t)keep[1] * r1 * sizeof(float));
  for (int c = 0; c < fe->conv[2].out_channels; ++c) {
    float *plane = fe->bufu + (size_t)c * s->h2 * s->w2;
    memmove(plane, plane + (size_t)sh[2] * s->w2, (size_t)keep[2] * s->w2 * sizeof(float));
  }
  return 1;
}

/* Rows of a convolution's output whose receptive field lies in the first `in_rows` input rows. */
static int fe_rows_from(const ZfConvS8 *c, int in_rows, int cap) {
  if (in_rows < c->kh) return 0;
  const int r = (in_rows - c->kh) / c->stride_h + 1;
  return r < cap ? r : cap;
}

/* Copy rows [r0, r1) of every channel plane of an NCHW tensor into another, with the planes'
 * heights given separately (the band scratch holds only the band). */
static void fe_copy_planes(const float *src, int src_h, int src_r0, float *dst, int dst_h, int dst_r0,
                           int rows, int channels, int width) {
  for (int c = 0; c < channels; ++c)
    memcpy(dst + ((size_t)c * dst_h + dst_r0) * width, src + ((size_t)c * src_h + src_r0) * width,
           (size_t)rows * width * sizeof(float));
}

/* Start a window: take whatever the previous window already computed, and put the cache in front of
 * the depthwise input. */
static void fe_begin_window(ZfFrontEnd *fe, const float *x, int frames, int valid, const float *state,
                            const Shapes *s) {
  int keep[3] = {0, 0, 0};
  (void)fe_reuse_rows(fe, x, frames, valid, s, keep);
  fe->prev_frames = 0; /* until a whole window has rewritten all three outputs */
  for (int i = 0; i < 3; ++i) fe->d[i] = keep[i];
  const int channels = fe->conv[2].out_channels, width = s->w2;
  for (int c = 0; c < channels; ++c)
    memcpy(fe->bufcat + (size_t)c * (s->h2 + 3) * width, state + (size_t)c * 3 * width,
           (size_t)3 * width * sizeof(float));
  if (fe->d[2] > 0)
    fe_copy_planes(fe->bufu, s->h2, 0, fe->bufcat, s->h2 + 3, 3, fe->d[2], channels, width);
  fe->ddw = fe->dpw = 0;
  fe->all_fused = 1;
  fe->win_frames = frames;
  fe->pv = 0;
  memcpy(fe->prog_state, state, (size_t)zf_frontend_state_floats(fe) * sizeof(float));
}

/* Everything the first `valid` frames of the window allow, in bands. conv0 and conv1 write their
 * pixel-major outputs in place (a row's position does not depend on the height); conv2, the
 * depthwise and the second pointwise write channel-major planes whose stride is the whole height,
 * so they compute into the band scratch and are copied into place. The first pointwise reads
 * channel-major planes the same way. Nothing here changes which operations produce a value. */
static void fe_advance(ZfFrontEnd *fe, const float *x, int valid, const Shapes *s,
                       const ZfParallel *par) {
  ZfConvS8 *c0 = &fe->conv[0], *c1 = &fe->conv[1], *c2 = &fe->conv[2];
  const int ch2 = c2->out_channels, width = s->w2;
  double t = now_ms();
  const int r0 = fe_rows_from(c0, valid, s->h0);
  if (r0 > fe->d[0]) {
    run_conv(fe, c0, x, (r0 - 1) * c0->stride_h + c0->kh, ZF_FE_BINS, fe->buf0, 1, 0, 1, fe->d[0],
             par);
    fe->d[0] = r0;
  }
  fe->stage_ms[0] += now_ms() - t;
  t = now_ms();
  const int r1 = fe_rows_from(c1, fe->d[0], s->h1);
  if (r1 > fe->d[1]) {
    run_conv(fe, c1, fe->buf0, (r1 - 1) * c1->stride_h + c1->kh, s->w0, fe->buf1, 1, 1, 1,
             fe->d[1], par);
    fe->d[1] = r1;
  }
  fe->stage_ms[1] += now_ms() - t;
  t = now_ms();
  const int r2 = fe_rows_from(c2, fe->d[1], s->h2);
  if (r2 > fe->d[2]) {
    const int band = r2 - fe->d[2];
    const size_t in_row = (size_t)s->w1 * c1->out_channels; /* buf1 is pixel-major */
    run_conv(fe, c2, fe->buf1 + (size_t)fe->d[2] * c2->stride_h * in_row,
             (band - 1) * c2->stride_h + c2->kh, s->w1, fe->band_out, 1, 1, 0, 0, par);
    fe_copy_planes(fe->band_out, band, 0, fe->bufu, s->h2, fe->d[2], band, ch2, width);
    fe_copy_planes(fe->band_out, band, 0, fe->bufcat, s->h2 + 3, 3 + fe->d[2], band, ch2, width);
    fe->d[2] = r2;
  }
  fe->stage_ms[2] += now_ms() - t;

  /* the depthwise: output row i reads cache-and-conv2 rows i .. i + kh - 1 */
  t = now_ms();
  int rdw = 3 + fe->d[2] - fe->dw_kh + 1;
  if (rdw > s->hout) rdw = s->hout;
  if (rdw > fe->ddw) {
    const int band = rdw - fe->ddw, in_h = band + fe->dw_kh - 1;
    fe_copy_planes(fe->bufcat, s->h2 + 3, fe->ddw, fe->band_in, in_h, 0, in_h, fe->dw_channels, width);
    int tasks = (par && par->run && par->threads > 1) ? par->threads : 1;
    if (tasks > fe->dw_channels) tasks = fe->dw_channels;
    DwTask dt = {fe, fe->band_in, fe->band_out, in_h, width, band, width, tasks};
    if (tasks > 1) par->run(par->ctx, dw_slice, (size_t)tasks, &dt);
    else dw_slice(&dt, 0);
    fe_copy_planes(fe->band_out, band, 0, fe->bufdw, s->hout, fe->ddw, band, fe->dw_channels, width);
    fe->ddw = rdw;
  }
  fe->stage_ms[5] += now_ms() - t;

  /* the two pointwise convolutions, row for row behind the depthwise */
  t = now_ms();
  if (fe->ddw > fe->dpw) {
    const int band = fe->ddw - fe->dpw, pixels = band * width;
    const int wide = fe->conv[3].out_channels;
    fe_copy_planes(fe->bufdw, s->hout, fe->dpw, fe->band_in, band, 0, band, fe->dw_channels, width);
    run_conv_1x1(fe, &fe->conv[3], fe->band_in, pixels, 0, 1,
                 fe->bufwide + (size_t)fe->dpw * width * wide, fe->swoosh_l, par);
    fe->fused_done = 0;
    fe->fused_resid = fe_ort_fuse() ? fe->bufu + (size_t)fe->dpw * width : NULL;
    fe->fused_resid_stride = s->h2 * width;
    run_conv_1x1(fe, &fe->conv[4], fe->bufwide + (size_t)fe->dpw * width * wide, pixels, 1, 0,
                 fe->band_out, -1, par);
    fe->fused_resid = NULL;
    if (!fe->fused_done) fe->all_fused = 0;
    fe_copy_planes(fe->band_out, band, 0, fe->bufpw2, s->hout, fe->dpw, band,
                   fe->conv[4].out_channels, width);
    fe->dpw = fe->ddw;
  }
  fe->stage_ms[6] += now_ms() - t;
}

/* Whether this window continues the one in progress: the same length, and every frame seen so far
 * byte-identical. Anything else starts over, so a caller that seeks or resets loses nothing but
 * time. */
static int fe_continues(const ZfFrontEnd *fe, const float *x, int frames, const float *state) {
  return fe->pv > 0 && fe->win_frames == frames &&
         memcmp(x, fe->prog_x, (size_t)fe->pv * ZF_FE_BINS * sizeof(float)) == 0 &&
         memcmp(state, fe->prog_state, (size_t)zf_frontend_state_floats(fe) * sizeof(float)) == 0;
}

int zf_frontend_prefetch(ZfFrontEnd *fe, const float *x, int frames, int valid,
                         const float *state, const ZfParallel *par) {
  if (!fe || frames > fe->max_frames || valid < 0 || valid > frames) return 0;
  /* Only the fp32 path computes a row from its own inputs alone: the int8 path quantises each
   * convolution's input with one scale over the whole tensor, so a band would change its bits. */
  for (int i = 0; i < ZF_FE_CONVS; ++i)
    if (!fe_conv_is_f32(i) || !fe->conv_w32[i]) return 1;
  const Shapes s = plan_shapes(fe, frames);
  if (!fe_continues(fe, x, frames, state)) fe_begin_window(fe, x, frames, valid, state, &s);
  if (valid <= fe->pv) return 1;
  fe_advance(fe, x, valid, &s, par);
  memcpy(fe->prog_x + (size_t)fe->pv * ZF_FE_BINS, x + (size_t)fe->pv * ZF_FE_BINS,
         (size_t)(valid - fe->pv) * ZF_FE_BINS * sizeof(float));
  fe->pv = valid;
  return 1;
}

int zf_frontend_run(ZfFrontEnd *fe, const float *x, int frames, float *state, float *out,
                    const ZfParallel *par) {
  if (!fe || frames > fe->max_frames) return 0;
  const Shapes s = plan_shapes(fe, frames);
  FILE *dump = fe_dump_open();
  const int channels = fe->conv[2].out_channels;
  const int width = s.w2;
  if (!fe_continues(fe, x, frames, state)) fe_begin_window(fe, x, frames, frames, state, &s);
  fe_advance(fe, x, frames, &s, par);
  fe->pv = 0; /* this window is consumed; the next call starts a new one */
  int reusable = 1;
  for (int i = 0; i < 3; ++i)
    if (!fe_conv_is_f32(i) || !fe->conv_w32[i] || fe->conv[i].pad_top || fe->conv[i].pad_bottom)
      reusable = 0;
  if (dump) {
    char nm[96];
    snprintf(nm, sizeof nm, "buf0 pm h=%d w=%d c=%d", s.h0, s.w0, fe->conv[0].out_channels);
    fe_dump(dump, nm, fe->buf0, (size_t)s.h0 * s.w0 * fe->conv[0].out_channels);
    snprintf(nm, sizeof nm, "buf1 pm h=%d w=%d c=%d", s.h1, s.w1, fe->conv[1].out_channels);
    fe_dump(dump, nm, fe->buf1, (size_t)s.h1 * s.w1 * fe->conv[1].out_channels);
    snprintf(nm, sizeof nm, "bufu nchw h=%d w=%d c=%d", s.h2, width, channels);
    fe_dump(dump, nm, fe->bufu, (size_t)s.h2 * width * channels);
    snprintf(nm, sizeof nm, "bufdw nchw h=%d w=%d c=%d", s.hout, width, fe->dw_channels);
    fe_dump(dump, nm, fe->bufdw, (size_t)s.hout * width * fe->dw_channels);
    snprintf(nm, sizeof nm, "bufpw2 nchw h=%d w=%d c=%d", s.hout, width, fe->conv[4].out_channels);
    fe_dump(dump, nm, fe->bufpw2, (size_t)s.hout * width * fe->conv[4].out_channels);
  }
  /* the next chunk keeps the rows this one's last output consumed */
  for (int c = 0; c < channels; ++c)
    memcpy(state + (size_t)c * 3 * width,
           fe->bufcat + (size_t)c * (s.h2 + 3) * width + (size_t)s.hout * width,
           (size_t)3 * width * sizeof(float));
  fe->fused_done = fe->all_fused;
  double t = now_ms();

  /* The residual is the FIRST hout rows of the convolution output, not the last: the depthwise
   * convolution sees three cached rows in front, so its output row i is centred on new row i.
   *
   * This and the transpose below were the front end's two remaining passes on the calling thread,
   * together about 58 thousand values each. Both are per channel and independent, so both split. */
  if (fe->out_linear.k_pad != fe->out_linear.k) return 0; /* the flat row would need padding */
  {
    const int64_t dims[3] = {channels, s.hout, width};
    const int64_t perm[3] = {1, 0, 2};
    TailPass pass;
    pass.fe = fe;
    pass.channels = channels;
    pass.rows = s.hout;
    pass.width = width;
    pass.h2 = s.h2;
    const int want = (par && par->run && par->threads > 1) ? par->threads : 1;
    if (!zf_gather_transpose(&pass.gather, 3, dims, perm, (int)sizeof(float))) return 0;

    if (!fe->fused_done) {
      pass.phase = 0;
      pass.tasks = want > channels ? channels : want;
      if (pass.tasks > 1) par->run(par->ctx, tail_pass_slice, (size_t)pass.tasks, &pass);
      else tail_pass_slice(&pass, 0);
    }

    pass.phase = 1;
    pass.tasks = (int)(want > pass.gather.outer ? pass.gather.outer : want);
    if (pass.tasks > 1) par->run(par->ctx, tail_pass_slice, (size_t)pass.tasks, &pass);
    else tail_pass_slice(&pass, 0);
  }

  float a_scale = 0.0f;
  int a_zp = 0;
  zf_dynamic_quantize_rows(fe->flat, s.hout, fe->out_linear.k, fe->out_linear.k_pad, fe->flat_q,
                           &a_scale, &a_zp);
  for (int j = 0; j < fe->out_scale_count; ++j) fe->scales[j] = a_scale * fe->out_scale[j];
  {
    int tasks = (par && par->run && par->threads > 1) ? par->threads : 1;
    if (tasks > fe->out_linear.n_blocks) tasks = fe->out_linear.n_blocks;
    OutTask t = {fe, s.hout, a_zp, a_scale, tasks};
    if (tasks > 1)
      par->run(par->ctx, out_slice, (size_t)tasks, &t);
    else
      out_slice(&t, 0);
  }
  zf_bias_norm(fe->out_f32, s.hout, fe->out_linear.n, fe->norm_bias, fe->norm_scale, out);
  fe->stage_ms[7] += now_ms() - t;
  if (reusable) {
    memcpy(fe->prev_x, x, (size_t)frames * ZF_FE_BINS * sizeof(float));
    fe->prev_frames = frames;
  }
  if (dump) {
    char nm[96];
    snprintf(nm, sizeof nm, "out rows=%d c=%d", s.hout, fe->out_linear.n);
    fe_dump(dump, nm, out, (size_t)s.hout * fe->out_linear.n);
    fclose(dump);
  }
  return s.hout;
}
