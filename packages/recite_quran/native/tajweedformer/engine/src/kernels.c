#include "zf/kernels.h"
#include "zf/env.h"
#include "zf/libm.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "zf/neon.h"
#define ZF_NEON ZF_NEON_AVAILABLE

/* ZF_QUANT_DIVIDE: quantise by dividing, as ONNX Runtime does, instead of by a reciprocal.
 *
 * The engine computes inv = 1/scale once and multiplies, which is the obvious thing when a divide
 * is ten cycles and a multiply is one. It is not the same arithmetic. The reciprocal is itself
 * rounded, so x * fl(1/s) and fl(x/s) fall on opposite sides of a rounding boundary now and then,
 * and the quantiser commits them to different int8 codes. Over the traced chunk's 274 quantisers
 * and 878,016 values, dividing reproduces the reference's codes exactly and the reciprocal gets
 * one wrong.
 *
 * With it on, the linear rewrite is bit exact: `ZfLinearS8` alone, every other op left to ONNX
 * Runtime, decodes all 78 subset clips token for token. That is the only configuration of this
 * engine measured at zero divergence.
 *
 * It is off by default because it does not pay yet. It costs 2.74 ms a chunk, 3.6 per cent, and
 * on its own it moves the whole engine's divergence not at all: 12 edits with it, 12 without,
 * because the convolutions, the swoosh, the sigmoid and the attention softmax are still
 * approximating and a faithful kernel fed by an unfaithful one measures as noise. Turn it on as
 * part of making all of them exact, not before.
 *
 * The same defect is still in zf_recipq_f32, which refines a reciprocal estimate with two Newton
 * steps and feeds sigmoid, tanh and the softmax. MLAS ends those in a real divide. */
#ifndef ZF_QUANT_DIVIDE
#define ZF_QUANT_DIVIDE 0
#endif

#define ZF_QINV(scale) ((scale) != 0.0f ? 1.0f / (scale) : 0.0f)
#if ZF_QUANT_DIVIDE
#define ZF_QSCALE_S(v, s, inv) ((void)(inv), (v) / (s))
#else
#define ZF_QSCALE_S(v, s, inv) ((void)(s), (v) * (inv))
#endif


static void quantize_params(const float *x, size_t n, float *scale_out, int *zp_out) {
  float lo = 0.0f, hi = 0.0f; /* ONNX includes zero in the range */
  size_t i = 0;
#if ZF_NEON
  if (n >= 16) {
    float32x4_t l0 = vdupq_n_f32(0.0f), l1 = l0, h0 = l0, h1 = l0;
    for (; i + 8 <= n; i += 8) {
      const float32x4_t a = vld1q_f32(x + i), b = vld1q_f32(x + i + 4);
      l0 = vminq_f32(l0, a);
      l1 = vminq_f32(l1, b);
      h0 = vmaxq_f32(h0, a);
      h1 = vmaxq_f32(h1, b);
    }
    const float32x2_t lp = vpmin_f32(vget_low_f32(vminq_f32(l0, l1)),
                                     vget_high_f32(vminq_f32(l0, l1)));
    const float32x2_t hp = vpmax_f32(vget_low_f32(vmaxq_f32(h0, h1)),
                                     vget_high_f32(vmaxq_f32(h0, h1)));
    lo = vget_lane_f32(vpmin_f32(lp, lp), 0);
    hi = vget_lane_f32(vpmax_f32(hp, hp), 0);
  }
#endif
  for (; i < n; ++i) {
    if (x[i] < lo) lo = x[i];
    if (x[i] > hi) hi = x[i];
  }
  float scale = (hi - lo) / 255.0f;
  if (!(scale > 0.0f)) scale = 1.0f;
  float zp_f = nearbyintf(-lo / scale);
  if (zp_f < 0.0f) zp_f = 0.0f;
  if (zp_f > 255.0f) zp_f = 255.0f;
  *scale_out = scale;
  *zp_out = (int)zp_f;
}

void zf_dynamic_quantize_u8(const float *x, size_t n, uint8_t *q, float *scale_out, int *zp_out) {
  quantize_params(x, n, scale_out, zp_out);
  const float sc = *scale_out, inv = ZF_QINV(sc);
  const float zp = (float)*zp_out;
  for (size_t i = 0; i < n; ++i) {
    float v = nearbyintf(ZF_QSCALE_S(x[i], sc, inv)) + zp;
    if (v < 0.0f) v = 0.0f;
    if (v > 255.0f) v = 255.0f;
    q[i] = (uint8_t)v;
  }
}

/* Shifting the uint8 activations to int8 by subtracting 128 lets the kernel use signed 8-bit
 * multiplies on identical integers, because the constant shift folds into the correction:
 *   sum_k (a - zp) * w  =  sum_k (a - 128) * w  +  (128 - zp) * sum_k w
 * so each output unit needs nothing beyond its precomputed weight row sum. */
/* 1.5 * 2^23: adding then subtracting it rounds half to even in the default rounding mode, which
 * is what ONNX specifies and what ARMv7 NEON has no instruction for. */
#define ZF_ROUND_MAGIC 12582912.0f

#if ZF_NEON
/* x / scale, correctly rounded, without a divide.
 *
 * ARMv7 NEON has no vector float divide, so the obvious exact implementation is four lane by lane
 * VDIV.F32, which are about ten cycles each and do not pipeline. This is the classic fused
 * correction instead:
 *
 *   q0 = x * inv          with inv = 1/s rounded once, hoisted out of the loop
 *   r  = x - s*q0         fused, so the residual is exact
 *   q  = q0 + r*inv       fused
 *
 * and the result is the correctly rounded quotient. Checked against fl(x/s) over the traced
 * chunk's 274 quantisers and 878,016 values: identical on every one, where multiplying by the
 * reciprocal alone differs on 232,261 of them.
 *
 * One multiply and two fused multiply-adds, all pipelined, against four serialised divides. The
 * fused pair is inline assembly for the same reason the exponential's is: -mfpu=neon leaves
 * __ARM_FEATURE_FMA undefined so that the compiler cannot contract anything else, and block.h
 * fails the build if it ever becomes defined. It does mean this path needs VFPv4, which every
 * ARMv8 core in AArch32 has. */
static inline float32x4_t zf_vfma_q(float32x4_t acc, float32x4_t a, float32x4_t b)
    __attribute__((unused));
static inline float32x4_t zf_vfma_q(float32x4_t acc, float32x4_t a, float32x4_t b) {
#if ZF_NEON_A64
  return vfmaq_f32(acc, a, b); /* FMA is base AArch64; the intrinsic is the instruction */
#else
  __asm__(".fpu neon-vfpv4\n\tvfma.f32 %q0, %q1, %q2" : "+w"(acc) : "w"(a), "w"(b));
  return acc;
#endif
}

/* VRECPS as the Alcatel executes it, on every ABI.
 *
 * In AArch32, which is what the Alcatel runs, VRECPS is FPRecipStep: the product a * b is rounded,
 * then subtracted from 2.0, and infinity times zero gives exactly 2.0. AArch64's FRECPS is
 * FPRecipStepFused, one rounding. Eigen's ARMv7 divide, and the reciprocal estimates the engine
 * refines, take two of these per value, so on AArch64 the fused one moved the log kernel's output
 * and with it the whole front end. This is the AArch32 definition written out; FPCR already carries
 * ARMv7 NEON's flush-to-zero and default NaN on the engine's threads (zf_fp_enter). */
static inline float32x4_t zf_recpsq(float32x4_t a, float32x4_t b) {
#if ZF_NEON_A64
  const float32x4_t r = vsubq_f32(vdupq_n_f32(2.0f), vmulq_f32(a, b));
  const uint32x4_t ia = vceqq_f32(vabsq_f32(a), vdupq_n_f32(__builtin_inff()));
  const uint32x4_t ib = vceqq_f32(vabsq_f32(b), vdupq_n_f32(__builtin_inff()));
  const uint32x4_t za = vceqq_f32(a, vdupq_n_f32(0.0f)), zb = vceqq_f32(b, vdupq_n_f32(0.0f));
  const uint32x4_t two = vorrq_u32(vandq_u32(ia, zb), vandq_u32(za, ib));
  return vbslq_f32(two, vdupq_n_f32(2.0f), r);
#else
  return vrecpsq_f32(a, b);
#endif
}

static inline float32x4_t zf_vfms_q(float32x4_t acc, float32x4_t a, float32x4_t b)
    __attribute__((unused));
static inline float32x4_t zf_vfms_q(float32x4_t acc, float32x4_t a, float32x4_t b) {
#if ZF_NEON_A64
  return vfmsq_f32(acc, a, b);
#else
  __asm__(".fpu neon-vfpv4\n\tvfms.f32 %q0, %q1, %q2" : "+w"(acc) : "w"(a), "w"(b));
  return acc;
#endif
}

/* s is the scale, inv its reciprocal; the caller hoists both. */
static inline float32x4_t zf_divq_f32(float32x4_t x, float32x4_t s, float32x4_t inv)
    __attribute__((unused));
static inline float32x4_t zf_divq_f32(float32x4_t x, float32x4_t s, float32x4_t inv) {
  const float32x4_t q0 = vmulq_f32(x, inv);
  const float32x4_t r = zf_vfms_q(x, s, q0);
  return zf_vfma_q(q0, r, inv);
}

/* The quantisers take whichever of the two this build selected: the scale itself to divide by, or
 * its reciprocal to multiply by. The caller computes it once per tensor with ZF_QSCALE_PRE. */
static inline float32x4_t zf_qscale_q(float32x4_t v, float32x4_t s, float32x4_t inv) {
#if ZF_QUANT_DIVIDE
  return zf_divq_f32(v, s, inv);
#else
  (void)s;
  return vmulq_f32(v, inv);
#endif
}
#endif

static void quantize_into_shifted(const float *x, size_t n, int8_t *q, float scale, int zp) {
  const float qinv = ZF_QINV(scale);
  size_t i = 0;
#if ZF_NEON
  /* ARMv7 NEON has no round-to-nearest-even instruction (VRINTN arrived with ARMv8), but adding
   * and then subtracting 1.5 * 2^23 rounds exactly that way in the default rounding mode, and
   * x * inv is bounded by 255 here, so it is always in range for the trick. The saturating
   * narrowing stores then apply ONNX's clamp for free: rounding plus (zp - 128), saturated to
   * int8, is the same integer as clamping to [0, 255] and subtracting 128. */
  const float32x4_t vsc = vdupq_n_f32(scale), vinv = vdupq_n_f32(qinv);
  const float32x4_t magic = vdupq_n_f32(12582912.0f);
  const int32x4_t shift = vdupq_n_s32(zp - 128);
  for (; i + 16 <= n; i += 16) {
    int16x4_t h[4];
    for (int b = 0; b < 4; ++b) {
      const float32x4_t v = zf_qscale_q(vld1q_f32(x + i + (size_t)b * 4), vsc, vinv);
      const float32x4_t r = vsubq_f32(vaddq_f32(v, magic), magic);
      h[b] = vqmovn_s32(vaddq_s32(vcvtq_s32_f32(r), shift));
    }
    vst1_s8(q + i, vqmovn_s16(vcombine_s16(h[0], h[1])));
    vst1_s8(q + i + 8, vqmovn_s16(vcombine_s16(h[2], h[3])));
  }
#endif
  {
    const float zpf = (float)zp;
    for (; i < n; ++i) {
      float v = nearbyintf(ZF_QSCALE_S(x[i], scale, qinv)) + zpf;
      if (v < 0.0f) v = 0.0f;
      if (v > 255.0f) v = 255.0f;
      q[i] = (int8_t)((int)v - 128);
    }
  }
}

void zf_dynamic_quantize_shifted(const float *x, size_t n, int8_t *q, float *scale_out,
                                 int *zp_out) {
  quantize_params(x, n, scale_out, zp_out);
  quantize_into_shifted(x, n, q, *scale_out, *zp_out);
}

void zf_quantize_range_rows(const float *x, int k, float *lo, float *hi, int row0, int row1) {
  float l = 0.0f, h = 0.0f;
  for (int i = row0; i < row1; ++i) {
    float rl = 0.0f, rh = 0.0f;
    const float *row = x + (size_t)i * k;
    int j = 0;
#if ZF_NEON
    if (k >= 8) {
      float32x4_t lo0 = vdupq_n_f32(0.0f), hi0 = lo0;
      for (; j + 4 <= k; j += 4) {
        const float32x4_t v = vld1q_f32(row + j);
        lo0 = vminq_f32(lo0, v);
        hi0 = vmaxq_f32(hi0, v);
      }
      const float32x2_t lp = vpmin_f32(vget_low_f32(lo0), vget_high_f32(lo0));
      const float32x2_t hp = vpmax_f32(vget_low_f32(hi0), vget_high_f32(hi0));
      rl = vget_lane_f32(vpmin_f32(lp, lp), 0);
      rh = vget_lane_f32(vpmax_f32(hp, hp), 0);
    }
#endif
    for (; j < k; ++j) {
      if (row[j] < rl) rl = row[j];
      if (row[j] > rh) rh = row[j];
    }
    if (rl < l) l = rl;
    if (rh > h) h = rh;
  }
  *lo = l;
  *hi = h;
}

