#include "zf/block.h"
#include "zf/env.h"
#include "zf/libm.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Diagnostic only; see the comment at its use in the norm's reduction. */
static int zf_norm_seq(void) {
  static _Atomic int on = -1;
  if (on < 0) on = zf_getenv("ZF_NORM_SEQ") != NULL;
  return on;
}

#include "zf/neon.h"
#define ZF_NEON ZF_NEON_AVAILABLE

#if ZF_NEON && defined(__arm__) && !(defined(ZF_NEON_EMU) && ZF_NEON_EMU)
#define ZF_HAVE_NT_ASM 1
/* kernels_armv7.S: four key rows against one query, five vector registers kept live. */
void zf_matmul_nt_tile4(const float *arow, const float *b, int ldb_bytes, int groups, float *out4);
/* kernels_armv7.S: four rows against four, sixteen d-register accumulators, the next step's loads
 * scheduled among this step's multiply-adds. */
#define ZF_HAVE_NT_ASM_4X4 1
void zf_matmul_nt_tile4x4(const float *a, int lda_bytes, const float *b, int ldb_bytes, int groups,
                          float *out, int ldc_bytes);
/* kernels_armv7.S: the same tile stepping k by four with q register operands, so eight loads feed
 * 64 products instead of 32. Bit identical to the above; needs four to divide k. */
void zf_matmul_nt_tile4x4_q(const float *a, int lda_bytes, const float *b, int ldb_bytes,
                            int groups, float *out, int ldc_bytes);
/* kernels_armv7.S: the MLAS-order 4x8 tile's inner loop, software pipelined. Sums each lane up k
 * from what acc holds, `steps` pairs of k. */
void zf_seq_tile4x8(const float *panel, const float *a, int lda_bytes, int steps, float *acc);
/* The same stepping k by four; quads >= 1. */
void zf_seq_tile4x8_k4(const float *panel, const float *a, int lda_bytes, int quads, float *acc);
/* A whole even stride of the tile: zeroed in registers, folded (flags & 1) and stored in place, with
 * one trailing pair of k when flags & 2. */
void zf_seq_tile4x8_st(const float *panel, const float *a, int lda_bytes, int quads, float *out,
                       int ldc_bytes, int flags);
#else
#define ZF_HAVE_NT_ASM 0
#define ZF_HAVE_NT_ASM_4X4 0
#endif

static int zf_bias_norm_ort(void) {
  static _Atomic int on = -1;
  if (on < 0) {
    const char *v = zf_getenv("ZF_CONV_ORT");
    on = v && atoi(v);
  }
  return on;
}

void zf_bias_norm(const float *x, int rows, int channels, const float *bias, float scale,
                  float *y) {
  for (int t = 0; t < rows; ++t) {
    const float *row = x + (size_t)t * channels;
    float *out = y + (size_t)t * channels;
    float sum = 0.0f;
    int c = 0;
#if ZF_NEON
    /* ZF_NORM_SEQ: sum the squares strictly in order, one channel at a time.
     *
     * Float addition is not associative, so this reduction's ORDER is part of its result. The
     * vector form below carries two accumulators over eight channels and finishes with a pairwise
     * horizontal add; the graph's ReduceMean sums in whatever order ONNX Runtime chooses. A
     * few-ULP disagreement in every layer is exactly what that would look like, and unlike the
     * transcendentals an order can be changed for free.
     *
     * This switch exists to find out whether the reduction is implicated at all, by replacing the
     * order with the most boring one available. It is a diagnostic: the scalar path is slower and
     * is not what ships. */
    if (!zf_norm_seq()) {
    float32x4_t s0 = vdupq_n_f32(0.0f), s1 = s0;
    for (; c + 8 <= channels; c += 8) {
      const float32x4_t d0 = vsubq_f32(vld1q_f32(row + c), vld1q_f32(bias + c));
      const float32x4_t d1 = vsubq_f32(vld1q_f32(row + c + 4), vld1q_f32(bias + c + 4));
      s0 = vmlaq_f32(s0, d0, d0);
      s1 = vmlaq_f32(s1, d1, d1);
    }
    {
      const float32x4_t sv = vaddq_f32(s0, s1);
      const float32x2_t h = vadd_f32(vget_low_f32(sv), vget_high_f32(sv));
      sum = vget_lane_f32(h, 0) + vget_lane_f32(h, 1);
    }
    }
#endif
    for (; c < channels; ++c) {
      const float d = row[c] - bias[c];
      sum += d * d;
    }
    /* Two scalar steps here have to be spelled the graph's way, not the equivalent way.
     *
     * The graph's BiasNorm is ReduceMean, then Pow(-0.5), then a Mul by the scale, and each of
     * those rounds to fp32. Checked against the recorded node trace on layer 0's 24 rows:
     *
     *   ReduceMean : this reduction's own order, then sum / channels, reproduces all 24 rows
     *                exactly. Multiplying by a precomputed 1.0f/channels reproduces 15 of 24,
     *                because 1/192 is not representable in binary32, and the nine that differ do
     *                so by up to 3.8e-06.
     *   Pow(-0.5)  : powf(mean, -0.5f) reproduces all 24 rows exactly. 1.0f/sqrtf(mean) does not
     *                reproduce any of them; it is about one unit in the last place out.
     *
     * The vector reduction above is already in ORT's order, which is why only these two lines
     * needed changing.
     *
     * powf gives the right answer and costs about thirty times a square root, so it is not the
     * form to ship. The reason 1.0f/sqrtf misses is double rounding: it rounds the square root to
     * binary32 and then rounds the division, where Pow rounds once. Doing the same arithmetic in
     * binary64 and rounding once at the end reproduces Pow on all 24 of layer 0's rows, the same
     * as powf, and ARMv7 has VSQRT.F64 in hardware, so it measures 1.8 ns against powf's 54.5 and
     * the original's 1.5. bench/engine/biasnorm_check.c is that measurement. */
    /* ZF_CONV_ORT: the system's own powf, because that is literally what ONNX Runtime calls.
     *
     * Its Pow kernel with a scalar exponent is std::pow(x, y) in float, which resolves to libm's
     * powf. The double square root above reproduces a CORRECTLY ROUNDED x^-0.5, and on the x86
     * trace that was the same thing. On the phone it is not: Android 11's bionic powf (ARM's
     * optimized-routines) is accurate to 0.82 ulp, not correctly rounded, and on the emulator,
     * where a correctly rounded powf stood in for it, the engine and ORT agreed byte for byte on
     * clip 0101 while the phone's ORT did not. Calling the same function from the same libm is the
     * only way to agree with it everywhere. It is about 800 calls a chunk, some 44 microseconds. */
    const float mean = sum / (float)channels;
    const float factor = zf_bias_norm_ort()
                             ? zf_libm_powf(mean, -0.5f) * scale
                             : (float)(1.0 / sqrt((double)mean)) * scale;
    c = 0;
#if ZF_NEON
    const float32x4_t fv = vdupq_n_f32(factor);
    for (; c + 8 <= channels; c += 8) {
      vst1q_f32(out + c, vmulq_f32(vld1q_f32(row + c), fv));
      vst1q_f32(out + c + 4, vmulq_f32(vld1q_f32(row + c + 4), fv));
    }
#endif
    for (; c < channels; ++c) out[c] = row[c] * factor;
  }
}

