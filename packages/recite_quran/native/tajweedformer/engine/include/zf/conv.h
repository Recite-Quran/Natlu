/* int8 convolution, built on the same microkernel as the linear layers.
 *
 * The front end's five dense convolutions are 61M of a chunk's 72.5M convolution multiply-adds,
 * and two of them are 1x1, which makes them matmuls with several hundred rows: the shape the
 * microkernel is fastest at. So this lowers a convolution to that kernel by gathering patches
 * (im2col) and treats the 1x1 case as the degenerate gather it is.
 *
 * The shipped graph leaves these in fp32, so unlike the linear layers this is not bit-exact. It is
 * the arithmetic tools/quant_convs.py validated end to end: weights on a per-output-channel
 * symmetric int8 grid, activations through ONNX's DynamicQuantizeLinear, padding filled with the
 * activation zero point so it contributes exactly zero, int32 accumulation, fp32 bias.
 */
#ifndef ZF_CONV_H
#define ZF_CONV_H

#include <stddef.h>
#include <stdint.h>

#include "zf/kernels.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  int in_channels;
  int out_channels;
  int kh, kw;
  int stride_h, stride_w;
  int pad_top, pad_left, pad_bottom, pad_right;
  ZfWeightsS8 weights; /* n = out_channels, k = in_channels * kh * kw, in (c, dy, dx) order */
  const float *scale;  /* weight scale, one value or one per output channel */
  int scale_count;
  const float *bias;   /* may be NULL */
} ZfConvS8;

int zf_conv_out_h(const ZfConvS8 *c, int h);
int zf_conv_out_w(const ZfConvS8 *c, int w);

/* Gather patches from a quantised NCHW input into one row per output pixel, at row stride
 * `weights.k_pad`. Positions outside the input take `pad_value`, which must be the activation
 * zero point shifted by 128, so that those terms contribute nothing once the row-sum correction is
 * applied. */
void zf_conv_im2col(const ZfConvS8 *c, const int8_t *qin, int h, int w, int8_t pad_value,
                    int8_t *rows);

/* The same over output rows [oy0, oy1), so the gather can be split across threads. */
void zf_conv_im2col_rows(const ZfConvS8 *c, const int8_t *qin, int h, int w, int8_t pad_value,
                         int8_t *rows, int oy0, int oy1);

/* The same gather from an input that is already one row per pixel, with k in (dy, dx, channel)
 * order rather than (channel, dy, dx).
 *
 * A convolution's result comes out of the matmul one row per pixel and has to be transposed into
 * NCHW for the next gather to read it, and that transpose was the largest item in the front end
 * after the matmuls themselves: 17 ms of a chunk's single-core time for 196 thousand values, and
 * indifferent to tiling and to prefetching, so it is the latency of eight strided streams rather
 * than anything a cache can fix. Leaving the result alone and teaching the gather to read it is
 * what removes the pass rather than making it faster.
 *
 * It is also a better gather. Reading (dy, dx, channel) from a pixel-major input is kh*kw copies of
 * `in_channels` contiguous bytes; reading (channel, dy, dx) from NCHW is in_channels*kh copies of
 * kw bytes, which for 32 channels and a 3x3 kernel is 96 copies of three bytes against nine of
 * thirty-two.
 *
 * The weights have to agree, so zf_conv_reorder_k permutes a packed tensor's k axis once at load. */
void zf_conv_im2col_rows_pm(const ZfConvS8 *c, const int8_t *qin, int h, int w, int8_t pad_value,
                            int8_t *rows, int oy0, int oy1);

/* Permute a packed tensor's k axis from (channel, dy, dx) to (dy, dx, channel), in place. The
 * products are the same integers summed in a different order, and int32 addition is exact, so the
 * result is unchanged. Returns 0 if the geometry is not one this understands. */
int zf_conv_reorder_k(int8_t *packed, int n, int k, int in_channels, int kh, int kw);

/* The same gather from an input that is already one row per pixel, with k in (dy, dx, channel)
 * order rather than (channel, dy, dx).
 *
 * A convolution's result comes out of the matmul one row per pixel and has to be transposed into
 * NCHW for the next gather to read it, and that transpose was the largest item in the front end
 * after the matmuls themselves: 17 ms of a chunk's single-core time for 196 thousand values, and
 * indifferent to tiling and to prefetching, so it is the latency of eight strided streams rather
 * than anything a cache can fix. Leaving the result alone and teaching the gather to read it is
 * what removes the pass rather than making it faster.
 *
 * It is also a better gather. Reading (dy, dx, channel) from a pixel-major input is kh*kw copies of
 * `in_channels` contiguous bytes; reading (channel, dy, dx) from NCHW is in_channels*kh copies of
 * kw bytes, which for 32 channels and a 3x3 kernel is 96 copies of three bytes against nine of
 * thirty-two.
 *
 * The weights have to agree, so zf_conv_reorder_k permutes a packed tensor's k axis once at load. */
void zf_conv_im2col_rows_pm(const ZfConvS8 *c, const int8_t *qin, int h, int w, int8_t pad_value,
                            int8_t *rows, int oy0, int oy1);

