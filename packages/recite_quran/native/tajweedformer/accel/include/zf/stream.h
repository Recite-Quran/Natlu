/* A stream: feature frames in as they arrive, phonemes out as soon as a chunk completes.
 *
 * This is the library entry point the harnesses stand in for. It owns the session, the graph's state
 * between chunks, the window of pending frames and the CTC decoder, and it schedules the front end's
 * prefetch: when the pending window lacks only its last `lead` frames, the front end runs on what
 * has arrived, so the chunk that follows finishes it. Measured on an iPhone 15 Pro Max at a live
 * stream's cadence, that burst 10 ms (one frame) before the window completes takes a chunk from
 * about 17 to 13 ms; spread thinly it helps nothing (see bench/accel/zf_run.c, ZF_PF_LATE_MS).
 *
 * Every number the stream produces is bit-identical to the harnesses' on the same features: it runs
 * the same graph, the same kernels, and the prefetch changes no bit.
 *
 * Features are kaldi fbank, 80 bins per 10 ms frame (povey window, dither 0, snip_edges false,
 * high_freq -400). Not thread-safe: one stream, one caller thread. One LIVE stream at a time per
 * process: the engine's operators keep process-wide state (the layer caches' restart list, the
 * prefetch front end, the weight map), so a second stream created before the first is destroyed
 * shares it. Streams in sequence are unlimited: destroy then create gives the same bits as a fresh
 * process, and zf_stream_reset gives the same bits as both. */
#ifndef ZF_STREAM_H
#define ZF_STREAM_H

#include <stddef.h>
#include <stdint.h>

#include "zf/decode.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ZfStream ZfStream;

/* Called after every chunk with its log probabilities, [frames, vocab] row major, valid only during
 * the call. For a caller that wants more than the greedy phonemes (scores, alignment, its own
 * confidence), however many chunks one push completes. */
typedef void (*ZfChunkCallback)(void *user, const float *log_probs, int frames, int vocab);

/* What the chunk's 16 kHz audio looked like (the samples after the engine's resampler, the chunk's
 * advance x 160 of them). All but `bandwidth_hz` are zero, and `has_samples` is 0, when the chunk
 * came from frames pushed with zf_stream_push. */
typedef struct {
  int has_samples;
  float rms, peak, dc;      /* full scale is 1 */
  int clipped;              /* samples at or above 0.99 of full scale */
  int zero_runs;            /* runs of at least 16 exact zeros (1 ms): dropouts, gaps, the flush */
  int zero_samples;         /* the samples in those runs */
  float noise_floor;        /* running: the quietest 10 ms RMS so far, allowed to rise 3 dB a second */
  float bandwidth_hz;       /* from the chunk's fbank frames: the upper edge of the highest mel bin
                               whose mean log energy is within 50 dB of the strongest bin's */
} ZfCaptureStats;

/* One chunk's evidence, beyond the log-probs: what the scoring engine reads (the phoneme engine's
 * calibration tables are built on exactly these bits). Every pointer is valid only during the call
 * and is NULL, with its size 0, when the graph does not carry that tap (tools/zftaps.py promotes
 * them). Rows are frames; stack 0 runs at 50 frames a second, so it has twice the log-probs' frames,
 * everything else at 25. */
typedef struct {
  size_t struct_size;        /* sizeof(ZfEvidence) as the engine was built: fields beyond a
                                caller's own header are ones it does not read */
  long long chunk;           /* 0 for the first chunk after a reset */
  int frames, vocab;
  const float *log_probs;    /* [frames, vocab]: the bits on_chunk sees */
  const float *logit_lse;    /* [frames]: logit - log_prob of class 0, the log-sum-exp the softmax
                                divides out (the logit energy) */
  const float *enc;          /* [frames, enc_dim]: the CTC head's input (512) */
  int enc_dim;
  const float *stack0;       /* [stack0_frames, stack0_dim]: stack 0's output (2 x frames, 192) */
  int stack0_frames, stack0_dim;
  const float *stack1;       /* [frames, stack1_dim]: stack 1's output before upsampling (256) */
  int stack1_dim;
  const float *samples;      /* [n_samples]: the chunk's advance x 160 samples at 16 kHz (the audio
                                its log-prob frames stand for); NULL when frames were pushed */
  int n_samples;
  ZfCaptureStats capture;
} ZfEvidence;

/* Called after every chunk, after on_chunk, with the same frames: batched streams (batch > 1) call
 * it chunk by chunk in order when the batch runs. Opt-in: a stream without one keeps no samples,
 * computes no statistics and copies nothing. */
typedef void (*ZfEvidenceCallback)(void *user, const ZfEvidence *evidence);

