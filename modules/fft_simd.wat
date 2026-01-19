  ;; SIMD-optimized FFT using Radix-2 Cooley-Tukey
  ;;
  ;; Features:
  ;; - SIMD v128 operations for parallel complex arithmetic
  ;; - Precomputed twiddle factors via JS Math.sin/cos
  ;; - Zero-copy memory (JS writes directly to WASM memory)
  ;;
  ;; Memory layout:
  ;;   [0, N*16): Complex data (16 bytes per complex: [f64 real, f64 imag])
  ;;   [131072, ...): Precomputed twiddle factors

  (global $TWIDDLE_BASE i32 (i32.const 131072))
  (global $NEG_TWO_PI f64 (f64.const -6.283185307179586))

  ;; Sign mask for complex multiply: negate first lane for [ac-bd, ad+bc]
  (global $SIGN_MASK v128 (v128.const i64x2 0x8000000000000000 0x0000000000000000))

  ;; Precompute twiddle factors W_N^k = e^(-2πik/N) for k = 0..N/2-1
  (func $precompute_twiddles (export "precompute_twiddles") (param $n i32)
    (local $k i32)
    (local $angle f64)
    (local $addr i32)
    (local $half_n i32)

    (local.set $half_n (i32.shr_u (local.get $n) (i32.const 1)))
    (local.set $k (i32.const 0))
    (local.set $addr (global.get $TWIDDLE_BASE))

    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $k) (local.get $half_n)))

        (local.set $angle
          (f64.div
            (f64.mul (f64.convert_i32_u (local.get $k)) (global.get $NEG_TWO_PI))
            (f64.convert_i32_u (local.get $n))
          )
        )

        ;; Store [cos, sin] as complex twiddle
        (f64.store (local.get $addr) (call $js_cos (local.get $angle)))
        (f64.store offset=8 (local.get $addr) (call $js_sin (local.get $angle)))

        (local.set $addr (i32.add (local.get $addr) (i32.const 16)))
        (local.set $k (i32.add (local.get $k) (i32.const 1)))
        (br $loop)
      )
    )
  )

  ;; SIMD complex multiply: (a+bi)(c+di) = (ac-bd) + (ad+bc)i
  ;; v1 = [a, b], v2 = [c, d] -> [ac-bd, ad+bc]
  (func $simd_cmul (param $v1 v128) (param $v2 v128) (result v128)
    (local $aa v128)
    (local $bb v128)
    (local $dc v128)
    (local $ac_ad v128)
    (local $bd_bc v128)

    ;; aa = [a, a], bb = [b, b]
    (local.set $aa (f64x2.splat (f64x2.extract_lane 0 (local.get $v1))))
    (local.set $bb (f64x2.splat (f64x2.extract_lane 1 (local.get $v1))))

    ;; dc = [d, c] (swap lanes of v2)
    (local.set $dc (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7
                                  (local.get $v2) (local.get $v2)))

    ;; [ac, ad] and [bd, bc]
    (local.set $ac_ad (f64x2.mul (local.get $aa) (local.get $v2)))
    (local.set $bd_bc (f64x2.mul (local.get $bb) (local.get $dc)))

    ;; [ac-bd, ad+bc] = [ac, ad] + [-bd, bc]
    (f64x2.add
      (local.get $ac_ad)
      (v128.xor (local.get $bd_bc) (global.get $SIGN_MASK))
    )
  )

  ;; SIMD bit-reversal permutation
  (func $simd_bit_reverse (param $n i32)
    (local $log2n i32)
    (local $i i32)
    (local $j i32)
    (local $temp v128)
    (local $i_addr i32)
    (local $j_addr i32)

    (local.set $log2n (i32.ctz (local.get $n)))
    (local.set $i (i32.const 0))

    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $i) (local.get $n)))

        (local.set $j (call $reverse_bits (local.get $i) (local.get $log2n)))

        (if (i32.lt_u (local.get $i) (local.get $j))
          (then
            (local.set $i_addr (i32.shl (local.get $i) (i32.const 4)))
            (local.set $j_addr (i32.shl (local.get $j) (i32.const 4)))
            ;; SIMD swap (16 bytes = 1 complex number)
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

  ;; Main SIMD FFT - Radix-2 with SIMD complex operations
  (func $fft_simd (export "fft_simd") (param $n i32)
    (local $size i32)
    (local $half_size i32)
    (local $tw_step i32)
    (local $m i32)
    (local $k i32)
    (local $i i32)
    (local $j i32)
    (local $i_addr i32)
    (local $j_addr i32)
    (local $tw_addr i32)
    (local $even v128)
    (local $odd v128)
    (local $tw v128)
    (local $temp v128)

    ;; Bit-reversal permutation using SIMD
    (call $simd_bit_reverse (local.get $n))

    ;; Main FFT loop - Radix-2 with SIMD butterflies
    (local.set $size (i32.const 2))

    (block $done_fft
      (loop $fft_loop
        (br_if $done_fft (i32.gt_u (local.get $size) (local.get $n)))

        (local.set $half_size (i32.shr_u (local.get $size) (i32.const 1)))
        (local.set $tw_step (i32.div_u (local.get $n) (local.get $size)))

        ;; For each butterfly position m
        (local.set $m (i32.const 0))
        (block $done_m
          (loop $m_loop
            (br_if $done_m (i32.ge_u (local.get $m) (local.get $half_size)))

            ;; Load twiddle factor
            (local.set $tw_addr
              (i32.add
                (global.get $TWIDDLE_BASE)
                (i32.shl (i32.mul (local.get $m) (local.get $tw_step)) (i32.const 4))
              )
            )
            (local.set $tw (v128.load (local.get $tw_addr)))

            ;; For each group
            (local.set $k (i32.const 0))
            (block $done_k
              (loop $k_loop
                (br_if $done_k (i32.ge_u (local.get $k) (local.get $n)))

                (local.set $i (i32.add (local.get $k) (local.get $m)))
                (local.set $j (i32.add (local.get $i) (local.get $half_size)))

                (local.set $i_addr (i32.shl (local.get $i) (i32.const 4)))
                (local.set $j_addr (i32.shl (local.get $j) (i32.const 4)))

                ;; Load even and odd
                (local.set $even (v128.load (local.get $i_addr)))
                (local.set $odd (v128.load (local.get $j_addr)))

                ;; temp = odd * twiddle (SIMD complex multiply)
                (local.set $temp (call $simd_cmul (local.get $odd) (local.get $tw)))

                ;; even_out = even + temp, odd_out = even - temp
                (v128.store (local.get $i_addr) (f64x2.add (local.get $even) (local.get $temp)))
                (v128.store (local.get $j_addr) (f64x2.sub (local.get $even) (local.get $temp)))

                (local.set $k (i32.add (local.get $k) (local.get $size)))
                (br $k_loop)
              )
            )

            (local.set $m (i32.add (local.get $m) (i32.const 1)))
            (br $m_loop)
          )
        )

        (local.set $size (i32.shl (local.get $size) (i32.const 1)))
        (br $fft_loop)
      )
    )
  )
