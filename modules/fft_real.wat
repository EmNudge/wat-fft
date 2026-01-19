;; Real FFT (r2c - real to complex)
;; Leverages Stockham N/2-point complex FFT to compute N-point real FFT
;;
;; Algorithm:
;; 1. Pack N real values into N/2 complex: z[k] = x[2k] + i*x[2k+1]
;; 2. Run N/2-point Stockham FFT
;; 3. Post-process to extract N/2+1 unique frequency bins
;;
;; Memory layout:
;;   0 - 65535:        Real input / complex output buffer
;;   65536 - 131071:   Secondary buffer (Stockham ping-pong)
;;   131072 - 196607:  Complex FFT twiddles (for N/2-point FFT)
;;   196608+:          Post-processing twiddles W_N^k for k=0..N/2

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

;; Real FFT: N real inputs -> N/2+1 complex outputs
;; Input: N real values at offset 0 (float64, 8 bytes each)
;; Output: N/2+1 complex values at offset 0 (interleaved re,im, 16 bytes each)
;;
;; Post-processing formula:
;; X[0] = (Z[0].re + Z[0].im, 0)  (DC component)
;; X[N/2] = (Z[0].re - Z[0].im, 0)  (Nyquist component)
;; For k = 1 to N/2-1:
;;   X[k] = 0.5*(Z[k] + conj(Z[N/2-k])) - 0.5i*W_N^k*(Z[k] - conj(Z[N/2-k]))
(func $rfft (export "rfft") (param $n i32)
  (local $n2 i32)
  (local $k i32)
  (local $n2_minus_k i32)

  ;; Z[k] components
  (local $zk_re f64)
  (local $zk_im f64)

  ;; Z[N/2-k] and its conjugate
  (local $zn2k_re f64)
  (local $zn2k_im f64)

  ;; Twiddle W_N^k
  (local $w_re f64)
  (local $w_im f64)

  ;; Temporaries for computation
  (local $sum_re f64)   ;; Re(Z[k] + conj(Z[N/2-k]))
  (local $sum_im f64)   ;; Im(Z[k] + conj(Z[N/2-k]))
  (local $diff_re f64)  ;; Re(Z[k] - conj(Z[N/2-k]))
  (local $diff_im f64)  ;; Im(Z[k] - conj(Z[N/2-k]))

  ;; W * diff (complex multiplication)
  (local $wd_re f64)
  (local $wd_im f64)

  ;; Final result X[k]
  (local $xk_re f64)
  (local $xk_im f64)

  ;; Addresses
  (local $addr_k i32)
  (local $addr_n2k i32)
  (local $addr_tw i32)

  ;; Z[0] for DC and Nyquist
  (local $z0_re f64)
  (local $z0_im f64)

  ;; n2 = n / 2
  (local.set $n2 (i32.shr_u (local.get $n) (i32.const 1)))

  ;; Step 1: Pack N real values into N/2 complex values
  ;; z[k] = x[2k] + i*x[2k+1]
  ;; This is done in-place: read from real[2k], real[2k+1], write to complex[k]
  ;; We need to be careful - read from end to start to avoid overwriting
  ;; Actually for in-place packing where output[k] uses input[2k] and input[2k+1]:
  ;; output address = k * 16 bytes
  ;; input addresses = 2k * 8 = k * 16 bytes and (2k+1) * 8 = k*16 + 8 bytes
  ;; So input and output addresses are identical - no movement needed!
  ;; The real values are already in the right places, we just reinterpret them.

  ;; Step 2: Run N/2-point Stockham FFT
  (call $fft_stockham (local.get $n2))

  ;; Step 3: Post-process to extract N/2+1 unique bins

  ;; Load Z[0] for special cases
  (local.set $z0_re (f64.load (i32.const 0)))
  (local.set $z0_im (f64.load (i32.const 8)))

  ;; We'll store results in a temporary region, then copy back
  ;; Actually, we need to be careful since X[k] depends on Z[k] and Z[N/2-k]
  ;; and we'll overwrite Z values.
  ;; Strategy: Process from k=1 to N/4, compute both X[k] and X[N/2-k]
  ;; Then handle k=0, k=N/2, and k=N/4 (if N/2 is even) specially

  ;; First, handle DC (k=0): X[0] = (Z[0].re + Z[0].im, 0)
  ;; We'll write this at the end to not interfere

  ;; Process k from 1 to N/2-1
  ;; For each k, compute X[k] using Z[k] and Z[N/2-k]
  ;;
  ;; X[k] = 0.5*(Z[k] + conj(Z[N/2-k])) - 0.5i*W_N^k*(Z[k] - conj(Z[N/2-k]))
  ;;
  ;; Let A = Z[k] + conj(Z[N/2-k])
  ;;     B = Z[k] - conj(Z[N/2-k])
  ;; Then X[k] = 0.5*A - 0.5i*W*B
  ;;           = 0.5*A - 0.5*(i*W*B)
  ;;           = 0.5*A - 0.5*((i*W)*B)
  ;;
  ;; i*W = i*(w_re + i*w_im) = -w_im + i*w_re
  ;; So (i*W)*B = (-w_im + i*w_re)*(b_re + i*b_im)
  ;;            = -w_im*b_re - w_re*b_im + i*(-w_im*b_im + w_re*b_re)
  ;;            = (-w_im*b_re - w_re*b_im) + i*(w_re*b_re - w_im*b_im)
  ;;
  ;; X[k] = 0.5*(a_re + (-w_im*b_re - w_re*b_im)) + i*0.5*(a_im + (w_re*b_re - w_im*b_im))
  ;; Wait, that's a_re - (i*W*B).re = a_re - (-w_im*b_re - w_re*b_im)
  ;;
  ;; Let me redo this more carefully:
  ;; X[k] = 0.5*A - 0.5*i*W*B
  ;;
  ;; -i*W = -i*(w_re + i*w_im) = w_im - i*w_re
  ;; (-i*W)*B = (w_im - i*w_re)*(b_re + i*b_im)
  ;;          = w_im*b_re + i*w_im*b_im - i*w_re*b_re + w_re*b_im
  ;;          = (w_im*b_re + w_re*b_im) + i*(w_im*b_im - w_re*b_re)
  ;;
  ;; X[k] = 0.5*(a_re, a_im) + 0.5*((w_im*b_re + w_re*b_im), (w_im*b_im - w_re*b_re))
  ;;      = (0.5*(a_re + w_im*b_re + w_re*b_im), 0.5*(a_im + w_im*b_im - w_re*b_re))

  ;; Store results in secondary buffer first, then copy back
  ;; Actually we can work in-place if we're careful about the order
  ;; But it's safer to use secondary buffer for intermediate results

  (local.set $k (i32.const 1))
  (block $done_main
    (loop $main_loop
      (br_if $done_main (i32.ge_u (local.get $k) (local.get $n2)))

      (local.set $n2_minus_k (i32.sub (local.get $n2) (local.get $k)))

      ;; Load Z[k] = (zk_re, zk_im)
      (local.set $addr_k (i32.shl (local.get $k) (i32.const 4)))
      (local.set $zk_re (f64.load (local.get $addr_k)))
      (local.set $zk_im (f64.load (i32.add (local.get $addr_k) (i32.const 8))))

      ;; Load Z[N/2-k]
      (local.set $addr_n2k (i32.shl (local.get $n2_minus_k) (i32.const 4)))
      (local.set $zn2k_re (f64.load (local.get $addr_n2k)))
      (local.set $zn2k_im (f64.load (i32.add (local.get $addr_n2k) (i32.const 8))))
      ;; conj(Z[N/2-k]) = (zn2k_re, -zn2k_im)

      ;; Load twiddle W_N^k
      (local.set $addr_tw (i32.add (global.get $RFFT_TWIDDLE_OFFSET)
                                   (i32.shl (local.get $k) (i32.const 4))))
      (local.set $w_re (f64.load (local.get $addr_tw)))
      (local.set $w_im (f64.load (i32.add (local.get $addr_tw) (i32.const 8))))

      ;; A = Z[k] + conj(Z[N/2-k]) = (zk_re + zn2k_re, zk_im - zn2k_im)
      (local.set $sum_re (f64.add (local.get $zk_re) (local.get $zn2k_re)))
      (local.set $sum_im (f64.sub (local.get $zk_im) (local.get $zn2k_im)))

      ;; B = Z[k] - conj(Z[N/2-k]) = (zk_re - zn2k_re, zk_im + zn2k_im)
      (local.set $diff_re (f64.sub (local.get $zk_re) (local.get $zn2k_re)))
      (local.set $diff_im (f64.add (local.get $zk_im) (local.get $zn2k_im)))

      ;; Compute -i*W*B (see derivation above)
      ;; (-i*W)*B = (w_im*b_re + w_re*b_im) + i*(w_im*b_im - w_re*b_re)
      (local.set $wd_re (f64.add
        (f64.mul (local.get $w_im) (local.get $diff_re))
        (f64.mul (local.get $w_re) (local.get $diff_im))))
      (local.set $wd_im (f64.sub
        (f64.mul (local.get $w_im) (local.get $diff_im))
        (f64.mul (local.get $w_re) (local.get $diff_re))))

      ;; X[k] = 0.5*(A + (-i*W)*B)
      (local.set $xk_re (f64.mul (f64.const 0.5)
        (f64.add (local.get $sum_re) (local.get $wd_re))))
      (local.set $xk_im (f64.mul (f64.const 0.5)
        (f64.add (local.get $sum_im) (local.get $wd_im))))

      ;; Store X[k] to secondary buffer
      (f64.store (i32.add (global.get $SECONDARY_OFFSET) (local.get $addr_k))
        (local.get $xk_re))
      (f64.store (i32.add (global.get $SECONDARY_OFFSET) (i32.add (local.get $addr_k) (i32.const 8)))
        (local.get $xk_im))

      (local.set $k (i32.add (local.get $k) (i32.const 1)))
      (br $main_loop)
    )
  )

  ;; Store X[0] (DC component) to secondary buffer
  ;; X[0] = (Z[0].re + Z[0].im, 0)
  (f64.store (i32.add (global.get $SECONDARY_OFFSET) (i32.const 0))
    (f64.add (local.get $z0_re) (local.get $z0_im)))
  (f64.store (i32.add (global.get $SECONDARY_OFFSET) (i32.const 8))
    (f64.const 0.0))

  ;; Store X[N/2] (Nyquist component) to secondary buffer
  ;; X[N/2] = (Z[0].re - Z[0].im, 0)
  ;; Address for X[N/2] is n2 * 16 bytes
  (local.set $addr_k (i32.shl (local.get $n2) (i32.const 4)))
  (f64.store (i32.add (global.get $SECONDARY_OFFSET) (local.get $addr_k))
    (f64.sub (local.get $z0_re) (local.get $z0_im)))
  (f64.store (i32.add (global.get $SECONDARY_OFFSET) (i32.add (local.get $addr_k) (i32.const 8)))
    (f64.const 0.0))

  ;; Copy results from secondary buffer to primary buffer
  ;; Copy N/2+1 complex values = (n2+1)*16 bytes
  (local.set $k (i32.const 0))
  (block $done_copy
    (loop $copy_loop
      ;; k goes from 0 to n2 (inclusive), so n2+1 iterations
      (br_if $done_copy (i32.gt_u (local.get $k) (local.get $n2)))

      (local.set $addr_k (i32.shl (local.get $k) (i32.const 4)))

      ;; Copy using v128 for efficiency (16 bytes at once)
      (v128.store (local.get $addr_k)
        (v128.load (i32.add (global.get $SECONDARY_OFFSET) (local.get $addr_k))))

      (local.set $k (i32.add (local.get $k) (i32.const 1)))
      (br $copy_loop)
    )
  )
)
