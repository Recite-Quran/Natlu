/* zf_tajweed.h: TajweedFormer V4 in the exact engine, inference only. API version 4.
 *
 * One header for the SDKs (Swift, Kotlin through JNI, WebAssembly, C): open a model folder, stream
 * audio through the exact engine, and read what the network says: every head it has, the greedy
 * tokens, and the decoded layer (the best token of each frame, the runner-up, any depth of ranking).
 * Nothing here judges a recitation: there is no scorer, no settings and no verdict in this library.
 *
 *   ZfTajweedOpenOptions o = zf_tajweed_open_default_options();
 *   o.context = "c16_l64";                                                the model's context folder
 *   ZfTajweedModel *m = zf_tajweed_model_open("sdk/v4.0", &o, &err);
 *   ZfTajweedStream *s = zf_tajweed_stream_create(m, &err);
 *   zf_tajweed_stream_push_audio(s, samples, n);                          as audio arrives
 *   zf_tajweed_stream_finish(s);                                          end of the take
 *   ZfTajweedHeads h; zf_tajweed_stream_heads(s, &h);                     every head of the take
 *   int n_tokens = zf_tajweed_stream_greedy(s, ids, max);                 what the model heard
 *
 * The model folder (sdk/v4.0):
 *   tokens.txt                tj3, 38 entries, blank 0 (required)
 *   <context>/                one folder per shipped context (c8_l64, c16_l64, c24_l72, c24_l256):
 *                             model_engine2.onnx.zfg, model_engine2.onnx.zfg.bin, frames.zfw
 *   layers.zfw, frontend.zfw  the weights every context shares
 *   calibration.json          optional, data only: handed over byte for byte by
 *                             zf_tajweed_model_calibration, never parsed or applied here
 *   expected_tj3.zfx          optional, data only: the reference data (the expected units of each
 *                             ayah), read by zf_tajweed_reference_*, never by a model
 * A folder without calibration.json and without expected_tj3.zfx opens and runs.
 *
 * Exactness: the heads are the same bits, chunk by chunk, as ONNX Runtime's int8 reference on the
 * same graph (the engine's definition of exact).
 *
 * Threads: a model is immutable after open and may be shared by any number of threads. A stream
 * belongs to one thread at a time. Only one stream may be live per process (the engine's rule,
 * zf/stream.h). A reference is immutable after open and needs no stream.
 *
 * Every function that returns a pointer returns NULL on failure and, when `error` is not NULL,
 * sets it to a static message. Every count-returning function returns -1 on failure.
 *
 * Structs are only ever appended to under a new ZF_TAJWEED_API_VERSION, and the struct_size fields say
 * which version a caller was built against.
 *
 * API version 4 (SDK 3.0.0, breaking): the library is inference only.
 *   Removed: the scorer (zf_tajweed_score, every zf_tajweed_result_*, ZfTajweedResult, ZfTajweedSite,
 *     ZfTajweedMadd, ZfTajweedLetter, ZfTajweedWord, ZfTajweedSummary, ZfTajweedEdit); the settings
 *     (every zf_tajweed_config_*, ZfTajweedConfig, ZfTajweedEffective, ZfTajweedWordSettings); the name
 *     tables and their types (zf_tajweed_class_name / _class_from_name / _class_check, _check_name /
 *     _check_from_name, _preset_name / _preset_from_name, _madd_class_name, _word_preset_name /
 *     _word_preset_from_name; ZfTajweedClass, ZfTajweedCheck, ZfTajweedPreset, ZfTajweedStatus,
 *     ZfTajweedSource, ZfTajweedMaddClass, ZfTajweedWordPreset, ZF_TJ_CHECK_WORD); the expected table
 *     as part of the model (zf_tajweed_ayah_count, zf_tajweed_expected_tokens, zf_tajweed_expected_words).
 *   Removed with calibration.json's parsing, which was their source: zf_tajweed_model_id,
 *     zf_tajweed_model_context_at, zf_tajweed_model_default_context. The model id, the contexts and
 *     the default context are in the model folder's signed manifest, which the SDKs read.
 *   Renamed: ZF_TAJWEED_HEADS_SCORER is ZF_TAJWEED_HEADS_DEFAULT (the same five heads).
 *   Changed: zf_tajweed_model_open reads tokens.txt and the context's engine files only. It no longer
 *     reads expected_tj3.zfx at all, and calibration.json only to hand its bytes over. The context is
 *     no longer looked up in calibration.json: with load_engine it must be given (the SDK passes the
 *     one in force), and it must be a folder of the model.
 *   New: zf_tajweed_model_calibration (calibration.json's bytes, or NULL); the reference data reader
 *     zf_tajweed_reference_open / _open_memory / _close / _ayah_count / _units / _tokens_sha256, which
 *     replaces zf_tajweed_ayah_count and zf_tajweed_expected_tokens / _words and returns the same
 *     values for the same file.
 *   Unchanged, declaration for declaration and bit for bit: the open options, the heads, the stream,
 *     the head selection, zf_tajweed_head_info, zf_tajweed_top2, zf_tajweed_topk and their stream forms.
 * API versions 1 to 3 were SDK 1.x and 2.x. */
