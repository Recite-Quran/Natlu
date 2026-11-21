/* The NEON intrinsics the engine uses, as ARMv7 NEON computes them, in portable C.
 *
 * Included through zf/neon.h when ZF_NEON_EMU is set (the default for WebAssembly). Built on
 * clang/GCC vector extensions, so a build with -msimd128 gets SIMD128 code and one without gets
 * scalar code, from the same definitions. What makes them ARM's and not the host's:
 *
 * - Flush to zero. ARMv7 NEON always runs with FZ and default NaN (the Apple and arm64 builds put
 *   FPCR.FZ and FPCR.DN on the engine's threads to match, zf_fp_enter). Every float arithmetic
 *   operation flushes each input whose magnitude is below 2^-126 to a zero of the same sign, and
 *   its result the same way, deciding that a result is tiny BEFORE rounding as ARM does: a product
 *   that rounds up to exactly 2^-126 from below is flushed. (Sums and differences near 2^-126 are
 *   exact, so only products need that test; a fused multiply-add landing within 2^-180 of 2^-126
 *   is the one case left to the host's rounding.) Moves, loads, stores, lane access, bit operations,
 *   VABS and VNEG do not flush, as on ARM.
 * - VMAX/VMIN: a NaN in either operand gives NaN, and max(+0, -0) is +0, min is -0 (IEEE maximum,
 *   which is also WebAssembly's f32x4.max).
 * - VRECPE: ARM's RecipEstimate, the 8-bit table value, with FZ's special cases (a denormal is a
 *   zero and gives infinity; |x| >= 2^126 gives zero).
 * - VCVT to integer: truncating and saturating, NaN to 0.
 * - vfmaq_f32 / vfmsq_f32: one rounding, which is what the engine's AArch64 spelling of its ARMv7
 *   inline VFMA asks for.
 * - vmlaq_*: a multiply rounded and flushed, then an add rounded and flushed, never fused.
 *
 * NaN payloads are not reproduced (ARM's default NaN is one pattern; WebAssembly's NaN bits are
 * not specified); no engine output depends on them. wasm/neon_check compares every operation here
 * with the hardware on an ARM host.
 *
 * Why the float vectors are structs. Flushing an input is four SIMD instructions, and a
 * multiply-add has three inputs and two results, so flushing everything made the float kernels
 * five times slower. Nearly all of those flushes are of values another emulated operation just
 * flushed. So each float vector carries `clean`, true when it is known to hold no denormal: every
 * arithmetic result is clean, a load or a reinterpreted integer is not. An input is flushed only
 * when it is not clean, and since the flag is a constant wherever the compiler can see where the
 * value came from (an accumulator, a chain of operations), the redundant flushes disappear at
 * compile time. The bits themselves are never touched except by an arithmetic operation's own
 * flush, so a stored or reinterpreted value is exactly ARM's.
 *
 * The file must be compiled with -ffp-contract=off, as the whole engine is. */
#ifndef ZF_NEON_EMU_H
#define ZF_NEON_EMU_H

#include <math.h>
#include <stdint.h>
#include <string.h>

#if defined(__wasm_simd128__)
#include <wasm_simd128.h>
#endif

#if defined(ZFE_TRACE)
/* Diagnostic: every intrinsic out of line, and every flush that changes a value logged against the
 * engine instruction that called it (engine/src/neon_emu_trace.c). Not for a release build. */
#define ZFE_INLINE static __attribute__((noinline, used))
void zfe_trace_flush(void *site, int kind);
#define ZFE_TRACE_FLUSH(changed, kind) \
  do { if (changed) zfe_trace_flush(__builtin_return_address(0), (kind)); } while (0)
#else
#define ZFE_INLINE static inline __attribute__((always_inline))
#define ZFE_TRACE_FLUSH(changed, kind) ((void)0)
#endif
#define ZFE_ALWAYS static inline __attribute__((always_inline))

typedef float zfe_f32x4 __attribute__((vector_size(16)));
typedef float zfe_f32x2 __attribute__((vector_size(8)));
typedef double zfe_f64x2 __attribute__((vector_size(16)));
typedef int64_t zfe_i64x2 __attribute__((vector_size(16)));

typedef struct { zfe_f32x4 v; int clean; } float32x4_t;
typedef struct { zfe_f32x2 v; int clean; } float32x2_t;
typedef int32_t int32x4_t __attribute__((vector_size(16)));
typedef int32_t int32x2_t __attribute__((vector_size(8)));
typedef uint32_t uint32x4_t __attribute__((vector_size(16)));
typedef uint32_t uint32x2_t __attribute__((vector_size(8)));
typedef int16_t int16x8_t __attribute__((vector_size(16)));
typedef uint16_t uint16x8_t __attribute__((vector_size(16)));
typedef int16_t int16x4_t __attribute__((vector_size(8)));
typedef int8_t int8x16_t __attribute__((vector_size(16)));
typedef int8_t int8x8_t __attribute__((vector_size(8)));
typedef uint8_t uint8x16_t __attribute__((vector_size(16)));
typedef uint8_t uint8x8_t __attribute__((vector_size(8)));
typedef struct { int32x4_t val[2]; } int32x4x2_t;
typedef struct { float32x4_t val[2]; } float32x4x2_t;

