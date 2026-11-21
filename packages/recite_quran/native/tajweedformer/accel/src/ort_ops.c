#include "zf/ort_ops.h"
#include "zf/env.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "zf/block.h"
#include "zf/conv.h"
#include "zf/frontend.h"
#include "zf/layer.h"
#include "zf/layout.h"
#include "zf/kernels.h"
#include "zf/pool.h"

static pthread_mutex_t g_config_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_once_t g_config_once = PTHREAD_ONCE_INIT;
static const OrtApi *g_api_first = NULL; /* the API the first registration brought */
static const OrtApi *g_api = NULL;
static int g_trace = 0;
#define TRACE(...) do { if (g_trace) { fprintf(stderr, "[zf] " __VA_ARGS__); fflush(stderr); } } while (0)
/* The ops' kernels (the pool, the layers' weights and scratch, the front end) belong to a session:
 * each zf_ort_register call makes one, and registers its own copies of the ops, each carrying a
 * pointer to it, so two streams in one process share nothing but read-only configuration. */
#define ZF_MAX_LAYERS 64
typedef struct ZfSession {
  ZfPool *pool;
  int own_pool, threads;
  char weights_dir[1024];
  ZfWeights *layer_weights;
  ZfWeights *frame_weights; /* a chunk length's frame-dependent tensors, when its graph names a file */
  ZfArena *layer_arena;
  ZfLayer *layers[ZF_MAX_LAYERS]; /* every layer kernel the session built, so a stream can restart */
  int layer_index[ZF_MAX_LAYERS]; /* each one's index in the model (the graph's `layer` attribute) */
  int layer_count;
  char layer_path[1024];
  int left_request, left_used; /* -1 until read, 0 means the graph's own value */
  void *fe_kernel;             /* the session's FrontEndKernel, for the prefetch */
  struct OpSlot *slots;
  OrtCustomOpDomain *domain;
} ZfSession;

/* An op as registered, with the session its kernels belong to: CreateKernelV2 is handed this op
 * pointer, which is how a kernel finds its session. */
typedef struct OpSlot {
  OrtCustomOp op;
  ZfSession *zs;
} OpSlot;
#define ZF_OPS 14
#define SESSION_OF_OP(op) (((const OpSlot *)(const void *)(op))->zs)
/* every kernel struct starts with its session */
#define SESSION_OF_KERNEL(k) (*(ZfSession *const *)(k))

/* the last session zf_ort_register made, for the calls that predate sessions */
static ZfSession *g_default = NULL;
static int g_layout_nop = 0;
static double g_matmul_parallel_from = 1e30;
/* per thread: each stream runs its ops on its own thread, so its stats stay its own */
static _Thread_local ZfOrtStats g_stats;

/* Stage and op timers are for breakdowns only (nothing decides on them), and a clock read around
 * every convolution and linear is measurable on a fast core: compiled out unless ZF_STAGE_TIMERS,
 * as layer.c's are. */
#ifndef ZF_STAGE_TIMERS
#define ZF_STAGE_TIMERS 0
#endif
static double now_ms(void) {
#if ZF_STAGE_TIMERS
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec * 1e3 + (double)ts.tv_nsec / 1e6;
#else
  return 0.0;
#endif
}

void zf_ort_stats(ZfOrtStats *out) { *out = g_stats; }
void zf_ort_stats_reset(void) { memset(&g_stats, 0, sizeof g_stats); }

/* Scratch that grows to the largest shape a kernel has seen. Shapes here are static, so this
 * allocates on the first chunk and never again. */
typedef struct {
  void *data;
  size_t bytes;
} Scratch;

static void *scratch_need(Scratch *s, size_t bytes) {
  if (bytes > s->bytes) {
    void *p = realloc(s->data, bytes);
    if (!p) return NULL;
    s->data = p;
    s->bytes = bytes;
  }
  return s->data;
}

static void scratch_free(Scratch *s) {
  free(s->data);
  s->data = NULL;
  s->bytes = 0;
}

/* ---------------------------------------------------------------- ZfLinearS8 */

typedef struct {
  ZfSession *zs;
  int64_t n, k;
  int lda, k_pad;
  ZfWeightsS8 weights;
  int weights_ready;
  Scratch act, acc, scales;
} LinearKernel;

static OrtStatus *linear_create(const struct OrtCustomOp *op, const OrtApi *api,
                               const OrtKernelInfo *info, void **out) {
  ZfSession *const zs = SESSION_OF_OP(op);
  (void)op;
  TRACE("linear_create\n");
  LinearKernel *k = (LinearKernel *)calloc(1, sizeof(LinearKernel));
  if (!k) return api->CreateStatus(ORT_FAIL, "ZfLinearS8: out of memory");
  OrtStatus *st = api->KernelInfoGetAttribute_int64(info, "n", &k->n);
  if (!st) st = api->KernelInfoGetAttribute_int64(info, "k", &k->k);
  if (st) { free(k); return st; }
  k->k_pad = (int)((k->k + ZF_S8_K_GROUP - 1) / ZF_S8_K_GROUP * ZF_S8_K_GROUP);
  k->lda = k->k_pad;
  k->zs = zs;
  *out = k;
  return NULL;
}

static void linear_destroy(void *kernel) {
  LinearKernel *k = (LinearKernel *)kernel;
  if (!k) return;
  scratch_free(&k->act);
  scratch_free(&k->acc);
  scratch_free(&k->scales);
  free(k);
}

typedef struct {
  const int8_t *a;
  int m, lda;
  const ZfWeightsS8 *w;
  int a_zero_point;
  int32_t *acc;
  int ldc;
  const float *scale;
  int scale_count;
  const float *bias;
  float *y;
  int tasks;
} LinearPar;

/* One task per thread rather than one per panel: ONNX Runtime's ParallelFor costs enough per
 * invocation that dispatching all 480 panels of a wide layer separately cost more than the
 * arithmetic. Each task also scales its own output units, while they are still in cache. */
static void linear_task(void *user, size_t index) {
  const LinearPar *p = (const LinearPar *)user;
  const int blocks = p->w->n_blocks;
  const int begin = (int)((size_t)blocks * index / (size_t)p->tasks);
  const int end = (int)((size_t)blocks * (index + 1) / (size_t)p->tasks);
  if (begin >= end) return;
  zf_linear_s8_range(p->a, p->m, p->lda, p->w, p->a_zero_point, p->acc, p->ldc, begin, end);
  const int j0 = begin * ZF_S8_UNIT_BLOCK;
  int j1 = end * ZF_S8_UNIT_BLOCK;
  if (j1 > p->w->n) j1 = p->w->n;
  zf_dequantize_range(p->acc, p->m, p->ldc, p->scale, p->scale_count, p->bias, p->y, p->ldc, j0,
                      j1);
}

static OrtStatus *tensor_dims(const OrtApi *api, const OrtValue *v, int64_t *dims, size_t max,
                              size_t *rank) {
  OrtTensorTypeAndShapeInfo *info = NULL;
  OrtStatus *st = api->GetTensorTypeAndShape(v, &info);
  if (st) return st;
  size_t count = 0;
  st = api->GetDimensionsCount(info, &count);
  if (!st && count > max) st = api->CreateStatus(ORT_FAIL, "tensor rank too large");
  if (!st) st = api->GetDimensions(info, dims, count);
  api->ReleaseTensorTypeAndShapeInfo(info);
  *rank = count;
  return st;
}

static OrtStatus *linear_compute(void *kernel, OrtKernelContext *ctx) {
  ZfSession *const zs = SESSION_OF_KERNEL(kernel);
  LinearKernel *kn = (LinearKernel *)kernel;
  const OrtApi *api = g_api;
  const double t0 = now_ms();

  size_t n_inputs = 0;
  TRACE("linear_compute n=%lld k=%lld\n", (long long)kn->n, (long long)kn->k);
  OrtStatus *st = api->KernelContext_GetInputCount(ctx, &n_inputs);
  if (st) return st;

  const OrtValue *x = NULL, *packed = NULL, *row_sums = NULL, *wscale = NULL, *bias = NULL;
  if (!st) st = api->KernelContext_GetInput(ctx, 0, &x);
  if (!st) st = api->KernelContext_GetInput(ctx, 1, &packed);
  if (!st) st = api->KernelContext_GetInput(ctx, 2, &row_sums);
  if (!st) st = api->KernelContext_GetInput(ctx, 3, &wscale);
  if (!st && n_inputs > 4) st = api->KernelContext_GetInput(ctx, 4, &bias);
  if (st) return st;

  int64_t xdims[8];
  size_t xrank = 0;
  st = tensor_dims(api, x, xdims, 8, &xrank);
  if (st) return st;
  if (xrank == 0 || xdims[xrank - 1] != kn->k)
    return api->CreateStatus(ORT_FAIL, "ZfLinearS8: input width does not match attribute k");
  int64_t m = 1;
  for (size_t d = 0; d + 1 < xrank; ++d) m *= xdims[d];

  const float *xdata = NULL;
  const void *pdata = NULL;
  const void *rdata = NULL;
  const float *sdata = NULL;
  const float *bdata = NULL;
  if (!st) st = api->GetTensorData(x, (const void **)&xdata);
  if (!st) st = api->GetTensorData(packed, &pdata);
  if (!st) st = api->GetTensorData(row_sums, &rdata);
  if (!st) st = api->GetTensorData(wscale, (const void **)&sdata);
  if (!st && bias) st = api->GetTensorData(bias, (const void **)&bdata);
  if (st) return st;

  if (!kn->weights_ready) { /* the packed blob is an initializer, so its pointer is stable */
    kn->weights.n = (int)kn->n;
    kn->weights.k = (int)kn->k;
    kn->weights.k_pad = kn->k_pad;
    kn->weights.n_blocks = (int)((kn->n + ZF_S8_UNIT_BLOCK - 1) / ZF_S8_UNIT_BLOCK);
    kn->weights.packed = (const int8_t *)pdata;
    kn->weights.row_sums = (const int32_t *)rdata;
    kn->weights_ready = 1;
  }

  int64_t ydims[8];
  for (size_t d = 0; d + 1 < xrank; ++d) ydims[d] = xdims[d];
  ydims[xrank - 1] = kn->n;
  OrtValue *y = NULL;
  st = api->KernelContext_GetOutput(ctx, 0, ydims, xrank, &y);
  float *ydata = NULL;
  if (!st) st = api->GetTensorMutableData(y, (void **)&ydata);
  if (st) return st;

  int8_t *act = (int8_t *)scratch_need(&kn->act, (size_t)m * kn->lda);
  int32_t *acc = (int32_t *)scratch_need(&kn->acc, (size_t)m * kn->n * sizeof(int32_t));
  if (!act || !acc) return api->CreateStatus(ORT_FAIL, "ZfLinearS8: out of memory");

  size_t scale_rank = 0;
  int64_t scale_dims[4];
  st = tensor_dims(api, wscale, scale_dims, 4, &scale_rank);
  if (st) return st;
  int64_t scale_count = 1;
  for (size_t d = 0; d < scale_rank; ++d) scale_count *= scale_dims[d];

  float a_scale = 0.0f;
  int a_zp = 0;
  const double t_quant = now_ms();
  zf_dynamic_quantize_rows(xdata, (int)m, (int)kn->k, kn->lda, act, &a_scale, &a_zp);
  g_stats.quant_ms += now_ms() - t_quant;

  float *combined = (float *)scratch_need(&kn->scales, (size_t)scale_count * sizeof(float));
  if (!combined) return api->CreateStatus(ORT_FAIL, "ZfLinearS8: out of memory");
  for (int64_t j = 0; j < scale_count; ++j) combined[j] = a_scale * sdata[j];

  const double t_gemm = now_ms();
  if (zs->own_pool) {
    zf_linear_s8_pool(zs->pool, act, (int)m, kn->lda, &kn->weights, a_zp, acc, (int)kn->n);
    const double t_deq = now_ms();
    g_stats.gemm_ms += t_deq - t_gemm;
    zf_dequantize(acc, (int)m, (int)kn->n, (int)kn->n, combined, (int)scale_count, bdata, ydata,
                  (int)kn->n);
    g_stats.deq_ms += now_ms() - t_deq;
  } else {
    /* ONNX Runtime's pool, not ours. Its intra-op threads spin while a node runs, so a second
     * pool of our own would contend with them for the same four cores: measured at three times
     * slower than this. */
    int tasks = zs->threads > 0 ? zs->threads : 1;
    if (tasks > kn->weights.n_blocks) tasks = kn->weights.n_blocks;
    LinearPar par = {act,      (int)m,           kn->lda, &kn->weights, a_zp, acc, (int)kn->n,
                     combined, (int)scale_count, bdata,   ydata,        tasks};
    if (tasks > 1) {
      st = api->KernelContext_ParallelFor(ctx, linear_task, (size_t)tasks, (size_t)tasks, &par);
      if (st) return st;
    } else {
      linear_task(&par, 0);
    }
    g_stats.gemm_ms += now_ms() - t_gemm;
  }

  g_stats.linear_ms += now_ms() - t0;
  g_stats.linear_calls += 1;
  g_stats.linear_madds += (double)m * (double)kn->k * (double)kn->n;
  return NULL;
}