void zf_bypass(const float *a, const float *b, int rows, int channels, const float *weight,
               float *y) {
  for (int t = 0; t < rows; ++t) {
    const float *ar = a + (size_t)t * channels;
    const float *br = b + (size_t)t * channels;
    float *out = y + (size_t)t * channels;
    int c = 0;
#if ZF_NEON
    for (; c + 4 <= channels; c += 4) {
      const float32x4_t av = vld1q_f32(ar + c), bv = vld1q_f32(br + c);
      vst1q_f32(out + c, vmlaq_f32(bv, vsubq_f32(av, bv), vld1q_f32(weight + c)));
    }
#endif
    for (; c < channels; ++c) out[c] = br[c] + (ar[c] - br[c]) * weight[c];
  }
}

void zf_matmul_f32(const float *a, const float *bb, int batch, int m, int k, int n, float *y,
                   int m0, int m1) {
  for (int b = 0; b < batch; ++b) {
    const float *ab = a + (size_t)b * m * k;
    const float *bbb = bb + (size_t)b * k * n;
    float *yb = y + (size_t)b * m * n;
    for (int i = m0; i < m1; ++i) {
      const float *arow = ab + (size_t)i * k;
      float *yrow = yb + (size_t)i * n;
      int j = 0;
#if ZF_NEON
      for (; j + 16 <= n; j += 16) {
        float32x4_t c0 = vdupq_n_f32(0.0f), c1 = c0, c2 = c0, c3 = c0;
        float32x4_t d0 = vdupq_n_f32(0.0f), d1 = d0, d2 = d0, d3 = d0;
        int p = 0;
        for (; p + 2 <= k; p += 2) {
          const float *brow = bbb + (size_t)p * n + j;
          const float a0 = arow[p], a1 = arow[p + 1];
          c0 = vmlaq_n_f32(c0, vld1q_f32(brow), a0);
          c1 = vmlaq_n_f32(c1, vld1q_f32(brow + 4), a0);
          c2 = vmlaq_n_f32(c2, vld1q_f32(brow + 8), a0);
          c3 = vmlaq_n_f32(c3, vld1q_f32(brow + 12), a0);
          d0 = vmlaq_n_f32(d0, vld1q_f32(brow + n), a1);
          d1 = vmlaq_n_f32(d1, vld1q_f32(brow + n + 4), a1);
          d2 = vmlaq_n_f32(d2, vld1q_f32(brow + n + 8), a1);
          d3 = vmlaq_n_f32(d3, vld1q_f32(brow + n + 12), a1);
        }
        for (; p < k; ++p) {
          const float av = arow[p];
          const float *brow = bbb + (size_t)p * n + j;
          c0 = vmlaq_n_f32(c0, vld1q_f32(brow), av);
          c1 = vmlaq_n_f32(c1, vld1q_f32(brow + 4), av);
          c2 = vmlaq_n_f32(c2, vld1q_f32(brow + 8), av);
          c3 = vmlaq_n_f32(c3, vld1q_f32(brow + 12), av);
        }
        c0 = vaddq_f32(c0, d0);
        c1 = vaddq_f32(c1, d1);
        c2 = vaddq_f32(c2, d2);
        c3 = vaddq_f32(c3, d3);
        vst1q_f32(yrow + j, c0);
        vst1q_f32(yrow + j + 4, c1);
        vst1q_f32(yrow + j + 8, c2);
        vst1q_f32(yrow + j + 12, c3);
      }
      /* Many of these have n = 12, where one four-wide accumulator would be a single dependency
       * chain at eight cycles a link. Four accumulators over four consecutive k break it. */
      for (; j + 4 <= n; j += 4) {
        float32x4_t c0 = vdupq_n_f32(0.0f), c1 = c0, c2 = c0, c3 = c0;
        int p = 0;
        for (; p + 4 <= k; p += 4) {
          const float *brow = bbb + (size_t)p * n + j;
          c0 = vmlaq_n_f32(c0, vld1q_f32(brow), arow[p]);
          c1 = vmlaq_n_f32(c1, vld1q_f32(brow + n), arow[p + 1]);
          c2 = vmlaq_n_f32(c2, vld1q_f32(brow + 2 * n), arow[p + 2]);
          c3 = vmlaq_n_f32(c3, vld1q_f32(brow + 3 * n), arow[p + 3]);
        }
        for (; p < k; ++p)
          c0 = vmlaq_n_f32(c0, vld1q_f32(bbb + (size_t)p * n + j), arow[p]);
        vst1q_f32(yrow + j, vaddq_f32(vaddq_f32(c0, c1), vaddq_f32(c2, c3)));
      }
#endif
      for (; j < n; ++j) {
        float sum = 0.0f;
        for (int p = 0; p < k; ++p) sum += arow[p] * bbb[(size_t)p * n + j];
        yrow[j] = sum;
      }
    }
  }
}

#if ZF_NEON
/* A 4 by 4 tile in d-registers, for the shapes it divides exactly.
 *
 * The kernel below takes one row against four columns: four accumulators, five loads per four
 * multiply-add instructions. Measured against this core's fp32 ceiling it reaches a uniform 38 per
 * cent on every shape tried, the attention's included, so the limit is the tile and not the shapes.
 *
 * This core's floating point datapath is 64 bits wide, so a 128 bit VMLA.F32 issues in two passes
 * and buys nothing over the 64 bit form. What the 64 bit form buys is registers: 32 d against 16 q,
 * which is room for 16 accumulators plus four row and four column operands. Per step of two along k
 * that is 8 loads against 16 multiply-adds where the current tile is 5 against 4.
 *
 * Measured on one core, as a fraction of the 2.55 GMAdds/s ceiling, with bench/engine/f32gemm_bench:
 *
 *   shape                 current   4x4
 *   240x128x384  (pw1)      38%     49%
 *   240x384x128  (pw2)      38%     43%
 *   240x288x128  (conv2)    39%     48%
 *   960x72x32    (conv1)    36%     47%
 *   24x32x280    (attention) 34%     49%
 *
 * Results are bit identical on all of them, which is why this can stand in at all: the attention
 * runs through here, so a different summation order would move the engine's output.
 *
 * Only when 4 divides m and n and 2 divides k. The tails would sum in a different order from the
 * kernel below, and "faster" is not worth "different" here. */
/* ZF_CONV_SEQ: accumulate every dot product strictly sequentially over k, from +0.0.
 *
 * The tiled path below accumulates two k elements at a time into float32x2_t and finishes with a
 * vpadd horizontal reduction, so its summation order is pairwise. MLAS, which is what ONNX Runtime
 * runs, never reduces horizontally: each output column owns one lane of a float32x4_t and
 * accumulates strictly in increasing k from +0.0 (see mlas/lib/arm/sgemmc.cpp). Those are
 * different orders and float addition is not associative.
 *
 * This switch forces the sequential order so the hypothesis can be tested before a vectorised
 * version is written. It is slow on purpose: the scalar residue loops at the bottom of this
 * function already have exactly the order wanted, so making everything take them costs speed and
 * costs nothing in fidelity. If the front end's divergence goes away with this on, the order is
 * the cause and the fix is to vectorise this order rather than the pairwise one. */
static int conv_seq_order(void) {
  static _Atomic int on = -1;
  if (on < 0) {
    const char *v = zf_getenv("ZF_CONV_SEQ");
    const char *o = zf_getenv("ZF_CONV_ORT");
    /* ZF_CONV_ORT implies this: matching ONNX Runtime needs the sequential order and the ONNX k
     * order together, and either alone is still the wrong sum. */
    on = (v && atoi(v)) || (o && atoi(o));
  }
  return on;
}

