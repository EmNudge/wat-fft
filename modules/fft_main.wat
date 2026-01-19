(module
  ;; Original Radix-2 Cooley-Tukey FFT implementation
  ;;
  ;; This is the basic FFT with embedded trig computation (no precomputed twiddles).
  ;; Used for the combined.wasm build with math_trig.
  ;;
  ;; Memory layout:
  ;;   [0, N*16): Complex data (16 bytes per complex: 8 real + 8 imag)

  ;; Imports - uses internal trig functions from math_trig module
  ;; When built standalone, these come from "math" namespace
  (import "math" "sin" (func $sin (param f64) (result f64)))
  (import "math" "cos" (func $cos (param f64) (result f64)))
  (import "bits" "reverse_bits" (func $reverse_bits (param i32 i32) (result i32)))

  ;; Memory (1 page = 64KB)
  (memory (export "memory") 1)

  ;; Swap two f64 values in memory
  (func $swap (param $a i32) (param $b i32)
    (local $temp f64)
    (local.set $temp (f64.load (local.get $a)))
    (f64.store (local.get $a) (f64.load (local.get $b)))
    (f64.store (local.get $b) (local.get $temp))
  )

  (func $fft (export "fft") (param $n i32)
    (local $log2n i32)
    (local $i i32)
    (local $j i32)
    (local $k i32)
    (local $m i32)

    (local $size i32)
    (local $half_size i32)

    (local $angle f64)
    (local $twiddle_real f64)
    (local $twiddle_imag f64)

    (local $temp_real f64)
    (local $temp_imag f64)

    (local $even_real f64)
    (local $even_imag f64)
    (local $odd_real f64)
    (local $odd_imag f64)

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

    ;; Main FFT loop
    (local.set $size (i32.const 2))
    (loop $fft_loop
      (local.set $half_size (i32.shr_u (local.get $size) (i32.const 1)))
      (local.set $m (i32.const 0))
      (loop $butterfly_loop
        (local.set $angle (f64.div (f64.mul (f64.convert_i32_u (local.get $m)) (f64.const -6.283185307179586)) (f64.convert_i32_u (local.get $size))))
        (local.set $twiddle_real (call $cos (local.get $angle)))
        (local.set $twiddle_imag (call $sin (local.get $angle)))

          (local.set $k (i32.const 0))
        (loop $inner_loop
          (local.set $i (i32.add (local.get $k) (local.get $m)))
          (local.set $j (i32.add (local.get $i) (local.get $half_size)))

          (local.set $even_real (f64.load (i32.mul (local.get $i) (i32.const 16))))
          (local.set $even_imag (f64.load (i32.add (i32.mul (local.get $i) (i32.const 16)) (i32.const 8))))

          (local.set $odd_real (f64.load (i32.mul (local.get $j) (i32.const 16))))
          (local.set $odd_imag (f64.load (i32.add (i32.mul (local.get $j) (i32.const 16)) (i32.const 8))))

          (local.set $temp_real (f64.sub (f64.mul (local.get $odd_real) (local.get $twiddle_real)) (f64.mul (local.get $odd_imag) (local.get $twiddle_imag))))
          (local.set $temp_imag (f64.add (f64.mul (local.get $odd_real) (local.get $twiddle_imag)) (f64.mul (local.get $odd_imag) (local.get $twiddle_real))))

          (f64.store (i32.mul (local.get $i) (i32.const 16)) (f64.add (local.get $even_real) (local.get $temp_real)))
          (f64.store (i32.add (i32.mul (local.get $i) (i32.const 16)) (i32.const 8)) (f64.add (local.get $even_imag) (local.get $temp_imag)))

          (f64.store (i32.mul (local.get $j) (i32.const 16)) (f64.sub (local.get $even_real) (local.get $temp_real)))
          (f64.store (i32.add (i32.mul (local.get $j) (i32.const 16)) (i32.const 8)) (f64.sub (local.get $even_imag) (local.get $temp_imag)))

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
) ;; end module
