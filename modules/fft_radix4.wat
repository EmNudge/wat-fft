(module
  ;; Radix-4 Stockham FFT
  ;;
  ;; For power-of-4 sizes (4, 16, 64, 256, 1024, 4096), radix-4 has:
  ;; - 50% fewer stages than radix-2 (log4(N) vs log2(N))
  ;; - Trivial twiddles within butterfly: W_4^0=1, W_4^1=-j, W_4^2=-1, W_4^3=j
  ;; - Only inter-group twiddles need computation
  ;;
  ;; Memory layout (same as stockham):
  ;;   0 - 65535: Primary data buffer
  ;;   65536 - 131071: Secondary buffer for ping-pong
  ;;   131072+: Twiddle factors

  (memory (export "memory") 4)

  (global $SECONDARY_OFFSET i32 (i32.const 65536))
  (global $TWIDDLE_OFFSET i32 (i32.const 131072))
  (global $PI f64 (f64.const 3.141592653589793))
  (global $HALF_PI f64 (f64.const 1.5707963267948966))

  ;; Inline sin/cos (same as stockham)
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

  ;; Precompute twiddles for radix-4 FFT
  ;; We need W_N^k for k = 0 to N-1
  (func $precompute_twiddles (export "precompute_twiddles") (param $n i32)
    (local $k i32)
    (local $angle f64)
    (local $addr i32)
    (local $neg_two_pi_over_n f64)

    (if (i32.le_u (local.get $n) (i32.const 4))
      (then (return)))

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

  ;; N=4 kernel (same as stockham)
  (func $fft_4
    (local $x0 v128) (local $x1 v128) (local $x2 v128) (local $x3 v128)
    (local $t0 v128) (local $t1 v128) (local $t2 v128) (local $t3 v128)

    (local.set $x0 (v128.load (i32.const 0)))
    (local.set $x1 (v128.load (i32.const 16)))
    (local.set $x2 (v128.load (i32.const 32)))
    (local.set $x3 (v128.load (i32.const 48)))

    ;; Radix-4 butterfly: no twiddles needed for N=4
    ;; t0 = x0 + x2, t1 = x0 - x2
    ;; t2 = x1 + x3, t3 = x1 - x3
    (local.set $t0 (f64x2.add (local.get $x0) (local.get $x2)))
    (local.set $t1 (f64x2.sub (local.get $x0) (local.get $x2)))
    (local.set $t2 (f64x2.add (local.get $x1) (local.get $x3)))
    (local.set $t3 (f64x2.sub (local.get $x1) (local.get $x3)))

    ;; Apply -j to t3: (a,b) -> (b,-a)
    (local.set $t3
      (f64x2.mul
        (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $t3) (local.get $t3))
        (v128.const f64x2 1.0 -1.0)))

    ;; Output: X0=t0+t2, X1=t1+t3, X2=t0-t2, X3=t1-t3
    (v128.store (i32.const 0) (f64x2.add (local.get $t0) (local.get $t2)))
    (v128.store (i32.const 16) (f64x2.add (local.get $t1) (local.get $t3)))
    (v128.store (i32.const 32) (f64x2.sub (local.get $t0) (local.get $t2)))
    (v128.store (i32.const 48) (f64x2.sub (local.get $t1) (local.get $t3)))
  )

  ;; N=16 fully unrolled codelet with inline twiddles
  ;; Two radix-4 stages, fully unrolled for maximum performance
  ;; Twiddles: W_16^k for k=0,1,2,3
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

    ;; Stage 1: Four radix-4 butterflies on groups [0,4,8,12], [1,5,9,13], [2,6,10,14], [3,7,11,15]
    ;; No twiddles needed within first stage

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
    ;; Twiddles: W_16^0 = 1, W_16^1 = 0.9239 - 0.3827i, W_16^2 = 0.7071 - 0.7071i, W_16^3 = 0.3827 - 0.9239i

    ;; Group 0: x0, x1, x2, x3 - twiddles are all W^0 = 1, so no multiply needed
    (local.set $t0 (f64x2.add (local.get $x0) (local.get $x2)))
    (local.set $t1 (f64x2.sub (local.get $x0) (local.get $x2)))
    (local.set $t2 (f64x2.add (local.get $x1) (local.get $x3)))
    (local.set $t3 (f64x2.sub (local.get $x1) (local.get $x3)))
    (local.set $t3 (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $t3) (local.get $t3)) (v128.const f64x2 1.0 -1.0)))
    (local.set $s0 (f64x2.add (local.get $t0) (local.get $t2)))
    (local.set $s1 (f64x2.add (local.get $t1) (local.get $t3)))
    (local.set $s2 (f64x2.sub (local.get $t0) (local.get $t2)))
    (local.set $s3 (f64x2.sub (local.get $t1) (local.get $t3)))
    (v128.store (i32.const 0) (local.get $s0))
    (v128.store (i32.const 64) (local.get $s1))
    (v128.store (i32.const 128) (local.get $s2))
    (v128.store (i32.const 192) (local.get $s3))

    ;; Group 1: x4, x5, x6, x7 - apply W_16^1, W_16^2, W_16^3
    ;; x5 *= W_16^1 = (0.9238795325112867, -0.3826834323650898)
    (local.set $tmp (local.get $x5))
    (local.set $x5
      (f64x2.add
        (f64x2.mul (local.get $tmp) (v128.const f64x2 0.9238795325112867 0.9238795325112867))
        (f64x2.mul
          (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $tmp) (local.get $tmp))
                     (v128.const f64x2 -0.3826834323650898 -0.3826834323650898))
          (v128.const f64x2 -1.0 1.0))))
    ;; x6 *= W_16^2 = (0.7071067811865476, -0.7071067811865476)
    (local.set $tmp (local.get $x6))
    (local.set $x6
      (f64x2.add
        (f64x2.mul (local.get $tmp) (v128.const f64x2 0.7071067811865476 0.7071067811865476))
        (f64x2.mul
          (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $tmp) (local.get $tmp))
                     (v128.const f64x2 -0.7071067811865476 -0.7071067811865476))
          (v128.const f64x2 -1.0 1.0))))
    ;; x7 *= W_16^3 = (0.3826834323650898, -0.9238795325112867)
    (local.set $tmp (local.get $x7))
    (local.set $x7
      (f64x2.add
        (f64x2.mul (local.get $tmp) (v128.const f64x2 0.3826834323650898 0.3826834323650898))
        (f64x2.mul
          (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $tmp) (local.get $tmp))
                     (v128.const f64x2 -0.9238795325112867 -0.9238795325112867))
          (v128.const f64x2 -1.0 1.0))))
    ;; Butterfly
    (local.set $t0 (f64x2.add (local.get $x4) (local.get $x6)))
    (local.set $t1 (f64x2.sub (local.get $x4) (local.get $x6)))
    (local.set $t2 (f64x2.add (local.get $x5) (local.get $x7)))
    (local.set $t3 (f64x2.sub (local.get $x5) (local.get $x7)))
    (local.set $t3 (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $t3) (local.get $t3)) (v128.const f64x2 1.0 -1.0)))
    (v128.store (i32.const 16) (f64x2.add (local.get $t0) (local.get $t2)))
    (v128.store (i32.const 80) (f64x2.add (local.get $t1) (local.get $t3)))
    (v128.store (i32.const 144) (f64x2.sub (local.get $t0) (local.get $t2)))
    (v128.store (i32.const 208) (f64x2.sub (local.get $t1) (local.get $t3)))

    ;; Group 2: x8, x9, x10, x11 - apply W_16^2, W_16^4=-j, W_16^6=-W_16^2
    ;; x9 *= W_16^2 = (0.7071067811865476, -0.7071067811865476)
    (local.set $tmp (local.get $x9))
    (local.set $x9
      (f64x2.add
        (f64x2.mul (local.get $tmp) (v128.const f64x2 0.7071067811865476 0.7071067811865476))
        (f64x2.mul
          (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $tmp) (local.get $tmp))
                     (v128.const f64x2 -0.7071067811865476 -0.7071067811865476))
          (v128.const f64x2 -1.0 1.0))))
    ;; x10 *= W_16^4 = -j = (0, -1) -> (im, -re)
    (local.set $x10 (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $x10) (local.get $x10)) (v128.const f64x2 1.0 -1.0)))
    ;; x11 *= W_16^6 = (-0.7071067811865476, -0.7071067811865476)
    (local.set $tmp (local.get $x11))
    (local.set $x11
      (f64x2.add
        (f64x2.mul (local.get $tmp) (v128.const f64x2 -0.7071067811865476 -0.7071067811865476))
        (f64x2.mul
          (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $tmp) (local.get $tmp))
                     (v128.const f64x2 -0.7071067811865476 -0.7071067811865476))
          (v128.const f64x2 -1.0 1.0))))
    ;; Butterfly
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
    ;; x13 *= W_16^3 = (0.3826834323650898, -0.9238795325112867)
    (local.set $tmp (local.get $x13))
    (local.set $x13
      (f64x2.add
        (f64x2.mul (local.get $tmp) (v128.const f64x2 0.3826834323650898 0.3826834323650898))
        (f64x2.mul
          (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $tmp) (local.get $tmp))
                     (v128.const f64x2 -0.9238795325112867 -0.9238795325112867))
          (v128.const f64x2 -1.0 1.0))))
    ;; x14 *= W_16^6 = (-0.7071067811865476, -0.7071067811865476)
    (local.set $tmp (local.get $x14))
    (local.set $x14
      (f64x2.add
        (f64x2.mul (local.get $tmp) (v128.const f64x2 -0.7071067811865476 -0.7071067811865476))
        (f64x2.mul
          (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $tmp) (local.get $tmp))
                     (v128.const f64x2 -0.7071067811865476 -0.7071067811865476))
          (v128.const f64x2 -1.0 1.0))))
    ;; x15 *= W_16^9 = (-0.9238795325112867, 0.3826834323650898)
    (local.set $tmp (local.get $x15))
    (local.set $x15
      (f64x2.add
        (f64x2.mul (local.get $tmp) (v128.const f64x2 -0.9238795325112867 -0.9238795325112867))
        (f64x2.mul
          (f64x2.mul (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $tmp) (local.get $tmp))
                     (v128.const f64x2 0.3826834323650898 0.3826834323650898))
          (v128.const f64x2 -1.0 1.0))))
    ;; Butterfly
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

  ;; SIMD complex multiply: (a+bi)(c+di) = (ac-bd) + (ad+bc)i
  ;; Input: $a = [re, im], $b = [re, im] as v128
  ;; Output: product as v128
  (func $simd_cmul (param $a v128) (param $b v128) (result v128)
    (local $b_re v128)
    (local $b_im v128)
    (local $prod1 v128)

    ;; b_re = [b.re, b.re]
    (local.set $b_re (i8x16.shuffle 0 1 2 3 4 5 6 7 0 1 2 3 4 5 6 7
                                    (local.get $b) (local.get $b)))
    ;; b_im = [b.im, b.im]
    (local.set $b_im (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15
                                    (local.get $b) (local.get $b)))
    ;; prod1 = [a.re * b.re, a.im * b.re]
    (local.set $prod1 (f64x2.mul (local.get $a) (local.get $b_re)))
    ;; swap a: [a.im, a.re], multiply by b_im, apply sign [-1, 1]
    ;; result: [-a.im*b.im, a.re*b.im]
    ;; add to prod1: [a.re*b.re - a.im*b.im, a.im*b.re + a.re*b.im]
    (f64x2.add
      (local.get $prod1)
      (f64x2.mul
        (f64x2.mul
          (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $a) (local.get $a))
          (local.get $b_im))
        (v128.const f64x2 -1.0 1.0)))
  )

  ;; Radix-4 Stockham FFT for N >= 16 (must be power of 4)
  ;; Now with SIMD complex arithmetic
  ;;
  ;; Each stage processes groups of 4 elements with a radix-4 butterfly.
  ;; Stage s has:
  ;;   - l = 4^s groups
  ;;   - r = N / (4 * l) radix-4 butterflies per group
  ;;   - tw_step = N / (4 * l) for inter-group twiddles
  (func $fft_radix4_general (param $n i32)
    (local $n4 i32)         ;; N/4
    (local $r i32)          ;; butterflies per group
    (local $l i32)          ;; number of groups
    (local $j i32)          ;; group index
    (local $k i32)          ;; butterfly index within group
    (local $src i32)
    (local $dst i32)
    (local $tw_step i32)

    ;; Input/output pointers
    (local $i0 i32) (local $i1 i32) (local $i2 i32) (local $i3 i32)
    (local $o0 i32) (local $o1 i32) (local $o2 i32) (local $o3 i32)

    ;; Twiddle factors as v128: [re, im]
    (local $w1 v128)
    (local $w2 v128)
    (local $w3 v128)
    (local $tw_idx i32)
    (local $tw_addr i32)

    ;; Complex values as v128
    (local $a v128)
    (local $b v128)
    (local $c v128)
    (local $d v128)

    ;; After twiddle application
    (local $b1 v128)
    (local $c1 v128)
    (local $d1 v128)

    ;; Intermediate sums for radix-4 butterfly
    (local $t0 v128)
    (local $t1 v128)
    (local $t2 v128)
    (local $t3 v128)

    ;; Stride calculations
    (local $r_bytes i32)
    (local $n4_bytes i32)

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

        ;; Initialize output pointers for 4 output quadrants
        (local.set $o0 (local.get $dst))
        (local.set $o1 (i32.add (local.get $dst) (local.get $n4_bytes)))
        (local.set $o2 (i32.add (local.get $o1) (local.get $n4_bytes)))
        (local.set $o3 (i32.add (local.get $o2) (local.get $n4_bytes)))
        (local.set $i0 (local.get $src))

        (block $done_groups
          (loop $group_loop
            (br_if $done_groups (i32.ge_u (local.get $j) (local.get $l)))

            ;; Load twiddles for this group: W^{j*tw_step}, W^{2*j*tw_step}, W^{3*j*tw_step}
            (local.set $tw_idx (i32.mul (local.get $j) (local.get $tw_step)))

            ;; W^k - load as v128 [re, im]
            (local.set $tw_addr (i32.add (global.get $TWIDDLE_OFFSET)
                                         (i32.shl (local.get $tw_idx) (i32.const 4))))
            (local.set $w1 (v128.load (local.get $tw_addr)))

            ;; W^{2k}
            (local.set $tw_addr (i32.add (global.get $TWIDDLE_OFFSET)
                                         (i32.shl (i32.mul (local.get $tw_idx) (i32.const 2)) (i32.const 4))))
            ;; Handle wrap-around for 2k >= N
            (if (i32.ge_u (i32.mul (local.get $tw_idx) (i32.const 2)) (local.get $n))
              (then
                (local.set $tw_addr (i32.add (global.get $TWIDDLE_OFFSET)
                  (i32.shl (i32.sub (i32.mul (local.get $tw_idx) (i32.const 2)) (local.get $n)) (i32.const 4))))))
            (local.set $w2 (v128.load (local.get $tw_addr)))

            ;; W^{3k}
            (local.set $tw_addr (i32.add (global.get $TWIDDLE_OFFSET)
                                         (i32.shl (i32.mul (local.get $tw_idx) (i32.const 3)) (i32.const 4))))
            ;; Handle wrap-around for 3k >= N
            (if (i32.ge_u (i32.mul (local.get $tw_idx) (i32.const 3)) (local.get $n))
              (then
                (local.set $tw_addr (i32.add (global.get $TWIDDLE_OFFSET)
                  (i32.shl (i32.rem_u (i32.mul (local.get $tw_idx) (i32.const 3)) (local.get $n)) (i32.const 4))))))
            (local.set $w3 (v128.load (local.get $tw_addr)))

            ;; Set up input pointers for the 4 input quadrants
            (local.set $i1 (i32.add (local.get $i0) (local.get $r_bytes)))
            (local.set $i2 (i32.add (local.get $i1) (local.get $r_bytes)))
            (local.set $i3 (i32.add (local.get $i2) (local.get $r_bytes)))

            (local.set $k (i32.const 0))

            (block $done_butterflies
              (loop $butterfly_loop
                (br_if $done_butterflies (i32.ge_u (local.get $k) (local.get $r)))

                ;; Load 4 complex inputs as v128 [re, im]
                (local.set $a (v128.load (local.get $i0)))
                (local.set $b (v128.load (local.get $i1)))
                (local.set $c (v128.load (local.get $i2)))
                (local.set $d (v128.load (local.get $i3)))

                ;; Apply twiddles: b' = W^k * b, c' = W^{2k} * c, d' = W^{3k} * d
                ;; Inline SIMD complex multiply: (a+bi)(c+di) = (ac-bd) + (ad+bc)i
                ;; b1 = b * w1
                (local.set $b1
                  (f64x2.add
                    (f64x2.mul (local.get $b)
                      (i8x16.shuffle 0 1 2 3 4 5 6 7 0 1 2 3 4 5 6 7 (local.get $w1) (local.get $w1)))
                    (f64x2.mul
                      (f64x2.mul
                        (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $b) (local.get $b))
                        (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $w1) (local.get $w1)))
                      (v128.const f64x2 -1.0 1.0))))
                ;; c1 = c * w2
                (local.set $c1
                  (f64x2.add
                    (f64x2.mul (local.get $c)
                      (i8x16.shuffle 0 1 2 3 4 5 6 7 0 1 2 3 4 5 6 7 (local.get $w2) (local.get $w2)))
                    (f64x2.mul
                      (f64x2.mul
                        (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $c) (local.get $c))
                        (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $w2) (local.get $w2)))
                      (v128.const f64x2 -1.0 1.0))))
                ;; d1 = d * w3
                (local.set $d1
                  (f64x2.add
                    (f64x2.mul (local.get $d)
                      (i8x16.shuffle 0 1 2 3 4 5 6 7 0 1 2 3 4 5 6 7 (local.get $w3) (local.get $w3)))
                    (f64x2.mul
                      (f64x2.mul
                        (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $d) (local.get $d))
                        (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $w3) (local.get $w3)))
                      (v128.const f64x2 -1.0 1.0))))

                ;; Radix-4 butterfly (DIT):
                ;; t0 = a + c', t1 = a - c'
                ;; t2 = b' + d', t3 = b' - d'
                (local.set $t0 (f64x2.add (local.get $a) (local.get $c1)))
                (local.set $t1 (f64x2.sub (local.get $a) (local.get $c1)))
                (local.set $t2 (f64x2.add (local.get $b1) (local.get $d1)))
                (local.set $t3 (f64x2.sub (local.get $b1) (local.get $d1)))

                ;; Store X0 = t0 + t2
                (v128.store (local.get $o0) (f64x2.add (local.get $t0) (local.get $t2)))

                ;; X1 = t1 - j*t3 where -j*(x+yi) = (y, -x) -> shuffle and negate
                ;; t3 shuffled: [im, re], then mul by [1, -1] gives [im, -re]
                ;; t1 + [im, -re] = [re + im, im - re]
                (v128.store (local.get $o1)
                  (f64x2.add (local.get $t1)
                    (f64x2.mul
                      (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7
                        (local.get $t3) (local.get $t3))
                      (v128.const f64x2 1.0 -1.0))))

                ;; Store X2 = t0 - t2
                (v128.store (local.get $o2) (f64x2.sub (local.get $t0) (local.get $t2)))

                ;; X3 = t1 + j*t3 where j*(x+yi) = (-y, x) -> shuffle and negate
                ;; t3 shuffled: [im, re], then mul by [-1, 1] gives [-im, re]
                ;; t1 + [-im, re] = [re - im, im + re]
                (v128.store (local.get $o3)
                  (f64x2.add (local.get $t1)
                    (f64x2.mul
                      (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7
                        (local.get $t3) (local.get $t3))
                      (v128.const f64x2 -1.0 1.0))))

                ;; Advance pointers
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

            ;; Skip input to next group (already moved by r elements, need to skip 3*r more)
            (local.set $i0 (i32.add (local.get $i0) (i32.mul (local.get $r_bytes) (i32.const 3))))
            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $group_loop)
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

        (local.set $r (i32.shr_u (local.get $r) (i32.const 2)))
        (local.set $l (i32.shl (local.get $l) (i32.const 2)))
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

  ;; Main entry point
  (func $fft_radix4 (export "fft_radix4") (param $n i32)
    (if (i32.eq (local.get $n) (i32.const 4))
      (then (call $fft_4) (return)))
    (if (i32.eq (local.get $n) (i32.const 16))
      (then (call $fft_16) (return)))
    (call $fft_radix4_general (local.get $n))
  )
)
