/* The int8 matmul kernels (zf/kernels.h, zf/dot.h) against a plain scalar reference.
 *
 * Nearly all of a chunk's arithmetic is this product: out[i][j] = sum over k of (q[i][k] - zp) * w[j][k],
 * with q the uint8 activations (handed over as int8, 128 subtracted) and w the int8 weights. It is
 * integer arithmetic, so the result is exact or wrong. The reference below is three nested loops over
 * the unpacked weights; the kernels run on packed panels with NEON (or its emulation), so this checks
 * the packing, the zero-point correction through the row sums, the padding to 16 columns and the
 * microkernel's sums. Checked for the model's own shapes and a few odd ones, with weights at the
 * extremes (+-127) and activations over the whole int8 range:
 *   - the pairing kernel (what every shipped build runs) equals the reference;
 *   - the dot-product layout (SDOT on cores that have it, a portable loop elsewhere) equals it too,
 *     packed directly and repacked from a pairing panel;
 *   - a tile of some panels holds exactly those columns;
 *   - both packers refuse a weight of -128. */
#include <stdlib.h>
#include <string.h>

#include "zf/dot.h"
#include "zf/kernels.h"
#include "zf_test.h"

/* m rows, k inputs, n output units */
static const int kShapes[][3] = {
    {24, 192, 272}, {12, 256, 768}, {6, 1152, 384}, {3, 512, 1536}, {24, 2432, 192},
    {1, 16, 8},     {5, 33, 7},     {2, 64, 4},     {7, 1, 1},      {4, 17, 13},
};

static void one_shape(int m, int k, int n, uint32_t seed) {
  uint32_t s = seed;
  int8_t *w = (int8_t *)malloc((size_t)n * k);
  int8_t *p_pair = (int8_t *)malloc(zf_weights_s8_packed_bytes(n, k));
  int8_t *p_dot = (int8_t *)malloc(zf_weights_s8_packed_dot_bytes(n, k));
  int32_t *sums_pair = (int32_t *)malloc((size_t)zf_weights_s8_row_sums_count(n) * sizeof(int32_t));
  int32_t *sums_dot = (int32_t *)malloc((size_t)zf_weights_s8_row_sums_count(n) * sizeof(int32_t));
  CHECK(w && p_pair && p_dot && sums_pair && sums_dot);
  if (!w || !p_pair || !p_dot || !sums_pair || !sums_dot) return;
  for (size_t i = 0; i < (size_t)n * k; ++i) {
    const uint32_t u = zf_test_lcg(&s) >> 8;
    /* one weight in eight at an extreme, the rest anywhere in [-127, 127] */
    w[i] = (int8_t)((u & 7) == 0 ? ((u & 8) ? 127 : -127) : (int)((u >> 4) % 255u) - 127);
  }
  ZfWeightsS8 pair, dot;
  CHECK(zf_weights_s8_pack(w, n, k, p_pair, sums_pair, &pair) != 0);
  CHECK(zf_weights_s8_pack_dot(w, n, k, p_dot, sums_dot, &dot) != 0);
  CHECK(pair.n == n && pair.k == k && pair.k_pad == (k + 15) / 16 * 16 && pair.n_blocks == (n + 3) / 4);
  CHECK(dot.k_pad == pair.k_pad && dot.n_blocks == pair.n_blocks);
  for (int j = 0; j < n; ++j) {
    int32_t sum = 0;
    for (int c = 0; c < k; ++c) sum += w[(size_t)j * k + c];
    CHECK(sums_pair[j] == sum && sums_dot[j] == sum);
  }

  /* activations as the quantiser leaves them: int8 = uint8 - 128, rows at stride k_pad, the pad zero */
  const int lda = pair.k_pad;
  const int zp = (int)(zf_test_lcg(&s) >> 24); /* 0 .. 255 */
  int8_t *a = (int8_t *)calloc((size_t)m * lda, 1);
  int32_t *want = (int32_t *)malloc((size_t)m * n * sizeof(int32_t));
  int32_t *got = (int32_t *)malloc((size_t)m * n * sizeof(int32_t));
  CHECK(a && want && got);
  if (!a || !want || !got) return;
  for (int i = 0; i < m; ++i)
    for (int c = 0; c < k; ++c) a[(size_t)i * lda + c] = (int8_t)((int)(zf_test_lcg(&s) >> 24) - 128);
  for (int i = 0; i < m; ++i)
    for (int j = 0; j < n; ++j) {
      int32_t acc = 0;
      for (int c = 0; c < k; ++c) acc += ((int32_t)a[(size_t)i * lda + c] + 128 - zp) * (int32_t)w[(size_t)j * k + c];
      want[(size_t)i * n + j] = acc;
    }

  memset(got, 0x55, (size_t)m * n * sizeof(int32_t));
  zf_linear_s8(a, m, lda, &pair, zp, got, n);
  CHECK(!memcmp(got, want, (size_t)m * n * sizeof(int32_t)));

  memset(got, 0x55, (size_t)m * n * sizeof(int32_t));
  zf_linear_s8_dot_range(a, m, lda, &dot, zp, got, n, 0, dot.n_blocks);
  CHECK(!memcmp(got, want, (size_t)m * n * sizeof(int32_t)));

  /* a pairing panel repacked in place is the dot panel */
  int8_t *p_re = (int8_t *)malloc(zf_weights_s8_packed_bytes(n, k));
  CHECK(p_re != NULL);
  if (p_re) {
    memcpy(p_re, p_pair, zf_weights_s8_packed_bytes(n, k));
    CHECK(zf_weights_s8_to_dot(p_re, n, k) != 0);
    CHECK(zf_weights_s8_packed_dot_bytes(n, k) == zf_weights_s8_packed_bytes(n, k));
    CHECK(!memcmp(p_re, p_dot, zf_weights_s8_packed_dot_bytes(n, k)));
    free(p_re);
  }

  /* a tile: the panels from the second one on, into a block that starts at their first column */
  if (pair.n_blocks > 1) {
    const int j0 = ZF_S8_UNIT_BLOCK, cols = n - j0;
    int32_t *tile = (int32_t *)malloc((size_t)m * cols * sizeof(int32_t));
    CHECK(tile != NULL);
    if (tile) {
      zf_linear_s8_tile(a, m, lda, &pair, zp, tile, cols, 1, pair.n_blocks, j0);
      int same = 1;
      for (int i = 0; i < m; ++i)
        for (int j = 0; j < cols; ++j) same &= tile[(size_t)i * cols + j] == want[(size_t)i * n + j0 + j];
      CHECK(same);
      free(tile);
    }
  }

  /* -128 does not fit the pairing kernel's int16 lane: both packers refuse it */
  w[(size_t)(n - 1) * k + (k - 1)] = -128;
  CHECK(zf_weights_s8_pack(w, n, k, p_pair, sums_pair, &pair) == 0);
  CHECK(zf_weights_s8_pack_dot(w, n, k, p_dot, sums_dot, &dot) == 0);

  free(w);
  free(p_pair);
  free(p_dot);
  free(sums_pair);
  free(sums_dot);
  free(a);
  free(want);
  free(got);
}

int main(void) {
  for (int c = 0; c < (int)(sizeof kShapes / sizeof kShapes[0]); ++c)
    one_shape(kShapes[c][0], kShapes[c][1], kShapes[c][2], 20261111u + (uint32_t)c);
  return zf_test_done("kernels");
}
