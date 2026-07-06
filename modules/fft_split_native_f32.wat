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
  ;;   0x20000 - 0x2FFFF: Twiddle factors (split format, classic W_N^k table)
  ;;   0x30000 - 0x3FFFF: Radix-4 forward stage tables (Experiment 58)
  ;;   0x40000 - 0x4FFFF: Radix-4 inverse stage tables (conjugated)
  ;;   0x50000 - 0x5FFFF: rfft post-process twiddles W_N^k, split (Experiment 59)
  ;;   0x60000 - 0x6FFFF: Real buffer C / Imag buffer C (rfft ping-pong partner
  ;;                      when the stage count is even, keeping A free for the
  ;;                      interleaved rfft output; irfft pipeline partner)
  ;;
  ;; Usage:
  ;;   const real = new Float32Array(memory.buffer, 0, N);
  ;;   const imag = new Float32Array(memory.buffer, 0x8000, N);
  ;;   // Fill real[] and imag[] with input data
  ;;   precompute_twiddles_split(N);
  ;;   fft_split(N);
  ;;   // Output is in real[] and imag[]
  ;;
  ;; Real FFT (N real samples, N >= 32):
  ;;   const input = new Float32Array(memory.buffer, 0, N);
  ;;   precompute_rfft_twiddles_split(N);
  ;;   rfft_split(N);
  ;;   // Output: N/2+1 interleaved complex f32 at offset 0
  ;;   irfft_split(N);
  ;;   // Back to N real samples at offset 0 (fully normalized)

  (memory (export "memory") 8)  ;; 8 pages = 512KB

  ;; Buffer offsets
  (global $REAL_A_OFFSET i32 (i32.const 0))
  (global $IMAG_A_OFFSET i32 (i32.const 32768))      ;; 0x8000
  (global $REAL_B_OFFSET i32 (i32.const 65536))      ;; 0x10000
  (global $IMAG_B_OFFSET i32 (i32.const 98304))      ;; 0x18000
  (global $TWIDDLE_RE_OFFSET i32 (i32.const 131072)) ;; 0x20000
  (global $TWIDDLE_IM_OFFSET i32 (i32.const 163840)) ;; 0x28000
  ;; Radix-4 stage tables: per stage, six consecutive f32 arrays of length l:
  ;; w1re w1im w2re w2im w3re w3im, where w1 = W_{4l}^j, w2 = w1^2, w3 = w1^3
  (global $STAGE_TW_FWD i32 (i32.const 196608))      ;; 0x30000
  (global $STAGE_TW_INV i32 (i32.const 262144))      ;; 0x40000
  ;; rfft post-process twiddles W_N^k for k = 0..N/4+3, split re/im arrays
  (global $RFFT_TW_RE i32 (i32.const 327680))        ;; 0x50000
  (global $RFFT_TW_IM i32 (i32.const 360448))        ;; 0x58000
  (global $REAL_C_OFFSET i32 (i32.const 393216))     ;; 0x60000
  (global $IMAG_C_OFFSET i32 (i32.const 425984))     ;; 0x68000

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
  (func $precompute_twiddles_split (export "precompute_twiddles_split") (param $n i32)
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

    ;; Build the radix-4 stage tables (forward and conjugated inverse)
    (if (i32.ge_u (local.get $n) (i32.const 16))
      (then
        (call $build_r4_tables (local.get $n) (global.get $STAGE_TW_FWD) (f32.const 1.0))
        (call $build_r4_tables (local.get $n) (global.get $STAGE_TW_INV) (f32.const -1.0))
      )
    )
  )

  ;; Derive per-stage radix-4 twiddle triples from the classic W_N^k table.
  ;; $im_sign = 1.0 for forward tables, -1.0 for conjugated (inverse) tables.
  (func $build_r4_tables (param $n i32) (param $dst i32) (param $im_sign f32)
    (local $l i32)
    (local $l_max i32)
    (local $j i32)
    (local $step i32)
    (local $k i32)
    (local $off i32)
    (local $lb i32)

    ;; Start at l=1 for even log2(n), l=2 for odd (a twiddle-free radix-2
    ;; stage runs first in that case)
    (if (i32.and (i32.ctz (local.get $n)) (i32.const 1))
      (then (local.set $l (i32.const 2)))
      (else (local.set $l (i32.const 1))))
    (local.set $l_max (i32.shr_u (local.get $n) (i32.const 2)))
    (local.set $off (local.get $dst))

    (block $done_stages
      (loop $stages
        (br_if $done_stages (i32.gt_u (local.get $l) (local.get $l_max)))

        (local.set $step (i32.div_u (local.get $n) (i32.shl (local.get $l) (i32.const 2))))
        (local.set $lb (i32.shl (local.get $l) (i32.const 2)))

        (local.set $j (i32.const 0))
        (block $done_j
          (loop $j_loop
            (br_if $done_j (i32.ge_u (local.get $j) (local.get $l)))

            ;; w1 = W_N^(j*step)
            (local.set $k (i32.shl (i32.mul (local.get $j) (local.get $step)) (i32.const 2)))
            (f32.store (i32.add (local.get $off) (i32.shl (local.get $j) (i32.const 2)))
              (f32.load (i32.add (global.get $TWIDDLE_RE_OFFSET) (local.get $k))))
            (f32.store (i32.add (i32.add (local.get $off) (local.get $lb))
                                (i32.shl (local.get $j) (i32.const 2)))
              (f32.mul (local.get $im_sign)
                (f32.load (i32.add (global.get $TWIDDLE_IM_OFFSET) (local.get $k)))))

            ;; w2 = W_N^(2*j*step)
            (local.set $k (i32.shl (i32.mul (i32.shl (local.get $j) (i32.const 1)) (local.get $step)) (i32.const 2)))
            (f32.store (i32.add (i32.add (local.get $off) (i32.shl (local.get $lb) (i32.const 1)))
                                (i32.shl (local.get $j) (i32.const 2)))
              (f32.load (i32.add (global.get $TWIDDLE_RE_OFFSET) (local.get $k))))
            (f32.store (i32.add (i32.add (local.get $off) (i32.mul (local.get $lb) (i32.const 3)))
                                (i32.shl (local.get $j) (i32.const 2)))
              (f32.mul (local.get $im_sign)
                (f32.load (i32.add (global.get $TWIDDLE_IM_OFFSET) (local.get $k)))))

            ;; w3 = W_N^(3*j*step)
            (local.set $k (i32.shl (i32.mul (i32.mul (local.get $j) (i32.const 3)) (local.get $step)) (i32.const 2)))
            (f32.store (i32.add (i32.add (local.get $off) (i32.shl (local.get $lb) (i32.const 2)))
                                (i32.shl (local.get $j) (i32.const 2)))
              (f32.load (i32.add (global.get $TWIDDLE_RE_OFFSET) (local.get $k))))
            (f32.store (i32.add (i32.add (local.get $off) (i32.mul (local.get $lb) (i32.const 5)))
                                (i32.shl (local.get $j) (i32.const 2)))
              (f32.mul (local.get $im_sign)
                (f32.load (i32.add (global.get $TWIDDLE_IM_OFFSET) (local.get $k)))))

            (local.set $j (i32.add (local.get $j) (i32.const 1)))
            (br $j_loop)
          )
        )

        ;; off += 6*l floats = 24*l bytes; l *= 4
        (local.set $off (i32.add (local.get $off) (i32.mul (local.get $l) (i32.const 24))))
        (local.set $l (i32.shl (local.get $l) (i32.const 2)))
        (br $stages)
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
  ;; ============================================================
  ;; Radix-4 split-format core (Experiment 58)
  ;; ============================================================

  ;; Leading radix-2 stage for N = 2*4^p (l=1, twiddle = W^0 = 1):
  ;; pure 4-wide add/sub, no twiddle loads.
  (func $stage_r2_lead
    (param $src_re i32) (param $src_im i32)
    (param $dst_re i32) (param $dst_im i32)
    (param $n i32)

    (local $i i32)
    (local $h i32)   ;; n/2 in bytes
    (local $a v128) (local $b v128)

    (local.set $h (i32.shl (local.get $n) (i32.const 1)))  ;; (n/2)*4 bytes
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $i) (local.get $h)))

        (local.set $a (v128.load (i32.add (local.get $src_re) (local.get $i))))
        (local.set $b (v128.load (i32.add (i32.add (local.get $src_re) (local.get $h)) (local.get $i))))
        (v128.store (i32.add (local.get $dst_re) (local.get $i))
          (f32x4.add (local.get $a) (local.get $b)))
        (v128.store (i32.add (i32.add (local.get $dst_re) (local.get $h)) (local.get $i))
          (f32x4.sub (local.get $a) (local.get $b)))

        (local.set $a (v128.load (i32.add (local.get $src_im) (local.get $i))))
        (local.set $b (v128.load (i32.add (i32.add (local.get $src_im) (local.get $h)) (local.get $i))))
        (v128.store (i32.add (local.get $dst_im) (local.get $i))
          (f32x4.add (local.get $a) (local.get $b)))
        (v128.store (i32.add (i32.add (local.get $dst_im) (local.get $h)) (local.get $i))
          (f32x4.sub (local.get $a) (local.get $b)))

        (local.set $i (i32.add (local.get $i) (i32.const 16)))
        (br $loop)
      )
    )
  )

  ;; Generic radix-4 stage for s >= 4 (s = elements per quarter-group).
  ;; One twiddle triple per group j, splatted; inner loop is 4-wide over t.
  ;; All SIMD ops are shuffle-free: the -i rotation is an operand swap+negate.
  (func $stage_r4_generic
    (param $src_re i32) (param $src_im i32)
    (param $dst_re i32) (param $dst_im i32)
    (param $s i32) (param $l i32) (param $tw i32) (param $n i32) (param $inv i32)

    (local $j i32)
    (local $tb i32)
    (local $s_bytes i32)
    (local $n4b i32)
    (local $in0 i32)
    (local $q i32)
    (local $lb i32)
    (local $offA i32)
    (local $offB i32)

    (local $w1r v128) (local $w1i v128)
    (local $w2r v128) (local $w2i v128)
    (local $w3r v128) (local $w3i v128)
    (local $ar v128) (local $ai v128)
    (local $br v128) (local $bi v128)
    (local $cr v128) (local $ci v128)
    (local $dr v128) (local $di v128)
    (local $wcr v128) (local $wci v128)
    (local $wbr v128) (local $wbi v128)
    (local $wdr v128) (local $wdi v128)
    (local $t0r v128) (local $t0i v128)
    (local $t1r v128) (local $t1i v128)
    (local $t2r v128) (local $t2i v128)
    (local $t3r v128) (local $t3i v128)

    (local.set $s_bytes (i32.shl (local.get $s) (i32.const 2)))
    (local.set $n4b (local.get $n))  ;; (n/4 elements) * 4 bytes = n bytes
    (local.set $lb (i32.shl (local.get $l) (i32.const 2)))

    ;; The radix-4 butterfly's hardcoded -i rotation is itself a twiddle: the
    ;; inverse transform needs +i, which swaps the two middle output blocks.
    ;; offA receives t1 - i*t3, offB receives t1 + i*t3.
    (local.set $offA (i32.add (local.get $n4b)
      (i32.mul (i32.shl (local.get $n4b) (i32.const 1)) (local.get $inv))))
    (local.set $offB (i32.sub (i32.mul (local.get $n4b) (i32.const 3))
      (i32.mul (i32.shl (local.get $n4b) (i32.const 1)) (local.get $inv))))

    (local.set $j (i32.const 0))
    (block $done_groups
      (loop $group_loop
        (br_if $done_groups (i32.ge_u (local.get $j) (local.get $l)))

        ;; Splat the 6 twiddle scalars for group j
        (local.set $in0 (i32.add (local.get $tw) (i32.shl (local.get $j) (i32.const 2))))
        (local.set $w1r (f32x4.splat (f32.load (local.get $in0))))
        (local.set $in0 (i32.add (local.get $in0) (local.get $lb)))
        (local.set $w1i (f32x4.splat (f32.load (local.get $in0))))
        (local.set $in0 (i32.add (local.get $in0) (local.get $lb)))
        (local.set $w2r (f32x4.splat (f32.load (local.get $in0))))
        (local.set $in0 (i32.add (local.get $in0) (local.get $lb)))
        (local.set $w2i (f32x4.splat (f32.load (local.get $in0))))
        (local.set $in0 (i32.add (local.get $in0) (local.get $lb)))
        (local.set $w3r (f32x4.splat (f32.load (local.get $in0))))
        (local.set $in0 (i32.add (local.get $in0) (local.get $lb)))
        (local.set $w3i (f32x4.splat (f32.load (local.get $in0))))

        (local.set $tb (i32.const 0))
        (block $done_t
          (loop $t_loop
            (br_if $done_t (i32.ge_u (local.get $tb) (local.get $s_bytes)))

            (local.set $in0 (i32.add
              (i32.mul (local.get $j) (i32.shl (local.get $s_bytes) (i32.const 2)))
              (local.get $tb)))

            (local.set $ar (v128.load (i32.add (local.get $src_re) (local.get $in0))))
            (local.set $ai (v128.load (i32.add (local.get $src_im) (local.get $in0))))
            (local.set $in0 (i32.add (local.get $in0) (local.get $s_bytes)))
            (local.set $br (v128.load (i32.add (local.get $src_re) (local.get $in0))))
            (local.set $bi (v128.load (i32.add (local.get $src_im) (local.get $in0))))
            (local.set $in0 (i32.add (local.get $in0) (local.get $s_bytes)))
            (local.set $cr (v128.load (i32.add (local.get $src_re) (local.get $in0))))
            (local.set $ci (v128.load (i32.add (local.get $src_im) (local.get $in0))))
            (local.set $in0 (i32.add (local.get $in0) (local.get $s_bytes)))
            (local.set $dr (v128.load (i32.add (local.get $src_re) (local.get $in0))))
            (local.set $di (v128.load (i32.add (local.get $src_im) (local.get $in0))))

            ;; wc = w2*c, wb = w1*b, wd = w3*d (split-form cmul, no shuffles)
            (local.set $wcr (f32x4.sub (f32x4.mul (local.get $w2r) (local.get $cr))
                                       (f32x4.mul (local.get $w2i) (local.get $ci))))
            (local.set $wci (f32x4.add (f32x4.mul (local.get $w2r) (local.get $ci))
                                       (f32x4.mul (local.get $w2i) (local.get $cr))))
            (local.set $wbr (f32x4.sub (f32x4.mul (local.get $w1r) (local.get $br))
                                       (f32x4.mul (local.get $w1i) (local.get $bi))))
            (local.set $wbi (f32x4.add (f32x4.mul (local.get $w1r) (local.get $bi))
                                       (f32x4.mul (local.get $w1i) (local.get $br))))
            (local.set $wdr (f32x4.sub (f32x4.mul (local.get $w3r) (local.get $dr))
                                       (f32x4.mul (local.get $w3i) (local.get $di))))
            (local.set $wdi (f32x4.add (f32x4.mul (local.get $w3r) (local.get $di))
                                       (f32x4.mul (local.get $w3i) (local.get $dr))))

            (local.set $t0r (f32x4.add (local.get $ar) (local.get $wcr)))
            (local.set $t0i (f32x4.add (local.get $ai) (local.get $wci)))
            (local.set $t1r (f32x4.sub (local.get $ar) (local.get $wcr)))
            (local.set $t1i (f32x4.sub (local.get $ai) (local.get $wci)))
            (local.set $t2r (f32x4.add (local.get $wbr) (local.get $wdr)))
            (local.set $t2i (f32x4.add (local.get $wbi) (local.get $wdi)))
            (local.set $t3r (f32x4.sub (local.get $wbr) (local.get $wdr)))
            (local.set $t3i (f32x4.sub (local.get $wbi) (local.get $wdi)))

            (local.set $q (i32.add (i32.mul (local.get $j) (local.get $s_bytes)) (local.get $tb)))

            (v128.store (i32.add (local.get $dst_re) (local.get $q))
              (f32x4.add (local.get $t0r) (local.get $t2r)))
            (v128.store (i32.add (local.get $dst_im) (local.get $q))
              (f32x4.add (local.get $t0i) (local.get $t2i)))

            ;; -i * t3 = (t3i, -t3r)
            (v128.store (i32.add (local.get $dst_re) (i32.add (local.get $q) (local.get $offA)))
              (f32x4.add (local.get $t1r) (local.get $t3i)))
            (v128.store (i32.add (local.get $dst_im) (i32.add (local.get $q) (local.get $offA)))
              (f32x4.sub (local.get $t1i) (local.get $t3r)))

            (v128.store (i32.add (local.get $dst_re)
                                 (i32.add (local.get $q) (i32.shl (local.get $n4b) (i32.const 1))))
              (f32x4.sub (local.get $t0r) (local.get $t2r)))
            (v128.store (i32.add (local.get $dst_im)
                                 (i32.add (local.get $q) (i32.shl (local.get $n4b) (i32.const 1))))
              (f32x4.sub (local.get $t0i) (local.get $t2i)))

            ;; +i * t3 = (-t3i, t3r)
            (v128.store (i32.add (local.get $dst_re) (i32.add (local.get $q) (local.get $offB)))
              (f32x4.sub (local.get $t1r) (local.get $t3i)))
            (v128.store (i32.add (local.get $dst_im) (i32.add (local.get $q) (local.get $offB)))
              (f32x4.add (local.get $t1i) (local.get $t3r)))

            (local.set $tb (i32.add (local.get $tb) (i32.const 16)))
            (br $t_loop)
          )
        )

        (local.set $j (i32.add (local.get $j) (i32.const 1)))
        (br $group_loop)
      )
    )
  )

  ;; Final s=1 radix-4 stage: 4 groups per iteration with 4 DIFFERENT twiddle
  ;; triples. Group j inputs are src[4j..4j+3]; a 4x4 transpose gathers a/b/c/d.
  ;; Requires l >= 4 (i.e. n >= 16).
  (func $stage_r4_s1
    (param $src_re i32) (param $src_im i32)
    (param $dst_re i32) (param $dst_im i32)
    (param $l i32) (param $tw i32) (param $n i32) (param $inv i32)

    (local $j i32)
    (local $n4b i32)
    (local $lb i32)
    (local $p i32)
    (local $q i32)
    (local $offA i32)
    (local $offB i32)

    (local $v0 v128) (local $v1 v128) (local $v2 v128) (local $v3 v128)
    (local $p0 v128) (local $p1 v128) (local $p2 v128) (local $p3 v128)
    (local $w1r v128) (local $w1i v128)
    (local $w2r v128) (local $w2i v128)
    (local $w3r v128) (local $w3i v128)
    (local $ar v128) (local $ai v128)
    (local $br v128) (local $bi v128)
    (local $cr v128) (local $ci v128)
    (local $dr v128) (local $di v128)
    (local $wcr v128) (local $wci v128)
    (local $wbr v128) (local $wbi v128)
    (local $wdr v128) (local $wdi v128)
    (local $t0r v128) (local $t0i v128)
    (local $t1r v128) (local $t1i v128)
    (local $t2r v128) (local $t2i v128)
    (local $t3r v128) (local $t3i v128)

    (local.set $n4b (local.get $n))
    (local.set $lb (i32.shl (local.get $l) (i32.const 2)))

    ;; Same middle-block swap as $stage_r4_generic: inverse flips -i to +i
    (local.set $offA (i32.add (local.get $n4b)
      (i32.mul (i32.shl (local.get $n4b) (i32.const 1)) (local.get $inv))))
    (local.set $offB (i32.sub (i32.mul (local.get $n4b) (i32.const 3))
      (i32.mul (i32.shl (local.get $n4b) (i32.const 1)) (local.get $inv))))

    (local.set $j (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $j) (local.get $l)))

        ;; ---- real plane: load 16 consecutive floats, transpose 4x4 ----
        (local.set $p (i32.add (local.get $src_re) (i32.shl (local.get $j) (i32.const 4))))
        (local.set $v0 (v128.load (local.get $p)))
        (local.set $v1 (v128.load (i32.add (local.get $p) (i32.const 16))))
        (local.set $v2 (v128.load (i32.add (local.get $p) (i32.const 32))))
        (local.set $v3 (v128.load (i32.add (local.get $p) (i32.const 48))))

        (local.set $p0 (i8x16.shuffle 0 1 2 3 16 17 18 19 8 9 10 11 24 25 26 27
                                      (local.get $v0) (local.get $v1)))
        (local.set $p2 (i8x16.shuffle 4 5 6 7 20 21 22 23 12 13 14 15 28 29 30 31
                                      (local.get $v0) (local.get $v1)))
        (local.set $p1 (i8x16.shuffle 0 1 2 3 16 17 18 19 8 9 10 11 24 25 26 27
                                      (local.get $v2) (local.get $v3)))
        (local.set $p3 (i8x16.shuffle 4 5 6 7 20 21 22 23 12 13 14 15 28 29 30 31
                                      (local.get $v2) (local.get $v3)))

        (local.set $ar (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
                                      (local.get $p0) (local.get $p1)))
        (local.set $cr (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31
                                      (local.get $p0) (local.get $p1)))
        (local.set $br (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
                                      (local.get $p2) (local.get $p3)))
        (local.set $dr (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31
                                      (local.get $p2) (local.get $p3)))

        ;; ---- imag plane ----
        (local.set $p (i32.add (local.get $src_im) (i32.shl (local.get $j) (i32.const 4))))
        (local.set $v0 (v128.load (local.get $p)))
        (local.set $v1 (v128.load (i32.add (local.get $p) (i32.const 16))))
        (local.set $v2 (v128.load (i32.add (local.get $p) (i32.const 32))))
        (local.set $v3 (v128.load (i32.add (local.get $p) (i32.const 48))))

        (local.set $p0 (i8x16.shuffle 0 1 2 3 16 17 18 19 8 9 10 11 24 25 26 27
                                      (local.get $v0) (local.get $v1)))
        (local.set $p2 (i8x16.shuffle 4 5 6 7 20 21 22 23 12 13 14 15 28 29 30 31
                                      (local.get $v0) (local.get $v1)))
        (local.set $p1 (i8x16.shuffle 0 1 2 3 16 17 18 19 8 9 10 11 24 25 26 27
                                      (local.get $v2) (local.get $v3)))
        (local.set $p3 (i8x16.shuffle 4 5 6 7 20 21 22 23 12 13 14 15 28 29 30 31
                                      (local.get $v2) (local.get $v3)))

        (local.set $ai (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
                                      (local.get $p0) (local.get $p1)))
        (local.set $ci (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31
                                      (local.get $p0) (local.get $p1)))
        (local.set $bi (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
                                      (local.get $p2) (local.get $p3)))
        (local.set $di (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31
                                      (local.get $p2) (local.get $p3)))

        ;; ---- 4 consecutive twiddle triples ----
        (local.set $p (i32.add (local.get $tw) (i32.shl (local.get $j) (i32.const 2))))
        (local.set $w1r (v128.load (local.get $p)))
        (local.set $p (i32.add (local.get $p) (local.get $lb)))
        (local.set $w1i (v128.load (local.get $p)))
        (local.set $p (i32.add (local.get $p) (local.get $lb)))
        (local.set $w2r (v128.load (local.get $p)))
        (local.set $p (i32.add (local.get $p) (local.get $lb)))
        (local.set $w2i (v128.load (local.get $p)))
        (local.set $p (i32.add (local.get $p) (local.get $lb)))
        (local.set $w3r (v128.load (local.get $p)))
        (local.set $p (i32.add (local.get $p) (local.get $lb)))
        (local.set $w3i (v128.load (local.get $p)))

        ;; ---- same butterfly math as the generic stage ----
        (local.set $wcr (f32x4.sub (f32x4.mul (local.get $w2r) (local.get $cr))
                                   (f32x4.mul (local.get $w2i) (local.get $ci))))
        (local.set $wci (f32x4.add (f32x4.mul (local.get $w2r) (local.get $ci))
                                   (f32x4.mul (local.get $w2i) (local.get $cr))))
        (local.set $wbr (f32x4.sub (f32x4.mul (local.get $w1r) (local.get $br))
                                   (f32x4.mul (local.get $w1i) (local.get $bi))))
        (local.set $wbi (f32x4.add (f32x4.mul (local.get $w1r) (local.get $bi))
                                   (f32x4.mul (local.get $w1i) (local.get $br))))
        (local.set $wdr (f32x4.sub (f32x4.mul (local.get $w3r) (local.get $dr))
                                   (f32x4.mul (local.get $w3i) (local.get $di))))
        (local.set $wdi (f32x4.add (f32x4.mul (local.get $w3r) (local.get $di))
                                   (f32x4.mul (local.get $w3i) (local.get $dr))))

        (local.set $t0r (f32x4.add (local.get $ar) (local.get $wcr)))
        (local.set $t0i (f32x4.add (local.get $ai) (local.get $wci)))
        (local.set $t1r (f32x4.sub (local.get $ar) (local.get $wcr)))
        (local.set $t1i (f32x4.sub (local.get $ai) (local.get $wci)))
        (local.set $t2r (f32x4.add (local.get $wbr) (local.get $wdr)))
        (local.set $t2i (f32x4.add (local.get $wbi) (local.get $wdi)))
        (local.set $t3r (f32x4.sub (local.get $wbr) (local.get $wdr)))
        (local.set $t3i (f32x4.sub (local.get $wbi) (local.get $wdi)))

        ;; outputs q = j..j+3 contiguous in each quarter block
        (local.set $q (i32.shl (local.get $j) (i32.const 2)))

        (v128.store (i32.add (local.get $dst_re) (local.get $q))
          (f32x4.add (local.get $t0r) (local.get $t2r)))
        (v128.store (i32.add (local.get $dst_im) (local.get $q))
          (f32x4.add (local.get $t0i) (local.get $t2i)))

        ;; -i * t3 = (t3i, -t3r)
        (v128.store (i32.add (local.get $dst_re) (i32.add (local.get $q) (local.get $offA)))
          (f32x4.add (local.get $t1r) (local.get $t3i)))
        (v128.store (i32.add (local.get $dst_im) (i32.add (local.get $q) (local.get $offA)))
          (f32x4.sub (local.get $t1i) (local.get $t3r)))

        (v128.store (i32.add (local.get $dst_re)
                             (i32.add (local.get $q) (i32.shl (local.get $n4b) (i32.const 1))))
          (f32x4.sub (local.get $t0r) (local.get $t2r)))
        (v128.store (i32.add (local.get $dst_im)
                             (i32.add (local.get $q) (i32.shl (local.get $n4b) (i32.const 1))))
          (f32x4.sub (local.get $t0i) (local.get $t2i)))

        ;; +i * t3 = (-t3i, t3r)
        (v128.store (i32.add (local.get $dst_re) (i32.add (local.get $q) (local.get $offB)))
          (f32x4.sub (local.get $t1r) (local.get $t3i)))
        (v128.store (i32.add (local.get $dst_im) (i32.add (local.get $q) (local.get $offB)))
          (f32x4.add (local.get $t1i) (local.get $t3r)))

        (local.set $j (i32.add (local.get $j) (i32.const 4)))
        (br $loop)
      )
    )
  )

  ;; Radix-4 stage loop starting from an arbitrary point in the pipeline
  ;; ($s/$l/$tw), ping-ponging between the sr/si and dr/di buffer pairs.
  ;; Returns the real plane offset the result landed in (imag plane =
  ;; that + 0x8000).
  (func $fft_r4_pipeline (param $n i32) (param $inv i32)
                         (param $s i32) (param $l i32) (param $tw i32)
                         (param $sr i32) (param $si i32)
                         (param $dr i32) (param $di i32) (result i32)
    (local $tmp i32)

    (block $done
      (loop $stages
        (br_if $done (i32.lt_u (local.get $s) (i32.const 1)))

        (if (i32.ge_u (local.get $s) (i32.const 4))
          (then
            (call $stage_r4_generic (local.get $sr) (local.get $si)
                                    (local.get $dr) (local.get $di)
                                    (local.get $s) (local.get $l)
                                    (local.get $tw) (local.get $n) (local.get $inv)))
          (else
            (call $stage_r4_s1 (local.get $sr) (local.get $si)
                               (local.get $dr) (local.get $di)
                               (local.get $l) (local.get $tw) (local.get $n) (local.get $inv))))

        (local.set $tmp (local.get $sr)) (local.set $sr (local.get $dr)) (local.set $dr (local.get $tmp))
        (local.set $tmp (local.get $si)) (local.set $si (local.get $di)) (local.set $di (local.get $tmp))

        (local.set $tw (i32.add (local.get $tw) (i32.mul (local.get $l) (i32.const 24))))
        (local.set $l (i32.shl (local.get $l) (i32.const 2)))
        (local.set $s (i32.shr_u (local.get $s) (i32.const 2)))
        (br $stages)
      )
    )

    (local.get $sr)
  )

  ;; Full radix-4 pipeline for n >= 16, no copy-back. Runs the optional
  ;; leading radix-2 stage, then radix-4 stages, ping-ponging between the
  ;; buffer pair starting at $sr/$si and its A<->B counterpart. Returns the
  ;; real plane offset the result landed in. $tw_base selects forward or
  ;; inverse stage tables.
  (func $fft_r4_core_nc (param $n i32) (param $tw_base i32) (param $inv i32)
                        (param $sr i32) (param $si i32) (result i32)
    (local $s i32)
    (local $l i32)
    (local $dr i32) (local $di i32)
    (local $tmp i32)

    ;; The other ping-pong pair: A_re=0x0/B_re=0x10000, A_im=0x8000/B_im=0x18000
    (local.set $dr (i32.xor (local.get $sr) (i32.const 65536)))
    (local.set $di (i32.xor (local.get $si) (i32.const 65536)))

    (if (i32.and (i32.ctz (local.get $n)) (i32.const 1))
      (then
        ;; odd log2(n): twiddle-free radix-2 stage first
        (call $stage_r2_lead (local.get $sr) (local.get $si)
                             (local.get $dr) (local.get $di) (local.get $n))
        (local.set $tmp (local.get $sr)) (local.set $sr (local.get $dr)) (local.set $dr (local.get $tmp))
        (local.set $tmp (local.get $si)) (local.set $si (local.get $di)) (local.set $di (local.get $tmp))
        (local.set $s (i32.shr_u (local.get $n) (i32.const 3)))
        (local.set $l (i32.const 2)))
      (else
        (local.set $s (i32.shr_u (local.get $n) (i32.const 2)))
        (local.set $l (i32.const 1))))

    (call $fft_r4_pipeline (local.get $n) (local.get $inv)
      (local.get $s) (local.get $l) (local.get $tw_base)
      (local.get $sr) (local.get $si) (local.get $dr) (local.get $di))
  )

  ;; Radix-4 pipeline driver for n >= 16, starting in buffer A; copies back
  ;; to A if the result lands in B (the complex API contract).
  (func $fft_r4_core (param $n i32) (param $tw_base i32) (param $inv i32)
    (local $sr i32)
    (local $i i32)
    (local $nb i32)

    (local.set $sr (call $fft_r4_core_nc
      (local.get $n) (local.get $tw_base) (local.get $inv)
      (global.get $REAL_A_OFFSET) (global.get $IMAG_A_OFFSET)))

    ;; If the result landed in buffer B, copy back to A (SIMD)
    (if (i32.eq (local.get $sr) (global.get $REAL_B_OFFSET))
      (then
        (local.set $nb (i32.shl (local.get $n) (i32.const 2)))
        (local.set $i (i32.const 0))
        (block $copy_done
          (loop $copy_loop
            (br_if $copy_done (i32.ge_u (local.get $i) (local.get $nb)))
            (v128.store (i32.add (global.get $REAL_A_OFFSET) (local.get $i))
              (v128.load (i32.add (global.get $REAL_B_OFFSET) (local.get $i))))
            (v128.store (i32.add (global.get $IMAG_A_OFFSET) (local.get $i))
              (v128.load (i32.add (global.get $IMAG_B_OFFSET) (local.get $i))))
            (local.set $i (i32.add (local.get $i) (i32.const 16)))
            (br $copy_loop)
          )
        )
      )
    )
  )

  ;; ============================================================
  ;; Real FFT on the radix-4 split core (Experiment 59)
  ;; ============================================================

  ;; Precompute everything rfft_split(n) needs: the M = n/2 complex-core
  ;; tables plus the post-process twiddles W_N^k = e^(-2*pi*i*k/N) in split
  ;; layout (contiguous re[] then im[], vector-loadable at any k).
  (func (export "precompute_rfft_twiddles_split") (param $n i32)
    (local $k i32)
    (local $kmax i32)
    (local $angle f32)
    (local $step f32)

    (call $precompute_twiddles_split (i32.shr_u (local.get $n) (i32.const 1)))

    (local.set $step (f32.div (f32.const -6.283185307) (f32.convert_i32_u (local.get $n))))
    ;; k = 0 .. n/4+3 covers every lane the post-process vector loop touches
    (local.set $kmax (i32.add (i32.shr_u (local.get $n) (i32.const 2)) (i32.const 3)))
    (local.set $k (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.gt_u (local.get $k) (local.get $kmax)))
        (local.set $angle (f32.mul (local.get $step) (f32.convert_i32_u (local.get $k))))
        (f32.store (i32.add (global.get $RFFT_TW_RE) (i32.shl (local.get $k) (i32.const 2)))
          (call $cos_f32 (local.get $angle)))
        (f32.store (i32.add (global.get $RFFT_TW_IM) (i32.shl (local.get $k) (i32.const 2)))
          (call $sin_f32 (local.get $angle)))
        (local.set $k (i32.add (local.get $k) (i32.const 1)))
        (br $loop)
      )
    )
  )

  ;; Fused deinterleave + leading radix-2 + first radix-4 stage = a radix-8
  ;; first stage, for odd log2(m). One memory pass replaces the three the
  ;; unfused pipeline would take. The radix-8 twiddles are constants
  ;; (1, -i, and sqrt(2)/2*(1-+i)), so everything stays shuffle-free splat
  ;; arithmetic. Reads packed input at offset 0, writes to buffer B.
  ;; Forward transform only (rfft).
  (func $stage_r8_first_fused (param $dst_re i32) (param $dst_im i32) (param $m i32)
    (local $tb i32)     ;; byte offset within a plane octant
    (local $sb i32)     ;; (m/8)*4 plane bytes
    (local $ob i32)     ;; octant stride in the interleaved input = m bytes
    (local $p i32)
    (local $q i32)
    (local $c v128)     ;; splat sqrt(2)/2
    (local $v0 v128) (local $v1 v128)
    (local $xr v128) (local $xi v128)
    (local $s0r v128) (local $s0i v128) (local $s1r v128) (local $s1i v128)
    (local $s2r v128) (local $s2i v128) (local $s3r v128) (local $s3i v128)
    (local $d0r v128) (local $d0i v128) (local $d1r v128) (local $d1i v128)
    (local $d2r v128) (local $d2i v128) (local $d3r v128) (local $d3i v128)
    (local $t0r v128) (local $t0i v128)
    (local $t1r v128) (local $t1i v128)
    (local $t2r v128) (local $t2i v128)
    (local $t3r v128) (local $t3i v128)

    (local.set $sb (i32.shr_u (local.get $m) (i32.const 1)))
    (local.set $ob (local.get $m))
    (local.set $c (f32x4.splat (f32.const 0.7071067811865476)))

    (local.set $tb (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $tb) (local.get $sb)))

        ;; Octant pairs (k, k+4): S_k = x_k + x_{k+4}, D_k = x_k - x_{k+4}
        ;; x octant k at input byte 2*tb + k*ob, deinterleaved on load
        (local.set $p (i32.shl (local.get $tb) (i32.const 1)))

        (local.set $v0 (v128.load (local.get $p)))
        (local.set $v1 (v128.load (i32.add (local.get $p) (i32.const 16))))
        (local.set $xr (i8x16.shuffle 0 1 2 3 8 9 10 11 16 17 18 19 24 25 26 27
          (local.get $v0) (local.get $v1)))
        (local.set $xi (i8x16.shuffle 4 5 6 7 12 13 14 15 20 21 22 23 28 29 30 31
          (local.get $v0) (local.get $v1)))
        (local.set $q (i32.add (local.get $p) (i32.shl (local.get $ob) (i32.const 2))))
        (local.set $v0 (v128.load (local.get $q)))
        (local.set $v1 (v128.load (i32.add (local.get $q) (i32.const 16))))
        (local.set $s0r (i8x16.shuffle 0 1 2 3 8 9 10 11 16 17 18 19 24 25 26 27
          (local.get $v0) (local.get $v1)))
        (local.set $s0i (i8x16.shuffle 4 5 6 7 12 13 14 15 20 21 22 23 28 29 30 31
          (local.get $v0) (local.get $v1)))
        (local.set $d0r (f32x4.sub (local.get $xr) (local.get $s0r)))
        (local.set $d0i (f32x4.sub (local.get $xi) (local.get $s0i)))
        (local.set $s0r (f32x4.add (local.get $xr) (local.get $s0r)))
        (local.set $s0i (f32x4.add (local.get $xi) (local.get $s0i)))

        (local.set $p (i32.add (local.get $p) (local.get $ob)))
        (local.set $v0 (v128.load (local.get $p)))
        (local.set $v1 (v128.load (i32.add (local.get $p) (i32.const 16))))
        (local.set $xr (i8x16.shuffle 0 1 2 3 8 9 10 11 16 17 18 19 24 25 26 27
          (local.get $v0) (local.get $v1)))
        (local.set $xi (i8x16.shuffle 4 5 6 7 12 13 14 15 20 21 22 23 28 29 30 31
          (local.get $v0) (local.get $v1)))
        (local.set $q (i32.add (local.get $p) (i32.shl (local.get $ob) (i32.const 2))))
        (local.set $v0 (v128.load (local.get $q)))
        (local.set $v1 (v128.load (i32.add (local.get $q) (i32.const 16))))
        (local.set $s1r (i8x16.shuffle 0 1 2 3 8 9 10 11 16 17 18 19 24 25 26 27
          (local.get $v0) (local.get $v1)))
        (local.set $s1i (i8x16.shuffle 4 5 6 7 12 13 14 15 20 21 22 23 28 29 30 31
          (local.get $v0) (local.get $v1)))
        (local.set $d1r (f32x4.sub (local.get $xr) (local.get $s1r)))
        (local.set $d1i (f32x4.sub (local.get $xi) (local.get $s1i)))
        (local.set $s1r (f32x4.add (local.get $xr) (local.get $s1r)))
        (local.set $s1i (f32x4.add (local.get $xi) (local.get $s1i)))

        (local.set $p (i32.add (local.get $p) (local.get $ob)))
        (local.set $v0 (v128.load (local.get $p)))
        (local.set $v1 (v128.load (i32.add (local.get $p) (i32.const 16))))
        (local.set $xr (i8x16.shuffle 0 1 2 3 8 9 10 11 16 17 18 19 24 25 26 27
          (local.get $v0) (local.get $v1)))
        (local.set $xi (i8x16.shuffle 4 5 6 7 12 13 14 15 20 21 22 23 28 29 30 31
          (local.get $v0) (local.get $v1)))
        (local.set $q (i32.add (local.get $p) (i32.shl (local.get $ob) (i32.const 2))))
        (local.set $v0 (v128.load (local.get $q)))
        (local.set $v1 (v128.load (i32.add (local.get $q) (i32.const 16))))
        (local.set $s2r (i8x16.shuffle 0 1 2 3 8 9 10 11 16 17 18 19 24 25 26 27
          (local.get $v0) (local.get $v1)))
        (local.set $s2i (i8x16.shuffle 4 5 6 7 12 13 14 15 20 21 22 23 28 29 30 31
          (local.get $v0) (local.get $v1)))
        (local.set $d2r (f32x4.sub (local.get $xr) (local.get $s2r)))
        (local.set $d2i (f32x4.sub (local.get $xi) (local.get $s2i)))
        (local.set $s2r (f32x4.add (local.get $xr) (local.get $s2r)))
        (local.set $s2i (f32x4.add (local.get $xi) (local.get $s2i)))

        (local.set $p (i32.add (local.get $p) (local.get $ob)))
        (local.set $v0 (v128.load (local.get $p)))
        (local.set $v1 (v128.load (i32.add (local.get $p) (i32.const 16))))
        (local.set $xr (i8x16.shuffle 0 1 2 3 8 9 10 11 16 17 18 19 24 25 26 27
          (local.get $v0) (local.get $v1)))
        (local.set $xi (i8x16.shuffle 4 5 6 7 12 13 14 15 20 21 22 23 28 29 30 31
          (local.get $v0) (local.get $v1)))
        (local.set $q (i32.add (local.get $p) (i32.shl (local.get $ob) (i32.const 2))))
        (local.set $v0 (v128.load (local.get $q)))
        (local.set $v1 (v128.load (i32.add (local.get $q) (i32.const 16))))
        (local.set $s3r (i8x16.shuffle 0 1 2 3 8 9 10 11 16 17 18 19 24 25 26 27
          (local.get $v0) (local.get $v1)))
        (local.set $s3i (i8x16.shuffle 4 5 6 7 12 13 14 15 20 21 22 23 28 29 30 31
          (local.get $v0) (local.get $v1)))
        (local.set $d3r (f32x4.sub (local.get $xr) (local.get $s3r)))
        (local.set $d3i (f32x4.sub (local.get $xi) (local.get $s3i)))
        (local.set $s3r (f32x4.add (local.get $xr) (local.get $s3r)))
        (local.set $s3i (f32x4.add (local.get $xi) (local.get $s3i)))

        ;; Group 0 (sums, w = 1) -> even output octants 0,2,4,6
        (local.set $t0r (f32x4.add (local.get $s0r) (local.get $s2r)))
        (local.set $t0i (f32x4.add (local.get $s0i) (local.get $s2i)))
        (local.set $t1r (f32x4.sub (local.get $s0r) (local.get $s2r)))
        (local.set $t1i (f32x4.sub (local.get $s0i) (local.get $s2i)))
        (local.set $t2r (f32x4.add (local.get $s1r) (local.get $s3r)))
        (local.set $t2i (f32x4.add (local.get $s1i) (local.get $s3i)))
        (local.set $t3r (f32x4.sub (local.get $s1r) (local.get $s3r)))
        (local.set $t3i (f32x4.sub (local.get $s1i) (local.get $s3i)))

        (local.set $p (i32.add (local.get $dst_re) (local.get $tb)))
        (local.set $q (i32.add (local.get $dst_im) (local.get $tb)))
        (v128.store (local.get $p) (f32x4.add (local.get $t0r) (local.get $t2r)))
        (v128.store (local.get $q) (f32x4.add (local.get $t0i) (local.get $t2i)))
        (v128.store (i32.add (local.get $p) (i32.shl (local.get $sb) (i32.const 1)))
          (f32x4.add (local.get $t1r) (local.get $t3i)))
        (v128.store (i32.add (local.get $q) (i32.shl (local.get $sb) (i32.const 1)))
          (f32x4.sub (local.get $t1i) (local.get $t3r)))
        (v128.store (i32.add (local.get $p) (i32.shl (local.get $sb) (i32.const 2)))
          (f32x4.sub (local.get $t0r) (local.get $t2r)))
        (v128.store (i32.add (local.get $q) (i32.shl (local.get $sb) (i32.const 2)))
          (f32x4.sub (local.get $t0i) (local.get $t2i)))
        (v128.store (i32.add (local.get $p) (i32.mul (local.get $sb) (i32.const 6)))
          (f32x4.sub (local.get $t1r) (local.get $t3i)))
        (v128.store (i32.add (local.get $q) (i32.mul (local.get $sb) (i32.const 6)))
          (f32x4.add (local.get $t1i) (local.get $t3r)))

        ;; Group 1 (diffs, w = W_8) -> odd output octants 1,3,5,7
        ;; t0 = D0 - i*D2, t1 = D0 + i*D2
        (local.set $t0r (f32x4.add (local.get $d0r) (local.get $d2i)))
        (local.set $t0i (f32x4.sub (local.get $d0i) (local.get $d2r)))
        (local.set $t1r (f32x4.sub (local.get $d0r) (local.get $d2i)))
        (local.set $t1i (f32x4.add (local.get $d0i) (local.get $d2r)))
        ;; w*D1 = c*(D1r+D1i, D1i-D1r) -> xr/xi
        (local.set $xr (f32x4.mul (local.get $c) (f32x4.add (local.get $d1r) (local.get $d1i))))
        (local.set $xi (f32x4.mul (local.get $c) (f32x4.sub (local.get $d1i) (local.get $d1r))))
        ;; w^3*D3 = c*(D3i-D3r, -(D3r+D3i)) -> d1r/d1i (reused as temps)
        (local.set $d1r (f32x4.mul (local.get $c) (f32x4.sub (local.get $d3i) (local.get $d3r))))
        (local.set $d1i (f32x4.neg (f32x4.mul (local.get $c) (f32x4.add (local.get $d3r) (local.get $d3i)))))
        ;; t2 = w*D1 + w^3*D3, t3 = w*D1 - w^3*D3
        (local.set $t2r (f32x4.add (local.get $xr) (local.get $d1r)))
        (local.set $t2i (f32x4.add (local.get $xi) (local.get $d1i)))
        (local.set $t3r (f32x4.sub (local.get $xr) (local.get $d1r)))
        (local.set $t3i (f32x4.sub (local.get $xi) (local.get $d1i)))

        (local.set $p (i32.add (i32.add (local.get $dst_re) (local.get $tb)) (local.get $sb)))
        (local.set $q (i32.add (i32.add (local.get $dst_im) (local.get $tb)) (local.get $sb)))
        (v128.store (local.get $p) (f32x4.add (local.get $t0r) (local.get $t2r)))
        (v128.store (local.get $q) (f32x4.add (local.get $t0i) (local.get $t2i)))
        (v128.store (i32.add (local.get $p) (i32.shl (local.get $sb) (i32.const 1)))
          (f32x4.add (local.get $t1r) (local.get $t3i)))
        (v128.store (i32.add (local.get $q) (i32.shl (local.get $sb) (i32.const 1)))
          (f32x4.sub (local.get $t1i) (local.get $t3r)))
        (v128.store (i32.add (local.get $p) (i32.shl (local.get $sb) (i32.const 2)))
          (f32x4.sub (local.get $t0r) (local.get $t2r)))
        (v128.store (i32.add (local.get $q) (i32.shl (local.get $sb) (i32.const 2)))
          (f32x4.sub (local.get $t0i) (local.get $t2i)))
        (v128.store (i32.add (local.get $p) (i32.mul (local.get $sb) (i32.const 6)))
          (f32x4.sub (local.get $t1r) (local.get $t3i)))
        (v128.store (i32.add (local.get $q) (i32.mul (local.get $sb) (i32.const 6)))
          (f32x4.add (local.get $t1i) (local.get $t3r)))

        (local.set $tb (i32.add (local.get $tb) (i32.const 16)))
        (br $loop)
      )
    )
  )

  ;; Fused deinterleave + first radix-4 stage (l=1, all twiddles = 1), for
  ;; even log2(m). Same input-at-offset-0 / write-to-B convention as
  ;; $stage_r8_first_fused. Forward transform only (rfft).
  (func $stage_r4_first_fused (param $dst_re i32) (param $dst_im i32) (param $m i32)
    (local $t i32)      ;; byte offset within a plane quarter
    (local $sb i32)     ;; (m/4)*4 plane bytes
    (local $p i32)
    (local $v0 v128) (local $v1 v128)
    (local $ar v128) (local $ai v128)
    (local $br v128) (local $bi v128)
    (local $cr v128) (local $ci v128)
    (local $dr v128) (local $di v128)
    (local $t0r v128) (local $t0i v128)
    (local $t1r v128) (local $t1i v128)
    (local $t2r v128) (local $t2i v128)
    (local $t3r v128) (local $t3i v128)

    (local.set $sb (local.get $m))  ;; (m/4 elements) * 4 bytes = m bytes
    (local.set $t (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $t) (local.get $sb)))

        ;; quarter a = z[t..], b = z[t+s..], c = z[t+2s..], d = z[t+3s..]
        (local.set $p (i32.shl (local.get $t) (i32.const 1)))
        (local.set $v0 (v128.load (local.get $p)))
        (local.set $v1 (v128.load (i32.add (local.get $p) (i32.const 16))))
        (local.set $ar (i8x16.shuffle 0 1 2 3 8 9 10 11 16 17 18 19 24 25 26 27
          (local.get $v0) (local.get $v1)))
        (local.set $ai (i8x16.shuffle 4 5 6 7 12 13 14 15 20 21 22 23 28 29 30 31
          (local.get $v0) (local.get $v1)))
        (local.set $p (i32.add (local.get $p) (i32.shl (local.get $sb) (i32.const 1))))
        (local.set $v0 (v128.load (local.get $p)))
        (local.set $v1 (v128.load (i32.add (local.get $p) (i32.const 16))))
        (local.set $br (i8x16.shuffle 0 1 2 3 8 9 10 11 16 17 18 19 24 25 26 27
          (local.get $v0) (local.get $v1)))
        (local.set $bi (i8x16.shuffle 4 5 6 7 12 13 14 15 20 21 22 23 28 29 30 31
          (local.get $v0) (local.get $v1)))
        (local.set $p (i32.add (local.get $p) (i32.shl (local.get $sb) (i32.const 1))))
        (local.set $v0 (v128.load (local.get $p)))
        (local.set $v1 (v128.load (i32.add (local.get $p) (i32.const 16))))
        (local.set $cr (i8x16.shuffle 0 1 2 3 8 9 10 11 16 17 18 19 24 25 26 27
          (local.get $v0) (local.get $v1)))
        (local.set $ci (i8x16.shuffle 4 5 6 7 12 13 14 15 20 21 22 23 28 29 30 31
          (local.get $v0) (local.get $v1)))
        (local.set $p (i32.add (local.get $p) (i32.shl (local.get $sb) (i32.const 1))))
        (local.set $v0 (v128.load (local.get $p)))
        (local.set $v1 (v128.load (i32.add (local.get $p) (i32.const 16))))
        (local.set $dr (i8x16.shuffle 0 1 2 3 8 9 10 11 16 17 18 19 24 25 26 27
          (local.get $v0) (local.get $v1)))
        (local.set $di (i8x16.shuffle 4 5 6 7 12 13 14 15 20 21 22 23 28 29 30 31
          (local.get $v0) (local.get $v1)))

        ;; Twiddle-free radix-4 butterfly (w1 = w2 = w3 = 1)
        (local.set $t0r (f32x4.add (local.get $ar) (local.get $cr)))
        (local.set $t0i (f32x4.add (local.get $ai) (local.get $ci)))
        (local.set $t1r (f32x4.sub (local.get $ar) (local.get $cr)))
        (local.set $t1i (f32x4.sub (local.get $ai) (local.get $ci)))
        (local.set $t2r (f32x4.add (local.get $br) (local.get $dr)))
        (local.set $t2i (f32x4.add (local.get $bi) (local.get $di)))
        (local.set $t3r (f32x4.sub (local.get $br) (local.get $dr)))
        (local.set $t3i (f32x4.sub (local.get $bi) (local.get $di)))

        (v128.store (i32.add (local.get $dst_re) (local.get $t))
          (f32x4.add (local.get $t0r) (local.get $t2r)))
        (v128.store (i32.add (local.get $dst_im) (local.get $t))
          (f32x4.add (local.get $t0i) (local.get $t2i)))
        ;; -i * t3 = (t3i, -t3r)
        (v128.store (i32.add (i32.add (local.get $dst_re) (local.get $sb)) (local.get $t))
          (f32x4.add (local.get $t1r) (local.get $t3i)))
        (v128.store (i32.add (i32.add (local.get $dst_im) (local.get $sb)) (local.get $t))
          (f32x4.sub (local.get $t1i) (local.get $t3r)))
        (v128.store (i32.add (i32.add (local.get $dst_re) (i32.shl (local.get $sb) (i32.const 1))) (local.get $t))
          (f32x4.sub (local.get $t0r) (local.get $t2r)))
        (v128.store (i32.add (i32.add (local.get $dst_im) (i32.shl (local.get $sb) (i32.const 1))) (local.get $t))
          (f32x4.sub (local.get $t0i) (local.get $t2i)))
        ;; +i * t3 = (-t3i, t3r)
        (v128.store (i32.add (i32.add (local.get $dst_re) (i32.mul (local.get $sb) (i32.const 3))) (local.get $t))
          (f32x4.sub (local.get $t1r) (local.get $t3i)))
        (v128.store (i32.add (i32.add (local.get $dst_im) (i32.mul (local.get $sb) (i32.const 3))) (local.get $t))
          (f32x4.add (local.get $t1i) (local.get $t3r)))

        (local.set $t (i32.add (local.get $t) (i32.const 16)))
        (br $loop)
      )
    )
  )

  ;; Split-format rfft post-processing. Reads the M-point FFT result Z from
  ;; split planes src_re/src_im (must NOT be buffer A - the interleaved
  ;; output overwrites both A planes) and writes X[0..M] interleaved to 0.
  ;;   G = (Z[k] + conj(Z[M-k]))/2      (spectrum of even samples)
  ;;   H = -i*(Z[k] - conj(Z[M-k]))/2   (spectrum of odd samples)
  ;;   X[k] = G + W_N^k * H,  X[M-k] = conj(G - W_N^k * H)
  ;; The vector loop runs k = 1, 5, ... , M/2-3: forward blocks cover
  ;; X[1..M/2], mirrored blocks cover X[M/2..M-1] (X[M/2] written twice with
  ;; the same value). All loads precede all stores per iteration and
  ;; src != dst, so the unaligned overlapping stores are hazard-free.
  (func $rfft_postprocess_split (param $m i32) (param $src_re i32) (param $src_im i32)
    (local $k i32)       ;; element index, steps by 4
    (local $kb i32)      ;; k * 4 (plane byte offset)
    (local $kend i32)
    (local $mrb i32)     ;; (m-k-3) * 4 (mirrored plane byte offset)
    (local $z0r f32) (local $z0i f32)
    (local $half v128)
    (local $zr v128) (local $zi v128)
    (local $mr v128) (local $mi v128)
    (local $gr v128) (local $gi v128)
    (local $hr v128) (local $hi v128)
    (local $wr v128) (local $wi v128)
    (local $tr v128) (local $ti v128)
    (local $xr v128) (local $xi v128)

    ;; DC bin (Nyquist is stored after the loop: for M=8192 it lands on the
    ;; first bytes of buffer B, which the loop still reads as Z[1])
    (local.set $z0r (f32.load (local.get $src_re)))
    (local.set $z0i (f32.load (local.get $src_im)))
    (f32.store (i32.const 0) (f32.add (local.get $z0r) (local.get $z0i)))
    (f32.store (i32.const 4) (f32.const 0))

    (local.set $half (f32x4.splat (f32.const 0.5)))
    (local.set $kend (i32.sub (i32.shr_u (local.get $m) (i32.const 1)) (i32.const 3)))
    (local.set $k (i32.const 1))
    (block $done
      (loop $loop
        (br_if $done (i32.gt_u (local.get $k) (local.get $kend)))

        (local.set $kb (i32.shl (local.get $k) (i32.const 2)))
        (local.set $mrb (i32.shl (i32.sub (i32.sub (local.get $m) (local.get $k)) (i32.const 3))
                                 (i32.const 2)))

        ;; Z[k..k+3] forward, Z[M-k-3..M-k] lane-reversed
        (local.set $zr (v128.load (i32.add (local.get $src_re) (local.get $kb))))
        (local.set $zi (v128.load (i32.add (local.get $src_im) (local.get $kb))))
        (local.set $mr (v128.load (i32.add (local.get $src_re) (local.get $mrb))))
        (local.set $mr (i8x16.shuffle 12 13 14 15 8 9 10 11 4 5 6 7 0 1 2 3
          (local.get $mr) (local.get $mr)))
        (local.set $mi (v128.load (i32.add (local.get $src_im) (local.get $mrb))))
        (local.set $mi (i8x16.shuffle 12 13 14 15 8 9 10 11 4 5 6 7 0 1 2 3
          (local.get $mi) (local.get $mi)))

        ;; 4 consecutive twiddles W_N^(k..k+3), contiguous split loads
        (local.set $wr (v128.load (i32.add (global.get $RFFT_TW_RE) (local.get $kb))))
        (local.set $wi (v128.load (i32.add (global.get $RFFT_TW_IM) (local.get $kb))))

        ;; 2G = (zr+mr, zi-mi), 2H = (zi+mi, mr-zr)
        (local.set $gr (f32x4.add (local.get $zr) (local.get $mr)))
        (local.set $gi (f32x4.sub (local.get $zi) (local.get $mi)))
        (local.set $hr (f32x4.add (local.get $zi) (local.get $mi)))
        (local.set $hi (f32x4.sub (local.get $mr) (local.get $zr)))

        ;; 2T = W * 2H (split cmul, no shuffles)
        (local.set $tr (f32x4.sub (f32x4.mul (local.get $wr) (local.get $hr))
                                  (f32x4.mul (local.get $wi) (local.get $hi))))
        (local.set $ti (f32x4.add (f32x4.mul (local.get $wr) (local.get $hi))
                                  (f32x4.mul (local.get $wi) (local.get $hr))))

        ;; X[k..k+3] = (G + T), interleave and store at byte 8k
        (local.set $xr (f32x4.mul (local.get $half) (f32x4.add (local.get $gr) (local.get $tr))))
        (local.set $xi (f32x4.mul (local.get $half) (f32x4.add (local.get $gi) (local.get $ti))))
        (v128.store (i32.shl (local.get $k) (i32.const 3))
          (i8x16.shuffle 0 1 2 3 16 17 18 19 4 5 6 7 20 21 22 23
            (local.get $xr) (local.get $xi)))
        (v128.store (i32.add (i32.shl (local.get $k) (i32.const 3)) (i32.const 16))
          (i8x16.shuffle 8 9 10 11 24 25 26 27 12 13 14 15 28 29 30 31
            (local.get $xr) (local.get $xi)))

        ;; X[M-k-3..M-k] = conj(G - T) reversed, store at byte 8(M-k-3)
        (local.set $xr (f32x4.mul (local.get $half) (f32x4.sub (local.get $gr) (local.get $tr))))
        (local.set $xi (f32x4.mul (local.get $half) (f32x4.sub (local.get $ti) (local.get $gi))))
        (v128.store (i32.shl (local.get $mrb) (i32.const 1))
          (i8x16.shuffle 12 13 14 15 28 29 30 31 8 9 10 11 24 25 26 27
            (local.get $xr) (local.get $xi)))
        (v128.store (i32.add (i32.shl (local.get $mrb) (i32.const 1)) (i32.const 16))
          (i8x16.shuffle 4 5 6 7 20 21 22 23 0 1 2 3 16 17 18 19
            (local.get $xr) (local.get $xi)))

        (local.set $k (i32.add (local.get $k) (i32.const 4)))
        (br $loop)
      )
    )

    ;; Nyquist bin
    (f32.store (i32.shl (local.get $m) (i32.const 3))
      (f32.sub (local.get $z0r) (local.get $z0i)))
    (f32.store (i32.add (i32.shl (local.get $m) (i32.const 3)) (i32.const 4)) (f32.const 0))
  )

  ;; Real FFT: n real f32 at offset 0 -> n/2+1 interleaved complex f32 at
  ;; offset 0. Requires n >= 32 (M = n/2 >= 16, the radix-4 core minimum).
  ;; Call precompute_rfft_twiddles_split(n) first.
  ;;
  ;; Structure (Experiment 59): the first stage of the M-point complex core
  ;; is fused with the even/odd deinterleave and reads the packed input at
  ;; offset 0 directly, writing to buffer B. Odd log2(M) sizes fuse a whole
  ;; radix-8 first stage (deinterleave + radix-2 + radix-4 in one pass).
  ;; The remaining stages ping-pong against A (even remainder: result
  ;; returns to B) or against C (odd remainder: result ends in C). Either
  ;; way the result avoids buffer A, so the post-process can stream the
  ;; interleaved spectrum over A with no copy-back pass anywhere.
  (func (export "rfft_split") (param $n i32)
    (local $m i32)
    (local $log2m i32)
    (local $rem i32)     ;; pipeline stages remaining after the fused one
    (local $s i32)
    (local $l i32)
    (local $tw i32)
    (local $pr i32)      ;; ping-pong partner (A or C), real plane
    (local $pi i32)      ;; partner imag plane
    (local $sr i32)

    (local.set $m (i32.shr_u (local.get $n) (i32.const 1)))
    (local.set $log2m (i32.ctz (local.get $m)))

    ;; Fused first stage: input at 0 -> buffer B
    (if (i32.and (local.get $log2m) (i32.const 1))
      (then
        ;; odd log2(m): fused radix-8, next radix-4 stage is l=8; skip the
        ;; table's l=2 entry (6*2 floats = 48 bytes)
        (call $stage_r8_first_fused
          (global.get $REAL_B_OFFSET) (global.get $IMAG_B_OFFSET) (local.get $m))
        (local.set $s (i32.shr_u (local.get $m) (i32.const 5)))
        (local.set $l (i32.const 8))
        (local.set $tw (i32.add (global.get $STAGE_TW_FWD) (i32.const 48)))
        (local.set $rem (i32.shr_u (i32.sub (local.get $log2m) (i32.const 3)) (i32.const 1))))
      (else
        ;; even log2(m): fused twiddle-free radix-4 (l=1), next is l=4;
        ;; skip the table's l=1 entry (6 floats = 24 bytes)
        (call $stage_r4_first_fused
          (global.get $REAL_B_OFFSET) (global.get $IMAG_B_OFFSET) (local.get $m))
        (local.set $s (i32.shr_u (local.get $m) (i32.const 4)))
        (local.set $l (i32.const 4))
        (local.set $tw (i32.add (global.get $STAGE_TW_FWD) (i32.const 24)))
        (local.set $rem (i32.sub (i32.shr_u (local.get $log2m) (i32.const 1)) (i32.const 1)))))

    ;; Partner so the last stage never writes to A: an even remainder
    ;; returns to B on its own; an odd remainder must end in C.
    (if (i32.and (local.get $rem) (i32.const 1))
      (then
        (local.set $pr (global.get $REAL_C_OFFSET))
        (local.set $pi (global.get $IMAG_C_OFFSET)))
      (else
        (local.set $pr (global.get $REAL_A_OFFSET))
        (local.set $pi (global.get $IMAG_A_OFFSET))))

    (local.set $sr (call $fft_r4_pipeline (local.get $m) (i32.const 0)
      (local.get $s) (local.get $l) (local.get $tw)
      (global.get $REAL_B_OFFSET) (global.get $IMAG_B_OFFSET)
      (local.get $pr) (local.get $pi)))

    (call $rfft_postprocess_split (local.get $m)
      (local.get $sr) (i32.add (local.get $sr) (i32.const 32768)))
  )

  ;; ============================================================
  ;; Inverse real FFT on the radix-4 split core (Experiment 60)
  ;; ============================================================

  ;; Split-format irfft pre-processing: reads the Hermitian spectrum X[0..M]
  ;; interleaved at offset 0 and writes the M-point sequence Z to split
  ;; planes dst_re/dst_im with the 1/M normalization folded in:
  ;;   G = (X[k] + conj(X[M-k]))/2         H = conj(W_N^k)*(X[k] - conj(X[M-k]))/2
  ;;   Z[k] = (G + i*H)/M                  Z[M-k] = (conj(G) + i*conj(H))/M
  ;; The vector loop runs k = 1, 5, ..., M/2-3 like the forward post-process:
  ;; forward blocks cover Z[1..M/2], mirrored blocks Z[M/2..M-1] (Z[M/2]
  ;; written twice with the same value). dst must not be buffer A - the loop
  ;; reads X from the A region. The only read/write overlap is X[M] at
  ;; N=16384, whose bytes coincide with dst_re[0]; it is read in the scalar
  ;; prologue before Z[0] is stored.
  (func $irfft_preprocess_split (param $m i32) (param $dst_re i32) (param $dst_im i32)
    (local $k i32)       ;; element index, steps by 4
    (local $kb i32)      ;; k * 4 (plane byte offset)
    (local $kend i32)
    (local $mrb i32)     ;; (m-k-3) * 4 (mirrored plane byte offset)
    (local $x0 f32) (local $xm f32)
    (local $sc f32)
    (local $scale v128)
    (local $v0 v128) (local $v1 v128)
    (local $ar v128) (local $ai v128)
    (local $br v128) (local $bi v128)
    (local $gr v128) (local $gi v128)
    (local $ur v128) (local $ui v128)
    (local $hr v128) (local $hi v128)
    (local $wr v128) (local $wi v128)
    (local $zr v128) (local $zi v128)

    ;; 0.5/M: the /2 from the G/H halving plus the 1/M inverse normalization
    (local.set $sc (f32.div (f32.const 0.5) (f32.convert_i32_u (local.get $m))))
    (local.set $scale (f32x4.splat (local.get $sc)))

    ;; DC/Nyquist prologue (imaginary parts are 0 for a valid real spectrum):
    ;; Z[0] = ((X0 + XM) + i*(X0 - XM)) * 0.5/M
    (local.set $x0 (f32.load (i32.const 0)))
    (local.set $xm (f32.load (i32.shl (local.get $m) (i32.const 3))))
    (f32.store (local.get $dst_re)
      (f32.mul (f32.add (local.get $x0) (local.get $xm)) (local.get $sc)))
    (f32.store (local.get $dst_im)
      (f32.mul (f32.sub (local.get $x0) (local.get $xm)) (local.get $sc)))

    (local.set $kend (i32.sub (i32.shr_u (local.get $m) (i32.const 1)) (i32.const 3)))
    (local.set $k (i32.const 1))
    (block $done
      (loop $loop
        (br_if $done (i32.gt_u (local.get $k) (local.get $kend)))

        (local.set $kb (i32.shl (local.get $k) (i32.const 2)))
        (local.set $mrb (i32.shl (i32.sub (i32.sub (local.get $m) (local.get $k)) (i32.const 3))
                                 (i32.const 2)))

        ;; X[k..k+3] interleaved at byte 8k, deinterleaved on load
        (local.set $v0 (v128.load (i32.shl (local.get $kb) (i32.const 1))))
        (local.set $v1 (v128.load (i32.add (i32.shl (local.get $kb) (i32.const 1)) (i32.const 16))))
        (local.set $ar (i8x16.shuffle 0 1 2 3 8 9 10 11 16 17 18 19 24 25 26 27
          (local.get $v0) (local.get $v1)))
        (local.set $ai (i8x16.shuffle 4 5 6 7 12 13 14 15 20 21 22 23 28 29 30 31
          (local.get $v0) (local.get $v1)))

        ;; X[M-k-3..M-k] interleaved at byte 8(M-k-3), deinterleave + lane-reverse
        (local.set $v0 (v128.load (i32.shl (local.get $mrb) (i32.const 1))))
        (local.set $v1 (v128.load (i32.add (i32.shl (local.get $mrb) (i32.const 1)) (i32.const 16))))
        (local.set $br (i8x16.shuffle 24 25 26 27 16 17 18 19 8 9 10 11 0 1 2 3
          (local.get $v0) (local.get $v1)))
        (local.set $bi (i8x16.shuffle 28 29 30 31 20 21 22 23 12 13 14 15 4 5 6 7
          (local.get $v0) (local.get $v1)))

        ;; 4 consecutive twiddles W_N^(k..k+3), contiguous split loads
        (local.set $wr (v128.load (i32.add (global.get $RFFT_TW_RE) (local.get $kb))))
        (local.set $wi (v128.load (i32.add (global.get $RFFT_TW_IM) (local.get $kb))))

        ;; 2G = X[k] + conj(X[M-k]), 2W^kH = X[k] - conj(X[M-k])
        (local.set $gr (f32x4.add (local.get $ar) (local.get $br)))
        (local.set $gi (f32x4.sub (local.get $ai) (local.get $bi)))
        (local.set $ur (f32x4.sub (local.get $ar) (local.get $br)))
        (local.set $ui (f32x4.add (local.get $ai) (local.get $bi)))

        ;; 2H = conj(W) * (2W^kH) (split cmul, no shuffles)
        (local.set $hr (f32x4.add (f32x4.mul (local.get $wr) (local.get $ur))
                                  (f32x4.mul (local.get $wi) (local.get $ui))))
        (local.set $hi (f32x4.sub (f32x4.mul (local.get $wr) (local.get $ui))
                                  (f32x4.mul (local.get $wi) (local.get $ur))))

        ;; Z[k..k+3] = (2G + i*2H) * 0.5/M
        (local.set $zr (f32x4.mul (local.get $scale) (f32x4.sub (local.get $gr) (local.get $hi))))
        (local.set $zi (f32x4.mul (local.get $scale) (f32x4.add (local.get $gi) (local.get $hr))))
        (v128.store (i32.add (local.get $dst_re) (local.get $kb)) (local.get $zr))
        (v128.store (i32.add (local.get $dst_im) (local.get $kb)) (local.get $zi))

        ;; Z[M-k-3..M-k] = (conj(2G) + i*conj(2H)) * 0.5/M, lane-reversed
        (local.set $zr (f32x4.mul (local.get $scale) (f32x4.add (local.get $gr) (local.get $hi))))
        (local.set $zi (f32x4.mul (local.get $scale) (f32x4.sub (local.get $hr) (local.get $gi))))
        (v128.store (i32.add (local.get $dst_re) (local.get $mrb))
          (i8x16.shuffle 12 13 14 15 8 9 10 11 4 5 6 7 0 1 2 3
            (local.get $zr) (local.get $zr)))
        (v128.store (i32.add (local.get $dst_im) (local.get $mrb))
          (i8x16.shuffle 12 13 14 15 8 9 10 11 4 5 6 7 0 1 2 3
            (local.get $zi) (local.get $zi)))

        (local.set $k (i32.add (local.get $k) (i32.const 4)))
        (br $loop)
      )
    )
  )

  ;; Final inverse s=1 radix-4 stage fused with the reinterleave: identical
  ;; loads/transpose/butterfly to $stage_r4_s1 with inv=1, but each output
  ;; quarter is interleaved (re,im) on store, streaming the time-domain
  ;; signal directly to offset 0 - interleaved z IS the packed real output
  ;; (z[j] = x[2j] + i*x[2j+1]). Replaces a whole reinterleave pass.
  ;; Requires l >= 4 (i.e. n >= 16).
  (func $stage_r4_s1_inv_fused
    (param $src_re i32) (param $src_im i32)
    (param $l i32) (param $tw i32) (param $n i32)

    (local $j i32)
    (local $n4b i32)
    (local $lb i32)
    (local $p i32)
    (local $q i32)

    (local $v0 v128) (local $v1 v128) (local $v2 v128) (local $v3 v128)
    (local $p0 v128) (local $p1 v128) (local $p2 v128) (local $p3 v128)
    (local $w1r v128) (local $w1i v128)
    (local $w2r v128) (local $w2i v128)
    (local $w3r v128) (local $w3i v128)
    (local $ar v128) (local $ai v128)
    (local $br v128) (local $bi v128)
    (local $cr v128) (local $ci v128)
    (local $dr v128) (local $di v128)
    (local $wcr v128) (local $wci v128)
    (local $wbr v128) (local $wbi v128)
    (local $wdr v128) (local $wdi v128)
    (local $t0r v128) (local $t0i v128)
    (local $t1r v128) (local $t1i v128)
    (local $t2r v128) (local $t2i v128)
    (local $t3r v128) (local $t3i v128)
    (local $xr v128) (local $xi v128)

    (local.set $n4b (local.get $n))
    (local.set $lb (i32.shl (local.get $l) (i32.const 2)))

    (local.set $j (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $j) (local.get $l)))

        ;; ---- real plane: load 16 consecutive floats, transpose 4x4 ----
        (local.set $p (i32.add (local.get $src_re) (i32.shl (local.get $j) (i32.const 4))))
        (local.set $v0 (v128.load (local.get $p)))
        (local.set $v1 (v128.load (i32.add (local.get $p) (i32.const 16))))
        (local.set $v2 (v128.load (i32.add (local.get $p) (i32.const 32))))
        (local.set $v3 (v128.load (i32.add (local.get $p) (i32.const 48))))

        (local.set $p0 (i8x16.shuffle 0 1 2 3 16 17 18 19 8 9 10 11 24 25 26 27
                                      (local.get $v0) (local.get $v1)))
        (local.set $p2 (i8x16.shuffle 4 5 6 7 20 21 22 23 12 13 14 15 28 29 30 31
                                      (local.get $v0) (local.get $v1)))
        (local.set $p1 (i8x16.shuffle 0 1 2 3 16 17 18 19 8 9 10 11 24 25 26 27
                                      (local.get $v2) (local.get $v3)))
        (local.set $p3 (i8x16.shuffle 4 5 6 7 20 21 22 23 12 13 14 15 28 29 30 31
                                      (local.get $v2) (local.get $v3)))

        (local.set $ar (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
                                      (local.get $p0) (local.get $p1)))
        (local.set $cr (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31
                                      (local.get $p0) (local.get $p1)))
        (local.set $br (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
                                      (local.get $p2) (local.get $p3)))
        (local.set $dr (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31
                                      (local.get $p2) (local.get $p3)))

        ;; ---- imag plane ----
        (local.set $p (i32.add (local.get $src_im) (i32.shl (local.get $j) (i32.const 4))))
        (local.set $v0 (v128.load (local.get $p)))
        (local.set $v1 (v128.load (i32.add (local.get $p) (i32.const 16))))
        (local.set $v2 (v128.load (i32.add (local.get $p) (i32.const 32))))
        (local.set $v3 (v128.load (i32.add (local.get $p) (i32.const 48))))

        (local.set $p0 (i8x16.shuffle 0 1 2 3 16 17 18 19 8 9 10 11 24 25 26 27
                                      (local.get $v0) (local.get $v1)))
        (local.set $p2 (i8x16.shuffle 4 5 6 7 20 21 22 23 12 13 14 15 28 29 30 31
                                      (local.get $v0) (local.get $v1)))
        (local.set $p1 (i8x16.shuffle 0 1 2 3 16 17 18 19 8 9 10 11 24 25 26 27
                                      (local.get $v2) (local.get $v3)))
        (local.set $p3 (i8x16.shuffle 4 5 6 7 20 21 22 23 12 13 14 15 28 29 30 31
                                      (local.get $v2) (local.get $v3)))

        (local.set $ai (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
                                      (local.get $p0) (local.get $p1)))
        (local.set $ci (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31
                                      (local.get $p0) (local.get $p1)))
        (local.set $bi (i8x16.shuffle 0 1 2 3 4 5 6 7 16 17 18 19 20 21 22 23
                                      (local.get $p2) (local.get $p3)))
        (local.set $di (i8x16.shuffle 8 9 10 11 12 13 14 15 24 25 26 27 28 29 30 31
                                      (local.get $p2) (local.get $p3)))

        ;; ---- 4 consecutive twiddle triples ----
        (local.set $p (i32.add (local.get $tw) (i32.shl (local.get $j) (i32.const 2))))
        (local.set $w1r (v128.load (local.get $p)))
        (local.set $p (i32.add (local.get $p) (local.get $lb)))
        (local.set $w1i (v128.load (local.get $p)))
        (local.set $p (i32.add (local.get $p) (local.get $lb)))
        (local.set $w2r (v128.load (local.get $p)))
        (local.set $p (i32.add (local.get $p) (local.get $lb)))
        (local.set $w2i (v128.load (local.get $p)))
        (local.set $p (i32.add (local.get $p) (local.get $lb)))
        (local.set $w3r (v128.load (local.get $p)))
        (local.set $p (i32.add (local.get $p) (local.get $lb)))
        (local.set $w3i (v128.load (local.get $p)))

        ;; ---- same butterfly math as the generic stage ----
        (local.set $wcr (f32x4.sub (f32x4.mul (local.get $w2r) (local.get $cr))
                                   (f32x4.mul (local.get $w2i) (local.get $ci))))
        (local.set $wci (f32x4.add (f32x4.mul (local.get $w2r) (local.get $ci))
                                   (f32x4.mul (local.get $w2i) (local.get $cr))))
        (local.set $wbr (f32x4.sub (f32x4.mul (local.get $w1r) (local.get $br))
                                   (f32x4.mul (local.get $w1i) (local.get $bi))))
        (local.set $wbi (f32x4.add (f32x4.mul (local.get $w1r) (local.get $bi))
                                   (f32x4.mul (local.get $w1i) (local.get $br))))
        (local.set $wdr (f32x4.sub (f32x4.mul (local.get $w3r) (local.get $dr))
                                   (f32x4.mul (local.get $w3i) (local.get $di))))
        (local.set $wdi (f32x4.add (f32x4.mul (local.get $w3r) (local.get $di))
                                   (f32x4.mul (local.get $w3i) (local.get $dr))))

        (local.set $t0r (f32x4.add (local.get $ar) (local.get $wcr)))
        (local.set $t0i (f32x4.add (local.get $ai) (local.get $wci)))
        (local.set $t1r (f32x4.sub (local.get $ar) (local.get $wcr)))
        (local.set $t1i (f32x4.sub (local.get $ai) (local.get $wci)))
        (local.set $t2r (f32x4.add (local.get $wbr) (local.get $wdr)))
        (local.set $t2i (f32x4.add (local.get $wbi) (local.get $wdi)))
        (local.set $t3r (f32x4.sub (local.get $wbr) (local.get $wdr)))
        (local.set $t3i (f32x4.sub (local.get $wbi) (local.get $wdi)))

        ;; outputs q = j..j+3 in each quarter block, interleaved at byte 2*q
        (local.set $q (i32.shl (local.get $j) (i32.const 2)))

        ;; quarter 0: t0 + t2
        (local.set $xr (f32x4.add (local.get $t0r) (local.get $t2r)))
        (local.set $xi (f32x4.add (local.get $t0i) (local.get $t2i)))
        (local.set $p (i32.shl (local.get $q) (i32.const 1)))
        (v128.store (local.get $p)
          (i8x16.shuffle 0 1 2 3 16 17 18 19 4 5 6 7 20 21 22 23
            (local.get $xr) (local.get $xi)))
        (v128.store (i32.add (local.get $p) (i32.const 16))
          (i8x16.shuffle 8 9 10 11 24 25 26 27 12 13 14 15 28 29 30 31
            (local.get $xr) (local.get $xi)))

        ;; quarter 1 (inverse rotation): t1 + i*t3 = (t1r - t3i, t1i + t3r)
        (local.set $xr (f32x4.sub (local.get $t1r) (local.get $t3i)))
        (local.set $xi (f32x4.add (local.get $t1i) (local.get $t3r)))
        (local.set $p (i32.shl (i32.add (local.get $q) (local.get $n4b)) (i32.const 1)))
        (v128.store (local.get $p)
          (i8x16.shuffle 0 1 2 3 16 17 18 19 4 5 6 7 20 21 22 23
            (local.get $xr) (local.get $xi)))
        (v128.store (i32.add (local.get $p) (i32.const 16))
          (i8x16.shuffle 8 9 10 11 24 25 26 27 12 13 14 15 28 29 30 31
            (local.get $xr) (local.get $xi)))

        ;; quarter 2: t0 - t2
        (local.set $xr (f32x4.sub (local.get $t0r) (local.get $t2r)))
        (local.set $xi (f32x4.sub (local.get $t0i) (local.get $t2i)))
        (local.set $p (i32.shl (i32.add (local.get $q) (i32.shl (local.get $n4b) (i32.const 1)))
                               (i32.const 1)))
        (v128.store (local.get $p)
          (i8x16.shuffle 0 1 2 3 16 17 18 19 4 5 6 7 20 21 22 23
            (local.get $xr) (local.get $xi)))
        (v128.store (i32.add (local.get $p) (i32.const 16))
          (i8x16.shuffle 8 9 10 11 24 25 26 27 12 13 14 15 28 29 30 31
            (local.get $xr) (local.get $xi)))

        ;; quarter 3 (inverse rotation): t1 - i*t3 = (t1r + t3i, t1i - t3r)
        (local.set $xr (f32x4.add (local.get $t1r) (local.get $t3i)))
        (local.set $xi (f32x4.sub (local.get $t1i) (local.get $t3r)))
        (local.set $p (i32.shl (i32.add (local.get $q) (i32.mul (local.get $n4b) (i32.const 3)))
                               (i32.const 1)))
        (v128.store (local.get $p)
          (i8x16.shuffle 0 1 2 3 16 17 18 19 4 5 6 7 20 21 22 23
            (local.get $xr) (local.get $xi)))
        (v128.store (i32.add (local.get $p) (i32.const 16))
          (i8x16.shuffle 8 9 10 11 24 25 26 27 12 13 14 15 28 29 30 31
            (local.get $xr) (local.get $xi)))

        (local.set $j (i32.add (local.get $j) (i32.const 4)))
        (br $loop)
      )
    )
  )

  ;; Inverse real FFT: n/2+1 interleaved complex f32 (Hermitian spectrum) at
  ;; offset 0 -> n real f32 at offset 0, fully normalized so that
  ;; irfft_split(rfft_split(x)) = x. Requires n >= 32. Call
  ;; precompute_rfft_twiddles_split(n) first.
  ;;
  ;; Structure (Experiment 60, mirror of rfft_split): one pre-process pass
  ;; converts X to the scaled M = n/2 point spectrum Z in split planes at B;
  ;; the inverse radix-4 pipeline ping-pongs B<->C, never touching A (which
  ;; the pre-process reads); the final s=1 stage is fused with the
  ;; reinterleave and streams the real signal over A. Total memory passes
  ;; match the forward transform exactly.
  (func (export "irfft_split") (param $n i32)
    (local $m i32)
    (local $s i32)
    (local $l i32)
    (local $tw i32)
    (local $sr i32) (local $si i32)
    (local $dr i32) (local $di i32)
    (local $tmp i32)

    (local.set $m (i32.shr_u (local.get $n) (i32.const 1)))

    ;; Pre-process: interleaved X in A -> scaled split Z in B
    (call $irfft_preprocess_split (local.get $m)
      (global.get $REAL_B_OFFSET) (global.get $IMAG_B_OFFSET))

    (local.set $sr (global.get $REAL_B_OFFSET))
    (local.set $si (global.get $IMAG_B_OFFSET))
    (local.set $dr (global.get $REAL_C_OFFSET))
    (local.set $di (global.get $IMAG_C_OFFSET))
    (local.set $tw (global.get $STAGE_TW_INV))

    (if (i32.and (i32.ctz (local.get $m)) (i32.const 1))
      (then
        ;; odd log2(m): twiddle-free radix-2 stage first (B -> C)
        (call $stage_r2_lead (local.get $sr) (local.get $si)
                             (local.get $dr) (local.get $di) (local.get $m))
        (local.set $tmp (local.get $sr)) (local.set $sr (local.get $dr)) (local.set $dr (local.get $tmp))
        (local.set $tmp (local.get $si)) (local.set $si (local.get $di)) (local.set $di (local.get $tmp))
        (local.set $s (i32.shr_u (local.get $m) (i32.const 3)))
        (local.set $l (i32.const 2)))
      (else
        (local.set $s (i32.shr_u (local.get $m) (i32.const 2)))
        (local.set $l (i32.const 1))))

    ;; Generic inverse stages, ping-ponging B<->C, until s = 1 remains
    (block $done
      (loop $stages
        (br_if $done (i32.lt_u (local.get $s) (i32.const 4)))
        (call $stage_r4_generic (local.get $sr) (local.get $si)
                                (local.get $dr) (local.get $di)
                                (local.get $s) (local.get $l)
                                (local.get $tw) (local.get $m) (i32.const 1))
        (local.set $tmp (local.get $sr)) (local.set $sr (local.get $dr)) (local.set $dr (local.get $tmp))
        (local.set $tmp (local.get $si)) (local.set $si (local.get $di)) (local.set $di (local.get $tmp))
        (local.set $tw (i32.add (local.get $tw) (i32.mul (local.get $l) (i32.const 24))))
        (local.set $l (i32.shl (local.get $l) (i32.const 2)))
        (local.set $s (i32.shr_u (local.get $s) (i32.const 2)))
        (br $stages)
      )
    )

    ;; Fused final stage: split planes -> interleaved real signal at offset 0
    (call $stage_r4_s1_inv_fused (local.get $sr) (local.get $si)
      (local.get $l) (local.get $tw) (local.get $m))
  )

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

    ;; n >= 16: radix-4 split-format core (Experiment 58)
    (if (i32.ge_u (local.get $n) (i32.const 16))
      (then
        (call $fft_r4_core (local.get $n) (global.get $STAGE_TW_FWD) (i32.const 0))
        (return)
      )
    )

    ;; n = 8 fallback: radix-2 Stockham path
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

  ;; For n >= 16: native inverse via conjugated radix-4 stage tables plus a
  ;; single 1/N scale pass. For small n: IFFT(x) = (1/N) * conj(FFT(conj(x))).
  (func (export "ifft_split") (param $n i32)
    (local $i i32)
    (local $n_bytes i32)
    (local $scale v128)
    (local $addr i32)

    (local.set $n_bytes (i32.shl (local.get $n) (i32.const 2)))

    (if (i32.ge_u (local.get $n) (i32.const 16))
      (then
        (call $fft_r4_core (local.get $n) (global.get $STAGE_TW_INV) (i32.const 1))

        ;; Scale by 1/N - SIMD 4 elements at a time
        (local.set $scale (f32x4.splat (f32.div (f32.const 1.0) (f32.convert_i32_u (local.get $n)))))
        (local.set $i (i32.const 0))
        (block $scale_done
          (loop $scale_loop
            (br_if $scale_done (i32.ge_u (local.get $i) (local.get $n_bytes)))
            (local.set $addr (i32.add (global.get $REAL_A_OFFSET) (local.get $i)))
            (v128.store (local.get $addr) (f32x4.mul (v128.load (local.get $addr)) (local.get $scale)))
            (local.set $addr (i32.add (global.get $IMAG_A_OFFSET) (local.get $i)))
            (v128.store (local.get $addr) (f32x4.mul (v128.load (local.get $addr)) (local.get $scale)))
            (local.set $i (i32.add (local.get $i) (i32.const 16)))
            (br $scale_loop)
          )
        )
        (return)
      )
    )

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
