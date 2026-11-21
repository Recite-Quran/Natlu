/* Small fused blocks that the graph spells out in several nodes each.
 *
 * Each of these is one pass over a row where ONNX needs three to six tensors written and read
 * again. A chunk materialises 11.9M tensor elements, 48 MB out and back at about 1 GB/s, so what
 * these save is not arithmetic but memory traffic.
 */
#ifndef ZF_BLOCK_H
#define ZF_BLOCK_H

/* Tripwire: a fused multiply-add would change every float in the engine.
 *
 * The engine is built -march=armv7-a with no -mfpu, so the target is vfpv3 plus NEON with no
 * VFMA, and every vmlaq_f32 lowers to an unfused VMLA.F32: the product is rounded before the
 * accumulate. Several kernels depend on that, because their scalar and vector paths have to agree
 * bit for bit and the scalar one is a separate multiply and add.
 *
 * Adding -mcpu=cortex-a53, -mfpu=neon-vfpv4 or -mfpu=fp-armv8 turns on +vfp4, and clang's default
 * -ffp-contract=on then fuses those into VFMA. Nothing fails, no test errors: the numbers simply
 * stop matching the reference by one rounding per multiply-add, across the whole encoder. Put
 * -mfpu=neon after any -mcpu so no FMA instruction exists to target, and keep -ffp-contract=off.
 */
#if defined(__ARM_FEATURE_FMA) && !defined(__aarch64__)
#error "FMA is available on a 32-bit ARM build: put -mfpu=neon after -mcpu, or every float changes"
#endif


#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* BiasNorm, as Zipformer2 defines it and the graph writes it out in six nodes:
 *   y[t][c] = x[t][c] * scale / sqrt(mean over c of (x[t][c] - bias[c])^2)
 * One pass reads the row twice from cache instead of writing three whole tensors. */
void zf_bias_norm(const float *x, int rows, int channels, const float *bias, float scale,
                  float *y);

/* Bypass: y = b + (a - b) * weight[c], the learned residual mix, three nodes in the graph. */
void zf_bypass(const float *a, const float *b, int rows, int channels, const float *weight,
               float *y);

/* Batched fp32 matmul for the attention products, the one arithmetic left that cannot go through
 * the int8 kernel because both operands are activations. y[b] = a[b] (m by k) times bb[b] (k by n).
 * The loop holds sixteen output columns in registers and walks k, so the second operand is read
 * along its contiguous axis and the accumulator never leaves the register file. Rows [m0, m1) only,
 * so it can be split across threads. */
void zf_matmul_f32(const float *a, const float *bb, int batch, int m, int k, int n, float *y,
                   int m0, int m1);

/* out[i][j] = sum_k a[i][k] * b[j][k], the attention score form, where both operands are read along
 * k. Four output columns at a time, so the four accumulators are reduced together by a transpose
 * rather than one horizontal sum per output. */
void zf_matmul_nt_f32(const float *a, int lda, const float *b, int ldb, int m, int n, int k,
                      float *out, int ldc);

/* The k stride ONNX Runtime's MLAS uses for a GEMM with N output columns and depth K (A not
 * transposed). Sums run sequentially from +0.0 inside a stride and strides fold in order. */
int zf_mlas_stride_k(int n, int k);

/* zf_matmul_nt_f32's sequential order with MLAS's beta = 1: each k stride is added to `out`, the
 * first one included. NEON builds only. */
void zf_matmul_nt_seq_acc_f32(const float *a, int lda, const float *b, int ldb, int m, int n,
                              int k, float *out, int ldc);

/* The same product through the 4 by 4 d-register tile, without the divisibility gate the function
 * above applies.
 *
 * That gate exists because zf_matmul_nt_f32 is the attention's kernel and the attention ships: a
 * tile whose tails reduce in a different order would move the engine's output, so it only takes the
 * tile on shapes it divides exactly. The fp32 convolutions have no such constraint, and their
 * threaded bands are not multiples of four, so they call this directly and take the tails. */
void zf_matmul_nt4x4_f32(const float *a, int lda, const float *b, int ldb, int m, int n, int k,
                         float *out, int ldc);

/* The two ways this model changes frame rate between its stacks.
 *
 * Both were spelled out in the graph as three nodes each, and there are eleven of them a chunk: a
 * reshape that splits the time axis into blocks, then a multiply by one weight per position in the
 * block, then a sum over the block for the downsamples; an unsqueeze, an expand and a reshape for
 * the upsamples. None of it is arithmetic worth naming, but each node costs ONNX Runtime a dispatch
 * and an allocation, and the eleven of them cost more than the work.
 *
 * out[t][c] = sum over j of in[t * factor + j][c] * weight[j], for `frames_out` rows. */
void zf_downsample_f32(const float *in, int frames_out, int factor, int channels,
                       const float *weight, float *out, int t0, int t1);

/* out[t * factor + j][c] = in[t][c] for every j below factor: each frame repeated. */
void zf_upsample_f32(const float *in, int frames_in, int factor, int channels, float *out, int t0,
                     int t1);

#ifdef __cplusplus
}
#endif
#endif /* ZF_BLOCK_H */