/* ------------------------------------------------------------------ flush to zero */

#if defined(ZFE_NO_FTZ) /* diagnostic: what flush to zero is worth */
ZFE_ALWAYS zfe_f32x4 zfe_ftz4(zfe_f32x4 v) { return v; }
ZFE_ALWAYS zfe_f32x2 zfe_ftz2(zfe_f32x2 v) { return v; }
ZFE_ALWAYS float zfe_ftz1(float v) { return v; }
#else
ZFE_ALWAYS zfe_f32x4 zfe_ftz4(zfe_f32x4 v) {
  const int32x4_t b = (int32x4_t)v;
  const int32x4_t tiny = (b & 0x7fffffff) < 0x00800000;
  const int32x4_t r = b & ~(tiny & 0x7fffffff);
  ZFE_TRACE_FLUSH((r[0] != b[0]) | (r[1] != b[1]) | (r[2] != b[2]) | (r[3] != b[3]), 4);
  return (zfe_f32x4)r;
}
ZFE_ALWAYS zfe_f32x2 zfe_ftz2(zfe_f32x2 v) {
  const int32x2_t b = (int32x2_t)v;
  const int32x2_t tiny = (b & 0x7fffffff) < 0x00800000;
  const int32x2_t r = b & ~(tiny & 0x7fffffff);
  ZFE_TRACE_FLUSH((r[0] != b[0]) | (r[1] != b[1]), 2);
  return (zfe_f32x2)r;
}
ZFE_ALWAYS float zfe_ftz1(float v) {
  uint32_t b;
  memcpy(&b, &v, 4);
  const uint32_t r = (b & 0x7fffffffu) < 0x00800000u ? b & 0x80000000u : b;
  ZFE_TRACE_FLUSH(r != b, 1);
  memcpy(&v, &r, 4);
  return v;
}
#endif

/* Lanes that are not zero and at most 2^-126 in magnitude: the only ones a flush (or the product
 * edge below) can change. Checking for them and branching keeps the flush off the arithmetic's
 * dependency chain; they almost never occur, and when they do the slow path does the full work. */
ZFE_ALWAYS int zfe_any_small4(zfe_f32x4 v) {
  const uint32x4_t m = (((uint32x4_t)v & 0x7fffffffu) - 1u) < 0x00800000u;
#if defined(__wasm_simd128__)
  return wasm_v128_any_true((v128_t)m);
#else
  return (int)((m[0] | m[1]) | (m[2] | m[3]));
#endif
}
ZFE_ALWAYS int zfe_any_small2(zfe_f32x2 v) {
  const uint32x2_t m = (((uint32x2_t)v & 0x7fffffffu) - 1u) < 0x00800000u;
  return (int)(m[0] | m[1]);
}

/* an operand as arithmetic sees it, and a result as arithmetic leaves it */
ZFE_ALWAYS zfe_f32x4 zfe_in4(float32x4_t a) {
  return a.clean || __builtin_expect(!zfe_any_small4(a.v), 1) ? a.v : zfe_ftz4(a.v);
}
ZFE_ALWAYS zfe_f32x2 zfe_in2(float32x2_t a) {
  return a.clean || __builtin_expect(!zfe_any_small2(a.v), 1) ? a.v : zfe_ftz2(a.v);
}
ZFE_ALWAYS float32x4_t zfe_out4(zfe_f32x4 v) {
  return (float32x4_t){__builtin_expect(!zfe_any_small4(v), 1) ? v : zfe_ftz4(v), 1};
}
ZFE_ALWAYS float32x2_t zfe_out2(zfe_f32x2 v) {
  return (float32x2_t){__builtin_expect(!zfe_any_small2(v), 1) ? v : zfe_ftz2(v), 1};
}
ZFE_ALWAYS float32x4_t zfe_raw4(zfe_f32x4 v) { return (float32x4_t){v, 0}; }
ZFE_ALWAYS float32x2_t zfe_raw2(zfe_f32x2 v) { return (float32x2_t){v, 0}; }
ZFE_ALWAYS int zfe_is_clean1(float s) { return fabsf(s) >= 0x1p-126f || s == 0.0f || s != s; }

ZFE_ALWAYS float zfe_default_nan(void) {
  const uint32_t b = 0x7fc00000u;
  float f;
  memcpy(&f, &b, 4);
  return f;
}

