/* The decoded layer's pure functions: the head table, top-K and top-2. They take values from any
 * source (the exact engine, an accelerator, a server) and need no model. */
#include "internal.h"

/* the heads in ZfTajweedHeads order, which is the ZF_TAJWEED_HEAD_ bit order */
static const struct { const char *name; int frame_ms, cols; } HEADS[12] = {
    {"log_probs", 40, 38},    {"inter1_log_probs", 40, 38}, {"inter4_log_probs", 40, 38},
    {"id_log_probs", 20, 38}, {"timing_log_probs", 20, 38}, {"gem", 20, 2},
    {"attr_tafkheem", 20, 3}, {"attr_ghunna", 20, 5},       {"attr_qalqalah", 20, 3},
    {"attr_face", 20, 4},     {"boundary", 20, 1},          {"conf", 20, 1},
};
const char *zf_tajweed_head_info(unsigned head, int *frame_ms, int *cols) {
  for (int k = 0; k < 12; ++k)
    if (head == (1u << k)) {
      if (frame_ms) *frame_ms = HEADS[k].frame_ms;
      if (cols) *cols = HEADS[k].cols;
      return HEADS[k].name;
    }
  return NULL;
}

/* Top-K: per row, k passes of a selection over the not yet ranked entries: the next entry is
 * the largest value, the lower id on a tie (a strictly greater value replaces the candidate, scanning
 * ids upwards), which is a stable argsort of the negated row. The margin of the last entry asked for
 * needs the next rank, so one more pass runs when k < cols. NaN is never expected in the heads (they are
 * softmax / log-softmax rows); a NaN entry ranks after every number. */
#define TJ_TOPK_MAX 64
int zf_tajweed_topk(const float *values, int frames, int cols, int k, int *ids, float *values_out,
                    float *margins) {
  if (!values || !ids || frames < 0 || cols < 1 || cols > TJ_TOPK_MAX || k < 1 || k > cols) return -1;
  const int passes = k < cols ? k + 1 : k;
  for (int f = 0; f < frames; ++f) {
    const float *row = values + (size_t)f * cols;
    unsigned char taken[TJ_TOPK_MAX] = {0};
    int rank[TJ_TOPK_MAX + 1];
    for (int j = 0; j < passes; ++j) {
      int best = -1;
      for (int v = 0; v < cols; ++v) {
        if (taken[v]) continue;
        if (best < 0 || row[v] > row[best] || (row[best] != row[best] && row[v] == row[v])) best = v;
      }
      taken[best] = 1;
      rank[j] = best;
    }
    int *io = ids + (size_t)f * k;
    for (int j = 0; j < k; ++j) {
      io[j] = rank[j];
      if (values_out) values_out[(size_t)f * k + j] = row[rank[j]];
      if (margins) margins[(size_t)f * k + j] = j + 1 < cols ? row[rank[j]] - row[rank[j + 1]] : 0.0f;
    }
  }
  return frames;
}

/* The decoded layer's top-1 and runner-up: zf_tajweed_topk at k = 2 (the same ranking as the engine's
 * decoder, so `token` is the greedy argmax). */
int zf_tajweed_top2(const float *lp, int frames, int vocab, ZfTajweedTop2 *out) {
  if (!lp || !out || frames < 0 || vocab < 2) return -1;
  for (int f = 0; f < frames; ++f) {
    int id[2];
    float val[2], mg[2];
    if (zf_tajweed_topk(lp + (size_t)f * vocab, 1, vocab, 2, id, val, mg) != 1) return -1;
    out[f].token = id[0];
    out[f].runner_up = id[1];
    out[f].log_prob = val[0];
    out[f].runner_up_log_prob = val[1];
    out[f].margin = val[0] - val[1];
  }
  return frames;
}
