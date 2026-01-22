# wat-fft

A high-performance FFT implementation in WebAssembly Text format that **significantly outperforms popular JavaScript FFT libraries**.

## Performance

### Complex FFT

Benchmarked against [fft.js](https://github.com/indutny/fft.js) (the fastest pure-JS FFT) and [fft-js](https://github.com/vail-systems/node-fft):

| Size   | wat-fft (Combined)   | fft.js           | Speedup vs fft.js |
| ------ | -------------------- | ---------------- | ----------------- |
| N=16   | **16,066,000 ops/s** | 11,613,000 ops/s | **1.38x**         |
| N=32   | **6,168,000 ops/s**  | 5,133,000 ops/s  | **1.20x**         |
| N=64   | **3,898,000 ops/s**  | 2,842,000 ops/s  | **1.37x**         |
| N=128  | **1,610,000 ops/s**  | 1,110,000 ops/s  | **1.45x**         |
| N=256  | **989,000 ops/s**    | 571,000 ops/s    | **1.73x**         |
| N=512  | **351,000 ops/s**    | 227,000 ops/s    | **1.54x**         |
| N=1024 | **198,000 ops/s**    | 115,000 ops/s    | **1.72x**         |
| N=2048 | **74,200 ops/s**     | 48,200 ops/s     | **1.54x**         |
| N=4096 | **44,600 ops/s**     | 24,100 ops/s     | **1.85x**         |

```mermaid
---
config:
    xyChart:
        width: 700
        height: 400
    themeVariables:
        xyChart:
            plotColorPalette: "#4ade80, #60a5fa, #a855f7, #f87171"
---
xychart-beta
    title "Complex FFT Performance (Million ops/s)"
    x-axis [N=16, N=32, N=64, N=128, N=256, N=512, N=1024, N=2048, N=4096]
    y-axis "Million ops/s" 0 --> 18
    line [16.05, 6.12, 3.87, 1.59, 0.98, 0.35, 0.20, 0.07, 0.04]
    line [11.57, 5.08, 2.81, 1.10, 0.57, 0.23, 0.11, 0.05, 0.02]
    line [6.08, 3.14, 1.92, 0.81, 0.45, 0.18, 0.10, 0.04, 0.02]
    line [0.59, 0.27, 0.12, 0.05, 0.02, 0.003, 0.001, 0.001, 0.0003]
```

> 🟢 **wat-fft** · 🔵 **fft.js** · 🟣 **kissfft-js** · 🔴 **fft-js**

**wat-fft Combined** auto-selects the optimal algorithm (radix-4 for power-of-4 sizes, radix-2 for others), achieving up to **1.87x speedup** over fft.js at N=4096.

### Real FFT

Benchmarked against [fftw-js](https://www.npmjs.com/package/fftw-js) (Emscripten port of FFTW):

| Size   | wat-fft rfft (f64)   | fftw-js (f32)       | Comparison  |
| ------ | -------------------- | ------------------- | ----------- |
| N=8    | **24,159,000 ops/s** | 10,793,000 ops/s    | **+123.8%** |
| N=16   | **12,487,000 ops/s** | 10,266,000 ops/s    | **+21.6%**  |
| N=32   | **13,140,000 ops/s** | 9,017,000 ops/s     | **+45.7%**  |
| N=64   | 4,807,000 ops/s      | **6,858,000 ops/s** | -29.9%      |
| N=128  | 2,897,000 ops/s      | **4,357,000 ops/s** | -33.5%      |
| N=256  | 1,258,000 ops/s      | **1,530,000 ops/s** | -17.8%      |
| N=512  | 736,000 ops/s        | **922,000 ops/s**   | -20.2%      |
| N=1024 | 281,000 ops/s        | **476,000 ops/s**   | -41.0%      |
| N=2048 | 155,000 ops/s        | **233,000 ops/s**   | -33.3%      |
| N=4096 | 62,000 ops/s         | **106,000 ops/s**   | -41.4%      |

```mermaid
---
config:
    xyChart:
        width: 700
        height: 400
    themeVariables:
        xyChart:
            plotColorPalette: "#4ade80, #f87171, #a855f7"
---
xychart-beta
    title "Real FFT Performance (Million ops/s)"
    x-axis [N=8, N=16, N=32, N=64, N=128, N=256, N=512, N=1024, N=2048, N=4096]
    y-axis "Million ops/s" 0 --> 26
    line [24.16, 12.49, 13.14, 4.81, 2.90, 1.26, 0.74, 0.28, 0.15, 0.06]
    line [10.79, 10.27, 9.02, 6.86, 4.36, 1.53, 0.92, 0.48, 0.23, 0.11]
    line [11.21, 7.90, 5.91, 3.00, 1.76, 0.78, 0.43, 0.18, 0.09, 0.04]
```

> 🟢 **wat-fft (f64)** · 🔴 **fftw-js (f32)** · 🟣 **kissfft-js (f32)**

**wat-fft beats fftw-js at small sizes (N≤32)** with massive speedups: **+124% at N=8** and **+46% at N=32**. This is achieved through fused rfft codelets that eliminate function call overhead and twiddle memory loads. For larger sizes, fftw-js (compiled from highly optimized FFTW C library with hierarchical codelets) is faster.

Note: The real FFT achieves ~2x speedup over complex FFT by computing only N/2 complex FFT internally. For small sizes (N≤32), fused rfft codelets with hardcoded twiddles provide additional speedups by eliminating memory loads and function call overhead.

## Quick Start

```bash
# Install dependencies
npm install

# Build WASM modules
npm run build

# Run tests
npm test

# Run benchmarks
npm run bench
```

### Prerequisites

- Node.js v18+
- [wasm-tools](https://github.com/bytecodealliance/wasm-tools)

```bash
cargo install wasm-tools
```

## Usage

```javascript
import fs from "fs";

// Load the WASM module (Stockham is recommended for best performance)
// No JavaScript imports needed - trig functions are computed inline
const wasmBuffer = fs.readFileSync("dist/combined_stockham.wasm");
const wasmModule = await WebAssembly.compile(wasmBuffer);
const instance = await WebAssembly.instantiate(wasmModule);
const fft = instance.exports;

// Prepare input (interleaved complex: [re0, im0, re1, im1, ...])
const N = 1024;
const data = new Float64Array(fft.memory.buffer, 0, N * 2);
for (let i = 0; i < N; i++) {
  data[i * 2] = Math.sin((2 * Math.PI * i) / N); // real
  data[i * 2 + 1] = 0; // imaginary
}

// Compute FFT
fft.precompute_twiddles(N);
fft.fft_stockham(N);

// Results are in-place in data[]
console.log("DC component:", data[0], data[1]);
```

## Implementations

Four FFT implementations are provided:

| Module                   | Algorithm                 | Best For                 | Speed           |
| ------------------------ | ------------------------- | ------------------------ | --------------- |
| `fft_combined.wasm`      | Radix-4 + Radix-2 auto    | **All power-of-2 sizes** | **Recommended** |
| `fft_real_combined.wasm` | Real FFT + auto dispatch  | **Real signals (any)**   | **Recommended** |
| `fft_radix4.wasm`        | Radix-4 Stockham + SIMD   | Complex FFT, pow-of-4    | Fastest cfft    |
| `fft_real_radix4.wasm`   | Real FFT + Radix-4        | Real signals, pow-of-4   | Fastest rfft    |
| `combined_stockham.wasm` | Radix-2 Stockham + SIMD   | All power-of-2 sizes     | Fast            |
| `combined_real.wasm`     | Real FFT (r2c) + Stockham | Real-valued signals      | Fast            |
| `combined_fast.wasm`     | Radix-2 (no SIMD)         | No SIMD support          | Medium          |

### Numerical Accuracy

The accuracy difference between implementations comes from trigonometric function computation:

- **Stockham/Real (~10⁻⁹)**: Uses inline 8-term Taylor series for sin/cos to avoid JavaScript import overhead. The Taylor series achieves ~10⁻¹⁰ accuracy per twiddle factor after range reduction to [-π/2, π/2]. Errors accumulate through log₂(N) butterfly stages, resulting in ~10⁻⁹ overall accuracy for typical FFT sizes.

- **Fast (~10⁻¹⁴)**: Uses JavaScript's `Math.sin`/`Math.cos` which provide full double-precision accuracy (~10⁻¹⁵), resulting in ~10⁻¹⁴ overall FFT accuracy.

**Test tolerances** are derived from these characteristics:

- Relative tolerance: `1e-9` (matches Taylor series single-operation error)
- Size scaling: `max(1e-9, N × 2e-11)` accounts for error accumulation in larger transforms
- Absolute floor: `5e-4` for property tests handles near-zero values where relative error is meaningless

For most signal processing applications, ~10⁻⁹ accuracy is more than sufficient. Use `combined_fast.wasm` if you need higher precision and can accept the ~30% performance penalty from JavaScript trig calls.

**Recommended:** Use `fft_combined.wasm` (complex) or `fft_real_combined.wasm` (real) for automatic algorithm selection. These modules use radix-4 for power-of-4 sizes and radix-2 for other sizes, similar to FFTW's approach.

For manual control, use `fft_radix4.wasm` for power-of-4 sizes, `combined_stockham.wasm` for other power-of-2 sizes, or `combined_fast.wasm` for environments without SIMD support.

### Radix-4 (Fastest for Power-of-4 Sizes)

Radix-4 Stockham FFT with SIMD acceleration - the fastest implementation for sizes 4, 16, 64, 256, 1024, 4096:

- **50% fewer stages** than radix-2 (log₄(N) vs log₂(N))
- **Inlined SIMD complex multiply** - no function call overhead
- **Fully unrolled N=4 and N=16 codelets** - inline twiddles, zero loop overhead
- **SIMD v128** for all butterfly operations
- No bit-reversal needed - Stockham ping-pong buffers
- **Up to 89% faster** than fft.js at large sizes

```javascript
// Radix-4 FFT usage (power-of-4 sizes only)
const wasmBuffer = fs.readFileSync("dist/fft_radix4.wasm");
const wasmModule = await WebAssembly.compile(wasmBuffer);
const instance = await WebAssembly.instantiate(wasmModule);
const fft = instance.exports;

const N = 1024; // Must be power of 4
fft.precompute_twiddles(N);
fft.fft_radix4(N);
```

### Combined (Recommended - All Power-of-2 Sizes)

Combined FFT modules that automatically select the optimal algorithm:

- **Radix-4** for power-of-4 sizes (4, 16, 64, 256, 1024, 4096) - fastest
- **Radix-2 Stockham** for other power-of-2 sizes (8, 32, 128, 512, 2048) - fast

This mirrors FFTW's approach of selecting the best algorithm per size.

```javascript
// Combined FFT usage (any power-of-2 size)
const wasmBuffer = fs.readFileSync("dist/fft_combined.wasm");
const wasmModule = await WebAssembly.compile(wasmBuffer);
const instance = await WebAssembly.instantiate(wasmModule);
const fft = instance.exports;

const N = 512; // Any power of 2
fft.precompute_twiddles(N);
fft.fft(N); // Automatically uses radix-2 for N=512
```

For real FFT:

```javascript
// Combined Real FFT usage
const wasmBuffer = fs.readFileSync("dist/fft_real_combined.wasm");
const wasmModule = await WebAssembly.compile(wasmBuffer);
const instance = await WebAssembly.instantiate(wasmModule);
const fft = instance.exports;

const N = 1024; // Any power of 2
fft.precompute_rfft_twiddles(N);
fft.rfft(N); // Uses radix-4 since N/2=512 is NOT power-of-4, uses radix-2
```

### Stockham Radix-2 (All Power-of-2 Sizes)

Radix-2 Stockham FFT with SIMD acceleration - works for any power-of-2:

- No bit-reversal needed - implicit reordering via ping-pong buffers
- Sequential memory access patterns for better cache performance
- SIMD v128 complex arithmetic
- **Loop Strength Reduction** - pointer increments instead of index multiplications
- **Inline trig functions** - Taylor series sin/cos (no JS imports needed)
- **Specialized N=4 kernel** - fully unrolled for ~16% speedup at small sizes
- Works for all power-of-2 sizes

Based on the algorithm from [scientificgo/fft](https://github.com/scientificgo/fft).

### Real FFT (r2c)

Optimized real-to-complex FFT for real-valued input signals:

- Computes N-point real FFT using N/2-point complex FFT
- Returns N/2+1 unique frequency bins (exploits conjugate symmetry)
- ~2x faster than complex FFT for real input
- Double precision (f64) for high accuracy
- **Fused rfft codelets** for N=8 and N=32 with hardcoded twiddles - **beats fftw-js by up to 124%**
- **Combined variant** (`fft_real_combined.wasm`) is recommended, auto-selects optimal algorithm

```javascript
// Real FFT usage (radix-4 recommended for best performance)
const wasmBuffer = fs.readFileSync("dist/fft_real_radix4.wasm");
const wasmModule = await WebAssembly.compile(wasmBuffer);
const instance = await WebAssembly.instantiate(wasmModule, {});
const fft = instance.exports;

const N = 1024;
const realInput = new Float64Array(fft.memory.buffer, 0, N);
for (let i = 0; i < N; i++) {
  realInput[i] = Math.sin((2 * Math.PI * i) / N);
}

fft.precompute_rfft_twiddles(N);
fft.rfft(N);

// Output: N/2+1 complex values (interleaved re, im)
const output = new Float64Array(fft.memory.buffer, 0, (N / 2 + 1) * 2);
console.log("DC:", output[0], output[1]);
console.log("Nyquist:", output[N], output[N + 1]);
```

### Fast (Non-SIMD Fallback)

Radix-2 with precomputed twiddle factors. Use this for environments without WebAssembly SIMD support (older browsers/runtimes).

## Project Structure

```
wat-fft/
├── modules/              # WAT source files
│   ├── fft_combined.wat  # Combined radix-2/4 FFT (recommended)
│   ├── fft_real_combined.wat # Combined real FFT (recommended)
│   ├── fft_radix4.wat    # Radix-4 Stockham FFT with SIMD (fastest)
│   ├── fft_real_radix4.wat # Real FFT using Radix-4
│   ├── fft_stockham.wat  # Stockham Radix-2 FFT with SIMD
│   ├── fft_real.wat      # Real FFT (r2c) using Stockham
│   ├── fft_fast.wat      # Radix-2 FFT (non-SIMD fallback)
│   ├── reverse_bits.wat  # Bit reversal utility
│   ├── swap.wat          # Memory swap utility
│   └── shared.wat        # Shared SIMD helpers
├── tests/                # Test suite
├── tools/                # Debug and analysis tools
├── benchmarks/           # Performance benchmarks
├── dist/                 # Compiled WASM (generated)
├── build.js              # Build system
└── package.json
```

## How It Works

### Real FFT Algorithm

The real FFT exploits conjugate symmetry of real-valued input to compute an N-point real FFT using an N/2-point complex FFT:

1. **Pack**: N real values into N/2 complex: `z[k] = x[2k] + i*x[2k+1]`
2. **Transform**: Run N/2-point Stockham FFT on packed data
3. **Unpack**: Post-process to extract N/2+1 unique frequency bins

Post-processing formula for k = 1 to N/2-1:

```
X[k] = 0.5*(Z[k] + conj(Z[N/2-k])) - 0.5i*W_N^k*(Z[k] - conj(Z[N/2-k]))
```

Special cases: `X[0] = Z[0].re + Z[0].im`, `X[N/2] = Z[0].re - Z[0].im`

### Memory Layout

Complex numbers are stored interleaved:

- Each complex number: 16 bytes (8 bytes real + 8 bytes imaginary)
- Data starts at offset 0
- Secondary buffer (Stockham ping-pong): offset 65536 (64KB)
- Complex FFT twiddle factors: offset 131072 (128KB)
- Real FFT post-processing twiddles: offset 196608 (192KB)

### SIMD Complex Multiply

```wat
;; Complex multiply using v128: (a + bi)(c + di) = (ac-bd) + (ad+bc)i
(func $simd_cmul (param $a v128) (param $b v128) (result v128)
  ;; Shuffle to get [d, c] from [c, d]
  ;; Multiply and combine with sign mask for subtraction
  ...)
```

## Scripts

```bash
npm run build         # Build all WASM modules
npm test              # Run all tests
npm run bench         # Run complex FFT benchmarks
npm run bench:rfft    # Run real FFT benchmarks
npm run test:fft      # Run comprehensive FFT tests
npm run test:rfft     # Run real FFT tests
npm run test:permutation  # Test permutation algorithms
```

## Testing FFT Implementations

The comprehensive FFT test suite (`tests/fft.test.js`) tests all implementations against a reference DFT with various input sizes and patterns.

### Run all FFT tests

```bash
npm run test:fft
```

### Test a single implementation (useful for debugging)

```bash
node tests/fft.test.js --impl stockham 64 random
node tests/fft.test.js --impl fast 256 impulse
```

### Input patterns

- `impulse` - Single 1.0 at index 0
- `constant` - All 1.0 values
- `singleFreq` - Single cosine wave
- `random` - Seeded pseudorandom values

### Test sizes

Powers of 2: 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096

## License

ISC