static OrtStatus *linear_infer_shape(const struct OrtCustomOp *op, OrtShapeInferContext *ctx) {
  (void)op;
  const OrtApi *api = g_api;
  OrtTensorTypeAndShapeInfo *in = NULL;
  TRACE("linear_infer_shape\n");
  OrtStatus *st = api->ShapeInferContext_GetInputTypeShape(ctx, 0, &in);
  if (st) return st;
  size_t rank = 0;
  int64_t dims[8];
  st = api->GetDimensionsCount(in, &rank);
  if (!st && rank > 8) st = api->CreateStatus(ORT_FAIL, "ZfLinearS8: rank too large");
  if (!st) st = api->GetDimensions(in, dims, rank);
  api->ReleaseTensorTypeAndShapeInfo(in);
  if (st) return st;

  /* An input whose shape ONNX Runtime has not inferred arrives with rank 0. Say nothing about the
   * output rather than indexing a rank-0 shape, and let it infer what it can elsewhere. */
  if (rank == 0) {
    TRACE("linear_infer_shape: input rank unknown, output shape left unset\n");
    return NULL;
  }

  const OrtOpAttr *attr = NULL;
  int64_t n = 0;
  size_t used = 0;
  st = api->ShapeInferContext_GetAttribute(ctx, "n", &attr);
  if (!st) st = api->ReadOpAttr(attr, ORT_OP_ATTR_INT, &n, sizeof n, &used);
  if (st) return st;
  dims[rank - 1] = n;

  OrtTensorTypeAndShapeInfo *out = NULL;
  st = api->CreateTensorTypeAndShapeInfo(&out);
  if (!st) st = api->SetTensorElementType(out, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT);
  if (!st) st = api->SetDimensions(out, dims, rank);
  if (!st) st = api->ShapeInferContext_SetOutputTypeShape(ctx, 0, out);
  api->ReleaseTensorTypeAndShapeInfo(out);
  return st;
}

/* ------------------------------------------------------------------ ZfConvS8 */

typedef struct {
  ZfSession *zs;
  ZfConvS8 conv;
  int weights_ready;
  Scratch qin, rows, acc;
} ConvKernel;

typedef struct {
  const ConvKernel *kn;
  const int8_t *rows;
  int m, pixels;
  int a_zero_point;
  float a_scale;
  int32_t *acc;
  float *y;
  int tasks;
} ConvPar;

static void conv_task(void *user, size_t index) {
  const ConvPar *p = (const ConvPar *)user;
  const ZfConvS8 *c = &p->kn->conv;
  const int blocks = c->weights.n_blocks;
  const int begin = (int)((size_t)blocks * index / (size_t)p->tasks);
  const int end = (int)((size_t)blocks * (index + 1) / (size_t)p->tasks);
  if (begin >= end) return;
  zf_linear_s8_range(p->rows, p->m, c->weights.k_pad, &c->weights, p->a_zero_point, p->acc,
                     c->out_channels, begin, end);
  const int j0 = begin * ZF_S8_UNIT_BLOCK;
  int j1 = end * ZF_S8_UNIT_BLOCK;
  if (j1 > c->out_channels) j1 = c->out_channels;
  zf_conv_dequantize_channels(c, p->acc, p->pixels, p->a_scale, p->y, j0, j1);
}

static OrtStatus *conv_attr(const OrtApi *api, const OrtKernelInfo *info, const char *name,
                            int *out) {
  int64_t v = 0;
  OrtStatus *st = api->KernelInfoGetAttribute_int64(info, name, &v);
  if (st) return st;
  *out = (int)v;
  return NULL;
}

static OrtStatus *conv_create(const struct OrtCustomOp *op, const OrtApi *api,
                              const OrtKernelInfo *info, void **out) {
  ZfSession *const zs = SESSION_OF_OP(op);
  (void)op;
  TRACE("conv_create\n");
  ConvKernel *k = (ConvKernel *)calloc(1, sizeof(ConvKernel));
  if (!k) return api->CreateStatus(ORT_FAIL, "ZfConvS8: out of memory");
  OrtStatus *st = NULL;
  int n = 0, kk = 0;
  if (!st) st = conv_attr(api, info, "n", &n);
  if (!st) st = conv_attr(api, info, "k", &kk);
  if (!st) st = conv_attr(api, info, "in_channels", &k->conv.in_channels);
  if (!st) st = conv_attr(api, info, "kh", &k->conv.kh);
  if (!st) st = conv_attr(api, info, "kw", &k->conv.kw);
  if (!st) st = conv_attr(api, info, "stride_h", &k->conv.stride_h);
  if (!st) st = conv_attr(api, info, "stride_w", &k->conv.stride_w);
  if (!st) st = conv_attr(api, info, "pad_top", &k->conv.pad_top);
  if (!st) st = conv_attr(api, info, "pad_left", &k->conv.pad_left);
  if (!st) st = conv_attr(api, info, "pad_bottom", &k->conv.pad_bottom);
  if (!st) st = conv_attr(api, info, "pad_right", &k->conv.pad_right);
  if (st) { free(k); return st; }
  k->conv.out_channels = n;
  k->conv.weights.n = n;
  k->conv.weights.k = kk;
  k->conv.weights.k_pad = (kk + ZF_S8_K_GROUP - 1) / ZF_S8_K_GROUP * ZF_S8_K_GROUP;
  k->conv.weights.n_blocks = (n + ZF_S8_UNIT_BLOCK - 1) / ZF_S8_UNIT_BLOCK;
  k->zs = zs;
  *out = k;
  return NULL;
}

static void conv_destroy(void *kernel) {
  ConvKernel *k = (ConvKernel *)kernel;
  if (!k) return;
  scratch_free(&k->qin);
  scratch_free(&k->rows);
  scratch_free(&k->acc);
  free(k);
}

static OrtStatus *conv_compute(void *kernel, OrtKernelContext *ctx) {
  ZfSession *const zs = SESSION_OF_KERNEL(kernel);
  ConvKernel *kn = (ConvKernel *)kernel;
  ZfConvS8 *c = &kn->conv;
  const OrtApi *api = g_api;
  const double t0 = now_ms();

  size_t n_inputs = 0;
  OrtStatus *st = api->KernelContext_GetInputCount(ctx, &n_inputs);
  if (st) return st;
  const OrtValue *x = NULL, *packed = NULL, *row_sums = NULL, *wscale = NULL, *bias = NULL;
  if (!st) st = api->KernelContext_GetInput(ctx, 0, &x);
  if (!st) st = api->KernelContext_GetInput(ctx, 1, &packed);
  if (!st) st = api->KernelContext_GetInput(ctx, 2, &row_sums);
  if (!st) st = api->KernelContext_GetInput(ctx, 3, &wscale);
  if (!st && n_inputs > 4) st = api->KernelContext_GetInput(ctx, 4, &bias);
  if (st) return st;

  int64_t xdims[4];
  size_t xrank = 0;
  st = tensor_dims(api, x, xdims, 4, &xrank);
  if (st) return st;
  if (xrank != 4 || xdims[0] != 1)
    return api->CreateStatus(ORT_FAIL, "ZfConvS8: expects one NCHW input with batch 1");
  const int h = (int)xdims[2], w = (int)xdims[3];
  if ((int)xdims[1] != c->in_channels)
    return api->CreateStatus(ORT_FAIL, "ZfConvS8: input channels do not match the attribute");

  const float *xdata = NULL;
  const void *pdata = NULL, *rdata = NULL;
  const float *sdata = NULL, *bdata = NULL;
  if (!st) st = api->GetTensorData(x, (const void **)&xdata);
  if (!st) st = api->GetTensorData(packed, &pdata);
  if (!st) st = api->GetTensorData(row_sums, &rdata);
  if (!st) st = api->GetTensorData(wscale, (const void **)&sdata);
  if (!st && bias) st = api->GetTensorData(bias, (const void **)&bdata);
  if (st) return st;

  if (!kn->weights_ready) {
    c->weights.packed = (const int8_t *)pdata;
    c->weights.row_sums = (const int32_t *)rdata;
    size_t scale_rank = 0;
    int64_t scale_dims[4];
    st = tensor_dims(api, wscale, scale_dims, 4, &scale_rank);
    if (st) return st;
    int64_t count = 1;
    for (size_t d = 0; d < scale_rank; ++d) count *= scale_dims[d];
    c->scale = sdata;
    c->scale_count = (int)count;
    c->bias = bdata;
    kn->weights_ready = 1;
  }

  const int out_h = zf_conv_out_h(c, h), out_w = zf_conv_out_w(c, w);
  const int pixels = out_h * out_w;
  int64_t ydims[4] = {1, c->out_channels, out_h, out_w};
  OrtValue *y = NULL;
  st = api->KernelContext_GetOutput(ctx, 0, ydims, 4, &y);
  float *ydata = NULL;
  if (!st) st = api->GetTensorMutableData(y, (void **)&ydata);
  if (st) return st;

  const size_t in_count = (size_t)c->in_channels * h * w;
  int8_t *qin = (int8_t *)scratch_need(&kn->qin, in_count);
  int8_t *rows = (int8_t *)scratch_need(&kn->rows, (size_t)pixels * c->weights.k_pad);
  int32_t *acc = (int32_t *)scratch_need(&kn->acc,
                                         (size_t)pixels * c->out_channels * sizeof(int32_t));
  if (!qin || !rows || !acc) return api->CreateStatus(ORT_FAIL, "ZfConvS8: out of memory");

  float a_scale = 0.0f;
  int a_zp = 0;
  const double t_quant = now_ms();
  zf_dynamic_quantize_shifted(xdata, in_count, qin, &a_scale, &a_zp);
  zf_conv_im2col(c, qin, h, w, (int8_t)(a_zp - 128), rows);
  g_stats.conv_prep_ms += now_ms() - t_quant;

  const double t_gemm = now_ms();
  int tasks = zs->threads > 0 ? zs->threads : 1;
  if (tasks > c->weights.n_blocks) tasks = c->weights.n_blocks;
  ConvPar par = {kn, rows, pixels, pixels, a_zp, a_scale, acc, ydata, tasks};
  if (tasks > 1 && !zs->own_pool) {
    st = api->KernelContext_ParallelFor(ctx, conv_task, (size_t)tasks, (size_t)tasks, &par);
    if (st) return st;
  } else {
    par.tasks = 1;
    conv_task(&par, 0);
  }
  g_stats.conv_gemm_ms += now_ms() - t_gemm;

  g_stats.conv_ms += now_ms() - t0;
  g_stats.conv_calls += 1;
  g_stats.conv_madds += (double)pixels * (double)c->weights.k * (double)c->out_channels;
  return NULL;
}

/* ------------------------------------------------------------------ ZfConvDW */

typedef struct {
  ZfSession *zs;
  int channels, kh, kw, stride_h, stride_w, pad_top, pad_left;
  int rank; /* 3 for the encoder's 1D convolution modules, 4 for the front end's 7x7 */
} DwKernel;

typedef struct {
  const DwKernel *kn;
  const float *x;
  const float *w;
  const float *bias;
  float *y;
  int h, w_in, out_h, out_w;
  int tasks;
} DwPar;

static void dw_task(void *user, size_t index) {
  const DwPar *p = (const DwPar *)user;
  const DwKernel *kn = p->kn;
  const int c0 = (int)((size_t)kn->channels * index / (size_t)p->tasks);
  const int c1 = (int)((size_t)kn->channels * (index + 1) / (size_t)p->tasks);
  if (c0 >= c1) return;
  if (kn->rank == 3)
    zf_conv_dw1d_f32(p->x, kn->channels, p->w_in, p->w_in, p->w, kn->kw, kn->stride_w,
                     kn->pad_left, p->bias, p->y, p->out_w, c0, c1);
  else
    zf_conv_dw2d_f32(p->x, kn->channels, p->h, p->w_in, p->w, kn->kh, kn->kw, kn->stride_h,
                     kn->stride_w, kn->pad_top, kn->pad_left, p->bias, p->y, p->out_h, p->out_w,
                     c0, c1);
}

static OrtStatus *dw_create(const struct OrtCustomOp *op, const OrtApi *api,
                            const OrtKernelInfo *info, void **out) {
  ZfSession *const zs = SESSION_OF_OP(op);
  (void)op;
  DwKernel *k = (DwKernel *)calloc(1, sizeof(DwKernel));
  if (!k) return api->CreateStatus(ORT_FAIL, "ZfConvDW: out of memory");
  OrtStatus *st = NULL;
  if (!st) st = conv_attr(api, info, "channels", &k->channels);
  if (!st) st = conv_attr(api, info, "kh", &k->kh);
  if (!st) st = conv_attr(api, info, "kw", &k->kw);
  if (!st) st = conv_attr(api, info, "stride_h", &k->stride_h);
  if (!st) st = conv_attr(api, info, "stride_w", &k->stride_w);
  if (!st) st = conv_attr(api, info, "pad_top", &k->pad_top);
  if (!st) st = conv_attr(api, info, "pad_left", &k->pad_left);
  if (!st) st = conv_attr(api, info, "rank", &k->rank);
  if (st) { free(k); return st; }
  k->zs = zs;
  *out = k;
  return NULL;
}

static void dw_destroy(void *kernel) { free(kernel); }

