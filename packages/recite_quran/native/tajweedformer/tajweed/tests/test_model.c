/* The model folder through zf_tajweed.h, without weights: the tokens file, the open options, the
 * calibration as data, and the context's chunk length.
 *
 *   test_model <tests/data/model> <scratch dir>
 *
 * The test folder (tests/data/model) holds the real tokens.txt and synthetic companions (random
 * tokens, not Quran text). Model folders with one thing different are built under the scratch
 * directory. Checked:
 *   - every one of the 38 token names, byte for byte, and the ids out of range;
 *   - a tokens.txt with CR LF line ends, tabs or blank lines reads the same; one with a line missing,
 *     one too many, ids out of order, a name missing or an id that is not a number is refused;
 *   - a folder with tokens.txt alone opens: no calibration.json and no expected_tj3.zfx is needed;
 *   - zf_tajweed_model_calibration returns calibration.json byte for byte, and NULL without one; the
 *     bytes are not parsed (a calibration.json that is not JSON, with a NUL inside, comes back whole);
 *   - the model never reads expected_tj3.zfx (a folder whose table is garbage opens);
 *   - the default open options, and an options struct of an older header (shorter struct_size);
 *   - the context: required with the engine, optional without, and never a path;
 *   - with the engine built in: a context's chunk length comes from its graph's metadata (160, 320
 *     and 480 ms for 16, 32 and 48 frames a chunk) in a folder that has only tokens.txt and the
 *     context, and a context without a graph is refused. */
#include "tj_test.h"
#include "zf_tajweed.h"

static const char *const kTokens[ZF_TAJWEED_VOCAB] = {
    "<blk>", "|", "\330\241", "\330\250", "\330\252", "\330\253",
    "\330\254", "\330\255", "\330\256", "\330\257", "\330\260", "\330\261",
    "\330\262", "\330\263", "\330\264", "\330\265", "\330\266", "\330\267",
    "\330\270", "\330\271", "\330\272", "\331\201", "\331\202", "\331\203",
    "\331\204", "\331\205", "\331\206", "\331\207", "\331\210", "\331\212",
    "\332\272", "a", "i", "u", "aa", "ii",
    "uu", "<foreign>",
};

static const char *g_data, *g_tmp;

/* A model folder under the scratch directory holding tokens.txt: the test folder's, or `tokens` when
 * it is not NULL. Returns its path (a static buffer, valid until the next call). */
static const char *folder(const char *name, const char *tokens) {
  static char dir[1024];
  char p[1100];
  tj_test_path(dir, sizeof dir, g_tmp, name);
  tj_test_mkdir(dir);
  /* an earlier run's files do not carry over */
  remove(tj_test_path(p, sizeof p, dir, "calibration.json"));
  remove(tj_test_path(p, sizeof p, dir, "expected_tj3.zfx"));
  if (tokens) CHECK(tj_test_write(tj_test_path(p, sizeof p, dir, "tokens.txt"), tokens, strlen(tokens)) == 0);
  else CHECK(tj_test_copy(g_data, dir, "tokens.txt") == 0);
  return dir;
}

/* tokens.txt text: line `drop` left out (-1: none), `sep` between name and id, `eol` after each
 * line, `extra` appended */
static char *tokens_text(int drop, const char *sep, const char *eol, const char *extra) {
  static char text[2048]; /* 38 lines of at most 16 bytes and a short extra: far below this */
  size_t n = 0;
  for (int i = 0; i < ZF_TAJWEED_VOCAB; ++i) {
    if (i == drop) continue;
    size_t len = strlen(kTokens[i]);
    memcpy(text + n, kTokens[i], len);
    n += len;
    len = strlen(sep);
    memcpy(text + n, sep, len);
    n += len;
    if (i >= 10) text[n++] = (char)('0' + i / 10);
    text[n++] = (char)('0' + i % 10);
    len = strlen(eol);
    memcpy(text + n, eol, len);
    n += len;
  }
  const size_t len = extra ? strlen(extra) : 0;
  if (len) memcpy(text + n, extra, len);
  text[n + len] = 0;
  return text;
}

static void names_are(const ZfTajweedModel *m) {
  for (int i = 0; i < ZF_TAJWEED_VOCAB; ++i) {
    const char *name = zf_tajweed_token_name(m, i);
    CHECK(name != NULL && !strcmp(name, kTokens[i]));
  }
  CHECK(zf_tajweed_token_name(m, -1) == NULL);
  CHECK(zf_tajweed_token_name(m, ZF_TAJWEED_VOCAB) == NULL);
}

static ZfTajweedOpenOptions no_engine(void) {
  ZfTajweedOpenOptions o = zf_tajweed_open_default_options();
  o.load_engine = 0;
  return o;
}

