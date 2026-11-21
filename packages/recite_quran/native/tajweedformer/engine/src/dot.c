#include "zf/dot.h"
#include "zf/env.h"

#include <stdlib.h>
#include <string.h>

#if defined(__aarch64__) && defined(__ARM_FEATURE_DOTPROD) && !(defined(ZF_NEON_EMU) && ZF_NEON_EMU)
#include <arm_neon.h>
#define ZF_DOT 1
#else
#define ZF_DOT 0
#endif

#if ZF_DOT && defined(__APPLE__)
#include <sys/sysctl.h>
#endif

#if ZF_DOT && defined(__linux__)
#include <sys/auxv.h>
#ifndef HWCAP_ASIMDDP
#define HWCAP_ASIMDDP (1 << 20)
#endif
#endif

/* Compiling for DotProd is not the same as running on it: an arm64-v8a build also runs on ARMv8.0
 * cores, where SDOT is an undefined instruction. So the kernel is compiled in and the core is asked
 * once, and a caller that gets 0 keeps to the pairing kernel. */
int zf_dot_available(void) {
#if ZF_DOT && defined(__linux__)
  static _Atomic int cached = -1;
  if (cached < 0) cached = (getauxval(AT_HWCAP) & HWCAP_ASIMDDP) ? 1 : 0;
  return cached;
#elif ZF_DOT && defined(__APPLE__)
  static _Atomic int cached = -1;
  if (cached < 0) {
    int v = 0;
    size_t len = sizeof v;
    cached = (sysctlbyname("hw.optional.arm.FEAT_DotProd", &v, &len, NULL, 0) == 0 && v) ? 1 : 0;
  }
  return cached;
#else
  return ZF_DOT;
#endif
}

static int round_up16(int v) { return (v + 15) & ~15; }

size_t zf_weights_s8_packed_dot_bytes(int n, int k) {
  const int blocks = (n + ZF_DOT_UNIT_BLOCK - 1) / ZF_DOT_UNIT_BLOCK;
  return (size_t)blocks * ZF_DOT_UNIT_BLOCK * (size_t)round_up16(k);
}

int zf_weights_s8_pack_dot(const int8_t *w_nk, int n, int k, int8_t *packed, int32_t *row_sums,
                           ZfWeightsS8 *out) {
  const int k_pad = round_up16(k);
  const int blocks = (n + ZF_DOT_UNIT_BLOCK - 1) / ZF_DOT_UNIT_BLOCK;
  memset(packed, 0, zf_weights_s8_packed_dot_bytes(n, k));
  for (int j = 0; j < blocks * ZF_DOT_UNIT_BLOCK; ++j) row_sums[j] = 0;

  for (int jb = 0; jb < blocks; ++jb) {
    int8_t *panel = packed + (size_t)jb * ZF_DOT_UNIT_BLOCK * k_pad;
    for (int u = 0; u < ZF_DOT_UNIT_BLOCK; ++u) {
      const int j = jb * ZF_DOT_UNIT_BLOCK + u;
      if (j >= n) continue;
      const int8_t *row = w_nk + (size_t)j * k;
      int32_t sum = 0;
      for (int c = 0; c < k; ++c) {
        if (row[c] == -128) return 0; /* the pairing layout cannot take it either */
        sum += row[c];
        /* [group of four k][unit][four k]: one SDOT reads sixteen bytes, four units wide */
        panel[(size_t)(c / ZF_DOT_K_GROUP) * (ZF_DOT_UNIT_BLOCK * ZF_DOT_K_GROUP) +
              (size_t)u * ZF_DOT_K_GROUP + (c % ZF_DOT_K_GROUP)] = row[c];
      }
      row_sums[j] = sum;
    }
  }
  if (out) {
    out->n = n;
    out->k = k;
    out->n_blocks = blocks;
    out->k_pad = k_pad;
    out->packed = packed;
    out->row_sums = row_sums;
  }
  return 1;
}

