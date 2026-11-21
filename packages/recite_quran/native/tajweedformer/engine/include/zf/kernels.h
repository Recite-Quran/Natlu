/* Engine kernels. The int8 path reproduces the deployed graph's integer arithmetic exactly:
 * DynamicQuantizeLinear to uint8, then sum over k of (a - a_zero_point) * weight, then a float
 * scale.
 *
 * Two facts about this model shape the kernel. First, every weight is in [-127, 127] (the census in
 * tools/matmul_shapes.py checked all 290 integer matmuls of the shipped graph), so two products fit
 * in one int16 lane and the multiply can be a VMULL plus a VMLAL before widening. Second, the
 * matmuls are skinny: m is 3, 6, 12 or 24, so each weight byte pays for only m multiply-adds and
 * has to be reused across all m rows while it sits in a register. Weights are therefore packed
 * offline into panels of four output units, interleaved in 16-byte groups, which makes each panel
 * one sequential stream and lets the microkernel hold four units and two rows in registers. */
#ifndef ZF_KERNELS_H
#define ZF_KERNELS_H

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
#include <stdint.h>

#include "zf/pool.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Output units per packed panel, and the k group the panel interleaves on. */
#define ZF_S8_UNIT_BLOCK 4
#define ZF_S8_K_GROUP 16

/* ONNX DynamicQuantizeLinear for uint8: scale = (max(0,max x) - min(0,min x)) / 255, zero point
 * = round(-min / scale), values = saturate(round(x / scale) + zero_point), all round-half-even. */
void zf_dynamic_quantize_u8(const float *x, size_t n, uint8_t *q, float *scale, int *zero_point);

/* Same quantisation, written out as int8 with 128 subtracted, which is what the linear kernel
 * consumes: the constant shift folds into the zero-point correction, so the integers are
 * unchanged and the kernel needs no per-unit subtraction. */
void zf_dynamic_quantize_shifted(const float *x, size_t n, int8_t *q, float *scale, int *zero_point);

/* Quantise an m by k activation block into the layout the linear kernel wants: one scale and zero
 * point for the whole block, as ONNX computes it, rows at stride `lda` (at least k rounded up to
 * ZF_S8_K_GROUP) and the padding zeroed so it contributes nothing. */
void zf_dynamic_quantize_rows(const float *x, int m, int k, int lda, int8_t *a, float *scale,
                              int *zero_point);

/* The same in two phases, so it can be split across threads: every task scans its own rows for the
 * range, the caller combines them into one scale and zero point, and every task then writes its own
 * rows. A chunk quantises about a million values across 272 linears, and doing it on one thread was
 * a third of what the whole layer spent outside its matmuls. */
void zf_quantize_range_rows(const float *x, int k, float *lo, float *hi, int row0, int row1);
void zf_quantize_params(float lo, float hi, float *scale, int *zero_point);
void zf_quantize_write_rows(const float *x, int k, int lda, int8_t *a, float scale, int zero_point,
                            int row0, int row1);

/* Weights packed for the microkernel, and the row sums that carry the zero-point correction. */
typedef struct {
  int n;         /* output units */
  int k;         /* input width */
  int n_blocks;  /* panels of ZF_S8_UNIT_BLOCK units, the unit of parallel work */
  int k_pad;     /* k rounded up to ZF_S8_K_GROUP; the pad is zero in both weights and rows */
  const int8_t *packed;
  const int32_t *row_sums;
} ZfWeightsS8;

/* Sizes the caller must allocate before packing. */
size_t zf_weights_s8_packed_bytes(int n, int k);
int zf_weights_s8_row_sums_count(int n);

/* Pack row-major weights (one contiguous row of k values per output unit) into panels, and sum
 * each row. Returns 0 without writing a usable result if any weight is -128, which would overflow
 * the microkernel's 16-bit pairing; the shipped graph has none. */
int zf_weights_s8_pack(const int8_t *w_nk, int n, int k, int8_t *packed, int32_t *row_sums,
                       ZfWeightsS8 *out);

/* Which microkernel the linear path uses: 1 for the hand-written assembly (32-bit ARM only), 0 for
 * the C intrinsics. The assembly is the default where it exists. Setting the variant returns 0 if
 * the request cannot be honoured, and is meant for benchmarks that measure both in one run; it is
 * not thread safe, so set it before any kernel call. */
int zf_kernels_asm_available(void);
int zf_kernels_set_variant(int use_asm);
int zf_kernels_variant(void);

/* out[i][j] = sum_k (a[i][k] - a_zero_point) * weight[j][k], where `a` holds shifted int8
 * activations at row stride `lda` and `out` has row stride `ldc`. */
void zf_linear_s8(const int8_t *a, int m, int lda, const ZfWeightsS8 *w, int a_zero_point,
                  int32_t *out, int ldc);

/* The int8 accelerator hook (weak in kernels.c, which declines; tajweedformer-native links a strong
 * one). Rows [row_begin, row_end) of `a` against unit blocks [block_begin, block_end), written to
 * out[i * ldc + j - j_shift] as the exact int32 above; returns 1 if it did, 0 to decline. Not called
 * on ARMv7, whose assembly scales in its own epilogue. */
int zf_s8_linear_hook(const ZfWeightsS8 *w, const int8_t *a, int row_begin, int row_end, int lda,
                      int a_zero_point, int32_t *out, int ldc, int block_begin, int block_end,
                      int j_shift);

/* Same over a slice of panels, for splitting across a pool. */
void zf_linear_s8_range(const int8_t *a, int m, int lda, const ZfWeightsS8 *w, int a_zero_point,
                        int32_t *out, int ldc, int block_begin, int block_end);

