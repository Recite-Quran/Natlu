/* Audio to 16 kHz, the same bits on every device.
 *
 * The models take 16 kHz. Phones record at 48 or 44.1 kHz, and a platform's converter
 * (AVAudioConverter, Android's resampler) is its own filter, its own arithmetic and its own version:
 * two apps, or one app on two OS releases, would feed the bit-exact engine different samples. So the
 * SDK resamples itself.
 *
 * A rational polyphase FIR: upsample by L, low-pass, keep one sample in M, with L/M = 16000/in_rate
 * in lowest terms (48000 is 1/3, 44100 is 160/441). The filters are Kaiser windowed sincs designed
 * offline in double precision and rounded to float once (tools/resample/make_tables.py, emitted as
 * hex float literals in resample_tables.h), so nothing transcendental runs here. Each output sample
 * is one dot product of its polyphase row with the input, accumulated in float from the newest
 * sample to the oldest, nothing contracted and nothing auto-vectorised: plain scalar IEEE arithmetic
 * in one order on every ISA and at every optimisation level.
 *
 * Rates 32000 to 48000 (and 22050, 24000): flat to 7.2 kHz, at least 80 dB down from 8 kHz. Rates
 * 8000 and 11025 upsample: flat to 0.9 of their own Nyquist, images at least 80 dB down from it.
 * 16000 is passed through untouched. resample_tables.h has the measured figures.
 *
 * Streaming: an output sample is written as soon as every input it needs has arrived, and any
 * chunking of the input gives the same output, bit for bit, as one call. The filter's delay is taken
 * out exactly (output sample j is at time j / 16000 s, as input sample i is at i / in_rate s), and
 * the input is taken as zero before its start and after its end, so n input samples give
 * ceil(n * 16000 / in_rate) outputs in all.
 *
 * Samples are float, the same scale in as out. */
#ifndef ZF_RESAMPLE_H
#define ZF_RESAMPLE_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ZfResampler ZfResampler;

/* 8000, 11025, 16000, 22050, 24000, 32000, 44100 or 48000 Hz to 16 kHz; NULL for any other rate. */
ZfResampler *zf_resampler_create(int in_rate);
void zf_resampler_destroy(ZfResampler *r);
void zf_resampler_reset(ZfResampler *r);

/* Room enough for a push of n more samples and for a finish after it: size `out` for it. With n = 0
 * it is exactly what zf_resampler_finish will write. */
int zf_resampler_max_out(const ZfResampler *r, int n);

/* Take n samples and write every output sample they complete; returns the number written, or -1
 * if max_out is too small for them (nothing is consumed then) or after a finish. */
int zf_resampler_push(ZfResampler *r, const float *in, int n, float *out, int max_out);

/* The end of the input: the outputs still waiting on the filter's tail, with zeros after the last
 * sample. Returns the number written, or -1 if max_out is too small (nothing changes then). After
 * this, zf_resampler_reset before pushing again. */
int zf_resampler_finish(ZfResampler *r, float *out, int max_out);

#ifdef __cplusplus
}
#endif
#endif /* ZF_RESAMPLE_H */
