/* Where the engine's vector code comes from.
 *
 * On ARM it is the real thing, arm_neon.h. Anywhere else (WebAssembly, and x86 if asked) the engine
 * runs the same NEON source through zf/neon_emu.h, which implements each intrinsic the engine uses
 * with the semantics ARMv7 NEON has on the Alcatel: every float operation flushes denormal inputs
 * and outputs to zero, VRECPE is ARM's 8-bit table estimate, VMAX and VMIN treat -0 < +0. The
 * portable C paths in the kernels are not the reference arithmetic (ONNX Runtime's ARM kernels exist
 * only in NEON form there), so an exact build off ARM has to take the NEON paths.
 *
 *   ZF_NEON_AVAILABLE  1 when either kind of NEON is available
 *   ZF_NEON_A64        1 when the AArch64 spelling of the arch-dependent helpers is to be used
 *                      (fused FMA via vfmaq_f32, VRECPS written out). The emulation takes it.
 *
 * ZF_NEON_EMU is on by default for WebAssembly and can be asked for anywhere (-DZF_NEON_EMU=1),
 * which is how the emulation is checked on an ARM host against the hardware it imitates. */
#ifndef ZF_NEON_H
#define ZF_NEON_H

#if defined(__wasm__) && !defined(ZF_NEON_EMU)
#define ZF_NEON_EMU 1
#endif

#if defined(ZF_NEON_EMU) && ZF_NEON_EMU
#include "zf/neon_emu.h"
#define ZF_NEON_AVAILABLE 1
#define ZF_NEON_A64 1
#elif defined(__ARM_NEON) || defined(__ARM_NEON__)
#include <arm_neon.h>
#define ZF_NEON_AVAILABLE 1
#if defined(__aarch64__)
#define ZF_NEON_A64 1
#else
#define ZF_NEON_A64 0
#endif
#else
#define ZF_NEON_AVAILABLE 0
#define ZF_NEON_A64 0
#endif

#endif