#ifndef ZF_TAJWEED_H
#define ZF_TAJWEED_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32) && defined(ZF_TAJWEED_BUILD_DLL)
#define ZF_TAJWEED_API __declspec(dllexport)
#elif defined(__GNUC__) || defined(__clang__)
#define ZF_TAJWEED_API __attribute__((visibility("default")))
#else
#define ZF_TAJWEED_API
#endif

#define ZF_TAJWEED_API_VERSION 4
/* The vocabulary: tj3, 38 tokens, blank 0 (tokens.txt). */
#define ZF_TAJWEED_VOCAB 38
#define ZF_TAJWEED_BLANK 0

/* "3.0.0"-style version of this library (the engine's), and ZF_TAJWEED_API_VERSION as built. */
ZF_TAJWEED_API const char *zf_tajweed_version(void);
ZF_TAJWEED_API int zf_tajweed_api_version(void);

/* ---------------------------------------------------------------------------------------------
 * The model
 * ------------------------------------------------------------------------------------------- */

typedef struct ZfTajweedModel ZfTajweedModel;

typedef struct {
  size_t struct_size;   /* sizeof(ZfTajweedOpenOptions) as the caller was built */
  const char *context;  /* the context to run: the name of its folder in the model ("c16_l64").
                           Required with load_engine; letters, digits, '_', '-' and '.' only */
  int load_engine;      /* 1 (default): the exact engine for this context, so streams can be made.
                           0: tokens.txt and calibration.json only, for heads that came from
                           elsewhere (the Neural Engine, an NPU, a server) */
  int threads;          /* engine threads; 0 = the fast cores */
  int sample_rate;      /* the rate audio is pushed at: 0 or 16000, or 8000 .. 48000 through the
                           engine's resampler */
  int batch;            /* engine chunks run together (stored audio); 0 or 1 for live audio */
  /* API 3, appended */
  int no_pin;           /* 0: the engine pins its threads one to a core (one stream on a phone).
                           1: no pinning (desktops, servers, several streams at once). The default
                           (zf_tajweed_open_default_options, and a caller whose header predates the
                           field) depends on the platform: 0 on Android and iOS, 1 on Windows,
                           Linux, macOS and WebAssembly. Setting it overrides either way. Timing
                           only, never a bit. */
} ZfTajweedOpenOptions;

/* context NULL, load_engine 1, threads 0, sample_rate 0, batch 1, no_pin by platform (0 on Android and
 * iOS, 1 on Windows, Linux, macOS and WebAssembly). */
ZF_TAJWEED_API ZfTajweedOpenOptions zf_tajweed_open_default_options(void);

/* `model_dir` is the model folder (sdk/v4.0). Reads tokens.txt (38 lines of "<token> <id>", ids 0 to
 * 37 in order), keeps calibration.json's bytes when the folder has one (it is not parsed), and with
 * load_engine reads the context's engine files. It does not read expected_tj3.zfx. The SDK verifies
 * the folder's files against its signed manifest before this call; nothing is verified here. */
ZF_TAJWEED_API ZfTajweedModel *zf_tajweed_model_open(const char *model_dir,
                                                     const ZfTajweedOpenOptions *options,
                                                     const char **error);
ZF_TAJWEED_API void zf_tajweed_model_close(ZfTajweedModel *m);

