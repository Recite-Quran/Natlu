/* expf, logf and powf as the Alcatel's libm computes them, on every ABI; see engine/src/zf_libm.c. */
#ifndef ZF_LIBM_H
#define ZF_LIBM_H

#ifdef __cplusplus
extern "C" {
#endif

float zf_libm_expf(float x);
float zf_libm_logf(float x);
float zf_libm_powf(float x, float y);

/* ARMv7 NEON always flushes denormals to zero and returns the default NaN; AArch64 does either only
 * when FPCR says so. zf_fp_enter sets FPCR.FZ and FPCR.DN for the engine's arithmetic and returns
 * the previous FPCR for zf_fp_leave. Both are no-ops off AArch64. */
unsigned long zf_fp_enter(void);
void zf_fp_leave(unsigned long saved);

#ifdef __cplusplus
}
#endif

#endif