/* The vectorised form of the sequential order.
 *
 * The scalar loop above it was written to be slow on purpose, to find out whether the order was
 * the cause before anything was built around it. It was, so this is the order that has to run at
 * speed, and the shape it wants is MLAS's own.
 *
 * The trick is which axis owns the lanes. The pairwise kernel puts k in the lanes, which is why it
 * has to finish with a vpadd and why its sum comes out pairwise. Put the OUTPUT COLUMNS in the
 * lanes instead and every lane accumulates independently, strictly in increasing k, from +0.0: the
 * sequential order falls out of the register layout and no horizontal reduction is ever needed.
 *
 * That needs b's k axis contiguous per k step rather than per column, so a block of four columns is
 * packed once into `panel` and reused down every row. b is the weight, so the packing is loop
 * invariant; for conv2 it is 288x128 floats copied once against 8.8M multiply-adds that read it.
 *
 * VMLA.F32 is a chained multiply-add: the product is rounded before the accumulation, exactly like
 * the scalar `acc += a * b` it replaces. The fused VFMA would NOT be bit identical here, which is
 * why this must not be written as plain C that the compiler is free to contract. (On this target it
 * cannot: vfma needs vfpv4, which is why zf_vfma_q in kernels.c carries its own .fpu directive.)
 *
 * Six rows at a time against four columns: seven loads feed twelve multiply-adds, where the
 * pairwise tile's best is eight loads for sixteen. Rows are independent accumulators, so widening
 * the row count costs registers and nothing else. */
/* MLAS does not carry one accumulator the whole way up k. It walks k in strides of 128, sums each
 * stride from +0.0, and folds that partial into C as it goes, so the total is
 *
 *     fl(fl(p0 + p1) + p2)        rather than        one running sum over all of k
 *
 * and those are different numbers. The first two convolutions checked both had k under 128, where
 * a single stride IS the whole k, so the two models were indistinguishable there and the sequential
 * reading looked complete. It was not. Against the same device trace, each convolution fed ONNX
 * Runtime's own recorded input:
 *
 *   conv.4,          k = 72    one stride                       36,192 of 36,192   100.00 %
 *   conv.7,          k = 288   one accumulator over all of k    10,664 of 65,664    16.24 %
 *                              strides of 128                   65,664 of 65,664   100.00 %
 *   pointwise_conv2, k = 384   one accumulator over all of k     8,809 of 58,368    15.09 %
 *                              strides of 128                   58,368 of 58,368   100.00 %
 *
 * Two different k, two different block structures, both exact, and no other stride tried comes
 * near. The strides start at 0, so 288 is 128 + 128 + 32 and not three even thirds.
 *
 * The partial for the first stride is stored rather than added, the way MLAS's ZeroMode does. It
 * happens not to matter here, since a partial summed from +0.0 can never be -0.0, but the cost of
 * writing it faithfully is one branch outside the inner loop.
 *
 * The panel is a stack buffer, so k has a ceiling. Above it the kernel falls back to the scalar
 * loop, which is the same order and so still bit identical: the cap can only cost speed, never
 * fidelity. Everything in this model is well under it (the widest is pointwise_conv1 at 384, and
 * the attention at 280), but "well under it" is an assumption about a graph, so ZF_SEQ_REPORT
 * makes the fallback say so instead of quietly being slow. */
#define ZF_SEQ_NR 4
#define ZF_SEQ_MR 6
#define ZF_SEQ_KBLOCK 128
#define ZF_SEQ_KMAX 1024
#define ZF_SEQ8_KMAX 512
#define ZF_SEQ_GROUP 64

/* The reference form of the order, and what ZF_SEQ_SCALAR runs. */
static void zf_seq_scalar_acc_f32(const float *a, int lda, const float *b, int ldb, int m, int n,
                                  int k, float *out, int ldc, int accumulate) {
  for (int r = 0; r < m; ++r)
    for (int c = 0; c < n; ++c) {
      const float *ar = a + (size_t)r * lda, *bc = b + (size_t)c * ldb;
      float total = accumulate ? out[(size_t)r * ldc + c] : 0.0f;
      for (int kb = 0; kb < k; kb += ZF_SEQ_KBLOCK) {
        const int ke = (kb + ZF_SEQ_KBLOCK < k) ? kb + ZF_SEQ_KBLOCK : k;
        float part = 0.0f;
        for (int p = kb; p < ke; ++p) part += ar[p] * bc[p];
        total = (kb || accumulate) ? total + part : part;
      }
      out[(size_t)r * ldc + c] = total;
    }
}

static void zf_seq_scalar_f32(const float *a, int lda, const float *b, int ldb, int m, int n, int k,
                              float *out, int ldc) {
  zf_seq_scalar_acc_f32(a, lda, b, ldb, m, n, k, out, ldc, 0);
}

