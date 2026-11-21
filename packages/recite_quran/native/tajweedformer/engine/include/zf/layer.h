/* One Zipformer2 encoder layer, as the deployed graph defines it.
 *
 * The graph spends about 120 nodes and 60 intermediate tensors per layer. This is one call over one
 * scratch arena. The order is the graph's order, which is also the paper's:
 *
 *   attn = self_attn_weights(src)            query, key and position in one linear, then the
 *                                            position term through its own int8 matmul and a fixed
 *                                            gather, the key padding mask, and a softmax
 *   src += feed_forward1(src)                linear, SwooshL, linear
 *   src += nonlin_attention(src, attn[0])    one linear into three parts, tanh, the attention
 *                                            product against the cached values, a gate, linear
 *   src += self_attn1(src, attn)             value projection, the attention product, linear
 *   src += conv_module1(src)                 linear, sigmoid gate, a causal and a chunkwise
 *                                            depthwise convolution combined through a constant,
 *                                            SwooshR, linear
 *   src += feed_forward2(src)
 *   src  = bypass_mid(src_in, src)
 *   src += self_attn2(src, attn)
 *   src += conv_module2(src)
 *   src += feed_forward3(src)
 *   src  = bypass(src_in, norm(src))
 *
 * Six tensors of state carry between chunks: the key cache, the nonlinear attention cache, two
 * value caches and the two convolution caches. They are ring buffers here rather than the graph's
 * concatenate-then-slice, so a chunk copies what it adds instead of the whole window.
 */
#ifndef ZF_LAYER_H
#define ZF_LAYER_H

#include <stddef.h>
#include <stdint.h>

#include "zf/frontend.h" /* for ZfParallel */
#include "zf/kernels.h"
#include "zf/zfw.h"

#ifdef __cplusplus
extern "C" {
#endif

/* A quantised linear as the weight file stores it. */
typedef struct {
  ZfWeightsS8 w;
  const float *scale;
  int scale_count;
  const float *bias;
  int dot; /* the weights are in the dot-product layout and the matmul uses SDOT */
} ZfLinear;

typedef struct ZfLayer ZfLayer;

/* Scratch shared by every layer.
 *
 * The sixteen layers run one after another and none of their scratch survives a call, so one block
 * sized for the widest layer serves them all. Sixteen private arenas were about eight megabytes,
 * and every layer started cold; sharing one keeps the largest part of a layer's working set
 * resident from one layer to the next, which is what the deep stacks need because their weight
 * stream already fills the cache. */
typedef struct ZfArena ZfArena;
ZfArena *zf_arena_create(void);
void zf_arena_destroy(ZfArena *arena);

/* Reads layer `index` out of the weight file. `frames` is the chunk's length in this stack and
 * `left_context` the number of cached frames (256 in this model, before downsampling). */
ZfLayer *zf_layer_create(ZfWeights *w, int index, int frames, int left_context,
                         const char **error);

/* The same, with the scratch taken from `shared`. The arena grows to the largest layer bound to
 * it, and every layer rebinds its pointers when it sees the block move, so layers may be created
 * in any order. The caller keeps the arena alive for as long as the layers. */
ZfLayer *zf_layer_create_in(ZfWeights *w, int index, int frames, int left_context,
                            ZfArena *shared, const char **error);
/* The same, with the tensors that depend on the chunk length (the position weight, its scale and
 * gather index, the convolution masks) taken from `frame_w` where it has them: a chunk length's
 * own small file next to the shared weights (tools/zfrechunk.py --overlay). NULL reads them all
 * from `w`. */
ZfLayer *zf_layer_create_over(ZfWeights *w, const ZfWeights *frame_w, int index, int frames,
                              int left_context, ZfArena *shared, const char **error);
void zf_layer_destroy(ZfLayer *layer);

int zf_layer_dim(const ZfLayer *layer);
/* SwooshL subtracts this before its softplus: 4 (v3.1, the default) or 1 (b8). Returns 0, or -1
 * for any other value. */
int zf_layer_set_swoosh_l_offset(ZfLayer *layer, float offset);
int zf_layer_heads(const ZfLayer *layer);

/* src and out are [frames, dim] and may be the same buffer. key_pad is [left_context + frames],
 * nonzero where a key position is padding; frame_pad is [frames], nonzero where a frame is
 * padding.
 *
 * The six caches live in the layer and advance here, so a caller streams chunks by calling this in
 * order and nothing else. The graph passed them in and out as tensors, which meant each of the six
 * was read once, staged into a concatenation buffer, read back and written out again: about eleven
 * megabytes of copying a chunk, more than the layers spent on their own cache maintenance. Holding
 * them means a chunk writes only the rows it adds and shifts the window down once.
 *
 * zf_layer_reset_state starts a new stream. */
int zf_layer_run(ZfLayer *layer, const float *src, int frames, const float *key_pad,
                 const float *frame_pad, float *out, const ZfParallel *par);
void zf_layer_reset_state(ZfLayer *layer);

/* The six caches in the graph's own layout, for handing a stream from one engine to another:
 * `which` 0 key [left, heads*32], 1 nonlinear attention [left, na], 2 and 3 the two value caches
 * [left, heads*12], 4 and 5 the two convolution caches [dim, taps-1]; rows are oldest first, as the
 * graph's cached_key_i, cached_nonlin_attn_i, cached_val1_i, cached_val2_i, cached_conv1_i and
 * cached_conv2_i hold them. zf_layer_cache_shape gives rows and columns; zf_layer_cache_read copies
 * one out and zf_layer_cache_write one in (the window restarts at the front of its buffer first).
 * Each returns 0, or -1 for a bad `which` or size. */
int zf_layer_cache_shape(const ZfLayer *layer, int which, int *rows, int *cols);
int zf_layer_cache_read(const ZfLayer *layer, int which, float *out, size_t floats);
int zf_layer_cache_write(ZfLayer *layer, int which, const float *in, size_t floats);

/* G consecutive chunks at once (src[b], key_pad[b], frame_pad[b] -> out[b]; the pad arrays may be
 * NULL): the same bits as zf_layer_run on each in order, with each linear's weights read once per
 * group instead of once per chunk. */
int zf_layer_run_group(ZfLayer *layer, int G, const float *const *src, int frames,
                       const float *const *key_pad, const float *const *frame_pad,
                       float *const *out, const ZfParallel *par);

/* Where a layer's time goes, in milliseconds, accumulated until reset. */
#define ZF_LAYER_STAGES 22
void zf_layer_stages(const ZfLayer *layer, double *out_ms);
void zf_layer_reset_stages(ZfLayer *layer);

/* Multiply-adds issued by this layer's integer linears, for the rate the stage timers imply. */
double zf_layer_madds(const ZfLayer *layer);

/* Time this process has spent in engine regions that ran on one thread. Measured at 0.35 ms a
 * chunk, which is how it is known that the serial term in the model's scaling curve is the ramp and
 * barrier of about a thousand parallel regions rather than code waiting to be split. */
double zf_serial_ms(void);
const char *zf_layer_stage_name(int index);

#ifdef __cplusplus
}
#endif
#endif /* ZF_LAYER_H */
