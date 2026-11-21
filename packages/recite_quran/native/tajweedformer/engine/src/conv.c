#include "zf/conv.h"
#include "zf/env.h"

#include "zf/block.h"  /* zf_matmul_nt_f32, for the fp32 convolution path */

#include <stdlib.h>

#include <string.h>

#include "zf/neon.h"
#define ZF_NEON ZF_NEON_AVAILABLE

int zf_conv_out_h(const ZfConvS8 *c, int h) {
  return (h + c->pad_top + c->pad_bottom - c->kh) / c->stride_h + 1;
}

int zf_conv_out_w(const ZfConvS8 *c, int w) {
  return (w + c->pad_left + c->pad_right - c->kw) / c->stride_w + 1;
}

/* A 1x1 convolution's patch gather is a transpose of the (channels by pixels) plane into one row
 * per pixel. Done element by element that dominated the whole convolution, so it goes in blocks:
 * each pass reads one 16 by 16 tile, which keeps both the source rows and the destination rows in
 * cache. */
static void im2col_pointwise(const ZfConvS8 *c, const int8_t *qin, int pixels, int8_t *rows) {
  const int ldk = c->weights.k_pad, channels = c->in_channels;
  const int tile = 16;
  for (int p0 = 0; p0 < pixels; p0 += tile) {
    const int p1 = (p0 + tile < pixels) ? p0 + tile : pixels;
    for (int ch0 = 0; ch0 < channels; ch0 += tile) {
      const int ch1 = (ch0 + tile < channels) ? ch0 + tile : channels;
      for (int ch = ch0; ch < ch1; ++ch) {
        const int8_t *src = qin + (size_t)ch * pixels;
        int8_t *dst = rows + (size_t)p0 * ldk + ch;
        for (int p = p0; p < p1; ++p, dst += ldk) *dst = src[p];
      }
    }
  }
  if (ldk > channels)
    for (int p = 0; p < pixels; ++p) memset(rows + (size_t)p * ldk + channels, 0,
                                            (size_t)(ldk - channels));
}

void zf_conv_im2col(const ZfConvS8 *c, const int8_t *qin, int h, int w, int8_t pad_value,
                    int8_t *rows) {
  zf_conv_im2col_rows(c, qin, h, w, pad_value, rows, 0, zf_conv_out_h(c, h));
}

void zf_conv_im2col_rows(const ZfConvS8 *c, const int8_t *qin, int h, int w, int8_t pad_value,
                         int8_t *rows, int oy0, int oy1) {
  const int out_w = zf_conv_out_w(c, w);
  const int ldk = c->weights.k_pad;
  const int taps = c->kw;
  if (c->kh == 1 && c->kw == 1 && c->stride_h == 1 && c->stride_w == 1 && c->pad_top == 0 &&
      c->pad_left == 0 && c->pad_bottom == 0 && c->pad_right == 0) {
    /* a 1x1 gather is a transpose, and splitting it by row would break the tiling, so the first
     * caller does all of it */
    if (oy0 == 0) im2col_pointwise(c, qin, h * w, rows);
    return;
  }
  for (int oy = oy0; oy < oy1; ++oy) {
    for (int ox = 0; ox < out_w; ++ox) {
      int8_t *row = rows + (size_t)(oy * out_w + ox) * ldk;
      const int y0 = oy * c->stride_h - c->pad_top;
      const int x0 = ox * c->stride_w - c->pad_left;
      int at = 0;
      for (int ch = 0; ch < c->in_channels; ++ch) {
        const int8_t *plane = qin + (size_t)ch * h * w;
        for (int dy = 0; dy < c->kh; ++dy, at += taps) {
          const int y = y0 + dy;
          if (y < 0 || y >= h) {
            memset(row + at, pad_value, (size_t)taps);
            continue;
          }
          const int8_t *src = plane + (size_t)y * w;
          if (x0 >= 0 && x0 + taps <= w) {
            /* the common case, nothing clipped: an explicit loop rather than memcpy, because the
             * tap count is 3 here and the call overhead dominated the copy */
            for (int dx = 0; dx < taps; ++dx) row[at + dx] = src[x0 + dx];
          } else {
            for (int dx = 0; dx < taps; ++dx) {
              const int x = x0 + dx;
              row[at + dx] = (x < 0 || x >= w) ? pad_value : src[x];
            }
          }
        }
      }
      if (ldk > at) memset(row + at, 0, (size_t)(ldk - at)); /* k padding multiplies by zero */
    }
  }
}

/* Quantise [channel, pixel] into [pixel, channel] in one pass, in 4 by 4 tiles so both sides move
 * contiguously. Used for the 1x1 convolutions, where the gather is exactly this transpose. */
void zf_conv_im2col_rows_pm(const ZfConvS8 *c, const int8_t *qin, int h, int w, int8_t pad_value,
                            int8_t *rows, int oy0, int oy1) {
  const int out_w = zf_conv_out_w(c, w);
  const int ldk = c->weights.k_pad;
  const int ch = c->in_channels;
  for (int oy = oy0; oy < oy1; ++oy) {
    for (int ox = 0; ox < out_w; ++ox) {
      int8_t *row = rows + (size_t)(oy * out_w + ox) * ldk;
      const int y0 = oy * c->stride_h - c->pad_top;
      const int x0 = ox * c->stride_w - c->pad_left;
      int at = 0;
      for (int dy = 0; dy < c->kh; ++dy) {
        const int y = y0 + dy;
        for (int dx = 0; dx < c->kw; ++dx, at += ch) {
          const int x = x0 + dx;
          if (y < 0 || y >= h || x < 0 || x >= w) {
            memset(row + at, pad_value, (size_t)ch);
            continue;
          }
          memcpy(row + at, qin + ((size_t)y * w + x) * ch, (size_t)ch);
        }
      }
      if (ldk > at) memset(row + at, 0, (size_t)(ldk - at)); /* k padding multiplies by zero */
    }
  }
}

