(module
  ;; Real FFT - f32 Dual-Complex Processing
  ;;
  ;; Combines the +105% dual-complex f32 FFT with real FFT post-processing.
  ;; Utilizes full f32x4 SIMD throughput by processing 2 complex numbers per v128.
  ;;
  ;; Algorithm:
  ;; 1. N real values are treated as N/2 complex: z[k] = x[2k] + i*x[2k+1]
  ;; 2. Run N/2-point dual-complex Stockham FFT
  ;; 3. Post-process to get real FFT output
  ;;
  ;; Memory layout (f32, 8 bytes per complex):
  ;;   0 - 32767: Primary data buffer (input real / output complex)
  ;;   32768 - 65535: Secondary buffer for ping-pong
  ;;   65536 - 131071: Pre-replicated FFT twiddles (16 bytes each: [w.re, w.im, w.re, w.im])
  ;;   131072+: RFFT post-processing twiddles (8 bytes each: [w.re, w.im])

  (memory (export "memory") 4)

  ;; Buffer offsets
  (global $SECONDARY_OFFSET i32 (i32.const 32768))
  (global $TWIDDLE_OFFSET i32 (i32.const 65536))
  (global $RFFT_TWIDDLE_OFFSET i32 (i32.const 131072))

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
  ;; N=8 Dual-Complex Kernel
  ;; ============================================================================
  ;; 8 complex numbers = 4 dual-packed v128 values
  ;; Process 2 radix-4 butterflies simultaneously

  (func $fft_8
    (local $d0 v128) (local $d1 v128) (local $d2 v128) (local $d3 v128)
    (local $t0 v128) (local $t1 v128) (local $t2 v128) (local $t3 v128)
    (local $u0 v128) (local $u1 v128) (local $u2 v128) (local $u3 v128)
    (local $w v128)
    (local $wr v128) (local $wi v128)
    (local $prod1 v128) (local $swapped v128)

    ;; Load 8 complex as 4 dual-packed v128
    ;; d0 = [x0.re, x0.im, x1.re, x1.im]
    ;; d1 = [x2.re, x2.im, x3.re, x3.im]
    ;; d2 = [x4.re, x4.im, x5.re, x5.im]
    ;; d3 = [x6.re, x6.im, x7.re, x7.im]
    (local.set $d0 (v128.load (i32.const 0)))
    (local.set $d1 (v128.load (i32.const 16)))
    (local.set $d2 (v128.load (i32.const 32)))
    (local.set $d3 (v128.load (i32.const 48)))

    ;; ============ Stage 1: r=4 butterflies ============
    ;; Butterfly (0,4) and (1,5): d0 +/- d2
    (local.set $t0 (f32x4.add (local.get $d0) (local.get $d2)))
    (local.set $t2 (f32x4.sub (local.get $d0) (local.get $d2)))

    ;; Butterfly (2,6) and (3,7): d1 +/- d3
    (local.set $t1 (f32x4.add (local.get $d1) (local.get $d3)))
    (local.set $t3 (f32x4.sub (local.get $d1) (local.get $d3)))

    ;; Apply W_8^0=1 to t2 (already done, W=1)
    ;; Apply W_8^2=-j to t3: multiply by -j swaps and negates
    ;; -j * (a+bi) = b - ai => [re, im] -> [im, -re]
    (local.set $t3
      (f32x4.mul
        (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $t3) (local.get $t3))
        (v128.const f32x4 1.0 -1.0 1.0 -1.0)))

    ;; ============ Stage 2: r=2 butterflies ============
    ;; Now we have:
    ;; t0 = [y0, y1], t1 = [y2, y3], t2 = [y4, y5], t3 = [y6, y7]
    ;; Need butterflies: (y0,y2), (y1,y3), (y4,y6), (y5,y7)

    ;; For (y0,y2) and (y1,y3): t0 +/- t1
    (local.set $u0 (f32x4.add (local.get $t0) (local.get $t1)))
    (local.set $u1 (f32x4.sub (local.get $t0) (local.get $t1)))

    ;; For (y4,y6) with W_8^0=1 and (y5,y7) with W_8^1
    ;; W_8^1 = cos(-pi/4) + i*sin(-pi/4) = (sqrt2/2, -sqrt2/2)
    ;; First: t2 + t3*W and t2 - t3*W

    ;; Multiply t3 by W_8^1 = [0.7071068, -0.7071068, 0.7071068, -0.7071068]
    ;; Using inline dual-complex multiply
    (local.set $w (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))

    ;; Broadcast w.re -> [w.re, w.re, w.re, w.re]
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11
                                  (local.get $w) (local.get $w)))
    ;; Broadcast w.im -> [w.im, w.im, w.im, w.im]
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15
                                  (local.get $w) (local.get $w)))

    ;; prod1 = t3 * w.re
    (local.set $prod1 (f32x4.mul (local.get $t3) (local.get $wr)))

    ;; swapped = [t3.im, t3.re, ...] (swap re/im pairs)
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11
                                       (local.get $t3) (local.get $t3)))

    ;; t3 * W = prod1 + swapped * wi * [-1, 1, -1, 1]
    (local.set $t3
      (f32x4.add
        (local.get $prod1)
        (f32x4.mul
          (f32x4.mul (local.get $swapped) (local.get $wi))
          (global.get $SIGN_MASK))))

    (local.set $u2 (f32x4.add (local.get $t2) (local.get $t3)))
    (local.set $u3 (f32x4.sub (local.get $t2) (local.get $t3)))

    ;; ============ Final bit-reversal output ============
    ;; Output order for N=8 DIF: 0,4,2,6,1,5,3,7
    ;; u0 = [y0, y1] -> output positions 0,4
    ;; u1 = [y2, y3] -> output positions 2,6
    ;; u2 = [y4, y5] -> output positions 1,5
    ;; u3 = [y6, y7] -> output positions 3,7

    ;; We need to interleave: [y0,y4], [y1,y5], [y2,y6], [y3,y7]
    ;; Which is: u0[0],u2[0], u0[1],u2[1], u1[0],u3[0], u1[1],u3[1]

    ;; Output [y0, y4]: low halves of u0 and u2
    (v128.store (i32.const 0)
      (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
                     (local.get $u0) (local.get $u2)))

    ;; Output [y1, y5]: high halves of u0 and u2
    (v128.store (i32.const 16)
      (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31
                     (local.get $u0) (local.get $u2)))

    ;; Output [y2, y6]: low halves of u1 and u3
    (v128.store (i32.const 32)
      (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
                     (local.get $u1) (local.get $u3)))

    ;; Output [y3, y7]: high halves of u1 and u3
    (v128.store (i32.const 48)
      (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31
                     (local.get $u1) (local.get $u3)))
  )


  ;; ============================================================================
  ;; N=16 Dual-Complex Kernel
  ;; ============================================================================
  ;; 16 complex numbers = 8 dual-packed v128 values
  ;; Fully unrolled with hardcoded twiddles

  (func $fft_16
    (local $d0 v128) (local $d1 v128) (local $d2 v128) (local $d3 v128)
    (local $d4 v128) (local $d5 v128) (local $d6 v128) (local $d7 v128)
    (local $t0 v128) (local $t1 v128) (local $t2 v128) (local $t3 v128)
    (local $t4 v128) (local $t5 v128) (local $t6 v128) (local $t7 v128)
    (local $u0 v128) (local $u1 v128) (local $u2 v128) (local $u3 v128)
    (local $u4 v128) (local $u5 v128) (local $u6 v128) (local $u7 v128)
    (local $w v128)
    (local $wr v128) (local $wi v128)
    (local $prod1 v128) (local $swapped v128)

    ;; Load 16 complex as 8 dual-packed v128
    (local.set $d0 (v128.load (i32.const 0)))    ;; [x0, x1]
    (local.set $d1 (v128.load (i32.const 16)))   ;; [x2, x3]
    (local.set $d2 (v128.load (i32.const 32)))   ;; [x4, x5]
    (local.set $d3 (v128.load (i32.const 48)))   ;; [x6, x7]
    (local.set $d4 (v128.load (i32.const 64)))   ;; [x8, x9]
    (local.set $d5 (v128.load (i32.const 80)))   ;; [x10, x11]
    (local.set $d6 (v128.load (i32.const 96)))   ;; [x12, x13]
    (local.set $d7 (v128.load (i32.const 112)))  ;; [x14, x15]

    ;; ============ Stage 1: r=8 butterflies ============
    ;; (0,8), (1,9), (2,10), (3,11), (4,12), (5,13), (6,14), (7,15)
    ;; Groups: d0+-d4, d1+-d5, d2+-d6, d3+-d7

    (local.set $t0 (f32x4.add (local.get $d0) (local.get $d4)))
    (local.set $t4 (f32x4.sub (local.get $d0) (local.get $d4)))
    (local.set $t1 (f32x4.add (local.get $d1) (local.get $d5)))
    (local.set $t5 (f32x4.sub (local.get $d1) (local.get $d5)))
    (local.set $t2 (f32x4.add (local.get $d2) (local.get $d6)))
    (local.set $t6 (f32x4.sub (local.get $d2) (local.get $d6)))
    (local.set $t3 (f32x4.add (local.get $d3) (local.get $d7)))
    (local.set $t7 (f32x4.sub (local.get $d3) (local.get $d7)))

    ;; Apply twiddles to t4-t7 (lower half gets W_16^k)
    ;; t4 *= W_16^0 = 1 (no-op)
    ;; t5 *= W_16^2 = (0.7071068, -0.7071068)
    ;; t6 *= W_16^4 = -j = (0, -1)
    ;; t7 *= W_16^6 = (-0.7071068, -0.7071068)

    ;; t5 *= W_16^2
    (local.set $w (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $w) (local.get $w)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $w) (local.get $w)))
    (local.set $prod1 (f32x4.mul (local.get $t5) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $t5) (local.get $t5)))
    (local.set $t5 (f32x4.add (local.get $prod1) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))

    ;; t6 *= W_16^4 = -j: [re,im] -> [im, -re]
    (local.set $t6 (f32x4.mul
      (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $t6) (local.get $t6))
      (v128.const f32x4 1.0 -1.0 1.0 -1.0)))

    ;; t7 *= W_16^6
    (local.set $w (v128.const f32x4 -0.7071068 -0.7071068 -0.7071068 -0.7071068))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $w) (local.get $w)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $w) (local.get $w)))
    (local.set $prod1 (f32x4.mul (local.get $t7) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $t7) (local.get $t7)))
    (local.set $t7 (f32x4.add (local.get $prod1) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))

    ;; ============ Stage 2: r=4 butterflies ============
    ;; Upper half: t0,t1,t2,t3 -> (0,4), (1,5), (2,6), (3,7)
    ;; Lower half: t4,t5,t6,t7 -> (8,12), (9,13), (10,14), (11,15)

    (local.set $u0 (f32x4.add (local.get $t0) (local.get $t2)))
    (local.set $u2 (f32x4.sub (local.get $t0) (local.get $t2)))
    (local.set $u1 (f32x4.add (local.get $t1) (local.get $t3)))
    (local.set $u3 (f32x4.sub (local.get $t1) (local.get $t3)))

    ;; u3 *= -j
    (local.set $u3 (f32x4.mul
      (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $u3) (local.get $u3))
      (v128.const f32x4 1.0 -1.0 1.0 -1.0)))

    (local.set $u4 (f32x4.add (local.get $t4) (local.get $t6)))
    (local.set $u6 (f32x4.sub (local.get $t4) (local.get $t6)))
    (local.set $u5 (f32x4.add (local.get $t5) (local.get $t7)))
    (local.set $u7 (f32x4.sub (local.get $t5) (local.get $t7)))

    ;; u7 *= -j
    (local.set $u7 (f32x4.mul
      (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $u7) (local.get $u7))
      (v128.const f32x4 1.0 -1.0 1.0 -1.0)))

    ;; ============ Stage 3: r=2 butterflies ============
    ;; Reuse d variables for final stage

    (local.set $d0 (f32x4.add (local.get $u0) (local.get $u1)))
    (local.set $d1 (f32x4.sub (local.get $u0) (local.get $u1)))

    ;; u5 *= W_8^1 = (0.7071068, -0.7071068)
    (local.set $w (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $w) (local.get $w)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $w) (local.get $w)))
    (local.set $prod1 (f32x4.mul (local.get $u5) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $u5) (local.get $u5)))
    (local.set $u5 (f32x4.add (local.get $prod1) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))

    (local.set $d2 (f32x4.add (local.get $u4) (local.get $u5)))
    (local.set $d3 (f32x4.sub (local.get $u4) (local.get $u5)))

    (local.set $d4 (f32x4.add (local.get $u2) (local.get $u3)))
    (local.set $d5 (f32x4.sub (local.get $u2) (local.get $u3)))

    ;; u7 *= W_8^1
    (local.set $prod1 (f32x4.mul (local.get $u7) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $u7) (local.get $u7)))
    (local.set $u7 (f32x4.add (local.get $prod1) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))

    (local.set $d6 (f32x4.add (local.get $u6) (local.get $u7)))
    (local.set $d7 (f32x4.sub (local.get $u6) (local.get $u7)))

    ;; ============ Bit-reversal output ============
    ;; Output order: 0,8,4,12,2,10,6,14,1,9,5,13,3,11,7,15
    ;; d0=[y0,y1], d1=[y4,y5], d2=[y8,y9], d3=[y12,y13]
    ;; d4=[y2,y3], d5=[y6,y7], d6=[y10,y11], d7=[y14,y15]

    ;; Need: [y0,y8], [y4,y12], [y2,y10], [y6,y14], [y1,y9], [y5,y13], [y3,y11], [y7,y15]

    ;; [y0, y8]: d0[0], d2[0]
    (v128.store (i32.const 0)
      (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $d0) (local.get $d2)))
    ;; [y4, y12]: d1[0], d3[0]
    (v128.store (i32.const 16)
      (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $d1) (local.get $d3)))
    ;; [y2, y10]: d4[0], d6[0]
    (v128.store (i32.const 32)
      (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $d4) (local.get $d6)))
    ;; [y6, y14]: d5[0], d7[0]
    (v128.store (i32.const 48)
      (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $d5) (local.get $d7)))
    ;; [y1, y9]: d0[1], d2[1]
    (v128.store (i32.const 64)
      (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $d0) (local.get $d2)))
    ;; [y5, y13]: d1[1], d3[1]
    (v128.store (i32.const 80)
      (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $d1) (local.get $d3)))
    ;; [y3, y11]: d4[1], d6[1]
    (v128.store (i32.const 96)
      (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $d4) (local.get $d6)))
    ;; [y7, y15]: d5[1], d7[1]
    (v128.store (i32.const 112)
      (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $d5) (local.get $d7)))
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
  ;; Internal FFT Entry Point
  ;; ============================================================================

  (func $fft (param $n i32)
    (if (i32.eq (local.get $n) (i32.const 4))
      (then (call $fft_4) (return)))
    (call $fft_general (local.get $n))
  )

  ;; ============================================================================
  ;; RFFT Twiddle Precomputation
  ;; ============================================================================

  (func $precompute_rfft_twiddles (export "precompute_rfft_twiddles") (param $n i32)
    (local $n2 i32) (local $k i32) (local $angle f32) (local $addr i32)
    (local $neg_two_pi_over_n f32)
    (local.set $n2 (i32.shr_u (local.get $n) (i32.const 1)))
    ;; Precompute N/2-point FFT twiddles (pre-replicated)
    (call $precompute_twiddles (local.get $n2))
    ;; Precompute post-processing twiddles W_N^k for k = 0 to N/2
    (local.set $neg_two_pi_over_n
      (f32.div (f32.mul (f32.const -2.0) (global.get $PI)) (f32.convert_i32_u (local.get $n))))
    (local.set $k (i32.const 0))
    (block $done (loop $loop
      (br_if $done (i32.gt_u (local.get $k) (local.get $n2)))
      (local.set $angle (f32.mul (f32.convert_i32_u (local.get $k)) (local.get $neg_two_pi_over_n)))
      (local.set $addr (i32.add (global.get $RFFT_TWIDDLE_OFFSET) (i32.shl (local.get $k) (i32.const 3))))
      (f32.store (local.get $addr) (call $cos (local.get $angle)))
      (f32.store (i32.add (local.get $addr) (i32.const 4)) (call $sin (local.get $angle)))
      (local.set $k (i32.add (local.get $k) (i32.const 1)))
      (br $loop)
    ))
  )

  ;; ============================================================================
  ;; Real FFT with Post-Processing
  ;; ============================================================================
  ;; Input: N real f32 values at offset 0
  ;; Output: N/2+1 complex f32 values at offset 0

  (func $rfft (export "rfft") (param $n i32)
    (local $n2 i32) (local $k i32) (local $k_end i32) (local $n2_minus_k i32)
    (local $addr_k i32) (local $addr_n2k i32) (local $tw_addr i32)
    ;; Scalar values
    (local $z0_re f32) (local $z0_im f32)
    (local $zk_re f32) (local $zk_im f32) (local $zn2k_re f32) (local $zn2k_im f32)
    (local $wk_re f32) (local $wk_im f32) (local $wn2k_re f32) (local $wn2k_im f32)
    (local $sum_re f32) (local $sum_im f32) (local $diff_re f32) (local $diff_im f32)
    (local $wd_re f32) (local $wd_im f32)
    (local $sum2_re f32) (local $sum2_im f32) (local $diff2_re f32) (local $diff2_im f32)
    (local $wd2_re f32) (local $wd2_im f32)
    (local $xk_re f32) (local $xk_im f32) (local $xn2k_re f32) (local $xn2k_im f32)

    (local.set $n2 (i32.shr_u (local.get $n) (i32.const 1)))

    ;; Step 1: Run N/2-point dual-complex FFT
    (call $fft (local.get $n2))

    ;; Step 2: Post-processing

    ;; DC and Nyquist
    (local.set $z0_re (f32.load (i32.const 0)))
    (local.set $z0_im (f32.load (i32.const 4)))
    (f32.store (i32.const 0) (f32.add (local.get $z0_re) (local.get $z0_im)))
    (f32.store (i32.const 4) (f32.const 0.0))
    (local.set $addr_k (i32.shl (local.get $n2) (i32.const 3)))
    (f32.store (local.get $addr_k) (f32.sub (local.get $z0_re) (local.get $z0_im)))
    (f32.store (i32.add (local.get $addr_k) (i32.const 4)) (f32.const 0.0))

    ;; Main loop: process pairs (k, n2-k)
    (local.set $k_end (i32.shr_u (local.get $n2) (i32.const 1)))
    (local.set $k (i32.const 1))

    (block $done_main (loop $main_loop
      (br_if $done_main (i32.ge_u (local.get $k) (local.get $k_end)))
      (local.set $n2_minus_k (i32.sub (local.get $n2) (local.get $k)))
      (local.set $addr_k (i32.shl (local.get $k) (i32.const 3)))
      (local.set $addr_n2k (i32.shl (local.get $n2_minus_k) (i32.const 3)))

      ;; Load Z[k] and Z[n2-k]
      (local.set $zk_re (f32.load (local.get $addr_k)))
      (local.set $zk_im (f32.load (i32.add (local.get $addr_k) (i32.const 4))))
      (local.set $zn2k_re (f32.load (local.get $addr_n2k)))
      (local.set $zn2k_im (f32.load (i32.add (local.get $addr_n2k) (i32.const 4))))

      ;; Load twiddles
      (local.set $tw_addr (i32.add (global.get $RFFT_TWIDDLE_OFFSET) (i32.shl (local.get $k) (i32.const 3))))
      (local.set $wk_re (f32.load (local.get $tw_addr)))
      (local.set $wk_im (f32.load (i32.add (local.get $tw_addr) (i32.const 4))))
      (local.set $tw_addr (i32.add (global.get $RFFT_TWIDDLE_OFFSET) (i32.shl (local.get $n2_minus_k) (i32.const 3))))
      (local.set $wn2k_re (f32.load (local.get $tw_addr)))
      (local.set $wn2k_im (f32.load (i32.add (local.get $tw_addr) (i32.const 4))))

      ;; X[k] computation
      (local.set $sum_re (f32.add (local.get $zk_re) (local.get $zn2k_re)))
      (local.set $sum_im (f32.sub (local.get $zk_im) (local.get $zn2k_im)))
      (local.set $diff_re (f32.sub (local.get $zk_re) (local.get $zn2k_re)))
      (local.set $diff_im (f32.add (local.get $zk_im) (local.get $zn2k_im)))
      (local.set $wd_re (f32.add
        (f32.mul (local.get $wk_im) (local.get $diff_re))
        (f32.mul (local.get $wk_re) (local.get $diff_im))))
      (local.set $wd_im (f32.sub
        (f32.mul (local.get $wk_im) (local.get $diff_im))
        (f32.mul (local.get $wk_re) (local.get $diff_re))))
      (local.set $xk_re (f32.mul (f32.const 0.5) (f32.add (local.get $sum_re) (local.get $wd_re))))
      (local.set $xk_im (f32.mul (f32.const 0.5) (f32.add (local.get $sum_im) (local.get $wd_im))))

      ;; X[n2-k] computation
      (local.set $sum2_re (f32.add (local.get $zn2k_re) (local.get $zk_re)))
      (local.set $sum2_im (f32.sub (local.get $zn2k_im) (local.get $zk_im)))
      (local.set $diff2_re (f32.sub (local.get $zn2k_re) (local.get $zk_re)))
      (local.set $diff2_im (f32.add (local.get $zn2k_im) (local.get $zk_im)))
      (local.set $wd2_re (f32.add
        (f32.mul (local.get $wn2k_im) (local.get $diff2_re))
        (f32.mul (local.get $wn2k_re) (local.get $diff2_im))))
      (local.set $wd2_im (f32.sub
        (f32.mul (local.get $wn2k_im) (local.get $diff2_im))
        (f32.mul (local.get $wn2k_re) (local.get $diff2_re))))
      (local.set $xn2k_re (f32.mul (f32.const 0.5) (f32.add (local.get $sum2_re) (local.get $wd2_re))))
      (local.set $xn2k_im (f32.mul (f32.const 0.5) (f32.add (local.get $sum2_im) (local.get $wd2_im))))

      ;; Store results
      (f32.store (local.get $addr_k) (local.get $xk_re))
      (f32.store (i32.add (local.get $addr_k) (i32.const 4)) (local.get $xk_im))
      (f32.store (local.get $addr_n2k) (local.get $xn2k_re))
      (f32.store (i32.add (local.get $addr_n2k) (i32.const 4)) (local.get $xn2k_im))

      (local.set $k (i32.add (local.get $k) (i32.const 1)))
      (br $main_loop)
    ))

    ;; Handle middle element when n2 is even
    (if (i32.and (i32.eqz (i32.and (local.get $n2) (i32.const 1))) (i32.gt_u (local.get $n2) (i32.const 2)))
      (then
        (local.set $addr_k (i32.shl (local.get $k_end) (i32.const 3)))
        (local.set $zk_re (f32.load (local.get $addr_k)))
        (local.set $zk_im (f32.load (i32.add (local.get $addr_k) (i32.const 4))))
        (local.set $tw_addr (i32.add (global.get $RFFT_TWIDDLE_OFFSET) (i32.shl (local.get $k_end) (i32.const 3))))
        (local.set $wk_re (f32.load (local.get $tw_addr)))
        (local.set $wk_im (f32.load (i32.add (local.get $tw_addr) (i32.const 4))))
        (local.set $sum_re (f32.mul (f32.const 2.0) (local.get $zk_re)))
        (local.set $sum_im (f32.const 0.0))
        (local.set $diff_re (f32.const 0.0))
        (local.set $diff_im (f32.mul (f32.const 2.0) (local.get $zk_im)))
        (local.set $wd_re (f32.add
          (f32.mul (local.get $wk_im) (local.get $diff_re))
          (f32.mul (local.get $wk_re) (local.get $diff_im))))
        (local.set $wd_im (f32.sub
          (f32.mul (local.get $wk_im) (local.get $diff_im))
          (f32.mul (local.get $wk_re) (local.get $diff_re))))
        (local.set $xk_re (f32.mul (f32.const 0.5) (f32.add (local.get $sum_re) (local.get $wd_re))))
        (local.set $xk_im (f32.mul (f32.const 0.5) (f32.add (local.get $sum_im) (local.get $wd_im))))
        (f32.store (local.get $addr_k) (local.get $xk_re))
        (f32.store (i32.add (local.get $addr_k) (i32.const 4)) (local.get $xk_im))
      )
    )
  )
)
