/* expf, logf and powf exactly as the Alcatel's libm computes them, on every ABI.
 *
 * Under ZF_CONV_ORT the engine calls libm in three places: BiasNorm's Pow(-0.5) (ORT's own Pow is
 * std::pow in float), the CTC head's LogSoftmax (std::log of the sum), and the decoder's printed
 * confidences. On the Alcatel, Android 11's 32-bit bionic implements all three with ARM's
 * optimized-routines, and a different phone's libm (arm64 bionic, another Android release) is a
 * different program: on AArch64 the same source rounds to integer with FRINTA (ties away) where the
 * 32-bit build adds a shift (ties to even), and may fuse multiply-adds. So the engine carries its own
 * copy, vendored from optimized-routines v20.05 (third_party/aor_math), with the 32-bit build's
 * configuration forced on every target: no rounding intrinsics, no fast FMA, and (in CMake) no
 * contraction. Every operation is then an IEEE double or float operation with one rounding, which is
 * the same on every core.
 *
 * Checked exhaustively on the Alcatel against its own libm: every 32-bit input for expf and logf,
 * every positive x for powf(x, -0.5), which is the only call the engine makes (bench/engine/libm_check).
 */
#undef HAVE_FAST_ROUND
#define HAVE_FAST_ROUND 0
#undef HAVE_FAST_LROUND
#define HAVE_FAST_LROUND 0
#undef HAVE_FAST_FMA
#define HAVE_FAST_FMA 0
#undef USE_GLIBC_ABI
#define USE_GLIBC_ABI 0 /* no glibc alias symbols */

/* libm's own declarations first, under their own names: with the renames below in force, glibc's
 * <math.h> (which math_config.h includes) would declare its vector variants as
 * __DECL_SIMD_zf_libm_expf and fail to compile. Its include guard keeps the second inclusion out. */
#include <math.h>
#include <stdint.h>

/* the vendored names, kept out of libm's way */
#define expf zf_libm_expf
#define logf zf_libm_logf
#define powf zf_libm_powf
#define __exp2f_data zf_libm_exp2f_data
#define __logf_data zf_libm_logf_data
#define __powf_log2_data zf_libm_powf_log2_data
#define __math_oflowf zf_libm_oflowf
#define __math_uflowf zf_libm_uflowf
#define __math_may_uflowf zf_libm_may_uflowf
#define __math_divzerof zf_libm_divzerof
#define __math_invalidf zf_libm_invalidf
#define __math_check_oflowf zf_libm_check_oflowf
#define __math_check_uflowf zf_libm_check_uflowf

#include "../../third_party/aor_math/math_errf.c"
#include "../../third_party/aor_math/exp2f_data.c"
#include "../../third_party/aor_math/logf_data.c"
#include "../../third_party/aor_math/powf_log2_data.c"
#include "../../third_party/aor_math/expf.c"
#include "../../third_party/aor_math/logf.c"
#include "../../third_party/aor_math/powf.c"

unsigned long zf_fp_enter(void) {
#if defined(__aarch64__) && !(defined(ZF_NEON_EMU) && ZF_NEON_EMU)
  unsigned long fpcr;
  __asm__ __volatile__("mrs %0, fpcr" : "=r"(fpcr));
  __asm__ __volatile__("msr fpcr, %0" ::"r"(fpcr | (1ul << 24) | (1ul << 25)));
  return fpcr;
#else
  return 0;
#endif
}

void zf_fp_leave(unsigned long saved) {
#if defined(__aarch64__) && !(defined(ZF_NEON_EMU) && ZF_NEON_EMU)
  __asm__ __volatile__("msr fpcr, %0" ::"r"(saved));
#else
  (void)saved;
#endif
}