/* What the instruction does, written out: the same sums in the same order. This is what runs on a
 * core without SDOT, which is how the layout and the algebra get tested, and it is also the path an
 * arm64-v8a build takes on an ARMv8.0 core. */
static void dot_panel_portable(const int8_t *a, int m, int lda, const int8_t *panel, int groups,
                               const int32_t *row_sums, int j0, int valid, int32_t correction,
                               int32_t *out, int ldc) {
  for (int i = 0; i < m; ++i) {
    const int8_t *pa0 = a + (size_t)i * lda;
    for (int u = 0; u < valid; ++u) {
      int32_t sum = 0;
      for (int g = 0; g < groups; ++g) {
        const int8_t *wg = panel + (size_t)g * (ZF_DOT_UNIT_BLOCK * ZF_DOT_K_GROUP) +
                           (size_t)u * ZF_DOT_K_GROUP;
        for (int e = 0; e < ZF_DOT_K_GROUP; ++e)
          sum += (int32_t)pa0[g * ZF_DOT_K_GROUP + e] * (int32_t)wg[e];
      }
      out[(size_t)i * ldc + j0 + u] = sum + correction * row_sums[j0 + u];
    }
  }
}

#if ZF_DOT
/* Two rows against one set of weights, so a weight load pays for two dot products, and four SDOTs
 * consume the sixteen activation bytes one load brings in. The generated loop is seventeen
 * instructions, eight of them SDOT, for 128 multiply-adds. */
static void dot_panel_sdot(const int8_t *a, int m, int lda, const int8_t *panel, int k_pad,
                           const int32_t *row_sums, int j0, int valid, int32_t correction,
                           int32_t *out, int ldc) {
  const int32x4_t corr = vmulq_n_s32(vld1q_s32(row_sums + j0), correction);
  int i = 0;
  for (; i + 2 <= m; i += 2) {
    const int8_t *pa0 = a + (size_t)i * lda;
    const int8_t *pa1 = pa0 + lda;
    const int8_t *pw = panel;
    int32x4_t c0 = vdupq_n_s32(0), c1 = vdupq_n_s32(0);
    for (int p = 0; p < k_pad; p += 16) {
      const int8x16_t av0 = vld1q_s8(pa0 + p), av1 = vld1q_s8(pa1 + p);
      const int8x16_t w0 = vld1q_s8(pw), w1 = vld1q_s8(pw + 16);
      const int8x16_t w2 = vld1q_s8(pw + 32), w3 = vld1q_s8(pw + 48);
      c0 = vdotq_laneq_s32(c0, w0, av0, 0);
      c1 = vdotq_laneq_s32(c1, w0, av1, 0);
      c0 = vdotq_laneq_s32(c0, w1, av0, 1);
      c1 = vdotq_laneq_s32(c1, w1, av1, 1);
      c0 = vdotq_laneq_s32(c0, w2, av0, 2);
      c1 = vdotq_laneq_s32(c1, w2, av1, 2);
      c0 = vdotq_laneq_s32(c0, w3, av0, 3);
      c1 = vdotq_laneq_s32(c1, w3, av1, 3);
      pw += 64;
    }
    int32_t t0[ZF_DOT_UNIT_BLOCK], t1[ZF_DOT_UNIT_BLOCK];
    vst1q_s32(t0, vaddq_s32(c0, corr));
    vst1q_s32(t1, vaddq_s32(c1, corr));
    for (int u = 0; u < valid; ++u) {
      out[(size_t)i * ldc + j0 + u] = t0[u];
      out[(size_t)(i + 1) * ldc + j0 + u] = t1[u];
    }
  }
  for (; i < m; ++i) {
    const int8_t *pa0 = a + (size_t)i * lda;
    const int8_t *pw = panel;
    int32x4_t c0 = vdupq_n_s32(0);
    for (int p = 0; p < k_pad; p += 16) {
      const int8x16_t av0 = vld1q_s8(pa0 + p);
      c0 = vdotq_laneq_s32(c0, vld1q_s8(pw), av0, 0);
      c0 = vdotq_laneq_s32(c0, vld1q_s8(pw + 16), av0, 1);
      c0 = vdotq_laneq_s32(c0, vld1q_s8(pw + 32), av0, 2);
      c0 = vdotq_laneq_s32(c0, vld1q_s8(pw + 48), av0, 3);
      pw += 64;
    }
    int32_t t0[ZF_DOT_UNIT_BLOCK];
    vst1q_s32(t0, vaddq_s32(c0, corr));
    for (int u = 0; u < valid; ++u) out[(size_t)i * ldc + j0 + u] = t0[u];
  }
}

