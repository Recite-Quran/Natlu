/* Hand-scheduled int8 microkernels for Cortex-A53 in 32-bit mode.
 *
 * The arithmetic is identical to the C intrinsics version in kernels.c: VMULL.S8 and VMLAL.S8 put
 * two products in each int16 lane (safe because every weight in this model is in [-127, 127]) and
 * VPADAL.S16 widens them into int32 accumulators. What assembly adds is the schedule. A53 is
 * in-order with a 64-bit NEON datapath, so every 128-bit operation issues twice and a dependent
 * instruction that arrives too early stalls the whole pipeline. These loops keep four product
 * registers in flight by reusing each weight register as a temporary the moment its last multiply
 * has issued, which puts three or more instructions between every producer and its consumer.
 *
 * Register map, 4 units by 2 rows: q0 and q1 hold the two activation rows, q2 to q5 the four units'
 * weights (loaded 32 bytes at a time), q8 to q11 accumulate row 0 and q12 to q15 row 1. Products
 * rotate through q6, q7 and the dead weight registers. That uses every one of the 16 quadword
 * registers, so d8 to d15 are saved as the ABI requires.
 */
#if defined(__arm__)
/* How far ahead to prefetch the weight panel, in bytes. One iteration consumes 64 bytes, which is
 * one cache line, so this is also the lead in iterations times 64. A chunk streams 63 MB of
 * weights, none of it resident, and an iteration is about forty issue slots: the lead has to cover
 * a DRAM miss with four cores competing, which is a good deal more than one iteration. */
#ifndef ZF_PLD_DIST
#define ZF_PLD_DIST 256
#endif
    .syntax unified
    .arch armv7-a
    .fpu neon
    .text

/* void zf_gemm_s8_4x2(const int8_t *a0, const int8_t *a1, const int8_t *panel, int groups,
 *                     const int32_t *corr, int32_t *out0, int32_t *out1, const float *sb);
 *
 * One packed panel of four output units against two activation rows, over all of k.
 * r0 = a0, r1 = a1, r2 = panel, r3 = groups, then corr, out0, out1, sb on the stack.
 *
 * `sb` is eight floats, four scales then four biases, or null. Null stores the int32 accumulators,
 * which is what the front end's convolutions want because they scale into NCHW with a transpose
 * and need the slab to transpose from. Non-null scales in place and stores float, which is what
 * every encoder linear wants: it saves writing the int32 out and reading it back, about 3.5 ms of a
 * chunk's single-core time and 3.5 MB of its traffic.
 *
 * Only the epilogue branches. The scheduled loop is shared and unchanged, which is the point: it is
 * the part that is hard to get right and hard to verify. `bias + acc * scale` is the same operation
 * in the same order as zf_dequantize_range performs, so the floats are the same floats.
 */
    .global zf_gemm_s8_4x2
    .type zf_gemm_s8_4x2, %function
    .thumb
    .thumb_func