static OrtStatus *dw_compute(void *kernel, OrtKernelContext *ctx) {
  ZfSession *const zs = SESSION_OF_KERNEL(kernel);
  DwKernel *kn = (DwKernel *)kernel;
  const OrtApi *api = g_api;
  const double t0 = now_ms();

  size_t n_inputs = 0;
  OrtStatus *st = api->KernelContext_GetInputCount(ctx, &n_inputs);
  if (st) return st;
  const OrtValue *x = NULL, *weights = NULL, *bias = NULL;
  if (!st) st = api->KernelContext_GetInput(ctx, 0, &x);
  if (!st) st = api->KernelContext_GetInput(ctx, 1, &weights);
  if (!st && n_inputs > 2) st = api->KernelContext_GetInput(ctx, 2, &bias);
  if (st) return st;

  int64_t xdims[4];
  size_t xrank = 0;
  st = tensor_dims(api, x, xdims, 4, &xrank);
  if (st) return st;
  if ((int)xrank != kn->rank || xdims[0] != 1)
    return api->CreateStatus(ORT_FAIL, "ZfConvDW: unexpected input rank or batch");

  const float *xdata = NULL, *wdata = NULL, *bdata = NULL;
  if (!st) st = api->GetTensorData(x, (const void **)&xdata);
  if (!st) st = api->GetTensorData(weights, (const void **)&wdata);
  if (!st && bias) st = api->GetTensorData(bias, (const void **)&bdata);
  if (st) return st;

  int h = 1, w_in = 0;
  if (kn->rank == 3) {
    w_in = (int)xdims[2];
  } else {
    h = (int)xdims[2];
    w_in = (int)xdims[3];
  }
  const int out_h = (h + 2 * kn->pad_top - kn->kh) / kn->stride_h + 1;
  const int out_w = (w_in + 2 * kn->pad_left - kn->kw) / kn->stride_w + 1;

  int64_t ydims[4];
  OrtValue *y = NULL;
  if (kn->rank == 3) {
    ydims[0] = 1; ydims[1] = kn->channels; ydims[2] = out_w;
    st = api->KernelContext_GetOutput(ctx, 0, ydims, 3, &y);
  } else {
    ydims[0] = 1; ydims[1] = kn->channels; ydims[2] = out_h; ydims[3] = out_w;
    st = api->KernelContext_GetOutput(ctx, 0, ydims, 4, &y);
  }
  float *ydata = NULL;
  if (!st) st = api->GetTensorMutableData(y, (void **)&ydata);
  if (st) return st;

  /* A depthwise convolution module here is about 138 thousand multiply-adds, which one core does
   * in well under a tenth of a millisecond: less than the parallel dispatch costs. Only the front
   * end's 7x7, at 2.5 million, is worth splitting. */
  const double work = (double)kn->channels * kn->kh * kn->kw * out_h * out_w;
  int tasks = (work >= 500000.0 && zs->threads > 0) ? zs->threads : 1;
  if (tasks > kn->channels) tasks = kn->channels;
  DwPar par = {kn, xdata, wdata, bdata, ydata, h, w_in, out_h, out_w, tasks};
  const double t_kernel = now_ms();
  if (tasks > 1 && !zs->own_pool) {
    st = api->KernelContext_ParallelFor(ctx, dw_task, (size_t)tasks, (size_t)tasks, &par);
    if (st) return st;
  } else {
    par.tasks = 1;
    dw_task(&par, 0);
  }
  g_stats.dw_kernel_ms += now_ms() - t_kernel;
  g_stats.dw_ms += now_ms() - t0;
  g_stats.dw_calls += 1;
  return NULL;
}

/* -------------------------------------------------- ZfSlice, ZfTranspose, ZfConcat */

/* Layout moves. Every shape here is static and every Slice in this graph has constant bounds, so
 * the copy pattern is resolved once (in the rewrite for the bounds, on the first call for the
 * shapes) and then each call is a run of memcpy. */
typedef struct {
  ZfSession *zs;
  int64_t attr[3][ZF_MAX_RANK]; /* starts, steps, out_dims for a slice; perm for a transpose */
  int rank;
  int axis; /* concat */
  ZfGather gather;
  int ready;
} LayoutKernel;

static OrtStatus *read_ints(const OrtApi *api, const OrtKernelInfo *info, const char *name,
                            int64_t *out, size_t *count, size_t max) {
  size_t n = max;
  OrtStatus *st = api->KernelInfoGetAttributeArray_int64(info, name, out, &n);
  if (st) return st;
  *count = n;
  return NULL;
}

static OrtStatus *slice_create(const struct OrtCustomOp *op, const OrtApi *api,
                               const OrtKernelInfo *info, void **out) {
  ZfSession *const zs = SESSION_OF_OP(op);
  (void)op;
  LayoutKernel *k = (LayoutKernel *)calloc(1, sizeof(LayoutKernel));
  if (!k) return api->CreateStatus(ORT_FAIL, "ZfSlice: out of memory");
  size_t a = 0, b = 0, c = 0;
  OrtStatus *st = read_ints(api, info, "starts", k->attr[0], &a, ZF_MAX_RANK);
  if (!st) st = read_ints(api, info, "steps", k->attr[1], &b, ZF_MAX_RANK);
  if (!st) st = read_ints(api, info, "out_dims", k->attr[2], &c, ZF_MAX_RANK);
  if (!st && (a != b || b != c)) st = api->CreateStatus(ORT_FAIL, "ZfSlice: attribute lengths differ");
  if (st) { free(k); return st; }
  k->rank = (int)a;
  k->zs = zs;
  *out = k;
  return NULL;
}

static OrtStatus *transpose_create(const struct OrtCustomOp *op, const OrtApi *api,
                                   const OrtKernelInfo *info, void **out) {
  ZfSession *const zs = SESSION_OF_OP(op);
  (void)op;
  LayoutKernel *k = (LayoutKernel *)calloc(1, sizeof(LayoutKernel));
  if (!k) return api->CreateStatus(ORT_FAIL, "ZfTranspose: out of memory");
  size_t a = 0;
  OrtStatus *st = read_ints(api, info, "perm", k->attr[0], &a, ZF_MAX_RANK);
  if (st) { free(k); return st; }
  k->rank = (int)a;
  k->zs = zs;
  *out = k;
  return NULL;
}

static OrtStatus *concat_create(const struct OrtCustomOp *op, const OrtApi *api,
                                const OrtKernelInfo *info, void **out) {
  ZfSession *const zs = SESSION_OF_OP(op);
  (void)op;
  LayoutKernel *k = (LayoutKernel *)calloc(1, sizeof(LayoutKernel));
  if (!k) return api->CreateStatus(ORT_FAIL, "ZfConcat: out of memory");
  int64_t axis = 0;
  OrtStatus *st = api->KernelInfoGetAttribute_int64(info, "axis", &axis);
  if (st) { free(k); return st; }
  k->axis = (int)axis;
  k->zs = zs;
  *out = k;
  return NULL;
}

static void layout_destroy(void *kernel) { free(kernel); }

static OrtStatus *gather_compute(void *kernel, OrtKernelContext *ctx, int transpose) {
  LayoutKernel *kn = (LayoutKernel *)kernel;
  const OrtApi *api = g_api;
  const double t0 = now_ms();

  const OrtValue *x = NULL;
  OrtStatus *st = api->KernelContext_GetInput(ctx, 0, &x);
  if (st) return st;
  int64_t in_dims[ZF_MAX_RANK];
  size_t rank = 0;
  st = tensor_dims(api, x, in_dims, ZF_MAX_RANK, &rank);
  if (st) return st;
  if ((int)rank != kn->rank)
    return api->CreateStatus(ORT_FAIL, "layout op: input rank does not match the attributes");

  if (!kn->ready) {
    const int ok = transpose
        ? zf_gather_transpose(&kn->gather, kn->rank, in_dims, kn->attr[0], (int)sizeof(float))
        : zf_gather_slice(&kn->gather, kn->rank, in_dims, kn->attr[0], kn->attr[1], kn->attr[2],
                          (int)sizeof(float));
    if (!ok) return api->CreateStatus(ORT_FAIL, "layout op: cannot plan this move");
    kn->ready = 1;
  }

  const float *xdata = NULL;
  st = api->GetTensorData(x, (const void **)&xdata);
  OrtValue *y = NULL;
  if (!st) st = api->KernelContext_GetOutput(ctx, 0, kn->gather.out_dims, (size_t)kn->rank, &y);
  float *ydata = NULL;
  if (!st) st = api->GetTensorMutableData(y, (void **)&ydata);
  if (st) return st;

  if (!g_layout_nop) zf_gather_run(&kn->gather, xdata, ydata, 0, kn->gather.outer);
  g_stats.layout_ms += now_ms() - t0;
  g_stats.layout_calls += 1;
  return NULL;
}

static OrtStatus *slice_compute(void *kernel, OrtKernelContext *ctx) {
  return gather_compute(kernel, ctx, 0);
}

static OrtStatus *transpose_compute(void *kernel, OrtKernelContext *ctx) {
  return gather_compute(kernel, ctx, 1);
}

static OrtStatus *concat_compute(void *kernel, OrtKernelContext *ctx) {
  LayoutKernel *kn = (LayoutKernel *)kernel;
  const OrtApi *api = g_api;
  const double t0 = now_ms();

  size_t count = 0;
  OrtStatus *st = api->KernelContext_GetInputCount(ctx, &count);
  if (st) return st;
  if (count == 0 || count > 16)
    return api->CreateStatus(ORT_FAIL, "ZfConcat: unsupported input count");

  int64_t dims[16][ZF_MAX_RANK];
  const int64_t *dim_ptr[16];
  const void *srcs[16];
  size_t rank = 0;
  for (size_t i = 0; i < count; ++i) {
    const OrtValue *v = NULL;
    st = api->KernelContext_GetInput(ctx, i, &v);
    if (st) return st;
    size_t r = 0;
    st = tensor_dims(api, v, dims[i], ZF_MAX_RANK, &r);
    if (st) return st;
    if (i == 0) rank = r;
    else if (r != rank) return api->CreateStatus(ORT_FAIL, "ZfConcat: ranks differ");
    st = api->GetTensorData(v, &srcs[i]);
    if (st) return st;
    dim_ptr[i] = dims[i];
  }
  const int axis = kn->axis < 0 ? kn->axis + (int)rank : kn->axis;
  if (axis < 0 || axis >= (int)rank)
    return api->CreateStatus(ORT_FAIL, "ZfConcat: axis out of range");

  int64_t out_dims[ZF_MAX_RANK];
  for (size_t d = 0; d < rank; ++d) out_dims[d] = dims[0][d];
  out_dims[axis] = 0;
  for (size_t i = 0; i < count; ++i) out_dims[axis] += dims[i][axis];

  OrtValue *y = NULL;
  st = api->KernelContext_GetOutput(ctx, 0, out_dims, rank, &y);
  float *ydata = NULL;
  if (!st) st = api->GetTensorMutableData(y, (void **)&ydata);
  if (st) return st;

  if (!g_layout_nop)
    zf_concat_run((int)rank, axis, (int)count, dim_ptr, srcs, ydata, (int)sizeof(float));
  g_stats.layout_ms += now_ms() - t0;
  g_stats.layout_calls += 1;
  return NULL;
}


/* ------------------------------------------------- ZfBiasNorm and ZfBypass */

typedef struct {
  ZfSession *zs;
  float scale;
} NormKernel;

static OrtStatus *norm_create(const struct OrtCustomOp *op, const OrtApi *api,
                              const OrtKernelInfo *info, void **out) {
  ZfSession *const zs = SESSION_OF_OP(op);
  (void)op;
  NormKernel *k = (NormKernel *)calloc(1, sizeof(NormKernel));
  if (!k) return api->CreateStatus(ORT_FAIL, "ZfBiasNorm: out of memory");
  OrtStatus *st = api->KernelInfoGetAttribute_float(info, "scale", &k->scale);
  if (st) { free(k); return st; }
  k->zs = zs;
  *out = k;
  return NULL;
}

static void block_destroy(void *kernel) { free(kernel); }

/* ONNX Runtime calls these without checking for null, so a stateless op still needs both. */
static OrtStatus *stateless_create(const struct OrtCustomOp *op, const OrtApi *api,
                                   const OrtKernelInfo *info, void **out) {
  ZfSession *const zs = SESSION_OF_OP(op);
  (void)op; (void)info;
  ZfSession **p = (ZfSession **)calloc(1, sizeof(ZfSession *));
  if (!p) return api->CreateStatus(ORT_FAIL, "custom op: out of memory");
  *p = zs;
  *out = p;
  return NULL;
}

/* Both blocks take rank-3 [1, rows, channels] tensors, which is the layout the encoder works in. */
static OrtStatus *rows_and_channels(const OrtApi *api, const OrtValue *v, int *rows,
                                    int *channels, int64_t *dims) {
  size_t rank = 0;
  OrtStatus *st = tensor_dims(api, v, dims, ZF_MAX_RANK, &rank);
  if (st) return st;
  if (rank < 2) return api->CreateStatus(ORT_FAIL, "block op: rank too small");
  *channels = (int)dims[rank - 1];
  int64_t r = 1;
  for (size_t d = 0; d + 1 < rank; ++d) r *= dims[d];
  *rows = (int)r;
  return NULL;
}

