/* The public surface of zf_tajweed.h, read from the header's own text.
 *
 *   test_api <tajweed/include/zf_tajweed.h>
 *
 * SDK 3.0 is inference only, and this keeps it so: with the comments taken out, the header must
 * declare exactly the functions and types listed below, in this order, and no identifier of the 2.x
 * scorer, settings, name tables or expected-table calls. Adding a function to the header without
 * adding it here fails; so does bringing a scorer name back. (The header's opening comment names
 * what was removed, which is why comments are taken out first.) */
#include <ctype.h>

#include "tj_test.h"
#include "zf_tajweed.h"

static const char *const kFunctions[] = {
    "zf_tajweed_version",
    "zf_tajweed_api_version",
    "zf_tajweed_open_default_options",
    "zf_tajweed_model_open",
    "zf_tajweed_model_close",
    "zf_tajweed_model_context",
    "zf_tajweed_model_chunk_ms",
    "zf_tajweed_token_name",
    "zf_tajweed_model_calibration",
    "zf_tajweed_stream_create",
    "zf_tajweed_stream_destroy",
    "zf_tajweed_stream_set_callback",
    "zf_tajweed_stream_reset",
    "zf_tajweed_stream_push_audio",
    "zf_tajweed_stream_finish",
    "zf_tajweed_stream_heads",
    "zf_tajweed_stream_greedy",
    "zf_tajweed_stream_last_error",
    "zf_tajweed_stream_set_heads",
    "zf_tajweed_stream_get_heads",
    "zf_tajweed_head_info",
    "zf_tajweed_top2",
    "zf_tajweed_stream_top2",
    "zf_tajweed_topk",
    "zf_tajweed_stream_topk",
    "zf_tajweed_reference_open",
    "zf_tajweed_reference_open_memory",
    "zf_tajweed_reference_close",
    "zf_tajweed_reference_ayah_count",
    "zf_tajweed_reference_units",
    "zf_tajweed_reference_tokens_sha256",
};
#define N_FUNCTIONS ((int)(sizeof kFunctions / sizeof kFunctions[0]))

static const char *const kTypes[] = {
    "ZfTajweedModel", "ZfTajweedOpenOptions", "ZfTajweedHeads", "ZfTajweedStream",
    "ZfTajweedChunkCallback", "ZfTajweedTop2", "ZfTajweedReference",
};
#define N_TYPES ((int)(sizeof kTypes / sizeof kTypes[0]))

/* 2.x names that must not come back: whole identifiers, and prefixes (a trailing '*') */
static const char *const kRemoved[] = {
    "zf_tajweed_score", "zf_tajweed_result_*", "zf_tajweed_config_*", "zf_tajweed_expected_*",
    "zf_tajweed_ayah_count", "zf_tajweed_class_*", "zf_tajweed_check_*", "zf_tajweed_preset_*",
    "zf_tajweed_madd_class_name", "zf_tajweed_word_preset_*", "zf_tajweed_model_id",
    "zf_tajweed_model_context_at", "zf_tajweed_model_default_context", "ZF_TJ_*", "ZF_TAJWEED_HEADS_SCORER",
    "ZfTajweedConfig", "ZfTajweedResult", "ZfTajweedSite", "ZfTajweedMadd", "ZfTajweedLetter",
    "ZfTajweedWord", "ZfTajweedSummary", "ZfTajweedEffective", "ZfTajweedWordSettings", "ZfTajweedClass",
    "ZfTajweedCheck", "ZfTajweedPreset", "ZfTajweedStatus", "ZfTajweedSource", "ZfTajweedMaddClass",
    "ZfTajweedWordPreset", "ZfTajweedEdit",
};

static int removed(const char *id) {
  for (size_t i = 0; i < sizeof kRemoved / sizeof kRemoved[0]; ++i) {
    const size_t n = strlen(kRemoved[i]);
    if (kRemoved[i][n - 1] == '*' ? !strncmp(id, kRemoved[i], n - 1) : !strcmp(id, kRemoved[i])) return 1;
  }
  return 0;
}