/* Where weight (unit, k) sits in the pairing layout: panels of four units, interleaved in groups
 * of sixteen k. */
static size_t pair_offset(int u, int kidx, int k_pad) {
  (void)k_pad;
  return (size_t)(kidx / ZF_S8_K_GROUP) * (ZF_S8_UNIT_BLOCK * ZF_S8_K_GROUP) +
         (size_t)u * ZF_S8_K_GROUP + (size_t)(kidx % ZF_S8_K_GROUP);
}

int zf_conv_reorder_k(int8_t *packed, int n, int k, int in_channels, int kh, int kw) {
  if (in_channels * kh * kw != k) return 0;
  const int k_pad = (k + ZF_S8_K_GROUP - 1) / ZF_S8_K_GROUP * ZF_S8_K_GROUP;
  const int blocks = (n + ZF_S8_UNIT_BLOCK - 1) / ZF_S8_UNIT_BLOCK;
  const size_t panel_bytes = (size_t)ZF_S8_UNIT_BLOCK * k_pad;
  int8_t *tmp = (int8_t *)malloc(panel_bytes);
  if (!tmp) return 0;
  for (int jb = 0; jb < blocks; ++jb) {
    int8_t *panel = packed + (size_t)jb * panel_bytes;
    memcpy(tmp, panel, panel_bytes);
    for (int u = 0; u < ZF_S8_UNIT_BLOCK; ++u)
      for (int c = 0; c < in_channels; ++c)
        for (int dy = 0; dy < kh; ++dy)
          for (int dx = 0; dx < kw; ++dx) {
            const int old_k = (c * kh + dy) * kw + dx;
            const int new_k = (dy * kw + dx) * in_channels + c;
            panel[pair_offset(u, new_k, k_pad)] = tmp[pair_offset(u, old_k, k_pad)];
          }
  }
  free(tmp);
  return 1;
}

void zf_conv_quantize_pixels(const ZfConvS8 *c, const float *x, int pixels, float scale,
                             int zero_point, int8_t *rows, int p0, int p1) {
  const int k = c->in_channels, lda = c->weights.k_pad;
  const float inv = scale != 0.0f ? 1.0f / scale : 0.0f;
  const float bias = (float)(zero_point - 128);
#if ZF_NEON
  const float32x4_t vinv = vdupq_n_f32(inv);
  const float32x4_t magic = vdupq_n_f32(12582912.0f); /* 1.5 * 2^23: round half to even */
#endif
  for (int p = p0; p < p1; ++p) {
    int8_t *row = rows + (size_t)p * lda;
    int ch = 0;
#if ZF_NEON
    for (; ch + 4 <= k; ch += 4) {
      float32x4_t v = vdupq_n_f32(x[(size_t)(ch + 0) * pixels + p]);
      v = vsetq_lane_f32(x[(size_t)(ch + 1) * pixels + p], v, 1);
      v = vsetq_lane_f32(x[(size_t)(ch + 2) * pixels + p], v, 2);
      v = vsetq_lane_f32(x[(size_t)(ch + 3) * pixels + p], v, 3);
      v = vmulq_f32(v, vinv);
      v = vsubq_f32(vaddq_f32(v, magic), magic);
      int32x4_t q = vcvtq_s32_f32(vaddq_f32(v, vdupq_n_f32(bias)));
      const int16x4_t h = vqmovn_s32(q);
      const int8x8_t b = vqmovn_s16(vcombine_s16(h, h));
      vst1_lane_u32((uint32_t *)row + ch / 4, vreinterpret_u32_s8(b), 0);
    }
#endif
    for (; ch < k; ++ch) {
      float v = x[(size_t)ch * pixels + p] * inv;
      v = (v + 12582912.0f) - 12582912.0f;
      int q = (int)(v + bias);
      if (q > 127) q = 127;
      if (q < -128) q = -128;
      row[ch] = (int8_t)q;
    }
    for (int j = k; j < lda; ++j) row[j] = 0; /* the weights are zero here too */
  }
}

/* One 4 by 4 tile of the transpose: four accumulator rows in, four NCHW rows out. */
#if ZF_NEON
static inline void deq_tile4(const int32_t *acc, int n, const float *scale, const float *bias,
                             float *dst, int pixels) {
  const int32x4_t r0 = vld1q_s32(acc);
  const int32x4_t r1 = vld1q_s32(acc + n);
  const int32x4_t r2 = vld1q_s32(acc + 2 * (size_t)n);
  const int32x4_t r3 = vld1q_s32(acc + 3 * (size_t)n);
  const int32x4x2_t a = vtrnq_s32(r0, r1);
  const int32x4x2_t b = vtrnq_s32(r2, r3);
  const int32x4_t c0 = vcombine_s32(vget_low_s32(a.val[0]), vget_low_s32(b.val[0]));
  const int32x4_t c1 = vcombine_s32(vget_low_s32(a.val[1]), vget_low_s32(b.val[1]));
  const int32x4_t c2 = vcombine_s32(vget_high_s32(a.val[0]), vget_high_s32(b.val[0]));
  const int32x4_t c3 = vcombine_s32(vget_high_s32(a.val[1]), vget_high_s32(b.val[1]));
  vst1q_f32(dst, vmlaq_n_f32(vdupq_n_f32(bias[0]), vcvtq_f32_s32(c0), scale[0]));
  vst1q_f32(dst + pixels, vmlaq_n_f32(vdupq_n_f32(bias[1]), vcvtq_f32_s32(c1), scale[1]));
  vst1q_f32(dst + 2 * (size_t)pixels,
            vmlaq_n_f32(vdupq_n_f32(bias[2]), vcvtq_f32_s32(c2), scale[2]));
  vst1q_f32(dst + 3 * (size_t)pixels,
            vmlaq_n_f32(vdupq_n_f32(bias[3]), vcvtq_f32_s32(c3), scale[3]));
}
#endif

