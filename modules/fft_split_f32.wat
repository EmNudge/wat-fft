(module
  ;; FFT with Split Real/Imaginary Format
  ;;
  ;; Uses pffft-style data layout:
  ;; - Real parts in one contiguous array
  ;; - Imaginary parts in another contiguous array
  ;; - Processes 4 complex numbers per SIMD operation
  ;;
  ;; Algorithm: Cooley-Tukey DIT (Decimation in Time)
  ;; - Bit-reverse input
  ;; - Iterative butterfly stages
  ;;
  ;; Memory layout:
  ;;   0 - 32767: Primary buffer (interleaved input/output)
  ;;   32768 - 65535: Split real buffer
  ;;   65536 - 98303: Split imaginary buffer
  ;;   98304+: Twiddle factors (split: reals then imags)

  ;; Import sin/cos from JavaScript for better accuracy
  (import "env" "sin" (func $sin_import (param f64) (result f64)))
  (import "env" "cos" (func $cos_import (param f64) (result f64)))

  (memory (export "memory") 4)

  (global $SPLIT_RE_OFFSET i32 (i32.const 32768))
  (global $SPLIT_IM_OFFSET i32 (i32.const 65536))
  (global $TWIDDLE_OFFSET i32 (i32.const 98304))
  (global $PI f64 (f64.const 3.14159265358979323846))

  ;; ============================================================================
  ;; Trig Functions (wrapper to convert f32 <-> f64)
  ;; ============================================================================

  (func $sin (param $x f32) (result f32)
    (f32.demote_f64 (call $sin_import (f64.promote_f32 (local.get $x))))
  )

  (func $cos (param $x f32) (result f32)
    (f32.demote_f64 (call $cos_import (f64.promote_f32 (local.get $x))))
  )

  ;; ============================================================================
  ;; Bit Reversal
  ;; ============================================================================

  (func $bit_reverse (param $x i32) (param $bits i32) (result i32)
    (local $result i32)
    (local $i i32)
    (local.set $result (i32.const 0))
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $i) (local.get $bits)))
        (local.set $result (i32.or
          (i32.shl (local.get $result) (i32.const 1))
          (i32.and (local.get $x) (i32.const 1))))
        (local.set $x (i32.shr_u (local.get $x) (i32.const 1)))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)
      )
    )
    (local.get $result)
  )

  ;; ============================================================================
  ;; Twiddle Precomputation (Split Format)
  ;; ============================================================================
  ;; Store W_N^k = cos(-2*pi*k/N) + i*sin(-2*pi*k/N)
  ;; Layout: [re_0, re_1, ..., re_{N-1}] then [im_0, im_1, ..., im_{N-1}]

  (func $precompute_twiddles (export "precompute_twiddles") (param $n i32)
    (local $k i32)
    (local $angle f64)
    (local $neg_two_pi_over_n f64)
    (local $re_addr i32)
    (local $im_addr i32)

    (if (i32.le_u (local.get $n) (i32.const 1))
      (then (return)))

    (local.set $neg_two_pi_over_n
      (f64.div (f64.mul (f64.const -2.0) (global.get $PI))
               (f64.convert_i32_u (local.get $n))))

    (local.set $re_addr (global.get $TWIDDLE_OFFSET))
    (local.set $im_addr (i32.add (global.get $TWIDDLE_OFFSET)
                                  (i32.shl (local.get $n) (i32.const 2))))
    (local.set $k (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $k) (local.get $n)))
        (local.set $angle (f64.mul (f64.convert_i32_u (local.get $k))
                                   (local.get $neg_two_pi_over_n)))
        (f32.store (local.get $re_addr) (f32.demote_f64 (call $cos_import (local.get $angle))))
        (f32.store (local.get $im_addr) (f32.demote_f64 (call $sin_import (local.get $angle))))
        (local.set $re_addr (i32.add (local.get $re_addr) (i32.const 4)))
        (local.set $im_addr (i32.add (local.get $im_addr) (i32.const 4)))
        (local.set $k (i32.add (local.get $k) (i32.const 1)))
        (br $loop)
      )
    )
  )

  ;; ============================================================================
  ;; Interleaved to Split Conversion with Bit-Reversal
  ;; ============================================================================
  ;; Reads interleaved from offset 0, writes split to SPLIT_RE/IM with bit-reversal

  (func $interleaved_to_split_bitrev (param $n i32)
    (local $i i32)
    (local $j i32)
    (local $log2n i32)
    (local $src i32)
    (local $re f32)
    (local $im f32)
    (local $m i32)

    ;; Compute log2(n)
    (local.set $log2n (i32.const 0))
    (local.set $m (local.get $n))
    (block $done_log
      (loop $log_loop
        (br_if $done_log (i32.le_u (local.get $m) (i32.const 1)))
        (local.set $m (i32.shr_u (local.get $m) (i32.const 1)))
        (local.set $log2n (i32.add (local.get $log2n) (i32.const 1)))
        (br $log_loop)
      )
    )

    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $i) (local.get $n)))

        ;; Bit-reverse index
        (local.set $j (call $bit_reverse (local.get $i) (local.get $log2n)))

        ;; Read from interleaved input at position j
        (local.set $src (i32.shl (local.get $j) (i32.const 3))) ;; j * 8 bytes
        (local.set $re (f32.load (local.get $src)))
        (local.set $im (f32.load (i32.add (local.get $src) (i32.const 4))))

        ;; Write to split output at position i
        (f32.store (i32.add (global.get $SPLIT_RE_OFFSET)
                            (i32.shl (local.get $i) (i32.const 2)))
                   (local.get $re))
        (f32.store (i32.add (global.get $SPLIT_IM_OFFSET)
                            (i32.shl (local.get $i) (i32.const 2)))
                   (local.get $im))

        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)
      )
    )
  )

  ;; ============================================================================
  ;; Split to Interleaved Conversion
  ;; ============================================================================

  (func $split_to_interleaved (param $n i32)
    (local $i i32)
    (local $dst i32)
    (local $re f32)
    (local $im f32)

    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_u (local.get $i) (local.get $n)))

        ;; Read from split
        (local.set $re (f32.load (i32.add (global.get $SPLIT_RE_OFFSET)
                                          (i32.shl (local.get $i) (i32.const 2)))))
        (local.set $im (f32.load (i32.add (global.get $SPLIT_IM_OFFSET)
                                          (i32.shl (local.get $i) (i32.const 2)))))

        ;; Write to interleaved output
        (local.set $dst (i32.shl (local.get $i) (i32.const 3)))
        (f32.store (local.get $dst) (local.get $re))
        (f32.store (i32.add (local.get $dst) (i32.const 4)) (local.get $im))

        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)
      )
    )
  )

  ;; ============================================================================
  ;; DIT FFT Core (Split Format) - Scalar version for correctness
  ;; ============================================================================

  (func $fft_dit_split_scalar (param $n i32)
    (local $log2n i32) (local $s i32) (local $m i32) (local $m2 i32)
    (local $k i32) (local $j i32)
    (local $tw_idx i32) (local $tw_stride i32)
    (local $idx0 i32) (local $idx1 i32)
    (local $u_re f32) (local $u_im f32)
    (local $t_re f32) (local $t_im f32)
    (local $w_re f32) (local $w_im f32)
    (local $x_re f32) (local $x_im f32)
    (local $tmp f32)
    (local $temp i32)

    ;; Compute log2(n)
    (local.set $log2n (i32.const 0))
    (local.set $temp (local.get $n))
    (block $done_log
      (loop $log_loop
        (br_if $done_log (i32.le_u (local.get $temp) (i32.const 1)))
        (local.set $temp (i32.shr_u (local.get $temp) (i32.const 1)))
        (local.set $log2n (i32.add (local.get $log2n) (i32.const 1)))
        (br $log_loop)
      )
    )

    ;; DIT stages: s = 0, 1, ..., log2(n)-1
    (local.set $s (i32.const 0))
    (block $done_stages
      (loop $stage_loop
        (br_if $done_stages (i32.ge_u (local.get $s) (local.get $log2n)))

        ;; m = 2^s (half butterfly size)
        ;; m2 = 2^(s+1) (full butterfly size)
        (local.set $m (i32.shl (i32.const 1) (local.get $s)))
        (local.set $m2 (i32.shl (local.get $m) (i32.const 1)))

        ;; Twiddle stride: N / m2
        (local.set $tw_stride (i32.div_u (local.get $n) (local.get $m2)))

        ;; For each butterfly group starting at k
        (local.set $k (i32.const 0))
        (block $done_groups
          (loop $group_loop
            (br_if $done_groups (i32.ge_u (local.get $k) (local.get $n)))

            ;; For each butterfly in the group
            (local.set $j (i32.const 0))
            (block $done_butterflies
              (loop $butterfly_loop
                (br_if $done_butterflies (i32.ge_u (local.get $j) (local.get $m)))

                ;; Indices for this butterfly
                (local.set $idx0 (i32.add (local.get $k) (local.get $j)))
                (local.set $idx1 (i32.add (local.get $idx0) (local.get $m)))

                ;; Twiddle factor W_N^(j * tw_stride)
                (local.set $tw_idx (i32.mul (local.get $j) (local.get $tw_stride)))
                (local.set $w_re (f32.load (i32.add (global.get $TWIDDLE_OFFSET)
                                                    (i32.shl (local.get $tw_idx) (i32.const 2)))))
                (local.set $w_im (f32.load (i32.add (global.get $TWIDDLE_OFFSET)
                                                    (i32.add (i32.shl (local.get $n) (i32.const 2))
                                                             (i32.shl (local.get $tw_idx) (i32.const 2))))))

                ;; Load u = X[idx0]
                (local.set $u_re (f32.load (i32.add (global.get $SPLIT_RE_OFFSET)
                                                    (i32.shl (local.get $idx0) (i32.const 2)))))
                (local.set $u_im (f32.load (i32.add (global.get $SPLIT_IM_OFFSET)
                                                    (i32.shl (local.get $idx0) (i32.const 2)))))

                ;; Load x = X[idx1]
                (local.set $x_re (f32.load (i32.add (global.get $SPLIT_RE_OFFSET)
                                                    (i32.shl (local.get $idx1) (i32.const 2)))))
                (local.set $x_im (f32.load (i32.add (global.get $SPLIT_IM_OFFSET)
                                                    (i32.shl (local.get $idx1) (i32.const 2)))))

                ;; t = x * w (complex multiply)
                ;; t_re = x_re * w_re - x_im * w_im
                ;; t_im = x_re * w_im + x_im * w_re
                (local.set $t_re (f32.sub (f32.mul (local.get $x_re) (local.get $w_re))
                                          (f32.mul (local.get $x_im) (local.get $w_im))))
                (local.set $t_im (f32.add (f32.mul (local.get $x_re) (local.get $w_im))
                                          (f32.mul (local.get $x_im) (local.get $w_re))))

                ;; X[idx0] = u + t
                (f32.store (i32.add (global.get $SPLIT_RE_OFFSET)
                                    (i32.shl (local.get $idx0) (i32.const 2)))
                           (f32.add (local.get $u_re) (local.get $t_re)))
                (f32.store (i32.add (global.get $SPLIT_IM_OFFSET)
                                    (i32.shl (local.get $idx0) (i32.const 2)))
                           (f32.add (local.get $u_im) (local.get $t_im)))

                ;; X[idx1] = u - t
                (f32.store (i32.add (global.get $SPLIT_RE_OFFSET)
                                    (i32.shl (local.get $idx1) (i32.const 2)))
                           (f32.sub (local.get $u_re) (local.get $t_re)))
                (f32.store (i32.add (global.get $SPLIT_IM_OFFSET)
                                    (i32.shl (local.get $idx1) (i32.const 2)))
                           (f32.sub (local.get $u_im) (local.get $t_im)))

                (local.set $j (i32.add (local.get $j) (i32.const 1)))
                (br $butterfly_loop)
              )
            )

            (local.set $k (i32.add (local.get $k) (local.get $m2)))
            (br $group_loop)
          )
        )

        (local.set $s (i32.add (local.get $s) (i32.const 1)))
        (br $stage_loop)
      )
    )
  )

  ;; ============================================================================
  ;; DIT FFT Core (Split Format) - SIMD version processing 4 at once
  ;; ============================================================================

  (func $fft_dit_split_simd (param $n i32)
    (local $log2n i32) (local $s i32) (local $m i32) (local $m2 i32)
    (local $k i32) (local $j i32)
    (local $tw_idx i32) (local $tw_stride i32)
    (local $idx0 i32) (local $idx1 i32)
    (local $u_re v128) (local $u_im v128)
    (local $t_re v128) (local $t_im v128)
    (local $w_re v128) (local $w_im v128)
    (local $x_re v128) (local $x_im v128)
    (local $tmp v128)
    (local $temp i32)
    (local $re_base i32) (local $im_base i32)
    (local $tw_re_base i32) (local $tw_im_base i32)
    ;; Scalar fallback locals
    (local $u_re_s f32) (local $u_im_s f32)
    (local $t_re_s f32) (local $t_im_s f32)
    (local $w_re_s f32) (local $w_im_s f32)
    (local $x_re_s f32) (local $x_im_s f32)

    ;; Compute log2(n)
    (local.set $log2n (i32.const 0))
    (local.set $temp (local.get $n))
    (block $done_log
      (loop $log_loop
        (br_if $done_log (i32.le_u (local.get $temp) (i32.const 1)))
        (local.set $temp (i32.shr_u (local.get $temp) (i32.const 1)))
        (local.set $log2n (i32.add (local.get $log2n) (i32.const 1)))
        (br $log_loop)
      )
    )

    (local.set $re_base (global.get $SPLIT_RE_OFFSET))
    (local.set $im_base (global.get $SPLIT_IM_OFFSET))
    (local.set $tw_re_base (global.get $TWIDDLE_OFFSET))
    (local.set $tw_im_base (i32.add (global.get $TWIDDLE_OFFSET)
                                     (i32.shl (local.get $n) (i32.const 2))))

    ;; DIT stages
    (local.set $s (i32.const 0))
    (block $done_stages
      (loop $stage_loop
        (br_if $done_stages (i32.ge_u (local.get $s) (local.get $log2n)))

        (local.set $m (i32.shl (i32.const 1) (local.get $s)))
        (local.set $m2 (i32.shl (local.get $m) (i32.const 1)))
        (local.set $tw_stride (i32.div_u (local.get $n) (local.get $m2)))

        (local.set $k (i32.const 0))
        (block $done_groups
          (loop $group_loop
            (br_if $done_groups (i32.ge_u (local.get $k) (local.get $n)))

            ;; Process butterflies in this group
            ;; For m >= 4, we can process 4 butterflies at once with SIMD
            (if (i32.ge_u (local.get $m) (i32.const 4))
              (then
                ;; SIMD path: process 4 butterflies at a time
                (local.set $j (i32.const 0))
                (block $done_simd
                  (loop $simd_loop
                    (br_if $done_simd (i32.ge_u (local.get $j) (local.get $m)))

                    (local.set $idx0 (i32.add (local.get $k) (local.get $j)))
                    (local.set $idx1 (i32.add (local.get $idx0) (local.get $m)))

                    ;; Load 4 twiddle factors
                    ;; W[j*stride], W[(j+1)*stride], W[(j+2)*stride], W[(j+3)*stride]
                    (local.set $tw_idx (i32.shl (i32.mul (local.get $j) (local.get $tw_stride)) (i32.const 2)))

                    ;; For tw_stride=1, twiddles are consecutive
                    ;; For tw_stride>1, we need to gather (not supported, fall back)
                    (if (i32.eq (local.get $tw_stride) (i32.const 1))
                      (then
                        ;; Consecutive twiddles - can load directly
                        (local.set $w_re (v128.load (i32.add (local.get $tw_re_base) (local.get $tw_idx))))
                        (local.set $w_im (v128.load (i32.add (local.get $tw_im_base) (local.get $tw_idx))))
                      )
                      (else
                        ;; Non-consecutive - gather 4 twiddles
                        (local.set $w_re (f32x4.replace_lane 0
                          (f32x4.replace_lane 1
                            (f32x4.replace_lane 2
                              (f32x4.replace_lane 3
                                (v128.const f32x4 0 0 0 0)
                                (f32.load (i32.add (local.get $tw_re_base)
                                  (i32.shl (i32.mul (i32.add (local.get $j) (i32.const 3)) (local.get $tw_stride)) (i32.const 2)))))
                              (f32.load (i32.add (local.get $tw_re_base)
                                (i32.shl (i32.mul (i32.add (local.get $j) (i32.const 2)) (local.get $tw_stride)) (i32.const 2)))))
                            (f32.load (i32.add (local.get $tw_re_base)
                              (i32.shl (i32.mul (i32.add (local.get $j) (i32.const 1)) (local.get $tw_stride)) (i32.const 2)))))
                          (f32.load (i32.add (local.get $tw_re_base)
                            (i32.shl (i32.mul (local.get $j) (local.get $tw_stride)) (i32.const 2))))))
                        (local.set $w_im (f32x4.replace_lane 0
                          (f32x4.replace_lane 1
                            (f32x4.replace_lane 2
                              (f32x4.replace_lane 3
                                (v128.const f32x4 0 0 0 0)
                                (f32.load (i32.add (local.get $tw_im_base)
                                  (i32.shl (i32.mul (i32.add (local.get $j) (i32.const 3)) (local.get $tw_stride)) (i32.const 2)))))
                              (f32.load (i32.add (local.get $tw_im_base)
                                (i32.shl (i32.mul (i32.add (local.get $j) (i32.const 2)) (local.get $tw_stride)) (i32.const 2)))))
                            (f32.load (i32.add (local.get $tw_im_base)
                              (i32.shl (i32.mul (i32.add (local.get $j) (i32.const 1)) (local.get $tw_stride)) (i32.const 2)))))
                          (f32.load (i32.add (local.get $tw_im_base)
                            (i32.shl (i32.mul (local.get $j) (local.get $tw_stride)) (i32.const 2))))))
                      )
                    )

                    ;; Load u = X[idx0:idx0+3]
                    (local.set $u_re (v128.load (i32.add (local.get $re_base)
                                                         (i32.shl (local.get $idx0) (i32.const 2)))))
                    (local.set $u_im (v128.load (i32.add (local.get $im_base)
                                                         (i32.shl (local.get $idx0) (i32.const 2)))))

                    ;; Load x = X[idx1:idx1+3]
                    (local.set $x_re (v128.load (i32.add (local.get $re_base)
                                                         (i32.shl (local.get $idx1) (i32.const 2)))))
                    (local.set $x_im (v128.load (i32.add (local.get $im_base)
                                                         (i32.shl (local.get $idx1) (i32.const 2)))))

                    ;; t = x * w (4 complex multiplies at once!)
                    ;; t_re = x_re * w_re - x_im * w_im
                    ;; t_im = x_re * w_im + x_im * w_re
                    (local.set $tmp (f32x4.mul (local.get $x_re) (local.get $w_im)))
                    (local.set $t_re (f32x4.sub
                      (f32x4.mul (local.get $x_re) (local.get $w_re))
                      (f32x4.mul (local.get $x_im) (local.get $w_im))))
                    (local.set $t_im (f32x4.add
                      (f32x4.mul (local.get $x_im) (local.get $w_re))
                      (local.get $tmp)))

                    ;; Store X[idx0] = u + t
                    (v128.store (i32.add (local.get $re_base) (i32.shl (local.get $idx0) (i32.const 2)))
                                (f32x4.add (local.get $u_re) (local.get $t_re)))
                    (v128.store (i32.add (local.get $im_base) (i32.shl (local.get $idx0) (i32.const 2)))
                                (f32x4.add (local.get $u_im) (local.get $t_im)))

                    ;; Store X[idx1] = u - t
                    (v128.store (i32.add (local.get $re_base) (i32.shl (local.get $idx1) (i32.const 2)))
                                (f32x4.sub (local.get $u_re) (local.get $t_re)))
                    (v128.store (i32.add (local.get $im_base) (i32.shl (local.get $idx1) (i32.const 2)))
                                (f32x4.sub (local.get $u_im) (local.get $t_im)))

                    (local.set $j (i32.add (local.get $j) (i32.const 4)))
                    (br $simd_loop)
                  )
                )
              )
              (else
                ;; Scalar path for m < 4
                (local.set $j (i32.const 0))
                (block $done_scalar
                  (loop $scalar_loop
                    (br_if $done_scalar (i32.ge_u (local.get $j) (local.get $m)))

                    (local.set $idx0 (i32.add (local.get $k) (local.get $j)))
                    (local.set $idx1 (i32.add (local.get $idx0) (local.get $m)))
                    (local.set $tw_idx (i32.mul (local.get $j) (local.get $tw_stride)))

                    ;; Load twiddle
                    (local.set $w_re_s (f32.load (i32.add (local.get $tw_re_base)
                                                          (i32.shl (local.get $tw_idx) (i32.const 2)))))
                    (local.set $w_im_s (f32.load (i32.add (local.get $tw_im_base)
                                                          (i32.shl (local.get $tw_idx) (i32.const 2)))))

                    ;; Load u
                    (local.set $u_re_s (f32.load (i32.add (local.get $re_base)
                                                          (i32.shl (local.get $idx0) (i32.const 2)))))
                    (local.set $u_im_s (f32.load (i32.add (local.get $im_base)
                                                          (i32.shl (local.get $idx0) (i32.const 2)))))

                    ;; Load x
                    (local.set $x_re_s (f32.load (i32.add (local.get $re_base)
                                                          (i32.shl (local.get $idx1) (i32.const 2)))))
                    (local.set $x_im_s (f32.load (i32.add (local.get $im_base)
                                                          (i32.shl (local.get $idx1) (i32.const 2)))))

                    ;; t = x * w
                    (local.set $t_re_s (f32.sub (f32.mul (local.get $x_re_s) (local.get $w_re_s))
                                                (f32.mul (local.get $x_im_s) (local.get $w_im_s))))
                    (local.set $t_im_s (f32.add (f32.mul (local.get $x_re_s) (local.get $w_im_s))
                                                (f32.mul (local.get $x_im_s) (local.get $w_re_s))))

                    ;; Store u + t and u - t
                    (f32.store (i32.add (local.get $re_base) (i32.shl (local.get $idx0) (i32.const 2)))
                               (f32.add (local.get $u_re_s) (local.get $t_re_s)))
                    (f32.store (i32.add (local.get $im_base) (i32.shl (local.get $idx0) (i32.const 2)))
                               (f32.add (local.get $u_im_s) (local.get $t_im_s)))
                    (f32.store (i32.add (local.get $re_base) (i32.shl (local.get $idx1) (i32.const 2)))
                               (f32.sub (local.get $u_re_s) (local.get $t_re_s)))
                    (f32.store (i32.add (local.get $im_base) (i32.shl (local.get $idx1) (i32.const 2)))
                               (f32.sub (local.get $u_im_s) (local.get $t_im_s)))

                    (local.set $j (i32.add (local.get $j) (i32.const 1)))
                    (br $scalar_loop)
                  )
                )
              )
            )

            (local.set $k (i32.add (local.get $k) (local.get $m2)))
            (br $group_loop)
          )
        )

        (local.set $s (i32.add (local.get $s) (i32.const 1)))
        (br $stage_loop)
      )
    )
  )

  ;; ============================================================================
  ;; Main FFT Entry Point
  ;; ============================================================================

  (func (export "fft") (param $n i32)
    ;; Step 1: Convert interleaved to split with bit-reversal
    (call $interleaved_to_split_bitrev (local.get $n))

    ;; Step 2: Run DIT FFT in split format
    (call $fft_dit_split_simd (local.get $n))

    ;; Step 3: Convert back to interleaved
    (call $split_to_interleaved (local.get $n))
  )
)