zf_gemm_s8_4x2:
    push        {r4, r5, r6, r7}
    vpush       {d8-d15}
    ldr         r4, [sp, #80]           /* corr: 64 bytes of d8-d15 plus 16 of r4-r7 */
    ldr         r5, [sp, #84]           /* out0 */
    ldr         r6, [sp, #88]           /* out1 */
    ldr         r7, [sp, #92]           /* sb, or zero for the int32 path */
    vmov.i32    q8, #0
    vmov.i32    q9, #0
    vmov.i32    q10, #0
    vmov.i32    q11, #0
    vmov.i32    q12, #0
    vmov.i32    q13, #0
    vmov.i32    q14, #0
    vmov.i32    q15, #0
    cmp         r3, #0
    ble         2f
1:
    vld1.8      {d0, d1}, [r0]!         /* activation row 0, 16 values */
    vld1.8      {d2, d3}, [r1]!         /* activation row 1 */
    vld1.8      {d4, d5, d6, d7}, [r2]! /* units 0 and 1 */
    vld1.8      {d8, d9, d10, d11}, [r2]! /* units 2 and 3 */
    pld         [r2, #ZF_PLD_DIST]
    vmull.s8    q6, d0, d4
    vmull.s8    q7, d2, d4
    vmlal.s8    q6, d1, d5
    vmlal.s8    q7, d3, d5              /* q2 is dead from here */
    vmull.s8    q2, d0, d6
    vpadal.s16  q8, q6
    vmull.s8    q6, d2, d6
    vpadal.s16  q12, q7
    vmlal.s8    q2, d1, d7
    vmlal.s8    q6, d3, d7              /* q3 is dead from here */
    vmull.s8    q7, d0, d8
    vpadal.s16  q9, q2
    vmull.s8    q3, d2, d8
    vpadal.s16  q13, q6
    vmlal.s8    q7, d1, d9
    vmlal.s8    q3, d3, d9              /* q4 is dead from here */
    vmull.s8    q2, d0, d10
    vpadal.s16  q10, q7
    vmull.s8    q6, d2, d10
    vpadal.s16  q14, q3
    vmlal.s8    q2, d1, d11
    vmlal.s8    q6, d3, d11
    vpadal.s16  q11, q2
    vpadal.s16  q15, q6
    subs        r3, r3, #1
    bne         1b
2:
    vld1.32     {d2, d3}, [r4]          /* the zero-point correction, one value per unit */
    vpadd.i32   d16, d16, d17
    vpadd.i32   d18, d18, d19
    vpadd.i32   d20, d20, d21
    vpadd.i32   d22, d22, d23
    vpadd.i32   d16, d16, d18
    vpadd.i32   d17, d20, d22
    vadd.i32    q8, q8, q1              /* row 0, four units */
    vpadd.i32   d24, d24, d25
    vpadd.i32   d26, d26, d27
    vpadd.i32   d28, d28, d29
    vpadd.i32   d30, d30, d31
    vpadd.i32   d24, d24, d26
    vpadd.i32   d25, d28, d30
    vadd.i32    q12, q12, q1            /* row 1 */
    cmp         r7, #0
    beq         3f
    /* scale in place: the products and activations are dead, so q0, q2 and q3 are free */
    vld1.32     {d4, d5}, [r7]!         /* scale */
    vld1.32     {d6, d7}, [r7]          /* bias */
    vcvt.f32.s32 q8, q8
    vcvt.f32.s32 q12, q12
    vmov        q0, q3
    vmla.f32    q0, q8, q2
    vmla.f32    q3, q12, q2
    vst1.32     {d0, d1}, [r5]
    vst1.32     {d6, d7}, [r6]
    vpop        {d8-d15}
    pop         {r4, r5, r6, r7}
    bx          lr
3:
    vst1.32     {d16, d17}, [r5]
    vst1.32     {d24, d25}, [r6]
    vpop        {d8-d15}
    pop         {r4, r5, r6, r7}
    bx          lr
    .size zf_gemm_s8_4x2, . - zf_gemm_s8_4x2

/* void zf_gemm_s8_4x1(const int8_t *a0, const int8_t *panel, int groups, const int32_t *corr,
 *                     int32_t *out0, const float *sb);
 * The odd row left over when m is odd. One row needs only four accumulators, which leaves q12 to
 * q15 for products and lets the whole loop live in caller-saved registers: no stack traffic, and
 * the weights load in two halves so the second load has three instructions to complete in.
 * r0 = a0, r1 = panel, r2 = groups, r3 = corr, out0 on the stack.
 */
    .global zf_gemm_s8_4x1
    .type zf_gemm_s8_4x1, %function
    .thumb
    .thumb_func
zf_gemm_s8_4x1:
    ldr         r12, [sp]               /* out0 */
    vmov.i32    q8, #0
    vmov.i32    q9, #0
    vmov.i32    q10, #0
    vmov.i32    q11, #0
    cmp         r2, #0
    ble         2f
1:
    vld1.8      {d0, d1}, [r0]!
    vld1.8      {d4, d5, d6, d7}, [r1]! /* units 0 and 1 */
    pld         [r1, #ZF_PLD_DIST]
    vmull.s8    q12, d0, d4
    vmull.s8    q13, d0, d6
    vmlal.s8    q12, d1, d5
    vmlal.s8    q13, d1, d7
    vld1.8      {d4, d5, d6, d7}, [r1]! /* units 2 and 3 */
    vpadal.s16  q8, q12
    vpadal.s16  q9, q13
    vmull.s8    q12, d0, d4
    vmull.s8    q13, d0, d6
    vmlal.s8    q12, d1, d5
    vmlal.s8    q13, d1, d7
    vpadal.s16  q10, q12
    vpadal.s16  q11, q13
    subs        r2, r2, #1
    bne         1b
2:
    vld1.32     {d2, d3}, [r3]
    vpadd.i32   d16, d16, d17
    vpadd.i32   d18, d18, d19
    vpadd.i32   d20, d20, d21
    vpadd.i32   d22, d22, d23
    vpadd.i32   d16, d16, d18
    vpadd.i32   d17, d20, d22
    vadd.i32    q8, q8, q1
    ldr         r2, [sp, #4]            /* sb, or zero for the int32 path */
    cmp         r2, #0
    beq         3f
    vld1.32     {d4, d5}, [r2]!         /* scale */
    vld1.32     {d6, d7}, [r2]          /* bias */
    vcvt.f32.s32 q8, q8
    vmla.f32    q3, q8, q2
    vst1.32     {d6, d7}, [r12]
    bx          lr
3:
    vst1.32     {d16, d17}, [r12]
    bx          lr
    .size zf_gemm_s8_4x1, . - zf_gemm_s8_4x1


/* void zf_matmul_nt_tile4(const float *arow, const float *b, int ldb_bytes, int groups,
 *                         float *out4);
 *
 * out4[j] = sum over k of arow[k] * b[j][k], for the four rows of b that ldb_bytes apart, with k
 * running over groups * 4 values.
 *
 * This exists because the compiler would not keep five vector registers live. Written in C with the
 * four rows indexed off one base it recycled one register for three of them, so every load waited
 * for the previous multiply to read it and the eight cycle load latency was never hidden, and three
 * of the loop's sixteen instructions were scalar address arithmetic. It measured 0.16 products a
 * cycle where the instruction count implies 0.8. Here each row has its own register and its own
 * post-incrementing pointer, all five loads issue before the four multiply-adds, and the loop is
 * eleven instructions for sixteen products.
 *
 * q8 to q11 accumulate, q12 holds the query, q13 to q15 and q0 the four key rows. All of those are
 * caller-saved (d16 to d31 and d0 to d7), so nothing needs pushing but the general registers.
 *
 * The lanes are reduced pairwise, (c[0] + c[1]) + (c[2] + c[3]), which is the order the intrinsics
 * version's transpose and adds produced, so the result is unchanged to the bit.
 */
    .global zf_matmul_nt_tile4
    .type zf_matmul_nt_tile4, %function
    .thumb
    .thumb_func
zf_matmul_nt_tile4:
    push        {r4, r5, r6, r7}
    ldr         r7, [sp, #16]           /* out4 */
    add         r4, r1, r2              /* b1 */
    add         r5, r4, r2              /* b2 */
    add         r6, r5, r2              /* b3 */
    vmov.i32    q8, #0
    vmov.i32    q9, #0
    vmov.i32    q10, #0
    vmov.i32    q11, #0
    cmp         r3, #0
    ble         2f
1:
    vld1.32     {d24, d25}, [r0]!       /* the query, shared by all four */
    vld1.32     {d26, d27}, [r1]!
    vld1.32     {d28, d29}, [r4]!
    vld1.32     {d30, d31}, [r5]!
    vld1.32     {d0, d1}, [r6]!
    vmla.f32    q8, q13, q12
    vmla.f32    q9, q14, q12
    vmla.f32    q10, q15, q12
    vmla.f32    q11, q0, q12
    subs        r3, r3, #1
    bne         1b
2:
    vpadd.f32   d16, d16, d17
    vpadd.f32   d18, d18, d19
    vpadd.f32   d20, d20, d21
    vpadd.f32   d22, d22, d23
    vpadd.f32   d16, d16, d16
    vpadd.f32   d18, d18, d18
    vpadd.f32   d20, d20, d20
    vpadd.f32   d22, d22, d22
    vst1.32     {d16[0]}, [r7]!
    vst1.32     {d18[0]}, [r7]!
    vst1.32     {d20[0]}, [r7]!
    vst1.32     {d22[0]}, [r7]
    pop         {r4, r5, r6, r7}
    bx          lr
    .size zf_matmul_nt_tile4, . - zf_matmul_nt_tile4

/* void zf_matmul_nt_tile4x4(const float *a, int lda_bytes, const float *b, int ldb_bytes,
 *                           int groups, float *out, int ldc_bytes);
 *
 * out[i][j] = sum over k of a[i][k] * b[j][k], for four rows of a and four rows of b, with k
 * running over groups * 2 values.
 *
 * Why four by four and why d registers. The tile above takes one row of a against four of b: five
 * loads for four multiply-adds, eleven instructions for sixteen products. Measured against this
 * core's fp32 ceiling it reaches a uniform 38 per cent whatever the shape, so the tile is the limit.
 *
 * This core's floating point datapath is 64 bits, so a 128 bit VMLA.F32 issues in two passes and
 * buys no throughput over the 64 bit form; the ceiling either way is two multiply-adds a cycle,
 * which is 2.55 GMAdds/s at 1.274 GHz. What the 64 bit form buys is registers: 32 d against 16 q.
 * That is room for sixteen accumulators plus four row and four column operands, so eight loads feed
 * sixteen multiply-adds instead of five feeding four.
 *
 * Eight loads and sixteen multiply-adds only take sixteen cycles if the loads issue alongside the
 * FP pipe rather than ahead of it. Issuing them as a block first measured 59 per cent of the
 * ceiling. So this is software pipelined: the loop keeps two sets of operands, d0-d7 and d8-d15,
 * and each body does its sixteen multiply-adds from one set while loading the next group into the
 * other, one load between every pair of multiply-adds. Unrolled by two so the sets swap by
 * alternating the body rather than by moving registers, which would cost the eight cycles the
 * pipelining saves. d8-d15 are callee-saved, hence the vpush.
 *
 * d16 to d31 accumulate, d0 to d3 hold a's four rows, d4 to d7 hold b's four. All caller-saved, so
 * only the general registers are pushed.
 *
 * Lane order matches the C version's vpadd, so the result is unchanged to the bit.
 */
    .global zf_matmul_nt_tile4x4
    .type zf_matmul_nt_tile4x4, %function
    .thumb
    .thumb_func
zf_matmul_nt_tile4x4:
    push        {r4, r5, r6, r7, r8, r9, r10, r11, lr}
    vpush       {d8-d15}
    ldr         r12, [sp, #100]         /* groups */
    add         r4, r0, r1              /* a1 */
    add         r5, r4, r1              /* a2 */
    add         r6, r5, r1              /* a3 */
    add         r7, r2, r3              /* b1 */
    add         r8, r7, r3              /* b2 */
    add         r9, r8, r3              /* b3 */
    vmov.i32    d16, #0
    vmov.i32    d17, #0
    vmov.i32    d18, #0
    vmov.i32    d19, #0
    vmov.i32    d20, #0
    vmov.i32    d21, #0
    vmov.i32    d22, #0
    vmov.i32    d23, #0
    vmov.i32    d24, #0
    vmov.i32    d25, #0
    vmov.i32    d26, #0
    vmov.i32    d27, #0
    vmov.i32    d28, #0
    vmov.i32    d29, #0
    vmov.i32    d30, #0
    vmov.i32    d31, #0
    cmp         r12, #0
    ble         9f
    /* prologue: the first group's operands, so the loop always has work in hand */
    vld1.32     {d0}, [r0]!
    vld1.32     {d1}, [r4]!
    vld1.32     {d2}, [r5]!
    vld1.32     {d3}, [r6]!
    vld1.32     {d4}, [r2]!
    vld1.32     {d5}, [r7]!
    vld1.32     {d6}, [r8]!
    vld1.32     {d7}, [r9]!
    subs        r12, r12, #1
    beq         8f
1:
    vmla.f32    d16, d0, d4
    vld1.32     {d8}, [r0]!
    vmla.f32    d17, d0, d5
    vld1.32     {d9}, [r4]!
    vmla.f32    d18, d0, d6
    vld1.32     {d10}, [r5]!
    vmla.f32    d19, d0, d7
    vld1.32     {d11}, [r6]!
    vmla.f32    d20, d1, d4
    vld1.32     {d12}, [r2]!
    vmla.f32    d21, d1, d5
    vld1.32     {d13}, [r7]!
    vmla.f32    d22, d1, d6
    vld1.32     {d14}, [r8]!
    vmla.f32    d23, d1, d7
    vld1.32     {d15}, [r9]!
    vmla.f32    d24, d2, d4
    vmla.f32    d25, d2, d5
    vmla.f32    d26, d2, d6
    vmla.f32    d27, d2, d7
    vmla.f32    d28, d3, d4
    vmla.f32    d29, d3, d5
    vmla.f32    d30, d3, d6
    vmla.f32    d31, d3, d7
    subs        r12, r12, #1
    beq         7f
    vmla.f32    d16, d8, d12
    vld1.32     {d0}, [r0]!
    vmla.f32    d17, d8, d13
    vld1.32     {d1}, [r4]!
    vmla.f32    d18, d8, d14
    vld1.32     {d2}, [r5]!
    vmla.f32    d19, d8, d15
    vld1.32     {d3}, [r6]!
    vmla.f32    d20, d9, d12
    vld1.32     {d4}, [r2]!
    vmla.f32    d21, d9, d13
    vld1.32     {d5}, [r7]!
    vmla.f32    d22, d9, d14
    vld1.32     {d6}, [r8]!
    vmla.f32    d23, d9, d15
    vld1.32     {d7}, [r9]!
    vmla.f32    d24, d10, d12
    vmla.f32    d25, d10, d13
    vmla.f32    d26, d10, d14
    vmla.f32    d27, d10, d15
    vmla.f32    d28, d11, d12
    vmla.f32    d29, d11, d13
    vmla.f32    d30, d11, d14
    vmla.f32    d31, d11, d15
    subs        r12, r12, #1
    bne         1b
    b           8f
7:
    /* the last group's operands are in d8-d15 */
    vmla.f32    d16, d8, d12
    vmla.f32    d17, d8, d13
    vmla.f32    d18, d8, d14
    vmla.f32    d19, d8, d15
    vmla.f32    d20, d9, d12
    vmla.f32    d21, d9, d13
    vmla.f32    d22, d9, d14
    vmla.f32    d23, d9, d15
    vmla.f32    d24, d10, d12
    vmla.f32    d25, d10, d13
    vmla.f32    d26, d10, d14
    vmla.f32    d27, d10, d15
    vmla.f32    d28, d11, d12
    vmla.f32    d29, d11, d13
    vmla.f32    d30, d11, d14
    vmla.f32    d31, d11, d15
    b           9f
8:
    /* the last group's operands are in d0-d7 */
    vmla.f32    d16, d0, d4
    vmla.f32    d17, d0, d5
    vmla.f32    d18, d0, d6
    vmla.f32    d19, d0, d7
    vmla.f32    d20, d1, d4
    vmla.f32    d21, d1, d5
    vmla.f32    d22, d1, d6
    vmla.f32    d23, d1, d7
    vmla.f32    d24, d2, d4
    vmla.f32    d25, d2, d5
    vmla.f32    d26, d2, d6
    vmla.f32    d27, d2, d7
    vmla.f32    d28, d3, d4
    vmla.f32    d29, d3, d5
    vmla.f32    d30, d3, d6
    vmla.f32    d31, d3, d7
9:
    ldr         r10, [sp, #104]         /* out */
    ldr         r11, [sp, #108]         /* ldc_bytes */
    /* vst1 wants consecutive registers, so each row's four sums reduce into a consecutive pair.
     * The pairing is (c0+c1, c2+c3) per lane, the order the intrinsics version's vpadd produced. */
    vpadd.f32   d16, d16, d17
    vpadd.f32   d17, d18, d19
    vst1.32     {d16, d17}, [r10], r11
    vpadd.f32   d18, d20, d21
    vpadd.f32   d19, d22, d23
    vst1.32     {d18, d19}, [r10], r11
    vpadd.f32   d20, d24, d25
    vpadd.f32   d21, d26, d27
    vst1.32     {d20, d21}, [r10], r11
    vpadd.f32   d22, d28, d29
    vpadd.f32   d23, d30, d31
    vst1.32     {d22, d23}, [r10]
    vpop        {d8-d15}
    pop         {r4, r5, r6, r7, r8, r9, r10, r11, pc}
    .size zf_matmul_nt_tile4x4, . - zf_matmul_nt_tile4x4

/* void zf_matmul_nt_tile4x4_q(const float *a, int lda_bytes, const float *b, int ldb_bytes,
 *                             int groups, float *out, int ldc_bytes);
 *
 * The same 4 by 4 tile, stepping k by four instead of two, with q register operands.
 *
 * The d register form is limited by loads rather than arithmetic. Measured on this core,
 * multiply-adds alone run at 4.39 GMAdds/s, 3.45 a cycle, so a step's 16 of them is 9.3 cycles;
 * the tile takes 23.2, so its 8 loads cost about 1.74 cycles each and do not pair with the FP pipe.
 * That caps it near 2.36 GMAdds/s however well the arithmetic is scheduled.
 *
 * Loading four k values per operand instead of two feeds 64 products from the same eight loads
 * rather than 32. The arithmetic doubles to 32 multiply-adds, 18.6 cycles, and the loads stay at
 * 13.9, so a step is about 32.5 cycles for 64 products: near 2.5 GMAdds/s against 1.76.
 *
 * The register file fits it exactly. Operands are q0 to q7, which is d0 to d15, and the sixteen
 * accumulators are d16 to d31. Nothing spills and nothing is moved.
 *
 * Bit identical to the d form, which is not obvious and is the reason this is safe: with q loads
 * d0 holds a[k], a[k+1] and d1 holds a[k+2], a[k+3], so lane 0 accumulates k, k+2, k+4 and lane 1
 * accumulates k+1, k+3, k+5, which is exactly the lane assignment stepping by two produces. The
 * pairwise reduction at the end is unchanged.
 *
 * The sixteen lo multiply-adds are issued before the sixteen hi, so an accumulator is not revisited
 * until fifteen other ops have issued and the latency is covered.
 *
 * Requires four to divide k. conv0 has k = 9 and takes the d form.
 */
    .global zf_matmul_nt_tile4x4_q
    .type zf_matmul_nt_tile4x4_q, %function
    .thumb
    .thumb_func
zf_matmul_nt_tile4x4_q:
    push        {r4, r5, r6, r7, r8, r9, r10, r11, lr}
    vpush       {d8-d15}
    ldr         r12, [sp, #100]         /* groups */
    add         r4, r0, r1              /* a1 */
    add         r5, r4, r1              /* a2 */
    add         r6, r5, r1              /* a3 */
    add         r7, r2, r3              /* b1 */
    add         r8, r7, r3              /* b2 */
    add         r9, r8, r3              /* b3 */
    vmov.i32    d16, #0
    vmov.i32    d17, #0
    vmov.i32    d18, #0
    vmov.i32    d19, #0
    vmov.i32    d20, #0
    vmov.i32    d21, #0
    vmov.i32    d22, #0
    vmov.i32    d23, #0
    vmov.i32    d24, #0
    vmov.i32    d25, #0
    vmov.i32    d26, #0
    vmov.i32    d27, #0
    vmov.i32    d28, #0
    vmov.i32    d29, #0
    vmov.i32    d30, #0
    vmov.i32    d31, #0
    cmp         r12, #0
    ble         9f
1:
    vld1.32     {d0, d1}, [r0]!
    vld1.32     {d2, d3}, [r4]!
    vld1.32     {d4, d5}, [r5]!
    vld1.32     {d6, d7}, [r6]!
    vld1.32     {d8, d9}, [r2]!
    vld1.32     {d10, d11}, [r7]!
    vld1.32     {d12, d13}, [r8]!
    vld1.32     {d14, d15}, [r9]!
    vmla.f32    d16, d0, d8
    vmla.f32    d17, d0, d10
    vmla.f32    d18, d0, d12
    vmla.f32    d19, d0, d14
    vmla.f32    d20, d2, d8
    vmla.f32    d21, d2, d10
    vmla.f32    d22, d2, d12
    vmla.f32    d23, d2, d14
    vmla.f32    d24, d4, d8
    vmla.f32    d25, d4, d10
    vmla.f32    d26, d4, d12
    vmla.f32    d27, d4, d14
    vmla.f32    d28, d6, d8
    vmla.f32    d29, d6, d10
    vmla.f32    d30, d6, d12
    vmla.f32    d31, d6, d14
    vmla.f32    d16, d1, d9
    vmla.f32    d17, d1, d11
    vmla.f32    d18, d1, d13
    vmla.f32    d19, d1, d15
    vmla.f32    d20, d3, d9
    vmla.f32    d21, d3, d11
    vmla.f32    d22, d3, d13
    vmla.f32    d23, d3, d15
    vmla.f32    d24, d5, d9
    vmla.f32    d25, d5, d11
    vmla.f32    d26, d5, d13
    vmla.f32    d27, d5, d15
    vmla.f32    d28, d7, d9
    vmla.f32    d29, d7, d11
    vmla.f32    d30, d7, d13
    vmla.f32    d31, d7, d15
    subs        r12, r12, #1
    bgt         1b
9:
    ldr         r10, [sp, #104]         /* out */
    ldr         r11, [sp, #108]         /* ldc_bytes */
    vpadd.f32   d16, d16, d17
    vpadd.f32   d17, d18, d19
    vst1.32     {d16, d17}, [r10], r11
    vpadd.f32   d18, d20, d21
    vpadd.f32   d19, d22, d23
    vst1.32     {d18, d19}, [r10], r11
    vpadd.f32   d20, d24, d25
    vpadd.f32   d21, d26, d27
    vst1.32     {d20, d21}, [r10], r11
    vpadd.f32   d22, d28, d29
    vpadd.f32   d23, d30, d31
    vst1.32     {d22, d23}, [r10]
    vpop        {d8-d15}
    pop         {r4, r5, r6, r7, r8, r9, r10, r11, pc}
    .size zf_matmul_nt_tile4x4_q, . - zf_matmul_nt_tile4x4_q


#endif /* __arm__ */

    .text

/* void zf_gemm_s8_4xm(const int8_t *a, int lda, const int8_t *panel, int groups, int pairs,
 *                     const int32_t *corr, void *out, int ldout, const float *sb);
 *
 * zf_gemm_s8_4x2 with its row loop brought inside.
 *
 * The panel loop in linear_s8_rows_f is outer and the row loop inner, so the 4x2 kernel's
 * `push {r4-r7}` plus `vpush {d8-d15}` and their matching pops -- 160 bytes of stack traffic and
 * four stack-argument loads -- were paid once per (panel, row pair), about 161 thousand times a
 * chunk. The arithmetic needs q4 to q7, which are callee-saved, so the save cannot simply be
 * dropped; but it only has to happen once per panel. Hoisting the row loop here takes the calls
 * to roughly 37 thousand.
 *
 * This runs the row PAIRS only. An odd last row stays with zf_gemm_s8_4x1 on the C side, which
 * needs no stack traffic of its own and keeps this kernel to one shape.
 *
 * Exact: the inner loop, its operand order and the reduction epilogue are copied verbatim from
 * zf_gemm_s8_4x2. Only the function boundary and the register save move outward, so every int32
 * partial sum and every float in the epilogue is what it was.
 *
 * The panel pointer is post-incremented through the loop and so is reset from r8 on each pass;
 * forgetting that reads past the panel and is the obvious way to get this wrong. */
    .global zf_gemm_s8_4xm
    .type zf_gemm_s8_4xm, %function
    .thumb
    .thumb_func
zf_gemm_s8_4xm:
    push        {r4, r5, r6, r7, r8, r10, r11, lr}  /* 32 bytes */
    vpush       {d8-d15}                /* 64 more: stack arguments start at sp+96 */
    ldr         r11, [sp, #96]          /* pairs */
    cmp         r11, #0
    ble         9f
    mov         r8, r2                  /* panel base, restored every pass */
    mov         r10, r3                 /* groups, likewise */
    ldr         r5, [sp, #104]          /* out0 */
    ldr         r12, [sp, #108]         /* ldout, in elements */
    add         lr, r1, r1              /* two rows of activation, in bytes */
    add         r1, r0, r1              /* a1 = a + lda */
    add         r6, r5, r12, lsl #2     /* out1 = out0 + ldout */
0:
    mov         r2, r8
    mov         r3, r10
    vmov.i32    q8, #0
    vmov.i32    q9, #0
    vmov.i32    q10, #0
    vmov.i32    q11, #0
    vmov.i32    q12, #0
    vmov.i32    q13, #0
    vmov.i32    q14, #0
    vmov.i32    q15, #0
    cmp         r3, #0
    ble         2f
1:
    vld1.8      {d0, d1}, [r0]!         /* activation row 0, 16 values */
    vld1.8      {d2, d3}, [r1]!         /* activation row 1 */
    vld1.8      {d4, d5, d6, d7}, [r2]! /* units 0 and 1 */
    vld1.8      {d8, d9, d10, d11}, [r2]! /* units 2 and 3 */
    pld         [r2, #ZF_PLD_DIST]
    vmull.s8    q6, d0, d4
    vmull.s8    q7, d2, d4
    vmlal.s8    q6, d1, d5
    vmlal.s8    q7, d3, d5              /* q2 is dead from here */
    vmull.s8    q2, d0, d6
    vpadal.s16  q8, q6
    vmull.s8    q6, d2, d6
    vpadal.s16  q12, q7
    vmlal.s8    q2, d1, d7
    vmlal.s8    q6, d3, d7              /* q3 is dead from here */
    vmull.s8    q7, d0, d8
    vpadal.s16  q9, q2
    vmull.s8    q3, d2, d8
    vpadal.s16  q13, q6
    vmlal.s8    q7, d1, d9
    vmlal.s8    q3, d3, d9              /* q4 is dead from here */
    vmull.s8    q2, d0, d10
    vpadal.s16  q10, q7
    vmull.s8    q6, d2, d10
    vpadal.s16  q14, q3
    vmlal.s8    q2, d1, d11
    vmlal.s8    q6, d3, d11
    vpadal.s16  q11, q2
    vpadal.s16  q15, q6
    subs        r3, r3, #1
    bne         1b
2:
    ldr         r4, [sp, #100]          /* corr */
    vld1.32     {d2, d3}, [r4]          /* the zero-point correction, one value per unit */
    vpadd.i32   d16, d16, d17
    vpadd.i32   d18, d18, d19
    vpadd.i32   d20, d20, d21
    vpadd.i32   d22, d22, d23
    vpadd.i32   d16, d16, d18
    vpadd.i32   d17, d20, d22
    vadd.i32    q8, q8, q1              /* row 0, four units */
    vpadd.i32   d24, d24, d25
    vpadd.i32   d26, d26, d27
    vpadd.i32   d28, d28, d29
    vpadd.i32   d30, d30, d31
    vpadd.i32   d24, d24, d26
    vpadd.i32   d25, d28, d30
    vadd.i32    q12, q12, q1            /* row 1 */
    ldr         r7, [sp, #112]          /* sb, reloaded because the float path advances it */
    cmp         r7, #0
    beq         3f
    /* scale in place: the products and activations are dead, so q0, q2 and q3 are free */
    vld1.32     {d4, d5}, [r7]!         /* scale */
    vld1.32     {d6, d7}, [r7]          /* bias */
    vcvt.f32.s32 q8, q8
    vcvt.f32.s32 q12, q12
    vmov        q0, q3
    vmla.f32    q0, q8, q2
    vmla.f32    q3, q12, q2
    vst1.32     {d0, d1}, [r5]
    vst1.32     {d6, d7}, [r6]
    b           4f
3:
    vst1.32     {d16, d17}, [r5]
    vst1.32     {d24, d25}, [r6]
4:
    /* The loop left r0 and r1 one panel of groups past their row, so wind that back and step on
     * by two rows. */
    sub.w       r0, r0, r10, lsl #4
    add         r0, r0, lr
    sub.w       r1, r1, r10, lsl #4
    add         r1, r1, lr
    ldr         r12, [sp, #108]
    add         r5, r5, r12, lsl #3     /* two rows of output, in bytes */
    add         r6, r6, r12, lsl #3
    subs        r11, r11, #1
    bne         0b
9:
    vpop        {d8-d15}
    pop         {r4, r5, r6, r7, r8, r10, r11, pc}
    .size zf_gemm_s8_4xm, . - zf_gemm_s8_4xm

/* void zf_seq_tile4x8(const float *panel, const float *a, int lda_bytes, int steps, float *acc);
 *
 * Four rows against eight columns in ONNX Runtime's summation order: every lane is one output and
 * sums strictly up k, k before k+1, starting from what `acc` holds. The caller does the strides
 * and folds; this is the inner loop, which C could not schedule.
 *
 * Written in C with intrinsics the same tile measured 24 to 32 per cent of the core's fp32 peak
 * against the old pairwise tile's 39 to 41, with the same eight loads per sixteen q multiply-adds:
 * clang put each load immediately before the multiply-add that used it, and the in-order A53
 * stalls on every one. Here the NEXT step's operands load between this step's multiply-adds. Rows
 * alternate between two register sets (d8-d11 and d12-d15), the panel's k and k+1 halves reload the
 * moment their last multiply-add has issued, and the final step is peeled so nothing is read past
 * the panel or past a row.
 *
 * r0 = panel, 16 floats a step (eight columns at k, then at k+1). r1 = row 0 at k, rows 1 to 3 at
 * lda_bytes apart. r3 = steps, at least one. acc on the stack: 32 floats, [row][column], in and out.
 * q8/q9 row 0, q10/q11 row 1, q12/q13 row 2, q14/q15 row 3.
 */
    .global zf_seq_tile4x8
    .type zf_seq_tile4x8, %function
    .thumb
    .thumb_func
zf_seq_tile4x8:
    push        {r4, r5, r6, r7, lr}
    vpush       {d8-d15}
    ldr         r12, [sp, #84]          /* acc */
    add         r4, r1, r2
    add         r5, r4, r2
    add         r6, r5, r2
    mov         r7, r12
    vld1.32     {d16-d19}, [r7]!
    vld1.32     {d20-d23}, [r7]!
    vld1.32     {d24-d27}, [r7]!
    vld1.32     {d28-d31}, [r7]
    vld1.32     {d0-d3}, [r0]!
    vld1.32     {d4-d7}, [r0]!
    vld1.32     {d8}, [r1]!
    vld1.32     {d9}, [r4]!
    vld1.32     {d10}, [r5]!
    vld1.32     {d11}, [r6]!
    subs        r3, r3, #1
    beq         8f
1:
    vmla.f32    q8, q0, d8[0]
    vmla.f32    q9, q1, d8[0]
    vld1.32     {d12}, [r1]!
    vmla.f32    q10, q0, d9[0]
    vmla.f32    q11, q1, d9[0]
    vld1.32     {d13}, [r4]!
    vmla.f32    q12, q0, d10[0]
    vmla.f32    q13, q1, d10[0]
    vld1.32     {d14}, [r5]!
    vmla.f32    q14, q0, d11[0]
    vmla.f32    q15, q1, d11[0]
    vld1.32     {d15}, [r6]!
    vld1.32     {d0-d3}, [r0]!
    vmla.f32    q8, q2, d8[1]
    vmla.f32    q9, q3, d8[1]
    vmla.f32    q10, q2, d9[1]
    vmla.f32    q11, q3, d9[1]
    vmla.f32    q12, q2, d10[1]
    vmla.f32    q13, q3, d10[1]
    vmla.f32    q14, q2, d11[1]
    vmla.f32    q15, q3, d11[1]
    vld1.32     {d4-d7}, [r0]!
    subs        r3, r3, #1
    beq         9f
    vmla.f32    q8, q0, d12[0]
    vmla.f32    q9, q1, d12[0]
    vld1.32     {d8}, [r1]!
    vmla.f32    q10, q0, d13[0]
    vmla.f32    q11, q1, d13[0]
    vld1.32     {d9}, [r4]!
    vmla.f32    q12, q0, d14[0]
    vmla.f32    q13, q1, d14[0]
    vld1.32     {d10}, [r5]!
    vmla.f32    q14, q0, d15[0]
    vmla.f32    q15, q1, d15[0]
    vld1.32     {d11}, [r6]!
    vld1.32     {d0-d3}, [r0]!
    vmla.f32    q8, q2, d12[1]
    vmla.f32    q9, q3, d12[1]
    vmla.f32    q10, q2, d13[1]
    vmla.f32    q11, q3, d13[1]
    vmla.f32    q12, q2, d14[1]
    vmla.f32    q13, q3, d14[1]
    vmla.f32    q14, q2, d15[1]
    vmla.f32    q15, q3, d15[1]
    vld1.32     {d4-d7}, [r0]!
    subs        r3, r3, #1
    bne         1b
8:
    vmla.f32    q8, q0, d8[0]
    vmla.f32    q9, q1, d8[0]
    vmla.f32    q10, q0, d9[0]
    vmla.f32    q11, q1, d9[0]
    vmla.f32    q12, q0, d10[0]
    vmla.f32    q13, q1, d10[0]
    vmla.f32    q14, q0, d11[0]
    vmla.f32    q15, q1, d11[0]
    vmla.f32    q8, q2, d8[1]
    vmla.f32    q9, q3, d8[1]
    vmla.f32    q10, q2, d9[1]
    vmla.f32    q11, q3, d9[1]
    vmla.f32    q12, q2, d10[1]
    vmla.f32    q13, q3, d10[1]
    vmla.f32    q14, q2, d11[1]
    vmla.f32    q15, q3, d11[1]
    b           7f
9:
    vmla.f32    q8, q0, d12[0]
    vmla.f32    q9, q1, d12[0]
    vmla.f32    q10, q0, d13[0]
    vmla.f32    q11, q1, d13[0]
    vmla.f32    q12, q0, d14[0]
    vmla.f32    q13, q1, d14[0]
    vmla.f32    q14, q0, d15[0]
    vmla.f32    q15, q1, d15[0]
    vmla.f32    q8, q2, d12[1]
    vmla.f32    q9, q3, d12[1]
    vmla.f32    q10, q2, d13[1]
    vmla.f32    q11, q3, d13[1]
    vmla.f32    q12, q2, d14[1]
    vmla.f32    q13, q3, d14[1]
    vmla.f32    q14, q2, d15[1]
    vmla.f32    q15, q3, d15[1]
7:
    vst1.32     {d16-d19}, [r12]!
    vst1.32     {d20-d23}, [r12]!
    vst1.32     {d24-d27}, [r12]!
    vst1.32     {d28-d31}, [r12]
    vpop        {d8-d15}
    pop         {r4, r5, r6, r7, pc}
    .size zf_seq_tile4x8, . - zf_seq_tile4x8


/* void zf_seq_tile4x8_k4(const float *panel, const float *a, int lda_bytes, int quads, float *acc);
 *
 * zf_seq_tile4x8 stepping k by four: each row's four k come in one quadword load, and the panel's
 * four k in four 32-byte loads, so 8 load instructions feed 32 multiply-adds where the two-step
 * loop needed 12. The panel register pair for k+2 reloads the moment k's last multiply-add has
 * issued, and k+3's the moment k+1's has. Same lanes, same order: every output sums k, k+1, k+2,
 * k+3 in turn, from what acc holds. quads >= 1; the caller does any remainder.
 */
    .global zf_seq_tile4x8_k4
    .type zf_seq_tile4x8_k4, %function
    .thumb
    .thumb_func
zf_seq_tile4x8_k4:
    push        {r4, r5, r6, r7, lr}
    vpush       {d8-d15}
    ldr         r12, [sp, #84]          /* acc */
    add         r4, r1, r2
    add         r5, r4, r2
    add         r6, r5, r2
    mov         r7, r12
    vld1.32     {d16-d19}, [r7]!
    vld1.32     {d20-d23}, [r7]!
    vld1.32     {d24-d27}, [r7]!
    vld1.32     {d28-d31}, [r7]
1:
    vld1.32     {d0-d3}, [r0]!          /* panel at k   */
    vld1.32     {d8, d9}, [r1]!         /* row 0, k..k+3 */
    vld1.32     {d10, d11}, [r4]!
    vld1.32     {d12, d13}, [r5]!
    vld1.32     {d14, d15}, [r6]!
    vld1.32     {d4-d7}, [r0]!          /* panel at k+1 */
    vmla.f32    q8, q0, d8[0]
    vmla.f32    q9, q1, d8[0]
    vmla.f32    q10, q0, d10[0]
    vmla.f32    q11, q1, d10[0]
    vmla.f32    q12, q0, d12[0]
    vmla.f32    q13, q1, d12[0]
    vmla.f32    q14, q0, d14[0]
    vmla.f32    q15, q1, d14[0]
    vld1.32     {d0-d3}, [r0]!          /* panel at k+2 */
    vmla.f32    q8, q2, d8[1]
    vmla.f32    q9, q3, d8[1]
    vmla.f32    q10, q2, d10[1]
    vmla.f32    q11, q3, d10[1]
    vmla.f32    q12, q2, d12[1]
    vmla.f32    q13, q3, d12[1]
    vmla.f32    q14, q2, d14[1]
    vmla.f32    q15, q3, d14[1]
    vld1.32     {d4-d7}, [r0]!          /* panel at k+3 */
    vmla.f32    q8, q0, d9[0]
    vmla.f32    q9, q1, d9[0]
    vmla.f32    q10, q0, d11[0]
    vmla.f32    q11, q1, d11[0]
    vmla.f32    q12, q0, d13[0]
    vmla.f32    q13, q1, d13[0]
    vmla.f32    q14, q0, d15[0]
    vmla.f32    q15, q1, d15[0]
    subs        r3, r3, #1
    vmla.f32    q8, q2, d9[1]
    vmla.f32    q9, q3, d9[1]
    vmla.f32    q10, q2, d11[1]
    vmla.f32    q11, q3, d11[1]
    vmla.f32    q12, q2, d13[1]
    vmla.f32    q13, q3, d13[1]
    vmla.f32    q14, q2, d15[1]
    vmla.f32    q15, q3, d15[1]
    bne         1b
    vst1.32     {d16-d19}, [r12]!
    vst1.32     {d20-d23}, [r12]!
    vst1.32     {d24-d27}, [r12]!
    vst1.32     {d28-d31}, [r12]
    vpop        {d8-d15}
    pop         {r4, r5, r6, r7, pc}
    .size zf_seq_tile4x8_k4, . - zf_seq_tile4x8_k4

/* void zf_seq_tile4x8_st(const float *panel, const float *a, int lda_bytes, int quads,
 *                        float *out, int ldc_bytes, int flags);
 *
 * One whole k stride of the 4x8 tile, from +0.0 to the store: zf_seq_tile4x8_k4's loop, then one
 * pair of k if flags & 2, then, if flags & 1, the fold onto what `out` holds, then the store. The
 * caller's version kept the accumulators in a stack buffer it zeroed, the loop loaded and stored,
 * and C loaded again to fold and store: 40 memory operations and two calls a tile that do no
 * arithmetic. The sums are the same: each lane starts from +0.0 (VMOV #0), takes its k in order,
 * and the fold is out + partial, one rounded addition.
 *
 * quads may be zero. The stride has to be even; an odd one stays on the caller's path.
 */
    .global zf_seq_tile4x8_st
    .type zf_seq_tile4x8_st, %function
    .thumb
    .thumb_func
zf_seq_tile4x8_st:
    push        {r4, r5, r6, r7, r8, lr}
    vpush       {d8-d15}
    add         r4, r1, r2
    add         r5, r4, r2
    add         r6, r5, r2
    vmov.i32    q8, #0
    vmov.i32    q9, #0
    vmov.i32    q10, #0
    vmov.i32    q11, #0
    vmov.i32    q12, #0
    vmov.i32    q13, #0
    vmov.i32    q14, #0
    vmov.i32    q15, #0
    cmp         r3, #0
    beq         2f
1:
    vld1.32     {d0-d3}, [r0]!
    vld1.32     {d8, d9}, [r1]!
    vld1.32     {d10, d11}, [r4]!
    vld1.32     {d12, d13}, [r5]!
    vld1.32     {d14, d15}, [r6]!
    vld1.32     {d4-d7}, [r0]!
    vmla.f32    q8, q0, d8[0]
    vmla.f32    q9, q1, d8[0]
    vmla.f32    q10, q0, d10[0]
    vmla.f32    q11, q1, d10[0]
    vmla.f32    q12, q0, d12[0]
    vmla.f32    q13, q1, d12[0]
    vmla.f32    q14, q0, d14[0]
    vmla.f32    q15, q1, d14[0]
    vld1.32     {d0-d3}, [r0]!
    vmla.f32    q8, q2, d8[1]
    vmla.f32    q9, q3, d8[1]
    vmla.f32    q10, q2, d10[1]
    vmla.f32    q11, q3, d10[1]
    vmla.f32    q12, q2, d12[1]
    vmla.f32    q13, q3, d12[1]
    vmla.f32    q14, q2, d14[1]
    vmla.f32    q15, q3, d14[1]
    vld1.32     {d4-d7}, [r0]!
    vmla.f32    q8, q0, d9[0]
    vmla.f32    q9, q1, d9[0]
    vmla.f32    q10, q0, d11[0]
    vmla.f32    q11, q1, d11[0]
    vmla.f32    q12, q0, d13[0]
    vmla.f32    q13, q1, d13[0]
    vmla.f32    q14, q0, d15[0]
    vmla.f32    q15, q1, d15[0]
    subs        r3, r3, #1
    vmla.f32    q8, q2, d9[1]
    vmla.f32    q9, q3, d9[1]
    vmla.f32    q10, q2, d11[1]
    vmla.f32    q11, q3, d11[1]
    vmla.f32    q12, q2, d13[1]
    vmla.f32    q13, q3, d13[1]
    vmla.f32    q14, q2, d15[1]
    vmla.f32    q15, q3, d15[1]
    bne         1b
2:
    ldr         r12, [sp, #88]          /* out */
    ldr         lr, [sp, #92]           /* ldc_bytes */
    ldr         r8, [sp, #96]           /* flags */
    tst         r8, #2
    beq         3f
    vld1.32     {d0-d3}, [r0]!          /* panel at k   */
    vld1.32     {d4-d7}, [r0]           /* panel at k+1 */
    vld1.32     {d8}, [r1]
    vld1.32     {d10}, [r4]
    vld1.32     {d12}, [r5]
    vld1.32     {d14}, [r6]
    vmla.f32    q8, q0, d8[0]
    vmla.f32    q9, q1, d8[0]
    vmla.f32    q10, q0, d10[0]
    vmla.f32    q11, q1, d10[0]
    vmla.f32    q12, q0, d12[0]
    vmla.f32    q13, q1, d12[0]
    vmla.f32    q14, q0, d14[0]
    vmla.f32    q15, q1, d14[0]
    vmla.f32    q8, q2, d8[1]
    vmla.f32    q9, q3, d8[1]
    vmla.f32    q10, q2, d10[1]
    vmla.f32    q11, q3, d10[1]
    vmla.f32    q12, q2, d12[1]
    vmla.f32    q13, q3, d12[1]
    vmla.f32    q14, q2, d14[1]
    vmla.f32    q15, q3, d14[1]
3:
    add         r4, r12, lr
    add         r5, r4, lr
    add         r6, r5, lr
    tst         r8, #1
    beq         4f
    vld1.32     {d0-d3}, [r12]
    vld1.32     {d4-d7}, [r4]
    vld1.32     {d8-d11}, [r5]
    vld1.32     {d12-d15}, [r6]
    vadd.f32    q8, q0, q8
    vadd.f32    q9, q1, q9
    vadd.f32    q10, q2, q10
    vadd.f32    q11, q3, q11
    vadd.f32    q12, q4, q12
    vadd.f32    q13, q5, q13
    vadd.f32    q14, q6, q14
    vadd.f32    q15, q7, q15
4:
    vst1.32     {d16-d19}, [r12]
    vst1.32     {d20-d23}, [r4]
    vst1.32     {d24-d27}, [r5]
    vst1.32     {d28-d31}, [r6]
    vpop        {d8-d15}
    pop         {r4, r5, r6, r7, r8, pc}
    .size zf_seq_tile4x8_st, . - zf_seq_tile4x8_st

    .section .note.GNU-stack, "", %progbits