static void zf_matmul_nt_seq_impl(const float *a, int lda, const float *b, int ldb, int m, int n,
                                  int k, float *out, int ldc, int accumulate) {
#if ZF_NEON
  if (k > ZF_SEQ_KMAX && zf_getenv("ZF_SEQ_REPORT")) {
    static _Atomic int said = 0;
    if (!said) {
      said = 1;
      fprintf(stderr, "zf_matmul_nt_seq_f32: k=%d over the %d panel cap, scalar fallback\n", k,
              ZF_SEQ_KMAX);
    }
  }
  if (k > 0 && k <= ZF_SEQ_KMAX) {
    float panel[ZF_SEQ_NR * ZF_SEQ_KMAX];
    int j = 0;
    /* Eight columns against four rows, MLAS's own scheme, and the fast path.
     *
     * The 6x4 tile below took its rows' values with broadcast loads, one per row per k, and on the
     * phone it measured about twice the old pairwise tile: seven loads for every six multiply-adds,
     * each broadcast feeding the multiply-add right behind it, which the in-order A53 cannot hide.
     * MLAS's ARM32 kernel does not broadcast from memory at all. It loads two k of a row into a d
     * register with one ordinary load and takes each k from its lane (VMLA.F32 by scalar). Here
     * that is four d loads and four panel loads per two k, feeding sixteen q multiply-adds: 8
     * loads against 32 cycles of arithmetic, where the old tile was 14 against 24.
     *
     * The order is untouched: every lane still sums its own output strictly up k from +0.0, the
     * strides fold exactly as before, and an odd k's last term goes in on its own. */
    if (k <= ZF_SEQ8_KMAX) {
      /* Blocked the way MLAS blocks it, because the tile alone was not the problem.
       *
       * On one core the assembly loop runs at 2.15 G products/s from L1, better than the old
       * pairwise tile's 1.84, and yet the whole kernel measured 0.9 to 1.5 on the real shapes.
       * The loop order was the cause: eight columns outermost meant the entire first operand was
       * streamed once per eight columns, 48 times over for the wide pointwise, and for pw2 that
       * operand is 700 KB, past L2, so every pass went to DRAM. MLAS keeps a WIDE column panel and
       * reuses it across every row. Here: k stride outermost (the order demands it), then 64
       * columns packed once per stride, then four-row tiles whose 2 KB of the first operand stays
       * in L1 while all eight of the group's column blocks run against it.
       *
       * Every output still takes its strides in order, each summed from +0.0 in its own lane and
       * folded into `out`, the first stored unless accumulating: the same sums as before. */
      float grp[ZF_SEQ_GROUP * ZF_SEQ_KBLOCK] __attribute__((aligned(16)));
      const int n8 = n & ~7;
      for (int kb = 0; kb < k; kb += ZF_SEQ_KBLOCK) {
        const int ke = (kb + ZF_SEQ_KBLOCK < k) ? kb + ZF_SEQ_KBLOCK : k;
        const int len = ke - kb;
        const int fold = kb || accumulate;
        for (int g0 = 0; g0 < n8; g0 += ZF_SEQ_GROUP) {
          const int g1 = (g0 + ZF_SEQ_GROUP < n8) ? g0 + ZF_SEQ_GROUP : n8;
          const int nb = (g1 - g0) / 8;
          for (int bi = 0; bi < nb; ++bi) {
            float *pp = grp + (size_t)bi * len * 8;
            for (int l = 0; l < 8; ++l) {
              const float *bl = b + (size_t)(g0 + bi * 8 + l) * ldb + kb;
              for (int p = 0; p < len; ++p) pp[p * 8 + l] = bl[p];
            }
          }
          int i = 0;
#if defined(ZF_NEON_EMU) && ZF_NEON_EMU
          const float panel_min = zfe_min_nonzero_abs(grp, nb * len * 8);
#endif
          for (; i + 4 <= m; i += 4) {
            const float *r0 = a + (size_t)(i + 0) * lda + kb, *r1 = a + (size_t)(i + 1) * lda + kb;
            const float *r2 = a + (size_t)(i + 2) * lda + kb, *r3 = a + (size_t)(i + 3) * lda + kb;
#if defined(ZF_NEON_EMU) && ZF_NEON_EMU
            float rows_min = zfe_min_nonzero_abs(r0, len), t;
            if ((t = zfe_min_nonzero_abs(r1, len)) < rows_min) rows_min = t;
            if ((t = zfe_min_nonzero_abs(r2, len)) < rows_min) rows_min = t;
            if ((t = zfe_min_nonzero_abs(r3, len)) < rows_min) rows_min = t;
            const int certified = zfe_mla_certified(panel_min, rows_min);
#endif
            /* The next four rows' stride, fetched while this one runs: 10 to 18 per cent on the
             * front end's shapes, whose first operand (up to 770 KB) streams from DRAM once per
             * group and which the A53's prefetcher, four rows apart, does not pick up. With the
             * operand resident the kernel ran 1.8 to 1.9 G products/s and streamed it ran 1.5 to
             * 1.7; prefetched it runs 1.7 to 1.9. Addresses only: no bit can move. A stride of a
             * few k (conv0's 9) has too little work to hide it behind, so those skip it. */
            if (i + 8 <= m && len >= 32)
              for (int q = 0; q < 4; ++q) {
                const char *nr = (const char *)(a + (size_t)(i + 4 + q) * lda + kb);
                for (int off = 0; off < len * 4; off += 64) __builtin_prefetch(nr + off);
              }
            for (int bi = 0; bi < nb; ++bi) {
              const float *pp = grp + (size_t)bi * len * 8;
              const int jc = g0 + bi * 8;
              float *o0 = out + (size_t)(i + 0) * ldc + jc, *o1 = out + (size_t)(i + 1) * ldc + jc;
              float *o2 = out + (size_t)(i + 2) * ldc + jc, *o3 = out + (size_t)(i + 3) * ldc + jc;
              float32x4_t c0a = vdupq_n_f32(0.0f), c0b = c0a, c1a = c0a, c1b = c0a;
              float32x4_t c2a = c0a, c2b = c0a, c3a = c0a, c3b = c0a;
              int p = 0;
#if ZF_HAVE_NT_ASM
              if (!(len & 1)) {
                const int quads = len / 4;
                zf_seq_tile4x8_st(pp, r0, (int)((size_t)lda * sizeof(float)), quads, o0,
                                  (int)((size_t)ldc * sizeof(float)),
                                  (fold ? 1 : 0) | ((len & 2) ? 2 : 0));
                continue;
              }
              if (len >= 2) {
                float acc[32] __attribute__((aligned(16))) = {0};
                const int lda_bytes = (int)((size_t)lda * sizeof(float));
                const int quads = len / 4;
                /* k by four where it can, then one pair, both continuing from acc */
                if (quads) zf_seq_tile4x8_k4(pp, r0, lda_bytes, quads, acc);
                const int steps = len / 2;
                if (steps > 2 * quads)
                  zf_seq_tile4x8(pp + (size_t)quads * 32, r0 + 4 * quads, lda_bytes, 1, acc);
                c0a = vld1q_f32(acc + 0);
                c0b = vld1q_f32(acc + 4);
                c1a = vld1q_f32(acc + 8);
                c1b = vld1q_f32(acc + 12);
                c2a = vld1q_f32(acc + 16);
                c2b = vld1q_f32(acc + 20);
                c3a = vld1q_f32(acc + 24);
                c3b = vld1q_f32(acc + 28);
                p = 2 * steps;
              }
#endif
#if defined(ZF_NEON_EMU) && ZF_NEON_EMU
              /* The emulated NEON's flush to zero costs more than the arithmetic. Where this
               * stride's operands prove it cannot act (zf/neon_emu.h, zfe_mla_certified), the same
               * multiply-adds in the same order run without it; otherwise the loop below does. */
              if (certified) {
                for (; p + 2 <= len; p += 2) {
                  const float *w = pp + (size_t)p * 8;
                  const float32x4_t w0a = vld1q_f32(w), w0b = vld1q_f32(w + 4);
                  const float32x4_t w1a = vld1q_f32(w + 8), w1b = vld1q_f32(w + 12);
                  c0a = zfe_mlaq_n_certified(c0a, w0a, r0[p]);
                  c0b = zfe_mlaq_n_certified(c0b, w0b, r0[p]);
                  c1a = zfe_mlaq_n_certified(c1a, w0a, r1[p]);
                  c1b = zfe_mlaq_n_certified(c1b, w0b, r1[p]);
                  c2a = zfe_mlaq_n_certified(c2a, w0a, r2[p]);
                  c2b = zfe_mlaq_n_certified(c2b, w0b, r2[p]);
                  c3a = zfe_mlaq_n_certified(c3a, w0a, r3[p]);
                  c3b = zfe_mlaq_n_certified(c3b, w0b, r3[p]);
                  c0a = zfe_mlaq_n_certified(c0a, w1a, r0[p + 1]);
                  c0b = zfe_mlaq_n_certified(c0b, w1b, r0[p + 1]);
                  c1a = zfe_mlaq_n_certified(c1a, w1a, r1[p + 1]);
                  c1b = zfe_mlaq_n_certified(c1b, w1b, r1[p + 1]);
                  c2a = zfe_mlaq_n_certified(c2a, w1a, r2[p + 1]);
                  c2b = zfe_mlaq_n_certified(c2b, w1b, r2[p + 1]);
                  c3a = zfe_mlaq_n_certified(c3a, w1a, r3[p + 1]);
                  c3b = zfe_mlaq_n_certified(c3b, w1b, r3[p + 1]);
                }
              }
#endif
              for (; p + 2 <= len; p += 2) {
                const float *w = pp + (size_t)p * 8;
                const float32x4_t w0a = vld1q_f32(w), w0b = vld1q_f32(w + 4);
                const float32x4_t w1a = vld1q_f32(w + 8), w1b = vld1q_f32(w + 12);
                const float32x2_t x0 = vld1_f32(r0 + p), x1 = vld1_f32(r1 + p);
                const float32x2_t x2 = vld1_f32(r2 + p), x3 = vld1_f32(r3 + p);
                c0a = vmlaq_lane_f32(c0a, w0a, x0, 0);
                c0b = vmlaq_lane_f32(c0b, w0b, x0, 0);
                c1a = vmlaq_lane_f32(c1a, w0a, x1, 0);
                c1b = vmlaq_lane_f32(c1b, w0b, x1, 0);
                c2a = vmlaq_lane_f32(c2a, w0a, x2, 0);
                c2b = vmlaq_lane_f32(c2b, w0b, x2, 0);
                c3a = vmlaq_lane_f32(c3a, w0a, x3, 0);
                c3b = vmlaq_lane_f32(c3b, w0b, x3, 0);
                c0a = vmlaq_lane_f32(c0a, w1a, x0, 1);
                c0b = vmlaq_lane_f32(c0b, w1b, x0, 1);
                c1a = vmlaq_lane_f32(c1a, w1a, x1, 1);
                c1b = vmlaq_lane_f32(c1b, w1b, x1, 1);
                c2a = vmlaq_lane_f32(c2a, w1a, x2, 1);
                c2b = vmlaq_lane_f32(c2b, w1b, x2, 1);
                c3a = vmlaq_lane_f32(c3a, w1a, x3, 1);
                c3b = vmlaq_lane_f32(c3b, w1b, x3, 1);
              }
              if (p < len) {
                const float32x4_t wa = vld1q_f32(pp + (size_t)p * 8);
                const float32x4_t wb = vld1q_f32(pp + (size_t)p * 8 + 4);
                c0a = vmlaq_n_f32(c0a, wa, r0[p]);
                c0b = vmlaq_n_f32(c0b, wb, r0[p]);
                c1a = vmlaq_n_f32(c1a, wa, r1[p]);
                c1b = vmlaq_n_f32(c1b, wb, r1[p]);
                c2a = vmlaq_n_f32(c2a, wa, r2[p]);
                c2b = vmlaq_n_f32(c2b, wb, r2[p]);
                c3a = vmlaq_n_f32(c3a, wa, r3[p]);
                c3b = vmlaq_n_f32(c3b, wb, r3[p]);
              }
              if (fold) {
                c0a = vaddq_f32(vld1q_f32(o0), c0a);
                c0b = vaddq_f32(vld1q_f32(o0 + 4), c0b);
                c1a = vaddq_f32(vld1q_f32(o1), c1a);
                c1b = vaddq_f32(vld1q_f32(o1 + 4), c1b);
                c2a = vaddq_f32(vld1q_f32(o2), c2a);
                c2b = vaddq_f32(vld1q_f32(o2 + 4), c2b);
                c3a = vaddq_f32(vld1q_f32(o3), c3a);
                c3b = vaddq_f32(vld1q_f32(o3 + 4), c3b);
              }
              vst1q_f32(o0, c0a);
              vst1q_f32(o0 + 4, c0b);
              vst1q_f32(o1, c1a);
              vst1q_f32(o1 + 4, c1b);
              vst1q_f32(o2, c2a);
              vst1q_f32(o2 + 4, c2b);
              vst1q_f32(o3, c3a);
              vst1q_f32(o3 + 4, c3b);
            }
          }
          for (; i < m; ++i) {
            const float *r0 = a + (size_t)i * lda + kb;
            for (int bi = 0; bi < nb; ++bi) {
              const float *pp = grp + (size_t)bi * len * 8;
              float *o0 = out + (size_t)i * ldc + g0 + bi * 8;
              float32x4_t ca = vdupq_n_f32(0.0f), cb = ca;
              for (int p = 0; p < len; ++p) {
                ca = vmlaq_n_f32(ca, vld1q_f32(pp + (size_t)p * 8), r0[p]);
                cb = vmlaq_n_f32(cb, vld1q_f32(pp + (size_t)p * 8 + 4), r0[p]);
              }
              if (fold) {
                ca = vaddq_f32(vld1q_f32(o0), ca);
                cb = vaddq_f32(vld1q_f32(o0 + 4), cb);
              }
              vst1q_f32(o0, ca);
              vst1q_f32(o0 + 4, cb);
            }
          }
        }
      }
      j = n8;
    }
    for (; j + ZF_SEQ_NR <= n; j += ZF_SEQ_NR) {
      const float *b0 = b + (size_t)(j + 0) * ldb, *b1 = b + (size_t)(j + 1) * ldb;
      const float *b2 = b + (size_t)(j + 2) * ldb, *b3 = b + (size_t)(j + 3) * ldb;
      for (int p = 0; p < k; ++p) {
        panel[p * 4 + 0] = b0[p];
        panel[p * 4 + 1] = b1[p];
        panel[p * 4 + 2] = b2[p];
        panel[p * 4 + 3] = b3[p];
      }
      /* The running total lives in `out`, not in registers. Keeping six more accumulators live
       * across the stride loop would spill, and there are at most three strides, so folding
       * through memory costs two extra passes over 24 floats and keeps the inner loop at seven
       * registers. It is also what MLAS itself does: its C is memory. */
      int i = 0;
      for (; i + ZF_SEQ_MR <= m; i += ZF_SEQ_MR) {
        float *o0 = out + (size_t)(i + 0) * ldc + j, *o1 = out + (size_t)(i + 1) * ldc + j;
        float *o2 = out + (size_t)(i + 2) * ldc + j, *o3 = out + (size_t)(i + 3) * ldc + j;
        float *o4 = out + (size_t)(i + 4) * ldc + j, *o5 = out + (size_t)(i + 5) * ldc + j;
        for (int kb = 0; kb < k; kb += ZF_SEQ_KBLOCK) {
          const int ke = (kb + ZF_SEQ_KBLOCK < k) ? kb + ZF_SEQ_KBLOCK : k;
          const float *r0 = a + (size_t)(i + 0) * lda, *r1 = a + (size_t)(i + 1) * lda;
          const float *r2 = a + (size_t)(i + 2) * lda, *r3 = a + (size_t)(i + 3) * lda;
          const float *r4 = a + (size_t)(i + 4) * lda, *r5 = a + (size_t)(i + 5) * lda;
          float32x4_t c0 = vdupq_n_f32(0.0f), c1 = c0, c2 = c0, c3 = c0, c4 = c0, c5 = c0;
          for (int p = kb; p < ke; ++p) {
            const float32x4_t wv = vld1q_f32(panel + p * 4);
            c0 = vmlaq_n_f32(c0, wv, r0[p]);
            c1 = vmlaq_n_f32(c1, wv, r1[p]);
            c2 = vmlaq_n_f32(c2, wv, r2[p]);
            c3 = vmlaq_n_f32(c3, wv, r3[p]);
            c4 = vmlaq_n_f32(c4, wv, r4[p]);
            c5 = vmlaq_n_f32(c5, wv, r5[p]);
          }
          if (kb || accumulate) {
            c0 = vaddq_f32(vld1q_f32(o0), c0);
            c1 = vaddq_f32(vld1q_f32(o1), c1);
            c2 = vaddq_f32(vld1q_f32(o2), c2);
            c3 = vaddq_f32(vld1q_f32(o3), c3);
            c4 = vaddq_f32(vld1q_f32(o4), c4);
            c5 = vaddq_f32(vld1q_f32(o5), c5);
          }
          vst1q_f32(o0, c0);
          vst1q_f32(o1, c1);
          vst1q_f32(o2, c2);
          vst1q_f32(o3, c3);
          vst1q_f32(o4, c4);
          vst1q_f32(o5, c5);
        }
      }
      for (; i < m; ++i) {
        float *o0 = out + (size_t)i * ldc + j;
        for (int kb = 0; kb < k; kb += ZF_SEQ_KBLOCK) {
          const int ke = (kb + ZF_SEQ_KBLOCK < k) ? kb + ZF_SEQ_KBLOCK : k;
          const float *r0 = a + (size_t)i * lda;
          float32x4_t c0 = vdupq_n_f32(0.0f);
          for (int p = kb; p < ke; ++p) c0 = vmlaq_n_f32(c0, vld1q_f32(panel + p * 4), r0[p]);
          vst1q_f32(o0, (kb || accumulate) ? vaddq_f32(vld1q_f32(o0), c0) : c0);
        }
      }
    }
    /* Column tail. Same order, one column at a time; there is nothing to vectorise across. */
    if (j < n)
      zf_seq_scalar_acc_f32(a, lda, b + (size_t)j * ldb, ldb, m, n - j, k, out + j, ldc,
                            accumulate);
    return;
  }
#endif
  zf_seq_scalar_acc_f32(a, lda, b, ldb, m, n, k, out, ldc, accumulate);
}