void zf_quantize_params(float lo, float hi, float *scale_out, int *zp_out) {
  float scale = (hi - lo) / 255.0f;
  if (!(scale > 0.0f)) scale = 1.0f;
  float zp_f = nearbyintf(-lo / scale);
  if (zp_f < 0.0f) zp_f = 0.0f;
  if (zp_f > 255.0f) zp_f = 255.0f;
  *scale_out = scale;
  *zp_out = (int)zp_f;
}

void zf_quantize_write_rows(const float *x, int k, int lda, int8_t *a, float scale, int zero_point,
                            int row0, int row1) {
  for (int i = row0; i < row1; ++i) {
    int8_t *row = a + (size_t)i * lda;
    quantize_into_shifted(x + (size_t)i * k, (size_t)k, row, scale, zero_point);
    memset(row + k, 0, (size_t)(lda - k));
  }
}

void zf_dynamic_quantize_rows(const float *x, int m, int k, int lda, int8_t *a, float *scale_out,
                              int *zp_out) {
  quantize_params(x, (size_t)m * k, scale_out, zp_out); /* one scale per tensor, as ONNX does */
  for (int i = 0; i < m; ++i) {
    int8_t *row = a + (size_t)i * lda;
    quantize_into_shifted(x + (size_t)i * k, (size_t)k, row, *scale_out, *zp_out);
    memset(row + k, 0, (size_t)(lda - k)); /* the pad must contribute nothing */
  }
}

static int round_up_int(int v, int mult) { return (v + mult - 1) / mult * mult; }

size_t zf_weights_s8_packed_bytes(int n, int k) {
  return (size_t)round_up_int(n, ZF_S8_UNIT_BLOCK) * (size_t)round_up_int(k, ZF_S8_K_GROUP);
}

int zf_weights_s8_row_sums_count(int n) { return round_up_int(n, ZF_S8_UNIT_BLOCK); }

int zf_weights_s8_pack(const int8_t *w_nk, int n, int k, int8_t *packed, int32_t *row_sums,
                       ZfWeightsS8 *out) {
  const int k_pad = round_up_int(k, ZF_S8_K_GROUP);
  const int n_pad = round_up_int(n, ZF_S8_UNIT_BLOCK);
  const int groups = k_pad / ZF_S8_K_GROUP;
  memset(packed, 0, (size_t)n_pad * k_pad);
  memset(row_sums, 0, (size_t)n_pad * sizeof(int32_t));
  for (int j = 0; j < n; ++j) {
    const int8_t *src = w_nk + (size_t)j * k;
    int32_t sum = 0;
    for (int p = 0; p < k; ++p) {
      if (src[p] == -128) return 0; /* two products would not fit one int16 lane */
      sum += src[p];
    }
    row_sums[j] = sum;
    int8_t *lane = packed + (size_t)(j / ZF_S8_UNIT_BLOCK) * ZF_S8_UNIT_BLOCK * k_pad +
                   (size_t)(j % ZF_S8_UNIT_BLOCK) * ZF_S8_K_GROUP;
    for (int g = 0; g < groups; ++g) {
      const int p = g * ZF_S8_K_GROUP;
      const int span = (k - p) < ZF_S8_K_GROUP ? (k - p) : ZF_S8_K_GROUP;
      if (span > 0)
        memcpy(lane + (size_t)g * ZF_S8_UNIT_BLOCK * ZF_S8_K_GROUP, src + p, (size_t)span);
    }
  }
  out->n = n;
  out->k = k;
  out->n_blocks = n_pad / ZF_S8_UNIT_BLOCK;
  out->k_pad = k_pad;
  out->packed = packed;
  out->row_sums = row_sums;
  return 1;
}

#if ZF_NEON && defined(__arm__) && !(defined(ZF_NEON_EMU) && ZF_NEON_EMU)
#define ZF_HAVE_ASM 1
/* kernels_armv7.S: the same arithmetic, hand-scheduled for the A53's in-order NEON pipeline. */
void zf_gemm_s8_4x2(const int8_t *a0, const int8_t *a1, const int8_t *panel, int groups,
                    const int32_t *corr, void *out0, void *out1, const float *sb);
void zf_gemm_s8_4x1(const int8_t *a0, const int8_t *panel, int groups, const int32_t *corr,
                    void *out0, const float *sb);
/* The same as 4x2, with the row-pair loop inside so the callee-saved registers are pushed once
 * per panel rather than once per row pair. Runs the pairs only; an odd row stays with 4x1. */
void zf_gemm_s8_4xm(const int8_t *a, int lda, const int8_t *panel, int groups, int pairs,
                    const int32_t *corr, void *out, int ldout, const float *sb);
#else
#define ZF_HAVE_ASM 0
#endif

/* Which microkernel the linear path uses. The assembly is the default where it exists; the knob is
 * here so a benchmark can measure both variants in one run, under one thermal state. */
static int g_use_asm = ZF_HAVE_ASM;

int zf_kernels_asm_available(void) { return ZF_HAVE_ASM; }

int zf_kernels_set_variant(int use_asm) {
  if (use_asm && !ZF_HAVE_ASM) return 0;
  g_use_asm = use_asm ? 1 : 0;
  return 1;
}

int zf_kernels_variant(void) { return g_use_asm; }

#if ZF_NEON
/* [hsum(a), hsum(b), hsum(c), hsum(d)] in six pairwise adds, which keeps the four output units of
 * a panel in a vector: no lane extraction, and no moves from NEON to the core registers. */
static inline int32x4_t hsum4_s32(int32x4_t a, int32x4_t b, int32x4_t c, int32x4_t d) {
  const int32x2_t pa = vpadd_s32(vget_low_s32(a), vget_high_s32(a));
  const int32x2_t pb = vpadd_s32(vget_low_s32(b), vget_high_s32(b));
  const int32x2_t pc = vpadd_s32(vget_low_s32(c), vget_high_s32(c));
  const int32x2_t pd = vpadd_s32(vget_low_s32(d), vget_high_s32(d));
  return vcombine_s32(vpadd_s32(pa, pb), vpadd_s32(pc, pd));
}

static inline void store_units(int32_t *dst, int32x4_t v, int valid) {
  if (valid == ZF_S8_UNIT_BLOCK) {
    vst1q_s32(dst, v);
    return;
  }
  int32_t tmp[ZF_S8_UNIT_BLOCK];
  vst1q_s32(tmp, v);
  for (int u = 0; u < valid; ++u) dst[u] = tmp[u];
}

/* One 16-byte k group against one unit's weights, for two rows at once. Two product registers so
 * the multiply of one row overlaps the widening accumulate of the other. */
#define ZF_PANEL_UNIT(cA, cB, wv)                          \
  do {                                                     \
    const int8x8_t wl = vget_low_s8(wv), wh = vget_high_s8(wv); \
    int16x8_t t0 = vmull_s8(a0l, wl);                      \
    int16x8_t t1 = vmull_s8(a1l, wl);                      \
    t0 = vmlal_s8(t0, a0h, wh);                            \
    t1 = vmlal_s8(t1, a1h, wh);                            \
    cA = vpadalq_s16(cA, t0);                              \
    cB = vpadalq_s16(cB, t1);                              \
  } while (0)
#endif

/* The panel loop, over rows [row_begin, row_end). */
/* `j_shift` is subtracted from the output column, so a caller can point `out` at a tile that holds
 * only the panels it is about to scale rather than the whole accumulator slab. */
/* `yf` is where the scaled result goes when the caller wants float straight out of the kernel; it
 * is null for the int32 form the front end's transposing scale needs. */
#if !ZF_HAVE_ASM
/* A host's own int8 kernel (tajweedformer-native's AVX-512 VNNI): it fills `out` with exactly the int32
 * the code below would, for rows [row_begin, row_end) and unit blocks [block_begin, block_end) with
 * columns shifted left by `j_shift`, and returns 1; or returns 0 and the code below runs. Integer
 * arithmetic, so it cannot move a bit; this weak default declines. Offered only where the kernel
 * produces int32 (every target without the ARMv7 assembly). */
__attribute__((weak)) int zf_s8_linear_hook(const ZfWeightsS8 *w, const int8_t *a, int row_begin,
                                            int row_end, int lda, int a_zero_point, int32_t *out,
                                            int ldc, int block_begin, int block_end, int j_shift) {
  (void)w; (void)a; (void)row_begin; (void)row_end; (void)lda; (void)a_zero_point; (void)out;
  (void)ldc; (void)block_begin; (void)block_end; (void)j_shift;
  return 0;
}
#endif