static void accepted(const char *name, const char *tokens) {
  ZfTajweedOpenOptions o = no_engine();
  const char *err = NULL;
  ZfTajweedModel *m = zf_tajweed_model_open(folder(name, tokens), &o, &err);
  if (!m) fprintf(stderr, "%s: %s\n", name, err ? err : "?");
  CHECK(m != NULL);
  if (m) names_are(m);
  zf_tajweed_model_close(m);
}

static void refused(const char *name, const char *tokens) {
  ZfTajweedOpenOptions o = no_engine();
  const char *err = NULL;
  ZfTajweedModel *m = zf_tajweed_model_open(folder(name, tokens), &o, &err);
  CHECK(m == NULL);
  CHECK(err != NULL && strstr(err, "tokens.txt") != NULL);
  zf_tajweed_model_close(m);
}

static void test_tokens(void) {
  ZfTajweedOpenOptions o = no_engine();
  const char *err = NULL;
  ZfTajweedModel *m = zf_tajweed_model_open(g_data, &o, &err);
  if (!m) fprintf(stderr, "model_open: %s\n", err ? err : "?");
  CHECK(m != NULL);
  if (!m) return;
  names_are(m);
  CHECK(zf_tajweed_token_name(NULL, 0) == NULL);
  /* no engine was asked for: no chunk length, and no stream */
  CHECK(zf_tajweed_model_chunk_ms(m) == 0);
  CHECK(zf_tajweed_stream_create(m, &err) == NULL && err != NULL);
  zf_tajweed_model_close(m);
  zf_tajweed_model_close(NULL);

  /* the file written back from the names is the file */
  size_t n = 0;
  char p[1100];
  unsigned char *d = tj_test_read(tj_test_path(p, sizeof p, g_data, "tokens.txt"), &n);
  CHECK(d != NULL);
  if (d) {
    const char *text = tokens_text(-1, " ", "\n", NULL);
    CHECK(n == strlen(text) && !memcmp(d, text, n));
    free(d);
  }

  accepted("tokens_crlf", tokens_text(-1, " ", "\r\n", NULL));
  accepted("tokens_tab", tokens_text(-1, "\t", "\n", NULL));
  accepted("tokens_blank_lines", tokens_text(-1, "  ", "\n\n", "\n\n"));
  refused("tokens_37", tokens_text(37, " ", "\n", NULL));               /* a line missing at the end */
  refused("tokens_gap", tokens_text(5, " ", "\n", NULL));               /* a line missing in the middle: ids jump */
  refused("tokens_39", tokens_text(-1, " ", "\n", "extra 38\n"));       /* one too many */
  refused("tokens_noid", tokens_text(37, " ", "\n", "<foreign>\n"));    /* a name without an id */
  refused("tokens_noname", tokens_text(37, " ", "\n", " 37\n"));        /* an id without a name */
  refused("tokens_word", tokens_text(37, " ", "\n", "<foreign> x7\n")); /* an id that is not a number */
  refused("tokens_empty", "");
  /* no tokens.txt at all */
  char empty[1024];
  tj_test_path(empty, sizeof empty, g_tmp, "no_tokens");
  tj_test_mkdir(empty);
  err = NULL;
  CHECK(zf_tajweed_model_open(empty, &o, &err) == NULL && err != NULL && strstr(err, "tokens.txt") != NULL);
}