typedef struct {
  /* sizeof(ZfStreamOptions) as the caller was compiled: zf_stream_default_options sets it, and the
   * engine reads only the fields a caller built against an older, shorter header knows about. */
  size_t struct_size;
  ZfChunkCallback on_chunk; /* optional */
  void *user;               /* passed to on_chunk */
  int threads;       /* engine threads; 0 means the fast cores: on Android the phone's fast cores from
                        its topology (sysfs, at most 4), whatever cpuset the app is in when the stream
                        is made (the team then follows the cpuset); elsewhere the fast cores the
                        process may use. A live stream on an iPhone does best with every core (6):
                        cold cores make the efficiency cores worth having. */
  int prefetch_lead; /* frames before the window completes at which the front end prefetches;
                        1 (10 ms) measured best; 0 disables the prefetch */
  int complete_runs; /* 1: hold each phoneme until its run ends, so its peak confidence is final
                        (see zf_decoder_set_complete_runs); 0, the default, hands it over at once */
  int sample_rate;   /* the rate zf_stream_push_audio's samples come at: 0 or 16000 as they are, or
                        8000, 11025, 22050, 24000, 32000, 44100, 48000, converted to 16 kHz by the
                        engine's own resampler (zf/resample.h), the same bits on every device */
  int batch;         /* chunks run together, layer by layer (0 or 1: each chunk as it completes).
                        With B > 1 a node's weights are read once for B chunks, which is much
                        faster where the weights do not fit the cache, at the price of B - 1 chunks
                        of latency: for decoding files or buffered audio. Output is the same bits.
                        Queued chunks run when B are ready, at zf_stream_finish_audio or
                        zf_stream_finish, at zf_stream_flush, or before a state is exported or
                        imported. */
  /* appended after batch: a caller built against an older header gets the defaults */
  ZfEvidenceCallback on_evidence; /* optional; passed `user` like on_chunk */
  int chunk_ms;      /* the step: 160, 320 or 480 ms, from the graph for that length next to
                        `model_path` (MODEL.c160.onnx for MODEL.onnx; tools/zfchunk.py); 0 is the
                        model's own. Anything else fails zf_stream_create. A new length is a new
                        stream. */
  /* appended after chunk_ms */
  int no_pin;        /* 0: the stream's thread and its pool's workers are pinned one to a core, best
                        for one stream on a phone. 1: no pinning, for desktops and servers (pinned,
                        every stream's calling thread shared the same fastest core). The default
                        (zf_stream_default_options, and a caller whose header predates the field)
                        depends on the platform: 0 on Android and iOS, 1 on Windows, Linux, macOS
                        and WebAssembly (ZF_NO_PIN_DEFAULT). Setting it overrides either way.
                        Changes timing only, never a bit. */
} ZfStreamOptions;
/* The header declares `batch` and zf_stream_flush */
#define ZF_STREAM_HAS_BATCH 1
/* The header declares ZfEvidence, `on_evidence`, `chunk_ms` and zf_stream_model_info_sized */
#define ZF_STREAM_HAS_EVIDENCE 1
/* The header declares `no_pin` */
#define ZF_STREAM_HAS_NO_PIN 1
/* The pinning default by platform: phones pin (the pool was tuned for big.LITTLE cores, one stream per
 * app), every other build does not (desktop, server, WebAssembly: a pinned caller thread shares one core
 * with everything else the machine runs; on a busy Windows host a pinned stream ran 18 ms a chunk
 * unpinned and 102 to 631 ms pinned, and the server tier's 8 streams 20.4x against 3.1x real time).
 * Pinning never changes a bit, only timing. */
#if defined(__ANDROID__)
#define ZF_NO_PIN_DEFAULT 0
#elif defined(__APPLE__)
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#define ZF_NO_PIN_DEFAULT 0 /* iOS, iPadOS (and the other Apple device OSes) */
#else
#define ZF_NO_PIN_DEFAULT 1 /* macOS */
#endif
#else
#define ZF_NO_PIN_DEFAULT 1 /* Windows, Linux, WebAssembly */
#endif

/* The defaults above: no callbacks, threads 0, prefetch_lead 1, complete_runs 0, sample_rate 0,
 * batch 1, chunk_ms 0, no_pin ZF_NO_PIN_DEFAULT (0 on Android and iOS, 1 elsewhere). */
ZfStreamOptions zf_stream_default_options(void);

/* `model_path` is the engine graph (model_engine2.onnx); its .zfg, .zfg.bin and the .zfw weight
 * files it names are read from the same directory. On failure returns NULL and, if `error` is not
 * NULL, a static message. */
