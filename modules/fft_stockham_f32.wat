(module
  ;; Stockham FFT - f32 (Single Precision) with SIMD
  ;;
  ;; Uses f32x4 SIMD for complex arithmetic. Algorithm matches the f64 version.
  ;;
  ;; Memory layout (f32, 8 bytes per complex):
  ;;   0 - 32767: Primary data buffer (4096 complex numbers max)
  ;;   32768 - 65535: Secondary buffer for ping-pong
  ;;   65536+: Twiddle factors

  (memory (export "memory") 2)

  ;; Buffer offsets
  (global $SECONDARY_OFFSET i32 (i32.const 32768))
  (global $TWIDDLE_OFFSET i32 (i32.const 65536))

  ;; Constants for trig functions
  (global $PI f32 (f32.const 3.1415927))
  (global $HALF_PI f32 (f32.const 1.5707964))

  ;; SIMD sign mask for f32 complex multiply
  (global $SIGN_MASK_F32 v128 (v128.const f32x4 1.0 -1.0 1.0 -1.0))


  ;; ============================================================================
  ;; SIMD Complex Multiply for f32
  ;; ============================================================================
  ;; Input: a = [a.re, a.im, ?, ?], b = [b.re, b.im, ?, ?]
  ;; Output: [a.re*b.re - a.im*b.im, a.re*b.im + a.im*b.re, ?, ?]
  (func $simd_cmul_f32 (param $a v128) (param $b v128) (result v128)
    (local $br v128)
    (local $bi v128)
    (local $prod1 v128)

    ;; br = [b.re, b.re, ?, ?]
    (local.set $br (i8x16.shuffle 0 1 2 3 0 1 2 3 0 1 2 3 0 1 2 3
                                  (local.get $b) (local.get $b)))

    ;; bi = [b.im, b.im, ?, ?]
    (local.set $bi (i8x16.shuffle 4 5 6 7 4 5 6 7 4 5 6 7 4 5 6 7
                                  (local.get $b) (local.get $b)))

    ;; prod1 = [a.re * b.re, a.im * b.re, ?, ?]
    (local.set $prod1 (f32x4.mul (local.get $a) (local.get $br)))

    ;; Swap a: [a.im, a.re, ?, ?], multiply by bi, apply sign mask
    ;; Result: [a.im*b.im, a.re*b.im, ?, ?] * [1, -1, 1, -1] = [a.im*b.im, -a.re*b.im, ?, ?]
    ;; Wait, we need [-a.im*b.im, a.re*b.im] to get correct result
    ;; Let's use: swap a, mul by bi, mul by [-1, 1, -1, 1]
    (f32x4.add
      (local.get $prod1)
      (f32x4.mul
        (f32x4.mul
          (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $a) (local.get $a))
          (local.get $bi))
        (v128.const f32x4 -1.0 1.0 -1.0 1.0)))
  )


  ;; ============================================================================
  ;; Inline Trig Functions (Taylor Series)
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
  ;; Twiddle Precomputation
  ;; ============================================================================

  (func $precompute_twiddles (export "precompute_twiddles") (param $n i32)
    (local $k i32)
    (local $angle f32)
    (local $addr i32)
    (local $neg_two_pi_over_n f32)

    ;; Skip for N<=4 (handled by specialized kernel)
    (if (i32.le_u (local.get $n) (i32.const 4))
      (then (return)))

    (local.set $neg_two_pi_over_n
      (f32.div
        (f32.mul (f32.const -2.0) (global.get $PI))
        (f32.convert_i32_u (local.get $n))))

    ;; Compute N twiddles (matching f64 version)
    (local.set $addr (global.get $TWIDDLE_OFFSET))
    (local.set $k (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $k) (local.get $n)))
        (local.set $angle
          (f32.mul (f32.convert_i32_u (local.get $k)) (local.get $neg_two_pi_over_n)))
        (f32.store (local.get $addr) (call $cos (local.get $angle)))
        (f32.store (i32.add (local.get $addr) (i32.const 4)) (call $sin (local.get $angle)))
        (local.set $addr (i32.add (local.get $addr) (i32.const 8)))
        (local.set $k (i32.add (local.get $k) (i32.const 1)))
        (br $loop)
      )
    )
  )


  ;; ============================================================================
  ;; N=4 Specialized Kernel
  ;; ============================================================================

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
  ;; General FFT (matches f64 algorithm structure)
  ;; ============================================================================

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

    ;; LSR pointers
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

        ;; r_bytes = r * 8
        (local.set $r_bytes (i32.shl (local.get $r) (i32.const 3)))
        (local.set $tw_step (i32.div_u (local.get $n) (i32.shl (local.get $l) (i32.const 1))))
        (local.set $tw_addr (global.get $TWIDDLE_OFFSET))
        (local.set $j (i32.const 0))

        ;; Initialize output pointers
        (local.set $o0 (local.get $dst))
        (local.set $o1 (i32.add (local.get $dst) (local.get $n2_bytes)))
        (local.set $i0 (local.get $src))

        (block $done_groups
          (loop $group_loop
            (br_if $done_groups (i32.ge_u (local.get $j) (local.get $l)))

            ;; Load twiddle once per group (all butterflies in group use same twiddle)
            (local.set $w (v128.load64_zero (local.get $tw_addr)))
            (local.set $i1 (i32.add (local.get $i0) (local.get $r_bytes)))
            (local.set $k (i32.const 0))

            (block $done_butterflies
              (loop $butterfly_loop
                (br_if $done_butterflies (i32.ge_u (local.get $k) (local.get $r)))

                (local.set $x0 (v128.load64_zero (local.get $i0)))
                (local.set $x1 (v128.load64_zero (local.get $i1)))
                (local.set $x1 (call $simd_cmul_f32 (local.get $x1) (local.get $w)))
                (v128.store64_lane 0 (local.get $o0) (f32x4.add (local.get $x0) (local.get $x1)))
                (v128.store64_lane 0 (local.get $o1) (f32x4.sub (local.get $x0) (local.get $x1)))

                ;; LSR: increment pointers by 8 bytes (one f32 complex)
                (local.set $i0 (i32.add (local.get $i0) (i32.const 8)))
                (local.set $i1 (i32.add (local.get $i1) (i32.const 8)))
                (local.set $o0 (i32.add (local.get $o0) (i32.const 8)))
                (local.set $o1 (i32.add (local.get $o1) (i32.const 8)))

                (local.set $k (i32.add (local.get $k) (i32.const 1)))
                (br $butterfly_loop)
              )
            )

            ;; Skip over second half of input for next group
            (local.set $i0 (i32.add (local.get $i0) (local.get $r_bytes)))
            ;; Advance twiddle for next group
            (local.set $tw_addr (i32.add (local.get $tw_addr) (i32.shl (local.get $tw_step) (i32.const 3))))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $group_loop)
          )
        )

        ;; Swap buffers
        (if (i32.eq (local.get $src) (i32.const 0))
          (then
            (local.set $src (global.get $SECONDARY_OFFSET))
            (local.set $dst (i32.const 0))
          )
          (else
            (local.set $src (i32.const 0))
            (local.set $dst (global.get $SECONDARY_OFFSET))
          )
        )

        (local.set $r (i32.shr_u (local.get $r) (i32.const 1)))
        (local.set $l (i32.shl (local.get $l) (i32.const 1)))
        (br $stage_loop)
      )
    )

    ;; Copy result back if needed
    (if (i32.ne (local.get $src) (i32.const 0))
      (then
        (local.set $i0 (global.get $SECONDARY_OFFSET))
        (local.set $o0 (i32.const 0))
        (local.set $k (i32.const 0))
        (block $done_copy
          (loop $copy_loop
            (br_if $done_copy (i32.ge_u (local.get $k) (local.get $n)))
            ;; Copy 2 complex at once (16 bytes) when possible
            (if (i32.le_u (i32.add (local.get $k) (i32.const 2)) (local.get $n))
              (then
                (v128.store (local.get $o0) (v128.load (local.get $i0)))
                (local.set $i0 (i32.add (local.get $i0) (i32.const 16)))
                (local.set $o0 (i32.add (local.get $o0) (i32.const 16)))
                (local.set $k (i32.add (local.get $k) (i32.const 2)))
              )
              (else
                (v128.store64_lane 0 (local.get $o0) (v128.load64_zero (local.get $i0)))
                (local.set $i0 (i32.add (local.get $i0) (i32.const 8)))
                (local.set $o0 (i32.add (local.get $o0) (i32.const 8)))
                (local.set $k (i32.add (local.get $k) (i32.const 1)))
              )
            )
            (br $copy_loop)
          )
        )
      )
    )
  )


  ;; ============================================================================
  ;; Main Entry Point
  ;; ============================================================================

  (func $fft_stockham (export "fft_stockham") (param $n i32)
    ;; N=4: use specialized kernel
    (if (i32.eq (local.get $n) (i32.const 4))
      (then (call $fft_4) (return)))
    ;; N>=8: use general algorithm
    (call $fft_general (local.get $n))
  )
) ;; end module