/* The calibration is data: present or absent, JSON or not, it comes back as the file's bytes. */
static void test_calibration(void) {
  ZfTajweedOpenOptions o = no_engine();
  const char *err = NULL;
  char p[1100];
  size_t file_n = 0;
  unsigned char *file = tj_test_read(tj_test_path(p, sizeof p, g_data, "calibration.json"), &file_n);
  CHECK(file != NULL && file_n == 8329);
  if (!file) return;

  /* the test folder has one */
  ZfTajweedModel *m = zf_tajweed_model_open(g_data, &o, &err);
  CHECK(m != NULL);
  if (m) {
    size_t n = 0;
    const unsigned char *c = (const unsigned char *)zf_tajweed_model_calibration(m, &n);
    CHECK(c != NULL && n == file_n);
    if (c && n == file_n) CHECK(!memcmp(c, file, n) && c[n] == 0);
    /* the size is optional, and the bytes are the same on every call */
    CHECK(zf_tajweed_model_calibration(m, NULL) == c);
    zf_tajweed_model_close(m);
  }
  free(file);

  /* a folder with tokens.txt alone: it opens, and there is no calibration */
  m = zf_tajweed_model_open(folder("tokens_only", NULL), &o, &err);
  if (!m) fprintf(stderr, "tokens_only: %s\n", err ? err : "?");
  CHECK(m != NULL);
  if (m) {
    size_t n = 77;
    CHECK(zf_tajweed_model_calibration(m, &n) == NULL && n == 0);
    CHECK(zf_tajweed_model_calibration(m, NULL) == NULL);
    names_are(m);
    zf_tajweed_model_close(m);
  }
  size_t n = 77;
  CHECK(zf_tajweed_model_calibration(NULL, &n) == NULL && n == 0);

  /* not JSON, with a NUL and high bytes inside: handed over whole, so nothing parsed it */
  static const char raw[] = "{ this is not JSON \0 \377\376 ] and it does not end";
  const char *dir = folder("calibration_raw", NULL);
  CHECK(tj_test_write(tj_test_path(p, sizeof p, dir, "calibration.json"), raw, sizeof raw - 1) == 0);
  m = zf_tajweed_model_open(dir, &o, &err);
  CHECK(m != NULL);
  if (m) {
    n = 0;
    const unsigned char *c = (const unsigned char *)zf_tajweed_model_calibration(m, &n);
    CHECK(c != NULL && n == sizeof raw - 1);
    if (c && n == sizeof raw - 1) CHECK(!memcmp(c, raw, sizeof raw));
    zf_tajweed_model_close(m);
  }
  /* an empty calibration.json is a file of no bytes, not an absent one */
  dir = folder("calibration_empty", NULL);
  CHECK(tj_test_write(tj_test_path(p, sizeof p, dir, "calibration.json"), "", 0) == 0);
  m = zf_tajweed_model_open(dir, &o, &err);
  CHECK(m != NULL);
  if (m) {
    n = 77;
    CHECK(zf_tajweed_model_calibration(m, &n) != NULL && n == 0);
    zf_tajweed_model_close(m);
  }

  /* the model never reads the reference data: a folder whose expected_tj3.zfx is garbage opens */
  dir = folder("reference_garbage", NULL);
  CHECK(tj_test_write(tj_test_path(p, sizeof p, dir, "expected_tj3.zfx"), "garbage", 7) == 0);
  m = zf_tajweed_model_open(dir, &o, &err);
  CHECK(m != NULL);
  if (m) names_are(m);
  zf_tajweed_model_close(m);
}

static void test_options(void) {
  ZfTajweedOpenOptions o = zf_tajweed_open_default_options();
  CHECK(o.struct_size == sizeof o && o.context == NULL && o.load_engine == 1 && o.threads == 0 &&
        o.sample_rate == 0 && o.batch == 1);
#if defined(__ANDROID__)
  CHECK(o.no_pin == 0);
#elif !defined(__APPLE__)
  CHECK(o.no_pin == 1); /* Windows, Linux, WebAssembly: threads are not pinned */
#endif
  CHECK(zf_tajweed_api_version() == ZF_TAJWEED_API_VERSION && ZF_TAJWEED_API_VERSION == 4);
  CHECK(zf_tajweed_version() != NULL && !strcmp(zf_tajweed_version(), "3.0.0"));
  const char *err = NULL;

  /* an options struct as a caller built against an older header passes it: the fields up to batch */
  o.load_engine = 0;
  o.struct_size = offsetof(ZfTajweedOpenOptions, batch) + sizeof(int);
  ZfTajweedModel *m = zf_tajweed_model_open(g_data, &o, &err);
  CHECK(m != NULL);
  zf_tajweed_model_close(m);
  /* shorter than that is refused */
  o.struct_size = offsetof(ZfTajweedOpenOptions, batch);
  err = NULL;
  CHECK(zf_tajweed_model_open(g_data, &o, &err) == NULL && err != NULL);

  /* no options at all: the defaults, which ask for the engine, and the engine needs a context */
  err = NULL;
  CHECK(zf_tajweed_model_open(g_data, NULL, &err) == NULL && err != NULL && strstr(err, "context") != NULL);
  /* the error pointer is optional */
  CHECK(zf_tajweed_model_open(g_data, NULL, NULL) == NULL);

  o = no_engine();
  err = NULL;
  CHECK(zf_tajweed_model_open(NULL, &o, &err) == NULL && err != NULL);
  err = NULL;
  CHECK(zf_tajweed_model_open("no/such/folder", &o, &err) == NULL && err != NULL);
}

