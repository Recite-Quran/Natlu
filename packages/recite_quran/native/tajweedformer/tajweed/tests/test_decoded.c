/* The decoded layer's pure functions (zf_tajweed.h): zf_tajweed_topk, zf_tajweed_top2 and
 * zf_tajweed_head_info, on rows with known answers.
 *
 * The SDKs build what they show (the best token per frame, the runner-up and its margin, the ranked
 * list to any depth) on these, for heads from the CPU engine and from an accelerator alike. Checked:
 *   - the ranking is by value, highest first, and equal values by the lower id;
 *   - values and margins are the row's own floats (margin j = value j minus value j + 1, taken from
 *     the next rank even when it is beyond k, and 0 for the last rank of the row);
 *   - a NaN ranks after every number;
 *   - top-2 is top-K at k = 2, field for field;
 *   - the full ranking of 38-wide rows equals an independent stable insertion sort;
 *   - every argument out of range is refused with -1;
 *   - the twelve heads' names, frame periods and widths, and the head masks' values. */
#include <math.h>
#include <stdint.h>

#include "tj_test.h"
#include "zf_tajweed.h"

static void test_topk(void) {
  /* three rows of four: plain, a three-way tie, a NaN */
  const float nan = (float)NAN;
  const float v[3][4] = {{0.125f, 0.5f, 0.25f, 0.0625f}, {0.5f, 0.5f, 0.25f, 0.5f}, {nan, 1.0f, 2.0f, -1.0f}};
  int ids[12];
  float val[12], mg[12];
  CHECK(zf_tajweed_topk(&v[0][0], 3, 4, 4, ids, val, mg) == 3);
  const int want0[4] = {1, 2, 0, 3}, want1[4] = {0, 1, 3, 2}, want2[4] = {2, 1, 3, 0};
  for (int j = 0; j < 4; ++j) {
    CHECK(ids[j] == want0[j] && ids[4 + j] == want1[j] && ids[8 + j] == want2[j]);
    CHECK(val[j] == v[0][want0[j]] && val[4 + j] == v[1][want1[j]]);
  }
  CHECK(val[8] == 2.0f && val[9] == 1.0f && val[10] == -1.0f && isnan(val[11]));
  CHECK(mg[0] == 0.25f && mg[1] == 0.125f && mg[2] == 0.0625f && mg[3] == 0.0f);
  CHECK(mg[4] == 0.0f && mg[5] == 0.0f && mg[6] == 0.25f && mg[7] == 0.0f);
  CHECK(mg[8] == 1.0f && mg[9] == 2.0f && isnan(mg[10]) && mg[11] == 0.0f);

  /* k below the width: the last margin still comes from the next rank */
  int id2[6];
  float val2[6], mg2[6];
  CHECK(zf_tajweed_topk(&v[0][0], 3, 4, 2, id2, val2, mg2) == 3);
  CHECK(id2[0] == 1 && id2[1] == 2 && val2[0] == 0.5f && val2[1] == 0.25f && mg2[0] == 0.25f && mg2[1] == 0.125f);
  CHECK(id2[2] == 0 && id2[3] == 1 && mg2[2] == 0.0f && mg2[3] == 0.0f);
  CHECK(id2[4] == 2 && id2[5] == 1 && mg2[4] == 1.0f && mg2[5] == 2.0f);

  /* values and margins are optional; k = 1 is the argmax */
  int id1[3] = {-1, -1, -1};
  CHECK(zf_tajweed_topk(&v[0][0], 3, 4, 1, id1, NULL, NULL) == 3);
  CHECK(id1[0] == 1 && id1[1] == 0 && id1[2] == 2);

  /* one column: the only id, margin 0 */
  const float one[2] = {-3.0f, 7.0f};
  CHECK(zf_tajweed_topk(one, 2, 1, 1, ids, val, mg) == 2);
  CHECK(ids[0] == 0 && ids[1] == 0 && val[0] == -3.0f && val[1] == 7.0f && mg[0] == 0.0f && mg[1] == 0.0f);

  /* no frames: nothing written, 0 */
  ids[0] = -7;
  CHECK(zf_tajweed_topk(&v[0][0], 0, 4, 4, ids, val, mg) == 0 && ids[0] == -7);

  /* the widest row the function takes is 64 */
  float wide[65];
  int wid[65];
  for (int i = 0; i < 65; ++i) wide[i] = (float)i;
  CHECK(zf_tajweed_topk(wide, 1, 64, 64, wid, NULL, NULL) == 1);
  CHECK(wid[0] == 63 && wid[63] == 0);
  CHECK(zf_tajweed_topk(wide, 1, 65, 1, wid, NULL, NULL) == -1);

  /* refused */
  CHECK(zf_tajweed_topk(NULL, 1, 4, 1, ids, val, mg) == -1);
  CHECK(zf_tajweed_topk(&v[0][0], 1, 4, 1, NULL, val, mg) == -1);
  CHECK(zf_tajweed_topk(&v[0][0], -1, 4, 1, ids, val, mg) == -1);
  CHECK(zf_tajweed_topk(&v[0][0], 1, 0, 1, ids, val, mg) == -1);
  CHECK(zf_tajweed_topk(&v[0][0], 1, 4, 0, ids, val, mg) == -1);
  CHECK(zf_tajweed_topk(&v[0][0], 1, 4, 5, ids, val, mg) == -1);
}