static int is_id(int c) { return isalnum(c) || c == '_'; }

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: %s <zf_tajweed.h>\n", argv[0]);
    return 2;
  }
  size_t size = 0;
  char *text = (char *)tj_test_read(argv[1], &size);
  CHECK(text != NULL && size > 1000);
  if (!text) return tj_test_done("api");

  /* comments out (the header has no string or character literal that holds a comment mark) */
  int comments = 0;
  for (size_t i = 0; i + 1 < size; ++i) {
    if (text[i] != '/' || text[i + 1] != '*') continue;
    size_t j = i + 2;
    while (j + 1 < size && !(text[j] == '*' && text[j + 1] == '/')) ++j;
    CHECK(j + 1 < size); /* every comment is closed */
    for (size_t k = i; k < j + 2 && k < size; ++k)
      if (text[k] != '\n') text[k] = ' ';
    ++comments;
    i = j + 1;
  }
  CHECK(comments > 20);
  CHECK(strstr(text, "//") == NULL);

  /* every identifier, in order */
  char seen_fn[64][48], seen_type[32][48];
  int n_fn = 0, n_type = 0, n_removed = 0, n_scorer_words = 0, has_default = 0, has_version = 0;
  for (size_t i = 0; i < size;) {
    if (!is_id((unsigned char)text[i]) || isdigit((unsigned char)text[i])) {
      ++i;
      continue;
    }
    size_t j = i;
    while (j < size && is_id((unsigned char)text[j])) ++j;
    char id[48];
    const size_t len = j - i;
    if (len < sizeof id) {
      memcpy(id, text + i, len);
      id[len] = 0;
      size_t k = j;
      while (k < size && (text[k] == ' ' || text[k] == '\n')) ++k;
      if (removed(id)) {
        fprintf(stderr, "zf_tajweed.h still declares %s\n", id);
        ++n_removed;
      }
      /* no identifier speaks of scoring at all */
      char low[48];
      for (size_t c = 0; c <= len; ++c) low[c] = (char)tolower((unsigned char)id[c]);
      if (strstr(low, "scor") || strstr(low, "verdict") || strstr(low, "threshold") || strstr(low, "preset"))
        ++n_scorer_words;
      if (!strcmp(id, "ZF_TAJWEED_HEADS_DEFAULT")) has_default = 1;
      if (!strcmp(id, "ZF_TAJWEED_API_VERSION")) has_version = 1;
      if (!strncmp(id, "zf_tajweed_", 11) && k < size && text[k] == '(') {
        int known = 0;
        for (int f = 0; f < n_fn; ++f) known |= !strcmp(seen_fn[f], id);
        if (!known && n_fn < 64) memcpy(seen_fn[n_fn++], id, len + 1);
      }
      if (!strncmp(id, "ZfTajweed", 9)) {
        int known = 0;
        for (int t = 0; t < n_type; ++t) known |= !strcmp(seen_type[t], id);
        if (!known && n_type < 32) memcpy(seen_type[n_type++], id, len + 1);
      }
    }
    i = j;
  }
  CHECK(n_removed == 0);
  CHECK(n_scorer_words == 0);
  CHECK(has_default && has_version);

  CHECK(n_fn == N_FUNCTIONS);
  for (int f = 0; f < n_fn && f < N_FUNCTIONS; ++f) {
    if (strcmp(seen_fn[f], kFunctions[f])) fprintf(stderr, "function %d is %s, expected %s\n", f, seen_fn[f], kFunctions[f]);
    CHECK(!strcmp(seen_fn[f], kFunctions[f]));
  }
  CHECK(n_type == N_TYPES);
  for (int t = 0; t < n_type && t < N_TYPES; ++t) {
    if (strcmp(seen_type[t], kTypes[t])) fprintf(stderr, "type %d is %s, expected %s\n", t, seen_type[t], kTypes[t]);
    CHECK(!strcmp(seen_type[t], kTypes[t]));
  }
  free(text);
  return tj_test_done("api");
}
