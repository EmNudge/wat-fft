  ;; Fast FFT implementation with precomputed twiddle factors
  ;;
  ;; Uses Radix-2 Cooley-Tukey DIT algorithm with precomputed sin/cos
  ;; This avoids the expensive Taylor series computation in the hot loop
  ;;
  ;; Memory layout:
  ;;   [0, N*16): Input/output complex data (16 bytes per complex: 8 real + 8 imag)
  ;;   [131072, ...): Precomputed twiddle factors
  ;;
  ;; Note: Requires imports to be provided by glue.js:
  ;;   (import "math" "sin" (func $js_sin (param f64) (result f64)))
  ;;   (import "math" "cos" (func $js_cos (param f64) (result f64)))

  (global $TWIDDLE_OFFSET i32 (i32.const 131072))
  (global $FFT_TWO_PI f64 (f64.const 6.283185307179586))

  ;; Precompute twiddle factors for FFT of size N
  ;; Must be called before fft_fast() with the same N
  (func $precompute_twiddles (export "precompute_twiddles") (param $n i32)
    (local $i i32)
    (local $angle f64)
    (local $offset i32)

    (local.set $i (i32.const 0))
    (local.set $offset (global.get $TWIDDLE_OFFSET))

    ;; Compute W_N^k = exp(-2*pi*i*k/N) for k = 0 to N/2-1
    (loop $twiddle_loop
      (local.set $angle
        (f64.div
          (f64.mul (f64.convert_i32_u (local.get $i)) (f64.neg (global.get $FFT_TWO_PI)))
          (f64.convert_i32_u (local.get $n))
        )
      )

      ;; Store cos(angle) as real part
      (f64.store (local.get $offset) (call $js_cos (local.get $angle)))
      ;; Store sin(angle) as imag part
      (f64.store (i32.add (local.get $offset) (i32.const 8)) (call $js_sin (local.get $angle)))

      (local.set $offset (i32.add (local.get $offset) (i32.const 16)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $twiddle_loop (i32.lt_u (local.get $i) (i32.shr_u (local.get $n) (i32.const 1))))
    )
  )

  ;; Fast FFT using Radix-2 with precomputed twiddles
  ;; Requires precompute_twiddles(n) to be called first
  (func $fft_fast (export "fft_fast") (param $n i32)
    (local $log2n i32)
    (local $i i32)
    (local $j i32)
    (local $k i32)
    (local $m i32)

    (local $size i32)
    (local $half_size i32)

    (local $twiddle_addr i32)
    (local $twiddle_step i32)
    (local $twiddle_real f64)
    (local $twiddle_imag f64)

    (local $temp_real f64)
    (local $temp_imag f64)

    (local $even_real f64)
    (local $even_imag f64)
    (local $odd_real f64)
    (local $odd_imag f64)

    (local $i_addr i32)
    (local $j_addr i32)

    ;; Bit-reversal permutation
    (local.set $log2n (i32.ctz (local.get $n)))
    (local.set $i (i32.const 0))
    (loop $bit_reversal_loop
      (local.set $j (call $reverse_bits (local.get $i) (local.get $log2n)))
      (if (i32.lt_u (local.get $i) (local.get $j))
        (then
          (call $swap (i32.mul (local.get $i) (i32.const 16)) (i32.mul (local.get $j) (i32.const 16)))
          (call $swap (i32.add (i32.mul (local.get $i) (i32.const 16)) (i32.const 8)) (i32.add (i32.mul (local.get $j) (i32.const 16)) (i32.const 8)))
        )
      )
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br_if $bit_reversal_loop (i32.lt_u (local.get $i) (local.get $n)))
    )

    ;; Main FFT loop (Radix-2 with precomputed twiddles)
    (local.set $size (i32.const 2))
    (loop $fft_loop
      (local.set $half_size (i32.shr_u (local.get $size) (i32.const 1)))

      ;; Twiddle step: how much to advance in twiddle table per m increment
      ;; twiddle_step = N / size (each stage uses every N/size-th twiddle)
      (local.set $twiddle_step (i32.div_u (local.get $n) (local.get $size)))

      (local.set $m (i32.const 0))
      (loop $butterfly_loop
        ;; Load twiddle factor from precomputed table
        ;; Index into table: m * twiddle_step
        (local.set $twiddle_addr
          (i32.add
            (global.get $TWIDDLE_OFFSET)
            (i32.mul (i32.mul (local.get $m) (local.get $twiddle_step)) (i32.const 16))
          )
        )
        (local.set $twiddle_real (f64.load (local.get $twiddle_addr)))
        (local.set $twiddle_imag (f64.load (i32.add (local.get $twiddle_addr) (i32.const 8))))

        (local.set $k (i32.const 0))
        (loop $inner_loop
          (local.set $i (i32.add (local.get $k) (local.get $m)))
          (local.set $j (i32.add (local.get $i) (local.get $half_size)))

          ;; Calculate addresses
          (local.set $i_addr (i32.mul (local.get $i) (i32.const 16)))
          (local.set $j_addr (i32.mul (local.get $j) (i32.const 16)))

          ;; Load even and odd elements
          (local.set $even_real (f64.load (local.get $i_addr)))
          (local.set $even_imag (f64.load (i32.add (local.get $i_addr) (i32.const 8))))
          (local.set $odd_real (f64.load (local.get $j_addr)))
          (local.set $odd_imag (f64.load (i32.add (local.get $j_addr) (i32.const 8))))

          ;; temp = odd * twiddle
          (local.set $temp_real (f64.sub (f64.mul (local.get $odd_real) (local.get $twiddle_real)) (f64.mul (local.get $odd_imag) (local.get $twiddle_imag))))
          (local.set $temp_imag (f64.add (f64.mul (local.get $odd_real) (local.get $twiddle_imag)) (f64.mul (local.get $odd_imag) (local.get $twiddle_real))))

          ;; even_out = even + temp
          (f64.store (local.get $i_addr) (f64.add (local.get $even_real) (local.get $temp_real)))
          (f64.store (i32.add (local.get $i_addr) (i32.const 8)) (f64.add (local.get $even_imag) (local.get $temp_imag)))

          ;; odd_out = even - temp
          (f64.store (local.get $j_addr) (f64.sub (local.get $even_real) (local.get $temp_real)))
          (f64.store (i32.add (local.get $j_addr) (i32.const 8)) (f64.sub (local.get $even_imag) (local.get $temp_imag)))

          (local.set $k (i32.add (local.get $k) (local.get $size)))
          (br_if $inner_loop (i32.lt_u (local.get $k) (local.get $n)))
        )

        (local.set $m (i32.add (local.get $m) (i32.const 1)))
        (br_if $butterfly_loop (i32.lt_u (local.get $m) (local.get $half_size)))
      )

      (local.set $size (i32.shl (local.get $size) (i32.const 1)))
      (br_if $fft_loop (i32.le_u (local.get $size) (local.get $n)))
    )
  )