static void linear_s8_rows_f(const int8_t *a, int row_begin, int row_end, int lda,
                             const ZfWeightsS8 *w, int a_zero_point, int32_t *out, int ldc,
                             int block_begin, int block_end, int j_shift, const float *scale,
                             int scale_count, const float *bias, float *yf, int ldy) {
  const int k_pad = w->k_pad;
  const int m = row_end - row_begin;
  const int32_t correction = 128 - a_zero_point;
#if !ZF_HAVE_ASM
  /* only the assembly epilogue scales; the portable paths leave int32 for the caller */
  (void)scale;
  (void)scale_count;
  (void)bias;
  if (zf_s8_linear_hook(w, a, row_begin, row_end, lda, a_zero_point, out, ldc, block_begin,
                        block_end, j_shift))
    return;
#endif
  a += (size_t)row_begin * lda;
  out += (size_t)row_begin * ldc;
  if (yf) yf += (size_t)row_begin * ldy;
  for (int jb = block_begin; jb < block_end; ++jb) {
    const int8_t *panel = w->packed + (size_t)jb * ZF_S8_UNIT_BLOCK * k_pad;
    const int j0 = jb * ZF_S8_UNIT_BLOCK;
    const int jo = j0 - j_shift;
    const int valid = (w->n - j0) < ZF_S8_UNIT_BLOCK ? (w->n - j0) : ZF_S8_UNIT_BLOCK;
    int i = 0;
#if ZF_NEON
    const int32x4_t corr = vmulq_n_s32(vld1q_s32(w->row_sums + j0), correction);
#endif
#if ZF_HAVE_ASM
    if (g_use_asm) {
      const int groups = k_pad / ZF_S8_K_GROUP;
      int32_t corr_buf[ZF_S8_UNIT_BLOCK], scratch0[ZF_S8_UNIT_BLOCK], scratch1[ZF_S8_UNIT_BLOCK];
      float fscratch0[ZF_S8_UNIT_BLOCK], fscratch1[ZF_S8_UNIT_BLOCK];
      vst1q_s32(corr_buf, corr);
      /* the panel's four scales and four biases, laid out the way the epilogue reads them */
      float sb[2 * ZF_S8_UNIT_BLOCK];
      const float *sbp = NULL;
      if (yf) {
        for (int u = 0; u < ZF_S8_UNIT_BLOCK; ++u) {
          const int col = j0 + u < w->n ? j0 + u : w->n - 1;
          sb[u] = (scale_count == 1) ? scale[0] : scale[col];
          sb[ZF_S8_UNIT_BLOCK + u] = bias ? bias[col] : 0.0f;
        }
        sbp = sb;
      }
      /* Whole blocks, which is every panel in both shipped weight files, take the kernel that
       * owns its row loop: one register save for the panel instead of one per row pair. The
       * narrow-block path below is unchanged and keeps its own loop. */
      if (valid == ZF_S8_UNIT_BLOCK && m >= 2) {
        const int pairs = m / 2;
        if (yf) zf_gemm_s8_4xm(a, lda, panel, groups, pairs, corr_buf, yf + j0, ldy, sbp);
        else zf_gemm_s8_4xm(a, lda, panel, groups, pairs, corr_buf, out + jo, ldc, NULL);
        i = pairs * 2;
      }
      for (; i + 2 <= m; i += 2) {
        const int8_t *pa0 = a + (size_t)i * lda;
        if (yf) {
          float *f0 = yf + (size_t)i * ldy + j0, *f1 = f0 + ldy;
          if (valid == ZF_S8_UNIT_BLOCK) {
            zf_gemm_s8_4x2(pa0, pa0 + lda, panel, groups, corr_buf, f0, f1, sbp);
          } else {
            zf_gemm_s8_4x2(pa0, pa0 + lda, panel, groups, corr_buf, fscratch0, fscratch1, sbp);
            for (int u = 0; u < valid; ++u) { f0[u] = fscratch0[u]; f1[u] = fscratch1[u]; }
          }
          continue;
        }
        int32_t *o0 = out + (size_t)i * ldc + jo, *o1 = o0 + ldc;
        if (valid == ZF_S8_UNIT_BLOCK) {
          zf_gemm_s8_4x2(pa0, pa0 + lda, panel, groups, corr_buf, o0, o1, NULL);
        } else {
          zf_gemm_s8_4x2(pa0, pa0 + lda, panel, groups, corr_buf, scratch0, scratch1, NULL);
          for (int u = 0; u < valid; ++u) { o0[u] = scratch0[u]; o1[u] = scratch1[u]; }
        }
      }
      for (; i < m; ++i) {
        const int8_t *pa0 = a + (size_t)i * lda;
        if (yf) {
          float *f0 = yf + (size_t)i * ldy + j0;
          if (valid == ZF_S8_UNIT_BLOCK) {
            zf_gemm_s8_4x1(pa0, panel, groups, corr_buf, f0, sbp);
          } else {
            zf_gemm_s8_4x1(pa0, panel, groups, corr_buf, fscratch0, sbp);
            for (int u = 0; u < valid; ++u) f0[u] = fscratch0[u];
          }
          continue;
        }
        int32_t *o0 = out + (size_t)i * ldc + jo;
        if (valid == ZF_S8_UNIT_BLOCK) {
          zf_gemm_s8_4x1(pa0, panel, groups, corr_buf, o0, NULL);
        } else {
          zf_gemm_s8_4x1(pa0, panel, groups, corr_buf, scratch0, NULL);
          for (int u = 0; u < valid; ++u) o0[u] = scratch0[u];
        }
      }
      continue;
    }
#endif
#if ZF_NEON
    for (; i + 2 <= m; i += 2) {
      const int8_t *pa0 = a + (size_t)i * lda;
      const int8_t *pa1 = pa0 + lda;
      const int8_t *pw = panel;
      int32x4_t c00 = vdupq_n_s32(0), c01 = vdupq_n_s32(0);
      int32x4_t c02 = vdupq_n_s32(0), c03 = vdupq_n_s32(0);
      int32x4_t c10 = vdupq_n_s32(0), c11 = vdupq_n_s32(0);
      int32x4_t c12 = vdupq_n_s32(0), c13 = vdupq_n_s32(0);
      for (int p = 0; p < k_pad; p += ZF_S8_K_GROUP) {
        const int8x16_t av0 = vld1q_s8(pa0 + p), av1 = vld1q_s8(pa1 + p);
        const int8x8_t a0l = vget_low_s8(av0), a0h = vget_high_s8(av0);
        const int8x8_t a1l = vget_low_s8(av1), a1h = vget_high_s8(av1);
        __builtin_prefetch(pw + 8 * ZF_S8_UNIT_BLOCK * ZF_S8_K_GROUP);
        ZF_PANEL_UNIT(c00, c10, vld1q_s8(pw));
        ZF_PANEL_UNIT(c01, c11, vld1q_s8(pw + 16));
        ZF_PANEL_UNIT(c02, c12, vld1q_s8(pw + 32));
        ZF_PANEL_UNIT(c03, c13, vld1q_s8(pw + 48));
        pw += ZF_S8_UNIT_BLOCK * ZF_S8_K_GROUP;
      }
      store_units(out + (size_t)i * ldc + jo, vaddq_s32(hsum4_s32(c00, c01, c02, c03), corr),
                  valid);
      store_units(out + (size_t)(i + 1) * ldc + jo,
                  vaddq_s32(hsum4_s32(c10, c11, c12, c13), corr), valid);
    }
    for (; i < m; ++i) { /* odd row count: the same panel, now hot in L1 */
      const int8_t *pa0 = a + (size_t)i * lda;
      const int8_t *pw = panel;
      int32x4_t c00 = vdupq_n_s32(0), c01 = vdupq_n_s32(0);
      int32x4_t c02 = vdupq_n_s32(0), c03 = vdupq_n_s32(0);
      for (int p = 0; p < k_pad; p += ZF_S8_K_GROUP) {
        const int8x16_t av0 = vld1q_s8(pa0 + p);
        const int8x8_t a0l = vget_low_s8(av0), a0h = vget_high_s8(av0);
        const int8x16_t w0 = vld1q_s8(pw), w1 = vld1q_s8(pw + 16);
        const int8x16_t w2 = vld1q_s8(pw + 32), w3 = vld1q_s8(pw + 48);
        int16x8_t t0 = vmull_s8(a0l, vget_low_s8(w0));
        int16x8_t t1 = vmull_s8(a0l, vget_low_s8(w1));
        t0 = vmlal_s8(t0, a0h, vget_high_s8(w0));
        t1 = vmlal_s8(t1, a0h, vget_high_s8(w1));
        c00 = vpadalq_s16(c00, t0);
        c01 = vpadalq_s16(c01, t1);
        t0 = vmull_s8(a0l, vget_low_s8(w2));
        t1 = vmull_s8(a0l, vget_low_s8(w3));
        t0 = vmlal_s8(t0, a0h, vget_high_s8(w2));
        t1 = vmlal_s8(t1, a0h, vget_high_s8(w3));
        c02 = vpadalq_s16(c02, t0);
        c03 = vpadalq_s16(c03, t1);
        pw += ZF_S8_UNIT_BLOCK * ZF_S8_K_GROUP;
      }
      store_units(out + (size_t)i * ldc + jo, vaddq_s32(hsum4_s32(c00, c01, c02, c03), corr),
                  valid);
    }
#else
    for (; i < m; ++i) {
      const int8_t *pa0 = a + (size_t)i * lda;
      for (int u = 0; u < valid; ++u) {
        int32_t sum = 0;
        for (int g = 0; g < k_pad / ZF_S8_K_GROUP; ++g) {
          const int8_t *wg = panel + (size_t)g * ZF_S8_UNIT_BLOCK * ZF_S8_K_GROUP +
                             (size_t)u * ZF_S8_K_GROUP;
          for (int e = 0; e < ZF_S8_K_GROUP; ++e)
            sum += (int32_t)pa0[g * ZF_S8_K_GROUP + e] * (int32_t)wg[e];
        }
        out[(size_t)i * ldc + jo + u] = sum + correction * w->row_sums[j0 + u];
      }
    }
#endif
  }
}

/* Row blocking. A linear layer here has at most 24 rows, but a lowered convolution has hundreds or
 * thousands, and then walking every row for one panel before moving to the next re-reads the whole
 * activation buffer once per panel. Blocking the rows so a block's activations stay in L1 turns
 * that into one pass over the weights per block instead. */
#define ZF_M_BLOCK 32

void zf_linear_s8_range(const int8_t *a, int m, int lda, const ZfWeightsS8 *w, int a_zero_point,
                        int32_t *out, int ldc, int block_begin, int block_end) {
  zf_linear_s8_tile(a, m, lda, w, a_zero_point, out, ldc, block_begin, block_end, 0);
}

/* The matmul with the scaling folded into its epilogue: no int32 ever reaches memory. `out` is
 * still needed as scratch when the assembly is switched off, because the portable paths accumulate
 * there and are scaled afterwards, which gives the same floats either way. */
void zf_linear_s8_f32_range(const int8_t *a, int m, int lda, const ZfWeightsS8 *w,
                            int a_zero_point, int32_t *scratch, const float *scale, int scale_count,
                            const float *bias, float *y, int ldy, int block_begin, int block_end) {
  if (m <= ZF_M_BLOCK) {
    linear_s8_rows_f(a, 0, m, lda, w, a_zero_point, scratch, w->n, block_begin, block_end, 0, scale,
                     scale_count, bias, y, ldy);
  } else {
    for (int i0 = 0; i0 < m; i0 += ZF_M_BLOCK) {
      const int i1 = (i0 + ZF_M_BLOCK < m) ? i0 + ZF_M_BLOCK : m;
      linear_s8_rows_f(a, i0, i1, lda, w, a_zero_point, scratch, w->n, block_begin, block_end, 0,
                       scale, scale_count, bias, y, ldy);
    }
  }
#if ZF_HAVE_ASM
  if (g_use_asm) return;
#endif
  /* the portable paths left int32 in the scratch; scale it the way they always did */
  {
    const int j0 = block_begin * ZF_S8_UNIT_BLOCK;
    int j1 = block_end * ZF_S8_UNIT_BLOCK;
    if (j1 > w->n) j1 = w->n;
    zf_dequantize_range(scratch, m, w->n, scale, scale_count, bias, y, ldy, j0, j1);
  }
}

/* `j_shift` lets the caller hand over a tile that starts at the first column this range produces,
 * rather than a slab spanning every column of the linear. */
void zf_linear_s8_tile(const int8_t *a, int m, int lda, const ZfWeightsS8 *w, int a_zero_point,
                       int32_t *out, int ldc, int block_begin, int block_end, int j_shift) {
  if (m <= ZF_M_BLOCK) {
    linear_s8_rows_f(a, 0, m, lda, w, a_zero_point, out, ldc, block_begin, block_end, j_shift,
                     NULL, 0, NULL, NULL, 0);
    return;
  }
  for (int i0 = 0; i0 < m; i0 += ZF_M_BLOCK) {
    const int i1 = (i0 + ZF_M_BLOCK < m) ? i0 + ZF_M_BLOCK : m;
    linear_s8_rows_f(a, i0, i1, lda, w, a_zero_point, out, ldc, block_begin, block_end, j_shift,
                     NULL, 0, NULL, NULL, 0);
  }
}

void zf_linear_s8(const int8_t *a, int m, int lda, const ZfWeightsS8 *w, int a_zero_point,
                  int32_t *out, int ldc) {
  zf_linear_s8_range(a, m, lda, w, a_zero_point, out, ldc, 0, w->n_blocks);
}

typedef struct {
  const int8_t *a;
  int m, lda;
  const ZfWeightsS8 *w;
  int a_zero_point;
  int32_t *out;
  int ldc;
} LinearJob;

static void linear_range(void *context, int begin, int end) {
  const LinearJob *job = (const LinearJob *)context;
  zf_linear_s8_range(job->a, job->m, job->lda, job->w, job->a_zero_point, job->out, job->ldc,
                     begin, end);
}

/* Scale a task's compact accumulator tile into its columns of the result.
 *
 * The tile holds this task's columns only, at its own row stride, so it is a few kilobytes and
 * stays in level one cache; the result is still written one contiguous run per row, which is what
 * keeps the stores to whole cache lines. Doing the same panel by panel instead writes a quarter of
 * a line at a time and costs more than the slab it saves. */
void zf_dequantize_tile(const int32_t *tile, int m, int cols, const float *scale, int scale_count,
                        const float *bias, float *y, int ldy, int j0) {
  for (int i = 0; i < m; ++i) {
    const int32_t *src = tile + (size_t)i * cols;
    float *dst = y + (size_t)i * ldy + j0;
    int u = 0;
#if ZF_NEON
    if (scale_count == 1) {
      const float32x4_t vsc = vdupq_n_f32(scale[0]);
      for (; u + 4 <= cols; u += 4) {
        const float32x4_t vbi = bias ? vld1q_f32(bias + j0 + u) : vdupq_n_f32(0.0f);
        vst1q_f32(dst + u, vmlaq_f32(vbi, vcvtq_f32_s32(vld1q_s32(src + u)), vsc));
      }
    } else {
      for (; u + 4 <= cols; u += 4) {
        const float32x4_t vsc = vld1q_f32(scale + j0 + u);
        const float32x4_t vbi = bias ? vld1q_f32(bias + j0 + u) : vdupq_n_f32(0.0f);
        vst1q_f32(dst + u, vmlaq_f32(vbi, vcvtq_f32_s32(vld1q_s32(src + u)), vsc));
      }
    }
#endif
    for (; u < cols; ++u) {
      const float sc = (scale_count == 1) ? scale[0] : scale[j0 + u];
      dst[u] = (float)src[u] * sc + (bias ? bias[j0 + u] : 0.0f);
    }
  }
}

/* The same, leaving the result transposed: one row per output unit at stride ldy. */
/* One 4 by 4 tile: four frames of four channels in, four channel rows out. */
#if ZF_NEON
static inline void deq_t_tile4(const int32_t *acc, int ldc, const float *scale, const float *bias,
                               float *dst, int ldy) {
  const int32x4_t r0 = vld1q_s32(acc);
  const int32x4_t r1 = vld1q_s32(acc + ldc);
  const int32x4_t r2 = vld1q_s32(acc + 2 * (size_t)ldc);
  const int32x4_t r3 = vld1q_s32(acc + 3 * (size_t)ldc);
  const int32x4x2_t a = vtrnq_s32(r0, r1);
  const int32x4x2_t b = vtrnq_s32(r2, r3);
  const int32x4_t c0 = vcombine_s32(vget_low_s32(a.val[0]), vget_low_s32(b.val[0]));
  const int32x4_t c1 = vcombine_s32(vget_low_s32(a.val[1]), vget_low_s32(b.val[1]));
  const int32x4_t c2 = vcombine_s32(vget_high_s32(a.val[0]), vget_high_s32(b.val[0]));
  const int32x4_t c3 = vcombine_s32(vget_high_s32(a.val[1]), vget_high_s32(b.val[1]));
  vst1q_f32(dst, vmlaq_n_f32(vdupq_n_f32(bias[0]), vcvtq_f32_s32(c0), scale[0]));
  vst1q_f32(dst + ldy, vmlaq_n_f32(vdupq_n_f32(bias[1]), vcvtq_f32_s32(c1), scale[1]));
  vst1q_f32(dst + 2 * (size_t)ldy, vmlaq_n_f32(vdupq_n_f32(bias[2]), vcvtq_f32_s32(c2), scale[2]));
  vst1q_f32(dst + 3 * (size_t)ldy, vmlaq_n_f32(vdupq_n_f32(bias[3]), vcvtq_f32_s32(c3), scale[3]));
}
#endif

