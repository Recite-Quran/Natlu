/* The engine's front end: features in, encoder input out, nothing materialised in between.
 *
 * This is the first piece of the engine proper. In the shipped graph the same work is about fifty
 * nodes and twenty intermediate tensors: three strided convolutions each followed by SwooshR, a
 * 7x7 depthwise convolution over a three-frame cache, two 1x1 convolutions with SwooshL between
 * them, a residual add, a transpose and reshape, a linear and a BiasNorm. Here it is one call over
 * one scratch arena, which is the whole point: a chunk's 48 MB of intermediate traffic is what the
 * per-node design cannot avoid.
 */
#ifndef ZF_FRONTEND_H
#define ZF_FRONTEND_H

#include <stddef.h>

#include "zf/zfw.h"

#ifdef __cplusplus
extern "C" {
#endif

/* How the caller lends threads. `run` must call `fn(user, i)` for every i in [0, count), in any
 * order, and return once they are all done. A NULL ZfForEach runs everything on the caller. */
typedef void (*ZfForEach)(void *ctx, void (*fn)(void *user, size_t index), size_t count,
                          void *user);

typedef struct {
  ZfForEach run;
  void *ctx;
  int threads;
} ZfParallel;

typedef struct ZfFrontEnd ZfFrontEnd;

/* Builds the convolution descriptors and the scratch arena for inputs of up to `max_frames`.
 * Borrows `w`, which must outlive it. */
ZfFrontEnd *zf_frontend_create(ZfWeights *w, int max_frames, const char **error);
void zf_frontend_destroy(ZfFrontEnd *fe);
/* The ConvNeXt's SwooshL subtracts this before its softplus: 4 (v3.1, the default) or 1 (b8).
 * Returns 0, or -1 for any other value. */
int zf_frontend_set_swoosh_l_offset(ZfFrontEnd *fe, float offset);

/* Frames the front end produces from `frames` input frames, and the cache it carries between
 * chunks, as [channels, rows, width] floats. */
int zf_frontend_out_frames(const ZfFrontEnd *fe, int frames);
int zf_frontend_state_floats(const ZfFrontEnd *fe);
int zf_frontend_out_channels(const ZfFrontEnd *fe);

/* x is [frames, 80] float32, state is the cache in and out, out is [out_frames, 192]. */
int zf_frontend_run(ZfFrontEnd *fe, const float *x, int frames, float *state, float *out,
                    const ZfParallel *par);

/* Run as much of the window as its first `valid` frames allow, while the rest of its audio is still
 * arriving; the zf_frontend_run that follows on the whole window then does only what remains. x is
 * the window's first `valid` frames (of `frames` in all), state the cache the run will be given. The
 * result is bit-identical to a single run: every row is computed by the same operations over the
 * same inputs, and a run whose frames differ from what was prefetched starts over. fp32 path only;
 * elsewhere this does nothing. Returns 0 on bad arguments. */
int zf_frontend_prefetch(ZfFrontEnd *fe, const float *x, int frames, int valid, const float *state,
                         const ZfParallel *par);

/* Where the last run's time went, in milliseconds, for the stages named by
 * zf_frontend_stage_name. Accumulates until zf_frontend_reset_stages. */
#define ZF_FE_STAGES 16
void zf_frontend_stages(const ZfFrontEnd *fe, double *out_ms);
void zf_frontend_reset_stages(ZfFrontEnd *fe);
const char *zf_frontend_stage_name(int index);

#ifdef __cplusplus
}
#endif
#endif /* ZF_FRONTEND_H */
