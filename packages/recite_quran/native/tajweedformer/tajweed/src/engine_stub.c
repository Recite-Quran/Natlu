/* The tajweed library without the exact engine: the tokens, the calibration bytes, the decoded layer
 * and the reference data work for heads from any source; streams do not. engine.c replaces this file
 * in builds that have the engine. */
#include <stddef.h>

#include "internal.h"

static const char NO_ENGINE[] = "this build of the tajweed library has no engine (open with load_engine = 0)";

int zf_tajweed__engine_open(ZfTajweedModel *m, const char *context_dir, const ZfTajweedOpenOptions *o,
                            const char **error) {
  (void)m;
  (void)context_dir;
  (void)o;
  if (error) *error = NO_ENGINE;
  return -1;
}

void zf_tajweed__engine_close(ZfTajweedModel *m) {
  if (m) m->engine = NULL;
}

ZfTajweedStream *zf_tajweed_stream_create(ZfTajweedModel *m, const char **error) {
  (void)m;
  if (error) *error = NO_ENGINE;
  return NULL;
}
void zf_tajweed_stream_destroy(ZfTajweedStream *s) { (void)s; }
void zf_tajweed_stream_set_callback(ZfTajweedStream *s, ZfTajweedChunkCallback cb, void *user) {
  (void)s;
  (void)cb;
  (void)user;
}
void zf_tajweed_stream_reset(ZfTajweedStream *s) { (void)s; }
int zf_tajweed_stream_push_audio(ZfTajweedStream *s, const float *samples, int n) {
  (void)s;
  (void)samples;
  (void)n;
  return -1;
}
int zf_tajweed_stream_finish(ZfTajweedStream *s) {
  (void)s;
  return -1;
}
int zf_tajweed_stream_heads(const ZfTajweedStream *s, ZfTajweedHeads *out) {
  (void)s;
  (void)out;
  return -1;
}
int zf_tajweed_stream_greedy(const ZfTajweedStream *s, int *ids, int max) {
  (void)s;
  (void)ids;
  (void)max;
  return -1;
}
const char *zf_tajweed_stream_last_error(const ZfTajweedStream *s) {
  (void)s;
  return NO_ENGINE;
}
int zf_tajweed_stream_set_heads(ZfTajweedStream *s, unsigned heads) {
  (void)s;
  (void)heads;
  return -1;
}
unsigned zf_tajweed_stream_get_heads(const ZfTajweedStream *s) {
  (void)s;
  return 0;
}
int zf_tajweed_stream_top2(const ZfTajweedStream *s, const ZfTajweedTop2 **out) {
  (void)s;
  if (out) *out = NULL;
  return -1;
}
int zf_tajweed_stream_topk(const ZfTajweedStream *s, unsigned head, int k, int *ids, float *values_out,
                           float *margins, int max_frames) {
  (void)s, (void)head, (void)k, (void)ids, (void)values_out, (void)margins, (void)max_frames;
  return -1;
}