/* The transposing scale, over the packed tile.
 *
 * This was the one dequantise still scalar, and it is the shipping path for the convolution
 * module's input linear: 32 of them a chunk. Its inner loop walks `i` at stride `cols`, so it
 * touched a cache line per value and ran a serialised load, convert, multiply-add, store.
 * deq_t_tile4 already exists for exactly this shape and was reachable only from the SDOT branch,
 * which this core does not have.
 *
 * The stride handed to the tile is `cols`, the packed tile's own row stride, not the linear's n:
 * zf_dequantize_range_t passes the full slab's stride because it reads the slab, and the column
 * index here is local to the tile while the output row is global. Getting that wrong reads the
 * wrong accumulators and no shape check catches it.
 *
 * Exact: the scalar form is round(round(x * sc) + bi), and NEON's VMLA.F32 is not a fused
 * multiply-add -- it rounds the product before the accumulate -- so vmlaq_n_f32(bias, x, scale) is
 * the same two roundings. Addition is commutative in IEEE 754, including for signed zeros, so
 * bi + x*sc and x*sc + bi are the same bits. zf_dequantize_range_t already pairs this tile with a
 * scalar residue doing `* sc + bi`, so the equivalence is one the engine already relies on. */
void zf_dequantize_tile_t(const int32_t *tile, int m, int cols, const float *scale,
                          int scale_count, const float *bias, float *y, int ldy, int j0) {
  int u = 0;
#if ZF_NEON
  for (; u + 4 <= cols; u += 4) {
    float sc[4], bi[4];
    for (int v = 0; v < 4; ++v) {
      sc[v] = (scale_count == 1) ? scale[0] : scale[j0 + u + v];
      bi[v] = bias ? bias[j0 + u + v] : 0.0f;
    }
    int i = 0;
    for (; i + 4 <= m; i += 4)
      deq_t_tile4(tile + (size_t)i * cols + u, cols, sc, bi, y + (size_t)(j0 + u) * ldy + i, ldy);
    /* m is the frame count, so the deep stacks at m = 3 never enter the tile at all and take this
     * residue for every row. */
    for (; i < m; ++i)
      for (int v = 0; v < 4; ++v)
        y[(size_t)(j0 + u + v) * ldy + i] = (float)tile[(size_t)i * cols + u + v] * sc[v] + bi[v];
  }
#endif
  for (; u < cols; ++u) {
    const float sc = (scale_count == 1) ? scale[0] : scale[j0 + u];
    const float bi = bias ? bias[j0 + u] : 0.0f;
    float *row = y + (size_t)(j0 + u) * ldy;
    for (int i = 0; i < m; ++i) row[i] = (float)tile[(size_t)i * cols + u] * sc + bi;
  }
}

void zf_linear_s8_pool(ZfPool *pool, const int8_t *a, int m, int lda, const ZfWeightsS8 *w,
                       int a_zero_point, int32_t *out, int ldc) {
  LinearJob job = {a, m, lda, w, a_zero_point, out, ldc};
  /* One grain is four panels, sixteen output units: small enough to balance four cores on the
   * narrowest layer (192 units) and large enough that the shared cursor is not the bottleneck. */
  zf_pool_run(pool, linear_range, &job, w->n_blocks, 4);
}

void zf_dequantize_range(const int32_t *acc, int m, int ldc, const float *scale, int scale_count,
                         const float *bias, float *y, int ldy, int begin, int end) {
  for (int i = 0; i < m; ++i) {
    const int32_t *arow = acc + (size_t)i * ldc;
    float *yrow = y + (size_t)i * ldy;
    if (scale_count == 1) {
      const float s = scale[0];
      int j = begin;
#if ZF_NEON
      const float32x4_t sv = vdupq_n_f32(s);
      for (; j + 4 <= end; j += 4) {
        float32x4_t v = vmulq_f32(vcvtq_f32_s32(vld1q_s32(arow + j)), sv);
        if (bias) v = vaddq_f32(v, vld1q_f32(bias + j));
        vst1q_f32(yrow + j, v);
      }
#endif
      for (; j < end; ++j) yrow[j] = (float)arow[j] * s + (bias ? bias[j] : 0.0f);
    } else {
      int j = begin;
#if ZF_NEON
      for (; j + 4 <= end; j += 4) {
        float32x4_t v = vmulq_f32(vcvtq_f32_s32(vld1q_s32(arow + j)), vld1q_f32(scale + j));
        if (bias) v = vaddq_f32(v, vld1q_f32(bias + j));
        vst1q_f32(yrow + j, v);
      }
#endif
      for (; j < end; ++j) yrow[j] = (float)arow[j] * scale[j] + (bias ? bias[j] : 0.0f);
    }
  }
}

void zf_dequantize(const int32_t *acc, int m, int n, int ldc, const float *scale, int scale_count,
                   const float *bias, float *y, int ldy) {
  zf_dequantize_range(acc, m, ldc, scale, scale_count, bias, y, ldy, 0, n);
}

#if ZF_NEON
/* -|z|, as one instruction and no register.
 *
 * vnegq(vabsq(z)) is two, and 0x80000000 is an encodable VORR.I32 immediate, so this needs no
 * constant either. Setting the sign bit and clearing-then-flipping it give the same bit pattern
 * for every input, including both zeros, both infinities and any NaN, whose payload is untouched
 * by all three operations. */
static inline float32x4_t zf_negabsq_f32(float32x4_t z) {
  return vreinterpretq_f32_u32(
      vorrq_u32(vreinterpretq_u32_f32(z), vdupq_n_u32(0x80000000u)));
}

/* The body of the exponential, on an argument already clamped from below.
 *
 * Split out so the callers that can prove their argument is not positive skip the upper clamp.
 * The floor is computed on the integer side: vcgtq_f32 yields all ones, which is -1 as int32, so
 * adding it is the same subtraction of one the float form did, and n is small enough to be exactly
 * representable either way. The exponent bias is then folded into the shifted result, which is the
 * same value as biasing before the shift because 127 << 23 is 0x3f800000 and neither form
 * overflows for the range the clamp allows. Between them these drop the 1.0f, 0.0f, 127 and 88.0f
 * constants and three instructions from a loop that was spilling eleven constants to the stack. */
static inline float32x4_t zf_expq_core_f32(float32x4_t x) {
  const float32x4_t log2e = vdupq_n_f32(1.44269504088896341f);
  const float32x4_t c1 = vdupq_n_f32(0.693359375f), c2 = vdupq_n_f32(-2.12194440e-4f);
  const float32x4_t shifted = vaddq_f32(vmulq_f32(x, log2e), vdupq_n_f32(0.5f));
  const int32x4_t nt = vcvtq_s32_f32(shifted);
  const float32x4_t ntf = vcvtq_f32_s32(nt);
  const int32x4_t ni = vaddq_s32(nt, vreinterpretq_s32_u32(vcgtq_f32(ntf, shifted)));
  const float32x4_t n = vcvtq_f32_s32(ni);
  const float32x4_t r = vsubq_f32(vsubq_f32(x, vmulq_f32(n, c1)), vmulq_f32(n, c2));
  float32x4_t y = vmlaq_f32(vdupq_n_f32(1.3981999507e-3f), vdupq_n_f32(1.9875691500e-4f), r);
  y = vmlaq_f32(vdupq_n_f32(8.3334519073e-3f), y, r);
  y = vmlaq_f32(vdupq_n_f32(4.1665795894e-2f), y, r);
  y = vmlaq_f32(vdupq_n_f32(1.6666665459e-1f), y, r);
  y = vmlaq_f32(vdupq_n_f32(5.0000001201e-1f), y, r);
  y = vmlaq_f32(vaddq_f32(r, vdupq_n_f32(1.0f)), y, vmulq_f32(r, r));
  const int32x4_t pow2n = vaddq_s32(vshlq_n_s32(ni, 23), vdupq_n_s32(0x3f800000));
  return vmulq_f32(y, vreinterpretq_f32_s32(pow2n));
}

static inline float32x4_t zf_expq_f32(float32x4_t x) {
  return zf_expq_core_f32(vminq_f32(vmaxq_f32(x, vdupq_n_f32(-87.0f)), vdupq_n_f32(88.0f)));
}

/* For an argument that cannot be positive, which is how swoosh and the softmax both call it: the
 * upper clamp can never select 88.0f, and on a NaN VMAX and VMIN both yield the default NaN with
 * or without it, so the bits agree there too. */
static inline float32x4_t zf_expq_np_f32(float32x4_t x) {
  return zf_expq_core_f32(vmaxq_f32(x, vdupq_n_f32(-87.0f)));
}

static inline float32x4_t zf_recipq_f32(float32x4_t b) {
  float32x4_t inv = vrecpeq_f32(b);
  inv = vmulq_f32(zf_recpsq(b, inv), inv);
  inv = vmulq_f32(zf_recpsq(b, inv), inv);
  return inv;
}
#endif

/* ZF_EXACT_MATH: take libm instead of the fast approximations, everywhere they are used.
 *
 * Four kernels share `zf_expq_f32` and `zf_recipq_f32`: swoosh, sigmoid, tanh and the attention
 * softmax. Each is accurate to around a part in ten million, which is far below anything that
 * should matter, and yet the engine decodes one token differently from the fp32 checkpoint on a
 * long clip while the published int8 export decodes it identically. Small errors in these kernels
 * are the only floating-point difference there is, because the matmuls are bit exact.
 *
 * So this switch exists to bound the problem rather than to ship: with it on, every one of those
 * four takes the scalar libm path that each already carries as its tail. If the disagreement
 * disappears the cause is approximation error and the fix is accuracy; if it survives, something
 * structural is wrong and accuracy would have been the wrong thing to chase.
 *
 * Measured on the clip that disagrees, as edit distance to the fp32 checkpoint's 248 tokens:
 * published int8 0, engine with the fast kernels 2, engine with libm swoosh alone 1. So swoosh was
 * one contributor of at least two, which is what prompted extending this to the other three. */
/* Read the VALUE, not just the presence.
 *
 * This tested `getenv(...) != NULL`, so ZF_EXACT_MATH=0 turned exact math ON: the obvious way to
 * ask for it to be off was the way to ask for it on. It costs 24.6 ms of a 75.8 ms chunk, so a
 * harness that set the variable to 0 for its baseline column measured every column a third slow
 * and read that as the feature being expensive when nothing had been varied at all. Every other
 * switch in the engine already goes through atoi; this one now does too. */
static int zf_exact_math(void) {
  static _Atomic int on = -1;
  if (on < 0) {
    const char *a = zf_getenv("ZF_EXACT_MATH"), *b = zf_getenv("ZF_SWOOSH_EXACT");
    on = (a && atoi(a)) || (b && atoi(b));
  }
  return on;
}

static void swoosh_libm(const float *x, float *y, size_t n, float offset, float constant) {
  for (size_t i = 0; i < n; ++i) {
    const float z = x[i] - offset;
    const float sp = (z > 0.0f ? z : 0.0f) + log1pf(expf(-fabsf(z)));
    y[i] = sp - 0.08f * x[i] - constant;
  }
}

#if ZF_NEON
/* Swoosh in two passes over a tile, because one pass cannot hold its constants.
 *
 * The single loop needs about twenty-four 128-bit constants -- the exponential's clamp, its
 * log2e/c1/c2 and six polynomial terms, then the offset, the final constant, 2.0, 0.0, 0.08 and
 * the four atanh terms -- against sixteen q registers. The compiler spilled eleven of them to the
 * stack in the prologue and reloaded them inside the loop, so the body was eighty instructions
 * per four values where the arithmetic is forty-two. That also explains why interleaving more
 * chains was measured as no help: adding chains to a loop that has already spilled every constant
 * can only spill more.
 *
 * Split by phase instead. The exponential pass holds ten constants and the tail pass seven, so
 * each fits with room for two independent chains. noinline keeps the allocator from merging them
 * back into one frame.
 *
 * Exact: every value meets the same operations in the same order, and u makes a round trip
 * through a stack tile, which returns a float unchanged. */
