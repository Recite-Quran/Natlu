/* The reference data reader (zf_tajweed_reference_*) on tests/data/model/expected_tj3.zfx.
 *
 *   test_reference <tests/data/model> <scratch dir>
 *
 * The table is synthetic (24 ayahs of random tokens in surahs 1 to 4, not Quran text). The expected
 * values below are what the 2.x calls zf_tajweed_ayah_count, zf_tajweed_expected_tokens and
 * zf_tajweed_expected_words returned for this file before they were removed: three ayahs written out
 * unit by unit, and a fingerprint of all 24 (count, words, every unit id and every unit's word), so
 * the reader is held to the 2.x output for the whole table. Checked:
 *   - the ayah count of every surah, and 0 for a surah the table does not have;
 *   - the units and the word of each unit, from a file and from memory, the same pointers' contents
 *     after the caller's buffer is overwritten (the reader keeps nothing of it);
 *   - an ayah or surah out of range is -1 and leaves the outputs alone;
 *   - the table names the tokens.txt it was built against (its SHA-256);
 *   - a truncated file, a file cut with its size field adjusted, and a file with one field damaged
 *     (magic, version, header size, a count, a section offset, a unit id, a word id, an ayah record)
 *     are each refused with a message, and the untouched bytes still open afterwards. */
#include <stdint.h>

#include "tj_test.h"
#include "zf_tajweed.h"

/* the 2.x output, tajweed/tests/data/model/expected_tj3.zfx (sha256 31186b4a...) */
static const int kAyahs[4] = {7, 5, 4, 8};
static const int kUnits_1_1[] = {7, 35, 19, 35, 20};
static const int kWords_1_1[] = {0, 0, 0, 0, 0};
static const int kUnits_2_3[] = {19, 32, 27, 33, 24, 34, 21, 1, 13, 32, 17, 31, 1, 27, 31, 20, 35, 22};
static const int kWords_2_3[] = {0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2};
static const int kUnits_4_8[] = {8, 31, 4, 32, 27, 33, 1, 6, 33, 1, 5, 32, 20, 34, 17};
static const int kWords_4_8[] = {0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 2, 2, 2, 2, 2};
#define TABLE_FINGERPRINT 0x49957c68b358f237ull
/* sha256 of tests/data/model/tokens.txt */
static const unsigned char kTokensSha[32] = {
    0x66, 0xfe, 0x6e, 0xb8, 0x1b, 0x15, 0x50, 0x62, 0x70, 0xf9, 0xe3, 0xc6, 0xef, 0xb0, 0x72, 0x4c,
    0xda, 0x75, 0x7c, 0xd5, 0x43, 0x26, 0xf2, 0x6c, 0xa4, 0xbc, 0xd6, 0xbe, 0x4f, 0x3b, 0x2a, 0xa4};

static uint64_t fnv(uint64_t h, const void *data, size_t n) {
  const unsigned char *p = (const unsigned char *)data;
  for (size_t i = 0; i < n; ++i) h = (h ^ p[i]) * 1099511628211ull;
  return h;
}

static void ayah_is(const ZfTajweedReference *r, int surah, int ayah, const int *units, const int *words, int n,
                    int n_words) {
  const int *u = NULL, *w = NULL;
  int nw = -1;
  CHECK(zf_tajweed_reference_units(r, surah, ayah, &u, &w, &nw) == n);
  CHECK(u != NULL && w != NULL && nw == n_words);
  if (!u || !w) return;
  CHECK(!memcmp(u, units, (size_t)n * sizeof(int)));
  CHECK(!memcmp(w, words, (size_t)n * sizeof(int)));
  /* every output is optional */
  CHECK(zf_tajweed_reference_units(r, surah, ayah, NULL, NULL, NULL) == n);
}