/* The context the model was opened with ("c16_l64"); NULL when none was given (load_engine 0). */
ZF_TAJWEED_API const char *zf_tajweed_model_context(const ZfTajweedModel *m);
/* Audio per engine chunk in ms (160 for c8, 320 for c16, 480 for c24); 0 without the engine. */
ZF_TAJWEED_API int zf_tajweed_model_chunk_ms(const ZfTajweedModel *m);
/* tokens.txt's entry for `id` ("<blk>", "|", a letter, "a", "aa", ...), NULL out of range. */
ZF_TAJWEED_API const char *zf_tajweed_token_name(const ZfTajweedModel *m, int id);

/* calibration.json exactly as the folder ships it: its bytes, and their count in *size (which may be
 * NULL). One NUL byte follows them, not counted, so the bytes can be read as a C string. NULL (and
 * *size 0) when the folder has no calibration.json. Data only: this library never parses it and never
 * applies it; what its numbers mean is in the SDKs' documentation. Valid until the model is closed. */
ZF_TAJWEED_API const void *zf_tajweed_model_calibration(const ZfTajweedModel *m, size_t *size);

/* ---------------------------------------------------------------------------------------------
 * Heads: what the network says, kept whole for the take
 * ------------------------------------------------------------------------------------------- */

/* Every output of the network after its states (README_heads.txt), row major, frames first.
 * Two frame rates: n40 frames at 40 ms and n20 = 2 x n40 frames at 20 ms, aligned (20 ms frame
 * 2k and 2k + 1 lie in 40 ms frame k). A pointer is NULL when a source does not provide that head
 * (a stream computes only the heads it was asked for, see zf_tajweed_stream_set_heads). */
typedef struct {
  int n40, n20;
  int vocab;                      /* 38 */
  const float *log_probs;         /* [n40, 38] final CTC, log-softmax */
  const float *inter1_log_probs;  /* [n40, 38] stack-1 InterCTC, log-softmax */
  const float *inter4_log_probs;  /* [n40, 38] stack-4 InterCTC, log-softmax (diagnostic) */
  const float *id_log_probs;      /* [n20, 38] identity CTC, log-softmax */
  const float *timing_log_probs;  /* [n20, 38] H-time chain, log-softmax; 0 = pause state */
  const float *gem;               /* [n20, 2] softmax: single, held */
  const float *attr_tafkheem;     /* [n20, 3] softmax: thin, heavy, low heavy */
  const float *attr_ghunna;       /* [n20, 5] softmax: none, plain, geminate, ikhfa, idgham */
  const float *attr_qalqalah;     /* [n20, 3] softmax: none, sughra, kubra */
  const float *attr_face;         /* [n20, 4] softmax: none, imala, tasheel, sakt */
  const float *boundary;          /* [n20] logit: a unit starts here */
  const float *conf;              /* [n20] logit: the frame's label is truthful */
} ZfTajweedHeads;

/* ---------------------------------------------------------------------------------------------
 * The stream: audio in, heads kept
 * ------------------------------------------------------------------------------------------- */

typedef struct ZfTajweedStream ZfTajweedStream;

/* Called after every engine chunk with that chunk's heads (n40 = 8 and n20 = 16 at c16; 12 and 24
 * at c24), valid only during the call. Optional. */
typedef void (*ZfTajweedChunkCallback)(void *user, const ZfTajweedHeads *chunk);

/* A stream over the model's engine (the model must have been opened with load_engine). */
ZF_TAJWEED_API ZfTajweedStream *zf_tajweed_stream_create(ZfTajweedModel *m, const char **error);
ZF_TAJWEED_API void zf_tajweed_stream_destroy(ZfTajweedStream *s);
ZF_TAJWEED_API void zf_tajweed_stream_set_callback(ZfTajweedStream *s, ZfTajweedChunkCallback cb,
                                                   void *user);
/* A new take: every cache and every kept head back to the start. */
ZF_TAJWEED_API void zf_tajweed_stream_reset(ZfTajweedStream *s);
/* Mono float samples in [-1, 1] at the open options' sample_rate. Returns the chunks run, or -1. */
ZF_TAJWEED_API int zf_tajweed_stream_push_audio(ZfTajweedStream *s, const float *samples, int n);
/* The end of the take: the 1.05 s flush the model is decoded with, and every chunk it completes.
 * Returns the chunks run, or -1. Reset before the next take. */
