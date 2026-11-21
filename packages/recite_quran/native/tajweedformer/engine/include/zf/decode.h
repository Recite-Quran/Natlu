#ifndef ZF_DECODE_H
#define ZF_DECODE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Greedy CTC over a stream, with a confidence for every phoneme it emits.
 *
 * The decoder is fed one chunk of log probabilities at a time and appends whatever phonemes that
 * chunk completed. It holds only the previous frame's argmax between calls, which is what CTC's
 * collapse rule needs, so it adds no latency of its own: a phoneme is reported in the same call as
 * the frame that produced it.
 *
 * That last point is a deliberate choice about what a confidence means here. A phoneme usually
 * occupies a run of consecutive frames, and the most informative number would be the peak posterior
 * over the whole run. But a run is only known to have ended when a different frame arrives, and a
 * run can cross a chunk boundary, so reporting the peak would mean holding phonemes back by up to a
 * run's length. Everything below is taken from the single frame that emitted the phoneme and is
 * therefore free. `zf_decoder_refine` is there for a caller that would rather have the peak and can
 * accept the delay; nothing requires it. */

typedef struct {
  int token;       /* the phoneme's id in the model's vocabulary */
  int frame;       /* the frame that emitted it, counted from the start of the stream */
  float prob;      /* its posterior at that frame, in [0, 1] */
  float margin;    /* its posterior minus the next most likely phoneme's at the same frame */
  float blank;     /* the blank's posterior at that frame */
  int run;         /* frames this phoneme has held the argmax so far, at least 1 */
  int runner_up;   /* the next most likely id at the emitting frame (may be the blank) */
  /* The run's peak: the posterior at the run's most confident frame, and the margin over that
   * frame's runner-up. A peak margin is the confidence two engines agree on; the first frame's
   * margin moves with where a near-tie falls. Final only when `complete` is 1; otherwise they are
   * the emitting frame's values. */
  float peak_prob;
  float peak_margin;
  int end_frame;   /* the run's last frame so far */
  int complete;    /* 1 when the run had ended before the phoneme was handed over */
} ZfToken;

typedef struct ZfDecoder ZfDecoder;

/* `blank` is the vocabulary index CTC collapses to nothing; 250 of 251 for this model. */
ZfDecoder *zf_decoder_create(int vocab, int blank);
void zf_decoder_destroy(ZfDecoder *d);

/* Forget the stream. The next chunk is treated as its first. */
void zf_decoder_reset(ZfDecoder *d);

/* Feed one chunk's log probabilities, row major [frames, vocab], and append what it completed.
 *
 * Returns the number of phonemes written to `out`, which is never more than `frames` and never
 * more than `max_out`; a chunk that emits nothing returns zero. The log probabilities are expected
 * to be a log softmax over the vocabulary, which is what the graph's log_probs output is, and the
 * posteriors reported are their exponentials. */
int zf_decoder_push(ZfDecoder *d, const float *log_probs, int frames, ZfToken *out, int max_out);

/* Complete runs: hold each phoneme until its run ends, so its peak, run and end frame are final
 * (`complete` 1). It costs latency: a phoneme leaves when the next frame is different, which is one
 * chunk later when its run reaches the end of a chunk. Off by default. */
void zf_decoder_set_complete_runs(ZfDecoder *d, int on);

/* The end of the stream: hands over a phoneme still held for its run. Returns 0 or 1. */
int zf_decoder_flush(ZfDecoder *d, ZfToken *out, int max_out);

/* Where a stream stands: frames consumed and the last frame's argmax (the blank at the start). A
 * stream handed over from another engine continues from here, so CTC's collapse rule and the
 * tokens' frame numbers carry across. */
void zf_decoder_position(const ZfDecoder *d, long long *frames, int *prev);
void zf_decoder_set_position(ZfDecoder *d, long long frames, int prev);

/* How many frames the stream has consumed, which is what a token's `frame` is counted against. */
long long zf_decoder_frames(const ZfDecoder *d);

/* The run length and peak posterior of the phoneme most recently emitted, which keep growing while
 * its run continues. A caller that wants a peak-over-run confidence calls this after each push and
 * updates its own last token; a caller that wants no delay ignores it. Returns 0 if nothing has
 * been emitted yet. */
int zf_decoder_refine(const ZfDecoder *d, int *run_out, float *peak_prob_out);

#ifdef __cplusplus
}
#endif

#endif