ZfStream *zf_stream_create(const char *model_path, const ZfStreamOptions *options,
                           const char **error);
/* The same, with the engine's weights taken from a CoreML model, so an app ships one set of
 * weights for both engines: `mlmodelc` is the compiled model directory (weights/weight.bin holds the
 * fp16 weights) and `sidecar` the engine.zfs made for it. The engine's files are rebuilt in memory
 * and each is checked against its SHA-256; a mismatch fails the call, it is never used. */
ZfStream *zf_stream_create_from_coreml(const char *mlmodelc, const char *sidecar,
                                       const ZfStreamOptions *options, const char **error);
void zf_stream_destroy(ZfStream *s);

/* Start a new utterance: every cache, the pending frames, the phoneme queue and the decoder go back
 * to their start. Queued phonemes not yet read are discarded; read them first to keep them. */
void zf_stream_reset(ZfStream *s);

/* Push `n` frames ([n, 80] float32). Runs every chunk they complete; the phonemes those chunks emit
 * join the stream's queue, and as many as fit are moved into `out` (at most `max_out`; `out` may be
 * NULL to leave them all queued). Returns how many were written to `out`, or -1 on an engine error.
 * No phoneme is ever dropped: whatever did not fit stays queued for the next push, the next
 * zf_stream_read, or zf_stream_pending to see. A caller that pushes audio as it arrives gets
 * phonemes with one chunk of latency. */
int zf_stream_push(ZfStream *s, const float *frames, int n, ZfToken *out, int max_out);

/* Phonemes decoded and not yet handed over. */
int zf_stream_pending(const ZfStream *s);

/* Move up to `max_out` queued phonemes into `out`, oldest first. Returns how many, or -1. */
int zf_stream_read(ZfStream *s, ZfToken *out, int max_out);

/* Push `n` audio samples (at the options' sample_rate, 16 kHz by default; float in [-1, 1], i.e.
 * int16 / 32768), resampled to 16 kHz first when the rate is another: the stream computes the
 * features itself (zf/fbank.h, the same bits on every device) and pushes them. Phonemes are queued
 * and handed over exactly as for zf_stream_push. Returns phonemes written to `out`, or -1. */
int zf_stream_push_audio(ZfStream *s, const float *samples, int n, ZfToken *out, int max_out);

/* The end of an utterance pushed as audio: the flush the models are decoded with (16,800 zero
 * samples, then the fbank's last frames), and every chunk that completes. Frames short of a whole
 * window are dropped, as the reference decoders do. Call zf_stream_reset before the next one. */
int zf_stream_finish_audio(ZfStream *s, ZfToken *out, int max_out);

/* The end of an utterance pushed as frames: hands over a phoneme still held for its run (see
 * `complete_runs`). Frames short of a whole window are dropped. Call zf_stream_reset before the
 * next utterance. Returns phonemes written to `out`, or -1. */
int zf_stream_finish(ZfStream *s, ZfToken *out, int max_out);

/* A stream's carried state, for handing it from one engine to another (the Neural Engine's CoreML
 * model to this one, when the Neural Engine misbehaves mid-utterance), in the ONNX model's own names
 * and layouts: cached_key_i [left, 1, heads*32], cached_nonlin_attn_i [1, 1, left, na],
 * cached_val1_i and cached_val2_i [left, 1, heads*12], cached_conv1_i and cached_conv2_i
 * [1, dim, taps-1] for every layer i; the graph's own states (embed_states, processed_lens); and
 * zf_position, int64 [3]: chunks run, frames decoded, the last frame's argmax. Float32 unless the
 * info says int64. States are listed in a fixed order, 0 to zf_stream_state_count - 1.
 *
 * To continue a stream elsewhere: export every state after a chunk, then on the other stream
 * zf_stream_reset, import every state, and push frames from the next window's start (the chunk's
 * advance after the last window's start). Returns 0, or -1 for an unknown name or a wrong size. */
int zf_stream_state_count(ZfStream *s);
int zf_stream_state_info(ZfStream *s, int index, const char **name, int64_t dims[8], int *rank,
                         int *is_int64);
int zf_stream_export_state(ZfStream *s, const char *name, void *out, size_t bytes);
int zf_stream_import_state(ZfStream *s, const char *name, const void *in, size_t bytes);

/* What went wrong, for the calls that return -1. The code stays until the next failure or reset. */
typedef enum {
  ZF_OK = 0,
  ZF_ERR_ARGUMENT = 1, /* a NULL pointer, a negative count, an unknown state name, a wrong size */
  ZF_ERR_MEMORY = 2,
  ZF_ERR_ENGINE = 3,   /* a chunk failed to run */
} ZfStatus;
ZfStatus zf_stream_last_error(const ZfStream *s, const char **message);