/* Products: flushed when tiny before rounding. A product below 2^-126 can round up to exactly
 * 2^-126 only from within half a denormal step of it, so only results equal to +-2^-126 need the
 * exact product, which a double holds. */
static __attribute__((noinline, cold, unused)) zfe_f32x4 zfe_mul_slow4(zfe_f32x4 a, zfe_f32x4 b,
                                                                       zfe_f32x4 r) {
  for (int i = 0; i < 4; ++i)
    if (fabsf(r[i]) == 0x1p-126f && fabs((double)a[i] * (double)b[i]) < 0x1p-126)
      r[i] = r[i] < 0 ? -0.0f : 0.0f;
  return zfe_ftz4(r);
}
static __attribute__((noinline, cold, unused)) zfe_f32x2 zfe_mul_slow2(zfe_f32x2 a, zfe_f32x2 b,
                                                                       zfe_f32x2 r) {
  for (int i = 0; i < 2; ++i)
    if (fabsf(r[i]) == 0x1p-126f && fabs((double)a[i] * (double)b[i]) < 0x1p-126)
      r[i] = r[i] < 0 ? -0.0f : 0.0f;
  return zfe_ftz2(r);
}
ZFE_ALWAYS float32x4_t zfe_mul_out4(zfe_f32x4 a, zfe_f32x4 b) {
  const zfe_f32x4 r = a * b;
  return (float32x4_t){__builtin_expect(!zfe_any_small4(r), 1) ? r : zfe_mul_slow4(a, b, r), 1};
}
ZFE_ALWAYS float32x2_t zfe_mul_out2(zfe_f32x2 a, zfe_f32x2 b) {
  const zfe_f32x2 r = a * b;
  return (float32x2_t){__builtin_expect(!zfe_any_small2(r), 1) ? r : zfe_mul_slow2(a, b, r), 1};
}

/* ------------------------------------------------------------------ scalar lane helpers */

ZFE_ALWAYS float zfe_max1(float a, float b) {
  if (a != a || b != b) return zfe_default_nan();
  if (a == b) { /* equal, or +0 against -0: +0 wins */
    uint32_t x, y;
    memcpy(&x, &a, 4);
    memcpy(&y, &b, 4);
    x &= y;
    memcpy(&a, &x, 4);
    return a;
  }
  return a > b ? a : b;
}
ZFE_ALWAYS float zfe_min1(float a, float b) {
  if (a != a || b != b) return zfe_default_nan();
  if (a == b) { /* -0 wins */
    uint32_t x, y;
    memcpy(&x, &a, 4);
    memcpy(&y, &b, 4);
    x |= y;
    memcpy(&a, &x, 4);
    return a;
  }
  return a < b ? a : b;
}
ZFE_ALWAYS int32_t zfe_cvt_s32_1(float f) {
  if (f != f) return 0;
  if (f >= 2147483648.0f) return INT32_MAX;
  if (f < -2147483648.0f) return INT32_MIN;
  return (int32_t)f;
}

/* ------------------------------------------------------------------ loads, stores, lanes */

ZFE_INLINE float32x4_t vld1q_f32(const float *p) { zfe_f32x4 v; memcpy(&v, p, 16); return zfe_raw4(v); }
ZFE_INLINE float32x2_t vld1_f32(const float *p) { zfe_f32x2 v; memcpy(&v, p, 8); return zfe_raw2(v); }
ZFE_INLINE int32x4_t vld1q_s32(const int32_t *p) { int32x4_t v; memcpy(&v, p, 16); return v; }
ZFE_INLINE int8x16_t vld1q_s8(const int8_t *p) { int8x16_t v; memcpy(&v, p, 16); return v; }
ZFE_INLINE int8x8_t vld1_s8(const int8_t *p) { int8x8_t v; memcpy(&v, p, 8); return v; }
ZFE_INLINE void vst1q_f32(float *p, float32x4_t v) { memcpy(p, &v.v, 16); }
ZFE_INLINE void vst1_f32(float *p, float32x2_t v) { memcpy(p, &v.v, 8); }
ZFE_INLINE void vst1q_s32(int32_t *p, int32x4_t v) { memcpy(p, &v, 16); }
ZFE_INLINE void vst1_s8(int8_t *p, int8x8_t v) { memcpy(p, &v, 8); }
ZFE_INLINE void vst1q_s8(int8_t *p, int8x16_t v) { memcpy(p, &v, 16); }
ZFE_INLINE float32x4_t vdupq_n_f32(float s) {
  return (float32x4_t){(zfe_f32x4){s, s, s, s}, zfe_is_clean1(s)};
}
ZFE_INLINE float32x2_t vdup_n_f32(float s) { return (float32x2_t){(zfe_f32x2){s, s}, zfe_is_clean1(s)}; }
ZFE_INLINE int32x4_t vdupq_n_s32(int32_t s) { return (int32x4_t){s, s, s, s}; }
ZFE_INLINE uint32x4_t vdupq_n_u32(uint32_t s) { return (uint32x4_t){s, s, s, s}; }
ZFE_INLINE float32x4_t vld1q_dup_f32(const float *p) { return vdupq_n_f32(*p); }
ZFE_INLINE float32x2_t vld1_dup_f32(const float *p) { return vdup_n_f32(*p); }
ZFE_INLINE float32x4_t zfe_setq_lane(float s, float32x4_t v, int lane) {
  v.v[lane] = s;
  v.clean = v.clean && zfe_is_clean1(s);
  return v;
}
#define vld1q_lane_f32(p, vec_, lane) zfe_setq_lane(*(p), (vec_), (lane))
#define vsetq_lane_f32(s, vec_, lane) zfe_setq_lane((s), (vec_), (lane))
#define vgetq_lane_f32(vec_, lane) ((float)((vec_).v[(lane)]))
#define vget_lane_f32(vec_, lane) ((float)((vec_).v[(lane)]))
#define vget_lane_u32(v, lane) ((uint32_t)((v)[(lane)]))
#define vgetq_lane_s32(v, lane) ((int32_t)((v)[(lane)]))
#define vst1_lane_u32(p, v, lane) \
  __extension__({ const uint32_t zfe_s_ = (uint32_t)((v)[(lane)]); memcpy((p), &zfe_s_, 4); })
