# How It Works

This document explains the algorithms and data structures used in wat-fft.

## Real FFT Algorithm

The real FFT exploits conjugate symmetry of real-valued input to compute an N-point real FFT using an N/2-point complex FFT:

1. **Pack**: N real values into N/2 complex: `z[k] = x[2k] + i*x[2k+1]`
2. **Transform**: Run N/2-point Stockham FFT on packed data
3. **Unpack**: Post-process to extract N/2+1 unique frequency bins

Post-processing formula for k = 1 to N/2-1:

```
X[k] = 0.5*(Z[k] + conj(Z[N/2-k])) - 0.5i*W_N^k*(Z[k] - conj(Z[N/2-k]))
```

Special cases: `X[0] = Z[0].re + Z[0].im`, `X[N/2] = Z[0].re - Z[0].im`

## Memory Layout

Complex numbers are stored interleaved:

- Each complex number: 16 bytes (8 bytes real + 8 bytes imaginary)
- Data starts at offset 0
- Secondary buffer (Stockham ping-pong): offset 65536 (64KB)
- Complex FFT twiddle factors: offset 131072 (128KB)
- Real FFT post-processing twiddles: offset 196608 (192KB)

## SIMD Complex Multiply

```wat
;; Complex multiply using v128: (a + bi)(c + di) = (ac-bd) + (ad+bc)i
(func $simd_cmul (param $a v128) (param $b v128) (result v128)
  ;; Shuffle to get [d, c] from [c, d]
  ;; Multiply and combine with sign mask for subtraction
  ...)
```

## Stockham FFT

The Stockham algorithm is a variant of the Cooley-Tukey FFT that avoids bit-reversal permutation by using two buffers (ping-pong). This provides several advantages:

- **No bit-reversal**: Output naturally arrives in correct order
- **Sequential access**: Better cache utilization
- **Simpler indexing**: Easier to vectorize with SIMD

Each stage reads from one buffer and writes to the other, swapping roles between stages.

## Radix-4 FFT

Radix-4 processes 4 elements per butterfly instead of 2, reducing the number of stages from log₂(N) to log₄(N). This means:

- **50% fewer stages**: Less loop overhead
- **Fewer twiddle factor loads**: Better memory efficiency
- **More computation per iteration**: Better instruction-level parallelism

The radix-4 butterfly computes:

```
y0 = x0 + x1 + x2 + x3
y1 = x0 - i*x1 - x2 + i*x3
y2 = x0 - x1 + x2 - x3
y3 = x0 + i*x1 - x2 - i*x3
```

## Twiddle Factors

Twiddle factors are the complex exponentials `W_N^k = e^(-2πik/N)` used in FFT butterflies. wat-fft precomputes these to avoid repeated trigonometric calculations:

- **Complex FFT twiddles**: Stored at offset 128KB
- **Real FFT post-processing twiddles**: Stored at offset 192KB

The `precompute_twiddles(N)` function must be called before running the FFT.

## Taylor Series for Trigonometry

To avoid JavaScript import overhead, wat-fft computes sin/cos inline using an 8-term Taylor series:

```
sin(x) ≈ x - x³/3! + x⁵/5! - x⁷/7! + ...
cos(x) ≈ 1 - x²/2! + x⁴/4! - x⁶/6! + ...
```

With range reduction to [-π/2, π/2], this achieves ~10⁻¹⁰ accuracy per operation, which accumulates to ~10⁻⁹ overall FFT accuracy.
