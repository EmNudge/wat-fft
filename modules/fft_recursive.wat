(module
  ;; Depth-First Recursive FFT
  ;;
  ;; Uses cache-oblivious recursive decomposition:
  ;; - Base case: N <= 64 uses iterative Stockham
  ;; - Recursive case: split into even/odd, recurse, combine
  ;;
  ;; Benefits for large N:
  ;; - Working set stays in cache longer
  ;; - Better temporal locality than breadth-first iteration
  ;;
  ;; Memory layout:
  ;;   0 - 65535: Primary data buffer
  ;;   65536 - 131071: Secondary buffer for recursion
  ;;   131072+: Twiddle factors

  (memory (export "memory") 4)

  (global $SECONDARY_OFFSET i32 (i32.const 65536))
  (global $TWIDDLE_OFFSET i32 (i32.const 131072))
  (global $PI f64 (f64.const 3.141592653589793))
  (global $HALF_PI f64 (f64.const 1.5707963267948966))

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

  ;; N=4 base case using SIMD
  (func $fft_4_at (param $base i32)
    (local $x0 v128) (local $x1 v128) (local $x2 v128) (local $x3 v128)
    (local $t0 v128) (local $t1 v128) (local $t2 v128) (local $t3 v128)

    (local.set $x0 (v128.load (local.get $base)))
    (local.set $x1 (v128.load (i32.add (local.get $base) (i32.const 16))))
    (local.set $x2 (v128.load (i32.add (local.get $base) (i32.const 32))))
    (local.set $x3 (v128.load (i32.add (local.get $base) (i32.const 48))))

    (local.set $t0 (f64x2.add (local.get $x0) (local.get $x2)))
    (local.set $t1 (f64x2.sub (local.get $x0) (local.get $x2)))
    (local.set $t2 (f64x2.add (local.get $x1) (local.get $x3)))
    (local.set $t3 (f64x2.sub (local.get $x1) (local.get $x3)))

    ;; Apply -j to t3: (a,b) -> (b,-a)
    (local.set $t3
      (f64x2.mul
        (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $t3) (local.get $t3))
        (v128.const f64x2 1.0 -1.0)))

    (v128.store (local.get $base) (f64x2.add (local.get $t0) (local.get $t2)))
    (v128.store (i32.add (local.get $base) (i32.const 16)) (f64x2.add (local.get $t1) (local.get $t3)))
    (v128.store (i32.add (local.get $base) (i32.const 32)) (f64x2.sub (local.get $t0) (local.get $t2)))
    (v128.store (i32.add (local.get $base) (i32.const 48)) (f64x2.sub (local.get $t1) (local.get $t3)))
  )

  ;; N=2 base case
  (func $fft_2_at (param $base i32)
    (local $x0 v128) (local $x1 v128)
    (local.set $x0 (v128.load (local.get $base)))
    (local.set $x1 (v128.load (i32.add (local.get $base) (i32.const 16))))
    (v128.store (local.get $base) (f64x2.add (local.get $x0) (local.get $x1)))
    (v128.store (i32.add (local.get $base) (i32.const 16)) (f64x2.sub (local.get $x0) (local.get $x1)))
  )

  ;; Iterative Stockham for medium sizes (used as base case)
  ;; Performs FFT in-place at the given base address
  (func $fft_stockham_at (param $base i32) (param $n i32)
    (local $half i32) (local $stride i32) (local $group_size i32)
    (local $j i32) (local $k i32)
    (local $tw_step i32) (local $tw_idx i32) (local $tw_addr i32)
    (local $even_addr i32) (local $odd_addr i32)
    (local $dst_addr i32) (local $dst_half i32)
    (local $src i32) (local $dst i32)
    (local $xe v128) (local $xo v128) (local $tw v128)
    (local $prod v128) (local $sum v128) (local $diff v128)

    (local.set $half (i32.shr_u (local.get $n) (i32.const 1)))
    (local.set $src (local.get $base))
    (local.set $dst (global.get $SECONDARY_OFFSET))
    (local.set $stride (i32.const 1))
    (local.set $group_size (local.get $half))

    (block $done_stages (loop $stage_loop
      (br_if $done_stages (i32.ge_u (local.get $stride) (local.get $n)))

      (local.set $tw_step (i32.div_u (local.get $n) (i32.shl (local.get $stride) (i32.const 1))))
      (local.set $j (i32.const 0))

      (block $done_groups (loop $group_loop
        (br_if $done_groups (i32.ge_u (local.get $j) (local.get $stride)))

        (local.set $tw_idx (i32.mul (local.get $j) (local.get $tw_step)))
        (local.set $tw_addr (i32.add (global.get $TWIDDLE_OFFSET)
                                     (i32.shl (local.get $tw_idx) (i32.const 4))))
        (local.set $tw (v128.load (local.get $tw_addr)))

        (local.set $even_addr (i32.add (local.get $src)
                               (i32.shl (i32.mul (local.get $j) (local.get $group_size)) (i32.const 4))))
        (local.set $odd_addr (i32.add (local.get $even_addr)
                              (i32.shl (local.get $half) (i32.const 4))))
        (local.set $dst_addr (i32.add (local.get $dst)
                              (i32.shl (i32.mul (local.get $j) (i32.const 2)) (i32.const 4))))
        (local.set $dst_half (i32.add (local.get $dst_addr)
                              (i32.shl (local.get $stride) (i32.const 4))))

        (local.set $k (i32.const 0))
        (block $done_k (loop $k_loop
          (br_if $done_k (i32.ge_u (local.get $k) (local.get $group_size)))

          (local.set $xe (v128.load (local.get $even_addr)))
          (local.set $xo (v128.load (local.get $odd_addr)))

          ;; Complex multiply xo * tw (inlined)
          (local.set $prod
            (f64x2.add
              (f64x2.mul (local.get $xo)
                (i8x16.shuffle 0 1 2 3 4 5 6 7 0 1 2 3 4 5 6 7 (local.get $tw) (local.get $tw)))
              (f64x2.mul
                (f64x2.mul
                  (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $xo) (local.get $xo))
                  (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $tw) (local.get $tw)))
                (v128.const f64x2 -1.0 1.0))))

          (local.set $sum (f64x2.add (local.get $xe) (local.get $prod)))
          (local.set $diff (f64x2.sub (local.get $xe) (local.get $prod)))

          (v128.store (local.get $dst_addr) (local.get $sum))
          (v128.store (local.get $dst_half) (local.get $diff))

          (local.set $even_addr (i32.add (local.get $even_addr) (i32.const 16)))
          (local.set $odd_addr (i32.add (local.get $odd_addr) (i32.const 16)))
          (local.set $dst_addr (i32.add (local.get $dst_addr) (i32.shl (i32.shl (local.get $stride) (i32.const 1)) (i32.const 4))))
          (local.set $dst_half (i32.add (local.get $dst_half) (i32.shl (i32.shl (local.get $stride) (i32.const 1)) (i32.const 4))))
          (local.set $k (i32.add (local.get $k) (i32.const 1)))
          (br $k_loop)
        ))

        (local.set $j (i32.add (local.get $j) (i32.const 1)))
        (br $group_loop)
      ))

      ;; Swap buffers
      (if (i32.eq (local.get $src) (local.get $base))
        (then
          (local.set $src (global.get $SECONDARY_OFFSET))
          (local.set $dst (local.get $base)))
        (else
          (local.set $src (local.get $base))
          (local.set $dst (global.get $SECONDARY_OFFSET))))

      (local.set $stride (i32.shl (local.get $stride) (i32.const 1)))
      (local.set $group_size (i32.shr_u (local.get $group_size) (i32.const 1)))
      (br $stage_loop)
    ))

    ;; Copy back if result is in secondary buffer
    (if (i32.ne (local.get $src) (local.get $base))
      (then
        (local.set $k (i32.const 0))
        (local.set $even_addr (global.get $SECONDARY_OFFSET))
        (local.set $odd_addr (local.get $base))
        (block $copy_done (loop $copy_loop
          (br_if $copy_done (i32.ge_u (local.get $k) (local.get $n)))
          (v128.store (local.get $odd_addr) (v128.load (local.get $even_addr)))
          (local.set $even_addr (i32.add (local.get $even_addr) (i32.const 16)))
          (local.set $odd_addr (i32.add (local.get $odd_addr) (i32.const 16)))
          (local.set $k (i32.add (local.get $k) (i32.const 1)))
          (br $copy_loop)
        ))
      )
    )
  )

  ;; Combine step: given FFT of even and odd halves, produce full FFT
  ;; Even half at base, odd half at base + n/2 * 16
  ;; Uses twiddles for size n
  (func $combine (param $base i32) (param $n i32)
    (local $half i32) (local $k i32)
    (local $even_addr i32) (local $odd_addr i32)
    (local $tw_step i32) (local $tw_addr i32)
    (local $xe v128) (local $xo v128) (local $tw v128) (local $prod v128)

    (local.set $half (i32.shr_u (local.get $n) (i32.const 1)))
    (local.set $tw_step (i32.const 1))  ;; twiddles precomputed for full N at top level
    (local.set $even_addr (local.get $base))
    (local.set $odd_addr (i32.add (local.get $base) (i32.shl (local.get $half) (i32.const 4))))
    (local.set $k (i32.const 0))

    (block $done (loop $loop
      (br_if $done (i32.ge_u (local.get $k) (local.get $half)))

      ;; Load twiddle W_n^k
      (local.set $tw_addr (i32.add (global.get $TWIDDLE_OFFSET)
                                   (i32.shl (local.get $k) (i32.const 4))))
      (local.set $tw (v128.load (local.get $tw_addr)))

      (local.set $xe (v128.load (local.get $even_addr)))
      (local.set $xo (v128.load (local.get $odd_addr)))

      ;; prod = xo * tw (inlined SIMD complex multiply)
      (local.set $prod
        (f64x2.add
          (f64x2.mul (local.get $xo)
            (i8x16.shuffle 0 1 2 3 4 5 6 7 0 1 2 3 4 5 6 7 (local.get $tw) (local.get $tw)))
          (f64x2.mul
            (f64x2.mul
              (i8x16.shuffle 8 9 10 11 12 13 14 15 0 1 2 3 4 5 6 7 (local.get $xo) (local.get $xo))
              (i8x16.shuffle 8 9 10 11 12 13 14 15 8 9 10 11 12 13 14 15 (local.get $tw) (local.get $tw)))
            (v128.const f64x2 -1.0 1.0))))

      ;; X[k] = xe + prod, X[k + n/2] = xe - prod
      (v128.store (local.get $even_addr) (f64x2.add (local.get $xe) (local.get $prod)))
      (v128.store (local.get $odd_addr) (f64x2.sub (local.get $xe) (local.get $prod)))

      (local.set $even_addr (i32.add (local.get $even_addr) (i32.const 16)))
      (local.set $odd_addr (i32.add (local.get $odd_addr) (i32.const 16)))
      (local.set $k (i32.add (local.get $k) (i32.const 1)))
      (br $loop)
    ))
  )

  ;; Recursive FFT implementation
  ;; For small N: use iterative Stockham
  ;; For large N: split, recurse, combine
  (func $fft_recursive_impl (param $base i32) (param $n i32)
    (local $half i32) (local $odd_base i32)

    ;; Base cases
    (if (i32.eq (local.get $n) (i32.const 2))
      (then (call $fft_2_at (local.get $base)) (return)))
    (if (i32.eq (local.get $n) (i32.const 4))
      (then (call $fft_4_at (local.get $base)) (return)))

    ;; For sizes <= 64, use iterative Stockham (fits in cache)
    (if (i32.le_u (local.get $n) (i32.const 64))
      (then (call $fft_stockham_at (local.get $base) (local.get $n)) (return)))

    ;; Recursive case: split into even/odd, recurse, combine
    (local.set $half (i32.shr_u (local.get $n) (i32.const 1)))
    (local.set $odd_base (i32.add (local.get $base) (i32.shl (local.get $half) (i32.const 4))))

    ;; NOTE: Data must already be in even/odd order for this to work
    ;; This is the Cooley-Tukey DIT pattern, not Stockham
    ;; Recurse on even half
    (call $fft_recursive_impl (local.get $base) (local.get $half))
    ;; Recurse on odd half
    (call $fft_recursive_impl (local.get $odd_base) (local.get $half))
    ;; Combine
    (call $combine (local.get $base) (local.get $n))
  )

  ;; Reorder data into even/odd split for recursive FFT
  ;; Input: natural order at base
  ;; Output: even indices in first half, odd indices in second half
  (func $reorder_even_odd (param $base i32) (param $n i32)
    (local $half i32) (local $k i32)
    (local $src_addr i32) (local $even_dst i32) (local $odd_dst i32)
    (local $temp_base i32)

    (local.set $half (i32.shr_u (local.get $n) (i32.const 1)))
    (local.set $temp_base (global.get $SECONDARY_OFFSET))

    ;; Copy even indices to temp first half
    (local.set $k (i32.const 0))
    (local.set $src_addr (local.get $base))
    (local.set $even_dst (local.get $temp_base))
    (block $even_done (loop $even_loop
      (br_if $even_done (i32.ge_u (local.get $k) (local.get $half)))
      (v128.store (local.get $even_dst) (v128.load (local.get $src_addr)))
      (local.set $src_addr (i32.add (local.get $src_addr) (i32.const 32)))  ;; skip by 2
      (local.set $even_dst (i32.add (local.get $even_dst) (i32.const 16)))
      (local.set $k (i32.add (local.get $k) (i32.const 1)))
      (br $even_loop)
    ))

    ;; Copy odd indices to temp second half
    (local.set $k (i32.const 0))
    (local.set $src_addr (i32.add (local.get $base) (i32.const 16)))  ;; start at index 1
    (local.set $odd_dst (i32.add (local.get $temp_base) (i32.shl (local.get $half) (i32.const 4))))
    (block $odd_done (loop $odd_loop
      (br_if $odd_done (i32.ge_u (local.get $k) (local.get $half)))
      (v128.store (local.get $odd_dst) (v128.load (local.get $src_addr)))
      (local.set $src_addr (i32.add (local.get $src_addr) (i32.const 32)))
      (local.set $odd_dst (i32.add (local.get $odd_dst) (i32.const 16)))
      (local.set $k (i32.add (local.get $k) (i32.const 1)))
      (br $odd_loop)
    ))

    ;; Copy back to base
    (local.set $k (i32.const 0))
    (local.set $src_addr (local.get $temp_base))
    (local.set $even_dst (local.get $base))
    (block $copy_done (loop $copy_loop
      (br_if $copy_done (i32.ge_u (local.get $k) (local.get $n)))
      (v128.store (local.get $even_dst) (v128.load (local.get $src_addr)))
      (local.set $src_addr (i32.add (local.get $src_addr) (i32.const 16)))
      (local.set $even_dst (i32.add (local.get $even_dst) (i32.const 16)))
      (local.set $k (i32.add (local.get $k) (i32.const 1)))
      (br $copy_loop)
    ))
  )

  ;; Main entry: recursive FFT on data at address 0
  (func $fft_recursive (export "fft_recursive") (param $n i32)
    ;; For recursive approach, we need to reorder data at each level
    ;; This adds overhead but enables depth-first processing

    ;; For now, just use iterative Stockham as baseline comparison
    ;; A true recursive implementation needs bit-reversal or more complex reordering
    (call $fft_stockham_at (i32.const 0) (local.get $n))
  )
)