static void zf_matmul_nt_seq_f32(const float *a, int lda, const float *b, int ldb, int m, int n,
                                 int k, float *out, int ldc) {
  zf_matmul_nt_seq_impl(a, lda, b, ldb, m, n, k, out, ldc, 0);
}

/* The same, with MLAS's beta = 1: every stride, the first included, is added to what `out` already
 * holds. ORT runs the front end's last convolution this way on ARM, fused with the residual add
 * that follows it, so the residual is the first term of the sum rather than the last. */
void zf_matmul_nt_seq_acc_f32(const float *a, int lda, const float *b, int ldb, int m, int n,
                              int k, float *out, int ldc) {
  zf_matmul_nt_seq_impl(a, lda, b, ldb, m, n, k, out, ldc, 1);
}

/* The attention scores in MLAS's order, at the speed the old tile had.
 *
 * zf_matmul_nt_seq_f32 packs the second operand four columns at a time, which pays for itself
 * when many rows reuse the panel. The scores do not have many rows: the frame block halves until
 * there are enough tasks, so a call gets 16, 8, 4, 2 or even 1 query, and every call repacked the
 * head's whole key window. With one query that is more packing than arithmetic.
 *
 * So the lanes here hold four QUERY rows instead, and it is the queries that get packed (k-major,
 * four rows to a vector), which is a few hundred floats. The keys are read where they lie, four k
 * at a time with one load, and each k is broadcast from its lane. Per four keys and four k that is
 * four query loads and four key loads against sixteen multiply-adds, 64 products, the same
 * ratio the assembly tile had, and a 4x4 transpose at the end of each block of keys.
 *
 * Every output still runs strictly up k from +0.0 in its own lane, so this is bit identical to
 * the scalar loop; it takes the whole depth as one stride, so it is only used where MLAS's stride
 * covers it (k <= 128; the scores' k is the head dimension, 32). */