ZF_TAJWEED_API int zf_tajweed_stream_finish(ZfTajweedStream *s);
/* Every head of the take so far. The pointers stay valid until the next push, finish or reset. */
ZF_TAJWEED_API int zf_tajweed_stream_heads(const ZfTajweedStream *s, ZfTajweedHeads *out);
/* What the model heard: greedy CTC on log_probs, blanks and repeats removed. Writes at most `max`
 * ids and returns how many there are in all. */
ZF_TAJWEED_API int zf_tajweed_stream_greedy(const ZfTajweedStream *s, int *ids, int max);
ZF_TAJWEED_API const char *zf_tajweed_stream_last_error(const ZfTajweedStream *s);

/* The heads a stream computes, as ZfTajweedHeads' fields. A head that is not asked for is not
 * computed at all (the engine skips every node that feeds only heads nobody asked for), and its
 * ZfTajweedHeads pointer is NULL; asking for one costs exactly its own nodes, and every head that is
 * computed is the same bits whatever else is asked for. A new stream computes
 * ZF_TAJWEED_HEADS_DEFAULT (log_probs, inter1_log_probs, timing_log_probs, gem, attr_qalqalah: the five
 * that 2.x called ZF_TAJWEED_HEADS_SCORER; the SDKs' default selection adds conf for the decoded
 * layer's confidence); ZF_TAJWEED_HEADS_ALL computes all twelve. log_probs is always computed. */
enum {
  ZF_TAJWEED_HEAD_LOG_PROBS = 1 << 0,
  ZF_TAJWEED_HEAD_INTER1 = 1 << 1,
  ZF_TAJWEED_HEAD_INTER4 = 1 << 2,
  ZF_TAJWEED_HEAD_ID = 1 << 3,
  ZF_TAJWEED_HEAD_TIMING = 1 << 4,
  ZF_TAJWEED_HEAD_GEM = 1 << 5,
  ZF_TAJWEED_HEAD_TAFKHEEM = 1 << 6,
  ZF_TAJWEED_HEAD_GHUNNA = 1 << 7,
  ZF_TAJWEED_HEAD_QALQALAH = 1 << 8,
  ZF_TAJWEED_HEAD_FACE = 1 << 9,
  ZF_TAJWEED_HEAD_BOUNDARY = 1 << 10,
  ZF_TAJWEED_HEAD_CONF = 1 << 11,
  ZF_TAJWEED_HEADS_DEFAULT = ZF_TAJWEED_HEAD_LOG_PROBS | ZF_TAJWEED_HEAD_INTER1 | ZF_TAJWEED_HEAD_TIMING |
                             ZF_TAJWEED_HEAD_GEM | ZF_TAJWEED_HEAD_QALQALAH,
  ZF_TAJWEED_HEADS_ALL = (1 << 12) - 1
};
/* Set at the start of a take (after create or reset, before the first push): returns 0, or -1 once
 * the take has chunks (the kept arrays would have holes). Unknown bits are ignored. */
ZF_TAJWEED_API int zf_tajweed_stream_set_heads(ZfTajweedStream *s, unsigned heads);
ZF_TAJWEED_API unsigned zf_tajweed_stream_get_heads(const ZfTajweedStream *s);
/* A head's name in the graph and README_heads.txt ("inter1_log_probs", ...) for one ZF_TAJWEED_HEAD_
 * bit, its frame period (40 or 20 ms) and values per frame; NULL for anything else. */
ZF_TAJWEED_API const char *zf_tajweed_head_info(unsigned head, int *frame_ms, int *cols);

/* ---------------------------------------------------------------------------------------------
 * The decoded layer: the best token of each frame, the runner-up, any depth of ranking
 * ------------------------------------------------------------------------------------------- */

/* Per 40 ms CTC frame of log_probs, the best token and the runner-up with their log-probs (one scan
 * of the row; ties go to the lower id, the engine decoder's rule, so `token` is the greedy decode's
 * argmax). margin = log_prob - runner_up_log_prob >= 0. */
typedef struct {
  int token, runner_up;
  float log_prob, runner_up_log_prob, margin;
} ZfTajweedTop2;
/* For log-probs from any source ([frames, vocab] row major, vocab >= 2). Returns frames, or -1. */
ZF_TAJWEED_API int zf_tajweed_top2(const float *log_probs, int frames, int vocab, ZfTajweedTop2 *out);
/* The take so far, kept by the stream as chunks arrive (n40 entries, valid until the next push,
 * finish or reset). Returns the count, or -1. */