/* What a stream is running. `weights_sha256` is the hex SHA-256 of the layers' weight file as the
 * engine read it (for a stream made from a CoreML model, the checksum its sidecar verified). */
typedef struct {
  int vocab, blank;       /* 251 and 250 for v3.1 */
  int window, advance;    /* frames a chunk sees and advances by: 61 and 48 */
  int layers;             /* encoder layers: 16 */
  int left_context;       /* full-rate frames the attention remembers: 256 */
  int sample_rate;        /* what zf_stream_push_audio takes */
  char model_type[32];    /* the graph's metadata: zipformer2 */
  char version[16];
  char weights_sha256[65];
  /* appended: filled by zf_stream_model_info_sized only */
  int backend;            /* ZF_BACKEND_EXACT_CPU for this engine */
  int chunk_ms;           /* the step this stream runs: advance x 10 ms */
} ZfModelInfo;
/* Where the arithmetic runs: the exact engine, or an approximate path measured against it */
typedef enum { ZF_BACKEND_UNKNOWN = 0, ZF_BACKEND_EXACT_CPU = 1, ZF_BACKEND_ANE = 2, ZF_BACKEND_NPU = 3 } ZfBackend;
/* Fills the fields up to weights_sha256, which every caller's header has. */
int zf_stream_model_info(ZfStream *s, ZfModelInfo *out);
/* Fills as much of `out` as `size` covers: sizeof(ZfModelInfo) as the caller was compiled. */
int zf_stream_model_info_sized(ZfStream *s, ZfModelInfo *out, size_t size);

/* Run any chunks queued for a batch (ZfStreamOptions.batch > 1) now; returns the phonemes appended,
 * or -1. A no-op when nothing is queued. zf_stream_finish_audio flushes itself. */
int zf_stream_flush(ZfStream *s, ZfToken *out, int max_out);

/* Chunks run since the last reset. */
long long zf_stream_chunks(const ZfStream *s);

/* The window (frames per chunk) and advance (frames per step) the model declares: 61 and 48 for the
 * shipped v3.1, 480 ms of new audio a step. */
int zf_stream_window(const ZfStream *s);
int zf_stream_advance(const ZfStream *s);

/* The last chunk's log probabilities, [frames, vocab] row major, valid until the next push; for a
 * caller that wants more than the greedy phonemes. */
const float *zf_stream_last_log_probs(const ZfStream *s, int *frames, int *vocab);

/* The graph's other outputs, beyond log_probs and the carried states: V4's tajweed heads
 * (inter1_log_probs, attr_tafkheem, attr_ghunna, attr_qalqalah, attr_face, gem, timing_log_probs,
 * id_log_probs, boundary, conf, inter4_log_probs; README_heads.txt), none for v3.x. By default
 * every Run asks for all of them (zf_stream_select_outputs below narrows that).
 * zf_stream_last_output gives the last chunk's values of one by name, `rows` frames of `cols` values row major ([1, T, C] is T rows of C, [1, T] is T rows of 1), valid until
 * the next push and already filled when on_chunk is called; NULL for an unknown name or before the
 * first chunk. */
#define ZF_STREAM_HAS_OUTPUTS 1
/* The engine threads taking part in the stream's regions now (the calling thread and the active
 * workers; the team follows the process's cpuset, at most the threads asked for). Diagnostics. */
int zf_stream_threads_active(const ZfStream *s);

int zf_stream_output_count(const ZfStream *s);
const char *zf_stream_output_name(const ZfStream *s, int index);
const float *zf_stream_last_output(const ZfStream *s, const char *name, int *rows, int *cols);

/* Which of those outputs the next chunks compute. By default every one (the 1.x behaviour, and what
 * the conformance sets check). `names`, `n`: compute exactly these (n = 0: none of them, only
 * log_probs and the states); n < 0: every one again. The graph runner then skips each node that
 * feeds none of the asked-for outputs, so an output nobody asked for costs nothing and asking for
 * one costs exactly its own nodes; the outputs that are computed are the same bits either way.
 * zf_stream_last_output returns NULL for an output the last chunk did not compute. Returns 0, or -1
 * for an unknown name or while a batch has chunks queued (zf_stream_flush first). */
#define ZF_STREAM_HAS_SELECT_OUTPUTS 1
int zf_stream_select_outputs(ZfStream *s, const char *const *names, int n);
/* 1 when `name` is computed under the current selection. */
int zf_stream_output_selected(const ZfStream *s, const char *name);

#ifdef __cplusplus
}
#endif
#endif /* ZF_STREAM_H */
