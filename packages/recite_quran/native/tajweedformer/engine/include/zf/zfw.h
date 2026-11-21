/* The engine's weight file: one flat file of named tensors, int8 weights already packed into the
 * microkernel's panel layout with their row sums precomputed. Loading is a read and an index
 * build, with no graph to parse. tools/zfw.py writes it. */
#ifndef ZF_ZFW_H
#define ZF_ZFW_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ZF_ZFW_NAME_LEN 40

typedef enum { ZF_DTYPE_F32 = 0, ZF_DTYPE_S8 = 1, ZF_DTYPE_S32 = 2 } ZfDtype;

typedef struct {
  const char *name;
  ZfDtype dtype;
  const void *data;
  size_t bytes;
  int32_t dims[4];
} ZfTensor;

typedef struct ZfWeights ZfWeights;

/* Reads the whole file. Returns NULL and, when `error` is not NULL, a static reason. */
ZfWeights *zf_weights_open(const char *path, const char **error);
/* The same from a blob already in memory; takes ownership of `blob` (malloc'd). */
ZfWeights *zf_weights_from_blob(unsigned char *blob, size_t size, const char **error);
void zf_weights_close(ZfWeights *w);

/* Looks a tensor up by name; returns NULL if absent. */
const ZfTensor *zf_weights_find(const ZfWeights *w, const char *name);

/* Same, for the common cases, returning the payload directly. NULL if absent or the wrong type. */
const float *zf_weights_f32(const ZfWeights *w, const char *name, size_t *count);
const int8_t *zf_weights_s8(const ZfWeights *w, const char *name, size_t *count);

/* Rearrange a packed int8 tensor in place from the pairing layout the file stores into the one the
 * dot-product kernel reads. Returns 1 if the tensor is now in the dot layout, including when it
 * already was: a tensor is converted at most once however many times this is called, because the
 * two layouts are permutations of the same bytes and converting twice would corrupt it. */
int zf_weights_convert_to_dot(ZfWeights *w, const char *name, int n, int k);

/* Permute a packed convolution weight's k axis from (channel, dy, dx) to (dy, dx, channel), at most
 * once however many times this is called. Returns 1 if the tensor is now in that order. */
int zf_weights_reorder_conv_k(ZfWeights *w, const char *name, int n, int k, int in_channels, int kh,
                              int kw);

/* The same for an fp32 conv weight, so the fp32 gather can read a pixel-major input in contiguous
 * runs of in_channels floats rather than one strided load per element. */
int zf_weights_reorder_conv_k_f32(ZfWeights *w, const char *name, int n, int in_channels, int kh,
                                  int kw);
const int32_t *zf_weights_s32(const ZfWeights *w, const char *name, size_t *count);

int zf_weights_count(const ZfWeights *w);
const ZfTensor *zf_weights_at(const ZfWeights *w, int index);

#ifdef __cplusplus
}
#endif
#endif /* ZF_ZFW_H */
