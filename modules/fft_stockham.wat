;; Stockham Radix-2 FFT - No bit-reversal permutation needed
;; Uses ping-pong buffers for implicit reordering during computation
;;
;; Based on: https://github.com/scientificgo/fft/blob/master/stockham.go
;;
;; Memory layout:
;;   0 - 65535: Primary data buffer (4096 complex numbers max)
;;   65536 - 131071: Secondary buffer for ping-pong
;;   131072+: Twiddle factors

;; Buffer offsets
(global $SECONDARY_OFFSET i32 (i32.const 65536))
(global $TWIDDLE_OFFSET i32 (i32.const 131072))
(global $NEG_PI f64 (f64.const -3.141592653589793))

;; SIMD sign masks for complex multiply
(global $SIGN_MASK v128 (v128.const i64x2 0x8000000000000000 0x0000000000000000))

;; Precompute twiddle factors for size N
;; Stores W_N^k = e^{-2*pi*i*k/N} for k = 0 to N-1
(func $precompute_twiddles (export "precompute_twiddles") (param $n i32)
  (local $k i32)
  (local $angle f64)
  (local $addr i32)
  (local $neg_two_pi_over_n f64)

  ;; Precompute -2*pi/n
  (local.set $neg_two_pi_over_n
    (f64.div
      (f64.mul (f64.const -2.0) (f64.const 3.141592653589793))
      (f64.convert_i32_u (local.get $n))))

  (local.set $k (i32.const 0))
  (block $done
    (loop $loop
      (br_if $done (i32.ge_u (local.get $k) (local.get $n)))

      (local.set $angle
        (f64.mul (f64.convert_i32_u (local.get $k)) (local.get $neg_two_pi_over_n)))

      (local.set $addr (i32.add (global.get $TWIDDLE_OFFSET)
                                (i32.shl (local.get $k) (i32.const 4))))

      (f64.store (local.get $addr) (call $js_cos (local.get $angle)))
      (f64.store (i32.add (local.get $addr) (i32.const 8)) (call $js_sin (local.get $angle)))

      (local.set $k (i32.add (local.get $k) (i32.const 1)))
      (br $loop)
    )
  )
)

;; SIMD complex multiply: (a + bi)(c + di) = (ac-bd) + (ad+bc)i
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