#define ZF_SWOOSH_TILE 32

/* ONNX Runtime's own exponential and logarithm, for the swoosh sites the graph spells stably.
 *
 * Exp is MLAS (`MlasComputeExp`), constants and statement order from
 * mlas/lib/elementwise_constants.h. Log is not MLAS at all, there is no MlasComputeLog: it is
 * Eigen's plog_float at the commit ONNX Runtime 1.23.2 pins, 1d8b82b0, where it is a degree two
 * over degree three rational finished with a real divide, not the nine term Cephes polynomial
 * that 3.4.0 and master carry. Both reproduce all 747,870 recorded values of their 84 nodes.
 *
 * Multiply-adds stay unfused: ARM32 has no MLAS platform table, so MlasComputeExp calls the
 * generic kernel where the macro is vmlaq_f32, and Eigen's pmadd has no float overload without
 * -mfma. The reference to match is the runtime on the phone. */
static inline float32x4_t zf_swdiv_f32(float32x4_t a, float32x4_t b) {
  float32x4_t r = a;
  r = vsetq_lane_f32(vgetq_lane_f32(a, 0) / vgetq_lane_f32(b, 0), r, 0);
  r = vsetq_lane_f32(vgetq_lane_f32(a, 1) / vgetq_lane_f32(b, 1), r, 1);
  r = vsetq_lane_f32(vgetq_lane_f32(a, 2) / vgetq_lane_f32(b, 2), r, 2);
  r = vsetq_lane_f32(vgetq_lane_f32(a, 3) / vgetq_lane_f32(b, 3), r, 3);
  return r;
}

/* a / b, correctly rounded, in NEON: the value zf_swdiv_f32's four VDIV.F32 give, without them.
 *
 * The quantiser's fused correction needs the reciprocal rounded once, which it can afford because
 * its divisor is one scalar a tensor. Here every lane has its own divisor, so the reciprocal comes
 * from the estimate instead and is corrected until it IS the rounded one (Markstein):
 *
 *   y  = VRECPE(b), then two VRECPS steps        about 24 bits
 *   y += y * (1 - b*y), twice, both fused        now RN(1/b)
 *   q0 = a * y;  r = a - b*q0 (fused, exact);  q = q0 + r*y (fused)   now RN(a/b)
 *
 * Checked on the host with exact fused arithmetic: y == RN(1/b) for every one of the 2^23
 * significands, at three exponents, whether VRECPS is fused or not, except the all-ones
 * significand, Markstein's known exception; and RN(a/b) on 344 million quotients (every numerator
 * against each divisor whose reciprocal the corrections miss, and against 40 random divisors),
 * with exactly one miss, 1 / (2 - 2^-23). Two corrections rather than one is what makes the answer
 * independent of how the core implements VRECPS.
 *
 * So lanes whose divisor has the all-ones significand go to the real divide, and so do lanes with
 * |a| < 2^-60, zero included: the residual is in NEON, which flushes denormals where VDIV does
 * not, and -0 / b has to stay -0. Neither happens in the sigmoid or the tanh at any value this
 * model produces, but "does not happen" is a claim about data and this is a claim about arithmetic,
 * so the fallback costs a compare and is never taken rather than being left out. */
static inline float32x4_t zf_divq_exact_f32(float32x4_t a, float32x4_t b) {
  float32x4_t y = vrecpeq_f32(b);
  y = vmulq_f32(zf_recpsq(b, y), y);
  y = vmulq_f32(zf_recpsq(b, y), y);
  const float32x4_t one = vdupq_n_f32(1.0f);
  y = zf_vfma_q(y, zf_vfms_q(one, b, y), y);
  y = zf_vfma_q(y, zf_vfms_q(one, b, y), y);
  const float32x4_t q0 = vmulq_f32(a, y);
  const float32x4_t q = zf_vfma_q(q0, zf_vfms_q(a, b, q0), y);
  const uint32x4_t frac = vandq_u32(vreinterpretq_u32_f32(b), vdupq_n_u32(0x7FFFFFu));
  const uint32x4_t special = vorrq_u32(vceqq_u32(frac, vdupq_n_u32(0x7FFFFFu)),
                                       vcltq_f32(vabsq_f32(a), vdupq_n_f32(0x1p-60f)));
  uint32x2_t any = vorr_u32(vget_low_u32(special), vget_high_u32(special));
  any = vpmax_u32(any, any);
  if (vget_lane_u32(any, 0)) return vbslq_f32(special, zf_swdiv_f32(a, b), q);
  return q;
}

/* ZF_FMADIV=0 puts the four VDIV.F32 back, for timing the difference; the values are the same. */
static int zf_fmadiv(void) {
  static _Atomic int on = -1;
  if (on < 0) {
    const char *v = zf_getenv("ZF_FMADIV");
    on = v ? atoi(v) : 1;
  }
  return on;
}

static inline float32x4_t zf_exp_ort_f32(float32x4_t x) {
  const float32x4_t magic = vdupq_n_f32(12582912.0f);
  x = vminq_f32(vmaxq_f32(x, vdupq_n_f32(-103.9720840454f)), vdupq_n_f32(88.7762626647950f));
  const float32x4_t biased = vmlaq_f32(magic, x, vdupq_n_f32(1.44269504088896341f));
  const float32x4_t m = vsubq_f32(biased, magic);
  x = vmlaq_f32(x, m, vdupq_n_f32(-6.93145752e-1f));
  x = vmlaq_f32(x, m, vdupq_n_f32(-1.42860677e-6f));
  const int32x4_t bias = vdupq_n_s32(0x3F800000);
  int32x4_t overflow = vshlq_n_s32(vreinterpretq_s32_f32(biased), 23);
  int32x4_t normal = vminq_s32(vmaxq_s32(overflow, vdupq_n_s32((int32_t)0xC1000000)), bias);
  overflow = vaddq_s32(vsubq_s32(overflow, normal), bias);
  normal = vaddq_s32(normal, bias);
  float32x4_t p = vdupq_n_f32(0x1.694000p-10f);
  p = vmlaq_f32(vdupq_n_f32(0x1.125edcp-7f), p, x);
  p = vmlaq_f32(vdupq_n_f32(0x1.555b5ap-5f), p, x);
  p = vmlaq_f32(vdupq_n_f32(0x1.555450p-3f), p, x);
  p = vmlaq_f32(vdupq_n_f32(0x1.fffff6p-2f), p, x);
  p = vmlaq_f32(vdupq_n_f32(0x1.000000p+0f), p, x);
  const float32x4_t ovf = vreinterpretq_f32_s32(overflow);
  x = vmulq_f32(x, ovf);
  p = vmlaq_f32(ovf, p, x);
  return vmulq_f32(p, vreinterpretq_f32_s32(normal));
}

/* specials = 0 skips Eigen's special values, for callers whose argument is provably in [1, 2]. */
static inline float32x4_t zf_log_ort_sp(float32x4_t x, const int specials) {
  const int32x4_t ix = vreinterpretq_s32_f32(x);
  float32x4_t m = vreinterpretq_f32_s32(
      vorrq_s32(vandq_s32(ix, vdupq_n_s32(0x807FFFFF)), vdupq_n_s32(0x3F000000)));
  float32x4_t e = vcvtq_f32_s32(
      vsubq_s32(vshrq_n_s32(vandq_s32(ix, vdupq_n_s32(0x7FFFFFFF)), 23), vdupq_n_s32(126)));
  const uint32x4_t lo = vcltq_f32(m, vdupq_n_f32(0.707106781186547524f));
  const float32x4_t tmp = vreinterpretq_f32_u32(vandq_u32(vreinterpretq_u32_f32(m), lo));
  m = vsubq_f32(m, vdupq_n_f32(1.0f));
  e = vsubq_f32(e, vreinterpretq_f32_u32(vandq_u32(lo, vdupq_n_u32(0x3F800000u))));
  m = vaddq_f32(m, tmp);
  float32x4_t p = vmlaq_f32(vdupq_n_f32(1.0000000190281063f),
                            vdupq_n_f32(0.18256296349849254f), m);
  p = vmlaq_f32(vdupq_n_f32(1.0000000190281136f), p, m);
  p = vmulq_f32(m, p);
  float32x4_t q = vmlaq_f32(vdupq_n_f32(0.59923249590823520f),
                            vdupq_n_f32(0.049616247954120038f), m);
  q = vmlaq_f32(vdupq_n_f32(1.4999999999999927f), q, m);
  q = vmlaq_f32(vdupq_n_f32(1.0f), q, m);
  /* Eigen's pdiv on ARMv7 is NOT a divide, and the true divide here was wrong on the phone.
   *
   * ARMv7 has no vector divide, so Eigen (1d8b82b0, pinned by ORT 1.23 and 1.28 alike) spells
   * pdiv<Packet4f> as pdiv_float_common: f * (a * preciprocal(b * f)), with f = 0.25 only when
   * |b| >= FLT_MAX / 4, and preciprocal = VRECPE refined by two VRECPS steps. No correction step,
   * so the quotient is an approximation and not RN(p / q). This kernel was "verified at 747,870 of
   * 747,870" against the x86 trace, where pdiv is an exact divps: the same mistake as every other
   * order-dependent kernel here, found this time because the ARM emulator reproduces the phone.
   *
   * Its f is always 1 here, so it is left out: q is a cubic in the reduced m alone, and m lies in
   * (-3, 0.415] for every bit pattern x can have, NaN and infinity included, so |q| stays under
   * 10 and never nears FLT_MAX / 4. Multiplying by 1.0f is exact, so dropping the two products
   * and the select changes no bit. */
  float32x4_t rec = vrecpeq_f32(q);
  rec = vmulq_f32(zf_recpsq(q, rec), rec);
  rec = vmulq_f32(zf_recpsq(q, rec), rec);
  const float32x4_t div = vmulq_f32(p, rec);
  const float32x4_t r =
      vmlaq_f32(div, e, vdupq_n_f32(0.693147180559945309417232121458176568f));
  if (!specials) return r;
  /* Eigen's special values: +inf stays +inf, 0 is -inf, negatives and NaN are NaN. The direct
   * swoosh relies on the first: its Where guard replaces Log(Exp(z) + 1) by z exactly when the
   * logarithm came out +inf, which only a real +inf here can produce. */
  const uint32x4_t invalid = vmvnq_u32(vcgeq_f32(x, vdupq_n_f32(0.0f)));
  const uint32x4_t iszero = vceqq_f32(x, vdupq_n_f32(0.0f));
  const uint32x4_t isinf = vceqq_f32(x, vdupq_n_f32(__builtin_inff()));
  float32x4_t out = vbslq_f32(isinf, vdupq_n_f32(__builtin_inff()), r);
  out = vreinterpretq_f32_u32(vorrq_u32(vreinterpretq_u32_f32(out), invalid));
  return vbslq_f32(iszero, vdupq_n_f32(-__builtin_inff()), out);
}
static inline float32x4_t zf_log_ort_f32(float32x4_t x) { return zf_log_ort_sp(x, 1); }

/* zf_exp_ort_f32 for x <= 0 only, where the only use of its result is 1 + exp(x).
 *
 * The upper clamp and the upper half of the scale split cannot act when x <= 0 (m <= 0). The
 * lower half, which carries 2^m for m < -126 as a second factor, is replaced by clamping the
 * scale at 2^-126: in those lanes MLAS gives exactly +0 (its product is below 2^-126 and NEON
 * flushes it), and this gives at most 1.42 * 2^-126, and 1 + either rounds to 1. Where m >= -126
 * the second factor is 1.0f, so x * 1.0f and 1.0f + p * x are the same values as before. NaN
 * comes out as some value, but the caller's Max(0, z) already makes that lane the default NaN. */
static inline float32x4_t zf_exp_ort_nonpos_f32(float32x4_t x) {
  const float32x4_t magic = vdupq_n_f32(12582912.0f);
  x = vmaxq_f32(x, vdupq_n_f32(-103.9720840454f));
  const float32x4_t biased = vmlaq_f32(magic, x, vdupq_n_f32(1.44269504088896341f));
  const float32x4_t m = vsubq_f32(biased, magic);
  x = vmlaq_f32(x, m, vdupq_n_f32(-6.93145752e-1f));
  x = vmlaq_f32(x, m, vdupq_n_f32(-1.42860677e-6f));
  const int32x4_t normal = vaddq_s32(
      vmaxq_s32(vshlq_n_s32(vreinterpretq_s32_f32(biased), 23), vdupq_n_s32((int32_t)0xC1000000)),
      vdupq_n_s32(0x3F800000));
  float32x4_t p = vdupq_n_f32(0x1.694000p-10f);
  p = vmlaq_f32(vdupq_n_f32(0x1.125edcp-7f), p, x);
  p = vmlaq_f32(vdupq_n_f32(0x1.555b5ap-5f), p, x);
  p = vmlaq_f32(vdupq_n_f32(0x1.555450p-3f), p, x);
  p = vmlaq_f32(vdupq_n_f32(0x1.fffff6p-2f), p, x);
  p = vmlaq_f32(vdupq_n_f32(0x1.000000p+0f), p, x);
  p = vmlaq_f32(vdupq_n_f32(1.0f), p, x);
  return vmulq_f32(p, vreinterpretq_f32_s32(normal));
}