#define vst1q_lane_f32(p, vec_, lane) \
  __extension__({ const float zfe_s_ = (vec_).v[(lane)]; memcpy((p), &zfe_s_, 4); })

ZFE_INLINE float32x2_t vget_low_f32(float32x4_t v) {
  return (float32x2_t){__builtin_shufflevector(v.v, v.v, 0, 1), v.clean};
}
ZFE_INLINE float32x2_t vget_high_f32(float32x4_t v) {
  return (float32x2_t){__builtin_shufflevector(v.v, v.v, 2, 3), v.clean};
}
ZFE_INLINE int32x2_t vget_low_s32(int32x4_t v) { return __builtin_shufflevector(v, v, 0, 1); }
ZFE_INLINE int32x2_t vget_high_s32(int32x4_t v) { return __builtin_shufflevector(v, v, 2, 3); }
ZFE_INLINE uint32x2_t vget_low_u32(uint32x4_t v) { return __builtin_shufflevector(v, v, 0, 1); }
ZFE_INLINE uint32x2_t vget_high_u32(uint32x4_t v) { return __builtin_shufflevector(v, v, 2, 3); }
ZFE_INLINE int16x4_t vget_low_s16(int16x8_t v) { return __builtin_shufflevector(v, v, 0, 1, 2, 3); }
ZFE_INLINE int16x4_t vget_high_s16(int16x8_t v) { return __builtin_shufflevector(v, v, 4, 5, 6, 7); }
ZFE_INLINE int8x8_t vget_low_s8(int8x16_t v) {
  return __builtin_shufflevector(v, v, 0, 1, 2, 3, 4, 5, 6, 7);
}
ZFE_INLINE int8x8_t vget_high_s8(int8x16_t v) {
  return __builtin_shufflevector(v, v, 8, 9, 10, 11, 12, 13, 14, 15);
}
ZFE_INLINE float32x4_t vcombine_f32(float32x2_t a, float32x2_t b) {
  return (float32x4_t){__builtin_shufflevector(a.v, b.v, 0, 1, 2, 3), a.clean && b.clean};
}
ZFE_INLINE int32x4_t vcombine_s32(int32x2_t a, int32x2_t b) {
  return __builtin_shufflevector(a, b, 0, 1, 2, 3);
}
ZFE_INLINE int16x8_t vcombine_s16(int16x4_t a, int16x4_t b) {
  return __builtin_shufflevector(a, b, 0, 1, 2, 3, 4, 5, 6, 7);
}
ZFE_INLINE int32x4x2_t vtrnq_s32(int32x4_t a, int32x4_t b) {
  int32x4x2_t r;
  r.val[0] = __builtin_shufflevector(a, b, 0, 4, 2, 6);
  r.val[1] = __builtin_shufflevector(a, b, 1, 5, 3, 7);
  return r;
}
ZFE_INLINE float32x4x2_t vtrnq_f32(float32x4_t a, float32x4_t b) {
  float32x4x2_t r;
  const int c = a.clean && b.clean;
  r.val[0] = (float32x4_t){__builtin_shufflevector(a.v, b.v, 0, 4, 2, 6), c};
  r.val[1] = (float32x4_t){__builtin_shufflevector(a.v, b.v, 1, 5, 3, 7), c};
  return r;
}

/* ------------------------------------------------------------------ reinterpretation */

