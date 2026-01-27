(module
  ;; Native Split-Format FFT (f32)
  ;;
  ;; This module processes data in split format (separate real/imag arrays)
  ;; to achieve 4 complex numbers per SIMD operation, matching pffft's approach.
  ;;
  ;; Memory Layout:
  ;;   0x00000 - 0x07FFF: Real buffer A (32KB) - input/output reals
  ;;   0x08000 - 0x0FFFF: Imag buffer A (32KB) - input/output imags
  ;;   0x10000 - 0x17FFF: Real buffer B (32KB) - ping-pong secondary
  ;;   0x18000 - 0x1FFFF: Imag buffer B (32KB) - ping-pong secondary
  ;;   0x20000+:          Twiddle factors (split format)
  ;;
  ;; Usage:
  ;;   const real = new Float32Array(memory.buffer, 0, N);
  ;;   const imag = new Float32Array(memory.buffer, 0x8000, N);
  ;;   // Fill real[] and imag[] with input data
  ;;   precompute_twiddles_split(N);
  ;;   fft_split(N);
  ;;   // Output is in real[] and imag[]

  (memory (export "memory") 4)  ;; 4 pages = 256KB

  ;; Buffer offsets
  (global $REAL_A_OFFSET i32 (i32.const 0))
  (global $IMAG_A_OFFSET i32 (i32.const 32768))      ;; 0x8000
  (global $REAL_B_OFFSET i32 (i32.const 65536))      ;; 0x10000
  (global $IMAG_B_OFFSET i32 (i32.const 98304))      ;; 0x18000
  (global $TWIDDLE_RE_OFFSET i32 (i32.const 131072)) ;; 0x20000
  (global $TWIDDLE_IM_OFFSET i32 (i32.const 163840)) ;; 0x28000

  ;; Math constants for range reduction
  (global $PI f32 (f32.const 3.14159265358979323846))
  (global $HALF_PI f32 (f32.const 1.5707963267948966))

  ;; Export offsets for JavaScript
  (global (export "REAL_OFFSET") i32 (i32.const 0))
  (global (export "IMAG_OFFSET") i32 (i32.const 32768))

  ;; ============================================================
  ;; Trigonometric functions (Taylor series approximation)
  ;; ============================================================

  ;; Compute sin(x) using Taylor series with range reduction
  (func $sin_f32 (param $x f32) (result f32)
    (local $x2 f32)
    (local $term f32)
    (local $sum f32)

    ;; Range reduction: bring x into [-π, π]
    (if (f32.lt (local.get $x) (f32.neg (global.get $PI)))
      (then (local.set $x (f32.add (local.get $x) (f32.mul (f32.const 2.0) (global.get $PI))))))
    (if (f32.gt (local.get $x) (global.get $PI))
      (then (local.set $x (f32.sub (local.get $x) (f32.mul (f32.const 2.0) (global.get $PI))))))
    ;; Quadrant reflection: bring x into [-π/2, π/2]
    (if (f32.gt (local.get $x) (global.get $HALF_PI))
      (then (local.set $x (f32.sub (global.get $PI) (local.get $x)))))
    (if (f32.lt (local.get $x) (f32.neg (global.get $HALF_PI)))
      (then (local.set $x (f32.sub (f32.neg (global.get $PI)) (local.get $x)))))

    (local.set $x2 (f32.mul (local.get $x) (local.get $x)))
    (local.set $sum (local.get $x))
    (local.set $term (local.get $x))

    ;; Taylor series: x - x^3/6 + x^5/120 - x^7/5040 + x^9/362880
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

  ;; Compute cos(x) using Taylor series with range reduction
  (func $cos_f32 (param $x f32) (result f32)
    (local $x2 f32)
    (local $term f32)
    (local $sum f32)
    (local $sign f32)

    ;; Range reduction: bring x into [-π, π]
    (if (f32.lt (local.get $x) (f32.neg (global.get $PI)))
      (then (local.set $x (f32.add (local.get $x) (f32.mul (f32.const 2.0) (global.get $PI))))))
    (if (f32.gt (local.get $x) (global.get $PI))
      (then (local.set $x (f32.sub (local.get $x) (f32.mul (f32.const 2.0) (global.get $PI))))))
    ;; Quadrant reflection with sign tracking
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

    ;; Taylor series: 1 - x^2/2 + x^4/24 - x^6/720 + x^8/40320
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

  ;; ============================================================
  ;; Twiddle factor precomputation
  ;; ============================================================

  ;; Precompute twiddle factors W_N^k = e^(-2*pi*i*k/N) = cos(-2*pi*k/N) + i*sin(-2*pi*k/N)
  ;; Stored in split format: all reals first, then all imags
  (func (export "precompute_twiddles_split") (param $n i32)
    (local $k i32)
    (local $angle f32)
    (local $pi2_over_n f32)
    (local $re_addr i32)
    (local $im_addr i32)

    ;; -2*pi/n
    (local.set $pi2_over_n (f32.div (f32.const -6.283185307) (f32.convert_i32_u (local.get $n))))

    (local.set $k (i32.const 0))
    (block $break
      (loop $loop
        (br_if $break (i32.ge_u (local.get $k) (local.get $n)))

        ;; angle = -2*pi*k/n
        (local.set $angle (f32.mul (local.get $pi2_over_n) (f32.convert_i32_u (local.get $k))))

        ;; Address calculations
        (local.set $re_addr (i32.add (global.get $TWIDDLE_RE_OFFSET)
                                     (i32.shl (local.get $k) (i32.const 2))))
        (local.set $im_addr (i32.add (global.get $TWIDDLE_IM_OFFSET)
                                     (i32.shl (local.get $k) (i32.const 2))))

        ;; Store cos(angle) as real part
        (f32.store (local.get $re_addr) (call $cos_f32 (local.get $angle)))
        ;; Store sin(angle) as imag part
        (f32.store (local.get $im_addr) (call $sin_f32 (local.get $angle)))

        (local.set $k (i32.add (local.get $k) (i32.const 1)))
        (br $loop)
      )
    )
  )

  ;; ============================================================
  ;; N=4 Codelet (base case)
  ;; ============================================================

  ;; FFT-4 in split format, operates on 4 consecutive elements
  ;; Input/output at specified offset in real/imag buffers
  (func $fft_4_split (param $re_base i32) (param $im_base i32)
    (local $r0 f32) (local $r1 f32) (local $r2 f32) (local $r3 f32)
    (local $i0 f32) (local $i1 f32) (local $i2 f32) (local $i3 f32)
    (local $t0_re f32) (local $t0_im f32)
    (local $t1_re f32) (local $t1_im f32)
    (local $t2_re f32) (local $t2_im f32)
    (local $t3_re f32) (local $t3_im f32)

    ;; Load 4 complex numbers
    (local.set $r0 (f32.load (local.get $re_base)))
    (local.set $r1 (f32.load (i32.add (local.get $re_base) (i32.const 4))))
    (local.set $r2 (f32.load (i32.add (local.get $re_base) (i32.const 8))))
    (local.set $r3 (f32.load (i32.add (local.get $re_base) (i32.const 12))))
    (local.set $i0 (f32.load (local.get $im_base)))
    (local.set $i1 (f32.load (i32.add (local.get $im_base) (i32.const 4))))
    (local.set $i2 (f32.load (i32.add (local.get $im_base) (i32.const 8))))
    (local.set $i3 (f32.load (i32.add (local.get $im_base) (i32.const 12))))

    ;; Stage 1: 2 radix-2 butterflies
    ;; t0 = x0 + x2, t2 = x0 - x2
    (local.set $t0_re (f32.add (local.get $r0) (local.get $r2)))
    (local.set $t0_im (f32.add (local.get $i0) (local.get $i2)))
    (local.set $t2_re (f32.sub (local.get $r0) (local.get $r2)))
    (local.set $t2_im (f32.sub (local.get $i0) (local.get $i2)))

    ;; t1 = x1 + x3, t3 = x1 - x3
    (local.set $t1_re (f32.add (local.get $r1) (local.get $r3)))
    (local.set $t1_im (f32.add (local.get $i1) (local.get $i3)))
    (local.set $t3_re (f32.sub (local.get $r1) (local.get $r3)))
    (local.set $t3_im (f32.sub (local.get $i1) (local.get $i3)))

    ;; Stage 2: Final butterflies
    ;; X[0] = t0 + t1
    (f32.store (local.get $re_base)
      (f32.add (local.get $t0_re) (local.get $t1_re)))
    (f32.store (local.get $im_base)
      (f32.add (local.get $t0_im) (local.get $t1_im)))

    ;; X[1] = t2 + t3*(-j) = t2 + (t3.im, -t3.re)
    ;; -j * (a + bi) = b - ai
    (f32.store (i32.add (local.get $re_base) (i32.const 4))
      (f32.add (local.get $t2_re) (local.get $t3_im)))
    (f32.store (i32.add (local.get $im_base) (i32.const 4))
      (f32.sub (local.get $t2_im) (local.get $t3_re)))

    ;; X[2] = t0 - t1
    (f32.store (i32.add (local.get $re_base) (i32.const 8))
      (f32.sub (local.get $t0_re) (local.get $t1_re)))
    (f32.store (i32.add (local.get $im_base) (i32.const 8))
      (f32.sub (local.get $t0_im) (local.get $t1_im)))

    ;; X[3] = t2 - t3*(-j) = t2 - (t3.im, -t3.re)
    (f32.store (i32.add (local.get $re_base) (i32.const 12))
      (f32.sub (local.get $t2_re) (local.get $t3_im)))
    (f32.store (i32.add (local.get $im_base) (i32.const 12))
      (f32.add (local.get $t2_im) (local.get $t3_re)))
  )

  ;; ============================================================
  ;; Stockham FFT - Split Format (SIMD with multi-twiddle)
  ;; ============================================================

  ;; Specialized r=1 stage: Process 4 groups with 4 DIFFERENT twiddles
  ;; This is the key optimization - true 4-wide SIMD on twiddle multiply!
  ;;
  ;; Input layout: [a0,b0,a1,b1,a2,b2,a3,b3,...] - consecutive pairs
  ;; Twiddles: W^0, W^1, W^2, W^3, ... - consecutive!
  ;; Output: dst[0..3] and dst[N/2..N/2+3] - consecutive in each half
  (func $fft_stage_r1_simd
    (param $src_re i32) (param $src_im i32)
    (param $dst_re i32) (param $dst_im i32)
    (param $n i32)

    (local $i i32)           ;; byte offset, processes 8 floats per iteration
    (local $n_bytes i32)     ;; n * 4
    (local $n_half_bytes i32) ;; n/2 * 4
    (local $tw_offset i32)   ;; twiddle byte offset

    (local $v0 v128) (local $v1 v128)
    (local $a_re v128) (local $a_im v128)
    (local $b_re v128) (local $b_im v128)
    (local $w_re v128) (local $w_im v128)
    (local $tw_b_re v128) (local $tw_b_im v128)

    (local.set $n_bytes (i32.shl (local.get $n) (i32.const 2)))
    (local.set $n_half_bytes (i32.shr_u (local.get $n_bytes) (i32.const 1)))

    (local.set $i (i32.const 0))
    (block $break
      (loop $loop
        (br_if $break (i32.ge_u (local.get $i) (local.get $n_bytes)))

        ;; Load 8 consecutive reals: [a0,b0,a1,b1,a2,b2,a3,b3]
        (local.set $v0 (v128.load (i32.add (local.get $src_re) (local.get $i))))
        (local.set $v1 (v128.load (i32.add (local.get $src_re) (i32.add (local.get $i) (i32.const 16)))))

        ;; Deinterleave: a_re = [a0,a1,a2,a3], b_re = [b0,b1,b2,b3]
        ;; Elements 0,2 from v0 and elements 0,2 from v1 (as bytes: 0-3,8-11,16-19,24-27)
        (local.set $a_re (i8x16.shuffle 0 1 2 3 8 9 10 11 16 17 18 19 24 25 26 27
          (local.get $v0) (local.get $v1)))
        ;; Elements 1,3 from v0 and elements 1,3 from v1 (as bytes: 4-7,12-15,20-23,28-31)
        (local.set $b_re (i8x16.shuffle 4 5 6 7 12 13 14 15 20 21 22 23 28 29 30 31
          (local.get $v0) (local.get $v1)))

        ;; Same for imaginary
        (local.set $v0 (v128.load (i32.add (local.get $src_im) (local.get $i))))
        (local.set $v1 (v128.load (i32.add (local.get $src_im) (i32.add (local.get $i) (i32.const 16)))))
        (local.set $a_im (i8x16.shuffle 0 1 2 3 8 9 10 11 16 17 18 19 24 25 26 27
          (local.get $v0) (local.get $v1)))
        (local.set $b_im (i8x16.shuffle 4 5 6 7 12 13 14 15 20 21 22 23 28 29 30 31
          (local.get $v0) (local.get $v1)))

        ;; Load 4 CONSECUTIVE twiddles - 4 DIFFERENT values!
        ;; tw_offset = i/2 (since we process 8 floats but only need 4 twiddles)
        (local.set $tw_offset (i32.shr_u (local.get $i) (i32.const 1)))
        (local.set $w_re (v128.load (i32.add (global.get $TWIDDLE_RE_OFFSET) (local.get $tw_offset))))
        (local.set $w_im (v128.load (i32.add (global.get $TWIDDLE_IM_OFFSET) (local.get $tw_offset))))

        ;; Complex multiply with 4 DIFFERENT twiddles - TRUE 4-wide SIMD!
        (local.set $tw_b_re (f32x4.sub (f32x4.mul (local.get $b_re) (local.get $w_re))
                                       (f32x4.mul (local.get $b_im) (local.get $w_im))))
        (local.set $tw_b_im (f32x4.add (f32x4.mul (local.get $b_re) (local.get $w_im))
                                       (f32x4.mul (local.get $b_im) (local.get $w_re))))

        ;; Butterfly outputs - consecutive in each half
        ;; out_lo = dst[j] for j=0,1,2,3
        ;; out_hi = dst[N/2 + j] for j=0,1,2,3
        (v128.store (i32.add (local.get $dst_re) (i32.shr_u (local.get $i) (i32.const 1)))
          (f32x4.add (local.get $a_re) (local.get $tw_b_re)))
        (v128.store (i32.add (local.get $dst_im) (i32.shr_u (local.get $i) (i32.const 1)))
          (f32x4.add (local.get $a_im) (local.get $tw_b_im)))
        (v128.store (i32.add (local.get $dst_re) (i32.add (i32.shr_u (local.get $i) (i32.const 1)) (local.get $n_half_bytes)))
          (f32x4.sub (local.get $a_re) (local.get $tw_b_re)))
        (v128.store (i32.add (local.get $dst_im) (i32.add (i32.shr_u (local.get $i) (i32.const 1)) (local.get $n_half_bytes)))
          (f32x4.sub (local.get $a_im) (local.get $tw_b_im)))

        (local.set $i (i32.add (local.get $i) (i32.const 32)))  ;; 8 floats * 4 bytes
        (br $loop)
      )
    )
  )

  ;; Specialized r=2 stage: Process 2 groups with 2 different twiddles (4 elements total)
  ;; Input layout: [a0_0,a0_1,b0_0,b0_1, a1_0,a1_1,b1_0,b1_1, ...]
  ;; Each group has 2 elements sharing same twiddle, but different groups have different twiddles
  (func $fft_stage_r2_simd
    (param $src_re i32) (param $src_im i32)
    (param $dst_re i32) (param $dst_im i32)
    (param $n i32)

    (local $i i32)           ;; byte offset
    (local $n_bytes i32)
    (local $n_half_bytes i32)
    (local $tw_step i32)     ;; twiddle step = 2 for r=2
    (local $group_idx i32)   ;; which pair of groups we're processing

    (local $v0 v128) (local $v1 v128)
    (local $a_re v128) (local $a_im v128)
    (local $b_re v128) (local $b_im v128)
    (local $w_re v128) (local $w_im v128)
    (local $tw_b_re v128) (local $tw_b_im v128)
    (local $w0_re f32) (local $w0_im f32)
    (local $w1_re f32) (local $w1_im f32)

    (local.set $n_bytes (i32.shl (local.get $n) (i32.const 2)))
    (local.set $n_half_bytes (i32.shr_u (local.get $n_bytes) (i32.const 1)))
    (local.set $tw_step (i32.const 2))  ;; For r=2, tw_step = N/(2*l) = N/(N/2) = 2

    (local.set $i (i32.const 0))
    (local.set $group_idx (i32.const 0))
    (block $break
      (loop $loop
        (br_if $break (i32.ge_u (local.get $i) (local.get $n_bytes)))

        ;; Load 8 consecutive reals: [a0_0,a0_1,b0_0,b0_1, a1_0,a1_1,b1_0,b1_1]
        (local.set $v0 (v128.load (i32.add (local.get $src_re) (local.get $i))))
        (local.set $v1 (v128.load (i32.add (local.get $src_re) (i32.add (local.get $i) (i32.const 16)))))

        ;; Shuffle to separate a and b:
        ;; a = [a0_0, a0_1, a1_0, a1_1] (elements 0,1 from v0 and 0,1 from v1)
        ;; Byte indices: 0-3, 4-7 from v0, 16-19, 20-23 from v1
        (local.set $a_re (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
          (local.get $v0) (local.get $v1)))
        ;; b = [b0_0, b0_1, b1_0, b1_1] (elements 2,3 from v0 and 2,3 from v1)
        ;; Byte indices: 8-11, 12-15 from v0, 24-27, 28-31 from v1
        (local.set $b_re (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31
          (local.get $v0) (local.get $v1)))

        ;; Same for imaginary
        (local.set $v0 (v128.load (i32.add (local.get $src_im) (local.get $i))))
        (local.set $v1 (v128.load (i32.add (local.get $src_im) (i32.add (local.get $i) (i32.const 16)))))
        (local.set $a_im (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
          (local.get $v0) (local.get $v1)))
        (local.set $b_im (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31
          (local.get $v0) (local.get $v1)))

        ;; Load 2 twiddles for groups group_idx and group_idx+1
        ;; Twiddle indices: group_idx * tw_step, (group_idx+1) * tw_step
        (local.set $w0_re (f32.load (i32.add (global.get $TWIDDLE_RE_OFFSET)
          (i32.shl (i32.mul (local.get $group_idx) (local.get $tw_step)) (i32.const 2)))))
        (local.set $w0_im (f32.load (i32.add (global.get $TWIDDLE_IM_OFFSET)
          (i32.shl (i32.mul (local.get $group_idx) (local.get $tw_step)) (i32.const 2)))))
        (local.set $w1_re (f32.load (i32.add (global.get $TWIDDLE_RE_OFFSET)
          (i32.shl (i32.mul (i32.add (local.get $group_idx) (i32.const 1)) (local.get $tw_step)) (i32.const 2)))))
        (local.set $w1_im (f32.load (i32.add (global.get $TWIDDLE_IM_OFFSET)
          (i32.shl (i32.mul (i32.add (local.get $group_idx) (i32.const 1)) (local.get $tw_step)) (i32.const 2)))))

        ;; Build twiddle vector: [w0, w0, w1, w1] (duplicate for 2 elements per group)
        (local.set $w_re (f32x4.replace_lane 0 (f32x4.splat (local.get $w0_re)) (local.get $w0_re)))
        (local.set $w_re (f32x4.replace_lane 1 (local.get $w_re) (local.get $w0_re)))
        (local.set $w_re (f32x4.replace_lane 2 (local.get $w_re) (local.get $w1_re)))
        (local.set $w_re (f32x4.replace_lane 3 (local.get $w_re) (local.get $w1_re)))

        (local.set $w_im (f32x4.replace_lane 0 (f32x4.splat (local.get $w0_im)) (local.get $w0_im)))
        (local.set $w_im (f32x4.replace_lane 1 (local.get $w_im) (local.get $w0_im)))
        (local.set $w_im (f32x4.replace_lane 2 (local.get $w_im) (local.get $w1_im)))
        (local.set $w_im (f32x4.replace_lane 3 (local.get $w_im) (local.get $w1_im)))

        ;; Complex multiply - 2 different twiddles (each used twice)
        (local.set $tw_b_re (f32x4.sub (f32x4.mul (local.get $b_re) (local.get $w_re))
                                       (f32x4.mul (local.get $b_im) (local.get $w_im))))
        (local.set $tw_b_im (f32x4.add (f32x4.mul (local.get $b_re) (local.get $w_im))
                                       (f32x4.mul (local.get $b_im) (local.get $w_re))))

        ;; Butterfly outputs
        ;; For r=2: out0 = j*2 + k, out1 = j*2 + k + N/2
        ;; Groups 0,1 output to: 0,1, 2,3 (lower) and N/2, N/2+1, N/2+2, N/2+3 (upper)
        (v128.store (i32.add (local.get $dst_re) (i32.shr_u (local.get $i) (i32.const 1)))
          (f32x4.add (local.get $a_re) (local.get $tw_b_re)))
        (v128.store (i32.add (local.get $dst_im) (i32.shr_u (local.get $i) (i32.const 1)))
          (f32x4.add (local.get $a_im) (local.get $tw_b_im)))
        (v128.store (i32.add (local.get $dst_re) (i32.add (i32.shr_u (local.get $i) (i32.const 1)) (local.get $n_half_bytes)))
          (f32x4.sub (local.get $a_re) (local.get $tw_b_re)))
        (v128.store (i32.add (local.get $dst_im) (i32.add (i32.shr_u (local.get $i) (i32.const 1)) (local.get $n_half_bytes)))
          (f32x4.sub (local.get $a_im) (local.get $tw_b_im)))

        (local.set $i (i32.add (local.get $i) (i32.const 32)))
        (local.set $group_idx (i32.add (local.get $group_idx) (i32.const 2)))
        (br $loop)
      )
    )
  )

  ;; SIMD Stockham FFT stage for r >= 4 (same twiddle per group, less optimal)
  ;; Parameters: r = butterfly span (n/2, n/4, ..., 4)
  ;;             l = number of groups (1, 2, ..., n/8)
  (func $fft_stockham_stage_split
    (param $src_re i32) (param $src_im i32)
    (param $dst_re i32) (param $dst_im i32)
    (param $n i32) (param $r i32) (param $l i32)

    (local $j i32)           ;; group index (0 to l - 1)
    (local $k i32)           ;; element within group (0 to r - 1)
    (local $tw_step i32)     ;; twiddle step
    (local $r2 i32)          ;; 2 * r
    (local $idx0 i32)
    (local $idx1 i32)
    (local $out0 i32)
    (local $out1 i32)
    (local $n_half i32)
    (local $tw_idx i32)
    (local $tw_re_addr i32)
    (local $tw_im_addr i32)
    (local $j_base i32)      ;; j * r2 (byte offset)
    (local $j_out_base i32)  ;; j * r (byte offset)

    ;; SIMD vectors
    (local $a_re v128) (local $a_im v128)
    (local $b_re v128) (local $b_im v128)
    (local $w_re v128) (local $w_im v128)
    (local $tw_b_re v128) (local $tw_b_im v128)
    (local $temp v128)

    ;; Scalar variables (for r < 4 fallback)
    (local $a_re_s f32) (local $a_im_s f32)
    (local $b_re_s f32) (local $b_im_s f32)
    (local $w_re_s f32) (local $w_im_s f32)
    (local $tw_b_re_s f32) (local $tw_b_im_s f32)
    (local $temp_s f32)

    ;; tw_step = n / (2 * l)
    (local.set $tw_step (i32.div_u (i32.shr_u (local.get $n) (i32.const 1)) (local.get $l)))
    (local.set $r2 (i32.shl (local.get $r) (i32.const 1)))
    (local.set $n_half (i32.shr_u (local.get $n) (i32.const 1)))

    ;; Choose SIMD or scalar based on r
    (if (i32.ge_u (local.get $r) (i32.const 4))
      (then
        ;; SIMD path: process 4 elements at a time
        (local.set $j (i32.const 0))
        (block $break_j
          (loop $loop_j
            (br_if $break_j (i32.ge_u (local.get $j) (local.get $l)))

            ;; Compute twiddle for group j and splat to all lanes
            (local.set $tw_idx (i32.mul (local.get $j) (local.get $tw_step)))
            (local.set $tw_re_addr (i32.add (global.get $TWIDDLE_RE_OFFSET)
                                           (i32.shl (local.get $tw_idx) (i32.const 2))))
            (local.set $tw_im_addr (i32.add (global.get $TWIDDLE_IM_OFFSET)
                                           (i32.shl (local.get $tw_idx) (i32.const 2))))
            (local.set $w_re (f32x4.splat (f32.load (local.get $tw_re_addr))))
            (local.set $w_im (f32x4.splat (f32.load (local.get $tw_im_addr))))

            ;; Precompute base addresses (in bytes)
            (local.set $j_base (i32.shl (i32.mul (local.get $j) (local.get $r2)) (i32.const 2)))
            (local.set $j_out_base (i32.shl (i32.mul (local.get $j) (local.get $r)) (i32.const 2)))

            ;; Process 4 elements at a time
            (local.set $k (i32.const 0))
            (block $break_k
              (loop $loop_k
                (br_if $break_k (i32.ge_u (local.get $k) (local.get $r)))

                ;; Input addresses (byte offset)
                (local.set $idx0 (i32.add (local.get $j_base) (i32.shl (local.get $k) (i32.const 2))))
                (local.set $idx1 (i32.add (local.get $idx0) (i32.shl (local.get $r) (i32.const 2))))

                ;; Output addresses (byte offset)
                (local.set $out0 (i32.add (local.get $j_out_base) (i32.shl (local.get $k) (i32.const 2))))
                (local.set $out1 (i32.add (local.get $out0) (i32.shl (local.get $n_half) (i32.const 2))))

                ;; Load 4 complex a and b values
                (local.set $a_re (v128.load (i32.add (local.get $src_re) (local.get $idx0))))
                (local.set $a_im (v128.load (i32.add (local.get $src_im) (local.get $idx0))))
                (local.set $b_re (v128.load (i32.add (local.get $src_re) (local.get $idx1))))
                (local.set $b_im (v128.load (i32.add (local.get $src_im) (local.get $idx1))))

                ;; Complex multiply: tw_b = b * w
                ;; tw_b_re = b_re * w_re - b_im * w_im
                ;; tw_b_im = b_re * w_im + b_im * w_re
                (local.set $temp (f32x4.mul (local.get $b_re) (local.get $w_re)))
                (local.set $tw_b_re (f32x4.sub (local.get $temp)
                                              (f32x4.mul (local.get $b_im) (local.get $w_im))))
                (local.set $temp (f32x4.mul (local.get $b_re) (local.get $w_im)))
                (local.set $tw_b_im (f32x4.add (local.get $temp)
                                              (f32x4.mul (local.get $b_im) (local.get $w_re))))

                ;; Butterfly: out0 = a + tw_b, out1 = a - tw_b
                (v128.store (i32.add (local.get $dst_re) (local.get $out0))
                  (f32x4.add (local.get $a_re) (local.get $tw_b_re)))
                (v128.store (i32.add (local.get $dst_im) (local.get $out0))
                  (f32x4.add (local.get $a_im) (local.get $tw_b_im)))
                (v128.store (i32.add (local.get $dst_re) (local.get $out1))
                  (f32x4.sub (local.get $a_re) (local.get $tw_b_re)))
                (v128.store (i32.add (local.get $dst_im) (local.get $out1))
                  (f32x4.sub (local.get $a_im) (local.get $tw_b_im)))

                (local.set $k (i32.add (local.get $k) (i32.const 4)))
                (br $loop_k)
              )
            )

            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $loop_j)
          )
        )
      )
      (else
        ;; Scalar fallback for r < 4 (final stages)
        (local.set $j (i32.const 0))
        (block $break_j_scalar
          (loop $loop_j_scalar
            (br_if $break_j_scalar (i32.ge_u (local.get $j) (local.get $l)))

            ;; Compute twiddle for group j
            (local.set $tw_idx (i32.mul (local.get $j) (local.get $tw_step)))
            (local.set $tw_re_addr (i32.add (global.get $TWIDDLE_RE_OFFSET)
                                           (i32.shl (local.get $tw_idx) (i32.const 2))))
            (local.set $tw_im_addr (i32.add (global.get $TWIDDLE_IM_OFFSET)
                                           (i32.shl (local.get $tw_idx) (i32.const 2))))
            (local.set $w_re_s (f32.load (local.get $tw_re_addr)))
            (local.set $w_im_s (f32.load (local.get $tw_im_addr)))

            ;; Process each element in this group
            (local.set $k (i32.const 0))
            (block $break_k_scalar
              (loop $loop_k_scalar
                (br_if $break_k_scalar (i32.ge_u (local.get $k) (local.get $r)))

                ;; Input indices (element, then byte offset)
                (local.set $idx0 (i32.add (i32.mul (local.get $j) (local.get $r2)) (local.get $k)))
                (local.set $idx1 (i32.add (local.get $idx0) (local.get $r)))

                ;; Output indices
                (local.set $out0 (i32.add (i32.mul (local.get $j) (local.get $r)) (local.get $k)))
                (local.set $out1 (i32.add (local.get $out0) (local.get $n_half)))

                ;; Convert to byte offsets
                (local.set $idx0 (i32.shl (local.get $idx0) (i32.const 2)))
                (local.set $idx1 (i32.shl (local.get $idx1) (i32.const 2)))
                (local.set $out0 (i32.shl (local.get $out0) (i32.const 2)))
                (local.set $out1 (i32.shl (local.get $out1) (i32.const 2)))

                ;; Load complex a and b
                (local.set $a_re_s (f32.load (i32.add (local.get $src_re) (local.get $idx0))))
                (local.set $a_im_s (f32.load (i32.add (local.get $src_im) (local.get $idx0))))
                (local.set $b_re_s (f32.load (i32.add (local.get $src_re) (local.get $idx1))))
                (local.set $b_im_s (f32.load (i32.add (local.get $src_im) (local.get $idx1))))

                ;; Complex multiply: tw_b = b * w
                (local.set $temp_s (f32.mul (local.get $b_re_s) (local.get $w_re_s)))
                (local.set $tw_b_re_s (f32.sub (local.get $temp_s)
                                              (f32.mul (local.get $b_im_s) (local.get $w_im_s))))
                (local.set $temp_s (f32.mul (local.get $b_re_s) (local.get $w_im_s)))
                (local.set $tw_b_im_s (f32.add (local.get $temp_s)
                                              (f32.mul (local.get $b_im_s) (local.get $w_re_s))))

                ;; Butterfly: out0 = a + tw_b, out1 = a - tw_b
                (f32.store (i32.add (local.get $dst_re) (local.get $out0))
                  (f32.add (local.get $a_re_s) (local.get $tw_b_re_s)))
                (f32.store (i32.add (local.get $dst_im) (local.get $out0))
                  (f32.add (local.get $a_im_s) (local.get $tw_b_im_s)))
                (f32.store (i32.add (local.get $dst_re) (local.get $out1))
                  (f32.sub (local.get $a_re_s) (local.get $tw_b_re_s)))
                (f32.store (i32.add (local.get $dst_im) (local.get $out1))
                  (f32.sub (local.get $a_im_s) (local.get $tw_b_im_s)))

                (local.set $k (i32.add (local.get $k) (i32.const 1)))
                (br $loop_k_scalar)
              )
            )

            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $loop_j_scalar)
          )
        )
      )
    )
  )

  ;; Main FFT function - split format
  (func $fft_split (export "fft_split") (param $n i32)
    (local $r i32)           ;; butterfly span (starts at n/2, halves each stage)
    (local $l i32)           ;; number of groups (starts at 1, doubles each stage)
    (local $src_re i32)
    (local $src_im i32)
    (local $dst_re i32)
    (local $dst_im i32)
    (local $temp i32)
    (local $i i32)

    ;; Handle small N with codelets
    (if (i32.eq (local.get $n) (i32.const 4))
      (then
        (call $fft_4_split (global.get $REAL_A_OFFSET) (global.get $IMAG_A_OFFSET))
        (return)
      )
    )

    ;; Initialize for Stockham: r starts at n/2, l starts at 1
    (local.set $r (i32.shr_u (local.get $n) (i32.const 1)))
    (local.set $l (i32.const 1))

    ;; Start with input in buffer A, output to buffer B
    (local.set $src_re (global.get $REAL_A_OFFSET))
    (local.set $src_im (global.get $IMAG_A_OFFSET))
    (local.set $dst_re (global.get $REAL_B_OFFSET))
    (local.set $dst_im (global.get $IMAG_B_OFFSET))

    ;; Process stages: r = n/2, n/4, ..., 4 (use generic stage)
    (block $break_stage
      (loop $loop_stage
        (br_if $break_stage (i32.lt_u (local.get $r) (i32.const 4)))

        ;; Process this stage with generic SIMD (same twiddle per group)
        (call $fft_stockham_stage_split
          (local.get $src_re) (local.get $src_im)
          (local.get $dst_re) (local.get $dst_im)
          (local.get $n) (local.get $r) (local.get $l))

        ;; Swap buffers for next stage
        (local.set $temp (local.get $src_re))
        (local.set $src_re (local.get $dst_re))
        (local.set $dst_re (local.get $temp))

        (local.set $temp (local.get $src_im))
        (local.set $src_im (local.get $dst_im))
        (local.set $dst_im (local.get $temp))

        ;; Update r and l for next stage
        (local.set $r (i32.shr_u (local.get $r) (i32.const 1)))
        (local.set $l (i32.shl (local.get $l) (i32.const 1)))

        (br $loop_stage)
      )
    )

    ;; r=2 stage: Use specialized 2-different-twiddle SIMD
    (if (i32.ge_u (local.get $n) (i32.const 8))
      (then
        (call $fft_stage_r2_simd
          (local.get $src_re) (local.get $src_im)
          (local.get $dst_re) (local.get $dst_im)
          (local.get $n))

        ;; Swap buffers
        (local.set $temp (local.get $src_re))
        (local.set $src_re (local.get $dst_re))
        (local.set $dst_re (local.get $temp))

        (local.set $temp (local.get $src_im))
        (local.set $src_im (local.get $dst_im))
        (local.set $dst_im (local.get $temp))
      )
    )

    ;; r=1 stage: Use specialized 4-different-twiddle SIMD (the key optimization!)
    (call $fft_stage_r1_simd
      (local.get $src_re) (local.get $src_im)
      (local.get $dst_re) (local.get $dst_im)
      (local.get $n))

    ;; Final result is in dst buffers, swap pointers for final copy check
    (local.set $temp (local.get $src_re))
    (local.set $src_re (local.get $dst_re))
    (local.set $dst_re (local.get $temp))

    ;; If result is in buffer B, copy back to buffer A
    (if (i32.eq (local.get $src_re) (global.get $REAL_B_OFFSET))
      (then
        ;; Copy from B to A
        (local.set $i (i32.const 0))
        (block $copy_done
          (loop $copy_loop
            (br_if $copy_done (i32.ge_u (local.get $i) (i32.shl (local.get $n) (i32.const 2))))

            (f32.store (i32.add (global.get $REAL_A_OFFSET) (local.get $i))
              (f32.load (i32.add (global.get $REAL_B_OFFSET) (local.get $i))))
            (f32.store (i32.add (global.get $IMAG_A_OFFSET) (local.get $i))
              (f32.load (i32.add (global.get $IMAG_B_OFFSET) (local.get $i))))

            (local.set $i (i32.add (local.get $i) (i32.const 4)))
            (br $copy_loop)
          )
        )
      )
    )
  )

  ;; ============================================================
  ;; Inverse FFT (using conjugate method)
  ;; ============================================================

  ;; IFFT(x) = (1/N) * conj(FFT(conj(x)))
  ;; Uses SIMD f32x4.neg for 4x throughput on conjugation
  (func (export "ifft_split") (param $n i32)
    (local $i i32)
    (local $n_bytes i32)
    (local $scale v128)
    (local $addr i32)

    (local.set $n_bytes (i32.shl (local.get $n) (i32.const 2)))

    ;; Conjugate input (negate imaginary parts) - SIMD 4 elements at a time
    (local.set $i (i32.const 0))
    (block $conj1_done
      (loop $conj1_loop
        (br_if $conj1_done (i32.ge_u (local.get $i) (local.get $n_bytes)))

        (local.set $addr (i32.add (global.get $IMAG_A_OFFSET) (local.get $i)))
        (v128.store (local.get $addr) (f32x4.neg (v128.load (local.get $addr))))

        (local.set $i (i32.add (local.get $i) (i32.const 16)))
        (br $conj1_loop)
      )
    )

    ;; Forward FFT
    (call $fft_split (local.get $n))

    ;; Conjugate and scale output - SIMD 4 elements at a time
    (local.set $scale (f32x4.splat (f32.div (f32.const 1.0) (f32.convert_i32_u (local.get $n)))))
    (local.set $i (i32.const 0))
    (block $conj2_done
      (loop $conj2_loop
        (br_if $conj2_done (i32.ge_u (local.get $i) (local.get $n_bytes)))

        ;; Scale real part
        (local.set $addr (i32.add (global.get $REAL_A_OFFSET) (local.get $i)))
        (v128.store (local.get $addr) (f32x4.mul (v128.load (local.get $addr)) (local.get $scale)))

        ;; Conjugate and scale imaginary part
        (local.set $addr (i32.add (global.get $IMAG_A_OFFSET) (local.get $i)))
        (v128.store (local.get $addr) (f32x4.mul (f32x4.neg (v128.load (local.get $addr))) (local.get $scale)))

        (local.set $i (i32.add (local.get $i) (i32.const 16)))
        (br $conj2_loop)
      )
    )
  )
)