/* The same into a compact tile: `out` holds only the columns this range produces, at row stride
 * `ldc`, and `j_shift` is the first of them. A few kilobytes rather than the whole m by n slab, so
 * the int32 never reaches memory. */
void zf_linear_s8_tile(const int8_t *a, int m, int lda, const ZfWeightsS8 *w, int a_zero_point,
                       int32_t *out, int ldc, int block_begin, int block_end, int j_shift);

/* The matmul with the scaling folded into the microkernel's epilogue, so the int32 accumulator
 * never reaches memory: it saves a pass over every output and 3.5 MB of a chunk's traffic. `scratch`
 * is only used when the assembly is switched off. Bit identical to zf_linear_s8_range followed by
 * zf_dequantize_range. */
void zf_linear_s8_f32_range(const int8_t *a, int m, int lda, const ZfWeightsS8 *w,
                            int a_zero_point, int32_t *scratch, const float *scale, int scale_count,
                            const float *bias, float *y, int ldy, int block_begin, int block_end);

/* Scale such a tile into columns [j0, j0 + cols) of the result, one contiguous run per row. The
 * _t form writes it transposed, one row per output unit. */
void zf_dequantize_tile(const int32_t *tile, int m, int cols, const float *scale, int scale_count,
                        const float *bias, float *y, int ldy, int j0);
void zf_dequantize_tile_t(const int32_t *tile, int m, int cols, const float *scale,
                          int scale_count, const float *bias, float *y, int ldy, int j0);

/* Parallel wrapper: splits the panels across the pool. */
void zf_linear_s8_pool(ZfPool *pool, const int8_t *a, int m, int lda, const ZfWeightsS8 *w,
                       int a_zero_point, int32_t *out, int ldc);

/* y = int32 result * scale + bias, where scale is a_scale * weight_scale (per output unit when
 * `scale_count` is n, otherwise one value for the whole tensor). bias may be NULL. */
void zf_dequantize(const int32_t *acc, int m, int n, int ldc, const float *scale, int scale_count,
                   const float *bias, float *y, int ldy);

/* Same over a column range, so the thread that produced those output units also scales them, while
 * they are still in cache and without touching another thread's columns. */
void zf_dequantize_range(const int32_t *acc, int m, int ldc, const float *scale, int scale_count,
                         const float *bias, float *y, int ldy, int begin, int end);

/* The same, writing the result transposed: y[j][i] rather than y[i][j], at row stride ldy.
 *
 * The convolution modules want one row per channel and the kernel produces one row per frame, so
 * the transpose the module used to do as its own pass rides along with the scaling, which has to
 * touch every value anyway. */
void zf_dequantize_range_t(const int32_t *acc, int m, int ldc, const float *scale, int scale_count,
                           const float *bias, float *y, int ldy, int begin, int end);

/* Quantise a column-major block: x is [k, rows] at row stride ldx, and the result is the row per
 * output position the linear kernel consumes. The other half of the same saving, on the way out of
 * the convolution module. */
void zf_quantize_range_cols(const float *x, int k, int rows, int ldx, float *lo, float *hi);
void zf_quantize_write_cols(const float *x, int k, int ldx, int lda, int8_t *a, float scale,
                            int zero_point, int row0, int row1);

/* SwooshL: log(1 + exp(x - 4)) - 0.08x - 0.035. SwooshR uses 1.0 and 0.313261687. One fused pass,
 * computed as max(z,0) + log1p(exp(-|z|)) with an atanh series for log1p, so no logarithm is
 * needed and the overflow guard the exported graph carries is unnecessary. */
void zf_swoosh_l(const float *x, float *y, size_t n);
void zf_swoosh_r(const float *x, float *y, size_t n);
/* The front end's swoosh sites. The graph spells them differently from the encoder's (stable,
 * Max(z, 0) + Log(1 + Exp(-|z|)), against the encoder's direct Log(Exp(z) + 1)), which only
 * matters under ZF_CONV_ORT; otherwise these are zf_swoosh_l and zf_swoosh_r. */
void zf_swoosh_l_fe(const float *x, float *y, size_t n);
void zf_swoosh_r_fe(const float *x, float *y, size_t n);
/* SwooshL at another offset: b8 subtracts 1 before its softplus where v3.1 subtracts 4 (the tail
 * 0.035 is the same). zf_swoosh_l is this at 4. */
void zf_swoosh_l_at(const float *x, float *y, size_t n, float offset);
/* The front end's sites by variant: ZF_SWOOSH_L (offset 4), ZF_SWOOSH_R, ZF_SWOOSH_L1 (SwooshL at
 * offset 1, b8's). The front end's convolutions pass one of these as their `swoosh`. */
enum { ZF_SWOOSH_L = 0, ZF_SWOOSH_R = 1, ZF_SWOOSH_L1 = 2 };
void zf_swoosh_fe(const float *x, float *y, size_t n, int variant);

/* The activations the encoder layers need, over the same NEON exp as Swoosh: the layer spent 13 ms
 * a chunk in libm's expf on softmax alone. */
void zf_sigmoid_f32(const float *x, float *y, size_t n);
void zf_tanh_f32(const float *x, float *y, size_t n);

/* Softmax along each row of [rows, n], in place. */
void zf_softmax_rows_f32(float *x, int rows, int n);
/* ONNX Runtime's LogSoftmax over the last axis on ARM32; see kernels.c. */
void zf_log_softmax_rows_f32(const float *x, float *y, int rows, int n);

#ifdef __cplusplus
}
#endif
#endif /* ZF_KERNELS_H */