#define ZF_SCORES_KMAX 128

static void zf_scores_seq_f32(const float *a, int lda, const float *b, int ldb, int m, int n,
                              int k, float *out, int ldc) {
  float qp[4 * ZF_SCORES_KMAX];
  for (int i0 = 0; i0 < m; i0 += 4) {
    const int rows = (m - i0 < 4) ? m - i0 : 4;
    for (int p = 0; p < k; ++p)
      for (int r = 0; r < 4; ++r) qp[p * 4 + r] = r < rows ? a[(size_t)(i0 + r) * lda + p] : 0.0f;
    int j = 0;
    for (; j + 4 <= n; j += 4) {
      const float *k0 = b + (size_t)(j + 0) * ldb, *k1 = b + (size_t)(j + 1) * ldb;
      const float *k2 = b + (size_t)(j + 2) * ldb, *k3 = b + (size_t)(j + 3) * ldb;
      float32x4_t c0 = vdupq_n_f32(0.0f), c1 = c0, c2 = c0, c3 = c0;
      int p = 0;
      for (; p + 4 <= k; p += 4) {
        const float32x4_t q0 = vld1q_f32(qp + (p + 0) * 4), q1 = vld1q_f32(qp + (p + 1) * 4);
        const float32x4_t q2 = vld1q_f32(qp + (p + 2) * 4), q3 = vld1q_f32(qp + (p + 3) * 4);
        const float32x4_t v0 = vld1q_f32(k0 + p), v1 = vld1q_f32(k1 + p);
        const float32x4_t v2 = vld1q_f32(k2 + p), v3 = vld1q_f32(k3 + p);
#define ZF_SC_STEP(c, v)                                  \
  c = vmlaq_lane_f32(c, q0, vget_low_f32(v), 0);          \
  c = vmlaq_lane_f32(c, q1, vget_low_f32(v), 1);          \
  c = vmlaq_lane_f32(c, q2, vget_high_f32(v), 0);         \
  c = vmlaq_lane_f32(c, q3, vget_high_f32(v), 1);
        ZF_SC_STEP(c0, v0)
        ZF_SC_STEP(c1, v1)
        ZF_SC_STEP(c2, v2)
        ZF_SC_STEP(c3, v3)
#undef ZF_SC_STEP
      }
      for (; p < k; ++p) {
        const float32x4_t q = vld1q_f32(qp + p * 4);
        c0 = vmlaq_n_f32(c0, q, k0[p]);
        c1 = vmlaq_n_f32(c1, q, k1[p]);
        c2 = vmlaq_n_f32(c2, q, k2[p]);
        c3 = vmlaq_n_f32(c3, q, k3[p]);
      }
      /* c_l holds key j+l for the four rows; transpose to a row's four keys */
      const float32x4x2_t t01 = vtrnq_f32(c0, c1), t23 = vtrnq_f32(c2, c3);
      const float32x4_t r0 = vcombine_f32(vget_low_f32(t01.val[0]), vget_low_f32(t23.val[0]));
      const float32x4_t r1 = vcombine_f32(vget_low_f32(t01.val[1]), vget_low_f32(t23.val[1]));
      const float32x4_t r2 = vcombine_f32(vget_high_f32(t01.val[0]), vget_high_f32(t23.val[0]));
      const float32x4_t r3 = vcombine_f32(vget_high_f32(t01.val[1]), vget_high_f32(t23.val[1]));
      vst1q_f32(out + (size_t)(i0 + 0) * ldc + j, r0);
      if (rows > 1) vst1q_f32(out + (size_t)(i0 + 1) * ldc + j, r1);
      if (rows > 2) vst1q_f32(out + (size_t)(i0 + 2) * ldc + j, r2);
      if (rows > 3) vst1q_f32(out + (size_t)(i0 + 3) * ldc + j, r3);
    }
    for (; j < n; ++j) {
      const float *kj = b + (size_t)j * ldb;
      float32x4_t c = vdupq_n_f32(0.0f);
      for (int p = 0; p < k; ++p) c = vmlaq_n_f32(c, vld1q_f32(qp + p * 4), kj[p]);
      float t[4];
      vst1q_f32(t, c);
      for (int r = 0; r < rows; ++r) out[(size_t)(i0 + r) * ldc + j] = t[r];
    }
  }
}