#define vreinterpretq_f32_s32(x) zfe_raw4((zfe_f32x4)(x))
#define vreinterpretq_f32_u32(x) zfe_raw4((zfe_f32x4)(x))
#define vreinterpretq_s32_f32(vec_) ((int32x4_t)((vec_).v))
#define vreinterpretq_u32_f32(vec_) ((uint32x4_t)((vec_).v))
#define vreinterpretq_s32_u32(x) ((int32x4_t)(x))
#define vreinterpretq_u32_s32(x) ((uint32x4_t)(x))
#define vreinterpret_u32_s8(x) ((uint32x2_t)(x))

/* ------------------------------------------------------------------ float arithmetic (FZ) */

ZFE_INLINE float32x4_t vaddq_f32(float32x4_t a, float32x4_t b) { return zfe_out4(zfe_in4(a) + zfe_in4(b)); }
ZFE_INLINE float32x4_t vsubq_f32(float32x4_t a, float32x4_t b) { return zfe_out4(zfe_in4(a) - zfe_in4(b)); }
ZFE_INLINE float32x4_t vmulq_f32(float32x4_t a, float32x4_t b) {
  return zfe_mul_out4(zfe_in4(a), zfe_in4(b));
}
ZFE_INLINE float32x2_t vadd_f32(float32x2_t a, float32x2_t b) { return zfe_out2(zfe_in2(a) + zfe_in2(b)); }
ZFE_INLINE float32x2_t vmul_f32(float32x2_t a, float32x2_t b) {
  return zfe_mul_out2(zfe_in2(a), zfe_in2(b));
}
/* by a scalar: the scalar is flushed as a scalar, before it is broadcast */
ZFE_INLINE float32x4_t vmulq_n_f32(float32x4_t a, float s) {
  const float t = zfe_ftz1(s);
  return vmulq_f32(a, (float32x4_t){(zfe_f32x4){t, t, t, t}, 1});
}
ZFE_INLINE float32x4_t vmlaq_f32(float32x4_t a, float32x4_t b, float32x4_t c) {
  return vaddq_f32(a, vmulq_f32(b, c));
}
ZFE_INLINE float32x2_t vmla_f32(float32x2_t a, float32x2_t b, float32x2_t c) {
  return vadd_f32(a, vmul_f32(b, c));
}
ZFE_INLINE float32x4_t vmlaq_n_f32(float32x4_t a, float32x4_t b, float s) {
  return vaddq_f32(a, vmulq_n_f32(b, s));
}
#define vmlaq_lane_f32(a, b, vec_, lane) vmlaq_n_f32((a), (b), (float)((vec_).v[(lane)]))
ZFE_INLINE float32x4_t vnegq_f32(float32x4_t a) {
  return (float32x4_t){(zfe_f32x4)((uint32x4_t)a.v ^ 0x80000000u), a.clean};
}
ZFE_INLINE float32x4_t vabsq_f32(float32x4_t a) {
  return (float32x4_t){(zfe_f32x4)((uint32x4_t)a.v & 0x7fffffffu), a.clean};
}

/* One rounding, inputs and result flushed. a*b is exact in double, so a*b + c in double is one
 * rounding, and narrowing it to float is the second: the two can differ from one rounding only
 * when the double lands exactly halfway between two floats (low 29 bits 0x10000000) without being
 * exact. Those lanes, about one in 2^29 of random inputs, take libm's fmaf. */
ZFE_ALWAYS zfe_f32x2 zfe_fma2(zfe_f32x2 a, zfe_f32x2 b, zfe_f32x2 c, int *slow) {
  const zfe_f64x2 p = __builtin_convertvector(a, zfe_f64x2) * __builtin_convertvector(b, zfe_f64x2);
  const zfe_f64x2 cd = __builtin_convertvector(c, zfe_f64x2);
  const zfe_f64x2 s = p + cd;
  const zfe_i64x2 halfway = (((zfe_i64x2)s) & 0x1fffffff) == 0x10000000;
  const zfe_i64x2 exact = (s - p == cd) & (s - cd == p);
  *slow |= (int)((halfway[0] & ~exact[0]) | (halfway[1] & ~exact[1]));
  return __builtin_convertvector(s, zfe_f32x2);
}
ZFE_INLINE float32x4_t vfmaq_f32(float32x4_t acc, float32x4_t a, float32x4_t b) {
  const zfe_f32x4 c = zfe_in4(acc), x = zfe_in4(a), y = zfe_in4(b);
  int slow = 0;
  const zfe_f32x2 lo = zfe_fma2(__builtin_shufflevector(x, x, 0, 1), __builtin_shufflevector(y, y, 0, 1),
                                __builtin_shufflevector(c, c, 0, 1), &slow);
  const zfe_f32x2 hi = zfe_fma2(__builtin_shufflevector(x, x, 2, 3), __builtin_shufflevector(y, y, 2, 3),
                                __builtin_shufflevector(c, c, 2, 3), &slow);
  zfe_f32x4 r = __builtin_shufflevector(lo, hi, 0, 1, 2, 3);
  if (__builtin_expect(slow, 0))
    for (int i = 0; i < 4; ++i) r[i] = fmaf(x[i], y[i], c[i]);
  return zfe_out4(r);
}
ZFE_INLINE float32x4_t vfmsq_f32(float32x4_t acc, float32x4_t a, float32x4_t b) {
  return vfmaq_f32(acc, vnegq_f32(a), b);
}

