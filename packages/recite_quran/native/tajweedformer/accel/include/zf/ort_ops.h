/* The engine's kernels, exposed to ONNX Runtime as custom operators.
 *
 * This is the bridge that lets the engine's int8 matmul and fused Swoosh run inside the graph that
 * actually ships, before the engine's own graph executor exists. Two rewrites of the deployed graph
 * (tools/zfgraph.py) collapse the chains ONNX needs many nodes to express:
 *
 *   ZfLinearS8   replaces DynamicQuantizeLinear, MatMulInteger, Cast, Mul and Add: 290 sites
 *   ZfSwoosh     replaces Sub, Mul, Exp, Add, Log, Cast, Equal, Where, Sub, Sub: 84 sites
 *   ZfConvS8     replaces the five dense front-end convolutions, which ship in fp32
 *   ZfConvDW     replaces the 65 depthwise convolutions, still in fp32
 *   ZfSlice, ZfTranspose, ZfConcat  replace the float32 layout moves
 *
 * Both compute what those chains compute. The linear op is bit-exact against them, which
 * bench/engine/op_case proves op by op; Swoosh differs only in floating-point rounding, and it
 * needs no overflow guard because it is computed in the stable form.
 */
#ifndef ZF_ORT_OPS_H
#define ZF_ORT_OPS_H

#include "onnxruntime_c_api.h"

#ifdef __cplusplus
extern "C" {
#endif

/* The domain the rewritten graph declares. */
#define ZF_ORT_DOMAIN "quranlab.zf"

/* Adds the custom op domain to `options`. `threads` sizes the engine's own thread pool, which the
 * kernels use while ONNX Runtime's pool is idle inside a node; 0 leaves it at one thread. Returns
 * NULL on success, or an OrtStatus the caller owns. */
OrtStatus *zf_ort_register(const OrtApi *api, OrtSessionOptions *options, int threads);

/* Sessions. Everything the ops' kernels hold (the thread pool, the layers' weights and scratch,
 * the front end) belongs to the session zf_ort_register_session makes; each session registers its
 * own copies of the ops, so several streams in one process share nothing mutable and may run at
 * once on different threads. zf_ort_register is the same, remembering the session as the default
 * the older calls below act on. Destroy a session after releasing the ORT session that used it. */
typedef struct ZfSession ZfSession;
OrtStatus *zf_ort_register_session(const OrtApi *api, OrtSessionOptions *options, int threads,
                                   ZfSession **out);
/* The same with the pool's pinning chosen (zf_pool_create_pinned): 1 pins, 0 does not. */
OrtStatus *zf_ort_register_session_pinned(const OrtApi *api, OrtSessionOptions *options, int threads,
                                          int pin, ZfSession **out);
void zf_ort_session_destroy(ZfSession *zs);
/* before the ORT session is created; the default is what zf_ort_set_weights_dir last set */
void zf_ort_session_set_weights_dir(ZfSession *zs, const char *dir);
void zf_ort_session_reset(ZfSession *zs);
int zf_ort_session_prefetch(ZfSession *zs, const float *x, int frames, int valid);
/* The session's layer with this index in the model, or NULL; and how many layers it has. */
struct ZfLayer *zf_ort_session_layer(ZfSession *zs, int index);
int zf_ort_session_layer_count(const ZfSession *zs);
/* The engine threads taking part in a region now (zf_pool_team), 1 without a pool. */
int zf_ort_session_team(const ZfSession *zs);
int zf_ort_session_left_context(const ZfSession *zs);
const char *zf_ort_session_weights_file(const ZfSession *zs, char *buf, size_t size);
/* The front end's own copy of its cache (the prefetch runs against it), for an imported state. */
int zf_ort_session_set_frontend_state(ZfSession *zs, const float *state, size_t floats);

/* Releases the shared pool. Call after the session is released. */
void zf_ort_shutdown(void);

/* How far back attention may look, in frames at the model's full frame rate, chosen before the
 * session is created.
 *
 * This is an inference-time choice and nothing else: the same weights, the same graph, the same
 * chunk. The engine owns the key and value caches now, so the left context is simply how many
 * cached rows each layer's attention sweeps, and each stack takes its share of this number scaled
 * by its own downsampling. It costs attention work and cache memory in proportion, so halving it
 * halves both.
 *
 * The exported graph's value is the default, and it is also the value the model was trained with,
 * which is the one that decodes best. Asking for less is a real trade rather than a free win: the
 * attention sees a shorter history than it was trained on, and the phonemes change. Asking for more
 * than the graph declares is refused, because the weights were never trained that way and the
 * positional term the graph carries does not reach further.
 *
 * `frames` of 0 restores the default. The environment variable ZF_LEFT does the same thing for
 * command line tools, and an explicit call wins over it. Call before CreateSession; afterwards it
 * has no effect until the next session. */
void zf_ort_set_left_context(int frames);

/* What the last session actually used, in full-rate frames: the default until a graph has been
 * read, then the value the layers were built with. */
int zf_ort_left_context(void);

/* Accumulated time in each custom op, for attributing a chunk without ONNX Runtime's profiler. */
typedef struct {
  /* Time inside a split region, sampled per op, so `layer_ms - layer_region_ms` is the serial part
   * of a layer: code on the calling thread while the other cores spin. That is the costliest shape
   * of time on four cores, because a millisecond of it wastes three more in idle. */
  double layer_region_ms;
  double frontend_region_ms;
  double linear_ms;
  double quant_ms;   /* dynamic quantisation of the activations */
  double gemm_ms;    /* the integer matmul, including its parallel dispatch */
  double deq_ms;     /* scaling the int32 result back to float */
  double swoosh_ms;
  double conv_ms;
  double conv_prep_ms;
  double conv_gemm_ms;
  unsigned long conv_calls;
  double conv_madds;
  double layer_ms;
  unsigned long layer_calls;
  double layer_stage_ms[22];
  double layer_madds;
  double layer_prologue_ms;
  double frontend_ms;
  unsigned long frontend_calls;
  double matmul_ms;
  unsigned long matmul_calls;
  double matmul_madds;
  double block_ms;
  unsigned long block_calls;
  double layout_ms;
  unsigned long layout_calls;
  double dw_ms;
  double dw_kernel_ms;
  unsigned long dw_calls;
  unsigned long linear_calls;
  unsigned long swoosh_calls;
  double linear_madds;
} ZfOrtStats;

/* Start a new stream: every encoder layer's caches go back to zero. The layers hold their own
 * state now, so a caller that has run a warmup pass has to say when the real stream begins. */
void zf_ort_reset_state(void);

/* The directory relative weight paths in the graph are resolved against (default: the working
 * directory). Call before creating the session. */
void zf_ort_set_weights_dir(const char *dir);

/* Run the next chunk's front end over the first `valid` of its `frames` input frames, before the
 * window is complete; the graph's own front end then finishes it. Bit-identical to not calling it.
 * Returns 0 when there is no session. */
int zf_ort_frontend_prefetch(const float *x, int frames, int valid);

void zf_ort_stats(ZfOrtStats *out);
void zf_ort_stats_reset(void);

#ifdef __cplusplus
}
#endif
#endif /* ZF_ORT_OPS_H */