;; Stockham Radix-2 FFT
;; Algorithm:
;;   for r = n/2 down to 1 (halving each stage):
;;     for each group j = 0 to l-1:
;;       for each butterfly k in group:
;;         read src[k] and src[k+r]
;;         apply twiddle to second element
;;         write butterfly outputs to dst[m] and dst[m + n/2]
;;     swap src and dst
;;     l *= 2
(func $fft_stockham (export "fft_stockham") (param $n i32)
  (local $n2 i32)           ;; n / 2
  (local $r i32)            ;; butterfly radius (half-size), halves each stage
  (local $l i32)            ;; number of groups, doubles each stage
  (local $j i32)            ;; group index
  (local $k i32)            ;; butterfly index within group
  (local $m i32)            ;; output position
  (local $jrs i32)          ;; j * 2r = start of group j
  (local $src i32)          ;; source buffer base
  (local $dst i32)          ;; destination buffer base
  (local $twiddle_idx i32)  ;; index into twiddle table
  (local $tw_step i32)      ;; twiddle step per j
  (local $x0 v128)          ;; first butterfly input
  (local $x1 v128)          ;; second butterfly input (after twiddle)
  (local $w v128)           ;; twiddle factor
  (local $i0 i32)           ;; input address 0
  (local $i1 i32)           ;; input address 1
  (local $o0 i32)           ;; output address 0
  (local $o1 i32)           ;; output address 1

  ;; n2 = n / 2
  (local.set $n2 (i32.shr_u (local.get $n) (i32.const 1)))

  ;; Initialize: src = primary buffer (0), dst = secondary buffer
  (local.set $src (i32.const 0))
  (local.set $dst (global.get $SECONDARY_OFFSET))

  ;; r starts at n/2, l starts at 1
  (local.set $r (local.get $n2))
  (local.set $l (i32.const 1))

  ;; Main loop: r halves each iteration until r < 1
  (block $done_stages
    (loop $stage_loop
      (br_if $done_stages (i32.lt_u (local.get $r) (i32.const 1)))

      ;; Twiddle step: angle increment is -π/l, so for precomputed W_N^k = exp(-2πik/N):
      ;; We need exp(-πij/l) = W_N^(j*N/(2l))
      ;; tw_step = n / (2 * l) to increment twiddle index per j
      (local.set $tw_step (i32.div_u (local.get $n) (i32.shl (local.get $l) (i32.const 1))))

      ;; For each group j
      (local.set $j (i32.const 0))
      (local.set $twiddle_idx (i32.const 0))
      (block $done_groups
        (loop $group_loop
          (br_if $done_groups (i32.ge_u (local.get $j) (local.get $l)))

          ;; Load twiddle factor for this j: W = twiddle[twiddle_idx]
          (local.set $w (v128.load (i32.add (global.get $TWIDDLE_OFFSET)
                                            (i32.shl (local.get $twiddle_idx) (i32.const 4)))))

          ;; jrs = j * 2 * r (starting position for this group in source)
          (local.set $jrs (i32.mul (local.get $j) (i32.shl (local.get $r) (i32.const 1))))

          ;; m = jrs / 2 (starting output position)
          (local.set $m (i32.shr_u (local.get $jrs) (i32.const 1)))

          ;; For each butterfly in this group: k goes from jrs to jrs+r-1
          (local.set $k (local.get $jrs))
          (block $done_butterflies
            (loop $butterfly_loop
              (br_if $done_butterflies (i32.ge_u (local.get $k) (i32.add (local.get $jrs) (local.get $r))))

              ;; Input addresses: src[k] and src[k+r]
              (local.set $i0 (i32.add (local.get $src) (i32.shl (local.get $k) (i32.const 4))))
              (local.set $i1 (i32.add (local.get $i0) (i32.shl (local.get $r) (i32.const 4))))

              ;; Output addresses: dst[m] and dst[m + n/2]
              (local.set $o0 (i32.add (local.get $dst) (i32.shl (local.get $m) (i32.const 4))))
              (local.set $o1 (i32.add (local.get $o0) (i32.shl (local.get $n2) (i32.const 4))))

              ;; Load inputs
              (local.set $x0 (v128.load (local.get $i0)))
              (local.set $x1 (v128.load (local.get $i1)))

              ;; Apply twiddle to x1: x1 = x1 * W
              (local.set $x1 (call $simd_cmul (local.get $x1) (local.get $w)))

              ;; Butterfly: y0 = x0 + W*x1, y1 = x0 - W*x1
              (v128.store (local.get $o0) (f64x2.add (local.get $x0) (local.get $x1)))
              (v128.store (local.get $o1) (f64x2.sub (local.get $x0) (local.get $x1)))

              ;; Increment k and m
              (local.set $k (i32.add (local.get $k) (i32.const 1)))
              (local.set $m (i32.add (local.get $m) (i32.const 1)))
              (br $butterfly_loop)
            )
          )

          ;; Increment twiddle index for next j
          (local.set $twiddle_idx (i32.add (local.get $twiddle_idx) (local.get $tw_step)))
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

      ;; Update r and l for next stage
      (local.set $r (i32.shr_u (local.get $r) (i32.const 1)))
      (local.set $l (i32.shl (local.get $l) (i32.const 1)))
      (br $stage_loop)
    )
  )

  ;; Copy result back to primary buffer if needed
  ;; After all swaps, result is in src
  (if (i32.ne (local.get $src) (i32.const 0))
    (then
      ;; Result is in secondary buffer, copy to primary
      (local.set $k (i32.const 0))
      (block $done_copy
        (loop $copy_loop
          (br_if $done_copy (i32.ge_u (local.get $k) (local.get $n)))
          (v128.store
            (i32.shl (local.get $k) (i32.const 4))
            (v128.load (i32.add (global.get $SECONDARY_OFFSET) (i32.shl (local.get $k) (i32.const 4)))))
          (local.set $k (i32.add (local.get $k) (i32.const 1)))
          (br $copy_loop)
        )
      )
    )
  )
)