/* results of max and min are one of their flushed operands (or NaN), so already clean */
#if defined(__wasm_simd128__)
ZFE_INLINE float32x4_t vmaxq_f32(float32x4_t a, float32x4_t b) {
  return (float32x4_t){(zfe_f32x4)wasm_f32x4_max((v128_t)zfe_in4(a), (v128_t)zfe_in4(b)), 1};
}
ZFE_INLINE float32x4_t vminq_f32(float32x4_t a, float32x4_t b) {
  return (float32x4_t){(zfe_f32x4)wasm_f32x4_min((v128_t)zfe_in4(a), (v128_t)zfe_in4(b)), 1};
}
ZFE_INLINE int32x4_t vcvtq_s32_f32(float32x4_t a) {
  return (int32x4_t)wasm_i32x4_trunc_sat_f32x4((v128_t)a.v);
}
#else
ZFE_INLINE float32x4_t vmaxq_f32(float32x4_t a, float32x4_t b) {
  const zfe_f32x4 x = zfe_in4(a), y = zfe_in4(b);
  zfe_f32x4 r;
  for (int i = 0; i < 4; ++i) r[i] = zfe_max1(x[i], y[i]);
  return (float32x4_t){r, 1};
}
ZFE_INLINE float32x4_t vminq_f32(float32x4_t a, float32x4_t b) {
  const zfe_f32x4 x = zfe_in4(a), y = zfe_in4(b);
  zfe_f32x4 r;
  for (int i = 0; i < 4; ++i) r[i] = zfe_min1(x[i], y[i]);
  return (float32x4_t){r, 1};
}
ZFE_INLINE int32x4_t vcvtq_s32_f32(float32x4_t a) {
  int32x4_t r;
  for (int i = 0; i < 4; ++i) r[i] = zfe_cvt_s32_1(a.v[i]); /* a denormal truncates to 0 anyway */
  return r;
}
#endif
/* an integer converts to zero or at least 1 in magnitude: clean */
ZFE_INLINE float32x4_t vcvtq_f32_s32(int32x4_t a) {
  return (float32x4_t){__builtin_convertvector(a, zfe_f32x4), 1};
}

/* pairwise: {a0 op a1, b0 op b1} */
ZFE_INLINE float32x2_t vpadd_f32(float32x2_t a, float32x2_t b) {
  const zfe_f32x2 x = zfe_in2(a), y = zfe_in2(b);
  return zfe_out2((zfe_f32x2){x[0] + x[1], y[0] + y[1]});
}
ZFE_INLINE float32x2_t vpmax_f32(float32x2_t a, float32x2_t b) {
  const zfe_f32x2 x = zfe_in2(a), y = zfe_in2(b);
  return (float32x2_t){(zfe_f32x2){zfe_max1(x[0], x[1]), zfe_max1(y[0], y[1])}, 1};
}
ZFE_INLINE float32x2_t vpmin_f32(float32x2_t a, float32x2_t b) {
  const zfe_f32x2 x = zfe_in2(a), y = zfe_in2(b);
  return (float32x2_t){(zfe_f32x2){zfe_min1(x[0], x[1]), zfe_min1(y[0], y[1])}, 1};
}

/* VRECPE in vectors. The table value for fraction bits i is r = (floor(2^19 / a) + 1) / 2 with
 * a = 2 * (256 + i) + 1; a is odd and at most 1023, so 2^19 / a is never an integer and sits at
 * least 1/1023 from one, far more than the float quotient's error (under 2^-13), and truncating the
 * float quotient gives the integer quotient exactly. A denormal input is read as the zero FZ makes
 * it, and every result is zero, normal, infinite or NaN, so the result is clean. */