/* Four panels (sixteen output units) against up to four rows at once. The two-row kernel above keeps
 * two accumulators, so every SDOT waits for the one before it on the same register; here sixteen
 * independent accumulators keep the dot-product pipes busy, and a step of sixteen k is 64 SDOTs for
 * R + 16 loads. The sums are the same integers in a different order, which integer addition does not
 * see, and the correction is added exactly as before, so the int32 outputs are identical. */
static inline __attribute__((always_inline)) void dot_4panels_rows(
    const int8_t *a, int lda, const int8_t *p0, size_t pstride, int k_pad, const int32x4_t corr[4],
    int32_t *out, int ldc, int R) {
  const int8_t *pw[4] = {p0, p0 + pstride, p0 + 2 * pstride, p0 + 3 * pstride};
  int32x4_t acc[4][4];
  for (int r = 0; r < 4; ++r)
    for (int q = 0; q < 4; ++q) acc[r][q] = vdupq_n_s32(0);
  for (int p = 0, off = 0; p < k_pad; p += 16, off += 64) {
    int8x16_t av[4];
    for (int r = 0; r < R; ++r) av[r] = vld1q_s8(a + (size_t)r * lda + p);
    for (int q = 0; q < 4; ++q) {
      const int8x16_t w0 = vld1q_s8(pw[q] + off), w1 = vld1q_s8(pw[q] + off + 16);
      const int8x16_t w2 = vld1q_s8(pw[q] + off + 32), w3 = vld1q_s8(pw[q] + off + 48);
      for (int r = 0; r < R; ++r) {
        acc[r][q] = vdotq_laneq_s32(acc[r][q], w0, av[r], 0);
        acc[r][q] = vdotq_laneq_s32(acc[r][q], w1, av[r], 1);
        acc[r][q] = vdotq_laneq_s32(acc[r][q], w2, av[r], 2);
        acc[r][q] = vdotq_laneq_s32(acc[r][q], w3, av[r], 3);
      }
    }
  }
  for (int r = 0; r < R; ++r)
    for (int q = 0; q < 4; ++q) vst1q_s32(out + (size_t)r * ldc + 4 * q, vaddq_s32(acc[r][q], corr[q]));
}

static void dot_4panels_sdot(const int8_t *a, int m, int lda, const int8_t *panel0, int k_pad,
                             const int32_t *row_sums, int j0, int32_t correction, int32_t *out,
                             int ldc) {
  const size_t pstride = (size_t)ZF_DOT_UNIT_BLOCK * k_pad;
  int32x4_t corr[4];
  for (int q = 0; q < 4; ++q) corr[q] = vmulq_n_s32(vld1q_s32(row_sums + j0 + 4 * q), correction);
  int i = 0;
  for (; i + 4 <= m; i += 4)
    dot_4panels_rows(a + (size_t)i * lda, lda, panel0, pstride, k_pad, corr, out + (size_t)i * ldc + j0, ldc, 4);
  switch (m - i) {
    case 3: dot_4panels_rows(a + (size_t)i * lda, lda, panel0, pstride, k_pad, corr, out + (size_t)i * ldc + j0, ldc, 3); break;
    case 2: dot_4panels_rows(a + (size_t)i * lda, lda, panel0, pstride, k_pad, corr, out + (size_t)i * ldc + j0, ldc, 2); break;
    case 1: dot_4panels_rows(a + (size_t)i * lda, lda, panel0, pstride, k_pad, corr, out + (size_t)i * ldc + j0, ldc, 1); break;
    default: break;
  }
}
#endif

