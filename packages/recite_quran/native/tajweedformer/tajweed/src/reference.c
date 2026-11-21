/* The reference data (zf_tajweed_reference_*): the expected units of each ayah, read from an
 * expected_tj3.zfx file (FORMAT.md) as a table of its own.
 *
 * A reader, not a judge: a file or a buffer in, and per surah and ayah the unit ids and the word of
 * each unit out. It has no link to a model: nothing here is called when a model is opened or run,
 * and nothing here looks at a take. Every read is bounds-checked against the file size before use;
 * the units and words are copied into arrays of int, so the caller's buffer is not kept.
 *
 * Read: the header, the ayah counts, the ayah index, the tokens and the words. The file's other
 * sections (token flags, madd entries, word forms, names) are checked to lie inside the file and are
 * otherwise not read. */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "internal.h"

#define ZFX_MAGIC "ZFTJEXP1"
#define ZFX_HEADER 160
#define ZFX_AYAH_REC 20
#define ZFX_MADD_REC 8

struct ZfTajweedReference {
  int n_surah, n_ayah;
  int *surah_first;                  /* [n_surah + 1]: index of the surah's first ayah */
  int *unit, *word;                  /* [n_units] each, all ayahs together (one allocation) */
  int *a_off, *a_count, *a_words;    /* [n_ayah] each (one allocation): first unit, units, words */
  unsigned char tokens_sha[32];
};

static uint32_t rd32(const unsigned char *p) {
  return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
static unsigned rd16(const unsigned char *p) { return (unsigned)p[0] | (unsigned)p[1] << 8; }

void zf_tajweed_reference_close(ZfTajweedReference *r) {
  if (!r) return;
  free(r->surah_first);
  free(r->unit);
  free(r->a_off);
  free(r);
}

static ZfTajweedReference *fail(ZfTajweedReference *r, const char **error, const char *msg) {
  zf_tajweed_reference_close(r);
  *error = msg;
  return NULL;
}

ZfTajweedReference *zf_tajweed_reference_open_memory(const void *bytes, size_t size, const char **error) {
  const char *dummy;
  if (!error) error = &dummy;
  const unsigned char *data = (const unsigned char *)bytes;
  if (!data) return fail(NULL, error, "reference data: no bytes");
  if (size < ZFX_HEADER || memcmp(data, ZFX_MAGIC, 8)) return fail(NULL, error, "reference data: not a ZFTJEXP1 file");
  if (rd32(data + 8) != 1) return fail(NULL, error, "reference data: unsupported version");
  if (rd32(data + 12) != ZFX_HEADER || rd32(data + 16) != size)
    return fail(NULL, error, "reference data: header or size mismatch (truncated?)");
  const uint32_t n_surah = rd32(data + 20), n_ayah = rd32(data + 24), n_tok = rd32(data + 28),
                 n_madd = rd32(data + 32), forms_bytes = rd32(data + 36);
  if (n_surah == 0 || n_surah > 1000 || n_ayah == 0 || n_ayah > 100000 || n_tok > 50000000 || n_madd > n_tok)
    return fail(NULL, error, "reference data: implausible counts");
  uint32_t off[8];
  for (int i = 0; i < 8; ++i) off[i] = rd32(data + 104 + 4 * i);
  /* ayah counts, ayah index, tokens, words, token flags, madd, forms, names */
  const uint64_t need[8] = {(uint64_t)n_surah * 2, (uint64_t)n_ayah * ZFX_AYAH_REC, n_tok, n_tok,
                            (uint64_t)n_tok * 2, (uint64_t)n_madd * ZFX_MADD_REC, forms_bytes, 4};
  for (int i = 0; i < 8; ++i)
    if (off[i] < ZFX_HEADER || (uint64_t)off[i] + need[i] > size)
      return fail(NULL, error, "reference data: a section lies outside the file");

  ZfTajweedReference *r = (ZfTajweedReference *)calloc(1, sizeof *r);
  if (!r) return fail(NULL, error, "out of memory");
  r->n_surah = (int)n_surah;
  r->n_ayah = (int)n_ayah;
  memcpy(r->tokens_sha, data + 72, 32);
  r->surah_first = (int *)malloc(sizeof(int) * ((size_t)n_surah + 1));
  r->unit = (int *)malloc(sizeof(int) * 2 * ((size_t)n_tok + 1));
  r->a_off = (int *)malloc(sizeof(int) * 3 * (size_t)n_ayah);
  if (!r->surah_first || !r->unit || !r->a_off) return fail(r, error, "out of memory");
  r->word = r->unit + n_tok;
  r->a_count = r->a_off + n_ayah;
  r->a_words = r->a_count + n_ayah;
  /* surahs */
  uint32_t acc = 0;
  for (uint32_t s = 0; s < n_surah; ++s) {
    r->surah_first[s] = (int)acc;
    acc += rd16(data + off[0] + 2 * s);
  }
  r->surah_first[n_surah] = (int)acc;
  if (acc != n_ayah) return fail(r, error, "reference data: ayah counts do not add up");
  /* units and their words */
  for (uint32_t i = 0; i < n_tok; ++i) {
    r->unit[i] = data[off[2] + i];
    r->word[i] = data[off[3] + i];
    if (r->unit[i] >= ZF_TAJWEED_VOCAB || r->unit[i] == ZF_TAJWEED_BLANK)
      return fail(r, error, "reference data: a unit outside tokens.txt");
  }
  /* ayahs */
  for (uint32_t a = 0; a < n_ayah; ++a) {
    const unsigned char *p = data + off[1] + (size_t)a * ZFX_AYAH_REC;
    const uint32_t first = rd32(p);
    const unsigned count = rd16(p + 12), words = p[16];
    if ((uint64_t)first + count > n_tok || count == 0 || words == 0)
      return fail(r, error, "reference data: an ayah record points outside its section");
    for (unsigned i = 0; i < count; ++i)
      if (r->word[first + i] >= (int)words) return fail(r, error, "reference data: a word id past the ayah's words");
    r->a_off[a] = (int)first;
    r->a_count[a] = (int)count;
    r->a_words[a] = (int)words;
  }
  return r;
}

ZfTajweedReference *zf_tajweed_reference_open(const char *path, const char **error) {
  const char *dummy;
  if (!error) error = &dummy;
  if (!path) return fail(NULL, error, "reference data: no path");
  size_t size = 0;
  unsigned char *data = zf_tj_read_file(path, &size);
  if (!data) return fail(NULL, error, "reference data: cannot read the file");
  ZfTajweedReference *r = zf_tajweed_reference_open_memory(data, size, error);
  free(data);
  return r;
}

int zf_tajweed_reference_ayah_count(const ZfTajweedReference *r, int surah) {
  if (!r || surah < 1 || surah > r->n_surah) return 0;
  return r->surah_first[surah] - r->surah_first[surah - 1];
}

int zf_tajweed_reference_units(const ZfTajweedReference *r, int surah, int ayah, const int **units,
                               const int **word_of_unit, int *n_words) {
  const int n = zf_tajweed_reference_ayah_count(r, surah);
  if (ayah < 1 || ayah > n) return -1;
  const int a = r->surah_first[surah - 1] + ayah - 1;
  if (units) *units = r->unit + r->a_off[a];
  if (word_of_unit) *word_of_unit = r->word + r->a_off[a];
  if (n_words) *n_words = r->a_words[a];
  return r->a_count[a];
}

const unsigned char *zf_tajweed_reference_tokens_sha256(const ZfTajweedReference *r) {
  return r ? r->tokens_sha : NULL;
}