static OrtStatus *norm_compute(void *kernel, OrtKernelContext *ctx) {
  const NormKernel *kn = (const NormKernel *)kernel;
  const OrtApi *api = g_api;
  const double t0 = now_ms();
  const OrtValue *x = NULL, *bias = NULL;
  OrtStatus *st = api->KernelContext_GetInput(ctx, 0, &x);
  if (!st) st = api->KernelContext_GetInput(ctx, 1, &bias);
  if (st) return st;
  int rows = 0, channels = 0;
  int64_t dims[ZF_MAX_RANK];
  size_t rank = 0;
  st = rows_and_channels(api, x, &rows, &channels, dims);
  if (st) return st;
  st = tensor_dims(api, x, dims, ZF_MAX_RANK, &rank);
  if (st) return st;
  const float *xd = NULL, *bd = NULL;
  if (!st) st = api->GetTensorData(x, (const void **)&xd);
  if (!st) st = api->GetTensorData(bias, (const void **)&bd);
  OrtValue *y = NULL;
  if (!st) st = api->KernelContext_GetOutput(ctx, 0, dims, rank, &y);
  float *yd = NULL;
  if (!st) st = api->GetTensorMutableData(y, (void **)&yd);
  if (st) return st;
  zf_bias_norm(xd, rows, channels, bd, kn->scale, yd);
  g_stats.block_ms += now_ms() - t0;
  g_stats.block_calls += 1;
  return NULL;
}

/* ------------------------------------------------- ZfDownsample and ZfUpsample
 *
 * The frame rate changes eleven times in a chunk, and the graph spelled out each change as three
 * nodes: a reshape splitting the time axis into blocks, a multiply by one weight per position in a
 * block, and a sum over the block; or an unsqueeze, an expand and a reshape to repeat each frame.
 * Thirty-three nodes in all, none of them arithmetic worth naming, and the profiler puts them at
 * about a hundred microseconds each because that is what a node costs regardless of its work: a
 * Reshape, which only renames a view, measured 67 us.
 *
 * Folded into one op apiece they cost a dispatch each instead of three, and their intermediate
 * tensors stop being allocated. The arithmetic is unchanged: the same products summed in the same
 * order as the Mul and ReduceSum performed them, so the result is the same bit pattern. */

/* The frame-rate changes and the stack bypasses run on the calling thread while the other three
 * spin, which is the shape of cost that matters most here: a chunk's serial time is paid four times
 * over in idle cores. There are sixteen of these a chunk for about 1.3 ms, so splitting them by
 * output row is worth about a millisecond of a chunk's wall time.
 *
 * Below a few rows a split costs more than it saves, and the deepest stack hands these ops three
 * rows, so the threshold is checked per call. */
typedef struct {
  int kind; /* 0 downsample, 1 upsample, 2 bypass */
  const float *a, *b, *weight;
  float *y;
  int rows, channels, factor, tasks;
} BlockJob;

static void block_range(void *context, int begin, int end) {
  const BlockJob *j = (const BlockJob *)context;
  const int t0 = (int)((long long)j->rows * begin / j->tasks);
  const int t1 = (int)((long long)j->rows * end / j->tasks);
  if (t0 >= t1) return;
  if (j->kind == 0) {
    zf_downsample_f32(j->a, j->rows, j->factor, j->channels, j->weight, j->y, t0, t1);
  } else if (j->kind == 1) {
    zf_upsample_f32(j->a, j->rows, j->factor, j->channels, j->y, t0, t1);
  } else {
    const size_t off = (size_t)t0 * j->channels;
    zf_bypass(j->a + off, j->b + off, t1 - t0, j->channels, j->weight, j->y + off);
  }
}

static void block_grain(void *user, size_t index) {
  block_range(user, (int)index, (int)index + 1);
}

/* Run `job` over its rows, split if there is enough of it to be worth a dispatch. */
static OrtStatus *run_block_job(ZfSession *zs, OrtKernelContext *ctx, BlockJob *job) {
  const int want = zs->threads > 1 ? zs->threads : 1;
  int tasks = want;
  if (tasks > job->rows) tasks = job->rows;
  /* one row of the widest stack is 512 floats; four rows is the point where a split pays */
  if (job->rows < 4 * tasks) tasks = job->rows / 4;
  if (tasks < 2) {
    job->tasks = 1;
    block_range(job, 0, 1);
    return NULL;
  }
  job->tasks = tasks;
  if (zs->own_pool) {
    zf_pool_run(zs->pool, block_range, job, tasks, 1);
    return NULL;
  }
  return g_api->KernelContext_ParallelFor(ctx, block_grain, (size_t)tasks, 0, job);
}

typedef struct {
  ZfSession *zs;
  int factor;
} ResampleKernel;

static OrtStatus *resample_create(const struct OrtCustomOp *op, const OrtApi *api,
                                  const OrtKernelInfo *info, void **out) {
  ZfSession *const zs = SESSION_OF_OP(op);
  (void)op;
  ResampleKernel *k = (ResampleKernel *)calloc(1, sizeof(ResampleKernel));
  if (!k) return api->CreateStatus(ORT_FAIL, "resample: out of memory");
  int64_t factor = 0;
  OrtStatus *st = api->KernelInfoGetAttribute_int64(info, "factor", &factor);
  if (st) { free(k); return st; }
  if (factor < 1) { free(k); return api->CreateStatus(ORT_FAIL, "resample: factor below one"); }
  k->factor = (int)factor;
  k->zs = zs;
  *out = k;
  return NULL;
}

static OrtStatus *downsample_compute(void *kernel, OrtKernelContext *ctx) {
  ZfSession *const zs = SESSION_OF_KERNEL(kernel);
  const ResampleKernel *kn = (const ResampleKernel *)kernel;
  const OrtApi *api = g_api;
  const double t0 = now_ms();
  const OrtValue *x = NULL, *wv = NULL;
  OrtStatus *st = api->KernelContext_GetInput(ctx, 0, &x);
  if (!st) st = api->KernelContext_GetInput(ctx, 1, &wv);
  if (st) return st;
  int rows = 0, channels = 0;
  int64_t dims[ZF_MAX_RANK];
  size_t rank = 0;
  st = rows_and_channels(api, x, &rows, &channels, dims);
  if (!st) st = tensor_dims(api, x, dims, ZF_MAX_RANK, &rank);
  if (st) return st;
  if (rows % kn->factor != 0)
    return api->CreateStatus(ORT_FAIL, "ZfDownsample: the factor does not divide the frames");
  const float *xd = NULL, *wd = NULL;
  if (!st) st = api->GetTensorData(x, (const void **)&xd);
  if (!st) st = api->GetTensorData(wv, (const void **)&wd);
  if (st) return st;
  const int out_rows = rows / kn->factor;
  /* the time axis is the leading one that carries the frames; the rest of the shape is kept */
  int64_t odims[ZF_MAX_RANK];
  for (size_t d = 0; d < rank; ++d) odims[d] = dims[d];
  odims[0] = out_rows;
  OrtValue *y = NULL;
  st = api->KernelContext_GetOutput(ctx, 0, odims, rank, &y);
  float *yd = NULL;
  if (!st) st = api->GetTensorMutableData(y, (void **)&yd);
  if (st) return st;
  {
    BlockJob job = {0, xd, NULL, wd, yd, out_rows, channels, kn->factor, 1};
    st = run_block_job(zs, ctx, &job);
    if (st) return st;
  }
  g_stats.block_ms += now_ms() - t0;
  g_stats.block_calls += 1;
  return NULL;
}

static OrtStatus *upsample_compute(void *kernel, OrtKernelContext *ctx) {
  ZfSession *const zs = SESSION_OF_KERNEL(kernel);
  const ResampleKernel *kn = (const ResampleKernel *)kernel;
  const OrtApi *api = g_api;
  const double t0 = now_ms();
  const OrtValue *x = NULL;
  OrtStatus *st = api->KernelContext_GetInput(ctx, 0, &x);
  if (st) return st;
  int rows = 0, channels = 0;
  int64_t dims[ZF_MAX_RANK];
  size_t rank = 0;
  st = rows_and_channels(api, x, &rows, &channels, dims);
  if (!st) st = tensor_dims(api, x, dims, ZF_MAX_RANK, &rank);
  if (st) return st;
  const float *xd = NULL;
  st = api->GetTensorData(x, (const void **)&xd);
  if (st) return st;
  int64_t odims[ZF_MAX_RANK];
  for (size_t d = 0; d < rank; ++d) odims[d] = dims[d];
  odims[0] = (int64_t)rows * kn->factor;
  OrtValue *y = NULL;
  st = api->KernelContext_GetOutput(ctx, 0, odims, rank, &y);
  float *yd = NULL;
  if (!st) st = api->GetTensorMutableData(y, (void **)&yd);
  if (st) return st;
  {
    BlockJob job = {1, xd, NULL, NULL, yd, rows, channels, kn->factor, 1};
    st = run_block_job(zs, ctx, &job);
    if (st) return st;
  }
  g_stats.block_ms += now_ms() - t0;
  g_stats.block_calls += 1;
  return NULL;
}

static OrtStatus *bypass_compute(void *kernel, OrtKernelContext *ctx) {
  ZfSession *const zs = SESSION_OF_KERNEL(kernel);
  (void)kernel;
  const OrtApi *api = g_api;
  const double t0 = now_ms();
  const OrtValue *a = NULL, *b = NULL, *wv = NULL;
  OrtStatus *st = api->KernelContext_GetInput(ctx, 0, &a);
  if (!st) st = api->KernelContext_GetInput(ctx, 1, &b);
  if (!st) st = api->KernelContext_GetInput(ctx, 2, &wv);
  if (st) return st;
  int rows = 0, channels = 0;
  int64_t dims[ZF_MAX_RANK];
  size_t rank = 0;
  st = rows_and_channels(api, a, &rows, &channels, dims);
  if (!st) st = tensor_dims(api, a, dims, ZF_MAX_RANK, &rank);
  if (st) return st;
  const float *ad = NULL, *bd = NULL, *wd = NULL;
  if (!st) st = api->GetTensorData(a, (const void **)&ad);
  if (!st) st = api->GetTensorData(b, (const void **)&bd);
  if (!st) st = api->GetTensorData(wv, (const void **)&wd);
  OrtValue *y = NULL;
  if (!st) st = api->KernelContext_GetOutput(ctx, 0, dims, rank, &y);
  float *yd = NULL;
  if (!st) st = api->GetTensorMutableData(y, (void **)&yd);
  if (st) return st;
  {
    BlockJob job = {2, ad, bd, wd, yd, rows, channels, 1, 1};
    st = run_block_job(zs, ctx, &job);
    if (st) return st;
  }
  g_stats.block_ms += now_ms() - t0;
  g_stats.block_calls += 1;
  return NULL;
}


/* --------------------------------------------------------------- ZfMatMulF32 */

/* The attention products, 9.4M multiply-adds a chunk over batched rank-4 operands. Both operands
 * are activations, so the int8 kernel cannot take these. */
typedef struct {
  const float *a;
  const float *b;
  float *y;
  int batch, m, k, n;
  int tasks;
} MatMulPar;

static void matmul_task(void *user, size_t index) {
  const MatMulPar *p = (const MatMulPar *)user;
  const int begin = (int)((size_t)p->m * index / (size_t)p->tasks);
  const int end = (int)((size_t)p->m * (index + 1) / (size_t)p->tasks);
  if (begin >= end) return;
  zf_matmul_f32(p->a, p->b, p->batch, p->m, p->k, p->n, p->y, begin, end);
}

static OrtStatus *matmul_compute(void *kernel, OrtKernelContext *ctx) {
  ZfSession *const zs = SESSION_OF_KERNEL(kernel);
  (void)kernel;
  const OrtApi *api = g_api;
  const double t0 = now_ms();
  const OrtValue *av = NULL, *bv = NULL;
  OrtStatus *st = api->KernelContext_GetInput(ctx, 0, &av);
  if (!st) st = api->KernelContext_GetInput(ctx, 1, &bv);
  if (st) return st;
  int64_t adims[ZF_MAX_RANK], bdims[ZF_MAX_RANK];
  size_t arank = 0, brank = 0;
  st = tensor_dims(api, av, adims, ZF_MAX_RANK, &arank);
  if (!st) st = tensor_dims(api, bv, bdims, ZF_MAX_RANK, &brank);
  if (st) return st;
  if (arank < 2 || arank != brank)
    return api->CreateStatus(ORT_FAIL, "ZfMatMulF32: ranks must match and be at least 2");
  int64_t batch = 1;
  for (size_t d = 0; d + 2 < arank; ++d) {
    if (adims[d] != bdims[d])
      return api->CreateStatus(ORT_FAIL, "ZfMatMulF32: batch dimensions differ");
    batch *= adims[d];
  }
  const int m = (int)adims[arank - 2], k = (int)adims[arank - 1];
  const int n = (int)bdims[brank - 1];
  if (k != (int)bdims[brank - 2])
    return api->CreateStatus(ORT_FAIL, "ZfMatMulF32: inner dimensions differ");

  int64_t ydims[ZF_MAX_RANK];
  for (size_t d = 0; d + 2 < arank; ++d) ydims[d] = adims[d];
  ydims[arank - 2] = m;
  ydims[arank - 1] = n;

  const float *ad = NULL, *bd = NULL;
  if (!st) st = api->GetTensorData(av, (const void **)&ad);
  if (!st) st = api->GetTensorData(bv, (const void **)&bd);
  OrtValue *y = NULL;
  if (!st) st = api->KernelContext_GetOutput(ctx, 0, ydims, arank, &y);
  float *yd = NULL;
  if (!st) st = api->GetTensorMutableData(y, (void **)&yd);
  if (st) return st;

  /* These are small: the largest is under a million multiply-adds, and a parallel
   * dispatch costs more than one core spends on it. Measured serial against four
   * tasks, serial won by a factor of four. */
  const double work = (double)batch * m * k * n;
  int tasks = (work >= g_matmul_parallel_from && zs->threads > 0) ? zs->threads : 1;
  if (tasks > m) tasks = m;
  MatMulPar par = {ad, bd, yd, (int)batch, m, k, n, tasks};
  if (tasks > 1 && !zs->own_pool) {
    st = api->KernelContext_ParallelFor(ctx, matmul_task, (size_t)tasks, (size_t)tasks, &par);
    if (st) return st;
  } else {
    zf_matmul_f32(ad, bd, (int)batch, m, k, n, yd, 0, m);
  }
  g_stats.matmul_ms += now_ms() - t0;
  g_stats.matmul_calls += 1;
  g_stats.matmul_madds += work;
  return NULL;
}