static void test_context(void) {
  ZfTajweedOpenOptions o = no_engine();
  const char *err = NULL;
  /* without the engine a context is a label: none, or any folder name */
  ZfTajweedModel *m = zf_tajweed_model_open(g_data, &o, &err);
  CHECK(m != NULL);
  if (m) CHECK(zf_tajweed_model_context(m) == NULL);
  zf_tajweed_model_close(m);
  CHECK(zf_tajweed_model_context(NULL) == NULL);
  char name[] = "c24_l256";
  o.context = name;
  m = zf_tajweed_model_open(g_data, &o, &err);
  CHECK(m != NULL);
  name[0] = 'x'; /* the caller's string is not kept */
  if (m) CHECK(!strcmp(zf_tajweed_model_context(m), "c24_l256"));
  zf_tajweed_model_close(m);

  /* never a path */
  static const char *const bad[] = {"", ".", "..", "../c16_l64", "c16_l64/..", "a/b", "a\\b", ".hidden", "c16 l64",
                                    "c16_l64\n", "C:c16",
                                    "x123456789012345678901234567890123456789012345678901234567890123"};
  for (size_t i = 0; i < sizeof bad / sizeof bad[0]; ++i) {
    o.context = bad[i];
    for (int engine = 0; engine < 2; ++engine) {
      o.load_engine = engine;
      err = NULL;
      CHECK(zf_tajweed_model_open(g_data, &o, &err) == NULL && err != NULL && strstr(err, "context") != NULL);
    }
  }
  /* 63 bytes is the longest name */
  o.load_engine = 0;
  o.context = "x12345678901234567890123456789012345678901234567890123456789012";
  m = zf_tajweed_model_open(g_data, &o, &err);
  CHECK(m != NULL);
  zf_tajweed_model_close(m);

  /* with the engine: a context the folder does not hold is refused (here: no build has its graph) */
  o.load_engine = 1;
  o.context = "c99_l1";
  err = NULL;
  CHECK(zf_tajweed_model_open(g_data, &o, &err) == NULL && err != NULL);
  o.context = "c16_l64";
  err = NULL;
  CHECK(zf_tajweed_model_open(g_data, &o, &err) == NULL && err != NULL);
}

#ifdef TJ_TEST_ENGINE
/* A context folder holding only a graph text with the chunk length in its metadata. */
static void context_folder(const char *model, const char *context, const char *zfg) {
  char dir[1100], p[1200];
  tj_test_path(dir, sizeof dir, model, context);
  tj_test_mkdir(dir);
  CHECK(tj_test_write(tj_test_path(p, sizeof p, dir, "model_engine2.onnx.zfg"), zfg, strlen(zfg)) == 0);
}

static void chunk_ms_is(const char *model, const char *context, int ms) {
  ZfTajweedOpenOptions o = zf_tajweed_open_default_options();
  const char *err = NULL;
  o.context = context;
  ZfTajweedModel *m = zf_tajweed_model_open(model, &o, &err);
  if (!m) fprintf(stderr, "model_open %s: %s\n", context, err ? err : "?");
  CHECK(m != NULL);
  if (!m) return;
  CHECK(zf_tajweed_model_chunk_ms(m) == ms);
  CHECK(!strcmp(zf_tajweed_model_context(m), context));
  CHECK(zf_tajweed_model_calibration(m, NULL) == NULL);
  names_are(m);
  zf_tajweed_model_close(m);
}

static void test_engine_open(void) {
  /* tokens.txt and the contexts: no calibration.json, no expected_tj3.zfx */
  const char *model = folder("engine_open", NULL); /* valid until the next folder() */
  context_folder(model, "c8_l64", "meta decode_chunk_len 16\n");
  context_folder(model, "c16_l64", "zfg 1\nmeta decode_chunk_len 32\nnode x\n");
  context_folder(model, "c24_l72", "meta other 7\nmeta decode_chunk_len 48\n");
  context_folder(model, "nometa", "zfg 1\nnode x\nmeta decode_chunk_len 32\n");
  chunk_ms_is(model, "c8_l64", 160);
  chunk_ms_is(model, "c16_l64", 320);
  chunk_ms_is(model, "c24_l72", 480);
  /* a graph without the chunk length before its first node, and a context without a folder */
  ZfTajweedOpenOptions o = zf_tajweed_open_default_options();
  const char *err = NULL;
  o.context = "nometa";
  CHECK(zf_tajweed_model_open(model, &o, &err) == NULL && err != NULL);
  o.context = "c24_l256";
  err = NULL;
  CHECK(zf_tajweed_model_open(model, &o, &err) == NULL && err != NULL);
}
#endif

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: %s <tests/data/model> <scratch dir>\n", argv[0]);
    return 2;
  }
  g_data = argv[1];
  g_tmp = argv[2];
  tj_test_mkdir(g_tmp);
  test_tokens();
  test_calibration();
  test_options();
  test_context();
#ifdef TJ_TEST_ENGINE
  test_engine_open();
#endif
  return tj_test_done("model");
}
