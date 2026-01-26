(module
  ;; Stockham FFT - f32 Dual-Complex Processing
  ;;
  ;; Utilizes full f32x4 SIMD throughput by processing 2 complex numbers per v128:
  ;;   [re0, im0, re1, im1] instead of [re, im, unused, unused]
  ;;
  ;; Key optimization: Pre-replicated twiddles stored as [w.re, w.im, w.re, w.im]
  ;; to eliminate runtime shuffle for twiddle broadcast.
  ;;
  ;; Memory layout (f32, 8 bytes per complex):
  ;;   0 - 32767: Primary data buffer (4096 complex numbers max)
  ;;   32768 - 65535: Secondary buffer for ping-pong
  ;;   65536+: Pre-replicated twiddle factors (16 bytes each)

  (memory (export "memory") 4)

  ;; Buffer offsets
  (global $SECONDARY_OFFSET i32 (i32.const 32768))
  (global $TWIDDLE_OFFSET i32 (i32.const 65536))

  ;; Constants for trig functions
  (global $PI f32 (f32.const 3.1415927))
  (global $HALF_PI f32 (f32.const 1.5707964))

  ;; Sign mask for dual-complex multiply: [-1, 1, -1, 1]
  (global $SIGN_MASK v128 (v128.const f32x4 -1.0 1.0 -1.0 1.0))

  ;; Conjugate mask for f32 complex: flip sign of imaginary parts [0, -0, 0, -0]
  (global $CONJ_MASK v128 (v128.const i32x4 0 0x80000000 0 0x80000000))


  ;; ============================================================================
  ;; Inline Trig Functions (Taylor Series) - Same as fft_stockham_f32.wat
  ;; ============================================================================

  (func $sin (param $x f32) (result f32)
    (local $x2 f32)
    (local $term f32)
    (local $sum f32)

    (if (f32.lt (local.get $x) (f32.neg (global.get $PI)))
      (then (local.set $x (f32.add (local.get $x) (f32.mul (f32.const 2.0) (global.get $PI))))))
    (if (f32.gt (local.get $x) (global.get $PI))
      (then (local.set $x (f32.sub (local.get $x) (f32.mul (f32.const 2.0) (global.get $PI))))))
    (if (f32.gt (local.get $x) (global.get $HALF_PI))
      (then (local.set $x (f32.sub (global.get $PI) (local.get $x)))))
    (if (f32.lt (local.get $x) (f32.neg (global.get $HALF_PI)))
      (then (local.set $x (f32.sub (f32.neg (global.get $PI)) (local.get $x)))))

    (local.set $x2 (f32.mul (local.get $x) (local.get $x)))
    (local.set $sum (local.get $x))
    (local.set $term (local.get $x))

    (local.set $term (f32.mul (local.get $term) (f32.div (local.get $x2) (f32.const -6.0))))
    (local.set $sum (f32.add (local.get $sum) (local.get $term)))
    (local.set $term (f32.mul (local.get $term) (f32.div (local.get $x2) (f32.const -20.0))))
    (local.set $sum (f32.add (local.get $sum) (local.get $term)))
    (local.set $term (f32.mul (local.get $term) (f32.div (local.get $x2) (f32.const -42.0))))
    (local.set $sum (f32.add (local.get $sum) (local.get $term)))
    (local.set $term (f32.mul (local.get $term) (f32.div (local.get $x2) (f32.const -72.0))))
    (local.set $sum (f32.add (local.get $sum) (local.get $term)))
    (local.set $term (f32.mul (local.get $term) (f32.div (local.get $x2) (f32.const -110.0))))
    (local.set $sum (f32.add (local.get $sum) (local.get $term)))

    (local.get $sum)
  )

  (func $cos (param $x f32) (result f32)
    (local $x2 f32)
    (local $term f32)
    (local $sum f32)
    (local $sign f32)

    (if (f32.lt (local.get $x) (f32.neg (global.get $PI)))
      (then (local.set $x (f32.add (local.get $x) (f32.mul (f32.const 2.0) (global.get $PI))))))
    (if (f32.gt (local.get $x) (global.get $PI))
      (then (local.set $x (f32.sub (local.get $x) (f32.mul (f32.const 2.0) (global.get $PI))))))
    (local.set $sign (f32.const 1.0))
    (if (f32.gt (local.get $x) (global.get $HALF_PI))
      (then
        (local.set $x (f32.sub (global.get $PI) (local.get $x)))
        (local.set $sign (f32.const -1.0))))
    (if (f32.lt (local.get $x) (f32.neg (global.get $HALF_PI)))
      (then
        (local.set $x (f32.add (global.get $PI) (local.get $x)))
        (local.set $sign (f32.const -1.0))))

    (local.set $x2 (f32.mul (local.get $x) (local.get $x)))
    (local.set $sum (f32.const 1.0))
    (local.set $term (f32.const 1.0))

    (local.set $term (f32.mul (local.get $term) (f32.div (local.get $x2) (f32.const -2.0))))
    (local.set $sum (f32.add (local.get $sum) (local.get $term)))
    (local.set $term (f32.mul (local.get $term) (f32.div (local.get $x2) (f32.const -12.0))))
    (local.set $sum (f32.add (local.get $sum) (local.get $term)))
    (local.set $term (f32.mul (local.get $term) (f32.div (local.get $x2) (f32.const -30.0))))
    (local.set $sum (f32.add (local.get $sum) (local.get $term)))
    (local.set $term (f32.mul (local.get $term) (f32.div (local.get $x2) (f32.const -56.0))))
    (local.set $sum (f32.add (local.get $sum) (local.get $term)))
    (local.set $term (f32.mul (local.get $term) (f32.div (local.get $x2) (f32.const -90.0))))
    (local.set $sum (f32.add (local.get $sum) (local.get $term)))

    (f32.mul (local.get $sum) (local.get $sign))
  )


  ;; ============================================================================
  ;; Pre-replicated Twiddle Computation
  ;; ============================================================================
  ;; Stores each W_N^k as [w.re, w.im, w.re, w.im] (16 bytes)
  ;; This eliminates the need for runtime shuffle to broadcast twiddles.

  (func $precompute_twiddles (export "precompute_twiddles") (param $n i32)
    (local $k i32)
    (local $angle f32)
    (local $addr i32)
    (local $neg_two_pi_over_n f32)
    (local $w_re f32)
    (local $w_im f32)

    ;; Skip for N<=4 (handled by specialized kernel)
    (if (i32.le_u (local.get $n) (i32.const 4))
      (then (return)))

    (local.set $neg_two_pi_over_n
      (f32.div
        (f32.mul (f32.const -2.0) (global.get $PI))
        (f32.convert_i32_u (local.get $n))))

    ;; Compute N twiddles, stored as pre-replicated [re, im, re, im]
    (local.set $addr (global.get $TWIDDLE_OFFSET))
    (local.set $k (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $k) (local.get $n)))
        (local.set $angle
          (f32.mul (f32.convert_i32_u (local.get $k)) (local.get $neg_two_pi_over_n)))
        (local.set $w_re (call $cos (local.get $angle)))
        (local.set $w_im (call $sin (local.get $angle)))

        ;; Store as [w.re, w.im, w.re, w.im] - pre-replicated for dual-complex
        (f32.store (local.get $addr) (local.get $w_re))
        (f32.store (i32.add (local.get $addr) (i32.const 4)) (local.get $w_im))
        (f32.store (i32.add (local.get $addr) (i32.const 8)) (local.get $w_re))
        (f32.store (i32.add (local.get $addr) (i32.const 12)) (local.get $w_im))

        (local.set $addr (i32.add (local.get $addr) (i32.const 16)))
        (local.set $k (i32.add (local.get $k) (i32.const 1)))
        (br $loop)
      )
    )
  )


  ;; ============================================================================
  ;; N=4 Specialized Kernel (minimal, can't dual-pack effectively)
  ;; ============================================================================
  ;; For N=4, we only have 4 complex numbers. We could pack them into 2 v128s
  ;; but the butterfly structure doesn't allow clean dual-processing.
  ;; Keep simple single-complex approach for this size.

  (func $fft_4
    (local $x0 v128) (local $x1 v128) (local $x2 v128) (local $x3 v128)
    (local $t0 v128) (local $t1 v128) (local $t2 v128) (local $t3 v128)

    ;; Load 4 complex values (8 bytes each)
    (local.set $x0 (v128.load64_zero (i32.const 0)))
    (local.set $x1 (v128.load64_zero (i32.const 8)))
    (local.set $x2 (v128.load64_zero (i32.const 16)))
    (local.set $x3 (v128.load64_zero (i32.const 24)))

    ;; Stage 1: butterflies (0,2) and (1,3)
    (local.set $t0 (f32x4.add (local.get $x0) (local.get $x2)))
    (local.set $t2 (f32x4.sub (local.get $x0) (local.get $x2)))
    (local.set $t1 (f32x4.add (local.get $x1) (local.get $x3)))
    (local.set $t3 (f32x4.sub (local.get $x1) (local.get $x3)))

    ;; Multiply t3 by -j: (a+bi)*(-j) = b - ai => [a,b] -> [b, -a]
    (local.set $t3
      (f32x4.mul
        (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $t3) (local.get $t3))
        (v128.const f32x4 1.0 -1.0 1.0 -1.0)))

    ;; Stage 2: final butterflies
    (v128.store64_lane 0 (i32.const 0) (f32x4.add (local.get $t0) (local.get $t1)))
    (v128.store64_lane 0 (i32.const 8) (f32x4.add (local.get $t2) (local.get $t3)))
    (v128.store64_lane 0 (i32.const 16) (f32x4.sub (local.get $t0) (local.get $t1)))
    (v128.store64_lane 0 (i32.const 24) (f32x4.sub (local.get $t2) (local.get $t3)))
  )


  ;; ============================================================================
  ;; General Dual-Complex Stockham FFT
  ;; ============================================================================
  ;; Processes 2 complex numbers per butterfly using full f32x4 SIMD
  ;; NO runtime branching in inner loops

  (func $fft_general (param $n i32)
    (local $n2 i32)
    (local $r i32)
    (local $l i32)
    (local $j i32)
    (local $k i32)
    (local $src i32)
    (local $dst i32)
    (local $tw_step i32)

    ;; SIMD values
    (local $x0 v128)
    (local $x1 v128)
    (local $w v128)
    (local $wr v128)
    (local $wi v128)
    (local $prod1 v128)
    (local $swapped v128)
    (local $tmp_v128 v128)

    ;; Pointers
    (local $i0 i32)
    (local $i1 i32)
    (local $o0 i32)
    (local $o1 i32)
    (local $r_bytes i32)
    (local $n2_bytes i32)
    (local $tw_addr i32)

    (local.set $n2 (i32.shr_u (local.get $n) (i32.const 1)))
    (local.set $n2_bytes (i32.shl (local.get $n2) (i32.const 3)))  ;; n2 * 8 bytes
    (local.set $src (i32.const 0))
    (local.set $dst (global.get $SECONDARY_OFFSET))
    (local.set $r (local.get $n2))
    (local.set $l (i32.const 1))

    (block $done_stages
      (loop $stage_loop
        (br_if $done_stages (i32.lt_u (local.get $r) (i32.const 1)))

        (local.set $r_bytes (i32.shl (local.get $r) (i32.const 3)))
        (local.set $tw_step (i32.div_u (local.get $n) (i32.shl (local.get $l) (i32.const 1))))
        (local.set $j (i32.const 0))

        ;; For r<2, use optimized dual-group processing
        (if (i32.lt_u (local.get $r) (i32.const 2))
          (then
            ;; r=1 optimized path: process 2 groups at once
            ;; Input layout for 2 groups: [A, B, C, D] where (A,B) and (C,D) are pairs
            (local.set $o0 (local.get $dst))
            (local.set $o1 (i32.add (local.get $dst) (local.get $n2_bytes)))
            (local.set $i0 (local.get $src))
            (local.set $tw_addr (global.get $TWIDDLE_OFFSET))

            ;; Process pairs of groups while we have at least 2 left
            (block $done_dual_groups
              (loop $dual_group_loop
                (br_if $done_dual_groups (i32.ge_u (i32.add (local.get $j) (i32.const 1)) (local.get $l)))

                ;; Load input: [A, B] for group j, [C, D] for group j+1
                ;; Memory: A at i0, B at i0+8, C at i0+16, D at i0+24
                (local.set $x0 (v128.load (local.get $i0)))        ;; [A, B]
                (local.set $x1 (v128.load (i32.add (local.get $i0) (i32.const 16)))) ;; [C, D]

                ;; Separate into first and second elements of each pair
                ;; first = [A, C], second = [B, D]
                (local.set $prod1 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
                                                 (local.get $x0) (local.get $x1))) ;; [A, C]
                (local.set $swapped (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31
                                                   (local.get $x0) (local.get $x1))) ;; [B, D]

                ;; Load twiddles for both groups
                ;; Twiddle j at tw_addr, twiddle j+1 at tw_addr + tw_step*16
                (local.set $w (v128.load (local.get $tw_addr)))  ;; [W_j.re, W_j.im, W_j.re, W_j.im]
                (local.set $i1 (i32.add (local.get $tw_addr) (i32.shl (local.get $tw_step) (i32.const 4))))
                (local.set $x1 (v128.load (local.get $i1)))      ;; [W_j+1.re, W_j+1.im, ...]

                ;; Build twiddle vector: [W_j, W_j+1] (both as complex pairs)
                (local.set $w (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
                                             (local.get $w) (local.get $x1)))

                ;; Multiply second elements [B, D] by respective twiddles [W_j, W_j+1]
                (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11
                                              (local.get $w) (local.get $w)))
                (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15
                                              (local.get $w) (local.get $w)))

                (local.set $x0 (f32x4.mul (local.get $swapped) (local.get $wr)))
                (local.set $x1 (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11
                                              (local.get $swapped) (local.get $swapped)))
                (local.set $x1 (f32x4.add (local.get $x0)
                  (f32x4.mul (f32x4.mul (local.get $x1) (local.get $wi)) (global.get $SIGN_MASK))))

                ;; Butterfly: result0 = first + twiddled, result1 = first - twiddled
                ;; result0 = [A+W_j*B, C+W_j+1*D], result1 = [A-W_j*B, C-W_j+1*D]
                (local.set $x0 (f32x4.add (local.get $prod1) (local.get $x1)))
                (local.set $x1 (f32x4.sub (local.get $prod1) (local.get $x1)))

                ;; Store to output: result0 goes to o0, o0+8; result1 goes to o1, o1+8
                (v128.store (local.get $o0) (local.get $x0))
                (v128.store (local.get $o1) (local.get $x1))

                ;; Advance: 2 groups processed, 32 bytes input, 16 bytes each output
                (local.set $i0 (i32.add (local.get $i0) (i32.const 32)))
                (local.set $o0 (i32.add (local.get $o0) (i32.const 16)))
                (local.set $o1 (i32.add (local.get $o1) (i32.const 16)))
                (local.set $tw_addr (i32.add (local.get $tw_addr)
                                             (i32.shl (local.get $tw_step) (i32.const 5)))) ;; 2 * tw_step * 16
                (local.set $j (i32.add (local.get $j) (i32.const 2)))
                (br $dual_group_loop)
              )
            )

            ;; Handle remaining single group if l was odd
            (if (i32.lt_u (local.get $j) (local.get $l))
              (then
                (local.set $w (v128.load (local.get $tw_addr)))
                (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 0 1 2 3 0 1 2 3
                                              (local.get $w) (local.get $w)))
                (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 4 5 6 7 4 5 6 7
                                              (local.get $w) (local.get $w)))
                (local.set $x0 (v128.load64_zero (local.get $i0)))
                (local.set $x1 (v128.load64_zero (i32.add (local.get $i0) (i32.const 8))))
                (local.set $prod1 (f32x4.mul (local.get $x1) (local.get $wr)))
                (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3
                                                   (local.get $x1) (local.get $x1)))
                (local.set $x1 (f32x4.add (local.get $prod1)
                  (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))
                (v128.store64_lane 0 (local.get $o0) (f32x4.add (local.get $x0) (local.get $x1)))
                (v128.store64_lane 0 (local.get $o1) (f32x4.sub (local.get $x0) (local.get $x1)))
              )
            )
          )
          (else
            (if (i32.eq (local.get $r) (i32.const 2))
              (then
                ;; r=2 optimized path: process 2 groups at once (4 butterflies total)
                ;; Each group has 2 elements in first half and 2 in second half
                ;; Layout per group: [A0, A1] in first half, [B0, B1] in second half
                ;; For 2 groups: i0=[A0,A1], i0+16=[B0,B1], i0+32=[C0,C1], i0+48=[D0,D1]
                (local.set $o0 (local.get $dst))
                (local.set $o1 (i32.add (local.get $dst) (local.get $n2_bytes)))
                (local.set $i0 (local.get $src))
                (local.set $tw_addr (global.get $TWIDDLE_OFFSET))

                ;; Process pairs of groups while we have at least 2 left
                (block $done_dual_groups_r2
                  (loop $dual_group_loop_r2
                    (br_if $done_dual_groups_r2 (i32.ge_u (i32.add (local.get $j) (i32.const 1)) (local.get $l)))

                    ;; Load all 4 v128s for 2 groups
                    ;; Group j: first half at i0, second half at i0+16
                    ;; Group j+1: first half at i0+32, second half at i0+48
                    (local.set $x0 (v128.load (local.get $i0)))                    ;; [A0, A1]
                    (local.set $x1 (v128.load (i32.add (local.get $i0) (i32.const 16)))) ;; [B0, B1]
                    (local.set $prod1 (v128.load (i32.add (local.get $i0) (i32.const 32)))) ;; [C0, C1]
                    (local.set $swapped (v128.load (i32.add (local.get $i0) (i32.const 48)))) ;; [D0, D1]

                    ;; Load twiddle for group j (same twiddle for both elements in group)
                    (local.set $w (v128.load (local.get $tw_addr)))
                    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11
                                                  (local.get $w) (local.get $w)))
                    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15
                                                  (local.get $w) (local.get $w)))

                    ;; Multiply B by twiddle: x1 * w
                    (local.set $tmp_v128 (f32x4.mul (local.get $x1) (local.get $wr)))
                    (local.set $x1 (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11
                                                  (local.get $x1) (local.get $x1)))
                    (local.set $x1 (f32x4.add (local.get $tmp_v128)
                      (f32x4.mul (f32x4.mul (local.get $x1) (local.get $wi)) (global.get $SIGN_MASK))))

                    ;; Butterfly for group j: store A+B*w and A-B*w
                    (v128.store (local.get $o0) (f32x4.add (local.get $x0) (local.get $x1)))
                    (v128.store (local.get $o1) (f32x4.sub (local.get $x0) (local.get $x1)))

                    ;; Load twiddle for group j+1
                    (local.set $w (v128.load (i32.add (local.get $tw_addr) (i32.shl (local.get $tw_step) (i32.const 4)))))
                    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11
                                                  (local.get $w) (local.get $w)))
                    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15
                                                  (local.get $w) (local.get $w)))

                    ;; Multiply D by twiddle: swapped * w
                    (local.set $x1 (f32x4.mul (local.get $swapped) (local.get $wr)))
                    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11
                                                       (local.get $swapped) (local.get $swapped)))
                    (local.set $swapped (f32x4.add (local.get $x1)
                      (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))

                    ;; Butterfly for group j+1: store C+D*w and C-D*w
                    (v128.store (i32.add (local.get $o0) (i32.const 16)) (f32x4.add (local.get $prod1) (local.get $swapped)))
                    (v128.store (i32.add (local.get $o1) (i32.const 16)) (f32x4.sub (local.get $prod1) (local.get $swapped)))

                    ;; Advance: 2 groups processed
                    (local.set $i0 (i32.add (local.get $i0) (i32.const 64)))   ;; 4 v128s = 64 bytes
                    (local.set $o0 (i32.add (local.get $o0) (i32.const 32)))   ;; 2 v128s output to each half
                    (local.set $o1 (i32.add (local.get $o1) (i32.const 32)))
                    (local.set $tw_addr (i32.add (local.get $tw_addr)
                                                 (i32.shl (local.get $tw_step) (i32.const 5)))) ;; 2 * tw_step * 16
                    (local.set $j (i32.add (local.get $j) (i32.const 2)))
                    (br $dual_group_loop_r2)
                  )
                )

                ;; Handle remaining single group if l was odd
                (if (i32.lt_u (local.get $j) (local.get $l))
                  (then
                    (local.set $x0 (v128.load (local.get $i0)))
                    (local.set $x1 (v128.load (i32.add (local.get $i0) (i32.const 16))))
                    (local.set $w (v128.load (local.get $tw_addr)))
                    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11
                                                  (local.get $w) (local.get $w)))
                    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15
                                                  (local.get $w) (local.get $w)))
                    (local.set $prod1 (f32x4.mul (local.get $x1) (local.get $wr)))
                    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11
                                                       (local.get $x1) (local.get $x1)))
                    (local.set $x1 (f32x4.add (local.get $prod1)
                      (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))
                    (v128.store (local.get $o0) (f32x4.add (local.get $x0) (local.get $x1)))
                    (v128.store (local.get $o1) (f32x4.sub (local.get $x0) (local.get $x1)))
                  )
                )
              )
              (else
                ;; Dual-complex path (r>=4): process 2 butterflies at a time
                ;; Initialize pointers once per stage (like original algorithm)
                (local.set $o0 (local.get $dst))
                (local.set $o1 (i32.add (local.get $dst) (local.get $n2_bytes)))
                (local.set $i0 (local.get $src))
                (local.set $tw_addr (global.get $TWIDDLE_OFFSET))

            (block $done_groups
              (loop $group_loop
                (br_if $done_groups (i32.ge_u (local.get $j) (local.get $l)))

                ;; Load pre-replicated twiddle (16 bytes: [w.re, w.im, w.re, w.im])
                (local.set $w (v128.load (local.get $tw_addr)))

                ;; Prepare broadcast twiddle components for dual-complex multiply
                (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11
                                              (local.get $w) (local.get $w)))
                (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15
                                              (local.get $w) (local.get $w)))

                ;; i1 offset is r_bytes (not n2_bytes!)
                (local.set $i1 (i32.add (local.get $i0) (local.get $r_bytes)))
                (local.set $k (i32.const 0))

                (block $done_pairs
                  (loop $pair_loop
                    (br_if $done_pairs (i32.ge_u (local.get $k) (local.get $r)))

                    ;; Load dual-packed inputs (2 complex from each half)
                    (local.set $x0 (v128.load (local.get $i0)))
                    (local.set $x1 (v128.load (local.get $i1)))

                    ;; Inline dual-complex multiply: x1 * w
                    (local.set $prod1 (f32x4.mul (local.get $x1) (local.get $wr)))
                    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11
                                                       (local.get $x1) (local.get $x1)))
                    (local.set $x1
                      (f32x4.add
                        (local.get $prod1)
                        (f32x4.mul
                          (f32x4.mul (local.get $swapped) (local.get $wi))
                          (global.get $SIGN_MASK))))

                    ;; Butterfly and store
                    (v128.store (local.get $o0) (f32x4.add (local.get $x0) (local.get $x1)))
                    (v128.store (local.get $o1) (f32x4.sub (local.get $x0) (local.get $x1)))

                    ;; Advance pointers by 16 bytes (2 complex numbers)
                    (local.set $i0 (i32.add (local.get $i0) (i32.const 16)))
                    (local.set $i1 (i32.add (local.get $i1) (i32.const 16)))
                    (local.set $o0 (i32.add (local.get $o0) (i32.const 16)))
                    (local.set $o1 (i32.add (local.get $o1) (i32.const 16)))

                    (local.set $k (i32.add (local.get $k) (i32.const 2)))
                    (br $pair_loop)
                  )
                )

                ;; Skip over second half of input for next group
                (local.set $i0 (i32.add (local.get $i0) (local.get $r_bytes)))
                ;; Advance twiddle for next group (16 bytes per twiddle * tw_step)
                (local.set $tw_addr (i32.add (local.get $tw_addr)
                                             (i32.shl (local.get $tw_step) (i32.const 4))))
                (local.set $j (i32.add (local.get $j) (i32.const 1)))
                (br $group_loop)
              )
            )
          )
            )
          )
        )

        ;; Swap buffers
        (if (i32.eq (local.get $src) (i32.const 0))
          (then
            (local.set $src (global.get $SECONDARY_OFFSET))
            (local.set $dst (i32.const 0)))
          (else
            (local.set $src (i32.const 0))
            (local.set $dst (global.get $SECONDARY_OFFSET))))

        (local.set $r (i32.shr_u (local.get $r) (i32.const 1)))
        (local.set $l (i32.shl (local.get $l) (i32.const 1)))
        (br $stage_loop)
      )
    )

    ;; Copy result to primary buffer if needed
    (if (i32.ne (local.get $src) (i32.const 0))
      (then
        (call $copy_buffer (local.get $n))))
  )


  ;; ============================================================================
  ;; Buffer Copy (when result is in secondary buffer)
  ;; ============================================================================

  (func $copy_buffer (param $n i32)
    (local $i i32)
    (local $bytes i32)
    (local $src i32)

    (local.set $bytes (i32.shl (local.get $n) (i32.const 3)))
    (local.set $src (global.get $SECONDARY_OFFSET))
    (local.set $i (i32.const 0))

    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $i) (local.get $bytes)))
        (v128.store (local.get $i)
          (v128.load (i32.add (local.get $src) (local.get $i))))
        (local.set $i (i32.add (local.get $i) (i32.const 16)))
        (br $loop)
      )
    )
  )


  ;; ============================================================================
  ;; Conjugate Buffer (flip sign of all imaginary parts)
  ;; ============================================================================
  ;; Used for IFFT: IFFT(X) = (1/N) * conj(FFT(conj(X)))

  (func $conjugate_buffer (param $n i32)
    (local $i i32)
    (local $bytes i32)

    (local.set $bytes (i32.shl (local.get $n) (i32.const 3)))  ;; n * 8 bytes
    (local.set $i (i32.const 0))

    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $i) (local.get $bytes)))
        (v128.store (local.get $i)
          (v128.xor (v128.load (local.get $i)) (global.get $CONJ_MASK)))
        (local.set $i (i32.add (local.get $i) (i32.const 16)))
        (br $loop)
      )
    )
  )


  ;; ============================================================================
  ;; Scale and Conjugate Buffer (multiply by 1/N and conjugate)
  ;; ============================================================================
  ;; Fused operation for IFFT: conj(FFT(conj(X))) / N
  ;; Both conjugate and scale in one pass for cache efficiency.

  (func $scale_and_conjugate (param $n i32)
    (local $i i32)
    (local $bytes i32)
    (local $inv_n v128)
    (local $v v128)

    (local.set $bytes (i32.shl (local.get $n) (i32.const 3)))  ;; n * 8 bytes
    (local.set $inv_n (f32x4.splat (f32.div (f32.const 1.0) (f32.convert_i32_u (local.get $n)))))
    (local.set $i (i32.const 0))

    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $i) (local.get $bytes)))
        ;; Load, conjugate (XOR sign bits), scale (multiply by 1/N)
        (local.set $v (v128.xor (v128.load (local.get $i)) (global.get $CONJ_MASK)))
        (v128.store (local.get $i) (f32x4.mul (local.get $v) (local.get $inv_n)))
        (local.set $i (i32.add (local.get $i) (i32.const 16)))
        (br $loop)
      )
    )
  )


  ;; ============================================================================
  ;; N=4 Inverse FFT Kernel
  ;; ============================================================================
  ;; IFFT-4: Same structure as FFT-4 but with +j instead of -j, then scale.
  ;; (a+bi)*(+j) = -b + ai => [a,b] -> [-b, a]

  (func $ifft_4
    (local $x0 v128) (local $x1 v128) (local $x2 v128) (local $x3 v128)
    (local $t0 v128) (local $t1 v128) (local $t2 v128) (local $t3 v128)
    (local $inv_n v128)

    (local.set $inv_n (v128.const f32x4 0.25 0.25 0.25 0.25))

    ;; Load 4 complex values (8 bytes each)
    (local.set $x0 (v128.load64_zero (i32.const 0)))
    (local.set $x1 (v128.load64_zero (i32.const 8)))
    (local.set $x2 (v128.load64_zero (i32.const 16)))
    (local.set $x3 (v128.load64_zero (i32.const 24)))

    ;; Stage 1: butterflies (0,2) and (1,3)
    (local.set $t0 (f32x4.add (local.get $x0) (local.get $x2)))
    (local.set $t2 (f32x4.sub (local.get $x0) (local.get $x2)))
    (local.set $t1 (f32x4.add (local.get $x1) (local.get $x3)))
    (local.set $t3 (f32x4.sub (local.get $x1) (local.get $x3)))

    ;; Multiply t3 by +j (conjugate of -j): (a+bi)*(+j) = -b + ai => [a,b] -> [-b, a]
    (local.set $t3
      (f32x4.mul
        (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $t3) (local.get $t3))
        (v128.const f32x4 -1.0 1.0 -1.0 1.0)))

    ;; Stage 2: final butterflies with scaling
    (v128.store64_lane 0 (i32.const 0)
      (f32x4.mul (f32x4.add (local.get $t0) (local.get $t1)) (local.get $inv_n)))
    (v128.store64_lane 0 (i32.const 8)
      (f32x4.mul (f32x4.add (local.get $t2) (local.get $t3)) (local.get $inv_n)))
    (v128.store64_lane 0 (i32.const 16)
      (f32x4.mul (f32x4.sub (local.get $t0) (local.get $t1)) (local.get $inv_n)))
    (v128.store64_lane 0 (i32.const 24)
      (f32x4.mul (f32x4.sub (local.get $t2) (local.get $t3)) (local.get $inv_n)))
  )


  ;; ============================================================================
  ;; Main FFT Entry Point
  ;; ============================================================================

  (func (export "fft") (param $n i32)
    (if (i32.eq (local.get $n) (i32.const 4))
      (then (call $fft_4) (return)))
    ;; For now, use general kernel for all sizes > 4
    ;; Specialized codelets for N=8,16 can be added after verifying correctness
    (call $fft_general (local.get $n))
  )


  ;; ============================================================================
  ;; Main IFFT Entry Point
  ;; ============================================================================
  ;; IFFT(X) = (1/N) * conj(FFT(conj(X)))
  ;;
  ;; This is mathematically equivalent to running FFT with conjugate twiddles,
  ;; but avoids storing separate twiddle tables by using the identity above.
  ;;
  ;; For N=4, we use a specialized kernel with fused scaling.
  ;; For larger N:
  ;;   1. Conjugate input buffer (XOR sign bits of imaginary parts)
  ;;   2. Run forward FFT
  ;;   3. Conjugate output and scale by 1/N (fused for cache efficiency)

  (func (export "ifft") (param $n i32)
    ;; N=4: use specialized kernel with fused scaling
    (if (i32.eq (local.get $n) (i32.const 4))
      (then (call $ifft_4) (return)))

    ;; General case: conj -> FFT -> conj+scale
    (call $conjugate_buffer (local.get $n))
    (call $fft_general (local.get $n))
    (call $scale_and_conjugate (local.get $n))
  )
)