static void table_is(const ZfTajweedReference *r) {
  CHECK(r != NULL);
  if (!r) return;
  for (int s = 1; s <= 4; ++s) CHECK(zf_tajweed_reference_ayah_count(r, s) == kAyahs[s - 1]);
  CHECK(zf_tajweed_reference_ayah_count(r, 5) == 0 && zf_tajweed_reference_ayah_count(r, 114) == 0);
  CHECK(zf_tajweed_reference_ayah_count(r, 0) == 0 && zf_tajweed_reference_ayah_count(r, 115) == 0 &&
        zf_tajweed_reference_ayah_count(r, -1) == 0);
  ayah_is(r, 1, 1, kUnits_1_1, kWords_1_1, 5, 1);
  ayah_is(r, 2, 3, kUnits_2_3, kWords_2_3, 18, 3);
  ayah_is(r, 4, 8, kUnits_4_8, kWords_4_8, 15, 3);

  /* out of range: -1, and the outputs are left alone */
  const int *u = kUnits_1_1, *w = kWords_1_1;
  int nw = 77;
  CHECK(zf_tajweed_reference_units(r, 1, 8, &u, &w, &nw) == -1);
  CHECK(zf_tajweed_reference_units(r, 1, 0, &u, &w, &nw) == -1);
  CHECK(zf_tajweed_reference_units(r, 5, 1, &u, &w, &nw) == -1);
  CHECK(zf_tajweed_reference_units(r, 0, 1, &u, &w, &nw) == -1);
  CHECK(zf_tajweed_reference_units(r, 115, 1, &u, &w, &nw) == -1);
  CHECK(u == kUnits_1_1 && w == kWords_1_1 && nw == 77);

  /* all 24 ayahs against the 2.x output */
  uint64_t h = 1469598103934665603ull;
  int ayahs = 0;
  for (int s = 1; s <= 114; ++s)
    for (int a = 1; a <= zf_tajweed_reference_ayah_count(r, s); ++a) {
      const int n = zf_tajweed_reference_units(r, s, a, &u, &w, &nw);
      CHECK(n > 0);
      if (n <= 0) continue;
      int32_t head[2] = {n, nw};
      h = fnv(h, head, sizeof head);
      h = fnv(h, u, (size_t)n * sizeof(int));
      h = fnv(h, w, (size_t)n * sizeof(int));
      /* a word bar closes the word before it; words count up from 0 without gaps */
      for (int i = 0; i < n; ++i) {
        CHECK(u[i] >= 1 && u[i] <= 36);
        CHECK(w[i] == (i == 0 ? 0 : w[i - 1] + (u[i - 1] == 1)));
      }
      CHECK(u[n - 1] != 1 && w[n - 1] == nw - 1);
      ++ayahs;
    }
  CHECK(ayahs == 24);
  CHECK(sizeof(int) == 4 && h == TABLE_FINGERPRINT);

  const unsigned char *sha = zf_tajweed_reference_tokens_sha256(r);
  CHECK(sha != NULL && !memcmp(sha, kTokensSha, 32));
}

