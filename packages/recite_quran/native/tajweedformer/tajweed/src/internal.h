/* Internal declarations of the tajweed library (zf_tajweed.h): not part of the public interface. */
#ifndef ZF_TAJWEED_INTERNAL_H
#define ZF_TAJWEED_INTERNAL_H

#include <stddef.h>

#include "zf_tajweed.h"

#ifndef ZF_TAJWEED_VERSION
#define ZF_TAJWEED_VERSION "3.0.0"
#endif

/* ---- the model (model.c) ------------------------------------------------------------------------- */
struct ZfTajweedModel {
  char *context;              /* the context it was opened with, NULL when none was given */
  char *token_names[ZF_TAJWEED_VOCAB];
  unsigned char *calibration; /* calibration.json's bytes as shipped (a NUL after them), NULL without */
  size_t calibration_size;
  /* the exact engine (engine glue): NULL without */
  void *engine;
  int chunk_ms;
  ZfTajweedOpenOptions options;
};

/* Engine glue: engine_stub.c fails the open; engine.c (builds that have the engine) replaces it. */
int zf_tajweed__engine_open(ZfTajweedModel *m, const char *context_dir, const ZfTajweedOpenOptions *o,
                            const char **error);
void zf_tajweed__engine_close(ZfTajweedModel *m);

/* Reads a whole file. Returns a malloc'd buffer (NUL-terminated past size) or NULL. */
unsigned char *zf_tj_read_file(const char *path, size_t *size);

#endif /* ZF_TAJWEED_INTERNAL_H */