static void test_top2(void) {
  const float lp[3][4] = {{-0.5f, -2.0f, -3.0f, -4.0f}, {-2.0f, -1.0f, -1.0f, -3.0f}, {-9.0f, -8.0f, -7.0f, -0.25f}};
  ZfTajweedTop2 t[3];
  CHECK(zf_tajweed_top2(&lp[0][0], 3, 4, t) == 3);
  CHECK(t[0].token == 0 && t[0].runner_up == 1 && t[0].log_prob == -0.5f && t[0].runner_up_log_prob == -2.0f &&
        t[0].margin == 1.5f);
  CHECK(t[1].token == 1 && t[1].runner_up == 2 && t[1].log_prob == -1.0f && t[1].runner_up_log_prob == -1.0f &&
        t[1].margin == 0.0f);
  CHECK(t[2].token == 3 && t[2].runner_up == 2 && t[2].log_prob == -0.25f && t[2].runner_up_log_prob == -7.0f &&
        t[2].margin == 6.75f);
  CHECK(zf_tajweed_top2(&lp[0][0], 0, 4, t) == 0);
  CHECK(zf_tajweed_top2(&lp[0][0], 3, 1, t) == -1);
  CHECK(zf_tajweed_top2(NULL, 3, 4, t) == -1);
  CHECK(zf_tajweed_top2(&lp[0][0], 3, 4, NULL) == -1);
  CHECK(zf_tajweed_top2(&lp[0][0], -1, 4, t) == -1);
}

/* 38-wide rows of small integers (so there are many ties), ranked to full depth and compared with a
 * stable insertion sort; top-2 must be the first two ranks. */
static void test_full_ranking(void) {
  enum { FRAMES = 200, COLS = ZF_TAJWEED_VOCAB };
  static float rows[FRAMES * COLS];
  static int ids[FRAMES * COLS];
  static float val[FRAMES * COLS], mg[FRAMES * COLS];
  static ZfTajweedTop2 t2[FRAMES];
  uint32_t s = 38u;
  for (int i = 0; i < FRAMES * COLS; ++i) {
    s = s * 1664525u + 1013904223u;
    rows[i] = -(float)((s >> 16) % 23u) * 0.25f;
  }
  CHECK(zf_tajweed_topk(rows, FRAMES, COLS, COLS, ids, val, mg) == FRAMES);
  CHECK(zf_tajweed_top2(rows, FRAMES, COLS, t2) == FRAMES);
  int bad = 0;
  for (int f = 0; f < FRAMES; ++f) {
    const float *row = rows + f * COLS;
    int ord[COLS];
    for (int v = 0; v < COLS; ++v) { /* a later id goes after an equal value */
      int j = v;
      while (j > 0 && row[ord[j - 1]] < row[v]) {
        ord[j] = ord[j - 1];
        --j;
      }
      ord[j] = v;
    }
    for (int j = 0; j < COLS; ++j)
      bad += ids[f * COLS + j] != ord[j] || val[f * COLS + j] != row[ord[j]] ||
             mg[f * COLS + j] != (j + 1 < COLS ? row[ord[j]] - row[ord[j + 1]] : 0.0f);
    bad += t2[f].token != ord[0] || t2[f].runner_up != ord[1] || t2[f].log_prob != row[ord[0]] ||
           t2[f].runner_up_log_prob != row[ord[1]] || t2[f].margin != row[ord[0]] - row[ord[1]];
  }
  CHECK(bad == 0);
}

static void test_heads(void) {
  static const struct { const char *name; int ms, cols; } want[12] = {
      {"log_probs", 40, 38},    {"inter1_log_probs", 40, 38}, {"inter4_log_probs", 40, 38},
      {"id_log_probs", 20, 38}, {"timing_log_probs", 20, 38}, {"gem", 20, 2},
      {"attr_tafkheem", 20, 3}, {"attr_ghunna", 20, 5},       {"attr_qalqalah", 20, 3},
      {"attr_face", 20, 4},     {"boundary", 20, 1},          {"conf", 20, 1},
  };
  for (int k = 0; k < 12; ++k) {
    int ms = -1, cols = -1;
    const char *name = zf_tajweed_head_info(1u << k, &ms, &cols);
    CHECK(name != NULL && !strcmp(name, want[k].name) && ms == want[k].ms && cols == want[k].cols);
    CHECK(zf_tajweed_head_info(1u << k, NULL, NULL) == name);
  }
  CHECK(zf_tajweed_head_info(0, NULL, NULL) == NULL);
  CHECK(zf_tajweed_head_info(3, NULL, NULL) == NULL);          /* two bits are not one head */
  CHECK(zf_tajweed_head_info(1u << 12, NULL, NULL) == NULL);

  CHECK(ZF_TAJWEED_HEAD_LOG_PROBS == 1 && ZF_TAJWEED_HEAD_INTER1 == 2 && ZF_TAJWEED_HEAD_INTER4 == 4 &&
        ZF_TAJWEED_HEAD_ID == 8 && ZF_TAJWEED_HEAD_TIMING == 16 && ZF_TAJWEED_HEAD_GEM == 32 &&
        ZF_TAJWEED_HEAD_TAFKHEEM == 64 && ZF_TAJWEED_HEAD_GHUNNA == 128 && ZF_TAJWEED_HEAD_QALQALAH == 256 &&
        ZF_TAJWEED_HEAD_FACE == 512 && ZF_TAJWEED_HEAD_BOUNDARY == 1024 && ZF_TAJWEED_HEAD_CONF == 2048);
  CHECK(ZF_TAJWEED_HEADS_ALL == 0xFFF);
  /* what a new stream computes: log_probs, inter1_log_probs, timing_log_probs, gem, attr_qalqalah */
  CHECK(ZF_TAJWEED_HEADS_DEFAULT == 0x133);
  CHECK(ZF_TAJWEED_VOCAB == 38 && ZF_TAJWEED_BLANK == 0);
}

int main(void) {
  test_topk();
  test_top2();
  test_full_ranking();
  test_heads();
  return tj_test_done("decoded");
}
