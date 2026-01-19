  ;; High-performance Radix-4 FFT with SIMD
  ;;
  ;; Uses base-4 digit reversal permutation for pure Radix-4 structure
  ;; Falls back to Radix-2 for final stage if N is not a power of 4
  ;;
  ;; Memory layout:
  ;;   [0, N*16): Complex data [f64 real, f64 imag] per element
  ;;   [131072, ...): Precomputed twiddle factors

  (global $TWIDDLE_BASE i32 (i32.const 131072))
  (global $NEG_TWO_PI f64 (f64.const -6.283185307179586))
  (global $SIGN_MASK v128 (v128.const i64x2 0x8000000000000000 0x0000000000000000))

  ;; Base-4 digit reversal: reverse the base-4 digits of x
  ;; numDigits = log4(N) = log2(N)/2
  (func $digit_reverse4 (export "digit_reverse4") (param $x i32) (param $num_digits i32) (result i32)
    (local $result i32)
    (local $i i32)

    (local.set $result (i32.const 0))
    (local.set $i (i32.const 0))

    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $i) (local.get $num_digits)))

        ;; result = (result << 2) | (x & 3)
        (local.set $result
          (i32.or
            (i32.shl (local.get $result) (i32.const 2))
            (i32.and (local.get $x) (i32.const 3))
          )
        )
        ;; x >>= 2
        (local.set $x (i32.shr_u (local.get $x) (i32.const 2)))

        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)
      )
    )

    (local.get $result)
  )

  ;; Precompute twiddle factors W_N^k for k = 0..N-1
  ;; We need more twiddles for Radix-4 (up to W^(3k))
  (func $precompute_twiddles (export "precompute_twiddles") (param $n i32)
    (local $k i32)
    (local $angle f64)
    (local $addr i32)

    (local.set $k (i32.const 0))
    (local.set $addr (global.get $TWIDDLE_BASE))

    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $k) (local.get $n)))

        (local.set $angle
          (f64.div
            (f64.mul (f64.convert_i32_u (local.get $k)) (global.get $NEG_TWO_PI))
            (f64.convert_i32_u (local.get $n))
          )
        )

        (f64.store (local.get $addr) (call $js_cos (local.get $angle)))
        (f64.store offset=8 (local.get $addr) (call $js_sin (local.get $angle)))

        (local.set $addr (i32.add (local.get $addr) (i32.const 16)))
        (local.set $k (i32.add (local.get $k) (i32.const 1)))
        (br $loop)
      )
    )
  )

  ;; SIMD complex multiply
  (func $simd_cmul (param $a v128) (param $b v128) (result v128)
    (local $ar v128) (local $ai v128) (local $bd v128)

    (local.set $ar (f64x2.splat (f64x2.extract_lane 0 (local.get $a))))
    (local.set $ai (f64x2.splat (f64x2.extract_lane 1 (local.get $a))))
    (local.set $bd (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7
                                  (local.get $b) (local.get $b)))

    (f64x2.add
      (f64x2.mul (local.get $ar) (local.get $b))
      (v128.xor (f64x2.mul (local.get $ai) (local.get $bd)) (global.get $SIGN_MASK))
    )
  )

  ;; Multiply by -j: [a,b] -> [b, -a]
  (func $mul_neg_j (param $v v128) (result v128)
    (f64x2.mul
      (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $v) (local.get $v))
      (v128.const f64x2 1.0 -1.0)
    )
  )

  ;; Multiply by +j: [a,b] -> [-b, a]
  (func $mul_pos_j (param $v v128) (result v128)
    (f64x2.mul
      (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $v) (local.get $v))
      (v128.const f64x2 -1.0 1.0)
    )
  )

  ;; Digit-reversal permutation for Radix-4
  (func $digit_reverse_permute (param $n i32) (param $num_digits i32)
    (local $i i32) (local $j i32)
    (local $i_addr i32) (local $j_addr i32)
    (local $temp v128)

    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $i) (local.get $n)))

        (local.set $j (call $digit_reverse4 (local.get $i) (local.get $num_digits)))

        (if (i32.lt_u (local.get $i) (local.get $j))
          (then
            (local.set $i_addr (i32.shl (local.get $i) (i32.const 4)))
            (local.set $j_addr (i32.shl (local.get $j) (i32.const 4)))
            (local.set $temp (v128.load (local.get $i_addr)))
            (v128.store (local.get $i_addr) (v128.load (local.get $j_addr)))
            (v128.store (local.get $j_addr) (local.get $temp))
          )
        )

        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)
      )
    )
  )

  ;; Bit-reversal permutation (for Radix-2 fallback)
  (func $bit_reverse_permute (param $n i32) (param $log2n i32)
    (local $i i32) (local $j i32)
    (local $i_addr i32) (local $j_addr i32)
    (local $temp v128)

    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $i) (local.get $n)))

        (local.set $j (call $reverse_bits (local.get $i) (local.get $log2n)))

        (if (i32.lt_u (local.get $i) (local.get $j))
          (then
            (local.set $i_addr (i32.shl (local.get $i) (i32.const 4)))
            (local.set $j_addr (i32.shl (local.get $j) (i32.const 4)))
            (local.set $temp (v128.load (local.get $i_addr)))
            (v128.store (local.get $i_addr) (v128.load (local.get $j_addr)))
            (v128.store (local.get $j_addr) (local.get $temp))
          )
        )

        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)
      )
    )
  )

  ;; Radix-4 FFT for powers of 4 (N = 4, 16, 64, 256, ...)
  (func $fft_radix4_pure (param $n i32) (param $log4n i32)
    (local $stage i32)
    (local $size i32)
    (local $quarter i32)
    (local $group_start i32)
    (local $k i32)
    (local $tw_base i32)
    (local $i0 i32) (local $i1 i32) (local $i2 i32) (local $i3 i32)
    (local $x0 v128) (local $x1 v128) (local $x2 v128) (local $x3 v128)
    (local $w1 v128) (local $w2 v128) (local $w3 v128)
    (local $t0 v128) (local $t1 v128) (local $t2 v128) (local $t3 v128)

    ;; Digit-reversal permutation
    (call $digit_reverse_permute (local.get $n) (local.get $log4n))

    ;; Process stages: size = 4, 16, 64, ...
    (local.set $size (i32.const 4))
    (local.set $stage (i32.const 0))

    (block $done_stages
      (loop $stage_loop
        (br_if $done_stages (i32.gt_u (local.get $size) (local.get $n)))

        (local.set $quarter (i32.shr_u (local.get $size) (i32.const 2)))

        ;; For each group of 'size' elements
        (local.set $group_start (i32.const 0))
        (block $done_groups
          (loop $group_loop
            (br_if $done_groups (i32.ge_u (local.get $group_start) (local.get $n)))

            ;; For each butterfly position k in [0, quarter)
            (local.set $k (i32.const 0))
            (block $done_k
              (loop $k_loop
                (br_if $done_k (i32.ge_u (local.get $k) (local.get $quarter)))

                ;; Element addresses
                (local.set $i0 (i32.shl (i32.add (local.get $group_start) (local.get $k)) (i32.const 4)))
                (local.set $i1 (i32.add (local.get $i0) (i32.shl (local.get $quarter) (i32.const 4))))
                (local.set $i2 (i32.add (local.get $i1) (i32.shl (local.get $quarter) (i32.const 4))))
                (local.set $i3 (i32.add (local.get $i2) (i32.shl (local.get $quarter) (i32.const 4))))

                ;; Load elements
                (local.set $x0 (v128.load (local.get $i0)))
                (local.set $x1 (v128.load (local.get $i1)))
                (local.set $x2 (v128.load (local.get $i2)))
                (local.set $x3 (v128.load (local.get $i3)))

                ;; Apply twiddle factors (except first stage where all twiddles are 1)
                (if (i32.gt_u (local.get $size) (i32.const 4))
                  (then
                    ;; Twiddle indices: k*N/size, 2*k*N/size, 3*k*N/size
                    (local.set $tw_base
                      (i32.add
                        (global.get $TWIDDLE_BASE)
                        (i32.shl
                          (i32.div_u (i32.mul (local.get $k) (local.get $n)) (local.get $size))
                          (i32.const 4)
                        )
                      )
                    )
                    (local.set $w1 (v128.load (local.get $tw_base)))

                    (local.set $tw_base
                      (i32.add
                        (global.get $TWIDDLE_BASE)
                        (i32.shl
                          (i32.div_u (i32.mul (i32.shl (local.get $k) (i32.const 1)) (local.get $n)) (local.get $size))
                          (i32.const 4)
                        )
                      )
                    )
                    (local.set $w2 (v128.load (local.get $tw_base)))

                    (local.set $tw_base
                      (i32.add
                        (global.get $TWIDDLE_BASE)
                        (i32.shl
                          (i32.div_u (i32.mul (i32.mul (local.get $k) (i32.const 3)) (local.get $n)) (local.get $size))
                          (i32.const 4)
                        )
                      )
                    )
                    (local.set $w3 (v128.load (local.get $tw_base)))

                    ;; x1 *= w1, x2 *= w2, x3 *= w3
                    (local.set $x1 (call $simd_cmul (local.get $x1) (local.get $w1)))
                    (local.set $x2 (call $simd_cmul (local.get $x2) (local.get $w2)))
                    (local.set $x3 (call $simd_cmul (local.get $x3) (local.get $w3)))
                  )
                )

                ;; Radix-4 DIT butterfly
                ;; t0 = x0 + x2, t1 = x0 - x2
                ;; t2 = x1 + x3, t3 = x1 - x3
                (local.set $t0 (f64x2.add (local.get $x0) (local.get $x2)))
                (local.set $t1 (f64x2.sub (local.get $x0) (local.get $x2)))
                (local.set $t2 (f64x2.add (local.get $x1) (local.get $x3)))
                (local.set $t3 (f64x2.sub (local.get $x1) (local.get $x3)))

                ;; y0 = t0 + t2
                ;; y1 = t1 - j*t3 (multiply t3 by -j)
                ;; y2 = t0 - t2
                ;; y3 = t1 + j*t3 (multiply t3 by +j)
                (v128.store (local.get $i0) (f64x2.add (local.get $t0) (local.get $t2)))
                (v128.store (local.get $i1) (f64x2.add (local.get $t1) (call $mul_neg_j (local.get $t3))))
                (v128.store (local.get $i2) (f64x2.sub (local.get $t0) (local.get $t2)))
                (v128.store (local.get $i3) (f64x2.add (local.get $t1) (call $mul_pos_j (local.get $t3))))

                (local.set $k (i32.add (local.get $k) (i32.const 1)))
                (br $k_loop)
              )
            )

            (local.set $group_start (i32.add (local.get $group_start) (local.get $size)))
            (br $group_loop)
          )
        )

        (local.set $size (i32.shl (local.get $size) (i32.const 2)))
        (local.set $stage (i32.add (local.get $stage) (i32.const 1)))
        (br $stage_loop)
      )
    )
  )

  ;; Mixed Radix-4/Radix-2 FFT for any power of 2
  ;; Uses bit-reversal and combines Radix-4 stages with optional Radix-2 cleanup
  ;;
  ;; Key insight: bit-reversal creates a consistent pattern where at each radix-4 stage,
  ;; the sub-DFT groups are arranged as G_0, G_2, G_1, G_3 instead of G_0, G_1, G_2, G_3.
  ;; We compensate by swapping load positions at quarter and 2*quarter for ALL stages.
  (func $fft_radix4_mixed (param $n i32) (param $log2n i32)
    (local $size i32)
    (local $half i32)
    (local $quarter i32)
    (local $group_start i32)
    (local $k i32)
    (local $tw_step i32)
    (local $tw_addr i32)
    (local $i0 i32) (local $i1 i32) (local $i2 i32) (local $i3 i32)
    (local $x0 v128) (local $x1 v128) (local $x2 v128) (local $x3 v128)
    (local $w1 v128) (local $w2 v128) (local $w3 v128)
    (local $t0 v128) (local $t1 v128) (local $t2 v128) (local $t3 v128)
    (local $even v128) (local $odd v128) (local $tw v128) (local $temp v128)

    ;; Standard bit-reversal permutation
    (call $bit_reverse_permute (local.get $n) (local.get $log2n))

    ;; If log2n is odd, start with one Radix-2 stage
    (if (i32.and (local.get $log2n) (i32.const 1))
      (then
        ;; Radix-2 stage with size=2
        (local.set $group_start (i32.const 0))
        (block $done_r2
          (loop $r2_loop
            (br_if $done_r2 (i32.ge_u (local.get $group_start) (local.get $n)))

            (local.set $i0 (i32.shl (local.get $group_start) (i32.const 4)))
            (local.set $i1 (i32.add (local.get $i0) (i32.const 16)))

            (local.set $x0 (v128.load (local.get $i0)))
            (local.set $x1 (v128.load (local.get $i1)))

            (v128.store (local.get $i0) (f64x2.add (local.get $x0) (local.get $x1)))
            (v128.store (local.get $i1) (f64x2.sub (local.get $x0) (local.get $x1)))

            (local.set $group_start (i32.add (local.get $group_start) (i32.const 2)))
            (br $r2_loop)
          )
        )
        ;; Start Radix-4 stages from size=8
        (local.set $size (i32.const 8))
      )
      (else
        ;; Start Radix-4 stages from size=4
        (local.set $size (i32.const 4))
      )
    )

    ;; Radix-4 stages with swapped addressing to compensate for bit-reversal order
    ;; Bit-reversal creates arrangement: G_0, G_2, G_1, G_3 at positions 0, quarter, 2*quarter, 3*quarter
    ;; We load from 0, 2*quarter, quarter, 3*quarter to get G_0, G_1, G_2, G_3 order
    (block $done_r4
      (loop $r4_loop
        (br_if $done_r4 (i32.gt_u (local.get $size) (local.get $n)))

        (local.set $quarter (i32.shr_u (local.get $size) (i32.const 2)))
        (local.set $tw_step (i32.div_u (local.get $n) (local.get $size)))

        (local.set $group_start (i32.const 0))
        (block $done_groups
          (loop $group_loop
            (br_if $done_groups (i32.ge_u (local.get $group_start) (local.get $n)))

            (local.set $k (i32.const 0))
            (block $done_k
              (loop $k_loop
                (br_if $done_k (i32.ge_u (local.get $k) (local.get $quarter)))

                ;; Element addresses with swap: i1 and i2 are swapped to correct for bit-reversal order
                (local.set $i0 (i32.shl (i32.add (local.get $group_start) (local.get $k)) (i32.const 4)))
                (local.set $i1 (i32.add (local.get $i0) (i32.shl (local.get $quarter) (i32.const 5)))) ;; +2*quarter*16 (swapped)
                (local.set $i2 (i32.add (local.get $i0) (i32.shl (local.get $quarter) (i32.const 4)))) ;; +quarter*16 (swapped)
                (local.set $i3 (i32.add (local.get $i0) (i32.mul (local.get $quarter) (i32.const 48)))) ;; +3*quarter*16

                ;; Load elements (now in correct G_0, G_1, G_2, G_3 order)
                (local.set $x0 (v128.load (local.get $i0)))
                (local.set $x1 (v128.load (local.get $i1)))
                (local.set $x2 (v128.load (local.get $i2)))
                (local.set $x3 (v128.load (local.get $i3)))

                ;; Twiddle factors
                (local.set $tw_addr (i32.add (global.get $TWIDDLE_BASE)
                                             (i32.shl (i32.mul (local.get $k) (local.get $tw_step)) (i32.const 4))))
                (local.set $w1 (v128.load (local.get $tw_addr)))

                (local.set $tw_addr (i32.add (global.get $TWIDDLE_BASE)
                                             (i32.shl (i32.mul (i32.shl (local.get $k) (i32.const 1)) (local.get $tw_step)) (i32.const 4))))
                (local.set $w2 (v128.load (local.get $tw_addr)))

                (local.set $tw_addr (i32.add (global.get $TWIDDLE_BASE)
                                             (i32.shl (i32.mul (i32.mul (local.get $k) (i32.const 3)) (local.get $tw_step)) (i32.const 4))))
                (local.set $w3 (v128.load (local.get $tw_addr)))

                ;; Apply twiddles
                (local.set $x1 (call $simd_cmul (local.get $x1) (local.get $w1)))
                (local.set $x2 (call $simd_cmul (local.get $x2) (local.get $w2)))
                (local.set $x3 (call $simd_cmul (local.get $x3) (local.get $w3)))

                ;; Radix-4 butterfly
                (local.set $t0 (f64x2.add (local.get $x0) (local.get $x2)))
                (local.set $t1 (f64x2.sub (local.get $x0) (local.get $x2)))
                (local.set $t2 (f64x2.add (local.get $x1) (local.get $x3)))
                (local.set $t3 (f64x2.sub (local.get $x1) (local.get $x3)))

                ;; Store outputs with same swap pattern (to maintain consistency for next stage)
                (v128.store (local.get $i0) (f64x2.add (local.get $t0) (local.get $t2)))
                (v128.store (local.get $i2) (f64x2.add (local.get $t1) (call $mul_neg_j (local.get $t3)))) ;; store to i2 (was quarter)
                (v128.store (local.get $i1) (f64x2.sub (local.get $t0) (local.get $t2))) ;; store to i1 (was 2*quarter)
                (v128.store (local.get $i3) (f64x2.add (local.get $t1) (call $mul_pos_j (local.get $t3))))

                (local.set $k (i32.add (local.get $k) (i32.const 1)))
                (br $k_loop)
              )
            )

            (local.set $group_start (i32.add (local.get $group_start) (local.get $size)))
            (br $group_loop)
          )
        )

        (local.set $size (i32.shl (local.get $size) (i32.const 2)))
        (br $r4_loop)
      )
    )
  )

  ;; Main entry point - automatically chooses best algorithm
  (func $fft_radix4 (export "fft_radix4") (param $n i32)
    (local $log2n i32)
    (local $log4n i32)

    (local.set $log2n (i32.ctz (local.get $n)))

    ;; Check if N is a power of 4 (log2n is even)
    (if (i32.eqz (i32.and (local.get $log2n) (i32.const 1)))
      (then
        ;; Pure Radix-4
        (local.set $log4n (i32.shr_u (local.get $log2n) (i32.const 1)))
        (call $fft_radix4_pure (local.get $n) (local.get $log4n))
      )
      (else
        ;; Mixed Radix-4/Radix-2
        (call $fft_radix4_mixed (local.get $n) (local.get $log2n))
      )
    )
  )