/* --------------------------------------------------------------- ZfFrontEnd */

/* The engine's front end, dropped into the graph in place of the fifty-odd nodes it replaces. The
 * weights come from its own file rather than from graph initializers, because that file is what
 * the engine reads when there is no graph left at all. */
typedef struct {
  ZfSession *zs;
  ZfWeights *weights;
  ZfFrontEnd *fe;
  float *state;
  int state_floats;
} FrontEndKernel;

/* Where a weight file named by a relative path lives. The graph names its .zfw files relative to
 * the directory it was exported into; a harness runs from that directory, but a library cannot
 * depend on the working directory, so a caller that knows where the model is sets this. */
static char g_weights_dir[1024]; /* copied into the next session zf_ort_register makes */

void zf_ort_session_set_weights_dir(ZfSession *zs, const char *dir) {
  if (zs) snprintf(zs->weights_dir, sizeof zs->weights_dir, "%s", dir ? dir : "");
}

void zf_ort_set_weights_dir(const char *dir) {
  snprintf(g_weights_dir, sizeof g_weights_dir, "%s", dir ? dir : "");
}

/* Folder layout 3 (tools/zfshare.py) keeps one layers.zfw and one frontend.zfw for every context and
 * names them from the context's graph as ../layers.zfw. The joined path is folded lexically
 * ("dir/ctx/../layers.zfw" -> "dir/layers.zfw") so it also names a file held in memory (zf/vfs.h,
 * the CoreML sidecar's "zfmem:N/" prefix and the wasm build), where no file system resolves "..".
 * Only a ".." that follows a real component is folded; a leading one is kept as written. */
static void fold_dotdot(char *p) {
  char *seg = strstr(p, "/../");
  while (seg) {
    char *start = seg; /* the component before "/../" begins after the previous '/' */
    while (start > p && start[-1] != '/') --start;
    const size_t len = (size_t)(seg - start);
    if (len == 0 || (len == 2 && start[0] == '.' && start[1] == '.') || (len == 1 && start[0] == '.')) {
      seg = strstr(seg + 3, "/../");
      continue;
    }
    memmove(start, seg + 4, strlen(seg + 4) + 1);
    seg = strstr(p, "/../");
  }
}

static const char *weights_path(const ZfSession *zs, const char *path, char *buf, size_t size) {
  if (!zs->weights_dir[0] || path[0] == '/') return path;
  snprintf(buf, size, "%s/%s", zs->weights_dir, path);
  fold_dotdot(buf);
  return buf;
}

/* ZF_FE_PROFILE=1: the front end's own stage totals on stderr at exit. Diagnostic only. */
static ZfFrontEnd *g_profile_fe = NULL;

static void fe_profile_print(void) {
  if (!g_profile_fe) return;
  double ms[ZF_FE_STAGES];
  zf_frontend_stages(g_profile_fe, ms);
  fprintf(stderr, "frontend stages (ms, summed over calls; task stages are thread time):\n");
  for (int i = 0; i < ZF_FE_STAGES; ++i)
    if (ms[i] > 0.0) fprintf(stderr, "  %-16s %9.2f\n", zf_frontend_stage_name(i), ms[i]);
}

typedef struct {
  void (*fn)(void *user, size_t index);
  void *user;
} PoolBridge;

static void pool_bridge_range(void *context, int begin, int end) {
  const PoolBridge *b = (const PoolBridge *)context;
  for (int i = begin; i < end; ++i) b->fn(b->user, (size_t)i);
}

/* The engine's own pool. Once the engine owns the whole forward pass, ONNX Runtime's threads have
 * nothing else to do, so running the parallel regions on our own pool avoids its per-dispatch cost
 * without contending with anything. ZF_OWN_POOL selects it, with ONNX Runtime set to one thread. */
/* What a parallel region needs to dispatch: ONNX Runtime's kernel context, and the session whose
 * pool runs it. The engine's own pool: once the engine owns the whole forward pass, ONNX Runtime's
 * threads have nothing else to do, so running the parallel regions on our own pool avoids its
 * per-dispatch cost without contending with anything. */
typedef struct {
  OrtKernelContext *kctx;
  ZfSession *zs;
} ForEachCtx;

static void ort_for_each(void *ctx, void (*fn)(void *user, size_t index), size_t count,
                         void *user) {
  const ForEachCtx *c = (const ForEachCtx *)ctx;
  if (c->zs->own_pool && c->zs->pool) {
    PoolBridge bridge = {fn, user};
    zf_pool_set_tag((const void *)fn);
    zf_pool_run(c->zs->pool, pool_bridge_range, &bridge, (int)count, 1);
    return;
  }
  OrtStatus *st = g_api->KernelContext_ParallelFor(c->kctx, fn, count, count, user);
  if (st) { /* fall back to this thread rather than lose the work */
    g_api->ReleaseStatus(st);
    for (size_t i = 0; i < count; ++i) fn(user, i);
  }
}

/* What SwooshL subtracts before its softplus, from the node (tools/zfgraph.py records it for a model
 * where it is not v3.1's 4: b8's is 1). */
static float swoosh_l_offset(const OrtApi *api, const OrtKernelInfo *info) {
  float offset = 4.0f;
  OrtStatus *st = api->KernelInfoGetAttribute_float(info, "swoosh_l_offset", &offset);
  if (st) {
    api->ReleaseStatus(st);
    offset = 4.0f;
  }
  return offset;
}

static OrtStatus *frontend_create(const struct OrtCustomOp *op, const OrtApi *api,
                                  const OrtKernelInfo *info, void **out) {
  ZfSession *const zs = SESSION_OF_OP(op);
  (void)op;
  FrontEndKernel *k = (FrontEndKernel *)calloc(1, sizeof(FrontEndKernel));
  if (!k) return api->CreateStatus(ORT_FAIL, "ZfFrontEnd: out of memory");
  char path[1024];
  size_t len = sizeof path;
  OrtStatus *st = api->KernelInfoGetAttribute_string(info, "weights", path, &len);
  if (st) { free(k); return st; }
  const char *error = NULL;
  char full[2048];
  k->weights = zf_weights_open(weights_path(zs, path, full, sizeof full), &error);
  if (!k->weights) {
    free(k);
    return api->CreateStatus(ORT_FAIL, error ? error : "ZfFrontEnd: cannot read the weight file");
  }
  int64_t frames = 61;
  st = api->KernelInfoGetAttribute_int64(info, "frames", &frames);
  if (st) { api->ReleaseStatus(st); st = NULL; }
  k->fe = zf_frontend_create(k->weights, (int)frames, &error);
  if (!k->fe) {
    zf_weights_close(k->weights);
    free(k);
    return api->CreateStatus(ORT_FAIL, error ? error : "ZfFrontEnd: cannot start");
  }
  if (zf_frontend_set_swoosh_l_offset(k->fe, swoosh_l_offset(api, info)) != 0) {
    zf_frontend_destroy(k->fe);
    zf_weights_close(k->weights);
    free(k);
    return api->CreateStatus(ORT_FAIL, "ZfFrontEnd: a SwooshL offset other than 4 or 1");
  }
  k->state_floats = zf_frontend_state_floats(k->fe);
  k->state = (float *)calloc((size_t)k->state_floats, sizeof(float));
  if (!k->state) {
    zf_frontend_destroy(k->fe);
    zf_weights_close(k->weights);
    free(k);
    return api->CreateStatus(ORT_FAIL, "ZfFrontEnd: out of memory");
  }
  TRACE("frontend_create from %s\n", path);
  zs->fe_kernel = k; /* the session's front end, for the prefetch: one session, one front end */
  k->zs = zs;
  *out = k;
  return NULL;
}

static void frontend_destroy(void *kernel) {
  FrontEndKernel *k = (FrontEndKernel *)kernel;
  if (!k) return;
  if (k->zs && k->zs->fe_kernel == k) k->zs->fe_kernel = NULL;
  free(k->state);
  zf_frontend_destroy(k->fe);
  zf_weights_close(k->weights);
  free(k);
}

/* The front end of the next chunk, as far as its first `valid` frames allow, with the cache the
 * last chunk left: what a stream calls while the window's audio is still arriving. */
int zf_ort_session_prefetch(ZfSession *zs, const float *x, int frames, int valid) {
  FrontEndKernel *k = zs ? (FrontEndKernel *)zs->fe_kernel : NULL;
  if (!k) return 0;
  ForEachCtx fec = {NULL, zs}; /* only the session's own pool: ONNX Runtime has no kernel context here */
  ZfParallel par = {zs->threads > 1 && zs->own_pool ? ort_for_each : NULL, &fec, zs->threads};
  return zf_frontend_prefetch(k->fe, x, frames, valid, k->state, &par);
}

/* A stream taking over another's state: the front end's own copy of its cache, which the prefetch
 * runs against, must be the imported one too. Returns 0, or -1 when the size is not the cache's. */
int zf_ort_session_set_frontend_state(ZfSession *zs, const float *state, size_t floats) {
  FrontEndKernel *k = zs ? (FrontEndKernel *)zs->fe_kernel : NULL;
  if (!k || floats != (size_t)k->state_floats) return -1;
  memcpy(k->state, state, floats * sizeof(float));
  return 0;
}

int zf_ort_frontend_prefetch(const float *x, int frames, int valid) {
  return zf_ort_session_prefetch(g_default, x, frames, valid);
}

static OrtStatus *frontend_compute(void *kernel, OrtKernelContext *ctx) {
  ZfSession *const zs = SESSION_OF_KERNEL(kernel);
  FrontEndKernel *k = (FrontEndKernel *)kernel;
  const OrtApi *api = g_api;
  const double t0 = now_ms();
  const double region0 = zf_pool_region_ms();

  const OrtValue *x = NULL, *state_in = NULL;
  OrtStatus *st = api->KernelContext_GetInput(ctx, 0, &x);
  if (!st) st = api->KernelContext_GetInput(ctx, 1, &state_in);
  if (st) return st;
  int64_t xdims[ZF_MAX_RANK], sdims[ZF_MAX_RANK];
  size_t xrank = 0, srank = 0;
  st = tensor_dims(api, x, xdims, ZF_MAX_RANK, &xrank);
  if (!st) st = tensor_dims(api, state_in, sdims, ZF_MAX_RANK, &srank);
  if (st) return st;
  const int frames = (int)xdims[xrank - 2];
  const float *xd = NULL, *sd = NULL;
  if (!st) st = api->GetTensorData(x, (const void **)&xd);
  if (!st) st = api->GetTensorData(state_in, (const void **)&sd);
  if (st) return st;

  const int out_frames = zf_frontend_out_frames(k->fe, frames);
  const int out_dim = zf_frontend_out_channels(k->fe);
  int64_t ydims[3] = {1, out_frames, out_dim};
  OrtValue *y = NULL, *state_out = NULL;
  st = api->KernelContext_GetOutput(ctx, 0, ydims, 3, &y);
  if (!st) st = api->KernelContext_GetOutput(ctx, 1, sdims, srank, &state_out);
  float *yd = NULL, *so = NULL;
  if (!st) st = api->GetTensorMutableData(y, (void **)&yd);
  if (!st) st = api->GetTensorMutableData(state_out, (void **)&so);
  if (st) return st;

  memcpy(k->state, sd, (size_t)k->state_floats * sizeof(float));
  ForEachCtx fec = {ctx, zs};
  ZfParallel par = {zs->threads > 1 ? ort_for_each : NULL, &fec, zs->threads};
  if (!zf_frontend_run(k->fe, xd, frames, k->state, yd, &par))
    return api->CreateStatus(ORT_FAIL, "ZfFrontEnd: the front end refused this input");
  memcpy(so, k->state, (size_t)k->state_floats * sizeof(float));
  if (!g_profile_fe && zf_getenv("ZF_FE_PROFILE")) {
    g_profile_fe = k->fe;
    atexit(fe_profile_print);
  }

  g_stats.frontend_ms += now_ms() - t0;
  g_stats.frontend_region_ms += zf_pool_region_ms() - region0;
  g_stats.frontend_calls += 1;
  return NULL;
}

/* ------------------------------------------------------------ ZfEncoderLayer */

