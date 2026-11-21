/* Layout moves: gather (which covers slicing and transposing) and concatenation.
 *
 * After the arithmetic went to the engine's kernels, these are what a chunk spends its time on:
 * 324 Slice, 211 Transpose and 102 Concat nodes, about 54 ms of a 241 ms chunk inside ONNX
 * Runtime's generic implementations. Nothing about the work is hard. Every shape in this model is
 * static, so the copy pattern can be worked out once and reduced to a run of memcpy calls, which
 * is what these do; the generic versions rediscover it per element per call.
 */
#ifndef ZF_LAYOUT_H
#define ZF_LAYOUT_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ZF_MAX_RANK 8

/* A gather reads one element of the source for each element of the destination, at a source offset
 * that is an affine function of the destination index. Slicing and transposing are both that. */
typedef struct {
  int rank;
  int element_size;
  int64_t out_dims[ZF_MAX_RANK];
  int64_t src_strides[ZF_MAX_RANK]; /* source element stride per destination axis */
  int64_t src_offset;               /* where destination index zero starts */
  int64_t inner;                    /* destination elements per memcpy, 1 when nothing is contiguous */
  int64_t outer;                    /* number of copies */
  int outer_rank;                   /* axes the odometer walks, the rest being the inner run */
} ZfGather;

/* Slice as ONNX defines it: for each listed axis, start, step and the output length; axes not
 * listed are copied whole. Returns 0 if the request cannot be represented. */
int zf_gather_slice(ZfGather *g, int rank, const int64_t *in_dims, const int64_t *starts,
                    const int64_t *steps, const int64_t *out_dims, int element_size);

/* Transpose: destination axis d reads source axis perm[d]. */
int zf_gather_transpose(ZfGather *g, int rank, const int64_t *in_dims, const int64_t *perm,
                        int element_size);

/* Run a gather over destination copies [begin, end), so it can be split across threads. */
void zf_gather_run(const ZfGather *g, const void *src, void *dst, int64_t begin, int64_t end);

/* Concatenate `count` inputs along `axis`. `dims` is each input's shape, all equal except on the
 * axis. */
void zf_concat_run(int rank, int axis, int count, const int64_t *const *dims,
                   const void *const *srcs, void *dst, int element_size);

#ifdef __cplusplus
}
#endif
#endif /* ZF_LAYOUT_H */