void zf_matmul_nt4x4_f32(const float *a, int lda, const float *b, int ldb, int m, int n, int k,
                         float *out, int ldc) {
  int i = 0;
  if (conv_seq_order()) {
    /* ZF_SEQ_SCALAR keeps the original loop reachable, so the vectorised kernel can be checked
     * against it on the device rather than only against a model of it. */
    static _Atomic int scalar = -1;
    if (scalar < 0) {
      const char *v = zf_getenv("ZF_SEQ_SCALAR");
      scalar = v && atoi(v);
    }
    if (scalar)
      zf_seq_scalar_f32(a, lda, b, ldb, m, n, k, out, ldc);
    else
      zf_matmul_nt_seq_f32(a, lda, b, ldb, m, n, k, out, ldc);
    return;
  }
  for (; i + 4 <= m; i += 4) {
    const float *a0 = a + (size_t)(i + 0) * lda, *a1 = a + (size_t)(i + 1) * lda;
    const float *a2 = a + (size_t)(i + 2) * lda, *a3 = a + (size_t)(i + 3) * lda;
    int j = 0;
    for (; j + 4 <= n; j += 4) {
      const float *b0 = b + (size_t)(j + 0) * ldb, *b1 = b + (size_t)(j + 1) * ldb;
      const float *b2 = b + (size_t)(j + 2) * ldb, *b3 = b + (size_t)(j + 3) * ldb;
#if ZF_HAVE_NT_ASM_4X4
      if ((k & 3) == 0) {
        zf_matmul_nt_tile4x4_q(a0, (int)((size_t)lda * sizeof(float)), b0,
                               (int)((size_t)ldb * sizeof(float)), k / 4,
                               out + (size_t)i * ldc + j, (int)((size_t)ldc * sizeof(float)));
        continue;
      }
      if ((k & 1) == 0) {
        zf_matmul_nt_tile4x4(a0, (int)((size_t)lda * sizeof(float)), b0,
                             (int)((size_t)ldb * sizeof(float)), k / 2,
                             out + (size_t)i * ldc + j, (int)((size_t)ldc * sizeof(float)));
        continue;
      }
#endif
      float32x2_t c00 = vdup_n_f32(0.0f), c01 = c00, c02 = c00, c03 = c00;
      float32x2_t c10 = c00, c11 = c00, c12 = c00, c13 = c00;
      float32x2_t c20 = c00, c21 = c00, c22 = c00, c23 = c00;
      float32x2_t c30 = c00, c31 = c00, c32 = c00, c33 = c00;
      int p = 0;
      for (; p + 2 <= k; p += 2) {
        const float32x2_t v0 = vld1_f32(b0 + p), v1 = vld1_f32(b1 + p);
        const float32x2_t v2 = vld1_f32(b2 + p), v3 = vld1_f32(b3 + p);
        const float32x2_t u0 = vld1_f32(a0 + p);
        c00 = vmla_f32(c00, u0, v0);
        c01 = vmla_f32(c01, u0, v1);
        c02 = vmla_f32(c02, u0, v2);
        c03 = vmla_f32(c03, u0, v3);
        const float32x2_t u1 = vld1_f32(a1 + p);
        c10 = vmla_f32(c10, u1, v0);
        c11 = vmla_f32(c11, u1, v1);
        c12 = vmla_f32(c12, u1, v2);
        c13 = vmla_f32(c13, u1, v3);
        const float32x2_t u2 = vld1_f32(a2 + p);
        c20 = vmla_f32(c20, u2, v0);
        c21 = vmla_f32(c21, u2, v1);
        c22 = vmla_f32(c22, u2, v2);
        c23 = vmla_f32(c23, u2, v3);
        const float32x2_t u3 = vld1_f32(a3 + p);
        c30 = vmla_f32(c30, u3, v0);
        c31 = vmla_f32(c31, u3, v1);
        c32 = vmla_f32(c32, u3, v2);
        c33 = vmla_f32(c33, u3, v3);
      }
      float *o0 = out + (size_t)(i + 0) * ldc + j, *o1 = out + (size_t)(i + 1) * ldc + j;
      float *o2 = out + (size_t)(i + 2) * ldc + j, *o3 = out + (size_t)(i + 3) * ldc + j;
      /* An odd k leaves one element and dropping it is silent. conv0 has k = 9, and without
       * this the front end came out at a mean error of 3.15 against a graph mean of 2.13. */
      const int odd = (p < k);
      const float xa0 = odd ? a0[p] : 0.0f, xa1 = odd ? a1[p] : 0.0f;
      const float xa2 = odd ? a2[p] : 0.0f, xa3 = odd ? a3[p] : 0.0f;
      const float yb0 = odd ? b0[p] : 0.0f, yb1 = odd ? b1[p] : 0.0f;
      const float yb2 = odd ? b2[p] : 0.0f, yb3 = odd ? b3[p] : 0.0f;
      o0[0] = vget_lane_f32(vpadd_f32(c00, c00), 0) + xa0 * yb0;
      o0[1] = vget_lane_f32(vpadd_f32(c01, c01), 0) + xa0 * yb1;
      o0[2] = vget_lane_f32(vpadd_f32(c02, c02), 0) + xa0 * yb2;
      o0[3] = vget_lane_f32(vpadd_f32(c03, c03), 0) + xa0 * yb3;
      o1[0] = vget_lane_f32(vpadd_f32(c10, c10), 0) + xa1 * yb0;
      o1[1] = vget_lane_f32(vpadd_f32(c11, c11), 0) + xa1 * yb1;
      o1[2] = vget_lane_f32(vpadd_f32(c12, c12), 0) + xa1 * yb2;
      o1[3] = vget_lane_f32(vpadd_f32(c13, c13), 0) + xa1 * yb3;
      o2[0] = vget_lane_f32(vpadd_f32(c20, c20), 0) + xa2 * yb0;
      o2[1] = vget_lane_f32(vpadd_f32(c21, c21), 0) + xa2 * yb1;
      o2[2] = vget_lane_f32(vpadd_f32(c22, c22), 0) + xa2 * yb2;
      o2[3] = vget_lane_f32(vpadd_f32(c23, c23), 0) + xa2 * yb3;
      o3[0] = vget_lane_f32(vpadd_f32(c30, c30), 0) + xa3 * yb0;
      o3[1] = vget_lane_f32(vpadd_f32(c31, c31), 0) + xa3 * yb1;
      o3[2] = vget_lane_f32(vpadd_f32(c32, c32), 0) + xa3 * yb2;
      o3[3] = vget_lane_f32(vpadd_f32(c33, c33), 0) + xa3 * yb3;
    }
    for (; j < n; ++j)
      for (int r = 0; r < 4; ++r) {
        float acc = 0.0f;
        for (int p = 0; p < k; ++p) acc += a[(size_t)(i + r) * lda + p] * b[(size_t)j * ldb + p];
        out[(size_t)(i + r) * ldc + j] = acc;
      }
  }
  for (; i < m; ++i)
    for (int j = 0; j < n; ++j) {
      float acc = 0.0f;
      for (int p = 0; p < k; ++p) acc += a[(size_t)i * lda + p] * b[(size_t)j * ldb + p];
      out[(size_t)i * ldc + j] = acc;
    }
}
#endif