/* The transpose, tiled so each accumulator cache line is read once.
 *
 * Walking channels outer and pixels inner re-reads the whole accumulator slab once per group of
 * four channels: the 1x1 convolutions here are 456 pixels by 384 channels, and only sixteen bytes
 * of every sixty-four byte line are used per pass. That cost more than the matmul that produced
 * the slab. A tile of ZF_DEQ_P pixels by ZF_DEQ_J channels consumes each line whole, and both the
 * source tile and the destination tile fit in this chip's 32 KB level one cache. */
#define ZF_DEQ_P 16
#define ZF_DEQ_J 64

static void deq_transpose(const ZfConvS8 *c, const int32_t *acc, int n, int pixels, int count,
                          int p0, float a_scale, float *y, int j0, int j1) {
  for (int pb = 0; pb < count; pb += ZF_DEQ_P) {
    int pe = pb + ZF_DEQ_P;
    if (pe > count) pe = count;
    for (int jb = j0; jb < j1; jb += ZF_DEQ_J) {
      int je = jb + ZF_DEQ_J;
      if (je > j1) je = j1;
      int j = jb;
#if ZF_NEON
      for (; j + 4 <= je; j += 4) {
        float scale[4], bias[4];
        for (int u = 0; u < 4; ++u) {
          scale[u] = a_scale * ((c->scale_count == 1) ? c->scale[0] : c->scale[j + u]);
          bias[u] = c->bias ? c->bias[j + u] : 0.0f;
        }
        int p = pb;
        for (; p + 4 <= pe; p += 4)
          deq_tile4(acc + (size_t)p * n + j, n, scale, bias,
                    y + (size_t)j * pixels + p0 + p, pixels);
        for (; p < pe; ++p)
          for (int u = 0; u < 4; ++u)
            y[(size_t)(j + u) * pixels + p0 + p] =
                (float)acc[(size_t)p * n + j + u] * scale[u] + bias[u];
      }
#endif
      for (; j < je; ++j) {
        const float sc = a_scale * ((c->scale_count == 1) ? c->scale[0] : c->scale[j]);
        const float bi = c->bias ? c->bias[j] : 0.0f;
        for (int p = pb; p < pe; ++p)
          y[(size_t)j * pixels + p0 + p] = (float)acc[(size_t)p * n + j] * sc + bi;
      }
    }
  }
}

void zf_conv_dequantize_channels(const ZfConvS8 *c, const int32_t *acc, int pixels, float a_scale,
                                 float *y, int j0, int j1) {
  deq_transpose(c, acc, c->out_channels, pixels, pixels, 0, a_scale, y, j0, j1);
}

/* Swoosh over what this task just scaled, while it is still in cache.
 *
 * Every front-end convolution but the last is followed by one, and running it as its own pass over
 * the whole tensor read and wrote up to 175 thousand values again for nothing. `variant` is 0 for
 * SwooshL and 1 for SwooshR, matching the graph's two forms. */
void zf_conv_swoosh_channels(int pixels, int count, int p0, float *y, int j0, int j1,
                             int variant) {
  for (int j = j0; j < j1; ++j) {
    float *row = y + (size_t)j * pixels + p0;
    zf_swoosh_fe(row, row, (size_t)count, variant);
  }
}

/* Depthwise convolution, fp32.
 *
 * These are small and awkward: 3, 6, 12 or 24 outputs against 8 to 31 taps over 192 to 512
 * channels for the encoder's convolution modules, and 24 by 19 outputs against 49 taps over 128
 * channels for the front end's 7x7. Three earlier versions were slow for reasons worth recording.
 * Accumulating y[p] in memory across taps serialises on store-to-load forwarding, about five
 * cycles per multiply-add. Making each output an inner product removed that but paid a horizontal
 * sum and two NEON-to-core register moves per output. Vectorising over outputs instead fixed the
 * wide cases but left the narrow ones entirely scalar, because an output row of three has no full
 * four-lane block, and left the 7x7 mostly scalar, because every column near an edge needs bounds
 * checks.
 *
 * So both kernels copy the input into a zero-padded scratch with four floats of slack at the end.
 * Every load is then in bounds, no tap needs a bounds check, and even a row of three outputs runs
 * as one four-lane block with the extra lanes discarded. Four tap accumulators cover the
 * eight-cycle latency of a Q-form floating-point multiply accumulate, and since the lanes are
 * different outputs nothing is ever summed horizontally.
 */
#define ZF_DW_SCRATCH 4096

/* Sixteen outputs at a time, four accumulators to a weight.
 *
 * A tap is one scalar times a contiguous run, and the scalar has to reach a NEON lane. Applying it
 * to one accumulator vector meant a four byte load and its use eight cycles later for every four
 * products, and on this in-order core the stall was most of the kernel: the front end's 7 by 7
 * convolution measured four times its arithmetic. Four accumulators per weight load hide the
 * latency behind the multiply-adds and cost nothing but registers. */
#define ZF_DW_LANES 16

/* Defined with the fp32 convolution below; the depthwise needs it too, NEON or not. */
static int zf_conv_ort_order(void);