/* One encoder layer, in place of the roughly 120 nodes the graph spends on it. A session opens the
 * weight file once and its layers share it (sixteen kernels each opening it would hold sixteen
 * copies of 66 MB on a phone with 912 MB), and they share one scratch block: they run in sequence
 * and keep nothing between calls. */

void zf_ort_session_reset(ZfSession *zs) {
  if (!zs) return;
  TRACE("reset state for %d layers\n", zs->layer_count);
  for (int i = 0; i < zs->layer_count; ++i) zf_layer_reset_state(zs->layers[i]);
  /* a new stream starts from a zero cache, which is what the front end should prefetch against */
  FrontEndKernel *fe = (FrontEndKernel *)zs->fe_kernel;
  if (fe) memset(fe->state, 0, (size_t)fe->state_floats * sizeof(float));
}

void zf_ort_reset_state(void) { zf_ort_session_reset(g_default); }

ZfLayer *zf_ort_session_layer(ZfSession *zs, int index) {
  for (int i = 0; zs && i < zs->layer_count; ++i)
    if (zs->layer_index[i] == index) return zs->layers[i];
  return NULL;
}

int zf_ort_session_layer_count(const ZfSession *zs) { return zs ? zs->layer_count : 0; }
int zf_ort_session_team(const ZfSession *zs) { return zs && zs->pool ? zf_pool_team(zs->pool) : 1; }

int zf_ort_session_left_context(const ZfSession *zs) { return zs ? zs->left_used : 0; }

/* The layers' weight file as the session opened it (its directory joined), or "" before any layer. */
const char *zf_ort_session_weights_file(const ZfSession *zs, char *buf, size_t size) {
  if (!zs || !zs->layer_path[0]) return "";
  return weights_path(zs, zs->layer_path, buf, size);
}

/* The full-rate frames one exported left context covers, which is the same for every stack. */
#define ZF_MASK_RANGE 256

/* The left context asked for, in full-rate frames (copied into the next session), and what a
 * session's layers were built with. */
static int g_left_request = -1; /* -1 until set, 0 means the graph's own value */

void zf_ort_set_left_context(int frames) { g_left_request = frames > 0 ? frames : 0; }

int zf_ort_left_context(void) { return g_default ? g_default->left_used : 0; }

static int left_request(ZfSession *zs) {
  if (zs->left_request < 0) {
    const char *v = zf_getenv("ZF_LEFT");
    zs->left_request = v ? atoi(v) : 0;
    if (zs->left_request < 0) zs->left_request = 0;
  }
  return zs->left_request;
}

/* This layer's left context in its own rows, from the graph's value and the request.
 *
 * A caller asks for one number at the full rate, because that is what the left context is: a single
 * `--left-context-frames` at the model's internal 20 ms rate. The six values sherpa prints per
 * stack are that one number viewed at each stack's own rate. So a request converts to rows by this
 * stack's downsampling, rounds up to keep at least what was asked for, and is capped at what the
 * graph carries, since the caches are sized for that.
 *
 * `graph_downsample` comes from the node when the graph carries it. When it does not, fall back to
 * recovering it from the left context itself, which works only because v3.1 was trained with
 * --left-context-frames 256: then graph_left * downsample is ZF_MASK_RANGE at every stack. That
 * assumption is silent and wrong for any model trained with a different left context, which is why
 * the attribute exists; the fallback is here for graphs built before it did. */
static int layer_left(ZfSession *zs, int graph_left, int graph_downsample, int *downsample_out) {
  int d = graph_downsample > 0 ? graph_downsample
                               : (graph_left > 0 ? ZF_MASK_RANGE / graph_left : 1);
  if (d < 1) d = 1;
  if (downsample_out) *downsample_out = d;
  const int want = left_request(zs);
  if (want <= 0) return graph_left;
  int rows = (want + d - 1) / d;
  if (rows < 1) rows = 1;
  if (rows > graph_left) rows = graph_left;
  return rows;
}

typedef struct {
  ZfSession *zs;
  ZfLayer *layer;
  int frames, left, downsample, dim, heads, na_dim, conv_keep;
  float *key_pad;
  float *frame_pad;
  int pad_floats;
  /* zf_ops_defer_begin: the batch's chunks, run together at zf_ops_defer_end */
  int n_pend, cap_pend;
  const float **pend_src;
  float **pend_out;
  float *pend_pad;
  OrtKernelContext *pend_ctx;
} LayerKernel;

static OrtStatus *encoder_layer_create(const struct OrtCustomOp *op, const OrtApi *api,
                                       const OrtKernelInfo *info, void **out) {
  ZfSession *const zs = SESSION_OF_OP(op);
  (void)op;
  LayerKernel *k = (LayerKernel *)calloc(1, sizeof(LayerKernel));
  if (!k) return api->CreateStatus(ORT_FAIL, "ZfEncoderLayer: out of memory");
  char path[1024];
  size_t len = sizeof path;
  int64_t index = 0, frames = 0, left = 0;
  OrtStatus *st = api->KernelInfoGetAttribute_string(info, "weights", path, &len);
  if (!st) st = api->KernelInfoGetAttribute_int64(info, "layer", &index);
  if (!st) st = api->KernelInfoGetAttribute_int64(info, "frames", &frames);
  if (!st) st = api->KernelInfoGetAttribute_int64(info, "left", &left);
  if (st) { free(k); return st; }
  if (!zs->layer_weights) {
    const char *error = NULL;
    char full[2048];
    zs->layer_weights = zf_weights_open(weights_path(zs, path, full, sizeof full), &error);
    if (!zs->layer_weights) {
      free(k);
      return api->CreateStatus(ORT_FAIL, error ? error : "cannot read the layer weights");
    }
    snprintf(zs->layer_path, sizeof zs->layer_path, "%s", path);
  }
  const char *error = NULL;
  if (!zs->layer_arena) zs->layer_arena = zf_arena_create();
  /* Optional: graphs built before zfgraph.py recorded it do not carry one, and layer_left falls
   * back to inferring it. Any error here means absent, which is not fatal. */
  int64_t graph_downsample = 0;
  OrtStatus *opt = api->KernelInfoGetAttribute_int64(info, "downsample", &graph_downsample);
  if (opt) {
    api->ReleaseStatus(opt);
    graph_downsample = 0;
  }
  int downsample = 1;
  const int use_left = layer_left(zs, (int)left, (int)graph_downsample, &downsample);
  zs->left_used = use_left * downsample;
  /* Optional: a graph rebuilt for another chunk length (tools/zfchunk.py) names the file holding
   * the tensors that depend on it, so every length shares the one layer weight file. */
  char fpath[1024];
  size_t flen = sizeof fpath;
  OrtStatus *fst = api->KernelInfoGetAttribute_string(info, "frame_weights", fpath, &flen);
  if (fst) {
    api->ReleaseStatus(fst);
  } else if (!zs->frame_weights) {
    char full[2048];
    zs->frame_weights = zf_weights_open(weights_path(zs, fpath, full, sizeof full), &error);
    if (!zs->frame_weights) {
      free(k);
      return api->CreateStatus(ORT_FAIL, error ? error : "cannot read the chunk length's weights");
    }
  }
  k->layer = zf_layer_create_over(zs->layer_weights, fst ? NULL : zs->frame_weights, (int)index,
                                  (int)frames, use_left, zs->layer_arena, &error);
  if (!k->layer) {
    free(k);
    return api->CreateStatus(ORT_FAIL, error ? error : "cannot start this layer");
  }
  if (zf_layer_set_swoosh_l_offset(k->layer, swoosh_l_offset(api, info)) != 0) {
    zf_layer_destroy(k->layer);
    free(k);
    return api->CreateStatus(ORT_FAIL, "ZfEncoderLayer: a SwooshL offset other than 4 or 1");
  }
  k->frames = (int)frames;
  k->left = use_left;
  k->downsample = downsample;
  k->dim = zf_layer_dim(k->layer);
  k->heads = zf_layer_heads(k->layer);
  k->pad_floats = k->left + k->frames;
  k->key_pad = (float *)calloc((size_t)k->pad_floats, sizeof(float));
  k->frame_pad = (float *)calloc((size_t)k->frames, sizeof(float));
  if (!k->key_pad || !k->frame_pad) {
    zf_layer_destroy(k->layer);
    free(k->key_pad);
    free(k->frame_pad);
    free(k);
    return api->CreateStatus(ORT_FAIL, "ZfEncoderLayer: out of memory");
  }
  if (zs->layer_count < ZF_MAX_LAYERS) {
    zs->layer_index[zs->layer_count] = (int)index;
    zs->layers[zs->layer_count++] = k->layer;
  }
  TRACE("encoder layer %lld ready: frames %lld left %lld\n", (long long)index, (long long)frames,
        (long long)left);
  k->zs = zs;
  *out = k;
  return NULL;
}

static void encoder_layer_destroy(void *kernel) {
  LayerKernel *k = (LayerKernel *)kernel;
  if (!k) return;
  /* out of the session's restart list first, or its next reset writes into a freed layer */
  ZfSession *zs = k->zs;
  for (int i = 0; zs && i < zs->layer_count; ++i)
    if (zs->layers[i] == k->layer) {
      --zs->layer_count;
      zs->layers[i] = zs->layers[zs->layer_count];
      zs->layer_index[i] = zs->layer_index[zs->layer_count];
      break;
    }
  zf_layer_destroy(k->layer);
  free(k->pend_src);
  free(k->pend_out);
  free(k->pend_pad);
  free(k->key_pad);
  free(k->frame_pad);
  free(k);
}

/* The key padding mask, from the one integer it actually depends on.
 *
 * The exported graph builds it with about eighty-five nodes: a comparison against a range, a
 * reverse, a concatenation with this chunk's zeros, then a slice per stack and a cast, unsqueeze
 * and expand per layer to reach the shapes its Where nodes wanted. All of it is
 *
 *   padding at cache position i  <=>  processed + i * downsampling <= ZF_MASK_RANGE - 1
 *
 * and the mask over this chunk's own frames is the concatenated zeros, so it is always empty. Each
 * layer now takes the counter and writes its own row, which is a few hundred bytes, and ONNX
 * Runtime launches and allocates eighty-five fewer nodes a chunk. */

/* A cache row is padding while the frame it would hold predates the stream.
 *
 * Row i of a left context of `left` rows, `downsample` frames apart, holds the frame from
 * (left - i) * downsample frames ago, so it is padding until that many frames have been processed.
 * The graph's own form of this compares against ZF_MASK_RANGE - 1, which is the same thing only
 * because the exported left context times its downsampling is exactly ZF_MASK_RANGE. Writing the
 * general form is what lets the left context be chosen. */
static void fill_key_pad(long long processed, int left, int frames, int downsample, float *out) {
  const long long span = (long long)left * downsample;
  for (int i = 0; i < left + frames; ++i) {
    const long long at = processed + (long long)i * downsample;
    out[i] = (i < left && at <= span - 1) ? 1.0f : 0.0f;
  }
}


static OrtStatus *read_processed(const OrtApi *api, const OrtValue *value, long long *out) {
  OrtTensorTypeAndShapeInfo *info = NULL;
  ONNXTensorElementDataType type = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED;
  OrtStatus *st = api->GetTensorTypeAndShape(value, &info);
  if (!st) st = api->GetTensorElementType(info, &type);
  if (info) api->ReleaseTensorTypeAndShapeInfo(info);
  if (st) return st;
  const void *data = NULL;
  st = api->GetTensorData(value, &data);
  if (st) return st;
  if (type == ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64) *out = *(const int64_t *)data;
  else if (type == ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32) *out = *(const int32_t *)data;
  else return api->CreateStatus(ORT_FAIL, "ZfEncoderLayer: processed_lens is not an integer");
  return NULL;
}

/* chunks a lockstep group (a build can choose: tajweedformer-wasm measures best with 4) */
#ifndef ZF_LANES_DEFAULT
#define ZF_LANES_DEFAULT 8
#endif
/* the layer whose computes a batch is deferring, per thread: each stream runs its batch on its own */
static _Thread_local LayerKernel *g_defer_layer = NULL;

static OrtStatus *encoder_layer_compute(void *kernel, OrtKernelContext *ctx);

/* zf_rt_run_batch's lockstep: between these two calls an encoder layer's computes only record their
 * chunk, and the end runs the chunks through zf_layer_run_group, ZF_LANES (default 8) at a time.
 * The same bits as running them one by one; ZF_LANES=1 does exactly that. */
int zf_ops_defer_begin(const OrtCustomOp *op, void *kernel) {
  static int lanes = -1;
  if (lanes < 0) {
    const char *v = zf_getenv("ZF_LANES");
    lanes = v ? atoi(v) : ZF_LANES_DEFAULT;
  }
  /* each session registers its own copy of the op (OpSlot), so it is known by its compute */
  if (!op || op->KernelComputeV2 != encoder_layer_compute || lanes <= 1 || !kernel) return 0;
  g_defer_layer = (LayerKernel *)kernel;
  g_defer_layer->n_pend = 0;
  return lanes;
}

