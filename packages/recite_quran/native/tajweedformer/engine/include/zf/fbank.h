/* Kaldi fbank, the same bits on every device.
 *
 * The features the models were trained on come from kaldi-native-fbank: 80 mel bins, 25 ms povey
 * window every 10 ms, dither 0, DC removed, pre-emphasis 0.97, snip_edges false, 20 Hz to Nyquist
 * minus 400, log energies. It is exact only as far as its platform lets it be: it asks libm for its
 * window, its mel banks and its FFT twiddles at start-up, calls the platform's logf per value, and
 * leaves multiply-adds to the compiler, which fuses them on some targets and not others.
 *
 * This is its algorithm, operation for operation, with those taken away: the start-up constants
 * are tables generated once by kaldi-native-fbank's and kissfft's own code (tools/fbank/
 * dump_tables.cc), the FFT is kissfft (the version kaldi-native-fbank pins) with those twiddles, the
 * log is the engine's vendored logf, nothing is contracted and nothing is auto-vectorised (ARMv7
 * NEON flushes denormals where scalar arithmetic does not). So a waveform gives the same features
 * on every ABI, and the engine takes it from there.
 *
 * Samples are float in [-1, 1] at 16 kHz (int16 divided by 32768). Streaming, like
 * kaldi-native-fbank's OnlineFbank: a frame is produced once every sample it needs has arrived. */
#ifndef ZF_FBANK_H
#define ZF_FBANK_H

#ifdef __cplusplus
extern "C" {
#endif

#define ZF_FBANK_BINS 80
#define ZF_FBANK_SHIFT 160 /* samples per frame at 16 kHz */

typedef struct ZfFbank ZfFbank;

ZfFbank *zf_fbank_create(void);
void zf_fbank_destroy(ZfFbank *f);
void zf_fbank_reset(ZfFbank *f);

/* The most frames one call can produce from n more samples: size `out` for it. */
int zf_fbank_max_frames(int n);

/* Take n samples and write every frame they complete to `out` ([frames, 80]); returns the number
 * of frames, or -1 if max_frames is too small (nothing is consumed then). */
int zf_fbank_accept(ZfFbank *f, const float *samples, int n, float *out, int max_frames);

/* The end of the input: the frames that were waiting on samples that will not come, reflected at
 * the end as kaldi does. After this, zf_fbank_reset before accepting again. */
int zf_fbank_finish(ZfFbank *f, float *out, int max_frames);

#ifdef __cplusplus
}
#endif
#endif /* ZF_FBANK_H */