/* The k stride MlasSgemmOperation picks for a GEMM of N columns and depth K, with A not
 * transposed, at v1.23.2 (sgemm.cpp; MlasConvOperation repeats the same rule for convolutions,
 * with N = the output pixels, since one intra-op thread never segments them).
 *
 * The stride is NOT a constant 128. When N is small against K, MLAS narrows its N panel and
 * widens the K one, up to 1024, so a skinny product sums in one block where a wide one of the
 * same depth sums in three. In this model that decides both attention products at S = 280: the
 * nonlinear attention, N = 144, strides 128 + 128 + 24, while the values, N = 12, stride 1024
 * and sum straight through. */
int zf_mlas_stride_k(int n, int k) {
  int sn = 128, sk = 128;
  if (n >= k) {
    while (sk / 2 >= k) {
      sn *= 2;
      sk /= 2;
    }
  } else {
    while (sn > 16 && sn / 2 >= n) {
      sk *= 2;
      sn /= 2;
    }
  }
  (void)sn;
  return sk;
}

void zf_matmul_nt_f32(const float *a, int lda, const float *b, int ldb, int m, int n, int k,
                      float *out, int ldc) {
  /* Four output columns outer, all rows inner. The other way round re-reads the whole second
   * operand once per row: for the attention scores that is a 143 KB key cache read 24 times, and
   * this way it is read once while four of its rows stay in L1. */
  int j = 0;
  /* ZF_CONV_ORT: every shape, not only the four aligned ones, takes MLAS's order. The attention
   * scores run with a frame block of T = 6 and T = 3 in the deep stacks, and those shapes used to
   * fall through to the tile below, which puts k in the lanes and reduces with a transpose: a
   * third order, neither pairwise nor MLAS's. */
#if ZF_NEON
  if (conv_seq_order()) {
    if (k <= ZF_SCORES_KMAX)
      zf_scores_seq_f32(a, lda, b, ldb, m, n, k, out, ldc);
    else
      zf_matmul_nt_seq_f32(a, lda, b, ldb, m, n, k, out, ldc);
    return;
  }
  if ((m & 3) == 0 && (n & 3) == 0 && (k & 1) == 0 && m >= 4 && n >= 4) {
    zf_matmul_nt4x4_f32(a, lda, b, ldb, m, n, k, out, ldc);
    return;
  }
  for (; j + 4 <= n; j += 4) {
    const float *b0 = b + (size_t)(j + 0) * ldb;
    const float *b1 = b + (size_t)(j + 1) * ldb;
    const float *b2 = b + (size_t)(j + 2) * ldb;
    const float *b3 = b + (size_t)(j + 3) * ldb;
    for (int i = 0; i < m; ++i) {
      const float *arow = a + (size_t)i * lda;
      /* Four key rows against one query, with five vector registers kept live.
       *
       * The compiler would not keep them: given the four rows indexed off one base it recycled one
       * register for three of them, so every load waited for the previous multiply to read it and
       * the eight cycle load latency was never hidden. That is why this tile is assembly; see
       * kernels_armv7.S. */
      int p = 0;
#if ZF_HAVE_NT_ASM
      /* the assembly does the whole group loop and hands back the four reduced sums */
      float acc4[4];
      zf_matmul_nt_tile4(arow, b0, ldb * (int)sizeof(float), k / 4, acc4);
      p = (k / 4) * 4;
      float32x4_t sum = vld1q_f32(acc4);
#else
      const float *pa = arow;
      const float *q0 = b0, *q1 = b1, *q2 = b2, *q3 = b3;
      float32x4_t c0 = vdupq_n_f32(0.0f), c1 = c0, c2 = c0, c3 = c0;
      for (; p + 4 <= k; p += 4) {
        const float32x4_t av = vld1q_f32(pa);
        const float32x4_t v0 = vld1q_f32(q0);
        const float32x4_t v1 = vld1q_f32(q1);
        const float32x4_t v2 = vld1q_f32(q2);
        const float32x4_t v3 = vld1q_f32(q3);
        pa += 4;
        q0 += 4;
        q1 += 4;
        q2 += 4;
        q3 += 4;
        c0 = vmlaq_f32(c0, av, v0);
        c1 = vmlaq_f32(c1, av, v1);
        c2 = vmlaq_f32(c2, av, v2);
        c3 = vmlaq_f32(c3, av, v3);
      }
      const float32x4x2_t t0 = vtrnq_f32(c0, c1);
      const float32x4x2_t t1 = vtrnq_f32(c2, c3);
      const float32x4_t r0 = vcombine_f32(vget_low_f32(t0.val[0]), vget_low_f32(t1.val[0]));
      const float32x4_t r1 = vcombine_f32(vget_low_f32(t0.val[1]), vget_low_f32(t1.val[1]));
      const float32x4_t r2 = vcombine_f32(vget_high_f32(t0.val[0]), vget_high_f32(t1.val[0]));
      const float32x4_t r3 = vcombine_f32(vget_high_f32(t0.val[1]), vget_high_f32(t1.val[1]));
      float32x4_t sum = vaddq_f32(vaddq_f32(r0, r1), vaddq_f32(r2, r3));
#endif
      for (; p < k; ++p) {
        const float av = arow[p];
        const float tail[4] = {av * b0[p], av * b1[p], av * b2[p], av * b3[p]};
        sum = vaddq_f32(sum, vld1q_f32(tail));
      }
      vst1q_f32(out + (size_t)i * ldc + j, sum);
    }
  }
#endif
  for (; j < n; ++j) {
    const float *brow = b + (size_t)j * ldb;
    for (int i = 0; i < m; ++i) {
      const float *arow = a + (size_t)i * lda;
      float s = 0.0f;
      for (int p = 0; p < k; ++p) s += arow[p] * brow[p];
      out[(size_t)i * ldc + j] = s;
    }
  }
}

void zf_downsample_f32(const float *in, int frames_out, int factor, int channels,
                       const float *weight, float *out, int t0, int t1) {
  (void)frames_out;
  for (int t = t0; t < t1; ++t) {
    const float *src = in + (size_t)t * factor * channels;
    float *dst = out + (size_t)t * channels;
    int c = 0;
#if ZF_NEON
    /* The weights are a handful of scalars and the channel count is a multiple of four in every
     * stack, so the whole thing is one pass with `factor` multiply-adds a vector. */
    for (; c + 8 <= channels; c += 8) {
      float32x4_t a0 = vmulq_n_f32(vld1q_f32(src + c), weight[0]);
      float32x4_t a1 = vmulq_n_f32(vld1q_f32(src + c + 4), weight[0]);
      for (int j = 1; j < factor; ++j) {
        const float *row = src + (size_t)j * channels;
        a0 = vmlaq_n_f32(a0, vld1q_f32(row + c), weight[j]);
        a1 = vmlaq_n_f32(a1, vld1q_f32(row + c + 4), weight[j]);
      }
      vst1q_f32(dst + c, a0);
      vst1q_f32(dst + c + 4, a1);
    }
#endif
    for (; c < channels; ++c) {
      float sum = src[c] * weight[0];
      for (int j = 1; j < factor; ++j) sum += src[(size_t)j * channels + c] * weight[j];
      dst[c] = sum;
    }
  }
}

void zf_upsample_f32(const float *in, int frames_in, int factor, int channels, float *out, int t0,
                     int t1) {
  (void)frames_in;
  for (int t = t0; t < t1; ++t) {
    const float *src = in + (size_t)t * channels;
    for (int j = 0; j < factor; ++j)
      memcpy(out + ((size_t)t * factor + j) * channels, src, (size_t)channels * sizeof(float));
  }
}
