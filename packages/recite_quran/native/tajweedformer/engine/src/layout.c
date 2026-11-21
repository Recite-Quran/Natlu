#include "zf/layout.h"

#include <string.h>

static void finish_plan(ZfGather *g) {
  /* Collapse the trailing axes that are contiguous in both source and destination into one
   * memcpy: that is what makes a transpose of the last two axes cost one copy per row rather than
   * one per element. */
  int64_t inner = 1, expected = 1;
  int axis = g->rank - 1;
  for (; axis >= 0; --axis) {
    if (g->src_strides[axis] != expected) break;
    inner *= g->out_dims[axis];
    expected *= g->out_dims[axis];
  }
  int64_t outer = 1;
  for (int d = 0; d <= axis; ++d) outer *= g->out_dims[d];
  g->inner = inner;
  g->outer = outer;
  g->outer_rank = axis + 1;
}

int zf_gather_slice(ZfGather *g, int rank, const int64_t *in_dims, const int64_t *starts,
                    const int64_t *steps, const int64_t *out_dims, int element_size) {
  if (rank <= 0 || rank > ZF_MAX_RANK) return 0;
  int64_t stride = 1;
  int64_t in_strides[ZF_MAX_RANK];
  for (int d = rank - 1; d >= 0; --d) {
    in_strides[d] = stride;
    stride *= in_dims[d];
  }
  g->rank = rank;
  g->element_size = element_size;
  g->src_offset = 0;
  for (int d = 0; d < rank; ++d) {
    if (out_dims[d] <= 0) return 0;
    g->out_dims[d] = out_dims[d];
    g->src_strides[d] = in_strides[d] * steps[d];
    g->src_offset += starts[d] * in_strides[d];
  }
  finish_plan(g);
  return 1;
}

int zf_gather_transpose(ZfGather *g, int rank, const int64_t *in_dims, const int64_t *perm,
                        int element_size) {
  if (rank <= 0 || rank > ZF_MAX_RANK) return 0;
  int64_t stride = 1;
  int64_t in_strides[ZF_MAX_RANK];
  for (int d = rank - 1; d >= 0; --d) {
    in_strides[d] = stride;
    stride *= in_dims[d];
  }
  g->rank = rank;
  g->element_size = element_size;
  g->src_offset = 0;
  for (int d = 0; d < rank; ++d) {
    const int64_t axis = perm[d];
    if (axis < 0 || axis >= rank) return 0;
    g->out_dims[d] = in_dims[axis];
    g->src_strides[d] = in_strides[axis];
  }
  finish_plan(g);
  return 1;
}

void zf_gather_run(const ZfGather *g, const void *src, void *dst, int64_t begin, int64_t end) {
  const char *in = (const char *)src;
  char *out = (char *)dst;
  const int esz = g->element_size;
  const int64_t inner = g->inner;
  const int outer_rank = g->outer_rank;
  int64_t dims[ZF_MAX_RANK], strides[ZF_MAX_RANK], index[ZF_MAX_RANK];
  for (int d = 0; d < outer_rank; ++d) {
    dims[d] = g->out_dims[d];
    strides[d] = g->src_strides[d];
  }

  /* set the odometer to `begin` */
  int64_t src_index = g->src_offset;
  int64_t rest = begin;
  for (int d = outer_rank - 1; d >= 0; --d) {
    index[d] = rest % dims[d];
    rest /= dims[d];
    src_index += index[d] * strides[d];
  }

  const size_t run = (size_t)inner * esz;
  for (int64_t i = begin; i < end; ++i) {
    memcpy(out + (size_t)i * run, in + (size_t)src_index * esz, run);
    for (int d = outer_rank - 1; d >= 0; --d) {
      src_index += strides[d];
      if (++index[d] < dims[d]) break;
      src_index -= dims[d] * strides[d];
      index[d] = 0;
    }
  }
}

void zf_concat_run(int rank, int axis, int count, const int64_t *const *dims,
                   const void *const *srcs, void *dst, int element_size) {
  int64_t outer = 1, inner = 1;
  for (int d = 0; d < axis; ++d) outer *= dims[0][d];
  for (int d = axis + 1; d < rank; ++d) inner *= dims[0][d];

  int64_t total_axis = 0;
  for (int i = 0; i < count; ++i) total_axis += dims[i][axis];

  char *out = (char *)dst;
  int64_t written = 0;
  for (int i = 0; i < count; ++i) {
    const char *in = (const char *)srcs[i];
    const int64_t block = dims[i][axis] * inner;
    for (int64_t o = 0; o < outer; ++o)
      memcpy(out + (size_t)(o * total_axis * inner + written * inner) * element_size,
             in + (size_t)(o * block) * element_size, (size_t)block * element_size);
    written += dims[i][axis];
  }
}
