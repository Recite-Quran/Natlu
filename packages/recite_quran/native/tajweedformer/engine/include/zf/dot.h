/* The int8 matmul as one instruction per sixteen products, for cores that have SDOT.
 *
 * On the Alcatel's Cortex-A53 a weight byte and an activation byte meet in VMULL.S8 plus VMLAL.S8,
 * two products to an int16 lane, and VPADAL.S16 widens them: three 128-bit instructions per sixteen
 * multiply-adds, and on a 64-bit datapath that is six cycles, so 2.67 products a cycle. Two
 * products a lane is the most that fits, because two times 127 squared is 32258 against an int16
 * limit of 32767. That ceiling is the reason the engine's matmuls stop where they do, and it is a
 * property of ARMv8.0 rather than of the code.
 *
 * SDOT, from ARMv8.2-A DotProd, does four int8 multiply-adds per 32-bit lane in one instruction:
 *
 *   SDOT vacc.4s, vw.16b, va.4b[lane]
 *
 * accumulates, for each of four lanes u, sum over j of vw[4u + j] * va[4 * lane + j]. With four
 * output units laid side by side in vw and the activation's four k values selected by lane, that is
 * sixteen products in one instruction: three times the pairing form's arithmetic throughput.
 *
 * It needs its own weight layout, so this carries its own packer. The arithmetic is the same
 * integer sum in the same order, and the accumulator cannot overflow (the widest k in the model is
 * 2432, and 2432 times 127 squared is 39.2M against an int32 limit of 2.1G), so the result is the
 * same integers the pairing kernel produces. zf_dot_available says whether the instruction is
 * there; the portable path below computes the same thing so the layout can be tested anywhere.
 */
#ifndef ZF_DOT_H
#define ZF_DOT_H

#include <stddef.h>
#include <stdint.h>

#include "zf/kernels.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Output units per packed panel, and the k group one SDOT consumes. */
#define ZF_DOT_UNIT_BLOCK 4
#define ZF_DOT_K_GROUP 4

/* 1 when this build and this core can issue SDOT, 0 when the portable path is used instead. */
int zf_dot_available(void);

/* Sizes to allocate before packing. k is rounded up to sixteen, as the pairing layout does, so a
 * panel is four units by k_pad bytes and the total matches. */
size_t zf_weights_s8_packed_dot_bytes(int n, int k);

/* Pack row-major weights into [k group of four][unit][four k]. Refuses -128 for the same reason
 * the pairing packer does, so the two layouts accept exactly the same weights. */
int zf_weights_s8_pack_dot(const int8_t *w_nk, int n, int k, int8_t *packed, int32_t *row_sums,
                           ZfWeightsS8 *out);

/* Turn a panel already packed for the pairing kernel into the dot layout, in place.
 *
 * The weight file stores panels packed for the shipping ABI, and both layouts are permutations of
 * the same bytes within one panel, so a device that has SDOT rearranges them on the way in rather
 * than carrying a second copy of 63 MB. Returns 0 if the geometry is not one this understands. */
int zf_weights_s8_to_dot(int8_t *packed, int n, int k);

/* out[i][j] = sum_k (a[i][k] - a_zero_point) * weight[j][k], over panels [block_begin, block_end),
 * with `a` the shifted int8 activations at row stride lda and `out` at row stride ldc. Identical
 * integers to zf_linear_s8_range on the same weights. */
void zf_linear_s8_dot_range(const int8_t *a, int m, int lda, const ZfWeightsS8 *w, int a_zero_point,
                            int32_t *out, int ldc, int block_begin, int block_end);

#ifdef __cplusplus
}
#endif
#endif /* ZF_DOT_H */