#if ZF_NEON
/* Sixteen outputs, four accumulators, and the taps taken from a register lane.
 *
 * A tap is one weight times a contiguous run. Written with the scalar form the weight arrives in a
 * general register and has to be moved into a NEON lane before the multiply, which on this in-order
 * core is a stall of about eight cycles on the critical path of every tap: the 7 by 7 convolution
 * measured four times its arithmetic. Loading four taps at once into a quadword and multiplying by
 * lane removes the move entirely, four taps per load instead of one move per tap. The accumulation
 * order is unchanged, so the result is bit for bit what the scalar form produced.
 *
 * Four accumulators give the multiply-add's eight cycle latency four independent chains to hide in.
 */
#define ZF_DW_LANES 16

/* ZF_CONV_ORT applies here too, for a reason the matmul fix does not reach.
 *
 * The depthwise runs in these kernels, not through zf_matmul_nt4x4_f32, so the order work done on
 * the matmul cannot touch it. And it has its own divergence: it SEEDS each accumulator with the
 * bias, where MLAS accumulates the taps from +0.0 and adds the bias at the end. `b + t0 + t1 + ...`
 * and `(t0 + t1 + ...) + b` are not the same float.
 *
 * Measured against the device trace on the front end's 7 by 7 depthwise, on the 51,072 outputs
 * whose receptive field lies inside tensors the trace actually carries:
 *
 *   sequential over taps, bias LAST      51,072 of 51,072   100.00 %
 *   sequential over taps, bias FIRST     12,936              25.33 %
 *   four accumulators pairwise, bias first  11,476           22.47 %
 *   four accumulators pairwise, bias last   15,591           30.53 %
 *
 * (The other 7,296 outputs are the three rows that read embed_states, which the trace captured
 * after the chunk rather than before. Every one of the other twenty one rows is 128 of 128.)
 *
 * So the sixteen wide block needs only its seed moved: a0 to a3 already hold sixteen DIFFERENT
 * outputs, each summed straight up the taps. The four wide tail needs more, because there a0 to a3
 * are four partial sums of the SAME outputs, combined pairwise at the end, and that is the wrong
 * order whatever the bias does. It gets one accumulator instead, which is slower per output and
 * runs on at most three columns of a row. */

#define ZF_DW_TAP(lanes, lane)                                    \
  do {                                                            \
    a0 = vmlaq_lane_f32(a0, vld1q_f32(p), (lanes), (lane));        \
    a1 = vmlaq_lane_f32(a1, vld1q_f32(p + 4), (lanes), (lane));    \
    a2 = vmlaq_lane_f32(a2, vld1q_f32(p + 8), (lanes), (lane));    \
    a3 = vmlaq_lane_f32(a3, vld1q_f32(p + 12), (lanes), (lane));   \
    ++p;                                                          \
  } while (0)

static inline void dw_block16(const float *s, const float *w, int taps, float b, float *y) {
  const int bias_last = zf_conv_ort_order();
  const float32x4_t seed = vdupq_n_f32(bias_last ? 0.0f : b);
  float32x4_t a0 = seed, a1 = seed, a2 = seed, a3 = seed;
  const float *p = s;
  int j = 0;
  for (; j + 4 <= taps; j += 4) {
    const float32x4_t wv = vld1q_f32(w + j);
    const float32x2_t wl = vget_low_f32(wv), wh = vget_high_f32(wv);
    ZF_DW_TAP(wl, 0);
    ZF_DW_TAP(wl, 1);
    ZF_DW_TAP(wh, 0);
    ZF_DW_TAP(wh, 1);
  }
  for (; j < taps; ++j) {
    const float32x2_t wl = vld1_dup_f32(w + j);
    ZF_DW_TAP(wl, 0);
  }
  if (bias_last) {
    const float32x4_t bv = vdupq_n_f32(b);
    a0 = vaddq_f32(a0, bv);
    a1 = vaddq_f32(a1, bv);
    a2 = vaddq_f32(a2, bv);
    a3 = vaddq_f32(a3, bv);
  }
  vst1q_f32(y, a0);
  vst1q_f32(y + 4, a1);
  vst1q_f32(y + 8, a2);
  vst1q_f32(y + 12, a3);
}

/* The same over four outputs, for the tail of a row. `count` says how many to keep. */
static inline void dw_block4(const float *s, const float *w, int taps, float b, float *y,
                             int count) {
  float32x4_t sum;
  if (zf_conv_ort_order()) {
    float32x4_t a0 = vdupq_n_f32(0.0f);
    for (int j = 0; j < taps; ++j) a0 = vmlaq_n_f32(a0, vld1q_f32(s + j), w[j]);
    sum = vaddq_f32(a0, vdupq_n_f32(b));
    if (count >= 4) {
      vst1q_f32(y, sum);
    } else {
      float tmp[4];
      vst1q_f32(tmp, sum);
      for (int t = 0; t < count; ++t) y[t] = tmp[t];
    }
    return;
  }
  float32x4_t a0 = vdupq_n_f32(b), a1 = vdupq_n_f32(0.0f), a2 = a1, a3 = a1;
  int j = 0;
  for (; j + 4 <= taps; j += 4) {
    const float32x4_t wv = vld1q_f32(w + j);
    const float32x2_t wl = vget_low_f32(wv), wh = vget_high_f32(wv);
    a0 = vmlaq_lane_f32(a0, vld1q_f32(s + j), wl, 0);
    a1 = vmlaq_lane_f32(a1, vld1q_f32(s + j + 1), wl, 1);
    a2 = vmlaq_lane_f32(a2, vld1q_f32(s + j + 2), wh, 0);
    a3 = vmlaq_lane_f32(a3, vld1q_f32(s + j + 3), wh, 1);
  }
  for (; j < taps; ++j) a0 = vmlaq_lane_f32(a0, vld1q_f32(s + j), vld1_dup_f32(w + j), 0);
  sum = vaddq_f32(vaddq_f32(a0, a1), vaddq_f32(a2, a3));
  if (count >= 4) {
    vst1q_f32(y, sum);
  } else {
    float tmp[4];
    vst1q_f32(tmp, sum);
    for (int t = 0; t < count; ++t) y[t] = tmp[t];
  }
}