/* Permute a packed tensor's k axis from (channel, dy, dx) to (dy, dx, channel), in place. The
 * products are the same integers summed in a different order, and int32 addition is exact, so the
 * result is unchanged. Returns 0 if the geometry is not one this understands. */
int zf_conv_reorder_k(int8_t *packed, int n, int k, int in_channels, int kh, int kw);

/* Quantise an NCHW input straight into the row-per-pixel layout a 1x1 convolution wants, which is
 * the transpose the separate quantise-then-gather pair used to make in two passes. `lo` and `hi`
 * come from one scan of the whole tensor, so every task writes with the same scale. */
void zf_conv_quantize_pixels(const ZfConvS8 *c, const float *x, int pixels, float scale,
                             int zero_point, int8_t *rows, int p0, int p1);

/* Scale the int32 result of output channels [j0, j1) into NCHW: the kernel wrote one row per
 * output pixel, and NCHW wants one row per channel, so this transposes as it scales. */
void zf_conv_dequantize_channels(const ZfConvS8 *c, const int32_t *acc, int pixels, float a_scale,
                                 float *y, int j0, int j1);

/* Swoosh in place over channels [j0, j1) of a block of `count` output pixels starting at p0, which
 * is the block the same task just scaled. variant 0 is SwooshL, 1 is SwooshR. */
void zf_conv_swoosh_channels(int pixels, int count, int p0, float *y, int j0, int j1, int variant);

/* The same transpose for a block of pixels rather than a block of channels: `acc` points at this
 * block's rows, `p0` says where they sit in the output row. */
void zf_conv_dequantize_pixels(const ZfConvS8 *c, const int32_t *acc, int pixels, int count,
                               int p0, float a_scale, float *y);

/* Depthwise convolution in fp32, over channels [c0, c1).
 *
 * The 65 depthwise convolutions are only about 2 million of a chunk's multiply-adds, but in ONNX
 * Runtime's generic fp32 convolution they cost about 40 ms, the largest item left outside the
 * engine. They stay in fp32, which keeps them exact: each channel is one contiguous row, so a tap
 * is a scalar times a contiguous run, which is what vmla wants. Accumulation runs tap by tap in
 * index order.
 *
 * The 1D form covers the 64 convolution modules in the encoder (kernel 8, 15, 16 or 31 over one
 * time axis), the 2D form the front end's 7x7.
 */
/* `ldx` is the distance between one channel's row and the next, which is not the same thing as the
 * window length and matters much more than it looks.
 *
 * The taps read every row about thirty times, so the row's alignment is paid thirty times over. A
 * window of T + taps - 1 floats is 33 for the deep stacks and 54 for the shallow ones, neither a
 * multiple of four, so with the window length doubling as the stride every channel starts at a
 * different sixteen byte offset and three in four of the loads straddle a boundary. Measured on
 * this core at the deep stack's shape: 148 cycles a value with the rows aligned and 478 with them
 * not, for identical arithmetic. Rounding the stride up to a multiple of four is the whole fix. */
void zf_conv_dw1d_f32(const float *x, int channels, int length, int ldx, const float *w, int taps,
                      int stride, int pad_left, const float *bias, float *y, int out_length,
                      int c0, int c1);

void zf_conv_dw2d_f32(const float *x, int channels, int h, int w_in, const float *weights, int kh,
                      int kw, int stride_h, int stride_w, int pad_top, int pad_left,
                      const float *bias, float *y, int out_h, int out_w, int c0, int c1);

/* The same dense convolution as ZfConvS8, in fp32, producing a pixel-major result.
 *
 * The deployed graph runs the front end's five dense convolutions in fp32 and the engine ran them
 * in int8. Measured against the graph that is a 3.64 per cent relative error, and it is the sole
 * cause of the engine's token divergence from the published model: with these in fp32 the front end
 * reproduces the graph exactly, 0.000000 mean error over the case, because everything after them
 * (the depthwise, the output linear) already matches.
 *
 * Geometry, padding and output layout are ZfConvS8's, so the two are interchangeable at the call
 * site. `weight` is [out_channels, in_channels * kh * kw] in the same (c, dy, dx) order the int8
 * packing uses, which is what zf_matmul_nt_f32 wants: it computes out[i][j] = sum_k a[i][k] *
 * b[j][k], and here a is one im2col row per output pixel and b is one row per output channel.
 *
 * `in_pixel_major` and `out_pixel_major` select the input and output layouts, matching the int8
 * path's flags, because the five convolutions use three different combinations of them.
 *
 * `rows` is scratch of at least out_h * out_w * (k + out_channels) floats: the im2col, plus room
 * past it for the pixel-major product when an NCHW output has to be transposed out of it. Output
 * rows [oy0, oy1) only, so it splits across threads the way the int8 path does. */
void zf_conv_f32(const ZfConvS8 *c, const float *weight, const float *x, int h, int w, float *rows,
                 float *y, int in_pixel_major, int out_pixel_major, int oy0, int oy1);

#ifdef __cplusplus
}
#endif
#endif /* ZF_CONV_H */