static void wr32(unsigned char *p, uint32_t v) {
  p[0] = (unsigned char)v;
  p[1] = (unsigned char)(v >> 8);
  p[2] = (unsigned char)(v >> 16);
  p[3] = (unsigned char)(v >> 24);
}
static uint32_t rd32(const unsigned char *p) {
  return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

/* The bytes with `len` bytes at `at` replaced must be refused; the bytes are restored afterwards. */
static void damaged(unsigned char *d, size_t size, size_t at, const void *patch, size_t len, const char *what) {
  unsigned char keep[8];
  memcpy(keep, d + at, len);
  memcpy(d + at, patch, len);
  const char *err = NULL;
  ZfTajweedReference *r = zf_tajweed_reference_open_memory(d, size, &err);
  if (r) fprintf(stderr, "accepted a file with %s damaged\n", what);
  CHECK(r == NULL);
  CHECK(err != NULL && err[0] != 0);
  zf_tajweed_reference_close(r);
  memcpy(d + at, keep, len);
}

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: %s <tests/data/model> <scratch dir>\n", argv[0]);
    return 2;
  }
  char path[1100], cut[1100];
  tj_test_path(path, sizeof path, argv[1], "expected_tj3.zfx");
  const char *err = NULL;

  /* from a file */
  ZfTajweedReference *r = zf_tajweed_reference_open(path, &err);
  if (!r) fprintf(stderr, "reference_open: %s\n", err ? err : "?");
  table_is(r);
  zf_tajweed_reference_close(r);
  zf_tajweed_reference_close(NULL);

  /* from memory: the reader keeps nothing of the caller's buffer */
  size_t size = 0;
  unsigned char *file = tj_test_read(path, &size);
  CHECK(file != NULL && size == 4308);
  if (!file || size != 4308) return tj_test_done("reference");
  unsigned char *d = (unsigned char *)malloc(size);
  CHECK(d != NULL);
  if (!d) return tj_test_done("reference");
  memcpy(d, file, size);
  r = zf_tajweed_reference_open_memory(d, size, &err);
  memset(d, 0xff, size);
  table_is(r);
  zf_tajweed_reference_close(r);
  /* the error pointer is optional */
  r = zf_tajweed_reference_open_memory(file, size, NULL);
  CHECK(r != NULL);
  zf_tajweed_reference_close(r);

  /* nothing to read */
  CHECK(zf_tajweed_reference_open(NULL, &err) == NULL);
  CHECK(zf_tajweed_reference_open("no/such/expected_tj3.zfx", &err) == NULL);
  CHECK(zf_tajweed_reference_open_memory(NULL, size, &err) == NULL);
  CHECK(zf_tajweed_reference_open_memory(file, 0, &err) == NULL);
  CHECK(zf_tajweed_reference_ayah_count(NULL, 1) == 0);
  CHECK(zf_tajweed_reference_units(NULL, 1, 1, NULL, NULL, NULL) == -1);
  CHECK(zf_tajweed_reference_tokens_sha256(NULL) == NULL);

  /* truncated: every shorter length is refused (the header says how long the file is) */
  memcpy(d, file, size);
  for (size_t n = 0; n < size; n += n < 200 ? 1 : 97) {
    err = NULL;
    CHECK(zf_tajweed_reference_open_memory(d, n, &err) == NULL && err != NULL);
  }
  err = NULL;
  CHECK(zf_tajweed_reference_open_memory(d, size - 1, &err) == NULL && err != NULL);
  /* the same through a file */
  tj_test_mkdir(argv[2]);
  tj_test_path(cut, sizeof cut, argv[2], "truncated.zfx");
  CHECK(tj_test_write(cut, file, size - 1) == 0);
  err = NULL;
  CHECK(zf_tajweed_reference_open(cut, &err) == NULL && err != NULL);
  /* cut, with the size field made to agree: the last section now lies outside the file */
  unsigned char size_field[4];
  wr32(size_field, (uint32_t)(size - 4));
  memcpy(d + 16, size_field, 4);
  err = NULL;
  CHECK(zf_tajweed_reference_open_memory(d, size - 4, &err) == NULL && err != NULL);
  memcpy(d, file, size);

  /* one field damaged at a time */
  const uint32_t o_counts = rd32(file + 104), o_index = rd32(file + 108), o_units = rd32(file + 112),
                 o_words = rd32(file + 116);
  CHECK(o_counts == 160 && rd32(file + 20) == 114 && rd32(file + 24) == 24 && rd32(file + 28) == 386);
  unsigned char v[4];
  damaged(d, size, 0, "ZFTJEXP2", 8, "the magic");
  wr32(v, 2);
  damaged(d, size, 8, v, 4, "the version");
  wr32(v, 164);
  damaged(d, size, 12, v, 4, "the header size");
  wr32(v, (uint32_t)size + 1);
  damaged(d, size, 16, v, 4, "the file size");
  wr32(v, 0);
  damaged(d, size, 20, v, 4, "the surah count (0)");
  damaged(d, size, 24, v, 4, "the ayah count (0)");
  wr32(v, 25);
  damaged(d, size, 24, v, 4, "the ayah count (one more than the surahs hold)");
  wr32(v, 0xfffffff0u);
  damaged(d, size, 28, v, 4, "the unit count");
  damaged(d, size, 112, v, 4, "the units' offset");
  wr32(v, 100);
  damaged(d, size, 116, v, 4, "the words' offset (inside the header)");
  wr32(v, (uint32_t)size - 3);
  damaged(d, size, 132, v, 4, "the names' offset (3 bytes before the end)");
  damaged(d, size, o_counts, "\010\000", 2, "surah 1's ayah count (8)");
  damaged(d, size, o_units, "\000", 1, "a unit (the blank)");
  damaged(d, size, o_units + 385, "\046", 1, "the last unit (38)");
  damaged(d, size, o_words, "\001", 1, "a word id (1 in an ayah of one word)");
  wr32(v, 386);
  damaged(d, size, o_index, v, 4, "ayah 1's first unit (past the units)");
  damaged(d, size, o_index + 12, "\000\000", 2, "ayah 1's unit count (0)");
  damaged(d, size, o_index + 16, "\000", 1, "ayah 1's word count (0)");
  damaged(d, size, o_index + 23 * 20 + 12, "\020\000", 2, "the last ayah's unit count (one too many)");

  /* and the bytes as shipped still open */
  CHECK(!memcmp(d, file, size));
  r = zf_tajweed_reference_open_memory(d, size, &err);
  table_is(r);
  zf_tajweed_reference_close(r);
  free(d);
  free(file);
  return tj_test_done("reference");
}