/* One padded row of outputs, whole blocks first and then the tail. */
static inline void dw_line(const float *s, const float *w, int taps, float b, float *y,
                           int count) {
  int p = 0;
  for (; p + ZF_DW_LANES <= count; p += ZF_DW_LANES) dw_block16(s + p, w, taps, b, y + p);
  for (; p < count; p += 4) {
    int left = count - p;
    if (left > 4) left = 4;
    dw_block4(s + p, w, taps, b, y + p, left);
  }
}
#endif

void zf_conv_dw1d_f32(const float *x, int channels, int length, int ldx, const float *w, int taps,
                      int stride, int pad_left, const float *bias, float *y, int out_length,
                      int c0, int c1) {
  (void)channels;
  if (ldx < length) ldx = length;
  float scratch[ZF_DW_SCRATCH];
  const int padded = length + 2 * pad_left;
  const int need = padded + ZF_DW_LANES + 4;
  const int fast = (stride == 1 && need <= ZF_DW_SCRATCH && out_length + taps - 1 <= padded &&
                    (pad_left > 0 || out_length + taps - 1 <= length));
#if ZF_NEON
  /* Only [pad_left, pad_left + length) is ever written, so the padding and the slack past the end
   * stay zero for every channel: they are zeroed once rather than once a channel. With 128 channels
   * to a task and a 53 float window that was fifty times the zeroing the work needed. */
  if (fast && pad_left > 0) memset(scratch, 0, (size_t)need * sizeof(float));
#endif
  for (int c = c0; c < c1; ++c) {
    const float *xc = x + (size_t)c * ldx;
    const float *wc = w + (size_t)c * taps;
    float *yc = y + (size_t)c * out_length;
    const float b = bias ? bias[c] : 0.0f;
#if ZF_NEON
    if (fast) {
      if (pad_left == 0) {
        /* The causal convolutions pass the whole window and pad nothing, and a block never reads
         * past its last output's last tap, so the input is the source. Half the depthwise calls in
         * the encoder are these, and each was copying its row into a zeroed scratch first. */
        dw_line(xc, wc, taps, b, yc, out_length);
        continue;
      }
      /* the window's own values; the padding around them was zeroed once, before the loop */
      memcpy(scratch + pad_left, xc, (size_t)length * sizeof(float));
      dw_line(scratch, wc, taps, b, yc, out_length);
      continue;
    }
#else
    (void)fast;
    (void)need;
    (void)scratch;
#endif
    for (int p = 0; p < out_length; ++p) {
      const int base = p * stride - pad_left;
      int lo = -base;
      if (lo < 0) lo = 0;
      int hi = length - base;
      if (hi > taps) hi = taps;
      const int bias_last = zf_conv_ort_order();
      float sum = bias_last ? 0.0f : b;
      for (int j = lo; j < hi; ++j) sum += xc[base + j] * wc[j];
      yc[p] = bias_last ? sum + b : sum;
    }
  }
}

#if ZF_NEON
/* ZF_DW_TAIL_ROWS=0 puts back the sixteen wide tail, for timing; the values are the same. */
static int dw_tail_rows(void) {
  static _Atomic int on = -1;
  if (on < 0) {
    const char *v = zf_getenv("ZF_DW_TAIL_ROWS");
    on = v ? atoi(v) : 1;
  }
  return on;
}
#endif