OrtStatus *zf_ops_defer_end(const OrtCustomOp *op, void *kernel, int lanes) {
  (void)op;
  LayerKernel *k = (LayerKernel *)kernel;
  g_defer_layer = NULL;
  if (!k || !k->n_pend) return NULL;
  ZfSession *const zs = SESSION_OF_KERNEL(kernel);
  ForEachCtx fec = {k->pend_ctx, zs};
  ZfParallel par = {zs->threads > 1 ? ort_for_each : NULL, &fec, zs->threads};
  const float *pads[64];
  if (lanes > 64) lanes = 64;
  for (int i = 0; i < k->n_pend; i += lanes) {
    const int G = k->n_pend - i < lanes ? k->n_pend - i : lanes;
    for (int b = 0; b < G; ++b) pads[b] = k->pend_pad + (size_t)(i + b) * k->pad_floats;
    if (!zf_layer_run_group(k->layer, G, k->pend_src + i, k->frames, pads, NULL, k->pend_out + i, &par))
      return g_api->CreateStatus(ORT_FAIL, "ZfEncoderLayer: the layer refused this input");
  }
  k->n_pend = 0;
  return NULL;
}

static OrtStatus *encoder_layer_compute(void *kernel, OrtKernelContext *ctx) {
  ZfSession *const zs = SESSION_OF_KERNEL(kernel);
  LayerKernel *k = (LayerKernel *)kernel;
  const OrtApi *api = g_api;
  const double t0 = now_ms();
  const double region0 = zf_pool_region_ms();

  const OrtValue *in[2] = {NULL};
  OrtStatus *st = NULL;
  for (int i = 0; i < 2 && !st; ++i) st = api->KernelContext_GetInput(ctx, (size_t)i, &in[i]);
  if (st) return st;

  int64_t dims[ZF_MAX_RANK];
  size_t rank = 0;
  st = tensor_dims(api, in[0], dims, ZF_MAX_RANK, &rank);
  if (st) return st;
  const float *src = NULL;
  st = api->GetTensorData(in[0], (const void **)&src);
  if (st) return st;

  long long processed = 0;
  st = read_processed(api, in[1], &processed);
  if (st) return st;
  if (g_defer_layer == k) {
    /* a batch: keep this chunk for zf_ops_defer_end, which runs them all through the layer at once */
    if (k->n_pend == k->cap_pend) {
      const int cap = k->cap_pend ? 2 * k->cap_pend : 32;
      const float **ps = (const float **)realloc((void *)k->pend_src, (size_t)cap * sizeof *ps);
      if (ps) k->pend_src = ps;
      float **po = (float **)realloc(k->pend_out, (size_t)cap * sizeof *po);
      if (po) k->pend_out = po;
      float *pp = (float *)realloc(k->pend_pad, (size_t)cap * k->pad_floats * sizeof *pp);
      if (pp) k->pend_pad = pp;
      if (!ps || !po || !pp) return api->CreateStatus(ORT_FAIL, "out of memory");
      k->cap_pend = cap;
    }
    fill_key_pad(processed, k->left, k->frames, k->downsample,
                 k->pend_pad + (size_t)k->n_pend * k->pad_floats);
    OrtValue *outv = NULL;
    st = api->KernelContext_GetOutput(ctx, 0, dims, rank, &outv);
    float *out = NULL;
    if (!st) st = api->GetTensorMutableData(outv, (void **)&out);
    if (st) return st;
    k->pend_src[k->n_pend] = src;
    k->pend_out[k->n_pend] = out;
    k->pend_ctx = ctx;
    k->n_pend++;
    return NULL;
  }
  fill_key_pad(processed, k->left, k->frames, k->downsample, k->key_pad);

  OrtValue *outv = NULL;
  st = api->KernelContext_GetOutput(ctx, 0, dims, rank, &outv);
  float *out = NULL;
  if (!st) st = api->GetTensorMutableData(outv, (void **)&out);
  if (st) return st;

  g_stats.layer_prologue_ms += now_ms() - t0;

  ForEachCtx fec = {ctx, zs};
  ZfParallel par = {zs->threads > 1 ? ort_for_each : NULL, &fec, zs->threads};
  zf_layer_reset_stages(k->layer);
  if (!zf_layer_run(k->layer, src, k->frames, k->key_pad, NULL, out, &par))
    return api->CreateStatus(ORT_FAIL, "ZfEncoderLayer: the layer refused this input");
  {
    double stage[ZF_LAYER_STAGES];
    zf_layer_stages(k->layer, stage);
    for (int i = 0; i < ZF_LAYER_STAGES && i < 22; ++i) g_stats.layer_stage_ms[i] += stage[i];
    g_stats.layer_madds += zf_layer_madds(k->layer);
  }

  g_stats.layer_ms += now_ms() - t0;
  g_stats.layer_region_ms += zf_pool_region_ms() - region0;
  g_stats.layer_calls += 1;
  return NULL;
}

/* ------------------------------------------------------------------ ZfSwoosh */

typedef struct {
  ZfSession *zs;
  int64_t variant; /* 0 = SwooshL, 1 = SwooshR */
} SwooshKernel;

typedef struct {
  const float *x;
  float *y;
  int variant;
} SwooshJob;

static void swoosh_range(void *context, int begin, int end) {
  const SwooshJob *job = (const SwooshJob *)context;
  const size_t off = (size_t)begin * 1024, count = (size_t)(end - begin) * 1024;
  if (job->variant)
    zf_swoosh_r(job->x + off, job->y + off, count);
  else
    zf_swoosh_l(job->x + off, job->y + off, count);
}

static void swoosh_grain(void *user, size_t index) {
  const SwooshJob *job = (const SwooshJob *)user;
  swoosh_range((void *)job, (int)index, (int)index + 1);
}

static OrtStatus *swoosh_create(const struct OrtCustomOp *op, const OrtApi *api,
                               const OrtKernelInfo *info, void **out) {
  ZfSession *const zs = SESSION_OF_OP(op);
  (void)op;
  TRACE("swoosh_create\n");
  SwooshKernel *k = (SwooshKernel *)calloc(1, sizeof(SwooshKernel));
  if (!k) return api->CreateStatus(ORT_FAIL, "ZfSwoosh: out of memory");
  OrtStatus *st = api->KernelInfoGetAttribute_int64(info, "variant", &k->variant);
  if (st) { free(k); return st; }
  k->zs = zs;
  *out = k;
  return NULL;
}

static void swoosh_destroy(void *kernel) { free(kernel); }

static OrtStatus *swoosh_compute(void *kernel, OrtKernelContext *ctx) {
  ZfSession *const zs = SESSION_OF_KERNEL(kernel);
  SwooshKernel *kn = (SwooshKernel *)kernel;
  const OrtApi *api = g_api;
  const double t0 = now_ms();

  const OrtValue *x = NULL;
  TRACE("swoosh_compute variant=%lld\n", (long long)kn->variant);
  OrtStatus *st = api->KernelContext_GetInput(ctx, 0, &x);
  if (st) return st;
  int64_t dims[8];
  size_t rank = 0;
  st = tensor_dims(api, x, dims, 8, &rank);
  if (st) return st;
  size_t count = 1;
  for (size_t d = 0; d < rank; ++d) count *= (size_t)dims[d];

  const float *xdata = NULL;
  st = api->GetTensorData(x, (const void **)&xdata);
  OrtValue *y = NULL;
  if (!st) st = api->KernelContext_GetOutput(ctx, 0, dims, rank, &y);
  float *ydata = NULL;
  if (!st) st = api->GetTensorMutableData(y, (void **)&ydata);
  if (st) return st;

  /* Split into 1024-value grains; below one grain the pool costs more than it saves. */
  const int grains = (int)(count / 1024);
  if (grains >= 2) {
    SwooshJob job = {xdata, ydata, (int)kn->variant};
    if (zs->own_pool)
      zf_pool_run(zs->pool, swoosh_range, &job, grains, 1);
    else
      st = api->KernelContext_ParallelFor(ctx, swoosh_grain, (size_t)grains, 0, &job);
    if (st) return st;
    const size_t done = (size_t)grains * 1024;
    if (count > done) {
      if (kn->variant)
        zf_swoosh_r(xdata + done, ydata + done, count - done);
      else
        zf_swoosh_l(xdata + done, ydata + done, count - done);
    }
  } else if (kn->variant) {
    zf_swoosh_r(xdata, ydata, count);
  } else {
    zf_swoosh_l(xdata, ydata, count);
  }

  g_stats.swoosh_ms += now_ms() - t0;
  g_stats.swoosh_calls += 1;
  return NULL;
}

static OrtStatus *swoosh_infer_shape(const struct OrtCustomOp *op, OrtShapeInferContext *ctx) {
  (void)op;
  const OrtApi *api = g_api;
  OrtTensorTypeAndShapeInfo *in = NULL;
  TRACE("swoosh_infer_shape\n");
  OrtStatus *st = api->ShapeInferContext_GetInputTypeShape(ctx, 0, &in);
  if (st) return st;
  st = api->ShapeInferContext_SetOutputTypeShape(ctx, 0, in);
  api->ReleaseTensorTypeAndShapeInfo(in);
  return st;
}

/* ------------------------------------------------------------- registration */

static const char *linear_name(const struct OrtCustomOp *op) { (void)op; return "ZfLinearS8"; }
static const char *swoosh_name(const struct OrtCustomOp *op) { (void)op; return "ZfSwoosh"; }
static const char *conv_name(const struct OrtCustomOp *op) { (void)op; return "ZfConvS8"; }
static const char *dw_name(const struct OrtCustomOp *op) { (void)op; return "ZfConvDW"; }
static const char *slice_name(const struct OrtCustomOp *op) { (void)op; return "ZfSlice"; }
static const char *transpose_name(const struct OrtCustomOp *op) { (void)op; return "ZfTranspose"; }
static const char *concat_name(const struct OrtCustomOp *op) { (void)op; return "ZfConcat"; }
static const char *norm_name(const struct OrtCustomOp *op) { (void)op; return "ZfBiasNorm"; }
static const char *bypass_name(const struct OrtCustomOp *op) { (void)op; return "ZfBypass"; }
static const char *downsample_name(const struct OrtCustomOp *op) {
  (void)op;
  return "ZfDownsample";
}
static const char *upsample_name(const struct OrtCustomOp *op) { (void)op; return "ZfUpsample"; }
static const char *matmul_name(const struct OrtCustomOp *op) { (void)op; return "ZfMatMulF32"; }
static const char *frontend_name(const struct OrtCustomOp *op) {
  (void)op;
  return "ZfFrontEnd";
}
static size_t two_outputs(const struct OrtCustomOp *op) { (void)op; return 2; }
static const char *encoder_layer_name(const struct OrtCustomOp *op) {
  (void)op;
  return "ZfEncoderLayer";
}
static size_t two(const struct OrtCustomOp *op) { (void)op; return 2; }
static OrtCustomOpInputOutputCharacteristic variadic_char(const struct OrtCustomOp *op,
                                                          size_t i) {
  (void)op; (void)i;
  return INPUT_OUTPUT_VARIADIC;
}
static size_t three(const struct OrtCustomOp *op) { (void)op; return 3; }
static OrtCustomOpInputOutputCharacteristic dw_in_char(const struct OrtCustomOp *op,
                                                       size_t i) {
  (void)op;
  return i == 2 ? INPUT_OUTPUT_OPTIONAL : INPUT_OUTPUT_REQUIRED;
}
static const char *provider_cpu(const struct OrtCustomOp *op) { (void)op; return NULL; }

static ONNXTensorElementDataType linear_in_type(const struct OrtCustomOp *op, size_t i) {
  (void)op;
  switch (i) {
    case 1: return ONNX_TENSOR_ELEMENT_DATA_TYPE_INT8;   /* packed weights */
    case 2: return ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32;  /* weight row sums */
    default: return ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT; /* x, weight scale, bias */
  }
}
static size_t linear_in_count(const struct OrtCustomOp *op) { (void)op; return 5; }
static ONNXTensorElementDataType f32_out_type(const struct OrtCustomOp *op, size_t i) {
  (void)op; (void)i;
  return ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT;
}
static size_t one(const struct OrtCustomOp *op) { (void)op; return 1; }
static OrtCustomOpInputOutputCharacteristic linear_in_char(const struct OrtCustomOp *op, size_t i) {
  (void)op;
  return i == 4 ? INPUT_OUTPUT_OPTIONAL : INPUT_OUTPUT_REQUIRED;
}
static OrtCustomOpInputOutputCharacteristic required_char(const struct OrtCustomOp *op, size_t i) {
  (void)op; (void)i;
  return INPUT_OUTPUT_REQUIRED;
}
/* The encoder layer takes the source in float and the processed-frame counter as an integer. */
static ONNXTensorElementDataType layer_in_type(const struct OrtCustomOp *op, size_t i) {
  (void)op;
  return i == 0 ? ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT : ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64;
}

static ONNXTensorElementDataType f32_in_type(const struct OrtCustomOp *op, size_t i) {
  (void)op; (void)i;
  return ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT;
}

/* Declaring the struct's version as the one we compiled against makes ONNX Runtime read every
 * callback that version knows about, including these, and it calls them without checking for null:
 * leaving them out crashes inside session creation. */
static OrtMemType mem_default(const struct OrtCustomOp *op, size_t i) {
  (void)op; (void)i;
  return OrtMemTypeDefault;
}
static int arity_one(const struct OrtCustomOp *op) { (void)op; return 1; }
static int homogeneous(const struct OrtCustomOp *op) { (void)op; return 1; }
static int start_version(const struct OrtCustomOp *op) { (void)op; return 1; }
static int end_version(const struct OrtCustomOp *op) { (void)op; return 2147483647; }

