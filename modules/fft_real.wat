(module
  ;; Real FFT (r2c - real to complex)
  ;;
  ;; Optimized with in-place post-processing to eliminate buffer copy.
  ;;
  ;; Algorithm:
  ;; 1. N real values are treated as N/2 complex: z[k] = x[2k] + i*x[2k+1]
  ;; 2. Run N/2-point Stockham FFT (result in primary buffer)
  ;; 3. In-place post-process: for k=1 to N/4, compute and store X[k], X[N/2-k]
  ;;
  ;; Memory layout:
  ;;   0 - 65535:        Real input / complex output buffer
  ;;   65536 - 131071:   Secondary buffer (Stockham ping-pong)
  ;;   131072 - 196607:  Complex FFT twiddles (for N/2-point FFT)
  ;;   196608+:          Post-processing twiddles W_N^k for k=0..N/2

  ;; Trig imports
  (import "math" "sin" (func $js_sin (param f64) (result f64)))
  (import "math" "cos" (func $js_cos (param f64) (result f64)))

  ;; Stockham FFT imports - provided by fft_stockham module
  (import "stockham" "precompute_twiddles" (func $precompute_twiddles (param i32)))
  (import "stockham" "fft_stockham" (func $fft_stockham (param i32)))

  ;; Memory (4 pages = 256KB, same layout as stockham)
  (memory (export "memory") 4)

  ;; Post-processing twiddle offset (after complex FFT twiddles)
  (global $RFFT_TWIDDLE_OFFSET i32 (i32.const 196608))

  ;; Precompute twiddles for real FFT of size N
  ;; This precomputes:
  ;; 1. N/2-point complex FFT twiddles (using existing precompute_twiddles)
  ;; 2. Post-processing twiddles W_N^k = e^{-2*pi*i*k/N} for k=0..N/2
  (func $precompute_rfft_twiddles (export "precompute_rfft_twiddles") (param $n i32)
    (local $n2 i32)
    (local $k i32)
    (local $angle f64)
    (local $addr i32)
    (local $neg_two_pi_over_n f64)

    ;; n2 = n / 2
    (local.set $n2 (i32.shr_u (local.get $n) (i32.const 1)))

    ;; Precompute N/2-point FFT twiddles
    (call $precompute_twiddles (local.get $n2))

    ;; Precompute post-processing twiddles W_N^k for k = 0 to N/2
    ;; W_N^k = cos(-2*pi*k/N) + i*sin(-2*pi*k/N)
    (local.set $neg_two_pi_over_n
      (f64.div
        (f64.mul (f64.const -2.0) (f64.const 3.141592653589793))
        (f64.convert_i32_u (local.get $n))))

    (local.set $k (i32.const 0))
    (block $done
      (loop $loop
        ;; Loop until k > n2 (we need k = 0 to N/2 inclusive)
        (br_if $done (i32.gt_u (local.get $k) (local.get $n2)))

        (local.set $angle
          (f64.mul (f64.convert_i32_u (local.get $k)) (local.get $neg_two_pi_over_n)))

        ;; Store at RFFT_TWIDDLE_OFFSET + k * 16 bytes (each complex is 16 bytes)
        (local.set $addr (i32.add (global.get $RFFT_TWIDDLE_OFFSET)
                                  (i32.shl (local.get $k) (i32.const 4))))

        (f64.store (local.get $addr) (call $js_cos (local.get $angle)))
        (f64.store (i32.add (local.get $addr) (i32.const 8)) (call $js_sin (local.get $angle)))

        (local.set $k (i32.add (local.get $k) (i32.const 1)))
        (br $loop)
      )
    )
  )

  ;; In-place Real FFT: N real inputs -> N/2+1 complex outputs
  ;; Input: N real values at offset 0 (float64, 8 bytes each)
  ;; Output: N/2+1 complex values at offset 0 (interleaved re,im, 16 bytes each)
  ;;
  ;; Key optimization: When computing X[k] and X[N/2-k] together, we read Z[k]
  ;; and Z[N/2-k], then can safely overwrite both positions since we've already
  ;; read the inputs. This eliminates the need for a secondary buffer and copy.
  (func $rfft (export "rfft") (param $n i32)
    (local $n2 i32)
    (local $k i32)
    (local $k_end i32)
    (local $n2_minus_k i32)

    ;; Z[k] and Z[N/2-k] values
    (local $zk_re f64)
    (local $zk_im f64)
    (local $zn2k_re f64)
    (local $zn2k_im f64)

    ;; Twiddles
    (local $wk_re f64)
    (local $wk_im f64)
    (local $wn2k_re f64)
    (local $wn2k_im f64)

    ;; Intermediates for X[k]
    (local $sum_re f64)
    (local $sum_im f64)
    (local $diff_re f64)
    (local $diff_im f64)
    (local $wd_re f64)
    (local $wd_im f64)

    ;; Intermediates for X[N/2-k]
    (local $sum2_re f64)
    (local $sum2_im f64)
    (local $diff2_re f64)
    (local $diff2_im f64)
    (local $wd2_re f64)
    (local $wd2_im f64)

    ;; Results
    (local $xk_re f64)
    (local $xk_im f64)
    (local $xn2k_re f64)
    (local $xn2k_im f64)

    ;; Addresses
    (local $addr_k i32)
    (local $addr_n2k i32)

    ;; Z[0] for DC and Nyquist
    (local $z0_re f64)
    (local $z0_im f64)

    ;; n2 = n / 2
    (local.set $n2 (i32.shr_u (local.get $n) (i32.const 1)))

    ;; Step 1: Input already packed as z[k] = x[2k] + i*x[2k+1]
    ;; Step 2: Run N/2-point Stockham FFT
    (call $fft_stockham (local.get $n2))

    ;; Step 3: In-place post-processing

    ;; Save Z[0] before it gets overwritten
    (local.set $z0_re (f64.load (i32.const 0)))
    (local.set $z0_im (f64.load (i32.const 8)))

    ;; First, store DC (X[0]) - this overwrites Z[0] but we've saved it
    ;; X[0] = (Z[0].re + Z[0].im, 0)
    (f64.store (i32.const 0) (f64.add (local.get $z0_re) (local.get $z0_im)))
    (f64.store (i32.const 8) (f64.const 0.0))

    ;; Store Nyquist (X[N/2]) - position n2*16
    ;; X[N/2] = (Z[0].re - Z[0].im, 0)
    (local.set $addr_k (i32.shl (local.get $n2) (i32.const 4)))
    (f64.store (local.get $addr_k) (f64.sub (local.get $z0_re) (local.get $z0_im)))
    (f64.store (i32.add (local.get $addr_k) (i32.const 8)) (f64.const 0.0))

    ;; Process k from 1 to n2/2 (exclusive)
    ;; For each k, compute both X[k] and X[N/2-k] from Z[k] and Z[N/2-k]
    (local.set $k_end (i32.shr_u (local.get $n2) (i32.const 1)))
    (local.set $k (i32.const 1))

    (block $done_main
      (loop $main_loop
        (br_if $done_main (i32.ge_u (local.get $k) (local.get $k_end)))

        (local.set $n2_minus_k (i32.sub (local.get $n2) (local.get $k)))
        (local.set $addr_k (i32.shl (local.get $k) (i32.const 4)))
        (local.set $addr_n2k (i32.shl (local.get $n2_minus_k) (i32.const 4)))

        ;; Load Z[k]
        (local.set $zk_re (f64.load (local.get $addr_k)))
        (local.set $zk_im (f64.load (i32.add (local.get $addr_k) (i32.const 8))))

        ;; Load Z[N/2-k]
        (local.set $zn2k_re (f64.load (local.get $addr_n2k)))
        (local.set $zn2k_im (f64.load (i32.add (local.get $addr_n2k) (i32.const 8))))

        ;; Load twiddle W_N^k
        (local.set $wk_re (f64.load (i32.add (global.get $RFFT_TWIDDLE_OFFSET)
                                            (i32.shl (local.get $k) (i32.const 4)))))
        (local.set $wk_im (f64.load (i32.add (global.get $RFFT_TWIDDLE_OFFSET)
                                            (i32.add (i32.shl (local.get $k) (i32.const 4)) (i32.const 8)))))

        ;; Load twiddle W_N^{N/2-k}
        (local.set $wn2k_re (f64.load (i32.add (global.get $RFFT_TWIDDLE_OFFSET)
                                              (i32.shl (local.get $n2_minus_k) (i32.const 4)))))
        (local.set $wn2k_im (f64.load (i32.add (global.get $RFFT_TWIDDLE_OFFSET)
                                              (i32.add (i32.shl (local.get $n2_minus_k) (i32.const 4)) (i32.const 8)))))

        ;; === Compute X[k] ===
        ;; A = Z[k] + conj(Z[N/2-k]) = (zk_re + zn2k_re, zk_im - zn2k_im)
        (local.set $sum_re (f64.add (local.get $zk_re) (local.get $zn2k_re)))
        (local.set $sum_im (f64.sub (local.get $zk_im) (local.get $zn2k_im)))

        ;; B = Z[k] - conj(Z[N/2-k]) = (zk_re - zn2k_re, zk_im + zn2k_im)
        (local.set $diff_re (f64.sub (local.get $zk_re) (local.get $zn2k_re)))
        (local.set $diff_im (f64.add (local.get $zk_im) (local.get $zn2k_im)))

        ;; -i*W*B = (w_im*b_re + w_re*b_im, w_im*b_im - w_re*b_re)
        (local.set $wd_re (f64.add
          (f64.mul (local.get $wk_im) (local.get $diff_re))
          (f64.mul (local.get $wk_re) (local.get $diff_im))))
        (local.set $wd_im (f64.sub
          (f64.mul (local.get $wk_im) (local.get $diff_im))
          (f64.mul (local.get $wk_re) (local.get $diff_re))))

        ;; X[k] = 0.5*(A + (-i*W*B))
        (local.set $xk_re (f64.mul (f64.const 0.5)
          (f64.add (local.get $sum_re) (local.get $wd_re))))
        (local.set $xk_im (f64.mul (f64.const 0.5)
          (f64.add (local.get $sum_im) (local.get $wd_im))))

        ;; === Compute X[N/2-k] ===
        ;; A' = Z[N/2-k] + conj(Z[k]) = (zn2k_re + zk_re, zn2k_im - zk_im)
        (local.set $sum2_re (f64.add (local.get $zn2k_re) (local.get $zk_re)))
        (local.set $sum2_im (f64.sub (local.get $zn2k_im) (local.get $zk_im)))

        ;; B' = Z[N/2-k] - conj(Z[k]) = (zn2k_re - zk_re, zn2k_im + zk_im)
        (local.set $diff2_re (f64.sub (local.get $zn2k_re) (local.get $zk_re)))
        (local.set $diff2_im (f64.add (local.get $zn2k_im) (local.get $zk_im)))

        ;; -i*W'*B' using W_{N/2-k}
        (local.set $wd2_re (f64.add
          (f64.mul (local.get $wn2k_im) (local.get $diff2_re))
          (f64.mul (local.get $wn2k_re) (local.get $diff2_im))))
        (local.set $wd2_im (f64.sub
          (f64.mul (local.get $wn2k_im) (local.get $diff2_im))
          (f64.mul (local.get $wn2k_re) (local.get $diff2_re))))

        ;; X[N/2-k] = 0.5*(A' + (-i*W'*B'))
        (local.set $xn2k_re (f64.mul (f64.const 0.5)
          (f64.add (local.get $sum2_re) (local.get $wd2_re))))
        (local.set $xn2k_im (f64.mul (f64.const 0.5)
          (f64.add (local.get $sum2_im) (local.get $wd2_im))))

        ;; Store X[k] and X[N/2-k] in-place
        (f64.store (local.get $addr_k) (local.get $xk_re))
        (f64.store (i32.add (local.get $addr_k) (i32.const 8)) (local.get $xk_im))
        (f64.store (local.get $addr_n2k) (local.get $xn2k_re))
        (f64.store (i32.add (local.get $addr_n2k) (i32.const 8)) (local.get $xn2k_im))

        (local.set $k (i32.add (local.get $k) (i32.const 1)))
        (br $main_loop)
      )
    )

    ;; Handle middle element when N/2 is even (k = N/4)
    ;; X[N/4] when n2 is even and > 2
    (if (i32.and (i32.eqz (i32.and (local.get $n2) (i32.const 1)))
                 (i32.gt_u (local.get $n2) (i32.const 2)))
      (then
        (local.set $addr_k (i32.shl (local.get $k_end) (i32.const 4)))

        ;; Load Z[N/4]
        (local.set $zk_re (f64.load (local.get $addr_k)))
        (local.set $zk_im (f64.load (i32.add (local.get $addr_k) (i32.const 8))))

        ;; Load W_{N/4}
        (local.set $wk_re (f64.load (i32.add (global.get $RFFT_TWIDDLE_OFFSET)
                                            (i32.shl (local.get $k_end) (i32.const 4)))))
        (local.set $wk_im (f64.load (i32.add (global.get $RFFT_TWIDDLE_OFFSET)
                                            (i32.add (i32.shl (local.get $k_end) (i32.const 4)) (i32.const 8)))))

        ;; For k = N/4 = n2/2, Z[N/2-k] = Z[k]
        ;; A = Z[k] + conj(Z[k]) = (2*zk_re, 0)
        ;; B = Z[k] - conj(Z[k]) = (0, 2*zk_im)
        (local.set $sum_re (f64.mul (f64.const 2.0) (local.get $zk_re)))
        (local.set $sum_im (f64.const 0.0))
        (local.set $diff_re (f64.const 0.0))
        (local.set $diff_im (f64.mul (f64.const 2.0) (local.get $zk_im)))

        ;; -i*W*B
        (local.set $wd_re (f64.add
          (f64.mul (local.get $wk_im) (local.get $diff_re))
          (f64.mul (local.get $wk_re) (local.get $diff_im))))
        (local.set $wd_im (f64.sub
          (f64.mul (local.get $wk_im) (local.get $diff_im))
          (f64.mul (local.get $wk_re) (local.get $diff_re))))

        ;; X[N/4] = 0.5*(A + (-i*W*B))
        (local.set $xk_re (f64.mul (f64.const 0.5)
          (f64.add (local.get $sum_re) (local.get $wd_re))))
        (local.set $xk_im (f64.mul (f64.const 0.5)
          (f64.add (local.get $sum_im) (local.get $wd_im))))

        ;; Store X[N/4]
        (f64.store (local.get $addr_k) (local.get $xk_re))
        (f64.store (i32.add (local.get $addr_k) (i32.const 8)) (local.get $xk_im))
      )
    )
  )
) ;; end module