/* ZF_SWOOSH_ORT: compute softplus as the four front end sites spell it, Max(0,z) + Log(1 + u),
 * with the two kernels above, instead of the atanh series in u/(2+u).
 *
 * The graph uses two different spellings. The four convolutional front end sites are stable,
 * Max(0, z) + Log(Add(1, Exp(Neg(Abs(z))))); all 80 in the encoder are direct,
 * Log(Add(Exp(Sub(x, c)), 1)) with a Where guard on +inf. The engine has one swoosh for both, so
 * this switch picks which of the two it is faithful to. Off by default, because the encoder is
 * 80 sites against the front end's four. */
static int swoosh_ort(void) {
  static _Atomic int on = -1;
  if (on < 0) {
    const char *v = zf_getenv("ZF_SWOOSH_ORT");
    on = v && atoi(v);
  }
  return on;
}

static void __attribute__((noinline)) swoosh_exp_tile(const float *x, float *u, float offset,
                                                      int n) {
  const float32x4_t voff = vdupq_n_f32(offset);
  int i = 0;
  for (; i + 8 <= n; i += 8) { /* two chains, so the exponential's latency overlaps */
    const float32x4_t z0 = vsubq_f32(vld1q_f32(x + i), voff);
    const float32x4_t z1 = vsubq_f32(vld1q_f32(x + i + 4), voff);
    if (swoosh_ort()) {
      vst1q_f32(u + i, zf_exp_ort_f32(zf_negabsq_f32(z0)));
      vst1q_f32(u + i + 4, zf_exp_ort_f32(zf_negabsq_f32(z1)));
    } else {
      vst1q_f32(u + i, zf_expq_np_f32(zf_negabsq_f32(z0)));
      vst1q_f32(u + i + 4, zf_expq_np_f32(zf_negabsq_f32(z1)));
    }
  }
  for (; i + 4 <= n; i += 4) {
    const float32x4_t z = vsubq_f32(vld1q_f32(x + i), voff);
    vst1q_f32(u + i, swoosh_ort() ? zf_exp_ort_f32(zf_negabsq_f32(z))
                                  : zf_expq_np_f32(zf_negabsq_f32(z)));
  }
}

static void __attribute__((noinline)) swoosh_tail_tile(const float *x, const float *u, float *y,
                                                       float offset, float constant, int n) {
  const float32x4_t voff = vdupq_n_f32(offset), vconst = vdupq_n_f32(constant);
  const float32x4_t two = vdupq_n_f32(2.0f), zero = vdupq_n_f32(0.0f), k08 = vdupq_n_f32(0.08f);
  const float32x4_t a3 = vdupq_n_f32(1.0f / 3.0f), a5 = vdupq_n_f32(1.0f / 5.0f);
  const float32x4_t a7 = vdupq_n_f32(1.0f / 7.0f), a9 = vdupq_n_f32(1.0f / 9.0f);
  for (int i = 0; i + 4 <= n; i += 4) {
    const float32x4_t xv = vld1q_f32(x + i);
    const float32x4_t z = vsubq_f32(xv, voff);
    const float32x4_t uu = vld1q_f32(u + i);
    if (swoosh_ort()) {
      const float32x4_t sp =
          vaddq_f32(vmaxq_f32(z, zero), zf_log_ort_f32(vaddq_f32(vdupq_n_f32(1.0f), uu)));
      vst1q_f32(y + i, vsubq_f32(vsubq_f32(sp, vmulq_f32(k08, xv)), vconst));
      continue;
    }
    const float32x4_t t = vmulq_f32(uu, zf_recipq_f32(vaddq_f32(two, uu)));
    const float32x4_t t2 = vmulq_f32(t, t);
    float32x4_t series = vmlaq_f32(a7, a9, t2);
    series = vmlaq_f32(a5, series, t2);
    series = vmlaq_f32(a3, series, t2);
    series = vmlaq_f32(vdupq_n_f32(1.0f), series, t2);
    const float32x4_t softplus = vaddq_f32(vmaxq_f32(z, zero), vmulq_f32(vmulq_f32(two, t), series));
    vst1q_f32(y + i, vsubq_f32(vsubq_f32(softplus, vmulq_f32(k08, xv)), vconst));
  }
}
#endif

static void swoosh(const float *x, float *y, size_t n, float offset, float constant) {
  if (zf_exact_math()) { swoosh_libm(x, y, n, offset, constant); return; }
  size_t i = 0;
#if ZF_NEON
  {
    float u[ZF_SWOOSH_TILE];
    while (i + 4 <= n) {
      size_t take = n - i;
      if (take > (size_t)ZF_SWOOSH_TILE) take = (size_t)ZF_SWOOSH_TILE;
      take &= ~(size_t)3; /* whole vectors here; the scalar tail below keeps the residue */
      swoosh_exp_tile(x + i, u, offset, (int)take);
      swoosh_tail_tile(x + i, u, y + i, offset, constant, (int)take);
      i += take;
    }
  }
#endif
  for (; i < n; ++i) {
    const float z = x[i] - offset;
    const float u = expf(-fabsf(z));
    const float t = u / (2.0f + u);
    const float t2 = t * t;
    const float series = 1.0f + t2 * (1.0f / 3.0f + t2 * (1.0f / 5.0f + t2 * (1.0f / 7.0f + t2 / 9.0f)));
    y[i] = (fmaxf(z, 0.0f) + 2.0f * t * series) - 0.08f * x[i] - constant;
  }
}

/* ZF_CONV_ORT, element-wise: sigmoid, tanh and both swoosh spellings exactly as ONNX Runtime
 * computes them on ARM32, v1.28.2.
 *
 * All four were identified at 100 per cent last time and then reverted, because each measured
 * worse on its own. That was the non-additivity trap and not a verdict on the kernels: a faithful
 * sigmoid fed an unfaithful input is not a faithful output, so none of them could show until the
 * convolutions, the softmax and the attention products were exact too. They are all behind the
 * one switch now, which is the only way any of them can be judged.
 *
 *   Sigmoid  MlasComputeLogistic: clamp to [-18, 18], an odd degree 9 over even degree 10
 *            rational in x*x, + 0.5, clamp to [0, 1].
 *   Tanh     MlasComputeTanh: clamp to [-9, 9], degree 13 over degree 6, no offset.
 *            Both divide with MlasDivideFloat32x4, which on NEON32 is four SCALAR divides, so this
 *            does the same (zf_swdiv_f32): a NEON reciprocal would be a different number.
 *   Swoosh   the graph spells it two ways and each site is computed its own way:
 *            front end (4 sites)  Max(z, 0) + Log(1 + Exp(-|z|)), then - 0.08x, then - c
 *            encoder  (80 sites)  Where(l == inf, z, l) with l = Log(Exp(z) + 1), then - 0.08x,
 *                                 then - c; 48 SwooshL (z = x - 4, c = 0.035) and 32 SwooshR
 *                                 (z = x - 1, c = 0.313261688), checked programmatically on the
 *                                 graph ORT actually executes.
 *            Exp is MLAS's MlasComputeExp and Log is Eigen's plog, both already verified at
 *            747,870 of 747,870 against ORT on the phone.
 *
 * Tails. ORT runs each of these over a whole tensor whose size is a multiple of four here, so
 * every element takes the NEON path. The engine calls them over task slices that need not be, so
 * the remainder is computed in a zero-padded vector rather than in scalar code: ARMv7 NEON always
 * flushes denormals and scalar VFP does not, and libm is not MLAS. */
#if ZF_NEON
static int zf_ort_mode(void) {
  static _Atomic int on = -1;
  if (on < 0) {
    const char *v = zf_getenv("ZF_CONV_ORT");
    on = v && atoi(v);
  }
  return on;
}

static inline float32x4_t zf_logistic_ort_f32(float32x4_t v) {
  v = vmaxq_f32(vdupq_n_f32(-18.0f), v);
  v = vminq_f32(vdupq_n_f32(18.0f), v);
  const float32x4_t v2 = vmulq_f32(v, v);
  float32x4_t p = vmlaq_f32(vdupq_n_f32(1.15627324459942e-07f), v2, vdupq_n_f32(4.37031012579801e-11f));
  p = vmlaq_f32(vdupq_n_f32(6.08574864600143e-05f), p, v2);
  p = vmlaq_f32(vdupq_n_f32(8.51377133304701e-03f), p, v2);
  p = vmlaq_f32(vdupq_n_f32(2.48287947061529e-01f), p, v2);
  p = vmulq_f32(p, v);
  float32x4_t q = vmlaq_f32(vdupq_n_f32(5.76102136993427e-09f), v2, vdupq_n_f32(6.10247389755681e-13f));
  q = vmlaq_f32(vdupq_n_f32(6.29106785017040e-06f), q, v2);
  q = vmlaq_f32(vdupq_n_f32(1.70198817374094e-03f), q, v2);
  q = vmlaq_f32(vdupq_n_f32(1.16817656904453e-01f), q, v2);
  q = vmlaq_f32(vdupq_n_f32(9.93151921023180e-01f), q, v2);
  const float32x4_t r =
      vaddq_f32(zf_fmadiv() ? zf_divq_exact_f32(p, q) : zf_swdiv_f32(p, q), vdupq_n_f32(0.5f));
  return vminq_f32(vdupq_n_f32(1.0f), vmaxq_f32(vdupq_n_f32(0.0f), r));
}

static inline float32x4_t zf_tanh_ort_f32(float32x4_t v) {
  v = vmaxq_f32(vdupq_n_f32(-9.0f), v);
  v = vminq_f32(vdupq_n_f32(9.0f), v);
  const float32x4_t v2 = vmulq_f32(v, v);
  float32x4_t p = vmlaq_f32(vdupq_n_f32(2.00018790482477e-13f), v2, vdupq_n_f32(-2.76076847742355e-16f));
  p = vmlaq_f32(vdupq_n_f32(-8.60467152213735e-11f), p, v2);
  p = vmlaq_f32(vdupq_n_f32(5.12229709037114e-08f), p, v2);
  p = vmlaq_f32(vdupq_n_f32(1.48572235717979e-05f), p, v2);
  p = vmlaq_f32(vdupq_n_f32(6.37261928875436e-04f), p, v2);
  p = vmlaq_f32(vdupq_n_f32(4.89352455891786e-03f), p, v2);
  p = vmulq_f32(p, v);
  float32x4_t q = vmlaq_f32(vdupq_n_f32(1.18534705686654e-04f), v2, vdupq_n_f32(1.19825839466702e-06f));
  q = vmlaq_f32(vdupq_n_f32(2.26843463243900e-03f), q, v2);
  q = vmlaq_f32(vdupq_n_f32(4.89352518554385e-03f), q, v2);
  return zf_fmadiv() ? zf_divq_exact_f32(p, q) : zf_swdiv_f32(p, q);
}

/* The encoder's swoosh, as the graph spells it. */
static inline float32x4_t zf_swoosh_direct_ort(float32x4_t x, float32x4_t off, float32x4_t c) {
  const float32x4_t z = vsubq_f32(x, off);
  /* The logarithm's argument a = exp(z) + 1 is at least 1 or NaN, so of Eigen's special values
   * only +inf can matter, and its output is +inf exactly when a is: the guard can test a and the
   * logarithm can skip its selects. A NaN lane needs nothing, because x is then NaN and the
   * x * 0.08 below makes the result the default NaN whatever w holds. */
  const float32x4_t a = vaddq_f32(zf_exp_ort_f32(z), vdupq_n_f32(1.0f));
  const uint32x4_t isinf = vceqq_f32(a, vdupq_n_f32(__builtin_inff()));
  const float32x4_t w = vbslq_f32(isinf, z, zf_log_ort_sp(a, 0));
  return vsubq_f32(vsubq_f32(w, vmulq_f32(x, vdupq_n_f32(0.08f))), c);
}

/* The front end's swoosh, as the graph spells it. */
static inline float32x4_t zf_swoosh_stable_ort(float32x4_t x, float32x4_t off, float32x4_t c) {
  const float32x4_t z = vsubq_f32(x, off);
  /* 1 + u is in [1, 2], so the logarithm's special values cannot arise */
  const float32x4_t u = zf_exp_ort_nonpos_f32(zf_negabsq_f32(z));
  const float32x4_t sp = vaddq_f32(vmaxq_f32(vdupq_n_f32(0.0f), z),
                                   zf_log_ort_sp(vaddq_f32(vdupq_n_f32(1.0f), u), 0));
  return vsubq_f32(vsubq_f32(sp, vmulq_f32(x, vdupq_n_f32(0.08f))), c);
}