void zf_conv_dw2d_f32(const float *x, int channels, int h, int w_in, const float *weights, int kh,
                      int kw, int stride_h, int stride_w, int pad_top, int pad_left,
                      const float *bias, float *y, int out_h, int out_w, int c0, int c1) {
  (void)channels;
  float scratch[ZF_DW_SCRATCH];
  const int wp = w_in + 2 * pad_left + ZF_DW_LANES + 4; /* slack so a block can read past the row */
  const int hp = h + 2 * pad_top;
  const int fast = (stride_w == 1 && stride_h == 1 && (size_t)hp * wp <= ZF_DW_SCRATCH &&
                    out_w + kw - 1 <= w_in + 2 * pad_left && out_h + kh - 1 <= hp);
#if ZF_NEON
  /* Every channel writes the same window of the same rows, so what surrounds it stays zero. */
  if (fast) memset(scratch, 0, (size_t)hp * wp * sizeof(float));
#endif
  for (int c = c0; c < c1; ++c) {
    const float *xc = x + (size_t)c * h * w_in;
    const float *wc = weights + (size_t)c * kh * kw;
    float *yc = y + (size_t)c * out_h * out_w;
    const float b = bias ? bias[c] : 0.0f;
#if ZF_NEON
    if (fast) {
      for (int row = 0; row < h; ++row)
        memcpy(scratch + (size_t)(row + pad_top) * wp + pad_left, xc + (size_t)row * w_in,
               (size_t)w_in * sizeof(float));
      for (int oy = 0; oy < out_h; ++oy) {
        float *out_row = yc + (size_t)oy * out_w;
        /* Sixteen outputs where the row allows it, with four accumulators held across every row
         * of the kernel so an output is written once, and the taps taken from a register lane. */
        const int bias_last = zf_conv_ort_order();
        int ox = 0;
        for (; ox + ZF_DW_LANES <= out_w; ox += ZF_DW_LANES) {
          const float32x4_t seed = vdupq_n_f32(bias_last ? 0.0f : b);
          float32x4_t a0 = seed, a1 = seed, a2 = seed, a3 = seed;
          for (int dy = 0; dy < kh; ++dy) {
            const float *p = scratch + (size_t)(oy + dy) * wp + ox;
            const float *wr = wc + (size_t)dy * kw;
            int dx = 0;
            for (; dx + 4 <= kw; dx += 4) {
              const float32x4_t wv = vld1q_f32(wr + dx);
              const float32x2_t wl = vget_low_f32(wv), wh = vget_high_f32(wv);
              ZF_DW_TAP(wl, 0);
              ZF_DW_TAP(wl, 1);
              ZF_DW_TAP(wh, 0);
              ZF_DW_TAP(wh, 1);
            }
            for (; dx < kw; ++dx) {
              const float32x2_t wl = vld1_dup_f32(wr + dx);
              ZF_DW_TAP(wl, 0);
            }
          }
          if (bias_last) {
            const float32x4_t bv = vdupq_n_f32(b);
            a0 = vaddq_f32(a0, bv);
            a1 = vaddq_f32(a1, bv);
            a2 = vaddq_f32(a2, bv);
            a3 = vaddq_f32(a3, bv);
          }
          vst1q_f32(out_row + ox, a0);
          vst1q_f32(out_row + ox + 4, a1);
          vst1q_f32(out_row + ox + 8, a2);
          vst1q_f32(out_row + ox + 12, a3);
        }
        if (bias_last && ox < out_w && dw_tail_rows()) continue; /* taken four rows at a time below */
        for (; ox < out_w; ox += 4) {
          float32x4_t sum;
          if (bias_last) {
            /* Run the SIXTEEN wide kernel over the tail into a scratch of sixteen and keep the
             * columns that exist.
             *
             * The obvious tail, one accumulator summed straight up the taps, has the right order
             * but is a 49 deep dependent chain of multiply-adds on an in-order core: about four
             * times the work per column. The wide kernel already has the right order, because its
             * four accumulators hold four DIFFERENT outputs rather than partial sums of the same
             * one, so the only thing standing in the way is that fewer than sixteen columns remain.
             * Computing sixteen and discarding the surplus costs at most thirteen wasted columns
             * once a row and keeps the latency hidden.
             *
             * Reading past out_w is safe here and only here: this path always reads `scratch`,
             * whose row stride carries ZF_DW_LANES + 4 floats of zeroed slack for exactly this.
             * The one dimensional dw_line cannot do the same, because with pad_left == 0 it reads
             * the caller's input buffer directly and there is no slack past it. */
            float tmp[ZF_DW_LANES];
            const float32x4_t seed = vdupq_n_f32(0.0f);
            float32x4_t a0 = seed, a1 = seed, a2 = seed, a3 = seed;
            for (int dy = 0; dy < kh; ++dy) {
              const float *p = scratch + (size_t)(oy + dy) * wp + ox;
              const float *wr = wc + (size_t)dy * kw;
              int dx = 0;
              for (; dx + 4 <= kw; dx += 4) {
                const float32x4_t wv = vld1q_f32(wr + dx);
                const float32x2_t wl = vget_low_f32(wv), wh = vget_high_f32(wv);
                ZF_DW_TAP(wl, 0);
                ZF_DW_TAP(wl, 1);
                ZF_DW_TAP(wh, 0);
                ZF_DW_TAP(wh, 1);
              }
              for (; dx < kw; ++dx) {
                const float32x2_t wl = vld1_dup_f32(wr + dx);
                ZF_DW_TAP(wl, 0);
              }
            }
            {
              const float32x4_t bv = vdupq_n_f32(b);
              vst1q_f32(tmp, vaddq_f32(a0, bv));
              vst1q_f32(tmp + 4, vaddq_f32(a1, bv));
              vst1q_f32(tmp + 8, vaddq_f32(a2, bv));
              vst1q_f32(tmp + 12, vaddq_f32(a3, bv));
            }
            for (int t = 0; t < ZF_DW_LANES && ox + t < out_w; ++t) out_row[ox + t] = tmp[t];
            break;
          }
          float32x4_t a0 = vdupq_n_f32(b), a1 = vdupq_n_f32(0.0f), a2 = a1, a3 = a1;
          for (int dy = 0; dy < kh; ++dy) {
            const float *s2 = scratch + (size_t)(oy + dy) * wp + ox;
            const float *wr = wc + (size_t)dy * kw;
            int dx = 0;
            for (; dx + 4 <= kw; dx += 4) {
              const float32x4_t wv = vld1q_f32(wr + dx);
              const float32x2_t wl = vget_low_f32(wv), wh = vget_high_f32(wv);
              a0 = vmlaq_lane_f32(a0, vld1q_f32(s2 + dx), wl, 0);
              a1 = vmlaq_lane_f32(a1, vld1q_f32(s2 + dx + 1), wl, 1);
              a2 = vmlaq_lane_f32(a2, vld1q_f32(s2 + dx + 2), wh, 0);
              a3 = vmlaq_lane_f32(a3, vld1q_f32(s2 + dx + 3), wh, 1);
            }
            for (; dx < kw; ++dx)
              a0 = vmlaq_lane_f32(a0, vld1q_f32(s2 + dx), vld1_dup_f32(wr + dx), 0);
          }
          sum = vaddq_f32(vaddq_f32(a0, a1), vaddq_f32(a2, a3));
          if (ox + 4 <= out_w) {
            vst1q_f32(out_row + ox, sum);
          } else {
            float tmp[4];
            vst1q_f32(tmp, sum);
            for (int t = 0; ox + t < out_w; ++t) out_row[ox + t] = tmp[t];
          }
        }
      }
      /* The row tails, in ONNX Runtime's order, four OUTPUT ROWS at a time.
       *
       * One tail's columns summed straight up the taps is one 49 deep chain of dependent
       * multiply-adds, which is why the tail above ran the sixteen wide block and threw thirteen
       * columns away: for this front end's 19 wide rows that made every row cost two blocks. Four
       * rows' tails are four independent chains of the same kind, each lane still one output summed
       * up its own taps from +0.0 with the bias last, so the order is untouched and the latency is
       * hidden at a quarter of the multiply-adds. Rows past out_h repeat the last row and are not
       * stored. Reading up to three columns past out_w is safe for the reason given above. */
      if (zf_conv_ort_order() && dw_tail_rows()) {
        const int ox0 = out_w - out_w % ZF_DW_LANES;
        const float32x4_t bv = vdupq_n_f32(b);
        for (int ox = ox0; ox < out_w; ox += 4) {
          for (int oy = 0; oy < out_h; oy += 4) {
            const float *base[4];
            for (int r = 0; r < 4; ++r) {
              const int yy = oy + r < out_h ? oy + r : out_h - 1;
              base[r] = scratch + (size_t)yy * wp + ox;
            }
            float32x4_t a0 = vdupq_n_f32(0.0f), a1 = a0, a2 = a0, a3 = a0;
            for (int dy = 0; dy < kh; ++dy) {
              const float *q0 = base[0] + (size_t)dy * wp, *q1 = base[1] + (size_t)dy * wp;
              const float *q2 = base[2] + (size_t)dy * wp, *q3 = base[3] + (size_t)dy * wp;
              const float *wr = wc + (size_t)dy * kw;
              for (int dx = 0; dx < kw; ++dx) {
                const float32x2_t wl = vld1_dup_f32(wr + dx);
                a0 = vmlaq_lane_f32(a0, vld1q_f32(q0 + dx), wl, 0);
                a1 = vmlaq_lane_f32(a1, vld1q_f32(q1 + dx), wl, 0);
                a2 = vmlaq_lane_f32(a2, vld1q_f32(q2 + dx), wl, 0);
                a3 = vmlaq_lane_f32(a3, vld1q_f32(q3 + dx), wl, 0);
              }
            }
            float tmp[4][4];
            vst1q_f32(tmp[0], vaddq_f32(a0, bv));
            vst1q_f32(tmp[1], vaddq_f32(a1, bv));
            vst1q_f32(tmp[2], vaddq_f32(a2, bv));
            vst1q_f32(tmp[3], vaddq_f32(a3, bv));
            for (int r = 0; r < 4 && oy + r < out_h; ++r)
              for (int t = 0; t < 4 && ox + t < out_w; ++t)
                yc[(size_t)(oy + r) * out_w + ox + t] = tmp[r][t];
          }
        }
      }
      continue;
    }
#else
    (void)fast;
    (void)scratch;
#endif
    for (int oy = 0; oy < out_h; ++oy) {
      for (int ox = 0; ox < out_w; ++ox) {
        const int bias_last = zf_conv_ort_order();
        float sum = bias_last ? 0.0f : b;
        for (int dy = 0; dy < kh; ++dy) {
          const int sy = oy * stride_h + dy - pad_top;
          if (sy < 0 || sy >= h) continue;
          const float *src = xc + (size_t)sy * w_in;
          for (int dx = 0; dx < kw; ++dx) {
            const int sx = ox * stride_w + dx - pad_left;
            if (sx >= 0 && sx < w_in) sum += src[sx] * wc[(size_t)dy * kw + dx];
          }
        }
        yc[(size_t)oy * out_w + ox] = bias_last ? sum + b : sum;
      }
    }
  }
}

