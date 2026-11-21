/* The model folder: tokens.txt, calibration.json's bytes when the folder has one (handed over as
 * data, never parsed) and, with load_engine, the context's engine files (engine glue). The reference
 * data (expected_tj3.zfx) is not read here: reference.c is a reader of its own. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "internal.h"

/* the same rule as zf/stream.h's ZF_NO_PIN_DEFAULT (this file builds without the engine's headers) */
/* The pinning default by platform: phones pin (the pool was tuned for big.LITTLE cores, one stream per
 * app), every other build does not (desktop, server, WebAssembly: a pinned caller thread shares one core
 * with everything else the machine runs; on a busy Windows host a pinned stream ran 18 ms a chunk
 * unpinned and 102 to 631 ms pinned, and the server tier's 8 streams 20.4x against 3.1x real time).
 * Pinning never changes a bit, only timing. */
#if defined(__ANDROID__)
#define ZF_TJ_NO_PIN_DEFAULT 0
#elif defined(__APPLE__)
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#define ZF_TJ_NO_PIN_DEFAULT 0 /* iOS, iPadOS (and the other Apple device OSes) */
#else
#define ZF_TJ_NO_PIN_DEFAULT 1 /* macOS */
#endif
#else
#define ZF_TJ_NO_PIN_DEFAULT 1 /* Windows, Linux, WebAssembly */
#endif

const char *zf_tajweed_version(void) { return ZF_TAJWEED_VERSION; }
int zf_tajweed_api_version(void) { return ZF_TAJWEED_API_VERSION; }

ZfTajweedOpenOptions zf_tajweed_open_default_options(void) {
  ZfTajweedOpenOptions o;
  memset(&o, 0, sizeof o);
  o.struct_size = sizeof o;
  o.context = NULL;
  o.load_engine = 1;
  o.threads = 0;
  o.sample_rate = 0;
  o.batch = 1;
  o.no_pin = ZF_TJ_NO_PIN_DEFAULT;
  return o;
}

unsigned char *zf_tj_read_file(const char *path, size_t *size) {
  FILE *f = fopen(path, "rb");
  if (!f) return NULL;
  unsigned char *buf = NULL;
  size_t n = 0, cap = 0;
  for (;;) {
    if (cap - n < 65536) {
      size_t nc = cap ? cap * 2 : 65536;
      unsigned char *nb = (unsigned char *)realloc(buf, nc + 1);
      if (!nb) {
        free(buf);
        fclose(f);
        return NULL;
      }
      buf = nb;
      cap = nc;
    }
    size_t r = fread(buf + n, 1, cap - n, f);
    n += r;
    if (r == 0) break;
  }
  int err = ferror(f);
  fclose(f);
  if (err) {
    free(buf);
    return NULL;
  }
  buf[n] = 0;
  *size = n;
  return buf;
}

static char *join(const char *dir, const char *name) {
  size_t a = strlen(dir), b = strlen(name);
  char *p = (char *)malloc(a + b + 2);
  if (!p) return NULL;
  memcpy(p, dir, a);
  size_t k = a;
  if (a && dir[a - 1] != '/' && dir[a - 1] != '\\') p[k++] = '/';
  memcpy(p + k, name, b + 1);
  return p;
}

static unsigned char *read_in(const char *dir, const char *name, size_t *size) {
  char *p = join(dir, name);
  if (!p) return NULL;
  unsigned char *d = zf_tj_read_file(p, size);
  free(p);
  return d;
}

/* A context is the name of a folder of the model, never a path: letters, digits, '_', '-' and '.',
 * not starting with a dot, at most 63 bytes. */
