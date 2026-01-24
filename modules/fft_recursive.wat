(module
  ;; Depth-First Recursive FFT using DIF (Decimation in Frequency)
  ;;
  ;; Uses cache-oblivious recursive decomposition:
  ;; - Base case: N <= 64 uses iterative Stockham
  ;; - Recursive case: DIF butterflies first, then recurse on halves
  ;;
  ;; DIF advantage: No data reordering needed before recursion
  ;;
  ;; Benefits for large N:
  ;; - Working set stays in cache longer
  ;; - Better temporal locality than breadth-first iteration
  ;; - Depth-first processing keeps data hot
  ;;
  ;; Memory layout:
  ;;   0 - 65535: Primary data buffer
  ;;   65536 - 131071: Secondary buffer (for iterative base case)
  ;;   131072+: Twiddle factors (precomputed for full N)

  (memory (export "memory") 4)

  (global $SECONDARY_OFFSET i32 (i32.const 65536))
  (global $TWIDDLE_OFFSET i32 (i32.const 131072))
  (global $PI f64 (f64.const 3.141592653589793))
  (global $HALF_PI f64 (f64.const 1.5707963267948966))

  ;; Store top-level N for twiddle stride calculation
  (global $TOP_N (mut i32) (i32.const 0))

  ;; Inline sin using Taylor series
  (func $sin (param $x f64) (result f64)
    (local $x2 f64) (local $term f64) (local $sum f64)
    (if (f64.lt (local.get $x) (f64.neg (global.get $PI)))
      (then (local.set $x (f64.add (local.get $x) (f64.mul (f64.const 2.0) (global.get $PI))))))
    (if (f64.gt (local.get $x) (global.get $PI))
      (then (local.set $x (f64.sub (local.get $x) (f64.mul (f64.const 2.0) (global.get $PI))))))
    (if (f64.gt (local.get $x) (global.get $HALF_PI))
      (then (local.set $x (f64.sub (global.get $PI) (local.get $x)))))
    (if (f64.lt (local.get $x) (f64.neg (global.get $HALF_PI)))
      (then (local.set $x (f64.sub (f64.neg (global.get $PI)) (local.get $x)))))
    (local.set $x2 (f64.mul (local.get $x) (local.get $x)))
    (local.set $sum (local.get $x))
    (local.set $term (local.get $x))
    (local.set $term (f64.mul (local.get $term) (f64.div (local.get $x2) (f64.const -6.0))))
    (local.set $sum (f64.add (local.get $sum) (local.get $term)))
    (local.set $term (f64.mul (local.get $term) (f64.div (local.get $x2) (f64.const -20.0))))
    (local.set $sum (f64.add (local.get $sum) (local.get $term)))
    (local.set $term (f64.mul (local.get $term) (f64.div (local.get $x2) (f64.const -42.0))))
    (local.set $sum (f64.add (local.get $sum) (local.get $term)))
    (local.set $term (f64.mul (local.get $term) (f64.div (local.get $x2) (f64.const -72.0))))
    (local.set $sum (f64.add (local.get $sum) (local.get $term)))
    (local.set $term (f64.mul (local.get $term) (f64.div (local.get $x2) (f64.const -110.0))))
    (local.set $sum (f64.add (local.get $sum) (local.get $term)))
    (local.set $term (f64.mul (local.get $term) (f64.div (local.get $x2) (f64.const -156.0))))
    (local.set $sum (f64.add (local.get $sum) (local.get $term)))
    (local.set $term (f64.mul (local.get $term) (f64.div (local.get $x2) (f64.const -210.0))))
    (local.set $sum (f64.add (local.get $sum) (local.get $term)))
    (local.get $sum)
  )

  ;; Inline cos using Taylor series
  (func $cos (param $x f64) (result f64)
    (local $x2 f64) (local $term f64) (local $sum f64) (local $sign f64)
    (if (f64.lt (local.get $x) (f64.neg (global.get $PI)))
      (then (local.set $x (f64.add (local.get $x) (f64.mul (f64.const 2.0) (global.get $PI))))))
    (if (f64.gt (local.get $x) (global.get $PI))
      (then (local.set $x (f64.sub (local.get $x) (f64.mul (f64.const 2.0) (global.get $PI))))))
    (local.set $sign (f64.const 1.0))
    (if (f64.gt (local.get $x) (global.get $HALF_PI))
      (then
        (local.set $x (f64.sub (global.get $PI) (local.get $x)))
        (local.set $sign (f64.const -1.0))))
    (if (f64.lt (local.get $x) (f64.neg (global.get $HALF_PI)))
      (then
        (local.set $x (f64.add (global.get $PI) (local.get $x)))
        (local.set $sign (f64.const -1.0))))
    (local.set $x2 (f64.mul (local.get $x) (local.get $x)))
    (local.set $sum (f64.const 1.0))
    (local.set $term (f64.const 1.0))
    (local.set $term (f64.mul (local.get $term) (f64.div (local.get $x2) (f64.const -2.0))))
    (local.set $sum (f64.add (local.get $sum) (local.get $term)))
    (local.set $term (f64.mul (local.get $term) (f64.div (local.get $x2) (f64.const -12.0))))
    (local.set $sum (f64.add (local.get $sum) (local.get $term)))
    (local.set $term (f64.mul (local.get $term) (f64.div (local.get $x2) (f64.const -30.0))))
    (local.set $sum (f64.add (local.get $sum) (local.get $term)))
    (local.set $term (f64.mul (local.get $term) (f64.div (local.get $x2) (f64.const -56.0))))
    (local.set $sum (f64.add (local.get $sum) (local.get $term)))
    (local.set $term (f64.mul (local.get $term) (f64.div (local.get $x2) (f64.const -90.0))))
    (local.set $sum (f64.add (local.get $sum) (local.get $term)))
    (local.set $term (f64.mul (local.get $term) (f64.div (local.get $x2) (f64.const -132.0))))
    (local.set $sum (f64.add (local.get $sum) (local.get $term)))
    (local.set $term (f64.mul (local.get $term) (f64.div (local.get $x2) (f64.const -182.0))))
    (local.set $sum (f64.add (local.get $sum) (local.get $term)))
    (f64.mul (local.get $sum) (local.get $sign))
  )

  ;; Precompute twiddles W_N^k for k = 0..N-1
  (func $precompute_twiddles (export "precompute_twiddles") (param $n i32)
    (local $k i32) (local $angle f64) (local $addr i32) (local $neg_two_pi_over_n f64)
    (if (i32.le_u (local.get $n) (i32.const 4)) (then (return)))
    (local.set $neg_two_pi_over_n
      (f64.div (f64.mul (f64.const -2.0) (global.get $PI))
               (f64.convert_i32_u (local.get $n))))
    (local.set $addr (global.get $TWIDDLE_OFFSET))
    (local.set $k (i32.const 0))
    (block $done (loop $loop
      (br_if $done (i32.ge_u (local.get $k) (local.get $n)))
      (local.set $angle (f64.mul (f64.convert_i32_u (local.get $k)) (local.get $neg_two_pi_over_n)))
      (f64.store (local.get $addr) (call $cos (local.get $angle)))
      (f64.store (i32.add (local.get $addr) (i32.const 8)) (call $sin (local.get $angle)))
      (local.set $addr (i32.add (local.get $addr) (i32.const 16)))
      (local.set $k (i32.add (local.get $k) (i32.const 1)))
      (br $loop)
    ))
  )

  ;; ============================================================================
  ;; N=2 base case (DIF butterfly, no twiddle)
  ;; ============================================================================
  (func $fft_2_at (param $base i32)
    (local $x0 v128) (local $x1 v128)
    (local.set $x0 (v128.load (local.get $base)))
    (local.set $x1 (v128.load (i32.add (local.get $base) (i32.const 16))))
    (v128.store (local.get $base) (f64x2.add (local.get $x0) (local.get $x1)))
    (v128.store (i32.add (local.get $base) (i32.const 16)) (f64x2.sub (local.get $x0) (local.get $x1)))
  )

  ;; ============================================================================
  ;; N=4 base case using SIMD (radix-4 DIF)
  ;; ============================================================================
  (func $fft_4_at (param $base i32)
    (local $x0 v128) (local $x1 v128) (local $x2 v128) (local $x3 v128)
    (local $t0 v128) (local $t1 v128) (local $t2 v128) (local $t3 v128)

    (local.set $x0 (v128.load (local.get $base)))
    (local.set $x1 (v128.load (i32.add (local.get $base) (i32.const 16))))
    (local.set $x2 (v128.load (i32.add (local.get $base) (i32.const 32))))
    (local.set $x3 (v128.load (i32.add (local.get $base) (i32.const 48))))

    ;; DIF Stage 1: butterflies with stride N/2=2
    (local.set $t0 (f64x2.add (local.get $x0) (local.get $x2)))
    (local.set $t1 (f64x2.add (local.get $x1) (local.get $x3)))
    (local.set $t2 (f64x2.sub (local.get $x0) (local.get $x2)))  ;; * W_4^0 = 1
    (local.set $t3 (f64x2.sub (local.get $x1) (local.get $x3)))  ;; * W_4^1 = -j

    ;; Apply -j to t3: (a,b) -> (b,-a)
    (local.set $t3
      (f64x2.mul
        (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $t3) (local.get $t3))
        (v128.const f64x2 1.0 -1.0)))

    ;; DIF Stage 2: butterflies with stride N/4=1
    (v128.store (local.get $base) (f64x2.add (local.get $t0) (local.get $t1)))
    (v128.store (i32.add (local.get $base) (i32.const 16)) (f64x2.sub (local.get $t0) (local.get $t1)))
    (v128.store (i32.add (local.get $base) (i32.const 32)) (f64x2.add (local.get $t2) (local.get $t3)))
    (v128.store (i32.add (local.get $base) (i32.const 48)) (f64x2.sub (local.get $t2) (local.get $t3)))
  )

  ;; ============================================================================
  ;; N=8 base case (DIF with hardcoded twiddles)
  ;; ============================================================================
  (func $fft_8_at (param $base i32)
    (local $x0 v128) (local $x1 v128) (local $x2 v128) (local $x3 v128)
    (local $x4 v128) (local $x5 v128) (local $x6 v128) (local $x7 v128)
    (local $t0 v128) (local $t1 v128) (local $t2 v128) (local $t3 v128)
    (local $a v128) (local $b v128)

    ;; Load all 8 complex values
    (local.set $x0 (v128.load (local.get $base)))
    (local.set $x1 (v128.load (i32.add (local.get $base) (i32.const 16))))
    (local.set $x2 (v128.load (i32.add (local.get $base) (i32.const 32))))
    (local.set $x3 (v128.load (i32.add (local.get $base) (i32.const 48))))
    (local.set $x4 (v128.load (i32.add (local.get $base) (i32.const 64))))
    (local.set $x5 (v128.load (i32.add (local.get $base) (i32.const 80))))
    (local.set $x6 (v128.load (i32.add (local.get $base) (i32.const 96))))
    (local.set $x7 (v128.load (i32.add (local.get $base) (i32.const 112))))

    ;; DIF Stage 1: butterflies combining x[k] and x[k+4] with W_8^k
    ;; k=0: W_8^0 = (1, 0)
    (local.set $t0 (f64x2.add (local.get $x0) (local.get $x4)))
    (local.set $a (f64x2.sub (local.get $x0) (local.get $x4)))
    (v128.store (local.get $base) (local.get $t0))
    (v128.store (i32.add (local.get $base) (i32.const 64)) (local.get $a))

    ;; k=1: W_8^1 = (0.7071067811865476, -0.7071067811865476)
    (local.set $t1 (f64x2.add (local.get $x1) (local.get $x5)))
    (local.set $a (f64x2.sub (local.get $x1) (local.get $x5)))
    (local.set $b (f64x2.add
      (f64x2.mul (local.get $a) (v128.const f64x2 0.7071067811865476 0.7071067811865476))
      (f64x2.mul (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)) (v128.const f64x2 -0.7071067811865476 -0.7071067811865476)) (v128.const f64x2 -1.0 1.0))))
    (v128.store (i32.add (local.get $base) (i32.const 16)) (local.get $t1))
    (v128.store (i32.add (local.get $base) (i32.const 80)) (local.get $b))

    ;; k=2: W_8^2 = (0, -1) = -j
    (local.set $t2 (f64x2.add (local.get $x2) (local.get $x6)))
    (local.set $a (f64x2.sub (local.get $x2) (local.get $x6)))
    (local.set $b (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)) (v128.const f64x2 1.0 -1.0)))
    (v128.store (i32.add (local.get $base) (i32.const 32)) (local.get $t2))
    (v128.store (i32.add (local.get $base) (i32.const 96)) (local.get $b))

    ;; k=3: W_8^3 = (-0.7071067811865476, -0.7071067811865476)
    (local.set $t3 (f64x2.add (local.get $x3) (local.get $x7)))
    (local.set $a (f64x2.sub (local.get $x3) (local.get $x7)))
    (local.set $b (f64x2.add
      (f64x2.mul (local.get $a) (v128.const f64x2 -0.7071067811865476 -0.7071067811865476))
      (f64x2.mul (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a)) (v128.const f64x2 -0.7071067811865476 -0.7071067811865476)) (v128.const f64x2 -1.0 1.0))))
    (v128.store (i32.add (local.get $base) (i32.const 48)) (local.get $t3))
    (v128.store (i32.add (local.get $base) (i32.const 112)) (local.get $b))

    ;; DIF Stage 2 & 3: Two FFT-4s on each half
    (call $fft_4_at (local.get $base))
    (call $fft_4_at (i32.add (local.get $base) (i32.const 64)))
  )

  ;; ============================================================================
  ;; N=16 base case (DIF with hardcoded twiddles)
  ;; ============================================================================
  (func $fft_16_at (param $base i32)
    (local $a v128) (local $b v128) (local $t v128)
    (local $off8 i32)

    (local.set $off8 (i32.add (local.get $base) (i32.const 128)))  ;; 8 * 16 bytes

    ;; DIF first pass: butterflies combining x[k] and x[k+8] with W_16^k

    ;; k=0: W_16^0 = (1, 0)
    (local.set $a (v128.load (local.get $base)))
    (local.set $b (v128.load (local.get $off8)))
    (v128.store (local.get $base) (f64x2.add (local.get $a) (local.get $b)))
    (v128.store (local.get $off8) (f64x2.sub (local.get $a) (local.get $b)))

    ;; k=1: W_16^1 = (0.9238795325112867, -0.3826834323650898)
    (local.set $a (v128.load (i32.add (local.get $base) (i32.const 16))))
    (local.set $b (v128.load (i32.add (local.get $off8) (i32.const 16))))
    (local.set $t (f64x2.sub (local.get $a) (local.get $b)))
    (v128.store (i32.add (local.get $base) (i32.const 16)) (f64x2.add (local.get $a) (local.get $b)))
    (v128.store (i32.add (local.get $off8) (i32.const 16)) (f64x2.add
      (f64x2.mul (local.get $t) (v128.const f64x2 0.9238795325112867 0.9238795325112867))
      (f64x2.mul (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $t) (local.get $t)) (v128.const f64x2 -0.3826834323650898 -0.3826834323650898)) (v128.const f64x2 -1.0 1.0))))

    ;; k=2: W_16^2 = (0.7071067811865476, -0.7071067811865476)
    (local.set $a (v128.load (i32.add (local.get $base) (i32.const 32))))
    (local.set $b (v128.load (i32.add (local.get $off8) (i32.const 32))))
    (local.set $t (f64x2.sub (local.get $a) (local.get $b)))
    (v128.store (i32.add (local.get $base) (i32.const 32)) (f64x2.add (local.get $a) (local.get $b)))
    (v128.store (i32.add (local.get $off8) (i32.const 32)) (f64x2.add
      (f64x2.mul (local.get $t) (v128.const f64x2 0.7071067811865476 0.7071067811865476))
      (f64x2.mul (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $t) (local.get $t)) (v128.const f64x2 -0.7071067811865476 -0.7071067811865476)) (v128.const f64x2 -1.0 1.0))))

    ;; k=3: W_16^3 = (0.3826834323650898, -0.9238795325112867)
    (local.set $a (v128.load (i32.add (local.get $base) (i32.const 48))))
    (local.set $b (v128.load (i32.add (local.get $off8) (i32.const 48))))
    (local.set $t (f64x2.sub (local.get $a) (local.get $b)))
    (v128.store (i32.add (local.get $base) (i32.const 48)) (f64x2.add (local.get $a) (local.get $b)))
    (v128.store (i32.add (local.get $off8) (i32.const 48)) (f64x2.add
      (f64x2.mul (local.get $t) (v128.const f64x2 0.3826834323650898 0.3826834323650898))
      (f64x2.mul (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $t) (local.get $t)) (v128.const f64x2 -0.9238795325112867 -0.9238795325112867)) (v128.const f64x2 -1.0 1.0))))

    ;; k=4: W_16^4 = (0, -1) = -j
    (local.set $a (v128.load (i32.add (local.get $base) (i32.const 64))))
    (local.set $b (v128.load (i32.add (local.get $off8) (i32.const 64))))
    (local.set $t (f64x2.sub (local.get $a) (local.get $b)))
    (v128.store (i32.add (local.get $base) (i32.const 64)) (f64x2.add (local.get $a) (local.get $b)))
    (v128.store (i32.add (local.get $off8) (i32.const 64)) (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $t) (local.get $t)) (v128.const f64x2 1.0 -1.0)))

    ;; k=5: W_16^5 = (-0.3826834323650898, -0.9238795325112867)
    (local.set $a (v128.load (i32.add (local.get $base) (i32.const 80))))
    (local.set $b (v128.load (i32.add (local.get $off8) (i32.const 80))))
    (local.set $t (f64x2.sub (local.get $a) (local.get $b)))
    (v128.store (i32.add (local.get $base) (i32.const 80)) (f64x2.add (local.get $a) (local.get $b)))
    (v128.store (i32.add (local.get $off8) (i32.const 80)) (f64x2.add
      (f64x2.mul (local.get $t) (v128.const f64x2 -0.3826834323650898 -0.3826834323650898))
      (f64x2.mul (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $t) (local.get $t)) (v128.const f64x2 -0.9238795325112867 -0.9238795325112867)) (v128.const f64x2 -1.0 1.0))))

    ;; k=6: W_16^6 = (-0.7071067811865476, -0.7071067811865476)
    (local.set $a (v128.load (i32.add (local.get $base) (i32.const 96))))
    (local.set $b (v128.load (i32.add (local.get $off8) (i32.const 96))))
    (local.set $t (f64x2.sub (local.get $a) (local.get $b)))
    (v128.store (i32.add (local.get $base) (i32.const 96)) (f64x2.add (local.get $a) (local.get $b)))
    (v128.store (i32.add (local.get $off8) (i32.const 96)) (f64x2.add
      (f64x2.mul (local.get $t) (v128.const f64x2 -0.7071067811865476 -0.7071067811865476))
      (f64x2.mul (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $t) (local.get $t)) (v128.const f64x2 -0.7071067811865476 -0.7071067811865476)) (v128.const f64x2 -1.0 1.0))))

    ;; k=7: W_16^7 = (-0.9238795325112867, -0.3826834323650898)
    (local.set $a (v128.load (i32.add (local.get $base) (i32.const 112))))
    (local.set $b (v128.load (i32.add (local.get $off8) (i32.const 112))))
    (local.set $t (f64x2.sub (local.get $a) (local.get $b)))
    (v128.store (i32.add (local.get $base) (i32.const 112)) (f64x2.add (local.get $a) (local.get $b)))
    (v128.store (i32.add (local.get $off8) (i32.const 112)) (f64x2.add
      (f64x2.mul (local.get $t) (v128.const f64x2 -0.9238795325112867 -0.9238795325112867))
      (f64x2.mul (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $t) (local.get $t)) (v128.const f64x2 -0.3826834323650898 -0.3826834323650898)) (v128.const f64x2 -1.0 1.0))))

    ;; DIF Stage 2 & 3: Two FFT-8s on each half
    (call $fft_8_at (local.get $base))
    (call $fft_8_at (local.get $off8))
  )

  ;; ============================================================================
  ;; DIF pass: Apply butterflies with twiddles for size N at given base
  ;; Twiddles are fetched from table using stride (TOP_N / n)
  ;; ============================================================================
  (func $dif_pass (param $base i32) (param $n i32) (param $tw_stride i32)
    (local $half i32) (local $k i32)
    (local $addr_a i32) (local $addr_b i32) (local $tw_addr i32)
    (local $a v128) (local $b v128) (local $t v128) (local $tw v128) (local $prod v128)

    (local.set $half (i32.shr_u (local.get $n) (i32.const 1)))
    (local.set $addr_a (local.get $base))
    (local.set $addr_b (i32.add (local.get $base) (i32.shl (local.get $half) (i32.const 4))))
    (local.set $k (i32.const 0))

    (block $done (loop $loop
      (br_if $done (i32.ge_u (local.get $k) (local.get $half)))

      ;; Load data
      (local.set $a (v128.load (local.get $addr_a)))
      (local.set $b (v128.load (local.get $addr_b)))

      ;; First half: a + b
      (v128.store (local.get $addr_a) (f64x2.add (local.get $a) (local.get $b)))

      ;; Second half: (a - b) * W_n^k
      (local.set $t (f64x2.sub (local.get $a) (local.get $b)))

      ;; Load twiddle: index = k * stride
      (local.set $tw_addr (i32.add (global.get $TWIDDLE_OFFSET)
                                   (i32.shl (i32.mul (local.get $k) (local.get $tw_stride)) (i32.const 4))))
      (local.set $tw (v128.load (local.get $tw_addr)))

      ;; Complex multiply: t * tw (inlined SIMD)
      (local.set $prod
        (f64x2.add
          (f64x2.mul (local.get $t)
            (i8x16.shuffle 0 1 2 3 4 5 6 7 0 1 2 3 4 5 6 7 (local.get $tw) (local.get $tw)))
          (f64x2.mul
            (f64x2.mul
              (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $t) (local.get $t))
              (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $tw) (local.get $tw)))
            (v128.const f64x2 -1.0 1.0))))

      (v128.store (local.get $addr_b) (local.get $prod))

      (local.set $addr_a (i32.add (local.get $addr_a) (i32.const 16)))
      (local.set $addr_b (i32.add (local.get $addr_b) (i32.const 16)))
      (local.set $k (i32.add (local.get $k) (i32.const 1)))
      (br $loop)
    ))
  )

  ;; ============================================================================
  ;; Iterative DIF for small N (used as base case to reduce recursive calls)
  ;; Performs complete DIF FFT iteratively for N <= 64
  ;; ============================================================================
  (func $fft_dif_iterative (param $base i32) (param $n i32) (param $tw_stride i32)
    (local $half i32) (local $stage_size i32) (local $num_groups i32)
    (local $group i32) (local $k i32) (local $group_offset i32)
    (local $addr_a i32) (local $addr_b i32) (local $tw_addr i32) (local $local_stride i32)
    (local $a v128) (local $b v128) (local $t v128) (local $tw v128) (local $prod v128)

    (local.set $stage_size (local.get $n))
    (local.set $local_stride (local.get $tw_stride))

    ;; Iterate through stages (DIF: start with full size, halve each stage)
    (block $done_stages (loop $stage_loop
      (br_if $done_stages (i32.le_u (local.get $stage_size) (i32.const 1)))

      (local.set $half (i32.shr_u (local.get $stage_size) (i32.const 1)))
      (local.set $num_groups (i32.div_u (local.get $n) (local.get $stage_size)))
      (local.set $group (i32.const 0))

      ;; Process each group at this stage
      (block $done_groups (loop $group_loop
        (br_if $done_groups (i32.ge_u (local.get $group) (local.get $num_groups)))

        (local.set $group_offset (i32.add (local.get $base)
          (i32.shl (i32.mul (local.get $group) (local.get $stage_size)) (i32.const 4))))
        (local.set $k (i32.const 0))

        ;; Process butterflies within this group
        (block $done_k (loop $k_loop
          (br_if $done_k (i32.ge_u (local.get $k) (local.get $half)))

          (local.set $addr_a (i32.add (local.get $group_offset) (i32.shl (local.get $k) (i32.const 4))))
          (local.set $addr_b (i32.add (local.get $addr_a) (i32.shl (local.get $half) (i32.const 4))))

          (local.set $a (v128.load (local.get $addr_a)))
          (local.set $b (v128.load (local.get $addr_b)))

          ;; First half: a + b
          (v128.store (local.get $addr_a) (f64x2.add (local.get $a) (local.get $b)))

          ;; Second half: (a - b) * W
          (local.set $t (f64x2.sub (local.get $a) (local.get $b)))

          ;; Load twiddle
          (local.set $tw_addr (i32.add (global.get $TWIDDLE_OFFSET)
            (i32.shl (i32.mul (local.get $k) (local.get $local_stride)) (i32.const 4))))
          (local.set $tw (v128.load (local.get $tw_addr)))

          ;; Complex multiply
          (local.set $prod
            (f64x2.add
              (f64x2.mul (local.get $t)
                (i8x16.shuffle 0 1 2 3 4 5 6 7 0 1 2 3 4 5 6 7 (local.get $tw) (local.get $tw)))
              (f64x2.mul
                (f64x2.mul
                  (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $t) (local.get $t))
                  (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $tw) (local.get $tw)))
                (v128.const f64x2 -1.0 1.0))))

          (v128.store (local.get $addr_b) (local.get $prod))

          (local.set $k (i32.add (local.get $k) (i32.const 1)))
          (br $k_loop)
        ))

        (local.set $group (i32.add (local.get $group) (i32.const 1)))
        (br $group_loop)
      ))

      ;; Next stage: halve size, double stride
      (local.set $stage_size (local.get $half))
      (local.set $local_stride (i32.shl (local.get $local_stride) (i32.const 1)))
      (br $stage_loop)
    ))
  )

  ;; ============================================================================
  ;; Depth-First Recursive DIF FFT implementation
  ;; Parameters:
  ;;   base: start address of data
  ;;   n: current size
  ;;   tw_stride: twiddle stride (TOP_N / n)
  ;; ============================================================================
  (func $fft_dif_recursive (param $base i32) (param $n i32) (param $tw_stride i32)
    (local $half i32) (local $second_half i32)

    ;; Base cases using optimized codelets (hardcoded twiddles, no loops)
    (if (i32.eq (local.get $n) (i32.const 2))
      (then (call $fft_2_at (local.get $base)) (return)))
    (if (i32.eq (local.get $n) (i32.const 4))
      (then (call $fft_4_at (local.get $base)) (return)))
    (if (i32.eq (local.get $n) (i32.const 8))
      (then (call $fft_8_at (local.get $base)) (return)))
    (if (i32.eq (local.get $n) (i32.const 16))
      (then (call $fft_16_at (local.get $base)) (return)))

    ;; Recursive case: DIF decomposition
    ;; 1. Apply DIF butterflies (first pass)
    ;; 2. Recurse on first half (depth-first)
    ;; 3. Recurse on second half (depth-first)

    (local.set $half (i32.shr_u (local.get $n) (i32.const 1)))
    (local.set $second_half (i32.add (local.get $base) (i32.shl (local.get $half) (i32.const 4))))

    ;; DIF pass: butterflies with twiddles
    (call $dif_pass (local.get $base) (local.get $n) (local.get $tw_stride))

    ;; Recurse depth-first on first half, then second half
    ;; This keeps the working set hot in cache
    (call $fft_dif_recursive (local.get $base) (local.get $half) (i32.shl (local.get $tw_stride) (i32.const 1)))
    (call $fft_dif_recursive (local.get $second_half) (local.get $half) (i32.shl (local.get $tw_stride) (i32.const 1)))
  )

  ;; ============================================================================
  ;; Bit-reversal permutation
  ;; DIF produces output in bit-reversed order, so we need to reorder
  ;; ============================================================================
  (func $bit_reverse (param $x i32) (param $log2n i32) (result i32)
    (local $result i32) (local $i i32)
    (local.set $result (i32.const 0))
    (local.set $i (i32.const 0))
    (block $done (loop $loop
      (br_if $done (i32.ge_u (local.get $i) (local.get $log2n)))
      (local.set $result (i32.or
        (i32.shl (local.get $result) (i32.const 1))
        (i32.and (local.get $x) (i32.const 1))))
      (local.set $x (i32.shr_u (local.get $x) (i32.const 1)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $loop)
    ))
    (local.get $result)
  )

  ;; Count trailing zeros to compute log2
  (func $log2 (param $n i32) (result i32)
    (local $result i32)
    (local.set $result (i32.const 0))
    (block $done (loop $loop
      (br_if $done (i32.and (local.get $n) (i32.const 1)))
      (local.set $result (i32.add (local.get $result) (i32.const 1)))
      (local.set $n (i32.shr_u (local.get $n) (i32.const 1)))
      (br $loop)
    ))
    (local.get $result)
  )

  ;; Apply bit-reversal permutation to output (in-place)
  ;; Only swaps pairs where i < j to avoid double-swapping
  (func $bit_reversal_permutation (param $n i32)
    (local $log2n i32) (local $i i32) (local $j i32)
    (local $addr_i i32) (local $addr_j i32)
    (local $tmp v128)

    (local.set $log2n (call $log2 (local.get $n)))

    (local.set $i (i32.const 0))
    (block $done (loop $loop
      (br_if $done (i32.ge_u (local.get $i) (local.get $n)))
      (local.set $j (call $bit_reverse (local.get $i) (local.get $log2n)))

      ;; Only swap if i < j (avoids swapping twice or with self)
      (if (i32.lt_u (local.get $i) (local.get $j))
        (then
          (local.set $addr_i (i32.shl (local.get $i) (i32.const 4)))
          (local.set $addr_j (i32.shl (local.get $j) (i32.const 4)))
          ;; Swap data[i] and data[j]
          (local.set $tmp (v128.load (local.get $addr_i)))
          (v128.store (local.get $addr_i) (v128.load (local.get $addr_j)))
          (v128.store (local.get $addr_j) (local.get $tmp))
        )
      )

      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $loop)
    ))
  )

  ;; ============================================================================
  ;; Main entry point: Recursive FFT on data at address 0
  ;; ============================================================================
  (func $fft_recursive (export "fft_recursive") (param $n i32)
    ;; Store top-level N for twiddle calculations
    (global.set $TOP_N (local.get $n))

    ;; Start recursion with stride=1 (twiddles precomputed for full N)
    (call $fft_dif_recursive (i32.const 0) (local.get $n) (i32.const 1))

    ;; DIF produces bit-reversed output, apply permutation to get natural order
    (call $bit_reversal_permutation (local.get $n))
  )

  ;; ============================================================================
  ;; Standard FFT entry point (alias for compatibility)
  ;; ============================================================================
  (func (export "fft") (param $n i32)
    (call $fft_recursive (local.get $n))
  )
)
