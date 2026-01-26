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

        ;; For r<4, use single-element processing (dual requires at least 2 pairs = 4 elements)
        (if (i32.lt_u (local.get $r) (i32.const 4))
          (then
            ;; Single-element path (matches original algorithm exactly)
            ;; Initialize output pointers once per stage
            (local.set $o0 (local.get $dst))
            (local.set $o1 (i32.add (local.get $dst) (local.get $n2_bytes)))
            (local.set $i0 (local.get $src))
            (local.set $tw_addr (global.get $TWIDDLE_OFFSET))

            (block $done_groups_single
              (loop $group_loop_single
                (br_if $done_groups_single (i32.ge_u (local.get $j) (local.get $l)))

                ;; Load twiddle for this group
                (local.set $w (v128.load (local.get $tw_addr)))

                ;; Prepare single-complex twiddle broadcast
                (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 0 1 2 3 0 1 2 3
                                              (local.get $w) (local.get $w)))
                (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 4 5 6 7 4 5 6 7
                                              (local.get $w) (local.get $w)))

                ;; i1 offset is r_bytes, not n2_bytes!
                (local.set $i1 (i32.add (local.get $i0) (local.get $r_bytes)))
                (local.set $k (i32.const 0))

                (block $done_k_single
                  (loop $k_loop_single
                    (br_if $done_k_single (i32.ge_u (local.get $k) (local.get $r)))

                    ;; Load single complex
                    (local.set $x0 (v128.load64_zero (local.get $i0)))
                    (local.set $x1 (v128.load64_zero (local.get $i1)))

                    ;; Single-complex multiply: x1 * w
                    (local.set $prod1 (f32x4.mul (local.get $x1) (local.get $wr)))
                    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3
                                                       (local.get $x1) (local.get $x1)))
                    (local.set $x1
                      (f32x4.add
                        (local.get $prod1)
                        (f32x4.mul
                          (f32x4.mul (local.get $swapped) (local.get $wi))
                          (global.get $SIGN_MASK))))

                    ;; Butterfly and store
                    (v128.store64_lane 0 (local.get $o0) (f32x4.add (local.get $x0) (local.get $x1)))
                    (v128.store64_lane 0 (local.get $o1) (f32x4.sub (local.get $x0) (local.get $x1)))

                    ;; Advance pointers by 8 bytes (1 complex)
                    (local.set $i0 (i32.add (local.get $i0) (i32.const 8)))
                    (local.set $i1 (i32.add (local.get $i1) (i32.const 8)))
                    (local.set $o0 (i32.add (local.get $o0) (i32.const 8)))
                    (local.set $o1 (i32.add (local.get $o1) (i32.const 8)))

                    (local.set $k (i32.add (local.get $k) (i32.const 1)))
                    (br $k_loop_single)
                  )
                )

                ;; Skip over second half of input for next group
                (local.set $i0 (i32.add (local.get $i0) (local.get $r_bytes)))
                ;; Advance twiddle for next group (16 bytes per twiddle * tw_step)
                (local.set $tw_addr (i32.add (local.get $tw_addr)
                                             (i32.shl (local.get $tw_step) (i32.const 4))))
                (local.set $j (i32.add (local.get $j) (i32.const 1)))
                (br $group_loop_single)
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
  ;; Main FFT Entry Point
  ;; ============================================================================

  (func (export "fft") (param $n i32)
    (if (i32.eq (local.get $n) (i32.const 4))
      (then (call $fft_4) (return)))
    ;; For now, use general kernel for all sizes > 4
    ;; Specialized codelets for N=8,16 can be added after verifying correctness
    (call $fft_general (local.get $n))
  )
)