void zf_conv_dequantize_pixels(const ZfConvS8 *c, const int32_t *acc, int pixels, int count,
                               int p0, float a_scale, float *y) {
  deq_transpose(c, acc, c->out_channels, pixels, count, p0, a_scale, y, 0, c->out_channels);
}

/* fp32 im2col for one band of output rows, one row per output pixel at stride k.
 *
 * Same traversal and the same (c, dy, dx) ordering as the int8 gather above, so an fp32 weight laid
 * out as [out_channels, in_channels * kh * kw] lines up without a permutation. Padding is a true
 * zero rather than an activation zero point, because fp32 has none.
 *
 * `in_pixel_major` says how the input is laid out: NCHW, or one contiguous row of channels per
 * pixel, which is what the previous convolution produces when it wrote a pixel-major result. */
/* ZF_CONV_ORT: sum the fp32 convolutions the way ONNX Runtime does on this phone.
 *
 * Two things have to match, not one. MLAS accumulates strictly sequentially over k from +0.0, and
 * it sums in ONNX's k order, which is (channel, dy, dx) because that is how the weight is stored.
 * Both were checked against a trace taken from ONNX Runtime ON THE DEVICE, each convolution fed
 * the reference's own recorded input:
 *
 *   conv.0, k = 9    sequential, (channel, dy, dx)   37,760 of 37,760   100.00 %
 *                    pairwise two-wide, as shipped   21,154              56.02 %
 *   conv.4, k = 72   sequential, (channel, dy, dx)   36,192 of 36,192   100.00 %
 *                    sequential, (dy, dx, channel)    7,490              20.70 %
 *
 * That last row is why forcing the accumulation order alone did nothing. conv1 and conv2 read a
 * pixel-major input and have their weights permuted to a (dy, dx, channel) k axis so that one tap
 * is a contiguous run of `cin` floats; a sequential sum in the wrong order is still the wrong sum.
 *
 * Every reference in this repository before this one came from x86, which is why six earlier
 * "exact" kernels each measured worse: a polynomial is the same on both machines and an
 * accumulation order is not. */
static int zf_conv_ort_order(void) {
  static _Atomic int on = -1;
  if (on < 0) {
    const char *v = zf_getenv("ZF_CONV_ORT");
    on = v && atoi(v);
  }
  return on;
}