static void fill_common(OrtCustomOp *op) {
  op->GetExecutionProviderType = provider_cpu;
  op->GetInputMemoryType = mem_default;
  op->GetVariadicInputMinArity = arity_one;
  op->GetVariadicInputHomogeneity = homogeneous;
  op->GetVariadicOutputMinArity = arity_one;
  op->GetVariadicOutputHomogeneity = homogeneous;
  op->GetStartVersion = start_version;
  op->GetEndVersion = end_version;
}

static OrtCustomOp g_linear_op;
static OrtCustomOp g_swoosh_op;
static OrtCustomOp g_conv_op;
static OrtCustomOp g_dw_op;
static OrtCustomOp g_slice_op;
static OrtCustomOp g_transpose_op;
static OrtCustomOp g_concat_op;
static OrtCustomOp g_norm_op;
static OrtCustomOp g_bypass_op;
static OrtCustomOp g_downsample_op;
static OrtCustomOp g_upsample_op;
static OrtCustomOp g_matmul_op;
static OrtCustomOp g_frontend_op;
static OrtCustomOp g_layer_op;

/* The op templates every session copies, filled once. */
static void templates_init(void) {
  memset(&g_linear_op, 0, sizeof g_linear_op);
  /* ORT caps the API it hands the kernel to this value, so it must be the version we compiled
   * against: the struct's V2 callbacks are only read above a threshold, and a lower number here
   * makes ORT call the V1 pointers, which are null. */
  g_linear_op.version = ORT_API_VERSION;
  fill_common(&g_linear_op);
  g_linear_op.GetName = linear_name;
  g_linear_op.GetInputType = linear_in_type;
  g_linear_op.GetInputTypeCount = linear_in_count;
  g_linear_op.GetOutputType = f32_out_type;
  g_linear_op.GetOutputTypeCount = one;
  g_linear_op.GetInputCharacteristic = linear_in_char;
  g_linear_op.GetOutputCharacteristic = required_char;
  g_linear_op.CreateKernelV2 = linear_create;
  g_linear_op.KernelComputeV2 = linear_compute;
  g_linear_op.KernelDestroy = linear_destroy;
  if (zf_getenv("ZF_INFER_SHAPE")) g_linear_op.InferOutputShapeFn = linear_infer_shape;

  memset(&g_swoosh_op, 0, sizeof g_swoosh_op);
  g_swoosh_op.version = ORT_API_VERSION;
  fill_common(&g_swoosh_op);
  g_swoosh_op.GetName = swoosh_name;
  g_swoosh_op.GetInputType = f32_in_type;
  g_swoosh_op.GetInputTypeCount = one;
  g_swoosh_op.GetOutputType = f32_out_type;
  g_swoosh_op.GetOutputTypeCount = one;
  g_swoosh_op.GetInputCharacteristic = required_char;
  g_swoosh_op.GetOutputCharacteristic = required_char;
  g_swoosh_op.CreateKernelV2 = swoosh_create;
  g_swoosh_op.KernelComputeV2 = swoosh_compute;
  g_swoosh_op.KernelDestroy = swoosh_destroy;
  if (zf_getenv("ZF_INFER_SHAPE")) g_swoosh_op.InferOutputShapeFn = swoosh_infer_shape;

  TRACE("registering domain %s, custom op version %d\n", ZF_ORT_DOMAIN, ORT_API_VERSION);
  memset(&g_conv_op, 0, sizeof g_conv_op);
  g_conv_op.version = ORT_API_VERSION;
  fill_common(&g_conv_op);
  g_conv_op.GetName = conv_name;
  g_conv_op.GetInputType = linear_in_type; /* x, packed, row sums, scale, bias: the same types */
  g_conv_op.GetInputTypeCount = linear_in_count;
  g_conv_op.GetOutputType = f32_out_type;
  g_conv_op.GetOutputTypeCount = one;
  g_conv_op.GetInputCharacteristic = linear_in_char;
  g_conv_op.GetOutputCharacteristic = required_char;
  g_conv_op.CreateKernelV2 = conv_create;
  g_conv_op.KernelComputeV2 = conv_compute;
  g_conv_op.KernelDestroy = conv_destroy;

  memset(&g_dw_op, 0, sizeof g_dw_op);
  g_dw_op.version = ORT_API_VERSION;
  fill_common(&g_dw_op);
  g_dw_op.GetName = dw_name;
  g_dw_op.GetInputType = f32_in_type;
  g_dw_op.GetInputTypeCount = three;
  g_dw_op.GetOutputType = f32_out_type;
  g_dw_op.GetOutputTypeCount = one;
  g_dw_op.GetInputCharacteristic = dw_in_char;
  g_dw_op.GetOutputCharacteristic = required_char;
  g_dw_op.CreateKernelV2 = dw_create;
  g_dw_op.KernelComputeV2 = dw_compute;
  g_dw_op.KernelDestroy = dw_destroy;

  memset(&g_slice_op, 0, sizeof g_slice_op);
  g_slice_op.version = ORT_API_VERSION;
  fill_common(&g_slice_op);
  g_slice_op.GetName = slice_name;
  g_slice_op.GetInputType = f32_in_type;
  g_slice_op.GetInputTypeCount = one;
  g_slice_op.GetOutputType = f32_out_type;
  g_slice_op.GetOutputTypeCount = one;
  g_slice_op.GetInputCharacteristic = required_char;
  g_slice_op.GetOutputCharacteristic = required_char;
  g_slice_op.CreateKernelV2 = slice_create;
  g_slice_op.KernelComputeV2 = slice_compute;
  g_slice_op.KernelDestroy = layout_destroy;

  memcpy(&g_transpose_op, &g_slice_op, sizeof g_transpose_op);
  g_transpose_op.GetName = transpose_name;
  g_transpose_op.CreateKernelV2 = transpose_create;
  g_transpose_op.KernelComputeV2 = transpose_compute;

  memcpy(&g_concat_op, &g_slice_op, sizeof g_concat_op);
  g_concat_op.GetName = concat_name;
  g_concat_op.GetInputCharacteristic = variadic_char;
  g_concat_op.CreateKernelV2 = concat_create;
  g_concat_op.KernelComputeV2 = concat_compute;

  memcpy(&g_norm_op, &g_slice_op, sizeof g_norm_op);
  g_norm_op.GetName = norm_name;
  g_norm_op.GetInputTypeCount = two;
  g_norm_op.CreateKernelV2 = norm_create;
  g_norm_op.KernelComputeV2 = norm_compute;
  g_norm_op.KernelDestroy = block_destroy;

  memcpy(&g_bypass_op, &g_slice_op, sizeof g_bypass_op);
  g_bypass_op.GetName = bypass_name;
  g_bypass_op.GetInputTypeCount = three;
  g_bypass_op.CreateKernelV2 = stateless_create;
  g_bypass_op.KernelComputeV2 = bypass_compute;
  g_bypass_op.KernelDestroy = block_destroy;

  memcpy(&g_downsample_op, &g_slice_op, sizeof g_downsample_op);
  g_downsample_op.GetName = downsample_name;
  g_downsample_op.GetInputTypeCount = two;
  g_downsample_op.CreateKernelV2 = resample_create;
  g_downsample_op.KernelComputeV2 = downsample_compute;
  g_downsample_op.KernelDestroy = block_destroy;

  memcpy(&g_upsample_op, &g_slice_op, sizeof g_upsample_op);
  g_upsample_op.GetName = upsample_name;
  g_upsample_op.GetInputTypeCount = one;
  g_upsample_op.CreateKernelV2 = resample_create;
  g_upsample_op.KernelComputeV2 = upsample_compute;
  g_upsample_op.KernelDestroy = block_destroy;

  memcpy(&g_matmul_op, &g_slice_op, sizeof g_matmul_op);
  g_matmul_op.GetName = matmul_name;
  g_matmul_op.GetInputTypeCount = two;
  g_matmul_op.CreateKernelV2 = stateless_create;
  g_matmul_op.KernelComputeV2 = matmul_compute;
  g_matmul_op.KernelDestroy = block_destroy;

  memcpy(&g_frontend_op, &g_slice_op, sizeof g_frontend_op);
  g_frontend_op.GetName = frontend_name;
  g_frontend_op.GetInputTypeCount = two;
  g_frontend_op.GetOutputTypeCount = two_outputs;
  g_frontend_op.CreateKernelV2 = frontend_create;
  g_frontend_op.KernelComputeV2 = frontend_compute;
  g_frontend_op.KernelDestroy = frontend_destroy;

  memcpy(&g_layer_op, &g_slice_op, sizeof g_layer_op);
  g_layer_op.GetName = encoder_layer_name;
  g_layer_op.GetInputType = layer_in_type;
  g_layer_op.GetInputTypeCount = two;
  g_layer_op.GetOutputTypeCount = one;
  g_layer_op.CreateKernelV2 = encoder_layer_create;
  g_layer_op.KernelComputeV2 = encoder_layer_compute;
  g_layer_op.KernelDestroy = encoder_layer_destroy;
}

static void config_init(void) {
  pthread_mutex_lock(&g_config_lock);
  g_api = g_api_first;
  pthread_mutex_unlock(&g_config_lock);
  g_trace = zf_getenv("ZF_TRACE") != NULL;
  /* diagnostic only: skip the copy to separate the work from the per-node cost */
  g_layout_nop = zf_getenv("ZF_LAYOUT_NOP") != NULL;
  const char *v = zf_getenv("ZF_MATMUL_PAR");
  if (v) g_matmul_parallel_from = atof(v);
  templates_init();
}

void zf_ort_session_destroy(ZfSession *zs) {
  if (!zs) return;
  if (g_default == zs) g_default = NULL;
  if (zs->layer_arena) zf_arena_destroy(zs->layer_arena);
  if (zs->layer_weights) zf_weights_close(zs->layer_weights);
  if (zs->frame_weights) zf_weights_close(zs->frame_weights);
  if (zs->pool) zf_pool_destroy(zs->pool);
  /* after the ORT session that used it has been released, which is the caller's order */
  if (zs->domain && g_api && g_api->ReleaseCustomOpDomain) g_api->ReleaseCustomOpDomain(zs->domain);
  free(zs->slots);
  free(zs);
}

OrtStatus *zf_ort_register_session(const OrtApi *api, OrtSessionOptions *options, int threads,
                                   ZfSession **out) {
  return zf_ort_register_session_pinned(api, options, threads, 1, out);
}

OrtStatus *zf_ort_register_session_pinned(const OrtApi *api, OrtSessionOptions *options, int threads,
                                          int pin, ZfSession **out) {
  /* process-wide and read-only once set, so set exactly once: two streams may register at once */
  pthread_mutex_lock(&g_config_lock);
  if (!g_api_first) g_api_first = api;
  pthread_mutex_unlock(&g_config_lock);
  pthread_once(&g_config_once, config_init);
  ZfSession *zs = (ZfSession *)calloc(1, sizeof(ZfSession));
  OpSlot *slots = (OpSlot *)calloc(ZF_OPS, sizeof(OpSlot));
  if (!zs || !slots) {
    free(zs);
    free(slots);
    return api->CreateStatus(ORT_FAIL, "zf_ort_register: out of memory");
  }
  zs->slots = slots;
  zs->own_pool = zf_getenv("ZF_ORT_POOL") == NULL;
  /* 0 threads: the fast cores (zf_pool_fast_cores) */
  zs->threads = threads > 0 ? threads : zf_pool_fast_cores();
  zs->left_request = g_left_request;
  snprintf(zs->weights_dir, sizeof zs->weights_dir, "%s", g_weights_dir);
  TRACE("register threads=%d api=%p\n", zs->threads, (const void *)api);
  if (zs->own_pool) {
    zs->pool = zf_pool_create_pinned(zs->threads, 2000, pin);
    if (!zs->pool) {
      zf_ort_session_destroy(zs);
      return api->CreateStatus(ORT_FAIL, "zf_ort_register: cannot create the thread pool");
    }
  }

  /* the session's own copies of the ops: a kernel finds its session through the op it came from */
  const OrtCustomOp *templates[ZF_OPS] = {&g_linear_op, &g_swoosh_op, &g_conv_op, &g_dw_op,
                                          &g_slice_op, &g_transpose_op, &g_concat_op, &g_norm_op,
                                          &g_bypass_op, &g_downsample_op, &g_upsample_op,
                                          &g_matmul_op, &g_frontend_op, &g_layer_op};
  OrtCustomOpDomain *domain = NULL;
  OrtStatus *st = api->CreateCustomOpDomain(ZF_ORT_DOMAIN, &domain);
  for (int i = 0; i < ZF_OPS && !st; ++i) {
    slots[i].op = *templates[i];
    slots[i].zs = zs;
    st = api->CustomOpDomain_Add(domain, &slots[i].op);
  }
  zs->domain = domain;
  if (!st) st = api->AddCustomOpDomain(options, domain);
  if (st) {
    zf_ort_session_destroy(zs);
    return st;
  }
  if (out) *out = zs;
  return NULL;
}

OrtStatus *zf_ort_register(const OrtApi *api, OrtSessionOptions *options, int threads) {
  ZfSession *zs = NULL;
  OrtStatus *st = zf_ort_register_session(api, options, threads, &zs);
  if (!st) g_default = zs;
  return st;
}

void zf_ort_shutdown(void) { zf_ort_session_destroy(g_default); }