int zf_weights_s8_to_dot(int8_t *packed, int n, int k) {
  const int k_pad = round_up16(k);
  const int blocks = (n + ZF_DOT_UNIT_BLOCK - 1) / ZF_DOT_UNIT_BLOCK;
  if (k_pad % ZF_S8_K_GROUP != 0 || ZF_S8_UNIT_BLOCK != ZF_DOT_UNIT_BLOCK) return 0;
  int8_t tmp[ZF_S8_UNIT_BLOCK * 64];
  const int panel_bytes = ZF_DOT_UNIT_BLOCK * k_pad;
  for (int jb = 0; jb < blocks; ++jb) {
    int8_t *panel = packed + (size_t)jb * panel_bytes;
    /* one k group of sixteen at a time, which is 64 bytes in either layout */
    for (int g16 = 0; g16 < k_pad / ZF_S8_K_GROUP; ++g16) {
      int8_t *src = panel + (size_t)g16 * (ZF_S8_UNIT_BLOCK * ZF_S8_K_GROUP);
      memcpy(tmp, src, ZF_S8_UNIT_BLOCK * ZF_S8_K_GROUP);
      for (int u = 0; u < ZF_DOT_UNIT_BLOCK; ++u)
        for (int e = 0; e < ZF_S8_K_GROUP; ++e) {
          /* pairing holds unit u's sixteen k together; dot wants four k of every unit together */
          const int c = g16 * ZF_S8_K_GROUP + e;
          const int g4 = (c / ZF_DOT_K_GROUP) - g16 * (ZF_S8_K_GROUP / ZF_DOT_K_GROUP);
          src[(size_t)g4 * (ZF_DOT_UNIT_BLOCK * ZF_DOT_K_GROUP) + (size_t)u * ZF_DOT_K_GROUP +
              (c % ZF_DOT_K_GROUP)] = tmp[(size_t)u * ZF_S8_K_GROUP + e];
        }
    }
  }
  return 1;
}

void zf_linear_s8_dot_range(const int8_t *a, int m, int lda, const ZfWeightsS8 *w, int a_zero_point,
                            int32_t *out, int ldc, int block_begin, int block_end) {
  const int k_pad = w->k_pad;
  const int32_t correction = 128 - a_zero_point;
  const int groups = k_pad / ZF_DOT_K_GROUP;
  const int use_dot = zf_dot_available();
  static _Atomic int wide = -1; /* ZF_DOT_NARROW=1 keeps to the one-panel kernel, for A/B runs */
  if (wide < 0) wide = zf_getenv("ZF_DOT_NARROW") ? 0 : 1;

  for (int jb = block_begin; jb < block_end; ++jb) {
    const int8_t *panel = w->packed + (size_t)jb * ZF_DOT_UNIT_BLOCK * k_pad;
    const int j0 = jb * ZF_DOT_UNIT_BLOCK;
#if ZF_DOT
    if (use_dot && jb + 4 <= block_end && j0 + 4 * ZF_DOT_UNIT_BLOCK <= w->n && wide) {
      dot_4panels_sdot(a, m, lda, panel, k_pad, w->row_sums, j0, correction, out, ldc);
      jb += 3;
      continue;
    }
#endif
    const int valid = (w->n - j0) < ZF_DOT_UNIT_BLOCK ? (w->n - j0) : ZF_DOT_UNIT_BLOCK;
#if ZF_DOT
    if (use_dot) {
      dot_panel_sdot(a, m, lda, panel, k_pad, w->row_sums, j0, valid, correction, out, ldc);
      continue;
    }
#endif
    (void)use_dot;
    dot_panel_portable(a, m, lda, panel, groups, w->row_sums, j0, valid, correction, out, ldc);
  }
}