/* Apply one of the above over n values, the remainder in a zero-padded vector.
 *
 * Refuted: two to four vectors per iteration, so the in-order A53 could fill one chain's stalls
 * with another's. 51 to 54 ns a value against 50: these loops are bound by NEON issue (a q
 * operation is two cycles on this core) and the extra chains only add spills. What moves them
 * is fewer operations.
 *
 * Refuted too: two passes over a 64-value block, exp into a buffer and then log, so each loop needs
 * half the constants and stops reloading them from the stack. 46 to 50 ns against 41, same bits:
 * the reloads were cheaper than the extra store, load and loop. */
/* On AArch64, four vectors an iteration first. Refuted on the A53 (below), where the loop is bound
 * by NEON issue and sixteen q registers spill; AArch64 has thirty-two, and an out-of-order core
 * like Apple's is bound instead by each vector's dependent chain of some thirty operations, which
 * four independent chains overlap. Every value goes through exactly the same operations. */
#if ZF_NEON_A64
#define ZF_ORT_UNROLL4(fn_expr)                                                  \
    for (; i_ + 16 <= n; i_ += 16) {                                             \
      float32x4_t r0_, r1_, r2_, r3_;                                            \
      { const float32x4_t v = vld1q_f32(x + i_);      r0_ = fn_expr; }           \
      { const float32x4_t v = vld1q_f32(x + i_ + 4);  r1_ = fn_expr; }           \
      { const float32x4_t v = vld1q_f32(x + i_ + 8);  r2_ = fn_expr; }           \
      { const float32x4_t v = vld1q_f32(x + i_ + 12); r3_ = fn_expr; }           \
      vst1q_f32(y + i_, r0_);                                                    \
      vst1q_f32(y + i_ + 4, r1_);                                                \
      vst1q_f32(y + i_ + 8, r2_);                                                \
      vst1q_f32(y + i_ + 12, r3_);                                               \
    }
#else
#define ZF_ORT_UNROLL4(fn_expr)
#endif
#define ZF_ORT_ELEMENTWISE(fn_expr)                                              \
  do {                                                                           \
    size_t i_ = 0;                                                               \
    ZF_ORT_UNROLL4(fn_expr)                                                      \
    for (; i_ + 4 <= n; i_ += 4) {                                               \
      const float32x4_t v = vld1q_f32(x + i_);                                   \
      vst1q_f32(y + i_, fn_expr);                                                \
    }                                                                            \
    if (i_ < n) {                                                                \
      float t_[4] = {0.0f, 0.0f, 0.0f, 0.0f};                                    \
      for (size_t k_ = 0; i_ + k_ < n; ++k_) t_[k_] = x[i_ + k_];                \
      const float32x4_t v = vld1q_f32(t_);                                       \
      vst1q_f32(t_, fn_expr);                                                    \
      for (size_t k_ = 0; i_ + k_ < n; ++k_) y[i_ + k_] = t_[k_];                \
    }                                                                            \
  } while (0)
#endif

void zf_sigmoid_f32(const float *x, float *y, size_t n) {
#if ZF_NEON
  if (zf_ort_mode()) {
    ZF_ORT_ELEMENTWISE(zf_logistic_ort_f32(v));
    return;
  }
#endif
  size_t i = 0;
#if ZF_NEON
  const float32x4_t one = vdupq_n_f32(1.0f);
  /* Two vectors an iteration: this kernel was short of independent work, not of work.
   *
   * The exponential reduces its argument and then runs six multiply-adds where each waits on the
   * one before. On this in-order core a vector multiply-add is about eight cycles of latency, so a
   * single chain leaves the pipeline with nothing to issue for most of them. Measured per value at
   * 1.274 GHz: 36 cycles for one chain, 20.9 for two, against a throughput floor of about 16.5.
   * Four chains measured worse, and the same treatment does nothing at all for swoosh below, which
   * turns out to be issue-bound rather than latency-bound: see docs/costmodel.md.
   *
   * No value's arithmetic changes and each chain keeps its order, so the results are the same bit
   * patterns. The loop below is the old one, for counts that are not a multiple of eight. */
  if (!zf_exact_math()) {
    for (; i + 8 <= n; i += 8) {
      const float32x4_t ea = zf_expq_f32(vnegq_f32(vld1q_f32(x + i)));
      const float32x4_t eb = zf_expq_f32(vnegq_f32(vld1q_f32(x + i + 4)));
      vst1q_f32(y + i, zf_recipq_f32(vaddq_f32(one, ea)));
      vst1q_f32(y + i + 4, zf_recipq_f32(vaddq_f32(one, eb)));
    }
    for (; i + 4 <= n; i += 4) {
      const float32x4_t e = zf_expq_f32(vnegq_f32(vld1q_f32(x + i)));
      vst1q_f32(y + i, zf_recipq_f32(vaddq_f32(one, e)));
    }
  }
#endif
  for (; i < n; ++i) y[i] = 1.0f / (1.0f + expf(-x[i]));
}

void zf_tanh_f32(const float *x, float *y, size_t n) {
#if ZF_NEON
  if (zf_ort_mode()) {
    ZF_ORT_ELEMENTWISE(zf_tanh_ort_f32(v));
    return;
  }
#endif
  size_t i = 0;
#if ZF_NEON
  /* tanh(x) = 1 - 2 / (exp(2x) + 1), which reuses the same exp */
  const float32x4_t one = vdupq_n_f32(1.0f), two = vdupq_n_f32(2.0f);
  if (!zf_exact_math()) {
    for (; i + 4 <= n; i += 4) {
      const float32x4_t v = vld1q_f32(x + i);
      const float32x4_t e = zf_expq_f32(vaddq_f32(v, v));
      vst1q_f32(y + i, vsubq_f32(one, vmulq_f32(two, zf_recipq_f32(vaddq_f32(e, one)))));
    }
  }
#endif
  for (; i < n; ++i) y[i] = tanhf(x[i]);
}

/* ZF_CONV_ORT, softmax: the attention softmax exactly as MLAS computes it on ARM32.
 *
 * Read off compute.cpp at v1.23.2, where the generic kernels are what this target runs, since
 * ARM32 has no MLAS platform table. The engine's own softmax differed from it in three places,
 * none of which the device trace could show, because the trace carries no encoder tensor:
 *
 *   1. The exponential. MLAS's softmax does not call its Exp kernel. It calls
 *      MlasComputeSumExpVector: clamp from below at -88.3762626647949, one scale factor rather
 *      than two, and the last polynomial constant applied twice. The engine used its own
 *      Cephes-style exp, a different polynomial altogether, on every score.
 *   2. The horizontal add. MlasReduceAddFloat32x4 on NEON32 is vpadd(low, high) twice, which is
 *      (l0 + l1) + (h0 + h1). The engine added low to high first, (l0 + h0) + (l1 + h1). Every
 *      row of every head was paired the other way.
 *   3. The tail. Past the last whole vector MLAS still uses its polynomial, one element at a time
 *      in a broadcast vector, and adds each to the scalar sum. The engine called libm expf. With
 *      S = 70 and S = 35 in the deep stacks that is two and three keys a row, and they are the
 *      current chunk's own frames.
 *
 * Everything else already matched: one vector accumulator with two exponentials added in order,
 * x + (-max) being bitwise x - max, 1.0f / sum, and a multiply that is vector for the first
 * floor(n/4)*4 elements and scalar after. That split matters and is kept: ARMv7 NEON always
 * flushes denormals and scalar VFP on Android does not, so which unit touches an element is part
 * of its value. */
#if ZF_NEON
/* MlasComputeSumExpVector, line for line. MlasMultiplyAddFloat32x4(a, b, c) is vmlaq_f32(c, a, b)
 * on MLAS_TARGET_ARM, a chained multiply-add, which is what these are. */
static inline float32x4_t zf_sumexpq_ort_f32(float32x4_t v, float32x4_t negmax) {
  const float32x4_t magic = vdupq_n_f32(12582912.0f);
  v = vaddq_f32(v, negmax);
  v = vmaxq_f32(vdupq_n_f32(-88.3762626647949f), v);
  const float32x4_t biased = vmlaq_f32(magic, v, vdupq_n_f32(1.44269504088896341f));
  const float32x4_t m = vsubq_f32(biased, magic);
  v = vmlaq_f32(v, m, vdupq_n_f32(-6.93145752e-1f));
  v = vmlaq_f32(v, m, vdupq_n_f32(-1.42860677e-6f));
  const int32x4_t normal =
      vaddq_s32(vshlq_n_s32(vreinterpretq_s32_f32(biased), 23), vdupq_n_s32(0x3F800000));
  float32x4_t p = vdupq_n_f32(0x1.694000p-10f);
  p = vmlaq_f32(vdupq_n_f32(0x1.125edcp-7f), p, v);
  p = vmlaq_f32(vdupq_n_f32(0x1.555b5ap-5f), p, v);
  p = vmlaq_f32(vdupq_n_f32(0x1.555450p-3f), p, v);
  p = vmlaq_f32(vdupq_n_f32(0x1.fffff6p-2f), p, v);
  p = vmlaq_f32(vdupq_n_f32(0x1.000000p+0f), p, v);
  p = vmlaq_f32(vdupq_n_f32(0x1.000000p+0f), p, v);
  return vmulq_f32(p, vreinterpretq_f32_s32(normal));
}

/* One row of MlasComputeSoftmaxThreaded: maximum, MlasComputeSumExpF32Kernel, then
 * MlasComputeSoftmaxOutputF32Kernel with 1.0f / sum. The maximum is order independent. */
static void zf_softmax_row_ort(float *row, int n, float best) {
  const float32x4_t negmax = vdupq_n_f32(-best);
  float sum = 0.0f;
  int j = 0;
  if (n >= 4) {
    float32x4_t acc = vdupq_n_f32(0.0f);
    for (; j + 8 <= n; j += 8) {
      const float32x4_t e0 = zf_sumexpq_ort_f32(vld1q_f32(row + j), negmax);
      const float32x4_t e1 = zf_sumexpq_ort_f32(vld1q_f32(row + j + 4), negmax);
      acc = vaddq_f32(acc, e0);
      acc = vaddq_f32(acc, e1);
      vst1q_f32(row + j, e0);
      vst1q_f32(row + j + 4, e1);
    }
    for (; j + 4 <= n; j += 4) {
      const float32x4_t e = zf_sumexpq_ort_f32(vld1q_f32(row + j), negmax);
      acc = vaddq_f32(acc, e);
      vst1q_f32(row + j, e);
    }
    float32x2_t lo = vget_low_f32(acc);
    const float32x2_t hi = vget_high_f32(acc);
    lo = vpadd_f32(lo, hi);
    lo = vpadd_f32(lo, hi);
    sum = vget_lane_f32(lo, 0);
  }
  for (; j < n; ++j) {
    const float e = vgetq_lane_f32(zf_sumexpq_ort_f32(vdupq_n_f32(row[j]), negmax), 0);
    sum += e;
    row[j] = e;
  }
  const float scale = 1.0f / sum;
  const float32x4_t sv = vdupq_n_f32(scale);
  j = 0;
  for (; j + 4 <= n; j += 4) vst1q_f32(row + j, vmulq_f32(sv, vld1q_f32(row + j)));
  for (; j < n; ++j) row[j] *= scale;
}
#endif