ZF_TAJWEED_API int zf_tajweed_stream_top2(const ZfTajweedStream *s, const ZfTajweedTop2 **out);

/* Top-K, for any head with a distribution, to any depth: per frame the k best entries, ranked. The
 * token heads (log_probs, inter1, inter4, id, timing: 38 tokens, k 1 to 38, 38 being the whole ranked
 * list) and the class heads (gem 2, attr_tafkheem 3, attr_ghunna 5, attr_qalqalah 3, attr_face 4
 * classes, k up to their count). boundary and conf are single logits and have no ranking.
 * The order is by value, highest first, and equal values by the lower id: exactly a stable argsort of
 * the negated row, so k = cols is the full argsort and k = 2 gives zf_tajweed_top2's token and
 * runner-up. ids, values and margins are [frames, k] row major (values and margins may be NULL);
 * margins[j] = values[j] - the value ranked j + 1 (even when that one is beyond k), and 0 for the last
 * entry of the row (rank cols - 1). Nothing is ranked unless it is asked for: a partial selection,
 * k passes over the row, per frame. */
/* For any [frames, cols] values (1 <= cols <= 64, 1 <= k <= cols). Returns frames, or -1. */
ZF_TAJWEED_API int zf_tajweed_topk(const float *values, int frames, int cols, int k, int *ids, float *values_out,
                                   float *margins);
/* For a head the stream keeps (a ZF_TAJWEED_HEAD_* bit: a token or class head it computes, see
 * zf_tajweed_stream_set_heads), over the whole take so far: writes the first min(frames, max_frames)
 * frames and returns the take's frame count at that head's rate (n40 or n20), or -1 (no stream, a head
 * that is not kept or has no ranking, k out of range). */
ZF_TAJWEED_API int zf_tajweed_stream_topk(const ZfTajweedStream *s, unsigned head, int k, int *ids,
                                          float *values_out, float *margins, int max_frames);

/* ---------------------------------------------------------------------------------------------
 * Reference data: the expected units of each ayah, as a table of its own
 * ------------------------------------------------------------------------------------------- */

/* A reader of an expected_tj3.zfx file (tajweed/FORMAT.md): surah and ayah in, the ayah's unit ids
 * (tokens.txt ids) and the word of each unit out. It is data, read only: it has no link to a model
 * (opening or running a model never reads the file, and this reader needs no model), and nothing in
 * the library compares it with a take. A reference is immutable after open and may be shared by any
 * number of threads. */
typedef struct ZfTajweedReference ZfTajweedReference;

/* From a file, or from the file's bytes in memory (they are copied; the caller keeps its buffer).
 * NULL with *error set when the bytes are not a whole, well-formed table. */
ZF_TAJWEED_API ZfTajweedReference *zf_tajweed_reference_open(const char *path, const char **error);
ZF_TAJWEED_API ZfTajweedReference *zf_tajweed_reference_open_memory(const void *bytes, size_t size,
                                                                    const char **error);
ZF_TAJWEED_API void zf_tajweed_reference_close(ZfTajweedReference *r);

/* Ayahs in a surah (1 to 114); 0 for a surah the table does not have. */
ZF_TAJWEED_API int zf_tajweed_reference_ayah_count(const ZfTajweedReference *r, int surah);
/* One ayah's expected units: the tj3 ids in reading order, the word bar "|" (id 1) between words
 * included (the continuing form: ibtida at the first word, wasl inside, the pausal form at the
 * ayah's end), and for every unit its 0-based word (a word bar belongs to the word before it).
 * Returns the unit count, or -1 for an ayah the table does not have (the outputs are then left
 * alone). Each output may be NULL. `units` and `word_of_unit` point into the reference and stay valid
 * until it is closed. */
ZF_TAJWEED_API int zf_tajweed_reference_units(const ZfTajweedReference *r, int surah, int ayah,
                                              const int **units, const int **word_of_unit, int *n_words);
/* The SHA-256 (32 bytes) of the tokens.txt the table's ids refer to: compare it with the model's
 * tokens.txt before using the ids with that model's heads. */
ZF_TAJWEED_API const unsigned char *zf_tajweed_reference_tokens_sha256(const ZfTajweedReference *r);

#ifdef __cplusplus
}
#endif
#endif /* ZF_TAJWEED_H */
