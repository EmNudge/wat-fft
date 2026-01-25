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

  ;; Conjugate mask for f32 complex: flip sign of imaginary parts [0, -0, 0, -0]
  (global $CONJ_MASK_F32 v128 (v128.const i32x4 0 0x80000000 0 0x80000000))


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

  ;; Correct FFT-8 codelet using DIF algorithm
  ;; Stage 1: butterflies (k, k+4) with twiddles W_8^k for k=0..3
  ;; Stage 2: butterflies (k, k+2) with twiddles W_4^k for k=0,1 in each half
  ;; Stage 3: butterflies (k, k+1) with twiddle W_2^0=1
  (func $fft_8
    (local $x0 v128) (local $x1 v128) (local $x2 v128) (local $x3 v128)
    (local $x4 v128) (local $x5 v128) (local $x6 v128) (local $x7 v128)
    (local $t v128) (local $sum v128) (local $diff v128)

    ;; Load 8 complex values as single-complex v128 (using low 64 bits)
    (local.set $x0 (v128.load64_zero (i32.const 0)))
    (local.set $x1 (v128.load64_zero (i32.const 8)))
    (local.set $x2 (v128.load64_zero (i32.const 16)))
    (local.set $x3 (v128.load64_zero (i32.const 24)))
    (local.set $x4 (v128.load64_zero (i32.const 32)))
    (local.set $x5 (v128.load64_zero (i32.const 40)))
    (local.set $x6 (v128.load64_zero (i32.const 48)))
    (local.set $x7 (v128.load64_zero (i32.const 56)))

    ;; ============ Stage 1: butterflies (k, k+4) ============
    ;; k=0: W_8^0 = 1
    (local.set $sum (f32x4.add (local.get $x0) (local.get $x4)))
    (local.set $x4 (f32x4.sub (local.get $x0) (local.get $x4)))
    (local.set $x0 (local.get $sum))

    ;; k=1: W_8^1 = (0.7071068, -0.7071068)
    (local.set $sum (f32x4.add (local.get $x1) (local.get $x5)))
    (local.set $diff (f32x4.sub (local.get $x1) (local.get $x5)))
    ;; diff * W = [re*wr - im*wi, re*wi + im*wr] = [re*0.707 - im*(-0.707), re*(-0.707) + im*0.707]
    ;;          = [re*0.707 + im*0.707, -re*0.707 + im*0.707]
    (local.set $t (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $diff) (local.get $diff)))
    (local.set $x5 (f32x4.mul
      (f32x4.add (local.get $diff) (f32x4.mul (local.get $t) (v128.const f32x4 1.0 -1.0 1.0 -1.0)))
      (v128.const f32x4 0.7071068 0.7071068 0.7071068 0.7071068)))
    (local.set $x1 (local.get $sum))

    ;; k=2: W_8^2 = -j = (0, -1), so z*(-j) = [im, -re]
    (local.set $sum (f32x4.add (local.get $x2) (local.get $x6)))
    (local.set $diff (f32x4.sub (local.get $x2) (local.get $x6)))
    (local.set $x6 (f32x4.mul
      (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $diff) (local.get $diff))
      (v128.const f32x4 1.0 -1.0 1.0 -1.0)))
    (local.set $x2 (local.get $sum))

    ;; k=3: W_8^3 = (-0.7071068, -0.7071068)
    (local.set $sum (f32x4.add (local.get $x3) (local.get $x7)))
    (local.set $diff (f32x4.sub (local.get $x3) (local.get $x7)))
    ;; diff * W where W = (-0.707, -0.707)
    ;; real = re*(-0.707) - im*(-0.707) = 0.707*(im - re)
    ;; imag = re*(-0.707) + im*(-0.707) = -0.707*(re + im)
    (local.set $t (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $diff) (local.get $diff)))
    (local.set $x7 (f32x4.mul
      (f32x4.sub (local.get $t) (f32x4.mul (local.get $diff) (v128.const f32x4 1.0 -1.0 1.0 -1.0)))
      (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068)))
    (local.set $x3 (local.get $sum))

    ;; ============ Stage 2: butterflies (k, k+2) ============
    ;; Top half [x0,x1,x2,x3]:
    ;; k=0: W_4^0 = 1
    (local.set $sum (f32x4.add (local.get $x0) (local.get $x2)))
    (local.set $x2 (f32x4.sub (local.get $x0) (local.get $x2)))
    (local.set $x0 (local.get $sum))

    ;; k=1: W_4^1 = -j
    (local.set $sum (f32x4.add (local.get $x1) (local.get $x3)))
    (local.set $diff (f32x4.sub (local.get $x1) (local.get $x3)))
    (local.set $x3 (f32x4.mul
      (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $diff) (local.get $diff))
      (v128.const f32x4 1.0 -1.0 1.0 -1.0)))
    (local.set $x1 (local.get $sum))

    ;; Bottom half [x4,x5,x6,x7]:
    ;; k=0: W_4^0 = 1
    (local.set $sum (f32x4.add (local.get $x4) (local.get $x6)))
    (local.set $x6 (f32x4.sub (local.get $x4) (local.get $x6)))
    (local.set $x4 (local.get $sum))

    ;; k=1: W_4^1 = -j
    (local.set $sum (f32x4.add (local.get $x5) (local.get $x7)))
    (local.set $diff (f32x4.sub (local.get $x5) (local.get $x7)))
    (local.set $x7 (f32x4.mul
      (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $diff) (local.get $diff))
      (v128.const f32x4 1.0 -1.0 1.0 -1.0)))
    (local.set $x5 (local.get $sum))

    ;; ============ Stage 3: butterflies (k, k+1), all W=1 ============
    (local.set $sum (f32x4.add (local.get $x0) (local.get $x1)))
    (local.set $x1 (f32x4.sub (local.get $x0) (local.get $x1)))
    (local.set $x0 (local.get $sum))

    (local.set $sum (f32x4.add (local.get $x2) (local.get $x3)))
    (local.set $x3 (f32x4.sub (local.get $x2) (local.get $x3)))
    (local.set $x2 (local.get $sum))

    (local.set $sum (f32x4.add (local.get $x4) (local.get $x5)))
    (local.set $x5 (f32x4.sub (local.get $x4) (local.get $x5)))
    (local.set $x4 (local.get $sum))

    (local.set $sum (f32x4.add (local.get $x6) (local.get $x7)))
    (local.set $x7 (f32x4.sub (local.get $x6) (local.get $x7)))
    (local.set $x6 (local.get $sum))

    ;; ============ Output in bit-reversed order: 0,4,2,6,1,5,3,7 ============
    (v128.store64_lane 0 (i32.const 0) (local.get $x0))
    (v128.store64_lane 0 (i32.const 8) (local.get $x4))
    (v128.store64_lane 0 (i32.const 16) (local.get $x2))
    (v128.store64_lane 0 (i32.const 24) (local.get $x6))
    (v128.store64_lane 0 (i32.const 32) (local.get $x1))
    (v128.store64_lane 0 (i32.const 40) (local.get $x5))
    (v128.store64_lane 0 (i32.const 48) (local.get $x3))
    (v128.store64_lane 0 (i32.const 56) (local.get $x7))
  )


  ;; ============================================================================
  ;; N=8 DIT Codelet (Natural Order Output)
  ;; ============================================================================
  ;; Uses Decimation in Time with bit-reversed INPUT loading.
  ;; Produces NATURAL ORDER output (compatible with RFFT post-processing).
  ;;
  ;; DIT algorithm:
  ;; - Load in bit-reversed order: positions 0,4,2,6,1,5,3,7
  ;; - Stage 1 (span 1): butterflies with W_2^0 = 1
  ;; - Stage 2 (span 2): butterflies with W_4^k
  ;; - Stage 3 (span 4): butterflies with W_8^k
  ;; - Output in natural order: 0,1,2,3,4,5,6,7

  (func $fft_8_dit
    (local $x0 v128) (local $x1 v128) (local $x2 v128) (local $x3 v128)
    (local $x4 v128) (local $x5 v128) (local $x6 v128) (local $x7 v128)
    (local $t v128) (local $sum v128) (local $diff v128)

    ;; Load in bit-reversed order: 0,4,2,6,1,5,3,7
    (local.set $x0 (v128.load64_zero (i32.const 0)))   ;; index 0
    (local.set $x1 (v128.load64_zero (i32.const 32)))  ;; index 4
    (local.set $x2 (v128.load64_zero (i32.const 16)))  ;; index 2
    (local.set $x3 (v128.load64_zero (i32.const 48)))  ;; index 6
    (local.set $x4 (v128.load64_zero (i32.const 8)))   ;; index 1
    (local.set $x5 (v128.load64_zero (i32.const 40)))  ;; index 5
    (local.set $x6 (v128.load64_zero (i32.const 24)))  ;; index 3
    (local.set $x7 (v128.load64_zero (i32.const 56)))  ;; index 7

    ;; ============ Stage 1 (span 1): all twiddles W_2^0 = 1 ============
    ;; DIT butterfly: a' = a + b, b' = a - b (since W=1)
    ;; Pairs: (0,1), (2,3), (4,5), (6,7)
    (local.set $sum (f32x4.add (local.get $x0) (local.get $x1)))
    (local.set $x1 (f32x4.sub (local.get $x0) (local.get $x1)))
    (local.set $x0 (local.get $sum))

    (local.set $sum (f32x4.add (local.get $x2) (local.get $x3)))
    (local.set $x3 (f32x4.sub (local.get $x2) (local.get $x3)))
    (local.set $x2 (local.get $sum))

    (local.set $sum (f32x4.add (local.get $x4) (local.get $x5)))
    (local.set $x5 (f32x4.sub (local.get $x4) (local.get $x5)))
    (local.set $x4 (local.get $sum))

    (local.set $sum (f32x4.add (local.get $x6) (local.get $x7)))
    (local.set $x7 (f32x4.sub (local.get $x6) (local.get $x7)))
    (local.set $x6 (local.get $sum))

    ;; ============ Stage 2 (span 2): W_4^0=1, W_4^1=-j ============
    ;; DIT butterfly: a' = a + b*W, b' = a - b*W
    ;; Pairs: (0,2) W=1, (1,3) W=-j, (4,6) W=1, (5,7) W=-j

    ;; (0,2) with W_4^0 = 1
    (local.set $sum (f32x4.add (local.get $x0) (local.get $x2)))
    (local.set $x2 (f32x4.sub (local.get $x0) (local.get $x2)))
    (local.set $x0 (local.get $sum))

    ;; (1,3) with W_4^1 = -j: b*(-j) = [b.im, -b.re]
    (local.set $t (f32x4.mul
      (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $x3) (local.get $x3))
      (v128.const f32x4 1.0 -1.0 1.0 -1.0)))
    (local.set $sum (f32x4.add (local.get $x1) (local.get $t)))
    (local.set $x3 (f32x4.sub (local.get $x1) (local.get $t)))
    (local.set $x1 (local.get $sum))

    ;; (4,6) with W_4^0 = 1
    (local.set $sum (f32x4.add (local.get $x4) (local.get $x6)))
    (local.set $x6 (f32x4.sub (local.get $x4) (local.get $x6)))
    (local.set $x4 (local.get $sum))

    ;; (5,7) with W_4^1 = -j
    (local.set $t (f32x4.mul
      (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $x7) (local.get $x7))
      (v128.const f32x4 1.0 -1.0 1.0 -1.0)))
    (local.set $sum (f32x4.add (local.get $x5) (local.get $t)))
    (local.set $x7 (f32x4.sub (local.get $x5) (local.get $t)))
    (local.set $x5 (local.get $sum))

    ;; ============ Stage 3 (span 4): W_8^0=1, W_8^1, W_8^2=-j, W_8^3 ============
    ;; Pairs: (0,4) W_8^0=1, (1,5) W_8^1, (2,6) W_8^2=-j, (3,7) W_8^3

    ;; (0,4) with W_8^0 = 1
    (local.set $sum (f32x4.add (local.get $x0) (local.get $x4)))
    (local.set $x4 (f32x4.sub (local.get $x0) (local.get $x4)))
    (local.set $x0 (local.get $sum))

    ;; (1,5) with W_8^1 = (0.7071068, -0.7071068)
    ;; b*W = [b.re*0.707 - b.im*(-0.707), b.re*(-0.707) + b.im*0.707]
    ;;     = [0.707*(b.re + b.im), 0.707*(b.im - b.re)]
    (local.set $t (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $x5) (local.get $x5)))
    (local.set $t (f32x4.mul
      (f32x4.add (local.get $x5) (f32x4.mul (local.get $t) (v128.const f32x4 1.0 -1.0 1.0 -1.0)))
      (v128.const f32x4 0.7071068 0.7071068 0.7071068 0.7071068)))
    (local.set $sum (f32x4.add (local.get $x1) (local.get $t)))
    (local.set $x5 (f32x4.sub (local.get $x1) (local.get $t)))
    (local.set $x1 (local.get $sum))

    ;; (2,6) with W_8^2 = -j: b*(-j) = [b.im, -b.re]
    (local.set $t (f32x4.mul
      (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $x6) (local.get $x6))
      (v128.const f32x4 1.0 -1.0 1.0 -1.0)))
    (local.set $sum (f32x4.add (local.get $x2) (local.get $t)))
    (local.set $x6 (f32x4.sub (local.get $x2) (local.get $t)))
    (local.set $x2 (local.get $sum))

    ;; (3,7) with W_8^3 = (-0.7071068, -0.7071068)
    ;; b*W = [b.re*(-0.707) - b.im*(-0.707), b.re*(-0.707) + b.im*(-0.707)]
    ;;     = [0.707*(b.im - b.re), -0.707*(b.re + b.im)]
    (local.set $t (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $x7) (local.get $x7)))
    (local.set $t (f32x4.mul
      (f32x4.sub (local.get $t) (f32x4.mul (local.get $x7) (v128.const f32x4 1.0 -1.0 1.0 -1.0)))
      (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068)))
    (local.set $sum (f32x4.add (local.get $x3) (local.get $t)))
    (local.set $x7 (f32x4.sub (local.get $x3) (local.get $t)))
    (local.set $x3 (local.get $sum))

    ;; ============ Output in natural order: 0,1,2,3,4,5,6,7 ============
    (v128.store64_lane 0 (i32.const 0) (local.get $x0))
    (v128.store64_lane 0 (i32.const 8) (local.get $x1))
    (v128.store64_lane 0 (i32.const 16) (local.get $x2))
    (v128.store64_lane 0 (i32.const 24) (local.get $x3))
    (v128.store64_lane 0 (i32.const 32) (local.get $x4))
    (v128.store64_lane 0 (i32.const 40) (local.get $x5))
    (v128.store64_lane 0 (i32.const 48) (local.get $x6))
    (v128.store64_lane 0 (i32.const 56) (local.get $x7))
  )


  ;; ============================================================================
  ;; N=16 DIT Dual-Complex Kernel (natural order output)
  ;; ============================================================================
  ;; Loads in bit-reversed order, outputs in natural order.
  ;; Compatible with RFFT post-processing.
  ;;
  ;; Bit-reversed order for N=16: 0,8,4,12,2,10,6,14,1,9,5,13,3,11,7,15

  (func $fft_16_dit
    (local $d0 v128) (local $d1 v128) (local $d2 v128) (local $d3 v128)
    (local $d4 v128) (local $d5 v128) (local $d6 v128) (local $d7 v128)
    (local $t0 v128) (local $t1 v128) (local $t2 v128) (local $t3 v128)
    (local $t4 v128) (local $t5 v128) (local $t6 v128) (local $t7 v128)
    (local $u0 v128) (local $u1 v128) (local $u2 v128) (local $u3 v128)
    (local $u4 v128) (local $u5 v128) (local $u6 v128) (local $u7 v128)
    (local $swapped v128) (local $prod v128)

    ;; ============ Load in bit-reversed order ============
    ;; d0 = [pos0, pos1] = [input[0], input[8]]
    (local.set $d0 (v128.load64_lane 1 (i32.const 64)
      (v128.load64_zero (i32.const 0))))
    ;; d1 = [pos2, pos3] = [input[4], input[12]]
    (local.set $d1 (v128.load64_lane 1 (i32.const 96)
      (v128.load64_zero (i32.const 32))))
    ;; d2 = [pos4, pos5] = [input[2], input[10]]
    (local.set $d2 (v128.load64_lane 1 (i32.const 80)
      (v128.load64_zero (i32.const 16))))
    ;; d3 = [pos6, pos7] = [input[6], input[14]]
    (local.set $d3 (v128.load64_lane 1 (i32.const 112)
      (v128.load64_zero (i32.const 48))))
    ;; d4 = [pos8, pos9] = [input[1], input[9]]
    (local.set $d4 (v128.load64_lane 1 (i32.const 72)
      (v128.load64_zero (i32.const 8))))
    ;; d5 = [pos10, pos11] = [input[5], input[13]]
    (local.set $d5 (v128.load64_lane 1 (i32.const 104)
      (v128.load64_zero (i32.const 40))))
    ;; d6 = [pos12, pos13] = [input[3], input[11]]
    (local.set $d6 (v128.load64_lane 1 (i32.const 88)
      (v128.load64_zero (i32.const 24))))
    ;; d7 = [pos14, pos15] = [input[7], input[15]]
    (local.set $d7 (v128.load64_lane 1 (i32.const 120)
      (v128.load64_zero (i32.const 56))))

    ;; ============ Stage 1 (span 1): all twiddles = 1 ============
    ;; Butterflies: (0,1), (2,3), (4,5), ..., (14,15)
    ;; Each d register has [pos_2k, pos_2k+1], so we do within-register butterflies
    ;; DIT butterfly: a' = a + b, b' = a - b (since W=1)

    ;; For within-register butterfly: d=[a,b] -> [a+b, a-b]
    ;; swap = [b, a], then (d + swap)/2 has both halves as (a+b), (d - swap) has [a-b, -(a-b)]
    ;; Better: use shuffle to duplicate then combine

    ;; d0: [a,b] -> [a+b, a-b]
    (local.set $swapped (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7
      (local.get $d0) (local.get $d0)))
    (local.set $t0 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d0) (local.get $swapped))
      (f32x4.sub (local.get $d0) (local.get $swapped))))

    (local.set $swapped (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7
      (local.get $d1) (local.get $d1)))
    (local.set $t1 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d1) (local.get $swapped))
      (f32x4.sub (local.get $d1) (local.get $swapped))))

    (local.set $swapped (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7
      (local.get $d2) (local.get $d2)))
    (local.set $t2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d2) (local.get $swapped))
      (f32x4.sub (local.get $d2) (local.get $swapped))))

    (local.set $swapped (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7
      (local.get $d3) (local.get $d3)))
    (local.set $t3 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d3) (local.get $swapped))
      (f32x4.sub (local.get $d3) (local.get $swapped))))

    (local.set $swapped (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7
      (local.get $d4) (local.get $d4)))
    (local.set $t4 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d4) (local.get $swapped))
      (f32x4.sub (local.get $d4) (local.get $swapped))))

    (local.set $swapped (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7
      (local.get $d5) (local.get $d5)))
    (local.set $t5 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d5) (local.get $swapped))
      (f32x4.sub (local.get $d5) (local.get $swapped))))

    (local.set $swapped (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7
      (local.get $d6) (local.get $d6)))
    (local.set $t6 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d6) (local.get $swapped))
      (f32x4.sub (local.get $d6) (local.get $swapped))))

    (local.set $swapped (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7
      (local.get $d7) (local.get $d7)))
    (local.set $t7 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d7) (local.get $swapped))
      (f32x4.sub (local.get $d7) (local.get $swapped))))

    ;; After Stage 1:
    ;; t0 = [W'[0], W'[1]], t1 = [W'[2], W'[3]], t2 = [W'[4], W'[5]], t3 = [W'[6], W'[7]]
    ;; t4 = [W'[8], W'[9]], t5 = [W'[10], W'[11]], t6 = [W'[12], W'[13]], t7 = [W'[14], W'[15]]

    ;; ============ Stage 2 (span 2): W_4^k twiddles ============
    ;; Butterflies: (0,2), (1,3), (4,6), (5,7), (8,10), (9,11), (12,14), (13,15)
    ;; k=0 mod 2 -> W_4^0 = 1
    ;; k=1 mod 2 -> W_4^1 = -j = (0, -1) -> multiply gives [im, -re]

    ;; Need to reorganize: pair up t0 with t1, t2 with t3, etc.
    ;; t0=[W'0,W'1], t1=[W'2,W'3] -> need (W'0,W'2) and (W'1,W'3)
    ;; u0 = [t0.low, t1.low] = [W'0, W'2]
    ;; u1 = [t0.high, t1.high] = [W'1, W'3]

    (local.set $u0 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (local.get $t0) (local.get $t1)))
    (local.set $u1 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31
      (local.get $t0) (local.get $t1)))

    (local.set $u2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (local.get $t2) (local.get $t3)))
    (local.set $u3 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31
      (local.get $t2) (local.get $t3)))

    (local.set $u4 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (local.get $t4) (local.get $t5)))
    (local.set $u5 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31
      (local.get $t4) (local.get $t5)))

    (local.set $u6 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (local.get $t6) (local.get $t7)))
    (local.set $u7 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31
      (local.get $t6) (local.get $t7)))

    ;; Now: u0=[W'0,W'2], u1=[W'1,W'3], u2=[W'4,W'6], u3=[W'5,W'7], ...
    ;; Butterfly (0,2): u0=[a,b] -> [a+b, a-b] with twiddle=1
    ;; Butterfly (1,3): u1=[a,b] -> [a+b*(-j), a-b*(-j)]

    ;; u0, u2, u4, u6: twiddle = 1, do within-register butterfly
    (local.set $swapped (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7
      (local.get $u0) (local.get $u0)))
    (local.set $d0 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $u0) (local.get $swapped))
      (f32x4.sub (local.get $u0) (local.get $swapped))))

    (local.set $swapped (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7
      (local.get $u2) (local.get $u2)))
    (local.set $d2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $u2) (local.get $swapped))
      (f32x4.sub (local.get $u2) (local.get $swapped))))

    (local.set $swapped (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7
      (local.get $u4) (local.get $u4)))
    (local.set $d4 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $u4) (local.get $swapped))
      (f32x4.sub (local.get $u4) (local.get $swapped))))

    (local.set $swapped (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7
      (local.get $u6) (local.get $u6)))
    (local.set $d6 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $u6) (local.get $swapped))
      (f32x4.sub (local.get $u6) (local.get $swapped))))

    ;; u1, u3, u5, u7: twiddle = -j for the b term
    ;; DIT butterfly: a' = a + b*W, b' = a - b*W
    ;; b*(-j) = [b.re*0 - b.im*(-1), b.re*(-1) + b.im*0] = [b.im, -b.re]
    ;; u1=[a,b] where a=[a.re,a.im,?,?], b=[?,?,b.re,b.im]
    ;; b*(-j) = [b.im, -b.re] in high position

    ;; First apply -j to the high element (b) of each register
    ;; prod = [a.re, a.im, b.im, -b.re]
    (local.set $prod (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11
      (local.get $u1) (local.get $u1)))
    (local.set $prod (f32x4.mul (local.get $prod) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    ;; Now prod = [a, b*(-j)]
    (local.set $swapped (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7
      (local.get $prod) (local.get $prod)))
    (local.set $d1 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $prod) (local.get $swapped))
      (f32x4.sub (local.get $prod) (local.get $swapped))))

    (local.set $prod (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11
      (local.get $u3) (local.get $u3)))
    (local.set $prod (f32x4.mul (local.get $prod) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $swapped (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7
      (local.get $prod) (local.get $prod)))
    (local.set $d3 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $prod) (local.get $swapped))
      (f32x4.sub (local.get $prod) (local.get $swapped))))

    (local.set $prod (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11
      (local.get $u5) (local.get $u5)))
    (local.set $prod (f32x4.mul (local.get $prod) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $swapped (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7
      (local.get $prod) (local.get $prod)))
    (local.set $d5 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $prod) (local.get $swapped))
      (f32x4.sub (local.get $prod) (local.get $swapped))))

    (local.set $prod (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11
      (local.get $u7) (local.get $u7)))
    (local.set $prod (f32x4.mul (local.get $prod) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $swapped (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7
      (local.get $prod) (local.get $prod)))
    (local.set $d7 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $prod) (local.get $swapped))
      (f32x4.sub (local.get $prod) (local.get $swapped))))

    ;; After Stage 2: d0-d7 contain [W''[k], W''[k+2]] pairs
    ;; d0=[W''0,W''2], d1=[W''1,W''3], d2=[W''4,W''6], d3=[W''5,W''7]
    ;; d4=[W''8,W''10], d5=[W''9,W''11], d6=[W''12,W''14], d7=[W''13,W''15]

    ;; ============ Stage 3 (span 4): W_8^k twiddles ============
    ;; Butterflies: (0,4), (1,5), (2,6), (3,7), (8,12), (9,13), (10,14), (11,15)
    ;; k=0: W_8^0 = 1
    ;; k=1: W_8^1 = (0.7071068, -0.7071068)
    ;; k=2: W_8^2 = -j
    ;; k=3: W_8^3 = (-0.7071068, -0.7071068)

    ;; Reorganize: pair d0 with d2, d1 with d3, d4 with d6, d5 with d7
    ;; t0 = [d0.low, d2.low] = [W''0, W''4]
    ;; t1 = [d0.high, d2.high] = [W''2, W''6]
    ;; etc.

    (local.set $t0 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (local.get $d0) (local.get $d2)))
    (local.set $t1 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31
      (local.get $d0) (local.get $d2)))
    (local.set $t2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (local.get $d1) (local.get $d3)))
    (local.set $t3 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31
      (local.get $d1) (local.get $d3)))
    (local.set $t4 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (local.get $d4) (local.get $d6)))
    (local.set $t5 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31
      (local.get $d4) (local.get $d6)))
    (local.set $t6 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (local.get $d5) (local.get $d7)))
    (local.set $t7 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31
      (local.get $d5) (local.get $d7)))

    ;; t0=[W''0,W''4], t1=[W''2,W''6]: butterflies (0,4) and (2,6)
    ;; t2=[W''1,W''5], t3=[W''3,W''7]: butterflies (1,5) and (3,7)
    ;; t4=[W''8,W''12], t5=[W''10,W''14]: butterflies (8,12) and (10,14)
    ;; t6=[W''9,W''13], t7=[W''11,W''15]: butterflies (9,13) and (11,15)

    ;; t0, t4: twiddle = W_8^0 = 1
    (local.set $swapped (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7
      (local.get $t0) (local.get $t0)))
    (local.set $u0 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $t0) (local.get $swapped))
      (f32x4.sub (local.get $t0) (local.get $swapped))))

    (local.set $swapped (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7
      (local.get $t4) (local.get $t4)))
    (local.set $u4 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $t4) (local.get $swapped))
      (f32x4.sub (local.get $t4) (local.get $swapped))))

    ;; t1, t5: twiddle = W_8^2 = -j
    (local.set $prod (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11
      (local.get $t1) (local.get $t1)))
    (local.set $prod (f32x4.mul (local.get $prod) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $swapped (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7
      (local.get $prod) (local.get $prod)))
    (local.set $u1 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $prod) (local.get $swapped))
      (f32x4.sub (local.get $prod) (local.get $swapped))))

    (local.set $prod (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11
      (local.get $t5) (local.get $t5)))
    (local.set $prod (f32x4.mul (local.get $prod) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $swapped (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7
      (local.get $prod) (local.get $prod)))
    (local.set $u5 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $prod) (local.get $swapped))
      (f32x4.sub (local.get $prod) (local.get $swapped))))

    ;; t2, t6: twiddle = W_8^1 = (0.7071068, -0.7071068)
    ;; b*W = [b.re*0.707 + b.im*0.707, -b.re*0.707 + b.im*0.707] = [0.707*(b.re+b.im), 0.707*(b.im-b.re)]
    ;; First compute b*W for the high element
    (local.set $prod (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15
      (local.get $t2) (local.get $t2)))  ;; [b, b]
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3
      (local.get $prod) (local.get $prod)))  ;; [b.im, b.re, b.im, b.re]
    (local.set $prod (f32x4.mul
      (f32x4.add (local.get $prod) (f32x4.mul (local.get $swapped) (v128.const f32x4 1.0 -1.0 1.0 -1.0)))
      (v128.const f32x4 0.7071068 0.7071068 0.7071068 0.7071068)))
    ;; prod = [b*W, b*W] in both halves, we need it in high half
    ;; Combine: [a, b*W]
    (local.set $prod (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31
      (local.get $t2) (local.get $prod)))
    (local.set $swapped (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7
      (local.get $prod) (local.get $prod)))
    (local.set $u2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $prod) (local.get $swapped))
      (f32x4.sub (local.get $prod) (local.get $swapped))))

    (local.set $prod (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15
      (local.get $t6) (local.get $t6)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3
      (local.get $prod) (local.get $prod)))
    (local.set $prod (f32x4.mul
      (f32x4.add (local.get $prod) (f32x4.mul (local.get $swapped) (v128.const f32x4 1.0 -1.0 1.0 -1.0)))
      (v128.const f32x4 0.7071068 0.7071068 0.7071068 0.7071068)))
    (local.set $prod (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31
      (local.get $t6) (local.get $prod)))
    (local.set $swapped (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7
      (local.get $prod) (local.get $prod)))
    (local.set $u6 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $prod) (local.get $swapped))
      (f32x4.sub (local.get $prod) (local.get $swapped))))

    ;; t3, t7: twiddle = W_8^3 = (-0.7071068, -0.7071068)
    ;; b*W = [b.re*(-0.707) - b.im*(-0.707), b.re*(-0.707) + b.im*(-0.707)]
    ;;     = [0.707*(b.im - b.re), -0.707*(b.re + b.im)]
    (local.set $prod (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15
      (local.get $t3) (local.get $t3)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3
      (local.get $prod) (local.get $prod)))
    (local.set $prod (f32x4.mul
      (f32x4.sub (local.get $swapped) (f32x4.mul (local.get $prod) (v128.const f32x4 1.0 -1.0 1.0 -1.0)))
      (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068)))
    (local.set $prod (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31
      (local.get $t3) (local.get $prod)))
    (local.set $swapped (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7
      (local.get $prod) (local.get $prod)))
    (local.set $u3 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $prod) (local.get $swapped))
      (f32x4.sub (local.get $prod) (local.get $swapped))))

    (local.set $prod (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15
      (local.get $t7) (local.get $t7)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3
      (local.get $prod) (local.get $prod)))
    (local.set $prod (f32x4.mul
      (f32x4.sub (local.get $swapped) (f32x4.mul (local.get $prod) (v128.const f32x4 1.0 -1.0 1.0 -1.0)))
      (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068)))
    (local.set $prod (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31
      (local.get $t7) (local.get $prod)))
    (local.set $swapped (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7
      (local.get $prod) (local.get $prod)))
    (local.set $u7 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $prod) (local.get $swapped))
      (f32x4.sub (local.get $prod) (local.get $swapped))))

    ;; After Stage 3: u0-u7 contain [W'''[k], W'''[k+4]] pairs
    ;; u0=[W'''0,W'''4], u1=[W'''2,W'''6], u2=[W'''1,W'''5], u3=[W'''3,W'''7]
    ;; u4=[W'''8,W'''12], u5=[W'''10,W'''14], u6=[W'''9,W'''13], u7=[W'''11,W'''15]

    ;; ============ Stage 4 (span 8): W_16^k twiddles ============
    ;; Butterflies: (0,8), (1,9), (2,10), (3,11), (4,12), (5,13), (6,14), (7,15)
    ;; k=0: W_16^0 = 1
    ;; k=1: W_16^1 = (0.9238795, -0.3826834)
    ;; k=2: W_16^2 = (0.7071068, -0.7071068)
    ;; k=3: W_16^3 = (0.3826834, -0.9238795)
    ;; k=4: W_16^4 = -j
    ;; k=5: W_16^5 = (-0.3826834, -0.9238795)
    ;; k=6: W_16^6 = (-0.7071068, -0.7071068)
    ;; k=7: W_16^7 = (-0.9238795, -0.3826834)

    ;; Reorganize: pair u0 with u4, u1 with u5, u2 with u6, u3 with u7
    ;; t0 = [u0.low, u4.low] = [W'''0, W'''8] -> butterfly (0,8)
    ;; t1 = [u0.high, u4.high] = [W'''4, W'''12] -> butterfly (4,12)
    ;; etc.

    (local.set $t0 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (local.get $u0) (local.get $u4)))  ;; [0,8]
    (local.set $t1 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31
      (local.get $u0) (local.get $u4)))  ;; [4,12]
    (local.set $t2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (local.get $u1) (local.get $u5)))  ;; [2,10]
    (local.set $t3 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31
      (local.get $u1) (local.get $u5)))  ;; [6,14]
    (local.set $t4 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (local.get $u2) (local.get $u6)))  ;; [1,9]
    (local.set $t5 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31
      (local.get $u2) (local.get $u6)))  ;; [5,13]
    (local.set $t6 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (local.get $u3) (local.get $u7)))  ;; [3,11]
    (local.set $t7 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31
      (local.get $u3) (local.get $u7)))  ;; [7,15]

    ;; t0: [0,8] -> butterfly with W_16^0 = 1
    (local.set $swapped (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7
      (local.get $t0) (local.get $t0)))
    (local.set $d0 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $t0) (local.get $swapped))
      (f32x4.sub (local.get $t0) (local.get $swapped))))  ;; d0 = [out0, out8]

    ;; t1: [4,12] -> butterfly with W_16^4 = -j
    (local.set $prod (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11
      (local.get $t1) (local.get $t1)))
    (local.set $prod (f32x4.mul (local.get $prod) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $swapped (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7
      (local.get $prod) (local.get $prod)))
    (local.set $d4 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $prod) (local.get $swapped))
      (f32x4.sub (local.get $prod) (local.get $swapped))))  ;; d4 = [out4, out12]

    ;; t2: [2,10] -> butterfly with W_16^2 = (0.7071068, -0.7071068)
    (local.set $prod (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15
      (local.get $t2) (local.get $t2)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3
      (local.get $prod) (local.get $prod)))
    (local.set $prod (f32x4.mul
      (f32x4.add (local.get $prod) (f32x4.mul (local.get $swapped) (v128.const f32x4 1.0 -1.0 1.0 -1.0)))
      (v128.const f32x4 0.7071068 0.7071068 0.7071068 0.7071068)))
    (local.set $prod (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31
      (local.get $t2) (local.get $prod)))
    (local.set $swapped (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7
      (local.get $prod) (local.get $prod)))
    (local.set $d2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $prod) (local.get $swapped))
      (f32x4.sub (local.get $prod) (local.get $swapped))))  ;; d2 = [out2, out10]

    ;; t3: [6,14] -> butterfly with W_16^6 = (-0.7071068, -0.7071068)
    (local.set $prod (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15
      (local.get $t3) (local.get $t3)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3
      (local.get $prod) (local.get $prod)))
    (local.set $prod (f32x4.mul
      (f32x4.sub (local.get $swapped) (f32x4.mul (local.get $prod) (v128.const f32x4 1.0 -1.0 1.0 -1.0)))
      (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068)))
    (local.set $prod (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31
      (local.get $t3) (local.get $prod)))
    (local.set $swapped (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7
      (local.get $prod) (local.get $prod)))
    (local.set $d6 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $prod) (local.get $swapped))
      (f32x4.sub (local.get $prod) (local.get $swapped))))  ;; d6 = [out6, out14]

    ;; t4: [1,9] -> butterfly with W_16^1 = (0.9238795, -0.3826834)
    (local.set $prod (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15
      (local.get $t4) (local.get $t4)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3
      (local.get $prod) (local.get $prod)))
    ;; b*W = [b.re*0.9238795 + b.im*0.3826834, b.im*0.9238795 - b.re*0.3826834]
    (local.set $prod (f32x4.add
      (f32x4.mul (local.get $prod) (v128.const f32x4 0.9238795 0.9238795 0.9238795 0.9238795))
      (f32x4.mul (local.get $swapped) (v128.const f32x4 0.3826834 -0.3826834 0.3826834 -0.3826834))))
    (local.set $prod (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31
      (local.get $t4) (local.get $prod)))
    (local.set $swapped (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7
      (local.get $prod) (local.get $prod)))
    (local.set $d1 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $prod) (local.get $swapped))
      (f32x4.sub (local.get $prod) (local.get $swapped))))  ;; d1 = [out1, out9]

    ;; t5: [5,13] -> butterfly with W_16^5 = (-0.3826834, -0.9238795)
    (local.set $prod (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15
      (local.get $t5) (local.get $t5)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3
      (local.get $prod) (local.get $prod)))
    ;; b*W = [b.re*(-0.3826834) + b.im*0.9238795, b.im*(-0.3826834) - b.re*0.9238795]
    (local.set $prod (f32x4.add
      (f32x4.mul (local.get $prod) (v128.const f32x4 -0.3826834 -0.3826834 -0.3826834 -0.3826834))
      (f32x4.mul (local.get $swapped) (v128.const f32x4 0.9238795 -0.9238795 0.9238795 -0.9238795))))
    (local.set $prod (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31
      (local.get $t5) (local.get $prod)))
    (local.set $swapped (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7
      (local.get $prod) (local.get $prod)))
    (local.set $d5 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $prod) (local.get $swapped))
      (f32x4.sub (local.get $prod) (local.get $swapped))))  ;; d5 = [out5, out13]

    ;; t6: [3,11] -> butterfly with W_16^3 = (0.3826834, -0.9238795)
    (local.set $prod (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15
      (local.get $t6) (local.get $t6)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3
      (local.get $prod) (local.get $prod)))
    ;; b*W = [b.re*0.3826834 + b.im*0.9238795, b.im*0.3826834 - b.re*0.9238795]
    (local.set $prod (f32x4.add
      (f32x4.mul (local.get $prod) (v128.const f32x4 0.3826834 0.3826834 0.3826834 0.3826834))
      (f32x4.mul (local.get $swapped) (v128.const f32x4 0.9238795 -0.9238795 0.9238795 -0.9238795))))
    (local.set $prod (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31
      (local.get $t6) (local.get $prod)))
    (local.set $swapped (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7
      (local.get $prod) (local.get $prod)))
    (local.set $d3 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $prod) (local.get $swapped))
      (f32x4.sub (local.get $prod) (local.get $swapped))))  ;; d3 = [out3, out11]

    ;; t7: [7,15] -> butterfly with W_16^7 = (-0.9238795, -0.3826834)
    (local.set $prod (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15
      (local.get $t7) (local.get $t7)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3
      (local.get $prod) (local.get $prod)))
    ;; b*W = [b.re*(-0.9238795) + b.im*0.3826834, b.im*(-0.9238795) - b.re*0.3826834]
    (local.set $prod (f32x4.add
      (f32x4.mul (local.get $prod) (v128.const f32x4 -0.9238795 -0.9238795 -0.9238795 -0.9238795))
      (f32x4.mul (local.get $swapped) (v128.const f32x4 0.3826834 -0.3826834 0.3826834 -0.3826834))))
    (local.set $prod (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31
      (local.get $t7) (local.get $prod)))
    (local.set $swapped (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7
      (local.get $prod) (local.get $prod)))
    (local.set $d7 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $prod) (local.get $swapped))
      (f32x4.sub (local.get $prod) (local.get $swapped))))  ;; d7 = [out7, out15]

    ;; ============ Store in natural order ============
    ;; d0=[out0,out8], d1=[out1,out9], d2=[out2,out10], d3=[out3,out11]
    ;; d4=[out4,out12], d5=[out5,out13], d6=[out6,out14], d7=[out7,out15]
    ;; Need to store: [out0,out1], [out2,out3], [out4,out5], [out6,out7],
    ;;                [out8,out9], [out10,out11], [out12,out13], [out14,out15]

    (v128.store (i32.const 0)
      (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $d0) (local.get $d1)))
    (v128.store (i32.const 16)
      (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $d2) (local.get $d3)))
    (v128.store (i32.const 32)
      (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $d4) (local.get $d5)))
    (v128.store (i32.const 48)
      (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $d6) (local.get $d7)))
    (v128.store (i32.const 64)
      (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $d0) (local.get $d1)))
    (v128.store (i32.const 80)
      (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $d2) (local.get $d3)))
    (v128.store (i32.const 96)
      (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $d4) (local.get $d5)))
    (v128.store (i32.const 112)
      (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $d6) (local.get $d7)))
  )

  ;; ============================================================================
  ;; N=32 DIT Dual-Complex Kernel (natural order output) - GENERATED
  ;; ============================================================================
  ;; 32 complex numbers = 16 dual-packed v128 values
  ;; Generated by: node tools/generate-dit-codelet.js 32

  (func $fft_32_dit
    (local $d0 v128) (local $d1 v128) (local $d2 v128) (local $d3 v128) (local $d4 v128) (local $d5 v128) (local $d6 v128) (local $d7 v128) (local $d8 v128) (local $d9 v128) (local $d10 v128) (local $d11 v128) (local $d12 v128) (local $d13 v128) (local $d14 v128) (local $d15 v128)
    (local $t0 v128) (local $t1 v128) (local $t2 v128) (local $t3 v128) (local $t4 v128) (local $t5 v128) (local $t6 v128) (local $t7 v128) (local $t8 v128) (local $t9 v128) (local $t10 v128) (local $t11 v128) (local $t12 v128) (local $t13 v128) (local $t14 v128) (local $t15 v128)
    (local $u0 v128) (local $u1 v128) (local $u2 v128) (local $u3 v128) (local $u4 v128) (local $u5 v128) (local $u6 v128) (local $u7 v128) (local $u8 v128) (local $u9 v128) (local $u10 v128) (local $u11 v128) (local $u12 v128) (local $u13 v128) (local $u14 v128) (local $u15 v128)
    (local $v0 v128) (local $v1 v128) (local $v2 v128) (local $v3 v128) (local $v4 v128) (local $v5 v128) (local $v6 v128) (local $v7 v128) (local $v8 v128) (local $v9 v128) (local $v10 v128) (local $v11 v128) (local $v12 v128) (local $v13 v128) (local $v14 v128) (local $v15 v128)
    (local $tmp v128) (local $tmp2 v128) (local $a v128) (local $b v128)

    ;; ============ Load in bit-reversed order ============
    (local.set $d0 (v128.load64_lane 1 (i32.const 128) (v128.load64_zero (i32.const 0))))
    (local.set $d1 (v128.load64_lane 1 (i32.const 192) (v128.load64_zero (i32.const 64))))
    (local.set $d2 (v128.load64_lane 1 (i32.const 160) (v128.load64_zero (i32.const 32))))
    (local.set $d3 (v128.load64_lane 1 (i32.const 224) (v128.load64_zero (i32.const 96))))
    (local.set $d4 (v128.load64_lane 1 (i32.const 144) (v128.load64_zero (i32.const 16))))
    (local.set $d5 (v128.load64_lane 1 (i32.const 208) (v128.load64_zero (i32.const 80))))
    (local.set $d6 (v128.load64_lane 1 (i32.const 176) (v128.load64_zero (i32.const 48))))
    (local.set $d7 (v128.load64_lane 1 (i32.const 240) (v128.load64_zero (i32.const 112))))
    (local.set $d8 (v128.load64_lane 1 (i32.const 136) (v128.load64_zero (i32.const 8))))
    (local.set $d9 (v128.load64_lane 1 (i32.const 200) (v128.load64_zero (i32.const 72))))
    (local.set $d10 (v128.load64_lane 1 (i32.const 168) (v128.load64_zero (i32.const 40))))
    (local.set $d11 (v128.load64_lane 1 (i32.const 232) (v128.load64_zero (i32.const 104))))
    (local.set $d12 (v128.load64_lane 1 (i32.const 152) (v128.load64_zero (i32.const 24))))
    (local.set $d13 (v128.load64_lane 1 (i32.const 216) (v128.load64_zero (i32.const 88))))
    (local.set $d14 (v128.load64_lane 1 (i32.const 184) (v128.load64_zero (i32.const 56))))
    (local.set $d15 (v128.load64_lane 1 (i32.const 248) (v128.load64_zero (i32.const 120))))

    ;; ============ Stage 1 (span 1): W_2 twiddles ============
    ;; Butterfly (0,1): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d0) (local.get $d0)))
    (local.set $t0 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d0) (local.get $tmp))
      (f32x4.sub (local.get $d0) (local.get $tmp))))
    ;; Butterfly (2,3): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d1) (local.get $d1)))
    (local.set $t1 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d1) (local.get $tmp))
      (f32x4.sub (local.get $d1) (local.get $tmp))))
    ;; Butterfly (4,5): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d2) (local.get $d2)))
    (local.set $t2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d2) (local.get $tmp))
      (f32x4.sub (local.get $d2) (local.get $tmp))))
    ;; Butterfly (6,7): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d3) (local.get $d3)))
    (local.set $t3 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d3) (local.get $tmp))
      (f32x4.sub (local.get $d3) (local.get $tmp))))
    ;; Butterfly (8,9): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d4) (local.get $d4)))
    (local.set $t4 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d4) (local.get $tmp))
      (f32x4.sub (local.get $d4) (local.get $tmp))))
    ;; Butterfly (10,11): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d5) (local.get $d5)))
    (local.set $t5 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d5) (local.get $tmp))
      (f32x4.sub (local.get $d5) (local.get $tmp))))
    ;; Butterfly (12,13): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d6) (local.get $d6)))
    (local.set $t6 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d6) (local.get $tmp))
      (f32x4.sub (local.get $d6) (local.get $tmp))))
    ;; Butterfly (14,15): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d7) (local.get $d7)))
    (local.set $t7 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d7) (local.get $tmp))
      (f32x4.sub (local.get $d7) (local.get $tmp))))
    ;; Butterfly (16,17): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d8) (local.get $d8)))
    (local.set $t8 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d8) (local.get $tmp))
      (f32x4.sub (local.get $d8) (local.get $tmp))))
    ;; Butterfly (18,19): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d9) (local.get $d9)))
    (local.set $t9 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d9) (local.get $tmp))
      (f32x4.sub (local.get $d9) (local.get $tmp))))
    ;; Butterfly (20,21): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d10) (local.get $d10)))
    (local.set $t10 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d10) (local.get $tmp))
      (f32x4.sub (local.get $d10) (local.get $tmp))))
    ;; Butterfly (22,23): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d11) (local.get $d11)))
    (local.set $t11 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d11) (local.get $tmp))
      (f32x4.sub (local.get $d11) (local.get $tmp))))
    ;; Butterfly (24,25): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d12) (local.get $d12)))
    (local.set $t12 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d12) (local.get $tmp))
      (f32x4.sub (local.get $d12) (local.get $tmp))))
    ;; Butterfly (26,27): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d13) (local.get $d13)))
    (local.set $t13 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d13) (local.get $tmp))
      (f32x4.sub (local.get $d13) (local.get $tmp))))
    ;; Butterfly (28,29): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d14) (local.get $d14)))
    (local.set $t14 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d14) (local.get $tmp))
      (f32x4.sub (local.get $d14) (local.get $tmp))))
    ;; Butterfly (30,31): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d15) (local.get $d15)))
    (local.set $t15 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d15) (local.get $tmp))
      (f32x4.sub (local.get $d15) (local.get $tmp))))

    ;; ============ Stage 2 (span 2): W_4 twiddles ============
    ;; Butterflies (0,2) and (1,3)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $t0) (local.get $t1))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $t0) (local.get $t1))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $b) (local.get $b)))
    (local.set $b (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $u0 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $u1 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (4,6) and (5,7)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $t2) (local.get $t3))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $t2) (local.get $t3))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $b) (local.get $b)))
    (local.set $b (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $u2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $u3 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (8,10) and (9,11)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $t4) (local.get $t5))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $t4) (local.get $t5))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $b) (local.get $b)))
    (local.set $b (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $u4 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $u5 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (12,14) and (13,15)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $t6) (local.get $t7))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $t6) (local.get $t7))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $b) (local.get $b)))
    (local.set $b (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $u6 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $u7 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (16,18) and (17,19)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $t8) (local.get $t9))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $t8) (local.get $t9))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $b) (local.get $b)))
    (local.set $b (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $u8 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $u9 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (20,22) and (21,23)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $t10) (local.get $t11))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $t10) (local.get $t11))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $b) (local.get $b)))
    (local.set $b (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $u10 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $u11 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (24,26) and (25,27)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $t12) (local.get $t13))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $t12) (local.get $t13))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $b) (local.get $b)))
    (local.set $b (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $u12 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $u13 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (28,30) and (29,31)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $t14) (local.get $t15))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $t14) (local.get $t15))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $b) (local.get $b)))
    (local.set $b (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $u14 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $u15 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))

    ;; ============ Stage 3 (span 4): W_8 twiddles ============
    ;; Butterflies (0,4) and (1,5)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $u0) (local.get $u2))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $u0) (local.get $u2))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.7071068 0.7071068 0.7071068 0.7071068))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $v0 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $v2 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (2,6) and (3,7)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $u1) (local.get $u3))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $u1) (local.get $u3))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $a) (local.get $a)))
    (local.set $a (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.7071068 -0.7071068 -0.7071068 -0.7071068))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $v1 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $v3 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (8,12) and (9,13)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $u4) (local.get $u6))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $u4) (local.get $u6))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.7071068 0.7071068 0.7071068 0.7071068))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $v4 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $v6 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (10,14) and (11,15)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $u5) (local.get $u7))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $u5) (local.get $u7))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $a) (local.get $a)))
    (local.set $a (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.7071068 -0.7071068 -0.7071068 -0.7071068))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $v5 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $v7 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (16,20) and (17,21)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $u8) (local.get $u10))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $u8) (local.get $u10))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.7071068 0.7071068 0.7071068 0.7071068))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $v8 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $v10 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (18,22) and (19,23)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $u9) (local.get $u11))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $u9) (local.get $u11))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $a) (local.get $a)))
    (local.set $a (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.7071068 -0.7071068 -0.7071068 -0.7071068))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $v9 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $v11 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (24,28) and (25,29)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $u12) (local.get $u14))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $u12) (local.get $u14))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.7071068 0.7071068 0.7071068 0.7071068))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $v12 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $v14 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (26,30) and (27,31)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $u13) (local.get $u15))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $u13) (local.get $u15))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $a) (local.get $a)))
    (local.set $a (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.7071068 -0.7071068 -0.7071068 -0.7071068))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $v13 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $v15 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))

    ;; ============ Stage 4 (span 8): W_16 twiddles ============
    ;; Butterflies (0,8) and (1,9)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $v0) (local.get $v4))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $v0) (local.get $v4))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.9238795 0.9238795 0.9238795 0.9238795))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.3826834 -0.3826834 0.3826834 -0.3826834))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $d0 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $d4 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (2,10) and (3,11)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $v1) (local.get $v5))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $v1) (local.get $v5))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $a) (local.get $a)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.7071068 0.7071068 0.7071068 0.7071068))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $a) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.3826834 0.3826834 0.3826834 0.3826834))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.9238795 -0.9238795 0.9238795 -0.9238795))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $d1 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $d5 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (4,12) and (5,13)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $v2) (local.get $v6))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $v2) (local.get $v6))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $a) (local.get $a)))
    (local.set $a (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.3826834 -0.3826834 -0.3826834 -0.3826834))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.9238795 -0.9238795 0.9238795 -0.9238795))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $d2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $d6 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (6,14) and (7,15)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $v3) (local.get $v7))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $v3) (local.get $v7))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $a) (local.get $a)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.7071068 -0.7071068 -0.7071068 -0.7071068))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $a) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.9238795 -0.9238795 -0.9238795 -0.9238795))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.3826834 -0.3826834 0.3826834 -0.3826834))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $d3 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $d7 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (16,24) and (17,25)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $v8) (local.get $v12))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $v8) (local.get $v12))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.9238795 0.9238795 0.9238795 0.9238795))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.3826834 -0.3826834 0.3826834 -0.3826834))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $d8 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $d12 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (18,26) and (19,27)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $v9) (local.get $v13))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $v9) (local.get $v13))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $a) (local.get $a)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.7071068 0.7071068 0.7071068 0.7071068))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $a) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.3826834 0.3826834 0.3826834 0.3826834))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.9238795 -0.9238795 0.9238795 -0.9238795))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $d9 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $d13 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (20,28) and (21,29)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $v10) (local.get $v14))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $v10) (local.get $v14))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $a) (local.get $a)))
    (local.set $a (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.3826834 -0.3826834 -0.3826834 -0.3826834))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.9238795 -0.9238795 0.9238795 -0.9238795))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $d10 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $d14 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (22,30) and (23,31)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $v11) (local.get $v15))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $v11) (local.get $v15))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $a) (local.get $a)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.7071068 -0.7071068 -0.7071068 -0.7071068))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $a) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.9238795 -0.9238795 -0.9238795 -0.9238795))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.3826834 -0.3826834 0.3826834 -0.3826834))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $d11 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $d15 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))

    ;; ============ Stage 5 (span 16): W_32 twiddles ============
    ;; Butterflies (0,16) and (1,17)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $d0) (local.get $d8))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $d0) (local.get $d8))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.9807853 0.9807853 0.9807853 0.9807853))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.1950903 -0.1950903 0.1950903 -0.1950903))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $t0 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $t8 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (2,18) and (3,19)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $d1) (local.get $d9))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $d1) (local.get $d9))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $a) (local.get $a)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.9238795 0.9238795 0.9238795 0.9238795))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.3826834 -0.3826834 0.3826834 -0.3826834))))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $a) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.8314696 0.8314696 0.8314696 0.8314696))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.5555702 -0.5555702 0.5555702 -0.5555702))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $t1 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $t9 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (4,20) and (5,21)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $d2) (local.get $d10))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $d2) (local.get $d10))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $a) (local.get $a)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.7071068 0.7071068 0.7071068 0.7071068))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $a) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.5555702 0.5555702 0.5555702 0.5555702))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.8314696 -0.8314696 0.8314696 -0.8314696))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $t2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $t10 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (6,22) and (7,23)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $d3) (local.get $d11))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $d3) (local.get $d11))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $a) (local.get $a)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.3826834 0.3826834 0.3826834 0.3826834))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.9238795 -0.9238795 0.9238795 -0.9238795))))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $a) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.1950903 0.1950903 0.1950903 0.1950903))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.9807853 -0.9807853 0.9807853 -0.9807853))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $t3 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $t11 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (8,24) and (9,25)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $d4) (local.get $d12))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $d4) (local.get $d12))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $a) (local.get $a)))
    (local.set $a (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.1950903 -0.1950903 -0.1950903 -0.1950903))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.9807853 -0.9807853 0.9807853 -0.9807853))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $t4 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $t12 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (10,26) and (11,27)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $d5) (local.get $d13))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $d5) (local.get $d13))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $a) (local.get $a)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.3826834 -0.3826834 -0.3826834 -0.3826834))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.9238795 -0.9238795 0.9238795 -0.9238795))))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $a) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.5555702 -0.5555702 -0.5555702 -0.5555702))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.8314696 -0.8314696 0.8314696 -0.8314696))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $t5 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $t13 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (12,28) and (13,29)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $d6) (local.get $d14))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $d6) (local.get $d14))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $a) (local.get $a)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.7071068 -0.7071068 -0.7071068 -0.7071068))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $a) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.8314696 -0.8314696 -0.8314696 -0.8314696))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.5555702 -0.5555702 0.5555702 -0.5555702))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $t6 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $t14 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (14,30) and (15,31)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $d7) (local.get $d15))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $d7) (local.get $d15))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $a) (local.get $a)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.9238795 -0.9238795 -0.9238795 -0.9238795))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.3826834 -0.3826834 0.3826834 -0.3826834))))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $a) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.9807853 -0.9807853 -0.9807853 -0.9807853))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.1950903 -0.1950903 0.1950903 -0.1950903))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $t7 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $t15 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))

    ;; ============ Store in natural order ============
    (v128.store (i32.const 0) (local.get $t0))
    (v128.store (i32.const 16) (local.get $t1))
    (v128.store (i32.const 32) (local.get $t2))
    (v128.store (i32.const 48) (local.get $t3))
    (v128.store (i32.const 64) (local.get $t4))
    (v128.store (i32.const 80) (local.get $t5))
    (v128.store (i32.const 96) (local.get $t6))
    (v128.store (i32.const 112) (local.get $t7))
    (v128.store (i32.const 128) (local.get $t8))
    (v128.store (i32.const 144) (local.get $t9))
    (v128.store (i32.const 160) (local.get $t10))
    (v128.store (i32.const 176) (local.get $t11))
    (v128.store (i32.const 192) (local.get $t12))
    (v128.store (i32.const 208) (local.get $t13))
    (v128.store (i32.const 224) (local.get $t14))
    (v128.store (i32.const 240) (local.get $t15))
  )



  ;; ============================================================================
  ;; N=64 DIT Dual-Complex Kernel (natural order output) - GENERATED
  ;; ============================================================================
  ;; 64 complex numbers = 32 dual-packed v128 values
  ;; Generated by: node tools/generate-dit-codelet.js 64

  (func $fft_64_dit
    (local $d0 v128) (local $d1 v128) (local $d2 v128) (local $d3 v128) (local $d4 v128) (local $d5 v128) (local $d6 v128) (local $d7 v128) (local $d8 v128) (local $d9 v128) (local $d10 v128) (local $d11 v128) (local $d12 v128) (local $d13 v128) (local $d14 v128) (local $d15 v128) (local $d16 v128) (local $d17 v128) (local $d18 v128) (local $d19 v128) (local $d20 v128) (local $d21 v128) (local $d22 v128) (local $d23 v128) (local $d24 v128) (local $d25 v128) (local $d26 v128) (local $d27 v128) (local $d28 v128) (local $d29 v128) (local $d30 v128) (local $d31 v128)
    (local $t0 v128) (local $t1 v128) (local $t2 v128) (local $t3 v128) (local $t4 v128) (local $t5 v128) (local $t6 v128) (local $t7 v128) (local $t8 v128) (local $t9 v128) (local $t10 v128) (local $t11 v128) (local $t12 v128) (local $t13 v128) (local $t14 v128) (local $t15 v128) (local $t16 v128) (local $t17 v128) (local $t18 v128) (local $t19 v128) (local $t20 v128) (local $t21 v128) (local $t22 v128) (local $t23 v128) (local $t24 v128) (local $t25 v128) (local $t26 v128) (local $t27 v128) (local $t28 v128) (local $t29 v128) (local $t30 v128) (local $t31 v128)
    (local $u0 v128) (local $u1 v128) (local $u2 v128) (local $u3 v128) (local $u4 v128) (local $u5 v128) (local $u6 v128) (local $u7 v128) (local $u8 v128) (local $u9 v128) (local $u10 v128) (local $u11 v128) (local $u12 v128) (local $u13 v128) (local $u14 v128) (local $u15 v128) (local $u16 v128) (local $u17 v128) (local $u18 v128) (local $u19 v128) (local $u20 v128) (local $u21 v128) (local $u22 v128) (local $u23 v128) (local $u24 v128) (local $u25 v128) (local $u26 v128) (local $u27 v128) (local $u28 v128) (local $u29 v128) (local $u30 v128) (local $u31 v128)
    (local $v0 v128) (local $v1 v128) (local $v2 v128) (local $v3 v128) (local $v4 v128) (local $v5 v128) (local $v6 v128) (local $v7 v128) (local $v8 v128) (local $v9 v128) (local $v10 v128) (local $v11 v128) (local $v12 v128) (local $v13 v128) (local $v14 v128) (local $v15 v128) (local $v16 v128) (local $v17 v128) (local $v18 v128) (local $v19 v128) (local $v20 v128) (local $v21 v128) (local $v22 v128) (local $v23 v128) (local $v24 v128) (local $v25 v128) (local $v26 v128) (local $v27 v128) (local $v28 v128) (local $v29 v128) (local $v30 v128) (local $v31 v128)
    (local $tmp v128) (local $tmp2 v128) (local $a v128) (local $b v128)

    ;; ============ Load in bit-reversed order ============
    (local.set $d0 (v128.load64_lane 1 (i32.const 256) (v128.load64_zero (i32.const 0))))
    (local.set $d1 (v128.load64_lane 1 (i32.const 384) (v128.load64_zero (i32.const 128))))
    (local.set $d2 (v128.load64_lane 1 (i32.const 320) (v128.load64_zero (i32.const 64))))
    (local.set $d3 (v128.load64_lane 1 (i32.const 448) (v128.load64_zero (i32.const 192))))
    (local.set $d4 (v128.load64_lane 1 (i32.const 288) (v128.load64_zero (i32.const 32))))
    (local.set $d5 (v128.load64_lane 1 (i32.const 416) (v128.load64_zero (i32.const 160))))
    (local.set $d6 (v128.load64_lane 1 (i32.const 352) (v128.load64_zero (i32.const 96))))
    (local.set $d7 (v128.load64_lane 1 (i32.const 480) (v128.load64_zero (i32.const 224))))
    (local.set $d8 (v128.load64_lane 1 (i32.const 272) (v128.load64_zero (i32.const 16))))
    (local.set $d9 (v128.load64_lane 1 (i32.const 400) (v128.load64_zero (i32.const 144))))
    (local.set $d10 (v128.load64_lane 1 (i32.const 336) (v128.load64_zero (i32.const 80))))
    (local.set $d11 (v128.load64_lane 1 (i32.const 464) (v128.load64_zero (i32.const 208))))
    (local.set $d12 (v128.load64_lane 1 (i32.const 304) (v128.load64_zero (i32.const 48))))
    (local.set $d13 (v128.load64_lane 1 (i32.const 432) (v128.load64_zero (i32.const 176))))
    (local.set $d14 (v128.load64_lane 1 (i32.const 368) (v128.load64_zero (i32.const 112))))
    (local.set $d15 (v128.load64_lane 1 (i32.const 496) (v128.load64_zero (i32.const 240))))
    (local.set $d16 (v128.load64_lane 1 (i32.const 264) (v128.load64_zero (i32.const 8))))
    (local.set $d17 (v128.load64_lane 1 (i32.const 392) (v128.load64_zero (i32.const 136))))
    (local.set $d18 (v128.load64_lane 1 (i32.const 328) (v128.load64_zero (i32.const 72))))
    (local.set $d19 (v128.load64_lane 1 (i32.const 456) (v128.load64_zero (i32.const 200))))
    (local.set $d20 (v128.load64_lane 1 (i32.const 296) (v128.load64_zero (i32.const 40))))
    (local.set $d21 (v128.load64_lane 1 (i32.const 424) (v128.load64_zero (i32.const 168))))
    (local.set $d22 (v128.load64_lane 1 (i32.const 360) (v128.load64_zero (i32.const 104))))
    (local.set $d23 (v128.load64_lane 1 (i32.const 488) (v128.load64_zero (i32.const 232))))
    (local.set $d24 (v128.load64_lane 1 (i32.const 280) (v128.load64_zero (i32.const 24))))
    (local.set $d25 (v128.load64_lane 1 (i32.const 408) (v128.load64_zero (i32.const 152))))
    (local.set $d26 (v128.load64_lane 1 (i32.const 344) (v128.load64_zero (i32.const 88))))
    (local.set $d27 (v128.load64_lane 1 (i32.const 472) (v128.load64_zero (i32.const 216))))
    (local.set $d28 (v128.load64_lane 1 (i32.const 312) (v128.load64_zero (i32.const 56))))
    (local.set $d29 (v128.load64_lane 1 (i32.const 440) (v128.load64_zero (i32.const 184))))
    (local.set $d30 (v128.load64_lane 1 (i32.const 376) (v128.load64_zero (i32.const 120))))
    (local.set $d31 (v128.load64_lane 1 (i32.const 504) (v128.load64_zero (i32.const 248))))

    ;; ============ Stage 1 (span 1): W_2 twiddles ============
    ;; Butterfly (0,1): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d0) (local.get $d0)))
    (local.set $t0 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d0) (local.get $tmp))
      (f32x4.sub (local.get $d0) (local.get $tmp))))
    ;; Butterfly (2,3): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d1) (local.get $d1)))
    (local.set $t1 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d1) (local.get $tmp))
      (f32x4.sub (local.get $d1) (local.get $tmp))))
    ;; Butterfly (4,5): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d2) (local.get $d2)))
    (local.set $t2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d2) (local.get $tmp))
      (f32x4.sub (local.get $d2) (local.get $tmp))))
    ;; Butterfly (6,7): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d3) (local.get $d3)))
    (local.set $t3 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d3) (local.get $tmp))
      (f32x4.sub (local.get $d3) (local.get $tmp))))
    ;; Butterfly (8,9): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d4) (local.get $d4)))
    (local.set $t4 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d4) (local.get $tmp))
      (f32x4.sub (local.get $d4) (local.get $tmp))))
    ;; Butterfly (10,11): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d5) (local.get $d5)))
    (local.set $t5 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d5) (local.get $tmp))
      (f32x4.sub (local.get $d5) (local.get $tmp))))
    ;; Butterfly (12,13): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d6) (local.get $d6)))
    (local.set $t6 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d6) (local.get $tmp))
      (f32x4.sub (local.get $d6) (local.get $tmp))))
    ;; Butterfly (14,15): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d7) (local.get $d7)))
    (local.set $t7 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d7) (local.get $tmp))
      (f32x4.sub (local.get $d7) (local.get $tmp))))
    ;; Butterfly (16,17): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d8) (local.get $d8)))
    (local.set $t8 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d8) (local.get $tmp))
      (f32x4.sub (local.get $d8) (local.get $tmp))))
    ;; Butterfly (18,19): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d9) (local.get $d9)))
    (local.set $t9 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d9) (local.get $tmp))
      (f32x4.sub (local.get $d9) (local.get $tmp))))
    ;; Butterfly (20,21): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d10) (local.get $d10)))
    (local.set $t10 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d10) (local.get $tmp))
      (f32x4.sub (local.get $d10) (local.get $tmp))))
    ;; Butterfly (22,23): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d11) (local.get $d11)))
    (local.set $t11 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d11) (local.get $tmp))
      (f32x4.sub (local.get $d11) (local.get $tmp))))
    ;; Butterfly (24,25): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d12) (local.get $d12)))
    (local.set $t12 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d12) (local.get $tmp))
      (f32x4.sub (local.get $d12) (local.get $tmp))))
    ;; Butterfly (26,27): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d13) (local.get $d13)))
    (local.set $t13 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d13) (local.get $tmp))
      (f32x4.sub (local.get $d13) (local.get $tmp))))
    ;; Butterfly (28,29): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d14) (local.get $d14)))
    (local.set $t14 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d14) (local.get $tmp))
      (f32x4.sub (local.get $d14) (local.get $tmp))))
    ;; Butterfly (30,31): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d15) (local.get $d15)))
    (local.set $t15 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d15) (local.get $tmp))
      (f32x4.sub (local.get $d15) (local.get $tmp))))
    ;; Butterfly (32,33): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d16) (local.get $d16)))
    (local.set $t16 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d16) (local.get $tmp))
      (f32x4.sub (local.get $d16) (local.get $tmp))))
    ;; Butterfly (34,35): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d17) (local.get $d17)))
    (local.set $t17 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d17) (local.get $tmp))
      (f32x4.sub (local.get $d17) (local.get $tmp))))
    ;; Butterfly (36,37): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d18) (local.get $d18)))
    (local.set $t18 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d18) (local.get $tmp))
      (f32x4.sub (local.get $d18) (local.get $tmp))))
    ;; Butterfly (38,39): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d19) (local.get $d19)))
    (local.set $t19 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d19) (local.get $tmp))
      (f32x4.sub (local.get $d19) (local.get $tmp))))
    ;; Butterfly (40,41): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d20) (local.get $d20)))
    (local.set $t20 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d20) (local.get $tmp))
      (f32x4.sub (local.get $d20) (local.get $tmp))))
    ;; Butterfly (42,43): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d21) (local.get $d21)))
    (local.set $t21 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d21) (local.get $tmp))
      (f32x4.sub (local.get $d21) (local.get $tmp))))
    ;; Butterfly (44,45): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d22) (local.get $d22)))
    (local.set $t22 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d22) (local.get $tmp))
      (f32x4.sub (local.get $d22) (local.get $tmp))))
    ;; Butterfly (46,47): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d23) (local.get $d23)))
    (local.set $t23 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d23) (local.get $tmp))
      (f32x4.sub (local.get $d23) (local.get $tmp))))
    ;; Butterfly (48,49): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d24) (local.get $d24)))
    (local.set $t24 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d24) (local.get $tmp))
      (f32x4.sub (local.get $d24) (local.get $tmp))))
    ;; Butterfly (50,51): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d25) (local.get $d25)))
    (local.set $t25 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d25) (local.get $tmp))
      (f32x4.sub (local.get $d25) (local.get $tmp))))
    ;; Butterfly (52,53): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d26) (local.get $d26)))
    (local.set $t26 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d26) (local.get $tmp))
      (f32x4.sub (local.get $d26) (local.get $tmp))))
    ;; Butterfly (54,55): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d27) (local.get $d27)))
    (local.set $t27 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d27) (local.get $tmp))
      (f32x4.sub (local.get $d27) (local.get $tmp))))
    ;; Butterfly (56,57): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d28) (local.get $d28)))
    (local.set $t28 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d28) (local.get $tmp))
      (f32x4.sub (local.get $d28) (local.get $tmp))))
    ;; Butterfly (58,59): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d29) (local.get $d29)))
    (local.set $t29 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d29) (local.get $tmp))
      (f32x4.sub (local.get $d29) (local.get $tmp))))
    ;; Butterfly (60,61): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d30) (local.get $d30)))
    (local.set $t30 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d30) (local.get $tmp))
      (f32x4.sub (local.get $d30) (local.get $tmp))))
    ;; Butterfly (62,63): within-reg, W_2^0=ONE
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d31) (local.get $d31)))
    (local.set $t31 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $d31) (local.get $tmp))
      (f32x4.sub (local.get $d31) (local.get $tmp))))

    ;; ============ Stage 2 (span 2): W_4 twiddles ============
    ;; Butterflies (0,2) and (1,3)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $t0) (local.get $t1))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $t0) (local.get $t1))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $b) (local.get $b)))
    (local.set $b (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $u0 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $u1 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (4,6) and (5,7)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $t2) (local.get $t3))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $t2) (local.get $t3))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $b) (local.get $b)))
    (local.set $b (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $u2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $u3 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (8,10) and (9,11)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $t4) (local.get $t5))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $t4) (local.get $t5))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $b) (local.get $b)))
    (local.set $b (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $u4 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $u5 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (12,14) and (13,15)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $t6) (local.get $t7))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $t6) (local.get $t7))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $b) (local.get $b)))
    (local.set $b (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $u6 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $u7 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (16,18) and (17,19)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $t8) (local.get $t9))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $t8) (local.get $t9))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $b) (local.get $b)))
    (local.set $b (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $u8 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $u9 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (20,22) and (21,23)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $t10) (local.get $t11))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $t10) (local.get $t11))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $b) (local.get $b)))
    (local.set $b (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $u10 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $u11 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (24,26) and (25,27)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $t12) (local.get $t13))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $t12) (local.get $t13))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $b) (local.get $b)))
    (local.set $b (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $u12 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $u13 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (28,30) and (29,31)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $t14) (local.get $t15))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $t14) (local.get $t15))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $b) (local.get $b)))
    (local.set $b (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $u14 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $u15 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (32,34) and (33,35)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $t16) (local.get $t17))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $t16) (local.get $t17))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $b) (local.get $b)))
    (local.set $b (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $u16 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $u17 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (36,38) and (37,39)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $t18) (local.get $t19))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $t18) (local.get $t19))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $b) (local.get $b)))
    (local.set $b (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $u18 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $u19 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (40,42) and (41,43)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $t20) (local.get $t21))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $t20) (local.get $t21))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $b) (local.get $b)))
    (local.set $b (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $u20 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $u21 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (44,46) and (45,47)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $t22) (local.get $t23))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $t22) (local.get $t23))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $b) (local.get $b)))
    (local.set $b (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $u22 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $u23 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (48,50) and (49,51)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $t24) (local.get $t25))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $t24) (local.get $t25))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $b) (local.get $b)))
    (local.set $b (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $u24 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $u25 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (52,54) and (53,55)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $t26) (local.get $t27))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $t26) (local.get $t27))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $b) (local.get $b)))
    (local.set $b (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $u26 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $u27 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (56,58) and (57,59)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $t28) (local.get $t29))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $t28) (local.get $t29))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $b) (local.get $b)))
    (local.set $b (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $u28 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $u29 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (60,62) and (61,63)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $t30) (local.get $t31))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $t30) (local.get $t31))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $b) (local.get $b)))
    (local.set $b (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $u30 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $u31 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))

    ;; ============ Stage 3 (span 4): W_8 twiddles ============
    ;; Butterflies (0,4) and (1,5)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $u0) (local.get $u2))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $u0) (local.get $u2))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.7071068 0.7071068 0.7071068 0.7071068))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $v0 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $v2 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (2,6) and (3,7)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $u1) (local.get $u3))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $u1) (local.get $u3))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $a) (local.get $a)))
    (local.set $a (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.7071068 -0.7071068 -0.7071068 -0.7071068))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $v1 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $v3 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (8,12) and (9,13)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $u4) (local.get $u6))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $u4) (local.get $u6))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.7071068 0.7071068 0.7071068 0.7071068))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $v4 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $v6 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (10,14) and (11,15)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $u5) (local.get $u7))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $u5) (local.get $u7))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $a) (local.get $a)))
    (local.set $a (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.7071068 -0.7071068 -0.7071068 -0.7071068))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $v5 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $v7 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (16,20) and (17,21)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $u8) (local.get $u10))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $u8) (local.get $u10))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.7071068 0.7071068 0.7071068 0.7071068))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $v8 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $v10 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (18,22) and (19,23)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $u9) (local.get $u11))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $u9) (local.get $u11))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $a) (local.get $a)))
    (local.set $a (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.7071068 -0.7071068 -0.7071068 -0.7071068))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $v9 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $v11 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (24,28) and (25,29)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $u12) (local.get $u14))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $u12) (local.get $u14))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.7071068 0.7071068 0.7071068 0.7071068))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $v12 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $v14 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (26,30) and (27,31)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $u13) (local.get $u15))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $u13) (local.get $u15))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $a) (local.get $a)))
    (local.set $a (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.7071068 -0.7071068 -0.7071068 -0.7071068))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $v13 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $v15 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (32,36) and (33,37)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $u16) (local.get $u18))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $u16) (local.get $u18))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.7071068 0.7071068 0.7071068 0.7071068))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $v16 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $v18 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (34,38) and (35,39)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $u17) (local.get $u19))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $u17) (local.get $u19))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $a) (local.get $a)))
    (local.set $a (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.7071068 -0.7071068 -0.7071068 -0.7071068))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $v17 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $v19 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (40,44) and (41,45)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $u20) (local.get $u22))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $u20) (local.get $u22))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.7071068 0.7071068 0.7071068 0.7071068))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $v20 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $v22 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (42,46) and (43,47)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $u21) (local.get $u23))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $u21) (local.get $u23))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $a) (local.get $a)))
    (local.set $a (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.7071068 -0.7071068 -0.7071068 -0.7071068))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $v21 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $v23 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (48,52) and (49,53)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $u24) (local.get $u26))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $u24) (local.get $u26))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.7071068 0.7071068 0.7071068 0.7071068))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $v24 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $v26 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (50,54) and (51,55)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $u25) (local.get $u27))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $u25) (local.get $u27))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $a) (local.get $a)))
    (local.set $a (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.7071068 -0.7071068 -0.7071068 -0.7071068))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $v25 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $v27 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (56,60) and (57,61)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $u28) (local.get $u30))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $u28) (local.get $u30))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.7071068 0.7071068 0.7071068 0.7071068))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $v28 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $v30 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (58,62) and (59,63)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $u29) (local.get $u31))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $u29) (local.get $u31))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $a) (local.get $a)))
    (local.set $a (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.7071068 -0.7071068 -0.7071068 -0.7071068))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $v29 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $v31 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))

    ;; ============ Stage 4 (span 8): W_16 twiddles ============
    ;; Butterflies (0,8) and (1,9)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $v0) (local.get $v4))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $v0) (local.get $v4))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.9238795 0.9238795 0.9238795 0.9238795))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.3826834 -0.3826834 0.3826834 -0.3826834))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $d0 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $d4 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (2,10) and (3,11)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $v1) (local.get $v5))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $v1) (local.get $v5))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $a) (local.get $a)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.7071068 0.7071068 0.7071068 0.7071068))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $a) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.3826834 0.3826834 0.3826834 0.3826834))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.9238795 -0.9238795 0.9238795 -0.9238795))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $d1 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $d5 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (4,12) and (5,13)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $v2) (local.get $v6))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $v2) (local.get $v6))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $a) (local.get $a)))
    (local.set $a (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.3826834 -0.3826834 -0.3826834 -0.3826834))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.9238795 -0.9238795 0.9238795 -0.9238795))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $d2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $d6 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (6,14) and (7,15)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $v3) (local.get $v7))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $v3) (local.get $v7))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $a) (local.get $a)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.7071068 -0.7071068 -0.7071068 -0.7071068))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $a) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.9238795 -0.9238795 -0.9238795 -0.9238795))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.3826834 -0.3826834 0.3826834 -0.3826834))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $d3 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $d7 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (16,24) and (17,25)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $v8) (local.get $v12))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $v8) (local.get $v12))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.9238795 0.9238795 0.9238795 0.9238795))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.3826834 -0.3826834 0.3826834 -0.3826834))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $d8 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $d12 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (18,26) and (19,27)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $v9) (local.get $v13))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $v9) (local.get $v13))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $a) (local.get $a)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.7071068 0.7071068 0.7071068 0.7071068))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $a) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.3826834 0.3826834 0.3826834 0.3826834))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.9238795 -0.9238795 0.9238795 -0.9238795))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $d9 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $d13 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (20,28) and (21,29)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $v10) (local.get $v14))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $v10) (local.get $v14))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $a) (local.get $a)))
    (local.set $a (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.3826834 -0.3826834 -0.3826834 -0.3826834))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.9238795 -0.9238795 0.9238795 -0.9238795))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $d10 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $d14 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (22,30) and (23,31)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $v11) (local.get $v15))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $v11) (local.get $v15))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $a) (local.get $a)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.7071068 -0.7071068 -0.7071068 -0.7071068))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $a) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.9238795 -0.9238795 -0.9238795 -0.9238795))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.3826834 -0.3826834 0.3826834 -0.3826834))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $d11 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $d15 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (32,40) and (33,41)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $v16) (local.get $v20))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $v16) (local.get $v20))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.9238795 0.9238795 0.9238795 0.9238795))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.3826834 -0.3826834 0.3826834 -0.3826834))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $d16 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $d20 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (34,42) and (35,43)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $v17) (local.get $v21))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $v17) (local.get $v21))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $a) (local.get $a)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.7071068 0.7071068 0.7071068 0.7071068))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $a) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.3826834 0.3826834 0.3826834 0.3826834))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.9238795 -0.9238795 0.9238795 -0.9238795))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $d17 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $d21 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (36,44) and (37,45)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $v18) (local.get $v22))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $v18) (local.get $v22))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $a) (local.get $a)))
    (local.set $a (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.3826834 -0.3826834 -0.3826834 -0.3826834))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.9238795 -0.9238795 0.9238795 -0.9238795))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $d18 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $d22 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (38,46) and (39,47)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $v19) (local.get $v23))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $v19) (local.get $v23))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $a) (local.get $a)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.7071068 -0.7071068 -0.7071068 -0.7071068))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $a) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.9238795 -0.9238795 -0.9238795 -0.9238795))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.3826834 -0.3826834 0.3826834 -0.3826834))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $d19 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $d23 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (48,56) and (49,57)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $v24) (local.get $v28))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $v24) (local.get $v28))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.9238795 0.9238795 0.9238795 0.9238795))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.3826834 -0.3826834 0.3826834 -0.3826834))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $d24 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $d28 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (50,58) and (51,59)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $v25) (local.get $v29))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $v25) (local.get $v29))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $a) (local.get $a)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.7071068 0.7071068 0.7071068 0.7071068))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $a) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.3826834 0.3826834 0.3826834 0.3826834))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.9238795 -0.9238795 0.9238795 -0.9238795))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $d25 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $d29 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (52,60) and (53,61)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $v26) (local.get $v30))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $v26) (local.get $v30))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $a) (local.get $a)))
    (local.set $a (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.3826834 -0.3826834 -0.3826834 -0.3826834))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.9238795 -0.9238795 0.9238795 -0.9238795))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $d26 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $d30 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (54,62) and (55,63)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $v27) (local.get $v31))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $v27) (local.get $v31))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $a) (local.get $a)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.7071068 -0.7071068 -0.7071068 -0.7071068))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $a) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.9238795 -0.9238795 -0.9238795 -0.9238795))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.3826834 -0.3826834 0.3826834 -0.3826834))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $d27 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $d31 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))

    ;; ============ Stage 5 (span 16): W_32 twiddles ============
    ;; Butterflies (0,16) and (1,17)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $d0) (local.get $d8))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $d0) (local.get $d8))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.9807853 0.9807853 0.9807853 0.9807853))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.1950903 -0.1950903 0.1950903 -0.1950903))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $t0 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $t8 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (2,18) and (3,19)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $d1) (local.get $d9))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $d1) (local.get $d9))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $a) (local.get $a)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.9238795 0.9238795 0.9238795 0.9238795))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.3826834 -0.3826834 0.3826834 -0.3826834))))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $a) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.8314696 0.8314696 0.8314696 0.8314696))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.5555702 -0.5555702 0.5555702 -0.5555702))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $t1 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $t9 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (4,20) and (5,21)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $d2) (local.get $d10))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $d2) (local.get $d10))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $a) (local.get $a)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.7071068 0.7071068 0.7071068 0.7071068))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $a) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.5555702 0.5555702 0.5555702 0.5555702))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.8314696 -0.8314696 0.8314696 -0.8314696))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $t2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $t10 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (6,22) and (7,23)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $d3) (local.get $d11))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $d3) (local.get $d11))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $a) (local.get $a)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.3826834 0.3826834 0.3826834 0.3826834))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.9238795 -0.9238795 0.9238795 -0.9238795))))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $a) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.1950903 0.1950903 0.1950903 0.1950903))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.9807853 -0.9807853 0.9807853 -0.9807853))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $t3 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $t11 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (8,24) and (9,25)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $d4) (local.get $d12))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $d4) (local.get $d12))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $a) (local.get $a)))
    (local.set $a (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.1950903 -0.1950903 -0.1950903 -0.1950903))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.9807853 -0.9807853 0.9807853 -0.9807853))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $t4 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $t12 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (10,26) and (11,27)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $d5) (local.get $d13))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $d5) (local.get $d13))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $a) (local.get $a)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.3826834 -0.3826834 -0.3826834 -0.3826834))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.9238795 -0.9238795 0.9238795 -0.9238795))))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $a) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.5555702 -0.5555702 -0.5555702 -0.5555702))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.8314696 -0.8314696 0.8314696 -0.8314696))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $t5 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $t13 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (12,28) and (13,29)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $d6) (local.get $d14))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $d6) (local.get $d14))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $a) (local.get $a)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.7071068 -0.7071068 -0.7071068 -0.7071068))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $a) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.8314696 -0.8314696 -0.8314696 -0.8314696))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.5555702 -0.5555702 0.5555702 -0.5555702))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $t6 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $t14 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (14,30) and (15,31)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $d7) (local.get $d15))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $d7) (local.get $d15))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $a) (local.get $a)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.9238795 -0.9238795 -0.9238795 -0.9238795))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.3826834 -0.3826834 0.3826834 -0.3826834))))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $a) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.9807853 -0.9807853 -0.9807853 -0.9807853))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.1950903 -0.1950903 0.1950903 -0.1950903))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $t7 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $t15 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (32,48) and (33,49)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $d16) (local.get $d24))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $d16) (local.get $d24))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.9807853 0.9807853 0.9807853 0.9807853))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.1950903 -0.1950903 0.1950903 -0.1950903))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $t16 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $t24 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (34,50) and (35,51)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $d17) (local.get $d25))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $d17) (local.get $d25))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $a) (local.get $a)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.9238795 0.9238795 0.9238795 0.9238795))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.3826834 -0.3826834 0.3826834 -0.3826834))))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $a) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.8314696 0.8314696 0.8314696 0.8314696))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.5555702 -0.5555702 0.5555702 -0.5555702))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $t17 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $t25 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (36,52) and (37,53)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $d18) (local.get $d26))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $d18) (local.get $d26))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $a) (local.get $a)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.7071068 0.7071068 0.7071068 0.7071068))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $a) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.5555702 0.5555702 0.5555702 0.5555702))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.8314696 -0.8314696 0.8314696 -0.8314696))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $t18 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $t26 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (38,54) and (39,55)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $d19) (local.get $d27))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $d19) (local.get $d27))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $a) (local.get $a)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.3826834 0.3826834 0.3826834 0.3826834))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.9238795 -0.9238795 0.9238795 -0.9238795))))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $a) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.1950903 0.1950903 0.1950903 0.1950903))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.9807853 -0.9807853 0.9807853 -0.9807853))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $t19 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $t27 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (40,56) and (41,57)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $d20) (local.get $d28))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $d20) (local.get $d28))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $a) (local.get $a)))
    (local.set $a (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.1950903 -0.1950903 -0.1950903 -0.1950903))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.9807853 -0.9807853 0.9807853 -0.9807853))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $t20 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $t28 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (42,58) and (43,59)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $d21) (local.get $d29))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $d21) (local.get $d29))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $a) (local.get $a)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.3826834 -0.3826834 -0.3826834 -0.3826834))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.9238795 -0.9238795 0.9238795 -0.9238795))))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $a) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.5555702 -0.5555702 -0.5555702 -0.5555702))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.8314696 -0.8314696 0.8314696 -0.8314696))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $t21 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $t29 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (44,60) and (45,61)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $d22) (local.get $d30))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $d22) (local.get $d30))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $a) (local.get $a)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.7071068 -0.7071068 -0.7071068 -0.7071068))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $a) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.8314696 -0.8314696 -0.8314696 -0.8314696))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.5555702 -0.5555702 0.5555702 -0.5555702))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $t22 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $t30 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (46,62) and (47,63)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $d23) (local.get $d31))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $d23) (local.get $d31))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $a) (local.get $a)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.9238795 -0.9238795 -0.9238795 -0.9238795))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.3826834 -0.3826834 0.3826834 -0.3826834))))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $a) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.9807853 -0.9807853 -0.9807853 -0.9807853))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.1950903 -0.1950903 0.1950903 -0.1950903))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $t23 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $t31 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))

    ;; ============ Stage 6 (span 32): W_64 twiddles ============
    ;; Butterflies (0,32) and (1,33)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $t0) (local.get $t16))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $t0) (local.get $t16))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.9951847 0.9951847 0.9951847 0.9951847))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.0980171 -0.0980171 0.0980171 -0.0980171))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $u0 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $u16 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (2,34) and (3,35)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $t1) (local.get $t17))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $t1) (local.get $t17))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $a) (local.get $a)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.9807853 0.9807853 0.9807853 0.9807853))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.1950903 -0.1950903 0.1950903 -0.1950903))))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $a) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.9569403 0.9569403 0.9569403 0.9569403))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.2902847 -0.2902847 0.2902847 -0.2902847))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $u1 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $u17 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (4,36) and (5,37)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $t2) (local.get $t18))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $t2) (local.get $t18))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $a) (local.get $a)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.9238795 0.9238795 0.9238795 0.9238795))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.3826834 -0.3826834 0.3826834 -0.3826834))))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $a) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.8819213 0.8819213 0.8819213 0.8819213))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.4713967 -0.4713967 0.4713967 -0.4713967))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $u2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $u18 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (6,38) and (7,39)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $t3) (local.get $t19))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $t3) (local.get $t19))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $a) (local.get $a)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.8314696 0.8314696 0.8314696 0.8314696))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.5555702 -0.5555702 0.5555702 -0.5555702))))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $a) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.7730105 0.7730105 0.7730105 0.7730105))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.6343933 -0.6343933 0.6343933 -0.6343933))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $u3 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $u19 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (8,40) and (9,41)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $t4) (local.get $t20))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $t4) (local.get $t20))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $a) (local.get $a)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.7071068 0.7071068 0.7071068 0.7071068))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $a) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.6343933 0.6343933 0.6343933 0.6343933))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7730105 -0.7730105 0.7730105 -0.7730105))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $u4 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $u20 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (10,42) and (11,43)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $t5) (local.get $t21))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $t5) (local.get $t21))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $a) (local.get $a)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.5555702 0.5555702 0.5555702 0.5555702))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.8314696 -0.8314696 0.8314696 -0.8314696))))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $a) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.4713967 0.4713967 0.4713967 0.4713967))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.8819213 -0.8819213 0.8819213 -0.8819213))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $u5 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $u21 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (12,44) and (13,45)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $t6) (local.get $t22))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $t6) (local.get $t22))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $a) (local.get $a)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.3826834 0.3826834 0.3826834 0.3826834))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.9238795 -0.9238795 0.9238795 -0.9238795))))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $a) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.2902847 0.2902847 0.2902847 0.2902847))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.9569403 -0.9569403 0.9569403 -0.9569403))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $u6 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $u22 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (14,46) and (15,47)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $t7) (local.get $t23))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $t7) (local.get $t23))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $a) (local.get $a)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.1950903 0.1950903 0.1950903 0.1950903))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.9807853 -0.9807853 0.9807853 -0.9807853))))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $a) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 0.0980171 0.0980171 0.0980171 0.0980171))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.9951847 -0.9951847 0.9951847 -0.9951847))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $u7 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $u23 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (16,48) and (17,49)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $t8) (local.get $t24))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $t8) (local.get $t24))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 0 1 2 3 4 5 6 7 12 13 14 15 8 9 10 11 (local.get $a) (local.get $a)))
    (local.set $a (f32x4.mul (local.get $tmp) (v128.const f32x4 1.0 1.0 1.0 -1.0)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.0980171 -0.0980171 -0.0980171 -0.0980171))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.9951847 -0.9951847 0.9951847 -0.9951847))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $u8 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $u24 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (18,50) and (19,51)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $t9) (local.get $t25))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $t9) (local.get $t25))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $a) (local.get $a)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.1950903 -0.1950903 -0.1950903 -0.1950903))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.9807853 -0.9807853 0.9807853 -0.9807853))))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $a) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.2902847 -0.2902847 -0.2902847 -0.2902847))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.9569403 -0.9569403 0.9569403 -0.9569403))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $u9 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $u25 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (20,52) and (21,53)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $t10) (local.get $t26))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $t10) (local.get $t26))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $a) (local.get $a)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.3826834 -0.3826834 -0.3826834 -0.3826834))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.9238795 -0.9238795 0.9238795 -0.9238795))))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $a) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.4713967 -0.4713967 -0.4713967 -0.4713967))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.8819213 -0.8819213 0.8819213 -0.8819213))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $u10 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $u26 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (22,54) and (23,55)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $t11) (local.get $t27))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $t11) (local.get $t27))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $a) (local.get $a)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.5555702 -0.5555702 -0.5555702 -0.5555702))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.8314696 -0.8314696 0.8314696 -0.8314696))))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $a) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.6343933 -0.6343933 -0.6343933 -0.6343933))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7730105 -0.7730105 0.7730105 -0.7730105))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $u11 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $u27 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (24,56) and (25,57)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $t12) (local.get $t28))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $t12) (local.get $t28))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $a) (local.get $a)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.7071068 -0.7071068 -0.7071068 -0.7071068))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $a) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.7730105 -0.7730105 -0.7730105 -0.7730105))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.6343933 -0.6343933 0.6343933 -0.6343933))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $u12 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $u28 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (26,58) and (27,59)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $t13) (local.get $t29))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $t13) (local.get $t29))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $a) (local.get $a)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.8314696 -0.8314696 -0.8314696 -0.8314696))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.5555702 -0.5555702 0.5555702 -0.5555702))))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $a) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.8819213 -0.8819213 -0.8819213 -0.8819213))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.4713967 -0.4713967 0.4713967 -0.4713967))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $u13 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $u29 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (28,60) and (29,61)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $t14) (local.get $t30))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $t14) (local.get $t30))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $a) (local.get $a)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.9238795 -0.9238795 -0.9238795 -0.9238795))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.3826834 -0.3826834 0.3826834 -0.3826834))))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $a) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.9569403 -0.9569403 -0.9569403 -0.9569403))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.2902847 -0.2902847 0.2902847 -0.2902847))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $u14 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $u30 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))
    ;; Butterflies (30,62) and (31,63)
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $t15) (local.get $t31))) ;; [a0, b0]
    (local.set $b (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $t15) (local.get $t31))) ;; [a1, b1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $a) (local.get $a)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.9807853 -0.9807853 -0.9807853 -0.9807853))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.1950903 -0.1950903 0.1950903 -0.1950903))))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $a) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $b) (local.get $b)))
    (local.set $tmp (f32x4.add
      (f32x4.mul (local.get $tmp) (v128.const f32x4 -0.9951847 -0.9951847 -0.9951847 -0.9951847))
      (f32x4.mul (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $tmp) (local.get $tmp)) (v128.const f32x4 0.0980171 -0.0980171 0.0980171 -0.0980171))))
    (local.set $b (i8x16.shuffle 0 1 2 3 4 5 6 7 24 25 26 27 28 29 30 31 (local.get $b) (local.get $tmp)))
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)))
    (local.set $tmp2 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $a) (local.get $tmp))
      (f32x4.sub (local.get $a) (local.get $tmp)))) ;; [a0+b0*w1, a0-b0*w1]
    (local.set $tmp (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)))
    (local.set $a (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
      (f32x4.add (local.get $b) (local.get $tmp))
      (f32x4.sub (local.get $b) (local.get $tmp)))) ;; [a1+b1*w2, a1-b1*w2]
    (local.set $u15 (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $tmp2) (local.get $a)))
    (local.set $u31 (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $tmp2) (local.get $a)))

    ;; ============ Store in natural order ============
    (v128.store (i32.const 0) (local.get $u0))
    (v128.store (i32.const 16) (local.get $u1))
    (v128.store (i32.const 32) (local.get $u2))
    (v128.store (i32.const 48) (local.get $u3))
    (v128.store (i32.const 64) (local.get $u4))
    (v128.store (i32.const 80) (local.get $u5))
    (v128.store (i32.const 96) (local.get $u6))
    (v128.store (i32.const 112) (local.get $u7))
    (v128.store (i32.const 128) (local.get $u8))
    (v128.store (i32.const 144) (local.get $u9))
    (v128.store (i32.const 160) (local.get $u10))
    (v128.store (i32.const 176) (local.get $u11))
    (v128.store (i32.const 192) (local.get $u12))
    (v128.store (i32.const 208) (local.get $u13))
    (v128.store (i32.const 224) (local.get $u14))
    (v128.store (i32.const 240) (local.get $u15))
    (v128.store (i32.const 256) (local.get $u16))
    (v128.store (i32.const 272) (local.get $u17))
    (v128.store (i32.const 288) (local.get $u18))
    (v128.store (i32.const 304) (local.get $u19))
    (v128.store (i32.const 320) (local.get $u20))
    (v128.store (i32.const 336) (local.get $u21))
    (v128.store (i32.const 352) (local.get $u22))
    (v128.store (i32.const 368) (local.get $u23))
    (v128.store (i32.const 384) (local.get $u24))
    (v128.store (i32.const 400) (local.get $u25))
    (v128.store (i32.const 416) (local.get $u26))
    (v128.store (i32.const 432) (local.get $u27))
    (v128.store (i32.const 448) (local.get $u28))
    (v128.store (i32.const 464) (local.get $u29))
    (v128.store (i32.const 480) (local.get $u30))
    (v128.store (i32.const 496) (local.get $u31))
  )


  ;; ============================================================================
  ;; N=16 DIF Dual-Complex Kernel (bit-reversed output - NOT USED)
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

        ;; For r<2, use single-element processing (dual requires at least 2 elements per half)
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
  ;; Fully Unrolled RFFT-64 Post-Processing (n2=32)
  ;; ============================================================================
  ;; Experiment 23: Inline twiddles, no loops, no memory twiddle loads.
  ;; Processes pairs (k, 32-k) for k=1..15 in 7 SIMD iterations + remainder.

  (func $rfft_postprocess_64
    (local $zk v128) (local $zn2k v128) (local $conj_zn2k v128) (local $conj_zk v128)
    (local $sum v128) (local $diff v128) (local $sum2 v128) (local $diff2 v128)
    (local $wk_rot v128) (local $wn2k_rot v128)
    (local $wr v128) (local $wi v128) (local $prod v128) (local $swapped v128)
    (local $wd v128) (local $wd2 v128) (local $xk v128) (local $xn2k v128)
    (local $half v128)
    (local $z0_re f32) (local $z0_im f32)

    (local.set $half (v128.const f32x4 0.5 0.5 0.5 0.5))

    ;; DC and Nyquist: X[0] = Z[0].re + Z[0].im, X[32] = Z[0].re - Z[0].im
    (local.set $z0_re (f32.load (i32.const 0)))
    (local.set $z0_im (f32.load (i32.const 4)))
    (f32.store (i32.const 0) (f32.add (local.get $z0_re) (local.get $z0_im)))
    (f32.store (i32.const 4) (f32.const 0.0))
    (f32.store (i32.const 256) (f32.sub (local.get $z0_re) (local.get $z0_im)))  ;; 32*8 = 256
    (f32.store (i32.const 260) (f32.const 0.0))

    ;; ======== Pairs k=1,2 and k=31,30 ========
    ;; Load Z[1,2] from addr 8
    (local.set $zk (v128.load (i32.const 8)))
    ;; Load Z[30,31] from addr 240, shuffle to [Z[31], Z[30]]
    (local.set $zn2k (v128.load (i32.const 240)))
    (local.set $zn2k (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $zn2k) (local.get $zn2k)))

    (local.set $conj_zn2k (v128.xor (local.get $zn2k) (global.get $CONJ_MASK_F32)))
    (local.set $sum (f32x4.add (local.get $zk) (local.get $conj_zn2k)))
    (local.set $diff (f32x4.sub (local.get $zk) (local.get $conj_zn2k)))

    ;; W_rot for k=1,2: [W^1_rot, W^2_rot] = [(w1_im, -w1_re), (w2_im, -w2_re)]
    (local.set $wk_rot (v128.const f32x4 -0.0980171412229538 -0.9951847195625305 -0.19509032368659973 -0.9807852506637573))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $wk_rot) (local.get $wk_rot)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $wk_rot) (local.get $wk_rot)))
    (local.set $prod (f32x4.mul (local.get $diff) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff) (local.get $diff)))
    (local.set $wd (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))
    (local.set $xk (f32x4.mul (f32x4.add (local.get $sum) (local.get $wd)) (local.get $half)))

    ;; X[31,30] computation
    (local.set $conj_zk (v128.xor (local.get $zk) (global.get $CONJ_MASK_F32)))
    (local.set $sum2 (f32x4.add (local.get $zn2k) (local.get $conj_zk)))
    (local.set $diff2 (f32x4.sub (local.get $zn2k) (local.get $conj_zk)))
    ;; W_rot for k=31,30: derive from wk_rot by flipping sign of real parts
    (local.set $wn2k_rot (v128.xor (local.get $wk_rot) (global.get $CONJ_MASK_F32)))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $wn2k_rot) (local.get $wn2k_rot)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $wn2k_rot) (local.get $wn2k_rot)))
    (local.set $prod (f32x4.mul (local.get $diff2) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff2) (local.get $diff2)))
    (local.set $wd2 (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))
    (local.set $xn2k (f32x4.mul (f32x4.add (local.get $sum2) (local.get $wd2)) (local.get $half)))

    ;; Store X[1,2] and X[31,30] (shuffled back)
    (v128.store (i32.const 8) (local.get $xk))
    (local.set $xn2k (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $xn2k) (local.get $xn2k)))
    (v128.store (i32.const 240) (local.get $xn2k))

    ;; ======== Pairs k=3,4 and k=29,28 ========
    (local.set $zk (v128.load (i32.const 24)))
    (local.set $zn2k (v128.load (i32.const 224)))
    (local.set $zn2k (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $zn2k) (local.get $zn2k)))
    (local.set $conj_zn2k (v128.xor (local.get $zn2k) (global.get $CONJ_MASK_F32)))
    (local.set $sum (f32x4.add (local.get $zk) (local.get $conj_zn2k)))
    (local.set $diff (f32x4.sub (local.get $zk) (local.get $conj_zn2k)))
    (local.set $wk_rot (v128.const f32x4 -0.290284663438797 -0.9569403529167175 -0.3826834261417389 -0.9238795042037964))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $wk_rot) (local.get $wk_rot)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $wk_rot) (local.get $wk_rot)))
    (local.set $prod (f32x4.mul (local.get $diff) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff) (local.get $diff)))
    (local.set $wd (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))
    (local.set $xk (f32x4.mul (f32x4.add (local.get $sum) (local.get $wd)) (local.get $half)))
    (local.set $conj_zk (v128.xor (local.get $zk) (global.get $CONJ_MASK_F32)))
    (local.set $sum2 (f32x4.add (local.get $zn2k) (local.get $conj_zk)))
    (local.set $diff2 (f32x4.sub (local.get $zn2k) (local.get $conj_zk)))
    (local.set $wn2k_rot (v128.xor (local.get $wk_rot) (global.get $CONJ_MASK_F32)))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $wn2k_rot) (local.get $wn2k_rot)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $wn2k_rot) (local.get $wn2k_rot)))
    (local.set $prod (f32x4.mul (local.get $diff2) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff2) (local.get $diff2)))
    (local.set $wd2 (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))
    (local.set $xn2k (f32x4.mul (f32x4.add (local.get $sum2) (local.get $wd2)) (local.get $half)))
    (v128.store (i32.const 24) (local.get $xk))
    (local.set $xn2k (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $xn2k) (local.get $xn2k)))
    (v128.store (i32.const 224) (local.get $xn2k))

    ;; ======== Pairs k=5,6 and k=27,26 ========
    (local.set $zk (v128.load (i32.const 40)))
    (local.set $zn2k (v128.load (i32.const 208)))
    (local.set $zn2k (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $zn2k) (local.get $zn2k)))
    (local.set $conj_zn2k (v128.xor (local.get $zn2k) (global.get $CONJ_MASK_F32)))
    (local.set $sum (f32x4.add (local.get $zk) (local.get $conj_zn2k)))
    (local.set $diff (f32x4.sub (local.get $zk) (local.get $conj_zn2k)))
    (local.set $wk_rot (v128.const f32x4 -0.4713967442512512 -0.8819212913513184 -0.5555702447891235 -0.8314695954322815))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $wk_rot) (local.get $wk_rot)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $wk_rot) (local.get $wk_rot)))
    (local.set $prod (f32x4.mul (local.get $diff) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff) (local.get $diff)))
    (local.set $wd (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))
    (local.set $xk (f32x4.mul (f32x4.add (local.get $sum) (local.get $wd)) (local.get $half)))
    (local.set $conj_zk (v128.xor (local.get $zk) (global.get $CONJ_MASK_F32)))
    (local.set $sum2 (f32x4.add (local.get $zn2k) (local.get $conj_zk)))
    (local.set $diff2 (f32x4.sub (local.get $zn2k) (local.get $conj_zk)))
    (local.set $wn2k_rot (v128.xor (local.get $wk_rot) (global.get $CONJ_MASK_F32)))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $wn2k_rot) (local.get $wn2k_rot)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $wn2k_rot) (local.get $wn2k_rot)))
    (local.set $prod (f32x4.mul (local.get $diff2) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff2) (local.get $diff2)))
    (local.set $wd2 (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))
    (local.set $xn2k (f32x4.mul (f32x4.add (local.get $sum2) (local.get $wd2)) (local.get $half)))
    (v128.store (i32.const 40) (local.get $xk))
    (local.set $xn2k (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $xn2k) (local.get $xn2k)))
    (v128.store (i32.const 208) (local.get $xn2k))

    ;; ======== Pairs k=7,8 and k=25,24 ========
    (local.set $zk (v128.load (i32.const 56)))
    (local.set $zn2k (v128.load (i32.const 192)))
    (local.set $zn2k (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $zn2k) (local.get $zn2k)))
    (local.set $conj_zn2k (v128.xor (local.get $zn2k) (global.get $CONJ_MASK_F32)))
    (local.set $sum (f32x4.add (local.get $zk) (local.get $conj_zn2k)))
    (local.set $diff (f32x4.sub (local.get $zk) (local.get $conj_zn2k)))
    (local.set $wk_rot (v128.const f32x4 -0.6343932747840881 -0.7730104327201843 -0.7071067690849304 -0.7071067690849304))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $wk_rot) (local.get $wk_rot)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $wk_rot) (local.get $wk_rot)))
    (local.set $prod (f32x4.mul (local.get $diff) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff) (local.get $diff)))
    (local.set $wd (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))
    (local.set $xk (f32x4.mul (f32x4.add (local.get $sum) (local.get $wd)) (local.get $half)))
    (local.set $conj_zk (v128.xor (local.get $zk) (global.get $CONJ_MASK_F32)))
    (local.set $sum2 (f32x4.add (local.get $zn2k) (local.get $conj_zk)))
    (local.set $diff2 (f32x4.sub (local.get $zn2k) (local.get $conj_zk)))
    (local.set $wn2k_rot (v128.xor (local.get $wk_rot) (global.get $CONJ_MASK_F32)))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $wn2k_rot) (local.get $wn2k_rot)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $wn2k_rot) (local.get $wn2k_rot)))
    (local.set $prod (f32x4.mul (local.get $diff2) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff2) (local.get $diff2)))
    (local.set $wd2 (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))
    (local.set $xn2k (f32x4.mul (f32x4.add (local.get $sum2) (local.get $wd2)) (local.get $half)))
    (v128.store (i32.const 56) (local.get $xk))
    (local.set $xn2k (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $xn2k) (local.get $xn2k)))
    (v128.store (i32.const 192) (local.get $xn2k))

    ;; ======== Pairs k=9,10 and k=23,22 ========
    (local.set $zk (v128.load (i32.const 72)))
    (local.set $zn2k (v128.load (i32.const 176)))
    (local.set $zn2k (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $zn2k) (local.get $zn2k)))
    (local.set $conj_zn2k (v128.xor (local.get $zn2k) (global.get $CONJ_MASK_F32)))
    (local.set $sum (f32x4.add (local.get $zk) (local.get $conj_zn2k)))
    (local.set $diff (f32x4.sub (local.get $zk) (local.get $conj_zn2k)))
    (local.set $wk_rot (v128.const f32x4 -0.7730104327201843 -0.6343932747840881 -0.8314695954322815 -0.5555702447891235))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $wk_rot) (local.get $wk_rot)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $wk_rot) (local.get $wk_rot)))
    (local.set $prod (f32x4.mul (local.get $diff) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff) (local.get $diff)))
    (local.set $wd (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))
    (local.set $xk (f32x4.mul (f32x4.add (local.get $sum) (local.get $wd)) (local.get $half)))
    (local.set $conj_zk (v128.xor (local.get $zk) (global.get $CONJ_MASK_F32)))
    (local.set $sum2 (f32x4.add (local.get $zn2k) (local.get $conj_zk)))
    (local.set $diff2 (f32x4.sub (local.get $zn2k) (local.get $conj_zk)))
    (local.set $wn2k_rot (v128.xor (local.get $wk_rot) (global.get $CONJ_MASK_F32)))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $wn2k_rot) (local.get $wn2k_rot)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $wn2k_rot) (local.get $wn2k_rot)))
    (local.set $prod (f32x4.mul (local.get $diff2) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff2) (local.get $diff2)))
    (local.set $wd2 (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))
    (local.set $xn2k (f32x4.mul (f32x4.add (local.get $sum2) (local.get $wd2)) (local.get $half)))
    (v128.store (i32.const 72) (local.get $xk))
    (local.set $xn2k (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $xn2k) (local.get $xn2k)))
    (v128.store (i32.const 176) (local.get $xn2k))

    ;; ======== Pairs k=11,12 and k=21,20 ========
    (local.set $zk (v128.load (i32.const 88)))
    (local.set $zn2k (v128.load (i32.const 160)))
    (local.set $zn2k (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $zn2k) (local.get $zn2k)))
    (local.set $conj_zn2k (v128.xor (local.get $zn2k) (global.get $CONJ_MASK_F32)))
    (local.set $sum (f32x4.add (local.get $zk) (local.get $conj_zn2k)))
    (local.set $diff (f32x4.sub (local.get $zk) (local.get $conj_zn2k)))
    (local.set $wk_rot (v128.const f32x4 -0.8819212913513184 -0.4713967442512512 -0.9238795042037964 -0.3826834261417389))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $wk_rot) (local.get $wk_rot)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $wk_rot) (local.get $wk_rot)))
    (local.set $prod (f32x4.mul (local.get $diff) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff) (local.get $diff)))
    (local.set $wd (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))
    (local.set $xk (f32x4.mul (f32x4.add (local.get $sum) (local.get $wd)) (local.get $half)))
    (local.set $conj_zk (v128.xor (local.get $zk) (global.get $CONJ_MASK_F32)))
    (local.set $sum2 (f32x4.add (local.get $zn2k) (local.get $conj_zk)))
    (local.set $diff2 (f32x4.sub (local.get $zn2k) (local.get $conj_zk)))
    (local.set $wn2k_rot (v128.xor (local.get $wk_rot) (global.get $CONJ_MASK_F32)))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $wn2k_rot) (local.get $wn2k_rot)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $wn2k_rot) (local.get $wn2k_rot)))
    (local.set $prod (f32x4.mul (local.get $diff2) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff2) (local.get $diff2)))
    (local.set $wd2 (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))
    (local.set $xn2k (f32x4.mul (f32x4.add (local.get $sum2) (local.get $wd2)) (local.get $half)))
    (v128.store (i32.const 88) (local.get $xk))
    (local.set $xn2k (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $xn2k) (local.get $xn2k)))
    (v128.store (i32.const 160) (local.get $xn2k))

    ;; ======== Pairs k=13,14 and k=19,18 ========
    (local.set $zk (v128.load (i32.const 104)))
    (local.set $zn2k (v128.load (i32.const 144)))
    (local.set $zn2k (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $zn2k) (local.get $zn2k)))
    (local.set $conj_zn2k (v128.xor (local.get $zn2k) (global.get $CONJ_MASK_F32)))
    (local.set $sum (f32x4.add (local.get $zk) (local.get $conj_zn2k)))
    (local.set $diff (f32x4.sub (local.get $zk) (local.get $conj_zn2k)))
    (local.set $wk_rot (v128.const f32x4 -0.9569403529167175 -0.290284663438797 -0.9807852506637573 -0.19509032368659973))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $wk_rot) (local.get $wk_rot)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $wk_rot) (local.get $wk_rot)))
    (local.set $prod (f32x4.mul (local.get $diff) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff) (local.get $diff)))
    (local.set $wd (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))
    (local.set $xk (f32x4.mul (f32x4.add (local.get $sum) (local.get $wd)) (local.get $half)))
    (local.set $conj_zk (v128.xor (local.get $zk) (global.get $CONJ_MASK_F32)))
    (local.set $sum2 (f32x4.add (local.get $zn2k) (local.get $conj_zk)))
    (local.set $diff2 (f32x4.sub (local.get $zn2k) (local.get $conj_zk)))
    (local.set $wn2k_rot (v128.xor (local.get $wk_rot) (global.get $CONJ_MASK_F32)))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $wn2k_rot) (local.get $wn2k_rot)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $wn2k_rot) (local.get $wn2k_rot)))
    (local.set $prod (f32x4.mul (local.get $diff2) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff2) (local.get $diff2)))
    (local.set $wd2 (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))
    (local.set $xn2k (f32x4.mul (f32x4.add (local.get $sum2) (local.get $wd2)) (local.get $half)))
    (v128.store (i32.const 104) (local.get $xk))
    (local.set $xn2k (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $xn2k) (local.get $xn2k)))
    (v128.store (i32.const 144) (local.get $xn2k))

    ;; ======== Single pair k=15 and k=17 ========
    ;; Load Z[15] from addr 120
    (local.set $zk (v128.load64_zero (i32.const 120)))
    ;; Load Z[17] from addr 136
    (local.set $zn2k (v128.load64_zero (i32.const 136)))
    (local.set $conj_zn2k (v128.xor (local.get $zn2k) (global.get $CONJ_MASK_F32)))
    (local.set $sum (f32x4.add (local.get $zk) (local.get $conj_zn2k)))
    (local.set $diff (f32x4.sub (local.get $zk) (local.get $conj_zn2k)))
    ;; W_rot for k=15
    (local.set $wk_rot (v128.const f32x4 -0.9951847195625305 -0.0980171412229538 0 0))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 0 1 2 3 0 1 2 3 (local.get $wk_rot) (local.get $wk_rot)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 4 5 6 7 4 5 6 7 (local.get $wk_rot) (local.get $wk_rot)))
    (local.set $prod (f32x4.mul (local.get $diff) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $diff) (local.get $diff)))
    (local.set $wd (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))
    (local.set $xk (f32x4.mul (f32x4.add (local.get $sum) (local.get $wd)) (local.get $half)))
    ;; X[17]
    (local.set $conj_zk (v128.xor (local.get $zk) (global.get $CONJ_MASK_F32)))
    (local.set $sum2 (f32x4.add (local.get $zn2k) (local.get $conj_zk)))
    (local.set $diff2 (f32x4.sub (local.get $zn2k) (local.get $conj_zk)))
    (local.set $wn2k_rot (v128.xor (local.get $wk_rot) (global.get $CONJ_MASK_F32)))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 0 1 2 3 0 1 2 3 (local.get $wn2k_rot) (local.get $wn2k_rot)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 4 5 6 7 4 5 6 7 (local.get $wn2k_rot) (local.get $wn2k_rot)))
    (local.set $prod (f32x4.mul (local.get $diff2) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $diff2) (local.get $diff2)))
    (local.set $wd2 (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))
    (local.set $xn2k (f32x4.mul (f32x4.add (local.get $sum2) (local.get $wd2)) (local.get $half)))
    (v128.store64_lane 0 (i32.const 120) (local.get $xk))
    (v128.store64_lane 0 (i32.const 136) (local.get $xn2k))

    ;; ======== Middle element k=16 (n2/2) ========
    ;; For the middle element: sum = 2*z.re, diff_im = 2*z.im
    ;; Z[16] at addr 128
    (local.set $zk (v128.load64_zero (i32.const 128)))
    (local.set $z0_re (f32x4.extract_lane 0 (local.get $zk)))
    (local.set $z0_im (f32x4.extract_lane 1 (local.get $zk)))
    (local.set $sum (f32x4.replace_lane 0 (v128.const f32x4 0 0 0 0) (f32.mul (f32.const 2.0) (local.get $z0_re))))
    (local.set $diff (f32x4.replace_lane 1 (v128.const f32x4 0 0 0 0) (f32.mul (f32.const 2.0) (local.get $z0_im))))
    ;; W_rot for k=16: W^16 = (0, -1), W_rot = (-1, 0)
    (local.set $wk_rot (v128.const f32x4 -1.0 0.0 0 0))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 0 1 2 3 0 1 2 3 (local.get $wk_rot) (local.get $wk_rot)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 4 5 6 7 4 5 6 7 (local.get $wk_rot) (local.get $wk_rot)))
    (local.set $prod (f32x4.mul (local.get $diff) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $diff) (local.get $diff)))
    (local.set $wd (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))
    (local.set $xk (f32x4.mul (f32x4.add (local.get $sum) (local.get $wd)) (local.get $half)))
    (v128.store64_lane 0 (i32.const 128) (local.get $xk))
  )

  ;; ============================================================================
  ;; SIMD Post-Processing for Real FFT (f32x4)
  ;; ============================================================================
  ;; Processes 2 pairs per iteration using full f32x4 SIMD throughput.
  ;; Pairs (k, n2-k) and (k+1, n2-k-1) are processed together.

  (func $rfft_postprocess_simd (param $n2 i32)
    (local $k i32) (local $k_end i32) (local $n2_minus_k i32)
    (local $addr_k i32) (local $addr_n2k i32) (local $tw_addr i32)
    ;; SIMD registers
    (local $zk v128) (local $zn2k v128) (local $conj_zn2k v128)
    (local $wk v128) (local $wk_rot v128)
    (local $wn2k v128) (local $wn2k_rot v128)
    (local $sum v128) (local $diff v128) (local $wd v128)
    (local $sum2 v128) (local $diff2 v128) (local $wd2 v128)
    (local $xk v128) (local $xn2k v128)
    (local $conj_zk v128)
    (local $half v128)
    ;; Scalar for DC/Nyquist
    (local $z0_re f32) (local $z0_im f32)
    ;; For complex multiply
    (local $wr v128) (local $wi v128) (local $prod v128) (local $swapped v128)

    (local.set $half (v128.const f32x4 0.5 0.5 0.5 0.5))

    ;; DC and Nyquist handling
    (local.set $z0_re (f32.load (i32.const 0)))
    (local.set $z0_im (f32.load (i32.const 4)))
    (f32.store (i32.const 0) (f32.add (local.get $z0_re) (local.get $z0_im)))
    (f32.store (i32.const 4) (f32.const 0.0))
    (local.set $addr_k (i32.shl (local.get $n2) (i32.const 3)))
    (f32.store (local.get $addr_k) (f32.sub (local.get $z0_re) (local.get $z0_im)))
    (f32.store (i32.add (local.get $addr_k) (i32.const 4)) (f32.const 0.0))

    ;; Main SIMD loop: process 2 pairs per iteration
    ;; Pairs (k, n2-k) and (k+1, n2-k-1)
    (local.set $k_end (i32.shr_u (local.get $n2) (i32.const 1)))
    (local.set $k (i32.const 1))

    (block $done_main (loop $main_loop
      ;; Need at least 2 pairs, so k+1 < k_end
      (br_if $done_main (i32.ge_u (i32.add (local.get $k) (i32.const 1)) (local.get $k_end)))

      (local.set $n2_minus_k (i32.sub (local.get $n2) (local.get $k)))
      (local.set $addr_k (i32.shl (local.get $k) (i32.const 3)))
      ;; addr_n2k points to Z[n2-k-1], loading 16 bytes gives [Z[n2-k-1], Z[n2-k]]
      (local.set $addr_n2k (i32.shl (i32.sub (local.get $n2_minus_k) (i32.const 1)) (i32.const 3)))

      ;; Load [Z[k], Z[k+1]] - contiguous
      (local.set $zk (v128.load (local.get $addr_k)))

      ;; Load [Z[n2-k-1], Z[n2-k]] and shuffle to [Z[n2-k], Z[n2-k-1]]
      (local.set $zn2k (v128.load (local.get $addr_n2k)))
      (local.set $zn2k (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7
                                      (local.get $zn2k) (local.get $zn2k)))

      ;; Compute conj(Z[n2-k], Z[n2-k-1]) = flip sign of imaginary parts
      (local.set $conj_zn2k (v128.xor (local.get $zn2k) (global.get $CONJ_MASK_F32)))

      ;; sum = Z[k,k+1] + conj(Z[n2-k, n2-k-1])
      ;; diff = Z[k,k+1] - conj(Z[n2-k, n2-k-1])
      (local.set $sum (f32x4.add (local.get $zk) (local.get $conj_zn2k)))
      (local.set $diff (f32x4.sub (local.get $zk) (local.get $conj_zn2k)))

      ;; Load [W[k], W[k+1]] - contiguous (8 bytes each)
      (local.set $tw_addr (i32.add (global.get $RFFT_TWIDDLE_OFFSET) (local.get $addr_k)))
      (local.set $wk (v128.load (local.get $tw_addr)))

      ;; W_rot = (w_im, -w_re) for each: shuffle to swap re/im, then negate re
      ;; [w0.re, w0.im, w1.re, w1.im] -> [w0.im, w0.re, w1.im, w1.re] -> [w0.im, -w0.re, w1.im, -w1.re]
      (local.set $wk_rot
        (f32x4.mul
          (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $wk) (local.get $wk))
          (v128.const f32x4 1.0 -1.0 1.0 -1.0)))

      ;; wd = W_rot * diff (dual-complex multiply)
      ;; For [a0+b0i, a1+b1i] * [c0+d0i, c1+d1i]:
      ;; = [(a0*c0-b0*d0) + (a0*d0+b0*c0)i, (a1*c1-b1*d1) + (a1*d1+b1*c1)i]
      (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11
                                    (local.get $wk_rot) (local.get $wk_rot)))
      (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15
                                    (local.get $wk_rot) (local.get $wk_rot)))
      (local.set $prod (f32x4.mul (local.get $diff) (local.get $wr)))
      (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11
                                         (local.get $diff) (local.get $diff)))
      (local.set $wd (f32x4.add (local.get $prod)
        (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))

      ;; X[k,k+1] = 0.5 * (sum + wd)
      (local.set $xk (f32x4.mul (f32x4.add (local.get $sum) (local.get $wd)) (local.get $half)))

      ;; Now compute X[n2-k, n2-k-1] using swapped inputs
      (local.set $conj_zk (v128.xor (local.get $zk) (global.get $CONJ_MASK_F32)))
      (local.set $sum2 (f32x4.add (local.get $zn2k) (local.get $conj_zk)))
      (local.set $diff2 (f32x4.sub (local.get $zn2k) (local.get $conj_zk)))

      ;; Load [W[n2-k-1], W[n2-k]] and shuffle to [W[n2-k], W[n2-k-1]]
      (local.set $tw_addr (i32.add (global.get $RFFT_TWIDDLE_OFFSET) (local.get $addr_n2k)))
      (local.set $wn2k (v128.load (local.get $tw_addr)))
      (local.set $wn2k (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7
                                      (local.get $wn2k) (local.get $wn2k)))

      ;; W_rot2 = (w_im, -w_re) for each
      (local.set $wn2k_rot
        (f32x4.mul
          (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $wn2k) (local.get $wn2k))
          (v128.const f32x4 1.0 -1.0 1.0 -1.0)))

      ;; wd2 = W_rot2 * diff2
      (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11
                                    (local.get $wn2k_rot) (local.get $wn2k_rot)))
      (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15
                                    (local.get $wn2k_rot) (local.get $wn2k_rot)))
      (local.set $prod (f32x4.mul (local.get $diff2) (local.get $wr)))
      (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11
                                         (local.get $diff2) (local.get $diff2)))
      (local.set $wd2 (f32x4.add (local.get $prod)
        (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))

      ;; X[n2-k, n2-k-1] = 0.5 * (sum2 + wd2)
      (local.set $xn2k (f32x4.mul (f32x4.add (local.get $sum2) (local.get $wd2)) (local.get $half)))

      ;; Store X[k, k+1]
      (v128.store (local.get $addr_k) (local.get $xk))

      ;; Store X[n2-k, n2-k-1] - need to shuffle back to [X[n2-k-1], X[n2-k]] order
      (local.set $xn2k (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7
                                      (local.get $xn2k) (local.get $xn2k)))
      (v128.store (local.get $addr_n2k) (local.get $xn2k))

      (local.set $k (i32.add (local.get $k) (i32.const 2)))
      (br $main_loop)
    ))

    ;; Handle remaining pair if k < k_end (odd number of pairs)
    (if (i32.lt_u (local.get $k) (local.get $k_end))
      (then
        (local.set $n2_minus_k (i32.sub (local.get $n2) (local.get $k)))
        (local.set $addr_k (i32.shl (local.get $k) (i32.const 3)))
        (local.set $addr_n2k (i32.shl (local.get $n2_minus_k) (i32.const 3)))

        ;; Load single pair using 64-bit loads
        (local.set $zk (v128.load64_zero (local.get $addr_k)))
        (local.set $zn2k (v128.load64_zero (local.get $addr_n2k)))
        (local.set $conj_zn2k (v128.xor (local.get $zn2k) (global.get $CONJ_MASK_F32)))

        (local.set $sum (f32x4.add (local.get $zk) (local.get $conj_zn2k)))
        (local.set $diff (f32x4.sub (local.get $zk) (local.get $conj_zn2k)))

        (local.set $tw_addr (i32.add (global.get $RFFT_TWIDDLE_OFFSET) (local.get $addr_k)))
        (local.set $wk (v128.load64_zero (local.get $tw_addr)))
        (local.set $wk_rot
          (f32x4.mul
            (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $wk) (local.get $wk))
            (v128.const f32x4 1.0 -1.0 1.0 -1.0)))

        (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 0 1 2 3 0 1 2 3
                                      (local.get $wk_rot) (local.get $wk_rot)))
        (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 4 5 6 7 4 5 6 7
                                      (local.get $wk_rot) (local.get $wk_rot)))
        (local.set $prod (f32x4.mul (local.get $diff) (local.get $wr)))
        (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3
                                           (local.get $diff) (local.get $diff)))
        (local.set $wd (f32x4.add (local.get $prod)
          (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))

        (local.set $xk (f32x4.mul (f32x4.add (local.get $sum) (local.get $wd)) (local.get $half)))

        ;; X[n2-k]
        (local.set $conj_zk (v128.xor (local.get $zk) (global.get $CONJ_MASK_F32)))
        (local.set $sum2 (f32x4.add (local.get $zn2k) (local.get $conj_zk)))
        (local.set $diff2 (f32x4.sub (local.get $zn2k) (local.get $conj_zk)))

        (local.set $tw_addr (i32.add (global.get $RFFT_TWIDDLE_OFFSET) (local.get $addr_n2k)))
        (local.set $wn2k (v128.load64_zero (local.get $tw_addr)))
        (local.set $wn2k_rot
          (f32x4.mul
            (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $wn2k) (local.get $wn2k))
            (v128.const f32x4 1.0 -1.0 1.0 -1.0)))

        (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 0 1 2 3 0 1 2 3
                                      (local.get $wn2k_rot) (local.get $wn2k_rot)))
        (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 4 5 6 7 4 5 6 7
                                      (local.get $wn2k_rot) (local.get $wn2k_rot)))
        (local.set $prod (f32x4.mul (local.get $diff2) (local.get $wr)))
        (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3
                                           (local.get $diff2) (local.get $diff2)))
        (local.set $wd2 (f32x4.add (local.get $prod)
          (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))

        (local.set $xn2k (f32x4.mul (f32x4.add (local.get $sum2) (local.get $wd2)) (local.get $half)))

        (v128.store64_lane 0 (local.get $addr_k) (local.get $xk))
        (v128.store64_lane 0 (local.get $addr_n2k) (local.get $xn2k))
      )
    )

    ;; Handle middle element when n2 is even and > 2
    (if (i32.and (i32.eqz (i32.and (local.get $n2) (i32.const 1))) (i32.gt_u (local.get $n2) (i32.const 2)))
      (then
        (local.set $addr_k (i32.shl (local.get $k_end) (i32.const 3)))
        (local.set $zk (v128.load64_zero (local.get $addr_k)))

        (local.set $tw_addr (i32.add (global.get $RFFT_TWIDDLE_OFFSET) (local.get $addr_k)))
        (local.set $wk (v128.load64_zero (local.get $tw_addr)))

        ;; For middle element: sum = 2*zk_re, diff_im = 2*zk_im
        ;; Extract re and im
        (local.set $z0_re (f32x4.extract_lane 0 (local.get $zk)))
        (local.set $z0_im (f32x4.extract_lane 1 (local.get $zk)))

        (local.set $sum (f32x4.replace_lane 0 (v128.const f32x4 0 0 0 0)
                          (f32.mul (f32.const 2.0) (local.get $z0_re))))
        (local.set $diff (f32x4.replace_lane 1 (v128.const f32x4 0 0 0 0)
                           (f32.mul (f32.const 2.0) (local.get $z0_im))))

        (local.set $wk_rot
          (f32x4.mul
            (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 (local.get $wk) (local.get $wk))
            (v128.const f32x4 1.0 -1.0 1.0 -1.0)))

        (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 0 1 2 3 0 1 2 3
                                      (local.get $wk_rot) (local.get $wk_rot)))
        (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 4 5 6 7 4 5 6 7
                                      (local.get $wk_rot) (local.get $wk_rot)))
        (local.set $prod (f32x4.mul (local.get $diff) (local.get $wr)))
        (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3
                                           (local.get $diff) (local.get $diff)))
        (local.set $wd (f32x4.add (local.get $prod)
          (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))

        (local.set $xk (f32x4.mul (f32x4.add (local.get $sum) (local.get $wd)) (local.get $half)))
        (v128.store64_lane 0 (local.get $addr_k) (local.get $xk))
      )
    )
  )


  ;; ============================================================================
  ;; N=16 Parameterized Kernel (operates at offset)
  ;; ============================================================================
  (func $fft_16_at (param $base i32)
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
    (local.set $d0 (v128.load (local.get $base)))
    (local.set $d1 (v128.load (i32.add (local.get $base) (i32.const 16))))
    (local.set $d2 (v128.load (i32.add (local.get $base) (i32.const 32))))
    (local.set $d3 (v128.load (i32.add (local.get $base) (i32.const 48))))
    (local.set $d4 (v128.load (i32.add (local.get $base) (i32.const 64))))
    (local.set $d5 (v128.load (i32.add (local.get $base) (i32.const 80))))
    (local.set $d6 (v128.load (i32.add (local.get $base) (i32.const 96))))
    (local.set $d7 (v128.load (i32.add (local.get $base) (i32.const 112))))

    ;; Stage 1: r=8 butterflies
    (local.set $t0 (f32x4.add (local.get $d0) (local.get $d4)))
    (local.set $t4 (f32x4.sub (local.get $d0) (local.get $d4)))
    (local.set $t1 (f32x4.add (local.get $d1) (local.get $d5)))
    (local.set $t5 (f32x4.sub (local.get $d1) (local.get $d5)))
    (local.set $t2 (f32x4.add (local.get $d2) (local.get $d6)))
    (local.set $t6 (f32x4.sub (local.get $d2) (local.get $d6)))
    (local.set $t3 (f32x4.add (local.get $d3) (local.get $d7)))
    (local.set $t7 (f32x4.sub (local.get $d3) (local.get $d7)))

    ;; t5 *= W_16^2 = (0.7071068, -0.7071068)
    (local.set $w (v128.const f32x4 0.7071068 -0.7071068 0.7071068 -0.7071068))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $w) (local.get $w)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $w) (local.get $w)))
    (local.set $prod1 (f32x4.mul (local.get $t5) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $t5) (local.get $t5)))
    (local.set $t5 (f32x4.add (local.get $prod1) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))

    ;; t6 *= W_16^4 = -j
    (local.set $t6 (f32x4.mul
      (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $t6) (local.get $t6))
      (v128.const f32x4 1.0 -1.0 1.0 -1.0)))

    ;; t7 *= W_16^6 = (-0.7071068, -0.7071068)
    (local.set $w (v128.const f32x4 -0.7071068 -0.7071068 -0.7071068 -0.7071068))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $w) (local.get $w)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $w) (local.get $w)))
    (local.set $prod1 (f32x4.mul (local.get $t7) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $t7) (local.get $t7)))
    (local.set $t7 (f32x4.add (local.get $prod1) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))

    ;; Stage 2: r=4 butterflies
    (local.set $u0 (f32x4.add (local.get $t0) (local.get $t2)))
    (local.set $u2 (f32x4.sub (local.get $t0) (local.get $t2)))
    (local.set $u1 (f32x4.add (local.get $t1) (local.get $t3)))
    (local.set $u3 (f32x4.sub (local.get $t1) (local.get $t3)))
    (local.set $u3 (f32x4.mul
      (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $u3) (local.get $u3))
      (v128.const f32x4 1.0 -1.0 1.0 -1.0)))
    (local.set $u4 (f32x4.add (local.get $t4) (local.get $t6)))
    (local.set $u6 (f32x4.sub (local.get $t4) (local.get $t6)))
    (local.set $u5 (f32x4.add (local.get $t5) (local.get $t7)))
    (local.set $u7 (f32x4.sub (local.get $t5) (local.get $t7)))
    (local.set $u7 (f32x4.mul
      (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $u7) (local.get $u7))
      (v128.const f32x4 1.0 -1.0 1.0 -1.0)))

    ;; Stage 3: r=2 butterflies
    (local.set $d0 (f32x4.add (local.get $u0) (local.get $u1)))
    (local.set $d1 (f32x4.sub (local.get $u0) (local.get $u1)))
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
    (local.set $prod1 (f32x4.mul (local.get $u7) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $u7) (local.get $u7)))
    (local.set $u7 (f32x4.add (local.get $prod1) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))
    (local.set $d6 (f32x4.add (local.get $u6) (local.get $u7)))
    (local.set $d7 (f32x4.sub (local.get $u6) (local.get $u7)))

    ;; Bit-reversal output
    (v128.store (local.get $base)
      (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $d0) (local.get $d2)))
    (v128.store (i32.add (local.get $base) (i32.const 16))
      (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $d1) (local.get $d3)))
    (v128.store (i32.add (local.get $base) (i32.const 32))
      (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $d4) (local.get $d6)))
    (v128.store (i32.add (local.get $base) (i32.const 48))
      (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23 (local.get $d5) (local.get $d7)))
    (v128.store (i32.add (local.get $base) (i32.const 64))
      (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $d0) (local.get $d2)))
    (v128.store (i32.add (local.get $base) (i32.const 80))
      (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $d1) (local.get $d3)))
    (v128.store (i32.add (local.get $base) (i32.const 96))
      (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $d4) (local.get $d6)))
    (v128.store (i32.add (local.get $base) (i32.const 112))
      (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31 (local.get $d5) (local.get $d7)))
  )


  ;; ============================================================================
  ;; N=32 Hierarchical Codelet (DIF decomposition using two FFT-16)
  ;; ============================================================================
  ;; Uses DIF: first stage butterflies with W_32^k, then two FFT-16 on halves
  (func $fft_32
    (local $a v128) (local $b v128) (local $w v128)
    (local $wr v128) (local $wi v128) (local $prod v128) (local $swapped v128)
    (local $diff v128)

    ;; W_32^k twiddles (k=0 to 15, dual-packed)
    ;; k=0,1: W_32^0 = (1,0), W_32^1 = (0.9808, -0.1951)
    (local.set $a (v128.load (i32.const 0)))
    (local.set $b (v128.load (i32.const 128)))
    (v128.store (i32.const 0) (f32x4.add (local.get $a) (local.get $b)))
    (local.set $diff (f32x4.sub (local.get $a) (local.get $b)))
    ;; diff * W_32^(0,1) = diff * [(1,0), (0.9808,-0.1951)]
    (local.set $w (v128.const f32x4 1.0 0.0 0.98078528 -0.19509032))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $w) (local.get $w)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $w) (local.get $w)))
    (local.set $prod (f32x4.mul (local.get $diff) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff) (local.get $diff)))
    (v128.store (i32.const 128) (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))

    ;; k=2,3: W_32^2 = (0.9239, -0.3827), W_32^3 = (0.8315, -0.5556)
    (local.set $a (v128.load (i32.const 16)))
    (local.set $b (v128.load (i32.const 144)))
    (v128.store (i32.const 16) (f32x4.add (local.get $a) (local.get $b)))
    (local.set $diff (f32x4.sub (local.get $a) (local.get $b)))
    (local.set $w (v128.const f32x4 0.92387953 -0.38268343 0.83146961 -0.55557023))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $w) (local.get $w)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $w) (local.get $w)))
    (local.set $prod (f32x4.mul (local.get $diff) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff) (local.get $diff)))
    (v128.store (i32.const 144) (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))

    ;; k=4,5: W_32^4 = (0.7071, -0.7071), W_32^5 = (0.5556, -0.8315)
    (local.set $a (v128.load (i32.const 32)))
    (local.set $b (v128.load (i32.const 160)))
    (v128.store (i32.const 32) (f32x4.add (local.get $a) (local.get $b)))
    (local.set $diff (f32x4.sub (local.get $a) (local.get $b)))
    (local.set $w (v128.const f32x4 0.70710678 -0.70710678 0.55557023 -0.83146961))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $w) (local.get $w)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $w) (local.get $w)))
    (local.set $prod (f32x4.mul (local.get $diff) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff) (local.get $diff)))
    (v128.store (i32.const 160) (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))

    ;; k=6,7: W_32^6 = (0.3827, -0.9239), W_32^7 = (0.1951, -0.9808)
    (local.set $a (v128.load (i32.const 48)))
    (local.set $b (v128.load (i32.const 176)))
    (v128.store (i32.const 48) (f32x4.add (local.get $a) (local.get $b)))
    (local.set $diff (f32x4.sub (local.get $a) (local.get $b)))
    (local.set $w (v128.const f32x4 0.38268343 -0.92387953 0.19509032 -0.98078528))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $w) (local.get $w)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $w) (local.get $w)))
    (local.set $prod (f32x4.mul (local.get $diff) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff) (local.get $diff)))
    (v128.store (i32.const 176) (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))

    ;; k=8,9: W_32^8 = (0, -1), W_32^9 = (-0.1951, -0.9808)
    (local.set $a (v128.load (i32.const 64)))
    (local.set $b (v128.load (i32.const 192)))
    (v128.store (i32.const 64) (f32x4.add (local.get $a) (local.get $b)))
    (local.set $diff (f32x4.sub (local.get $a) (local.get $b)))
    (local.set $w (v128.const f32x4 0.0 -1.0 -0.19509032 -0.98078528))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $w) (local.get $w)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $w) (local.get $w)))
    (local.set $prod (f32x4.mul (local.get $diff) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff) (local.get $diff)))
    (v128.store (i32.const 192) (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))

    ;; k=10,11: W_32^10 = (-0.3827, -0.9239), W_32^11 = (-0.5556, -0.8315)
    (local.set $a (v128.load (i32.const 80)))
    (local.set $b (v128.load (i32.const 208)))
    (v128.store (i32.const 80) (f32x4.add (local.get $a) (local.get $b)))
    (local.set $diff (f32x4.sub (local.get $a) (local.get $b)))
    (local.set $w (v128.const f32x4 -0.38268343 -0.92387953 -0.55557023 -0.83146961))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $w) (local.get $w)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $w) (local.get $w)))
    (local.set $prod (f32x4.mul (local.get $diff) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff) (local.get $diff)))
    (v128.store (i32.const 208) (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))

    ;; k=12,13: W_32^12 = (-0.7071, -0.7071), W_32^13 = (-0.8315, -0.5556)
    (local.set $a (v128.load (i32.const 96)))
    (local.set $b (v128.load (i32.const 224)))
    (v128.store (i32.const 96) (f32x4.add (local.get $a) (local.get $b)))
    (local.set $diff (f32x4.sub (local.get $a) (local.get $b)))
    (local.set $w (v128.const f32x4 -0.70710678 -0.70710678 -0.83146961 -0.55557023))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $w) (local.get $w)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $w) (local.get $w)))
    (local.set $prod (f32x4.mul (local.get $diff) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff) (local.get $diff)))
    (v128.store (i32.const 224) (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))

    ;; k=14,15: W_32^14 = (-0.9239, -0.3827), W_32^15 = (-0.9808, -0.1951)
    (local.set $a (v128.load (i32.const 112)))
    (local.set $b (v128.load (i32.const 240)))
    (v128.store (i32.const 112) (f32x4.add (local.get $a) (local.get $b)))
    (local.set $diff (f32x4.sub (local.get $a) (local.get $b)))
    (local.set $w (v128.const f32x4 -0.92387953 -0.38268343 -0.98078528 -0.19509032))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $w) (local.get $w)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $w) (local.get $w)))
    (local.set $prod (f32x4.mul (local.get $diff) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff) (local.get $diff)))
    (v128.store (i32.const 240) (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))

    ;; Two FFT-16 on each half
    (call $fft_16_at (i32.const 0))    ;; First half: indices 0-15
    (call $fft_16_at (i32.const 128))  ;; Second half: indices 16-31
  )


  ;; ============================================================================
  ;; N=32 Parameterized Codelet (for use by fft_64)
  ;; ============================================================================
  (func $fft_32_at (param $base i32)
    (local $a v128) (local $b v128) (local $w v128)
    (local $wr v128) (local $wi v128) (local $prod v128) (local $swapped v128)
    (local $diff v128)

    ;; k=0,1: W_32^0 = (1,0), W_32^1 = (0.9808, -0.1951)
    (local.set $a (v128.load (local.get $base)))
    (local.set $b (v128.load (i32.add (local.get $base) (i32.const 128))))
    (v128.store (local.get $base) (f32x4.add (local.get $a) (local.get $b)))
    (local.set $diff (f32x4.sub (local.get $a) (local.get $b)))
    (local.set $w (v128.const f32x4 1.0 0.0 0.98078528 -0.19509032))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $w) (local.get $w)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $w) (local.get $w)))
    (local.set $prod (f32x4.mul (local.get $diff) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff) (local.get $diff)))
    (v128.store (i32.add (local.get $base) (i32.const 128)) (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))

    ;; k=2,3: W_32^2 = (0.9239, -0.3827), W_32^3 = (0.8315, -0.5556)
    (local.set $a (v128.load (i32.add (local.get $base) (i32.const 16))))
    (local.set $b (v128.load (i32.add (local.get $base) (i32.const 144))))
    (v128.store (i32.add (local.get $base) (i32.const 16)) (f32x4.add (local.get $a) (local.get $b)))
    (local.set $diff (f32x4.sub (local.get $a) (local.get $b)))
    (local.set $w (v128.const f32x4 0.92387953 -0.38268343 0.83146961 -0.55557023))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $w) (local.get $w)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $w) (local.get $w)))
    (local.set $prod (f32x4.mul (local.get $diff) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff) (local.get $diff)))
    (v128.store (i32.add (local.get $base) (i32.const 144)) (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))

    ;; k=4,5: W_32^4 = (0.7071, -0.7071), W_32^5 = (0.5556, -0.8315)
    (local.set $a (v128.load (i32.add (local.get $base) (i32.const 32))))
    (local.set $b (v128.load (i32.add (local.get $base) (i32.const 160))))
    (v128.store (i32.add (local.get $base) (i32.const 32)) (f32x4.add (local.get $a) (local.get $b)))
    (local.set $diff (f32x4.sub (local.get $a) (local.get $b)))
    (local.set $w (v128.const f32x4 0.70710678 -0.70710678 0.55557023 -0.83146961))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $w) (local.get $w)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $w) (local.get $w)))
    (local.set $prod (f32x4.mul (local.get $diff) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff) (local.get $diff)))
    (v128.store (i32.add (local.get $base) (i32.const 160)) (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))

    ;; k=6,7: W_32^6 = (0.3827, -0.9239), W_32^7 = (0.1951, -0.9808)
    (local.set $a (v128.load (i32.add (local.get $base) (i32.const 48))))
    (local.set $b (v128.load (i32.add (local.get $base) (i32.const 176))))
    (v128.store (i32.add (local.get $base) (i32.const 48)) (f32x4.add (local.get $a) (local.get $b)))
    (local.set $diff (f32x4.sub (local.get $a) (local.get $b)))
    (local.set $w (v128.const f32x4 0.38268343 -0.92387953 0.19509032 -0.98078528))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $w) (local.get $w)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $w) (local.get $w)))
    (local.set $prod (f32x4.mul (local.get $diff) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff) (local.get $diff)))
    (v128.store (i32.add (local.get $base) (i32.const 176)) (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))

    ;; k=8,9: W_32^8 = (0, -1), W_32^9 = (-0.1951, -0.9808)
    (local.set $a (v128.load (i32.add (local.get $base) (i32.const 64))))
    (local.set $b (v128.load (i32.add (local.get $base) (i32.const 192))))
    (v128.store (i32.add (local.get $base) (i32.const 64)) (f32x4.add (local.get $a) (local.get $b)))
    (local.set $diff (f32x4.sub (local.get $a) (local.get $b)))
    (local.set $w (v128.const f32x4 0.0 -1.0 -0.19509032 -0.98078528))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $w) (local.get $w)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $w) (local.get $w)))
    (local.set $prod (f32x4.mul (local.get $diff) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff) (local.get $diff)))
    (v128.store (i32.add (local.get $base) (i32.const 192)) (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))

    ;; k=10,11: W_32^10 = (-0.3827, -0.9239), W_32^11 = (-0.5556, -0.8315)
    (local.set $a (v128.load (i32.add (local.get $base) (i32.const 80))))
    (local.set $b (v128.load (i32.add (local.get $base) (i32.const 208))))
    (v128.store (i32.add (local.get $base) (i32.const 80)) (f32x4.add (local.get $a) (local.get $b)))
    (local.set $diff (f32x4.sub (local.get $a) (local.get $b)))
    (local.set $w (v128.const f32x4 -0.38268343 -0.92387953 -0.55557023 -0.83146961))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $w) (local.get $w)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $w) (local.get $w)))
    (local.set $prod (f32x4.mul (local.get $diff) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff) (local.get $diff)))
    (v128.store (i32.add (local.get $base) (i32.const 208)) (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))

    ;; k=12,13: W_32^12 = (-0.7071, -0.7071), W_32^13 = (-0.8315, -0.5556)
    (local.set $a (v128.load (i32.add (local.get $base) (i32.const 96))))
    (local.set $b (v128.load (i32.add (local.get $base) (i32.const 224))))
    (v128.store (i32.add (local.get $base) (i32.const 96)) (f32x4.add (local.get $a) (local.get $b)))
    (local.set $diff (f32x4.sub (local.get $a) (local.get $b)))
    (local.set $w (v128.const f32x4 -0.70710678 -0.70710678 -0.83146961 -0.55557023))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $w) (local.get $w)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $w) (local.get $w)))
    (local.set $prod (f32x4.mul (local.get $diff) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff) (local.get $diff)))
    (v128.store (i32.add (local.get $base) (i32.const 224)) (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))

    ;; k=14,15: W_32^14 = (-0.9239, -0.3827), W_32^15 = (-0.9808, -0.1951)
    (local.set $a (v128.load (i32.add (local.get $base) (i32.const 112))))
    (local.set $b (v128.load (i32.add (local.get $base) (i32.const 240))))
    (v128.store (i32.add (local.get $base) (i32.const 112)) (f32x4.add (local.get $a) (local.get $b)))
    (local.set $diff (f32x4.sub (local.get $a) (local.get $b)))
    (local.set $w (v128.const f32x4 -0.92387953 -0.38268343 -0.98078528 -0.19509032))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $w) (local.get $w)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $w) (local.get $w)))
    (local.set $prod (f32x4.mul (local.get $diff) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff) (local.get $diff)))
    (v128.store (i32.add (local.get $base) (i32.const 240)) (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))

    ;; Two FFT-16 on each half
    (call $fft_16_at (local.get $base))
    (call $fft_16_at (i32.add (local.get $base) (i32.const 128)))
  )


  ;; ============================================================================
  ;; N=64 Hierarchical Codelet (DIF decomposition using two FFT-32)
  ;; ============================================================================
  ;; 64 complex = 32 dual-packed v128 values
  ;; First stage: 32 butterflies with W_64^k twiddles, then two FFT-32
  (func $fft_64
    (local $a v128) (local $b v128) (local $w v128)
    (local $wr v128) (local $wi v128) (local $prod v128) (local $swapped v128)
    (local $diff v128)

    ;; Stage 1: butterflies between indices k and k+32, with W_64^k twiddles
    ;; 64 complex numbers = 512 bytes per half, offsets 0-255 and 256-511

    ;; k=0,1: W_64^0 = (1,0), W_64^1 = (0.9952, -0.0980)
    (local.set $a (v128.load (i32.const 0)))
    (local.set $b (v128.load (i32.const 256)))
    (v128.store (i32.const 0) (f32x4.add (local.get $a) (local.get $b)))
    (local.set $diff (f32x4.sub (local.get $a) (local.get $b)))
    (local.set $w (v128.const f32x4 1.0 0.0 0.99518473 -0.09801714))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $w) (local.get $w)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $w) (local.get $w)))
    (local.set $prod (f32x4.mul (local.get $diff) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff) (local.get $diff)))
    (v128.store (i32.const 256) (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))

    ;; k=2,3: W_64^2 = (0.9808, -0.1951), W_64^3 = (0.9569, -0.2903)
    (local.set $a (v128.load (i32.const 16)))
    (local.set $b (v128.load (i32.const 272)))
    (v128.store (i32.const 16) (f32x4.add (local.get $a) (local.get $b)))
    (local.set $diff (f32x4.sub (local.get $a) (local.get $b)))
    (local.set $w (v128.const f32x4 0.98078528 -0.19509032 0.95694034 -0.29028468))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $w) (local.get $w)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $w) (local.get $w)))
    (local.set $prod (f32x4.mul (local.get $diff) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff) (local.get $diff)))
    (v128.store (i32.const 272) (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))

    ;; k=4,5: W_64^4 = (0.9239, -0.3827), W_64^5 = (0.8819, -0.4714)
    (local.set $a (v128.load (i32.const 32)))
    (local.set $b (v128.load (i32.const 288)))
    (v128.store (i32.const 32) (f32x4.add (local.get $a) (local.get $b)))
    (local.set $diff (f32x4.sub (local.get $a) (local.get $b)))
    (local.set $w (v128.const f32x4 0.92387953 -0.38268343 0.88192126 -0.47139674))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $w) (local.get $w)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $w) (local.get $w)))
    (local.set $prod (f32x4.mul (local.get $diff) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff) (local.get $diff)))
    (v128.store (i32.const 288) (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))

    ;; k=6,7: W_64^6 = (0.8315, -0.5556), W_64^7 = (0.7730, -0.6344)
    (local.set $a (v128.load (i32.const 48)))
    (local.set $b (v128.load (i32.const 304)))
    (v128.store (i32.const 48) (f32x4.add (local.get $a) (local.get $b)))
    (local.set $diff (f32x4.sub (local.get $a) (local.get $b)))
    (local.set $w (v128.const f32x4 0.83146961 -0.55557023 0.77301045 -0.63439328))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $w) (local.get $w)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $w) (local.get $w)))
    (local.set $prod (f32x4.mul (local.get $diff) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff) (local.get $diff)))
    (v128.store (i32.const 304) (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))

    ;; k=8,9: W_64^8 = (0.7071, -0.7071), W_64^9 = (0.6344, -0.7730)
    (local.set $a (v128.load (i32.const 64)))
    (local.set $b (v128.load (i32.const 320)))
    (v128.store (i32.const 64) (f32x4.add (local.get $a) (local.get $b)))
    (local.set $diff (f32x4.sub (local.get $a) (local.get $b)))
    (local.set $w (v128.const f32x4 0.70710678 -0.70710678 0.63439328 -0.77301045))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $w) (local.get $w)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $w) (local.get $w)))
    (local.set $prod (f32x4.mul (local.get $diff) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff) (local.get $diff)))
    (v128.store (i32.const 320) (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))

    ;; k=10,11: W_64^10 = (0.5556, -0.8315), W_64^11 = (0.4714, -0.8819)
    (local.set $a (v128.load (i32.const 80)))
    (local.set $b (v128.load (i32.const 336)))
    (v128.store (i32.const 80) (f32x4.add (local.get $a) (local.get $b)))
    (local.set $diff (f32x4.sub (local.get $a) (local.get $b)))
    (local.set $w (v128.const f32x4 0.55557023 -0.83146961 0.47139674 -0.88192126))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $w) (local.get $w)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $w) (local.get $w)))
    (local.set $prod (f32x4.mul (local.get $diff) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff) (local.get $diff)))
    (v128.store (i32.const 336) (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))

    ;; k=12,13: W_64^12 = (0.3827, -0.9239), W_64^13 = (0.2903, -0.9569)
    (local.set $a (v128.load (i32.const 96)))
    (local.set $b (v128.load (i32.const 352)))
    (v128.store (i32.const 96) (f32x4.add (local.get $a) (local.get $b)))
    (local.set $diff (f32x4.sub (local.get $a) (local.get $b)))
    (local.set $w (v128.const f32x4 0.38268343 -0.92387953 0.29028468 -0.95694034))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $w) (local.get $w)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $w) (local.get $w)))
    (local.set $prod (f32x4.mul (local.get $diff) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff) (local.get $diff)))
    (v128.store (i32.const 352) (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))

    ;; k=14,15: W_64^14 = (0.1951, -0.9808), W_64^15 = (0.0980, -0.9952)
    (local.set $a (v128.load (i32.const 112)))
    (local.set $b (v128.load (i32.const 368)))
    (v128.store (i32.const 112) (f32x4.add (local.get $a) (local.get $b)))
    (local.set $diff (f32x4.sub (local.get $a) (local.get $b)))
    (local.set $w (v128.const f32x4 0.19509032 -0.98078528 0.09801714 -0.99518473))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $w) (local.get $w)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $w) (local.get $w)))
    (local.set $prod (f32x4.mul (local.get $diff) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff) (local.get $diff)))
    (v128.store (i32.const 368) (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))

    ;; k=16,17: W_64^16 = (0, -1), W_64^17 = (-0.0980, -0.9952)
    (local.set $a (v128.load (i32.const 128)))
    (local.set $b (v128.load (i32.const 384)))
    (v128.store (i32.const 128) (f32x4.add (local.get $a) (local.get $b)))
    (local.set $diff (f32x4.sub (local.get $a) (local.get $b)))
    (local.set $w (v128.const f32x4 0.0 -1.0 -0.09801714 -0.99518473))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $w) (local.get $w)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $w) (local.get $w)))
    (local.set $prod (f32x4.mul (local.get $diff) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff) (local.get $diff)))
    (v128.store (i32.const 384) (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))

    ;; k=18,19: W_64^18 = (-0.1951, -0.9808), W_64^19 = (-0.2903, -0.9569)
    (local.set $a (v128.load (i32.const 144)))
    (local.set $b (v128.load (i32.const 400)))
    (v128.store (i32.const 144) (f32x4.add (local.get $a) (local.get $b)))
    (local.set $diff (f32x4.sub (local.get $a) (local.get $b)))
    (local.set $w (v128.const f32x4 -0.19509032 -0.98078528 -0.29028468 -0.95694034))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $w) (local.get $w)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $w) (local.get $w)))
    (local.set $prod (f32x4.mul (local.get $diff) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff) (local.get $diff)))
    (v128.store (i32.const 400) (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))

    ;; k=20,21: W_64^20 = (-0.3827, -0.9239), W_64^21 = (-0.4714, -0.8819)
    (local.set $a (v128.load (i32.const 160)))
    (local.set $b (v128.load (i32.const 416)))
    (v128.store (i32.const 160) (f32x4.add (local.get $a) (local.get $b)))
    (local.set $diff (f32x4.sub (local.get $a) (local.get $b)))
    (local.set $w (v128.const f32x4 -0.38268343 -0.92387953 -0.47139674 -0.88192126))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $w) (local.get $w)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $w) (local.get $w)))
    (local.set $prod (f32x4.mul (local.get $diff) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff) (local.get $diff)))
    (v128.store (i32.const 416) (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))

    ;; k=22,23: W_64^22 = (-0.5556, -0.8315), W_64^23 = (-0.6344, -0.7730)
    (local.set $a (v128.load (i32.const 176)))
    (local.set $b (v128.load (i32.const 432)))
    (v128.store (i32.const 176) (f32x4.add (local.get $a) (local.get $b)))
    (local.set $diff (f32x4.sub (local.get $a) (local.get $b)))
    (local.set $w (v128.const f32x4 -0.55557023 -0.83146961 -0.63439328 -0.77301045))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $w) (local.get $w)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $w) (local.get $w)))
    (local.set $prod (f32x4.mul (local.get $diff) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff) (local.get $diff)))
    (v128.store (i32.const 432) (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))

    ;; k=24,25: W_64^24 = (-0.7071, -0.7071), W_64^25 = (-0.7730, -0.6344)
    (local.set $a (v128.load (i32.const 192)))
    (local.set $b (v128.load (i32.const 448)))
    (v128.store (i32.const 192) (f32x4.add (local.get $a) (local.get $b)))
    (local.set $diff (f32x4.sub (local.get $a) (local.get $b)))
    (local.set $w (v128.const f32x4 -0.70710678 -0.70710678 -0.77301045 -0.63439328))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $w) (local.get $w)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $w) (local.get $w)))
    (local.set $prod (f32x4.mul (local.get $diff) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff) (local.get $diff)))
    (v128.store (i32.const 448) (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))

    ;; k=26,27: W_64^26 = (-0.8315, -0.5556), W_64^27 = (-0.8819, -0.4714)
    (local.set $a (v128.load (i32.const 208)))
    (local.set $b (v128.load (i32.const 464)))
    (v128.store (i32.const 208) (f32x4.add (local.get $a) (local.get $b)))
    (local.set $diff (f32x4.sub (local.get $a) (local.get $b)))
    (local.set $w (v128.const f32x4 -0.83146961 -0.55557023 -0.88192126 -0.47139674))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $w) (local.get $w)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $w) (local.get $w)))
    (local.set $prod (f32x4.mul (local.get $diff) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff) (local.get $diff)))
    (v128.store (i32.const 464) (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))

    ;; k=28,29: W_64^28 = (-0.9239, -0.3827), W_64^29 = (-0.9569, -0.2903)
    (local.set $a (v128.load (i32.const 224)))
    (local.set $b (v128.load (i32.const 480)))
    (v128.store (i32.const 224) (f32x4.add (local.get $a) (local.get $b)))
    (local.set $diff (f32x4.sub (local.get $a) (local.get $b)))
    (local.set $w (v128.const f32x4 -0.92387953 -0.38268343 -0.95694034 -0.29028468))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $w) (local.get $w)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $w) (local.get $w)))
    (local.set $prod (f32x4.mul (local.get $diff) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff) (local.get $diff)))
    (v128.store (i32.const 480) (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))

    ;; k=30,31: W_64^30 = (-0.9808, -0.1951), W_64^31 = (-0.9952, -0.0980)
    (local.set $a (v128.load (i32.const 240)))
    (local.set $b (v128.load (i32.const 496)))
    (v128.store (i32.const 240) (f32x4.add (local.get $a) (local.get $b)))
    (local.set $diff (f32x4.sub (local.get $a) (local.get $b)))
    (local.set $w (v128.const f32x4 -0.98078528 -0.19509032 -0.99518473 -0.09801714))
    (local.set $wr (i8x16.shuffle 0 1 2 3 0 1 2 3 8 9 10 11 8 9 10 11 (local.get $w) (local.get $w)))
    (local.set $wi (i8x16.shuffle 4 5 6 7 4 5 6 7 12 13 14 15 12 13 14 15 (local.get $w) (local.get $w)))
    (local.set $prod (f32x4.mul (local.get $diff) (local.get $wr)))
    (local.set $swapped (i8x16.shuffle 4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11 (local.get $diff) (local.get $diff)))
    (v128.store (i32.const 496) (f32x4.add (local.get $prod) (f32x4.mul (f32x4.mul (local.get $swapped) (local.get $wi)) (global.get $SIGN_MASK))))

    ;; Two FFT-32 on each half
    (call $fft_32_at (i32.const 0))    ;; First half: indices 0-31
    (call $fft_32_at (i32.const 256))  ;; Second half: indices 32-63
  )


  ;; ============================================================================
  ;; Internal FFT Entry Point
  ;; ============================================================================

  (func $fft (param $n i32)
    ;; Use DIT codelets for small sizes - they load bit-reversed and output natural order.
    ;; This is compatible with RFFT post-processing.
    ;;
    ;; Note: Dispatch order doesn't significantly affect performance (tested).
    ;; The gap at N=64/128 vs fftw-js is within benchmark variance (~3-5%).
    (if (i32.le_u (local.get $n) (i32.const 32))
      (then
        (if (i32.eq (local.get $n) (i32.const 32))
          (then (call $fft_32_dit) (return)))
        (if (i32.eq (local.get $n) (i32.const 16))
          (then (call $fft_16_dit) (return)))
        (if (i32.eq (local.get $n) (i32.const 8))
          (then (call $fft_8_dit) (return)))
        (call $fft_4)
        (return)
      )
    )
    ;; N>=64: Fall back to Stockham (fft_64_dit has too many locals, causing register spills)
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
    ;; Use specialized unrolled codelet for N=64
    (if (i32.eq (local.get $n) (i32.const 64))
      (then
        (call $rfft_postprocess_64)
        (return)
      )
    )
    ;; Use SIMD for N >= 128 (n2 >= 64)
    (if (i32.ge_u (local.get $n) (i32.const 128))
      (then
        (call $rfft_postprocess_simd (local.get $n2))
        (return)
      )
    )

    ;; Scalar post-processing for small N (N < 64)
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