void zf_softmax_rows_f32(float *x, int rows, int n) {
#if ZF_NEON
  if (zf_ort_mode()) {
    for (int r = 0; r < rows; ++r) {
      float *row = x + (size_t)r * n;
      float best = row[0];
      int j = 0;
      if (n >= 4) {
        float32x4_t mv = vld1q_f32(row);
        for (j = 4; j + 4 <= n; j += 4) mv = vmaxq_f32(mv, vld1q_f32(row + j));
        const float32x2_t h = vpmax_f32(vget_low_f32(mv), vget_high_f32(mv));
        best = vget_lane_f32(vpmax_f32(h, h), 0);
      }
      for (; j < n; ++j)
        if (row[j] > best) best = row[j];
      zf_softmax_row_ort(row, n, best);
    }
    return;
  }
#endif
  for (int r = 0; r < rows; ++r) {
    float *row = x + (size_t)r * n;
    int j = 0;
    float best = row[0];
#if ZF_NEON
    if (n >= 4) {
      float32x4_t m = vld1q_f32(row);
      for (j = 4; j + 4 <= n; j += 4) m = vmaxq_f32(m, vld1q_f32(row + j));
      const float32x2_t h = vpmax_f32(vget_low_f32(m), vget_high_f32(m));
      best = vget_lane_f32(vpmax_f32(h, h), 0);
    }
#endif
    for (; j < n; ++j)
      if (row[j] > best) best = row[j];

    float sum = 0.0f;
    j = 0;
#if ZF_NEON
    if (!zf_exact_math()) {
      const float32x4_t bv = vdupq_n_f32(best);
      float32x4_t acc = vdupq_n_f32(0.0f);
      /* Two exponentials in flight against ONE accumulator.
       *
       * The exponential is a long dependent chain and the loop ran one of them at a time, so each
       * iteration waited out its latency. Two independent chains overlap; the accumulator stays
       * single and is added to in the same order the four-wide loop used, which is what keeps the
       * sum bit-identical -- two accumulators combined at the end would regroup the additions and
       * that is a different float. best is the row's maximum, so the argument cannot be positive
       * and the exponential's upper clamp can never select 88.0f. */
      for (; j + 8 <= n; j += 8) {
        const float32x4_t ea = zf_expq_np_f32(vsubq_f32(vld1q_f32(row + j), bv));
        const float32x4_t eb = zf_expq_np_f32(vsubq_f32(vld1q_f32(row + j + 4), bv));
        vst1q_f32(row + j, ea);
        vst1q_f32(row + j + 4, eb);
        acc = vaddq_f32(acc, ea);
        acc = vaddq_f32(acc, eb);
      }
      for (; j + 4 <= n; j += 4) {
        const float32x4_t e = zf_expq_np_f32(vsubq_f32(vld1q_f32(row + j), bv));
        vst1q_f32(row + j, e);
        acc = vaddq_f32(acc, e);
      }
      const float32x2_t h = vadd_f32(vget_low_f32(acc), vget_high_f32(acc));
      sum = vget_lane_f32(h, 0) + vget_lane_f32(h, 1);
    }
#endif
    for (; j < n; ++j) {
      row[j] = expf(row[j] - best);
      sum += row[j];
    }
    const float inv = 1.0f / sum;
    j = 0;
#if ZF_NEON
    {
      const float32x4_t iv = vdupq_n_f32(inv);
      for (; j + 4 <= n; j += 4) vst1q_f32(row + j, vmulq_f32(vld1q_f32(row + j), iv));
    }
#endif
    for (; j < n; ++j) row[j] *= inv;
  }
}


void zf_dequantize_range_t(const int32_t *acc, int m, int ldc, const float *scale, int scale_count,
                           const float *bias, float *y, int ldy, int begin, int end) {
  int j = begin;
#if ZF_NEON
  for (; j + 4 <= end; j += 4) {
    float sc[4], bi[4];
    for (int u = 0; u < 4; ++u) {
      sc[u] = (scale_count == 1) ? scale[0] : scale[j + u];
      bi[u] = bias ? bias[j + u] : 0.0f;
    }
    int i = 0;
    for (; i + 4 <= m; i += 4)
      deq_t_tile4(acc + (size_t)i * ldc + j, ldc, sc, bi, y + (size_t)j * ldy + i, ldy);
    for (; i < m; ++i)
      for (int u = 0; u < 4; ++u)
        y[(size_t)(j + u) * ldy + i] = (float)acc[(size_t)i * ldc + j + u] * sc[u] + bi[u];
  }
#endif
  for (; j < end; ++j) {
    const float sc = (scale_count == 1) ? scale[0] : scale[j];
    const float bi = bias ? bias[j] : 0.0f;
    float *row = y + (size_t)j * ldy;
    for (int i = 0; i < m; ++i) row[i] = (float)acc[(size_t)i * ldc + j] * sc + bi;
  }
}

void zf_quantize_range_cols(const float *x, int k, int rows, int ldx, float *lo, float *hi) {
  float mn = 0.0f, mx = 0.0f;
  for (int c = 0; c < k; ++c) {
    const float *row = x + (size_t)c * ldx;
    int i = 0;
#if ZF_NEON
    float32x4_t vmn = vdupq_n_f32(0.0f), vmx = vmn;
    for (; i + 4 <= rows; i += 4) {
      const float32x4_t v = vld1q_f32(row + i);
      vmn = vminq_f32(vmn, v);
      vmx = vmaxq_f32(vmx, v);
    }
    {
      float t[4];
      vst1q_f32(t, vmn);
      for (int u = 0; u < 4; ++u) if (t[u] < mn) mn = t[u];
      vst1q_f32(t, vmx);
      for (int u = 0; u < 4; ++u) if (t[u] > mx) mx = t[u];
    }
#endif
    for (; i < rows; ++i) {
      if (row[i] < mn) mn = row[i];
      if (row[i] > mx) mx = row[i];
    }
  }
  *lo = mn;
  *hi = mx;
}

void zf_quantize_write_cols(const float *x, int k, int ldx, int lda, int8_t *a, float scale,
                            int zero_point, int row0, int row1) {
  const float qinv = ZF_QINV(scale);
  const int shift = zero_point - 128;
  for (int r = row0; r < row1; ++r) {
    int8_t *dst = a + (size_t)r * lda;
    int c = 0;
#if ZF_NEON
    const float32x4_t vsc = vdupq_n_f32(scale), vinv = vdupq_n_f32(qinv);
    const float32x4_t magic = vdupq_n_f32(ZF_ROUND_MAGIC);
    const int32x4_t vshift = vdupq_n_s32(zero_point - 128);
    for (; c + 4 <= k; c += 4) {
      float32x4_t v = vdupq_n_f32(x[(size_t)(c + 0) * ldx + r]);
      v = vsetq_lane_f32(x[(size_t)(c + 1) * ldx + r], v, 1);
      v = vsetq_lane_f32(x[(size_t)(c + 2) * ldx + r], v, 2);
      v = vsetq_lane_f32(x[(size_t)(c + 3) * ldx + r], v, 3);
      v = zf_qscale_q(v, vsc, vinv);
      v = vsubq_f32(vaddq_f32(v, magic), magic);
      const int32x4_t q = vaddq_s32(vcvtq_s32_f32(v), vshift);
      const int16x4_t h = vqmovn_s32(q);
      const int8x8_t b = vqmovn_s16(vcombine_s16(h, h));
      vst1_lane_u32((uint32_t *)(dst + c), vreinterpret_u32_s8(b), 0);
    }
#endif
    for (; c < k; ++c) {
      float v = ZF_QSCALE_S(x[(size_t)c * ldx + r], scale, qinv);
      v = (v + ZF_ROUND_MAGIC) - ZF_ROUND_MAGIC;
      int q = (int)(v + shift);
      if (q > 127) q = 127;
      if (q < -128) q = -128;
      dst[c] = (int8_t)q;
    }
    for (int j = k; j < lda; ++j) dst[j] = 0;
  }
}

/* The encoder's sites. Under ZF_CONV_ORT, the graph's direct spelling. */
void zf_swoosh_l_at(const float *x, float *y, size_t n, float offset) {
#if ZF_NEON
  if (zf_ort_mode()) {
    const float32x4_t off = vdupq_n_f32(offset), c = vdupq_n_f32(0.035f);
    ZF_ORT_ELEMENTWISE(zf_swoosh_direct_ort(v, off, c));
    return;
  }
#endif
  swoosh(x, y, n, offset, 0.035f);
}
void zf_swoosh_l(const float *x, float *y, size_t n) { zf_swoosh_l_at(x, y, n, 4.0f); }
void zf_swoosh_r(const float *x, float *y, size_t n) {
#if ZF_NEON
  if (zf_ort_mode()) {
    const float32x4_t off = vdupq_n_f32(1.0f), c = vdupq_n_f32(0.313261687f);
    ZF_ORT_ELEMENTWISE(zf_swoosh_direct_ort(v, off, c));
    return;
  }
#endif
  swoosh(x, y, n, 1.0f, 0.313261687f);
}

/* The front end's four sites. Under ZF_CONV_ORT, the graph's stable spelling; otherwise the same
 * as the encoder's, which is what they always were.
 *
 * ZF_FE_RAW=1 turns them into copies, so a ZF_FE_DUMP holds the convolutions' raw outputs and a
 * difference can be pinned on the convolution or on the activation. Diagnostic only: everything
 * downstream of it is wrong on purpose. */
static int zf_fe_raw(void) {
  static _Atomic int on = -1;
  if (on < 0) {
    const char *v = zf_getenv("ZF_FE_RAW");
    on = v && atoi(v);
  }
  return on;
}

static void swoosh_l_fe_at(const float *x, float *y, size_t n, float offset) {
  if (zf_fe_raw()) {
    if (y != x) memmove(y, x, n * sizeof(float));
    return;
  }
#if ZF_NEON
  if (zf_ort_mode()) {
    const float32x4_t off = vdupq_n_f32(offset), c = vdupq_n_f32(0.035f);
    ZF_ORT_ELEMENTWISE(zf_swoosh_stable_ort(v, off, c));
    return;
  }
#endif
  swoosh(x, y, n, offset, 0.035f);
}
void zf_swoosh_l_fe(const float *x, float *y, size_t n) { swoosh_l_fe_at(x, y, n, 4.0f); }
void zf_swoosh_r_fe(const float *x, float *y, size_t n) {
  if (zf_fe_raw()) {
    if (y != x) memmove(y, x, n * sizeof(float));
    return;
  }
#if ZF_NEON
  if (zf_ort_mode()) {
    const float32x4_t off = vdupq_n_f32(1.0f), c = vdupq_n_f32(0.313261687f);
    ZF_ORT_ELEMENTWISE(zf_swoosh_stable_ort(v, off, c));
    return;
  }
#endif
  swoosh(x, y, n, 1.0f, 0.313261687f);
}

void zf_swoosh_fe(const float *x, float *y, size_t n, int variant) {
  if (variant == ZF_SWOOSH_R) zf_swoosh_r_fe(x, y, n);
  else if (variant == ZF_SWOOSH_L1) swoosh_l_fe_at(x, y, n, 1.0f);
  else zf_swoosh_l_fe(x, y, n);
}

/* LogSoftmax over the last axis, as ONNX Runtime computes it on ARM32 (MlasComputeSoftmax with
 * LogSoftmax set, compute.cpp at v1.28.2): the row maximum, MlasComputeSumExpF32Kernel with
 * nothing stored, std::log of the sum (libm's logf, called here for the same reason BiasNorm calls
 * powf), then (x + (-max)) - log in vectors of sixteen, then four, then one element at a time.
 * The native runner uses this for the graph's one LogSoftmax node, the CTC head's. */
void zf_log_softmax_rows_f32(const float *x, float *y, int rows, int n) {
  for (int r = 0; r < rows; ++r) {
    const float *in = x + (size_t)r * n;
    float *out = y + (size_t)r * n;
    float best = in[0];
    int j = 0;
#if ZF_NEON
    if (n >= 4) {
      float32x4_t mv = vld1q_f32(in);
      for (j = 4; j + 4 <= n; j += 4) mv = vmaxq_f32(mv, vld1q_f32(in + j));
      const float32x2_t h = vpmax_f32(vget_low_f32(mv), vget_high_f32(mv));
      best = vget_lane_f32(vpmax_f32(h, h), 0);
    }
#endif
    for (; j < n; ++j)
      if (in[j] > best) best = in[j];
    const float negmax = -best;
    float sum = 0.0f;
    j = 0;
#if ZF_NEON
    const float32x4_t nm = vdupq_n_f32(negmax);
    if (n >= 4) {
      float32x4_t acc = vdupq_n_f32(0.0f);
      for (; j + 8 <= n; j += 8) {
        acc = vaddq_f32(acc, zf_sumexpq_ort_f32(vld1q_f32(in + j), nm));
        acc = vaddq_f32(acc, zf_sumexpq_ort_f32(vld1q_f32(in + j + 4), nm));
      }
      for (; j + 4 <= n; j += 4) acc = vaddq_f32(acc, zf_sumexpq_ort_f32(vld1q_f32(in + j), nm));
      float32x2_t lo = vget_low_f32(acc);
      const float32x2_t hi = vget_high_f32(acc);
      lo = vpadd_f32(lo, hi);
      lo = vpadd_f32(lo, hi);
      sum = vget_lane_f32(lo, 0);
    }
    for (; j < n; ++j) sum += vgetq_lane_f32(zf_sumexpq_ort_f32(vdupq_n_f32(in[j]), nm), 0);
    const float lg = zf_libm_logf(sum);
    const float32x4_t lv = vdupq_n_f32(lg);
    j = 0;
    for (; j + 16 <= n; j += 16)
      for (int q = 0; q < 16; q += 4)
        vst1q_f32(out + j + q, vsubq_f32(vaddq_f32(vld1q_f32(in + j + q), nm), lv));
    for (; j + 4 <= n; j += 4) vst1q_f32(out + j, vsubq_f32(vaddq_f32(vld1q_f32(in + j), nm), lv));
#else
    for (; j < n; ++j) sum += expf(in[j] + negmax);
    const float lg = logf(sum);
    j = 0;
#endif
    for (; j < n; ++j) out[j] = in[j] + negmax - lg;
  }
}