ZFE_INLINE float32x4_t vrecpeq_f32(float32x4_t a) {
#if defined(ZFE_RECPE_EXACT) /* diagnostic: a correctly rounded reciprocal instead of ARM's estimate */
  return zfe_out4(1.0f / zfe_in4(a));
#endif
  const uint32x4_t x = (uint32x4_t)a.v;
  const uint32x4_t sign = x & 0x80000000u, e = (x >> 23) & 0xffu, frac = x & 0x7fffffu;
  const int32x4_t den = (int32x4_t)((frac >> 15) * 2u + 513u);
  const zfe_f32x4 q = (zfe_f32x4){524288.0f, 524288.0f, 524288.0f, 524288.0f} /
                      __builtin_convertvector(den, zfe_f32x4);
  const uint32x4_t r = ((uint32x4_t)__builtin_convertvector(q, int32x4_t) + 1u) >> 1;
  const uint32x4_t est = sign | ((253u - e) << 23) | ((r & 0xffu) << 15);
  const uint32x4_t is_nan = (uint32x4_t)((e == 0xffu) & (frac != 0u));
  const uint32x4_t to_inf = (uint32x4_t)(e == 0u);    /* zero, or a denormal flushed to one */
  const uint32x4_t to_zero = (uint32x4_t)(e >= 253u); /* infinity, or |x| >= 2^126 underflowing */
  uint32x4_t out = (est & ~to_zero) | (sign & to_zero);
  out = (out & ~to_inf) | ((sign | 0x7f800000u) & to_inf);
  out = (out & ~is_nan) | (0x7fc00000u & is_nan);
  return (float32x4_t){(zfe_f32x4)out, 1};
}

/* comparisons: inputs flushed, all ones where true */
ZFE_INLINE uint32x4_t vceqq_f32(float32x4_t a, float32x4_t b) { return (uint32x4_t)(zfe_in4(a) == zfe_in4(b)); }
ZFE_INLINE uint32x4_t vcgtq_f32(float32x4_t a, float32x4_t b) { return (uint32x4_t)(zfe_in4(a) > zfe_in4(b)); }
ZFE_INLINE uint32x4_t vcgeq_f32(float32x4_t a, float32x4_t b) { return (uint32x4_t)(zfe_in4(a) >= zfe_in4(b)); }
ZFE_INLINE uint32x4_t vcltq_f32(float32x4_t a, float32x4_t b) { return (uint32x4_t)(zfe_in4(a) < zfe_in4(b)); }
ZFE_INLINE float32x4_t vbslq_f32(uint32x4_t m, float32x4_t a, float32x4_t b) {
  return (float32x4_t){(zfe_f32x4)((m & (uint32x4_t)a.v) | (~m & (uint32x4_t)b.v)), a.clean && b.clean};
}

/* ------------------------------------------------------------------ certified arithmetic */

/* For a kernel that has proved flush to zero cannot act on its multiply-adds, plain IEEE arithmetic
 * is ARM's: see zfe_mla_certified. The smallest nonzero magnitude in p[0..n), NaN ignored: +inf
 * when every value is zero, and a denormal comes out as itself, so a caller comparing with 2^-126
 * sees it. */
static inline float zfe_min_nonzero_abs(const float *p, int n) {
  zfe_f32x4 m = {__builtin_inff(), __builtin_inff(), __builtin_inff(), __builtin_inff()};
  const zfe_f32x4 inf = m;
  int i = 0;
  for (; i + 4 <= n; i += 4) {
    zfe_f32x4 v;
    memcpy(&v, p + i, 16);
    const uint32x4_t a = (uint32x4_t)v & 0x7fffffffu;
    const int32x4_t use = (int32x4_t)((a != 0u) & (a <= 0x7f800000u)); /* not zero, not NaN */
    const zfe_f32x4 av = (zfe_f32x4)((a & (uint32x4_t)use) | ((uint32x4_t)inf & ~(uint32x4_t)use));
    const int32x4_t lt = av < m;
    m = (zfe_f32x4)(((int32x4_t)av & lt) | ((int32x4_t)m & ~lt));
  }
  float r = m[0] < m[1] ? m[0] : m[1];
  r = r < m[2] ? r : m[2];
  r = r < m[3] ? r : m[3];
  for (; i < n; ++i) {
    const float a = fabsf(p[i]);
    if (a != 0.0f && a == a && a < r) r = a;
  }
  return r;
}

/* True when a sum of products of these operands, in any order, never meets flush to zero: no
 * operand is a denormal, and every nonzero product is at least 2^-99 * (1 - 2^-24) > 2^-100 in
 * magnitude, so a multiple of 2^-123. Every partial sum is then a multiple of 2^-123 too (an exact
 * sum below 2^-100 is representable, a rounded one above it keeps the grid), so none is a nonzero
 * value under 2^-126: no input, product or sum is ever flushed, and IEEE arithmetic without the
 * flush gives ARM's bits. */
static inline int zfe_mla_certified(float min_a, float min_b) {
  return min_a >= 0x1p-126f && min_b >= 0x1p-126f && (double)min_a * (double)min_b >= 0x1p-99;
}

/* a + b * s with neither flushed: valid only under zfe_mla_certified for the operands. */
ZFE_INLINE float32x4_t zfe_mlaq_n_certified(float32x4_t a, float32x4_t b, float s) {
  return (float32x4_t){a.v + b.v * s, 1};
}

/* ------------------------------------------------------------------ integer */

