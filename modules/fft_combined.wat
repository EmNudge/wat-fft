(module
  ;; Combined FFT - Radix-2 and Radix-4 with automatic dispatch
  ;;
  ;; Automatically selects the optimal algorithm:
  ;; - Radix-4 for power-of-4 sizes (4, 16, 64, 256, 1024, 4096) - fastest
  ;; - Radix-2 Stockham for other power-of-2 sizes (8, 32, 128, 512, 2048)
  ;;
  ;; Memory layout:
  ;;   0 - 65535: Primary data buffer
  ;;   65536 - 131071: Secondary buffer for ping-pong
  ;;   131072+: Twiddle factors

  (memory (export "memory") 4)

  (global $SECONDARY_OFFSET i32 (i32.const 65536))
  (global $TWIDDLE_OFFSET i32 (i32.const 131072))
  (global $PI f64 (f64.const 3.141592653589793))
  (global $HALF_PI f64 (f64.const 1.5707963267948966))

  ;; SIMD sign mask for complex multiply (from shared.wat)
  (global $SIGN_MASK v128 (v128.const i64x2 0x8000000000000000 0x0000000000000000))

  ;; ============================================================================
  ;; Utility: Check if N is a power of 4
  ;; ============================================================================
  ;; N is power-of-4 iff: N is power-of-2 AND the single set bit is at an even position
  ;; For power-of-2: (n & (n-1)) == 0
  ;; For even bit position: (n & 0xAAAAAAAA) == 0
  (func $is_power_of_4 (param $n i32) (result i32)
    (i32.and
      (i32.eqz (i32.and (local.get $n) (i32.sub (local.get $n) (i32.const 1))))
      (i32.eqz (i32.and (local.get $n) (i32.const 0xAAAAAAAA))))
  )

  ;; ============================================================================
  ;; Inline Trig Functions (Taylor Series)
  ;; ============================================================================
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

  ;; ============================================================================
  ;; Twiddle Precomputation
  ;; ============================================================================
  (func $precompute_twiddles (export "precompute_twiddles") (param $n i32)
    (local $k i32) (local $angle f64) (local $addr i32) (local $neg_two_pi_over_n f64)
    (if (i32.le_u (local.get $n) (i32.const 4)) (then (return)))
    (local.set $neg_two_pi_over_n
      (f64.div
        (f64.mul (f64.const -2.0) (global.get $PI))
        (f64.convert_i32_u (local.get $n))))
    (local.set $addr (global.get $TWIDDLE_OFFSET))
    (local.set $k (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $k) (local.get $n)))
        (local.set $angle
          (f64.mul (f64.convert_i32_u (local.get $k)) (local.get $neg_two_pi_over_n)))
        (f64.store (local.get $addr) (call $cos (local.get $angle)))
        (f64.store (i32.add (local.get $addr) (i32.const 8)) (call $sin (local.get $angle)))
        (local.set $addr (i32.add (local.get $addr) (i32.const 16)))
        (local.set $k (i32.add (local.get $k) (i32.const 1)))
        (br $loop)
      )
    )
  )

  ;; ============================================================================
  ;; SIMD Complex Multiply (for Stockham radix-2)
  ;; ============================================================================
  (func $simd_cmul (param $a v128) (param $b v128) (result v128)
    (local $ar v128) (local $ai v128) (local $bd v128)
    (local.set $ar (f64x2.splat (f64x2.extract_lane 0 (local.get $a))))
    (local.set $ai (f64x2.splat (f64x2.extract_lane 1 (local.get $a))))
    (local.set $bd (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7
                                  (local.get $b) (local.get $b)))
    (f64x2.add
      (f64x2.mul (local.get $ar) (local.get $b))
      (f64x2.mul (v128.xor (local.get $ai) (global.get $SIGN_MASK)) (local.get $bd)))
  )

  ;; ============================================================================
  ;; N=4 Kernel (shared by both radix-2 and radix-4)
  ;; ============================================================================
  (func $fft_4
    (local $x0 v128) (local $x1 v128) (local $x2 v128) (local $x3 v128)
    (local $t0 v128) (local $t1 v128) (local $t2 v128) (local $t3 v128)
    (local.set $x0 (v128.load (i32.const 0)))
    (local.set $x1 (v128.load (i32.const 16)))
    (local.set $x2 (v128.load (i32.const 32)))
    (local.set $x3 (v128.load (i32.const 48)))
    (local.set $t0 (f64x2.add (local.get $x0) (local.get $x2)))
    (local.set $t1 (f64x2.sub (local.get $x0) (local.get $x2)))
    (local.set $t2 (f64x2.add (local.get $x1) (local.get $x3)))
    (local.set $t3 (f64x2.sub (local.get $x1) (local.get $x3)))
    (local.set $t3
      (f64x2.mul
        (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $t3) (local.get $t3))
        (v128.const f64x2 1.0 -1.0)))
    (v128.store (i32.const 0) (f64x2.add (local.get $t0) (local.get $t2)))
    (v128.store (i32.const 16) (f64x2.add (local.get $t1) (local.get $t3)))
    (v128.store (i32.const 32) (f64x2.sub (local.get $t0) (local.get $t2)))
    (v128.store (i32.const 48) (f64x2.sub (local.get $t1) (local.get $t3)))
  )

  ;; ============================================================================
  ;; Radix-4: N=16 Fully Unrolled Codelet
  ;; ============================================================================
  (func $fft_16
    (local $x0 v128) (local $x1 v128) (local $x2 v128) (local $x3 v128)
    (local $x4 v128) (local $x5 v128) (local $x6 v128) (local $x7 v128)
    (local $x8 v128) (local $x9 v128) (local $x10 v128) (local $x11 v128)
    (local $x12 v128) (local $x13 v128) (local $x14 v128) (local $x15 v128)
    (local $t0 v128) (local $t1 v128) (local $t2 v128) (local $t3 v128)
    (local $s0 v128) (local $s1 v128) (local $s2 v128) (local $s3 v128)
    (local $tmp v128)

    ;; Load all 16 inputs
    (local.set $x0 (v128.load (i32.const 0)))
    (local.set $x1 (v128.load (i32.const 16)))
    (local.set $x2 (v128.load (i32.const 32)))
    (local.set $x3 (v128.load (i32.const 48)))
    (local.set $x4 (v128.load (i32.const 64)))
    (local.set $x5 (v128.load (i32.const 80)))
    (local.set $x6 (v128.load (i32.const 96)))
    (local.set $x7 (v128.load (i32.const 112)))
    (local.set $x8 (v128.load (i32.const 128)))
    (local.set $x9 (v128.load (i32.const 144)))
    (local.set $x10 (v128.load (i32.const 160)))
    (local.set $x11 (v128.load (i32.const 176)))
    (local.set $x12 (v128.load (i32.const 192)))
    (local.set $x13 (v128.load (i32.const 208)))
    (local.set $x14 (v128.load (i32.const 224)))
    (local.set $x15 (v128.load (i32.const 240)))

    ;; Stage 1: Four radix-4 butterflies
    ;; Group 0: x0, x4, x8, x12
    (local.set $t0 (f64x2.add (local.get $x0) (local.get $x8)))
    (local.set $t1 (f64x2.sub (local.get $x0) (local.get $x8)))
    (local.set $t2 (f64x2.add (local.get $x4) (local.get $x12)))
    (local.set $t3 (f64x2.sub (local.get $x4) (local.get $x12)))
    (local.set $t3 (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $t3) (local.get $t3)) (v128.const f64x2 1.0 -1.0)))
    (local.set $x0 (f64x2.add (local.get $t0) (local.get $t2)))
    (local.set $x4 (f64x2.add (local.get $t1) (local.get $t3)))
    (local.set $x8 (f64x2.sub (local.get $t0) (local.get $t2)))
    (local.set $x12 (f64x2.sub (local.get $t1) (local.get $t3)))

    ;; Group 1: x1, x5, x9, x13
    (local.set $t0 (f64x2.add (local.get $x1) (local.get $x9)))
    (local.set $t1 (f64x2.sub (local.get $x1) (local.get $x9)))
    (local.set $t2 (f64x2.add (local.get $x5) (local.get $x13)))
    (local.set $t3 (f64x2.sub (local.get $x5) (local.get $x13)))
    (local.set $t3 (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $t3) (local.get $t3)) (v128.const f64x2 1.0 -1.0)))
    (local.set $x1 (f64x2.add (local.get $t0) (local.get $t2)))
    (local.set $x5 (f64x2.add (local.get $t1) (local.get $t3)))
    (local.set $x9 (f64x2.sub (local.get $t0) (local.get $t2)))
    (local.set $x13 (f64x2.sub (local.get $t1) (local.get $t3)))

    ;; Group 2: x2, x6, x10, x14
    (local.set $t0 (f64x2.add (local.get $x2) (local.get $x10)))
    (local.set $t1 (f64x2.sub (local.get $x2) (local.get $x10)))
    (local.set $t2 (f64x2.add (local.get $x6) (local.get $x14)))
    (local.set $t3 (f64x2.sub (local.get $x6) (local.get $x14)))
    (local.set $t3 (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $t3) (local.get $t3)) (v128.const f64x2 1.0 -1.0)))
    (local.set $x2 (f64x2.add (local.get $t0) (local.get $t2)))
    (local.set $x6 (f64x2.add (local.get $t1) (local.get $t3)))
    (local.set $x10 (f64x2.sub (local.get $t0) (local.get $t2)))
    (local.set $x14 (f64x2.sub (local.get $t1) (local.get $t3)))

    ;; Group 3: x3, x7, x11, x15
    (local.set $t0 (f64x2.add (local.get $x3) (local.get $x11)))
    (local.set $t1 (f64x2.sub (local.get $x3) (local.get $x11)))
    (local.set $t2 (f64x2.add (local.get $x7) (local.get $x15)))
    (local.set $t3 (f64x2.sub (local.get $x7) (local.get $x15)))
    (local.set $t3 (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $t3) (local.get $t3)) (v128.const f64x2 1.0 -1.0)))
    (local.set $x3 (f64x2.add (local.get $t0) (local.get $t2)))
    (local.set $x7 (f64x2.add (local.get $t1) (local.get $t3)))
    (local.set $x11 (f64x2.sub (local.get $t0) (local.get $t2)))
    (local.set $x15 (f64x2.sub (local.get $t1) (local.get $t3)))

    ;; Stage 2: Four radix-4 butterflies with twiddles
    ;; Group 0: x0, x1, x2, x3 - no twiddles
    (local.set $t0 (f64x2.add (local.get $x0) (local.get $x2)))
    (local.set $t1 (f64x2.sub (local.get $x0) (local.get $x2)))
    (local.set $t2 (f64x2.add (local.get $x1) (local.get $x3)))
    (local.set $t3 (f64x2.sub (local.get $x1) (local.get $x3)))
    (local.set $t3 (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $t3) (local.get $t3)) (v128.const f64x2 1.0 -1.0)))
    (v128.store (i32.const 0) (f64x2.add (local.get $t0) (local.get $t2)))
    (v128.store (i32.const 64) (f64x2.add (local.get $t1) (local.get $t3)))
    (v128.store (i32.const 128) (f64x2.sub (local.get $t0) (local.get $t2)))
    (v128.store (i32.const 192) (f64x2.sub (local.get $t1) (local.get $t3)))

    ;; Group 1: x4, x5, x6, x7 - apply W_16^1, W_16^2, W_16^3
    (local.set $tmp (local.get $x5))
    (local.set $x5
      (f64x2.add
        (f64x2.mul (local.get $tmp) (v128.const f64x2 0.9238795325112867 0.9238795325112867))
        (f64x2.mul
          (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $tmp) (local.get $tmp))
                     (v128.const f64x2 -0.3826834323650898 -0.3826834323650898))
          (v128.const f64x2 -1.0 1.0))))
    (local.set $tmp (local.get $x6))
    (local.set $x6
      (f64x2.add
        (f64x2.mul (local.get $tmp) (v128.const f64x2 0.7071067811865476 0.7071067811865476))
        (f64x2.mul
          (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $tmp) (local.get $tmp))
                     (v128.const f64x2 -0.7071067811865476 -0.7071067811865476))
          (v128.const f64x2 -1.0 1.0))))
    (local.set $tmp (local.get $x7))
    (local.set $x7
      (f64x2.add
        (f64x2.mul (local.get $tmp) (v128.const f64x2 0.3826834323650898 0.3826834323650898))
        (f64x2.mul
          (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $tmp) (local.get $tmp))
                     (v128.const f64x2 -0.9238795325112867 -0.9238795325112867))
          (v128.const f64x2 -1.0 1.0))))
    (local.set $t0 (f64x2.add (local.get $x4) (local.get $x6)))
    (local.set $t1 (f64x2.sub (local.get $x4) (local.get $x6)))
    (local.set $t2 (f64x2.add (local.get $x5) (local.get $x7)))
    (local.set $t3 (f64x2.sub (local.get $x5) (local.get $x7)))
    (local.set $t3 (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $t3) (local.get $t3)) (v128.const f64x2 1.0 -1.0)))
    (v128.store (i32.const 16) (f64x2.add (local.get $t0) (local.get $t2)))
    (v128.store (i32.const 80) (f64x2.add (local.get $t1) (local.get $t3)))
    (v128.store (i32.const 144) (f64x2.sub (local.get $t0) (local.get $t2)))
    (v128.store (i32.const 208) (f64x2.sub (local.get $t1) (local.get $t3)))

    ;; Group 2: x8, x9, x10, x11 - apply W_16^2, W_16^4=-j, W_16^6
    (local.set $tmp (local.get $x9))
    (local.set $x9
      (f64x2.add
        (f64x2.mul (local.get $tmp) (v128.const f64x2 0.7071067811865476 0.7071067811865476))
        (f64x2.mul
          (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $tmp) (local.get $tmp))
                     (v128.const f64x2 -0.7071067811865476 -0.7071067811865476))
          (v128.const f64x2 -1.0 1.0))))
    (local.set $x10 (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $x10) (local.get $x10)) (v128.const f64x2 1.0 -1.0)))
    (local.set $tmp (local.get $x11))
    (local.set $x11
      (f64x2.add
        (f64x2.mul (local.get $tmp) (v128.const f64x2 -0.7071067811865476 -0.7071067811865476))
        (f64x2.mul
          (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $tmp) (local.get $tmp))
                     (v128.const f64x2 -0.7071067811865476 -0.7071067811865476))
          (v128.const f64x2 -1.0 1.0))))
    (local.set $t0 (f64x2.add (local.get $x8) (local.get $x10)))
    (local.set $t1 (f64x2.sub (local.get $x8) (local.get $x10)))
    (local.set $t2 (f64x2.add (local.get $x9) (local.get $x11)))
    (local.set $t3 (f64x2.sub (local.get $x9) (local.get $x11)))
    (local.set $t3 (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $t3) (local.get $t3)) (v128.const f64x2 1.0 -1.0)))
    (v128.store (i32.const 32) (f64x2.add (local.get $t0) (local.get $t2)))
    (v128.store (i32.const 96) (f64x2.add (local.get $t1) (local.get $t3)))
    (v128.store (i32.const 160) (f64x2.sub (local.get $t0) (local.get $t2)))
    (v128.store (i32.const 224) (f64x2.sub (local.get $t1) (local.get $t3)))

    ;; Group 3: x12, x13, x14, x15 - apply W_16^3, W_16^6, W_16^9
    (local.set $tmp (local.get $x13))
    (local.set $x13
      (f64x2.add
        (f64x2.mul (local.get $tmp) (v128.const f64x2 0.3826834323650898 0.3826834323650898))
        (f64x2.mul
          (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $tmp) (local.get $tmp))
                     (v128.const f64x2 -0.9238795325112867 -0.9238795325112867))
          (v128.const f64x2 -1.0 1.0))))
    (local.set $tmp (local.get $x14))
    (local.set $x14
      (f64x2.add
        (f64x2.mul (local.get $tmp) (v128.const f64x2 -0.7071067811865476 -0.7071067811865476))
        (f64x2.mul
          (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $tmp) (local.get $tmp))
                     (v128.const f64x2 -0.7071067811865476 -0.7071067811865476))
          (v128.const f64x2 -1.0 1.0))))
    (local.set $tmp (local.get $x15))
    (local.set $x15
      (f64x2.add
        (f64x2.mul (local.get $tmp) (v128.const f64x2 -0.9238795325112867 -0.9238795325112867))
        (f64x2.mul
          (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $tmp) (local.get $tmp))
                     (v128.const f64x2 0.3826834323650898 0.3826834323650898))
          (v128.const f64x2 -1.0 1.0))))
    (local.set $t0 (f64x2.add (local.get $x12) (local.get $x14)))
    (local.set $t1 (f64x2.sub (local.get $x12) (local.get $x14)))
    (local.set $t2 (f64x2.add (local.get $x13) (local.get $x15)))
    (local.set $t3 (f64x2.sub (local.get $x13) (local.get $x15)))
    (local.set $t3 (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $t3) (local.get $t3)) (v128.const f64x2 1.0 -1.0)))
    (v128.store (i32.const 48) (f64x2.add (local.get $t0) (local.get $t2)))
    (v128.store (i32.const 112) (f64x2.add (local.get $t1) (local.get $t3)))
    (v128.store (i32.const 176) (f64x2.sub (local.get $t0) (local.get $t2)))
    (v128.store (i32.const 240) (f64x2.sub (local.get $t1) (local.get $t3)))
  )

  ;; ============================================================================
  ;; Radix-4: General FFT for N >= 64 (power-of-4)
  ;; ============================================================================
  (func $fft_radix4_general (param $n i32)
    (local $n4 i32) (local $r i32) (local $l i32) (local $j i32) (local $k i32)
    (local $src i32) (local $dst i32) (local $tw_step i32)
    (local $i0 i32) (local $i1 i32) (local $i2 i32) (local $i3 i32)
    (local $o0 i32) (local $o1 i32) (local $o2 i32) (local $o3 i32)
    (local $w1 v128) (local $w2 v128) (local $w3 v128)
    (local $tw_idx i32) (local $tw_addr i32)
    (local $a v128) (local $b v128) (local $c v128) (local $d v128)
    (local $b1 v128) (local $c1 v128) (local $d1 v128)
    (local $t0 v128) (local $t1 v128) (local $t2 v128) (local $t3 v128)
    (local $r_bytes i32) (local $n4_bytes i32)

    (local.set $n4 (i32.shr_u (local.get $n) (i32.const 2)))
    (local.set $n4_bytes (i32.shl (local.get $n4) (i32.const 4)))
    (local.set $src (i32.const 0))
    (local.set $dst (global.get $SECONDARY_OFFSET))
    (local.set $r (local.get $n4))
    (local.set $l (i32.const 1))

    (block $done_stages
      (loop $stage_loop
        (br_if $done_stages (i32.lt_u (local.get $r) (i32.const 1)))
        (local.set $r_bytes (i32.shl (local.get $r) (i32.const 4)))
        (local.set $tw_step (i32.div_u (local.get $n) (i32.shl (local.get $l) (i32.const 2))))
        (local.set $j (i32.const 0))
        (local.set $o0 (local.get $dst))
        (local.set $o1 (i32.add (local.get $dst) (local.get $n4_bytes)))
        (local.set $o2 (i32.add (local.get $o1) (local.get $n4_bytes)))
        (local.set $o3 (i32.add (local.get $o2) (local.get $n4_bytes)))
        (local.set $i0 (local.get $src))

        (block $done_groups
          (loop $group_loop
            (br_if $done_groups (i32.ge_u (local.get $j) (local.get $l)))
            (local.set $tw_idx (i32.mul (local.get $j) (local.get $tw_step)))
            (local.set $tw_addr (i32.add (global.get $TWIDDLE_OFFSET) (i32.shl (local.get $tw_idx) (i32.const 4))))
            (local.set $w1 (v128.load (local.get $tw_addr)))
            (local.set $tw_addr (i32.add (global.get $TWIDDLE_OFFSET) (i32.shl (i32.mul (local.get $tw_idx) (i32.const 2)) (i32.const 4))))
            (if (i32.ge_u (i32.mul (local.get $tw_idx) (i32.const 2)) (local.get $n))
              (then (local.set $tw_addr (i32.add (global.get $TWIDDLE_OFFSET) (i32.shl (i32.sub (i32.mul (local.get $tw_idx) (i32.const 2)) (local.get $n)) (i32.const 4))))))
            (local.set $w2 (v128.load (local.get $tw_addr)))
            (local.set $tw_addr (i32.add (global.get $TWIDDLE_OFFSET) (i32.shl (i32.mul (local.get $tw_idx) (i32.const 3)) (i32.const 4))))
            (if (i32.ge_u (i32.mul (local.get $tw_idx) (i32.const 3)) (local.get $n))
              (then (local.set $tw_addr (i32.add (global.get $TWIDDLE_OFFSET) (i32.shl (i32.rem_u (i32.mul (local.get $tw_idx) (i32.const 3)) (local.get $n)) (i32.const 4))))))
            (local.set $w3 (v128.load (local.get $tw_addr)))
            (local.set $i1 (i32.add (local.get $i0) (local.get $r_bytes)))
            (local.set $i2 (i32.add (local.get $i1) (local.get $r_bytes)))
            (local.set $i3 (i32.add (local.get $i2) (local.get $r_bytes)))
            (local.set $k (i32.const 0))

            (block $done_butterflies
              (loop $butterfly_loop
                (br_if $done_butterflies (i32.ge_u (local.get $k) (local.get $r)))
                (local.set $a (v128.load (local.get $i0)))
                (local.set $b (v128.load (local.get $i1)))
                (local.set $c (v128.load (local.get $i2)))
                (local.set $d (v128.load (local.get $i3)))
                ;; Inline twiddle multiply
                (local.set $b1 (f64x2.add (f64x2.mul (local.get $b) (i8x16.shuffle 0 1 2 3 4 5 6 7 0 1 2 3 4 5 6 7 (local.get $w1) (local.get $w1))) (f64x2.mul (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b)) (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $w1) (local.get $w1))) (v128.const f64x2 -1.0 1.0))))
                (local.set $c1 (f64x2.add (f64x2.mul (local.get $c) (i8x16.shuffle 0 1 2 3 4 5 6 7 0 1 2 3 4 5 6 7 (local.get $w2) (local.get $w2))) (f64x2.mul (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $c) (local.get $c)) (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $w2) (local.get $w2))) (v128.const f64x2 -1.0 1.0))))
                (local.set $d1 (f64x2.add (f64x2.mul (local.get $d) (i8x16.shuffle 0 1 2 3 4 5 6 7 0 1 2 3 4 5 6 7 (local.get $w3) (local.get $w3))) (f64x2.mul (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d) (local.get $d)) (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $w3) (local.get $w3))) (v128.const f64x2 -1.0 1.0))))
                ;; Butterfly
                (local.set $t0 (f64x2.add (local.get $a) (local.get $c1)))
                (local.set $t1 (f64x2.sub (local.get $a) (local.get $c1)))
                (local.set $t2 (f64x2.add (local.get $b1) (local.get $d1)))
                (local.set $t3 (f64x2.sub (local.get $b1) (local.get $d1)))
                (v128.store (local.get $o0) (f64x2.add (local.get $t0) (local.get $t2)))
                (v128.store (local.get $o1) (f64x2.add (local.get $t1) (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $t3) (local.get $t3)) (v128.const f64x2 1.0 -1.0))))
                (v128.store (local.get $o2) (f64x2.sub (local.get $t0) (local.get $t2)))
                (v128.store (local.get $o3) (f64x2.add (local.get $t1) (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $t3) (local.get $t3)) (v128.const f64x2 -1.0 1.0))))
                (local.set $i0 (i32.add (local.get $i0) (i32.const 16)))
                (local.set $i1 (i32.add (local.get $i1) (i32.const 16)))
                (local.set $i2 (i32.add (local.get $i2) (i32.const 16)))
                (local.set $i3 (i32.add (local.get $i3) (i32.const 16)))
                (local.set $o0 (i32.add (local.get $o0) (i32.const 16)))
                (local.set $o1 (i32.add (local.get $o1) (i32.const 16)))
                (local.set $o2 (i32.add (local.get $o2) (i32.const 16)))
                (local.set $o3 (i32.add (local.get $o3) (i32.const 16)))
                (local.set $k (i32.add (local.get $k) (i32.const 1)))
                (br $butterfly_loop)
              )
            )
            (local.set $i0 (i32.add (local.get $i0) (i32.mul (local.get $r_bytes) (i32.const 3))))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $group_loop)
          )
        )
        (if (i32.eq (local.get $src) (i32.const 0))
          (then (local.set $src (global.get $SECONDARY_OFFSET)) (local.set $dst (i32.const 0)))
          (else (local.set $src (i32.const 0)) (local.set $dst (global.get $SECONDARY_OFFSET))))
        (local.set $r (i32.shr_u (local.get $r) (i32.const 2)))
        (local.set $l (i32.shl (local.get $l) (i32.const 2)))
        (br $stage_loop)
      )
    )
    ;; Copy back if needed
    (if (i32.ne (local.get $src) (i32.const 0))
      (then
        (local.set $i0 (global.get $SECONDARY_OFFSET))
        (local.set $o0 (i32.const 0))
        (local.set $k (i32.const 0))
        (block $done_copy
          (loop $copy_loop
            (br_if $done_copy (i32.ge_u (local.get $k) (local.get $n)))
            (v128.store (local.get $o0) (v128.load (local.get $i0)))
            (local.set $i0 (i32.add (local.get $i0) (i32.const 16)))
            (local.set $o0 (i32.add (local.get $o0) (i32.const 16)))
            (local.set $k (i32.add (local.get $k) (i32.const 1)))
            (br $copy_loop)
          )
        )
      )
    )
  )

  ;; Internal radix-4 entry point
  (func $fft_radix4 (param $n i32)
    (if (i32.eq (local.get $n) (i32.const 4)) (then (call $fft_4) (return)))
    (if (i32.eq (local.get $n) (i32.const 16)) (then (call $fft_16) (return)))
    (call $fft_radix4_general (local.get $n))
  )

  ;; ============================================================================
  ;; Radix-2 Stockham: General FFT for N > 4
  ;; ============================================================================
  (func $fft_stockham_general (param $n i32)
    (local $n2 i32) (local $r i32) (local $l i32) (local $j i32) (local $k i32)
    (local $src i32) (local $dst i32) (local $tw_step i32)
    (local $x0 v128) (local $x1 v128) (local $w v128)
    (local $i0 i32) (local $i1 i32) (local $o0 i32) (local $o1 i32)
    (local $r_bytes i32) (local $n2_bytes i32) (local $tw_addr i32)

    (local.set $n2 (i32.shr_u (local.get $n) (i32.const 1)))
    (local.set $n2_bytes (i32.shl (local.get $n2) (i32.const 4)))
    (local.set $src (i32.const 0))
    (local.set $dst (global.get $SECONDARY_OFFSET))
    (local.set $r (local.get $n2))
    (local.set $l (i32.const 1))

    (block $done_stages
      (loop $stage_loop
        (br_if $done_stages (i32.lt_u (local.get $r) (i32.const 1)))
        (local.set $r_bytes (i32.shl (local.get $r) (i32.const 4)))
        (local.set $tw_step (i32.div_u (local.get $n) (i32.shl (local.get $l) (i32.const 1))))
        (local.set $tw_addr (global.get $TWIDDLE_OFFSET))
        (local.set $j (i32.const 0))
        (local.set $o0 (local.get $dst))
        (local.set $o1 (i32.add (local.get $dst) (local.get $n2_bytes)))
        (local.set $i0 (local.get $src))

        (block $done_groups
          (loop $group_loop
            (br_if $done_groups (i32.ge_u (local.get $j) (local.get $l)))
            (local.set $w (v128.load (local.get $tw_addr)))
            (local.set $i1 (i32.add (local.get $i0) (local.get $r_bytes)))
            (local.set $k (i32.const 0))

            (block $done_butterflies
              (loop $butterfly_loop
                (br_if $done_butterflies (i32.ge_u (local.get $k) (local.get $r)))
                (local.set $x0 (v128.load (local.get $i0)))
                (local.set $x1 (v128.load (local.get $i1)))
                (local.set $x1 (call $simd_cmul (local.get $x1) (local.get $w)))
                (v128.store (local.get $o0) (f64x2.add (local.get $x0) (local.get $x1)))
                (v128.store (local.get $o1) (f64x2.sub (local.get $x0) (local.get $x1)))
                (local.set $i0 (i32.add (local.get $i0) (i32.const 16)))
                (local.set $i1 (i32.add (local.get $i1) (i32.const 16)))
                (local.set $o0 (i32.add (local.get $o0) (i32.const 16)))
                (local.set $o1 (i32.add (local.get $o1) (i32.const 16)))
                (local.set $k (i32.add (local.get $k) (i32.const 1)))
                (br $butterfly_loop)
              )
            )
            (local.set $i0 (i32.add (local.get $i0) (local.get $r_bytes)))
            (local.set $tw_addr (i32.add (local.get $tw_addr) (i32.shl (local.get $tw_step) (i32.const 4))))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $group_loop)
          )
        )
        (if (i32.eq (local.get $src) (i32.const 0))
          (then (local.set $src (global.get $SECONDARY_OFFSET)) (local.set $dst (i32.const 0)))
          (else (local.set $src (i32.const 0)) (local.set $dst (global.get $SECONDARY_OFFSET))))
        (local.set $r (i32.shr_u (local.get $r) (i32.const 1)))
        (local.set $l (i32.shl (local.get $l) (i32.const 1)))
        (br $stage_loop)
      )
    )
    ;; Copy back if needed
    (if (i32.ne (local.get $src) (i32.const 0))
      (then
        (local.set $i0 (global.get $SECONDARY_OFFSET))
        (local.set $o0 (i32.const 0))
        (local.set $k (i32.const 0))
        (block $done_copy
          (loop $copy_loop
            (br_if $done_copy (i32.ge_u (local.get $k) (local.get $n)))
            (v128.store (local.get $o0) (v128.load (local.get $i0)))
            (local.set $i0 (i32.add (local.get $i0) (i32.const 16)))
            (local.set $o0 (i32.add (local.get $o0) (i32.const 16)))
            (local.set $k (i32.add (local.get $k) (i32.const 1)))
            (br $copy_loop)
          )
        )
      )
    )
  )

  ;; Internal radix-2 Stockham entry point
  (func $fft_stockham (param $n i32)
    (if (i32.eq (local.get $n) (i32.const 4)) (then (call $fft_4) (return)))
    (call $fft_stockham_general (local.get $n))
  )

  ;; ============================================================================
  ;; Main Entry Point: Automatic Algorithm Selection
  ;; ============================================================================
  (func $fft (export "fft") (param $n i32)
    (if (call $is_power_of_4 (local.get $n))
      (then (call $fft_radix4 (local.get $n)))
      (else (call $fft_stockham (local.get $n)))
    )
  )
)