static void im2col_rows_f32(const ZfConvS8 *c, const float *x, int h, int w, int k, float *rows,
                            int oy0, int oy1, int in_pixel_major) {
  const int out_w = zf_conv_out_w(c, w);
  const int taps = c->kw;
  const int cin = c->in_channels;
  for (int oy = oy0; oy < oy1; ++oy) {
    for (int ox = 0; ox < out_w; ++ox) {
      float *row = rows + (size_t)(oy * out_w + ox) * k;
      const int y0 = oy * c->stride_h - c->pad_top;
      const int x0 = ox * c->stride_w - c->pad_left;
      if (in_pixel_major && !zf_conv_ort_order()) {
        /* k is (dy, dx, channel) here, so one tap is a contiguous run of `cin` floats and the whole
         * gather is kh*kw copies. The other ordering against a pixel-major input is one strided
         * load per element, which is what this path used to do. The weight is permuted to match at
         * load, by zf_weights_reorder_conv_k_f32. */
        int at = 0;
        for (int dy = 0; dy < c->kh; ++dy) {
          const int y = y0 + dy;
          for (int dx = 0; dx < taps; ++dx, at += cin) {
            const int xx = x0 + dx;
            if (y < 0 || y >= h || xx < 0 || xx >= w) {
              memset(row + at, 0, (size_t)cin * sizeof(float));
              continue;
            }
            memcpy(row + at, x + ((size_t)y * w + xx) * cin, (size_t)cin * sizeof(float));
          }
        }
      } else if (in_pixel_major) {
        /* ONNX's k order, (channel, dy, dx), read out of a pixel-major input. Float addition is
         * not associative, so a convolution that sums its taps in a different order than the
         * reference is a different number however carefully it accumulates, which is why this
         * order has to be produced even though the input is laid out against it.
         *
         * Written the obvious way, with the destination index running, the innermost step is dx
         * and the source stride is `cin`: for conv2 that is 288 loads a pixel, each 128 bytes from
         * the last, over an input of about 123 KB. Taking the taps outermost instead reads a
         * contiguous run of `cin` floats and writes at a stride of kh*kw, which inverts which side
         * is strided. That is the better way round here: the row being written is k floats, 1152
         * bytes for conv2, so it stays in L1 across all nine taps, while the input it reads is far
         * too big to stride through nine times.
         *
         * The values and their positions are identical either way. Only the traversal changes. */
        const int khkw = c->kh * taps;
        for (int dy = 0; dy < c->kh; ++dy) {
          const int y = y0 + dy;
          for (int dx = 0; dx < taps; ++dx) {
            const int xx = x0 + dx;
            float *dst = row + dy * taps + dx;
            if (y < 0 || y >= h || xx < 0 || xx >= w) {
              for (int ch = 0; ch < cin; ++ch) dst[(size_t)ch * khkw] = 0.0f;
              continue;
            }
            const float *src = x + ((size_t)y * w + xx) * cin;
            for (int ch = 0; ch < cin; ++ch) dst[(size_t)ch * khkw] = src[ch];
          }
        }
      } else {
        int at = 0;
        for (int ch = 0; ch < cin; ++ch) {
          for (int dy = 0; dy < c->kh; ++dy, at += taps) {
            const int y = y0 + dy;
            if (y < 0 || y >= h) {
              memset(row + at, 0, (size_t)taps * sizeof(float));
              continue;
            }
            for (int dx = 0; dx < taps; ++dx) {
              const int xx = x0 + dx;
              row[at + dx] = (xx >= 0 && xx < w) ? x[((size_t)ch * h + y) * w + xx] : 0.0f;
            }
          }
        }
      }
    }
  }
}

void zf_conv_f32(const ZfConvS8 *c, const float *weight, const float *x, int h, int w, float *rows,
                 float *y, int in_pixel_major, int out_pixel_major, int oy0, int oy1) {
  const int out_w = zf_conv_out_w(c, w);
  const int out_h = zf_conv_out_h(c, h);
  const int n = c->out_channels;
  const int k = c->in_channels * c->kh * c->kw;
  if (oy0 >= oy1) return;
  im2col_rows_f32(c, x, h, w, k, rows, oy0, oy1, in_pixel_major);

  const int p0 = oy0 * out_w;
  const int pixels = (oy1 - oy0) * out_w;
  if (out_pixel_major) {
    float *dst = y + (size_t)p0 * n;
    zf_matmul_nt4x4_f32(rows + (size_t)p0 * k, k, weight, k, pixels, n, k, dst, n);
    if (c->bias)
      for (int p = 0; p < pixels; ++p) {
        float *o = dst + (size_t)p * n;
        for (int j = 0; j < n; ++j) o[j] += c->bias[j];
      }
    return;
  }
  /* NCHW out: the matmul is pixel-major by nature, so it lands in the scratch past the im2col and
   * is transposed out one channel at a time. Each band writes at its OWN pixel offset in that
   * scratch, which is what lets this case be threaded: the bands are disjoint in p, so they are
   * disjoint in the slab too. Getting this wrong cost conv2 an 8.6x, because it was the only
   * convolution with an NCHW output and so the only one pinned to one thread. */
  {
    float *tmp = rows + (size_t)out_h * out_w * k + (size_t)p0 * n;
    zf_matmul_nt4x4_f32(rows + (size_t)p0 * k, k, weight, k, pixels, n, k, tmp, n);
    for (int j = 0; j < n; ++j) {
      float *plane = y + (size_t)j * out_h * out_w + p0;
      const float b = c->bias ? c->bias[j] : 0.0f;
      for (int p = 0; p < pixels; ++p) plane[p] = tmp[(size_t)p * n + j] + b;
    }
  }
}