static int context_ok(const char *c) {
  const size_t n = strlen(c);
  if (n == 0 || n > 63 || c[0] == '.') return 0;
  for (size_t i = 0; i < n; ++i) {
    const char ch = c[i];
    if (!((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_' ||
          ch == '-' || ch == '.'))
      return 0;
  }
  return 1;
}

/* tokens.txt: "<name> <id>" per line, ids 0 .. 37 in order */
static int parse_tokens(ZfTajweedModel *m, const unsigned char *d, size_t n, const char **error) {
  size_t i = 0;
  int count = 0;
  while (i < n) {
    size_t e = i;
    while (e < n && d[e] != '\n') e++;
    size_t le = e;
    if (le > i && d[le - 1] == '\r') le--;
    if (le > i) {
      size_t sp = le;
      while (sp > i && d[sp - 1] != ' ' && d[sp - 1] != '\t') sp--;
      if (sp == i || count >= ZF_TAJWEED_VOCAB) goto bad;
      long id = 0;
      for (size_t k = sp; k < le; ++k) {
        if (d[k] < '0' || d[k] > '9') goto bad;
        id = id * 10 + (d[k] - '0');
        if (id > 1000) goto bad;
      }
      if (id != count || sp == le) goto bad;
      size_t ne = sp;
      while (ne > i && (d[ne - 1] == ' ' || d[ne - 1] == '\t')) ne--;
      if (ne == i) goto bad;
      char *s = (char *)malloc(ne - i + 1);
      if (!s) {
        *error = "out of memory";
        return -1;
      }
      memcpy(s, d + i, ne - i);
      s[ne - i] = 0;
      m->token_names[count++] = s;
    }
    i = e + 1;
  }
  if (count != ZF_TAJWEED_VOCAB) goto bad;
  return 0;
bad:
  *error = "tokens.txt: not 38 lines of \"<token> <id>\" with ids 0 .. 37 in order";
  return -1;
}

void zf_tajweed_model_close(ZfTajweedModel *m) {
  if (!m) return;
  if (m->engine) zf_tajweed__engine_close(m);
  for (int i = 0; i < ZF_TAJWEED_VOCAB; ++i) free(m->token_names[i]);
  free(m->calibration);
  free(m->context);
  free(m);
}

ZfTajweedModel *zf_tajweed_model_open(const char *model_dir, const ZfTajweedOpenOptions *options,
                                      const char **error) {
  const char *dummy;
  if (!error) error = &dummy;
  ZfTajweedOpenOptions o = zf_tajweed_open_default_options();
  if (options) {
    if (options->struct_size < offsetof(ZfTajweedOpenOptions, batch) + sizeof(int)) {
      *error = "options: struct_size too small";
      return NULL;
    }
    /* only as much as the caller's header had (API 3 appended no_pin); the rest keep their defaults */
    size_t n = options->struct_size < sizeof o ? options->struct_size : sizeof o;
    memcpy(&o, options, n);
    o.struct_size = sizeof o;
  }
  if (!model_dir) {
    *error = "model_dir is NULL";
    return NULL;
  }
  if (o.context && !context_ok(o.context)) {
    *error = "options.context is not the name of a context folder";
    return NULL;
  }
  if (o.load_engine && !o.context) {
    *error = "options.context is required with load_engine (the manifest's default_context names the default)";
    return NULL;
  }
  ZfTajweedModel *m = (ZfTajweedModel *)calloc(1, sizeof *m);
  if (!m) {
    *error = "out of memory";
    return NULL;
  }
  m->options = o;
  m->options.context = NULL; /* the caller's string is not kept */
  if (o.context) {
    const size_t len = strlen(o.context);
    m->context = (char *)malloc(len + 1);
    if (!m->context) {
      *error = "out of memory";
      goto fail;
    }
    memcpy(m->context, o.context, len + 1);
  }
  /* tokens */
  size_t n;
  unsigned char *d = read_in(model_dir, "tokens.txt", &n);
  if (!d) {
    *error = "cannot read tokens.txt";
    goto fail;
  }
  int rc = parse_tokens(m, d, n, error);
  free(d);
  if (rc) goto fail;
  /* calibration.json: its bytes for zf_tajweed_model_calibration when the folder has one. Not parsed,
   * not required. */
  m->calibration = read_in(model_dir, "calibration.json", &m->calibration_size);
  if (!m->calibration) m->calibration_size = 0;
  if (o.load_engine) {
    char *cdir = join(model_dir, m->context);
    if (!cdir) {
      *error = "out of memory";
      goto fail;
    }
    rc = zf_tajweed__engine_open(m, cdir, &o, error);
    free(cdir);
    if (rc) goto fail;
  }
  return m;
fail:
  zf_tajweed_model_close(m);
  return NULL;
}

const char *zf_tajweed_model_context(const ZfTajweedModel *m) { return m ? m->context : NULL; }
int zf_tajweed_model_chunk_ms(const ZfTajweedModel *m) { return m && m->engine ? m->chunk_ms : 0; }
const char *zf_tajweed_token_name(const ZfTajweedModel *m, int id) {
  return m && id >= 0 && id < ZF_TAJWEED_VOCAB ? m->token_names[id] : NULL;
}

const void *zf_tajweed_model_calibration(const ZfTajweedModel *m, size_t *size) {
  if (size) *size = m && m->calibration ? m->calibration_size : 0;
  return m ? m->calibration : NULL;
}