ZFE_INLINE uint32x4_t vceqq_u32(uint32x4_t a, uint32x4_t b) { return (uint32x4_t)(a == b); }
ZFE_INLINE uint32x4_t vandq_u32(uint32x4_t a, uint32x4_t b) { return a & b; }
ZFE_INLINE uint32x4_t vorrq_u32(uint32x4_t a, uint32x4_t b) { return a | b; }
ZFE_INLINE uint32x2_t vorr_u32(uint32x2_t a, uint32x2_t b) { return a | b; }
ZFE_INLINE uint32x4_t vmvnq_u32(uint32x4_t a) { return ~a; }
ZFE_INLINE int32x4_t vandq_s32(int32x4_t a, int32x4_t b) { return a & b; }
ZFE_INLINE int32x4_t vorrq_s32(int32x4_t a, int32x4_t b) { return a | b; }
ZFE_INLINE uint32x2_t vpmax_u32(uint32x2_t a, uint32x2_t b) {
  return (uint32x2_t){a[0] > a[1] ? a[0] : a[1], b[0] > b[1] ? b[0] : b[1]};
}
ZFE_INLINE int32x4_t vaddq_s32(int32x4_t a, int32x4_t b) {
  return (int32x4_t)((uint32x4_t)a + (uint32x4_t)b);
}
ZFE_INLINE int32x4_t vsubq_s32(int32x4_t a, int32x4_t b) {
  return (int32x4_t)((uint32x4_t)a - (uint32x4_t)b);
}
ZFE_INLINE int32x4_t vmulq_n_s32(int32x4_t a, int32_t s) {
  return (int32x4_t)((uint32x4_t)a * (uint32_t)s);
}
ZFE_INLINE int32x4_t vmlaq_n_s32(int32x4_t acc, int32x4_t a, int32_t s) {
  return vaddq_s32(acc, vmulq_n_s32(a, s));
}
ZFE_ALWAYS int32x4_t zfe_sel_s32(int32x4_t m, int32x4_t a, int32x4_t b) { return (a & m) | (b & ~m); }
ZFE_INLINE int32x4_t vmaxq_s32(int32x4_t a, int32x4_t b) { return zfe_sel_s32(a > b, a, b); }
ZFE_INLINE int32x4_t vminq_s32(int32x4_t a, int32x4_t b) { return zfe_sel_s32(a < b, a, b); }
#define vshlq_n_s32(a, n) ((int32x4_t)((uint32x4_t)(a) << (n)))
#define vshrq_n_s32(a, n) ((int32x4_t)((a) >> (n)))
ZFE_INLINE int32x2_t vpadd_s32(int32x2_t a, int32x2_t b) {
  return (int32x2_t){(int32_t)((uint32_t)a[0] + (uint32_t)a[1]),
                     (int32_t)((uint32_t)b[0] + (uint32_t)b[1])};
}
ZFE_INLINE int16x8_t vmovl_s8(int8x8_t a) { return __builtin_convertvector(a, int16x8_t); }
ZFE_INLINE int32x4_t vmovl_s16(int16x4_t a) { return __builtin_convertvector(a, int32x4_t); }
ZFE_INLINE int16x8_t vmull_s8(int8x8_t a, int8x8_t b) {
  return __builtin_convertvector(a, int16x8_t) * __builtin_convertvector(b, int16x8_t);
}
ZFE_INLINE int16x8_t vmlal_s8(int16x8_t acc, int8x8_t a, int8x8_t b) {
  return (int16x8_t)((uint16x8_t)acc + (uint16x8_t)vmull_s8(a, b));
}
ZFE_INLINE int32x4_t vpadalq_s16(int32x4_t acc, int16x8_t b) {
#if defined(__wasm_simd128__)
  return vaddq_s32(acc, (int32x4_t)wasm_i32x4_extadd_pairwise_i16x8((v128_t)b));
#else
  const int16x4_t e = __builtin_shufflevector(b, b, 0, 2, 4, 6);
  const int16x4_t o = __builtin_shufflevector(b, b, 1, 3, 5, 7);
  return vaddq_s32(acc, vaddq_s32(__builtin_convertvector(e, int32x4_t),
                                  __builtin_convertvector(o, int32x4_t)));
#endif
}
ZFE_INLINE int16x4_t vqmovn_s32(int32x4_t a) {
  a = vminq_s32(a, vdupq_n_s32(32767));
  a = vmaxq_s32(a, vdupq_n_s32(-32768));
  return __builtin_convertvector(a, int16x4_t);
}
ZFE_INLINE int8x8_t vqmovn_s16(int16x8_t a) {
  const int16x8_t hi = {127, 127, 127, 127, 127, 127, 127, 127};
  const int16x8_t lo = {-128, -128, -128, -128, -128, -128, -128, -128};
  a = (hi & (a > hi)) | (a & ~(a > hi));
  a = (lo & (a < lo)) | (a & ~(a < lo));
  return __builtin_convertvector(a, int8x8_t);
}

#endif
