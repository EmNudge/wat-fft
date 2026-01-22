# wat-fft

A high-performance FFT implementation in WebAssembly Text format that **significantly outperforms popular JavaScript FFT libraries**.

## Performance

### Complex FFT

Benchmarked against [fft.js](https://github.com/indutny/fft.js) (the fastest pure-JS FFT) and [fft-js](https://github.com/vail-systems/node-fft):

| Size   | wat-fft (Radix-4)    | wat-fft (Radix-2) | fft.js           | Speedup vs fft.js |
| ------ | -------------------- | ----------------- | ---------------- | ----------------- |
| N=16   | **16,086,000 ops/s** | 11,205,000 ops/s  | 11,009,000 ops/s | **1.46x**         |
| N=64   | **3,814,000 ops/s**  | 3,424,000 ops/s   | 2,706,000 ops/s  | **1.41x**         |
| N=256  | **967,000 ops/s**    | 743,000 ops/s     | 554,000 ops/s    | **1.75x**         |
| N=1024 | **186,000 ops/s**    | 161,000 ops/s     | 109,000 ops/s    | **1.71x**         |
| N=4096 | **42,800 ops/s**     | 28,000 ops/s      | 22,700 ops/s     | **1.89x**         |

**wat-fft Radix-4** is the fastest option for power-of-4 sizes (4, 16, 64, 256, 1024, 4096), achieving up to **1.89x speedup** over fft.js at N=4096. For non-power-of-4 sizes, use the Radix-2 Stockham implementation.

### Real FFT

Benchmarked against [kissfft-wasm](https://www.npmjs.com/package/kissfft-wasm) and [fftw-js](https://www.npmjs.com/package/fftw-js):

| Size   | wat-fft rfft (f64)  | wat-fft rfft (f32) | kissfft-wasm (f32) | fftw-js (f32)   |
| ------ | ------------------- | ------------------ | ------------------ | --------------- |
| N=64   | **5,052,654 ops/s** | 4,557,213 ops/s    | 3,467,219 ops/s    | 6,918,197 ops/s |
| N=256  | **1,242,945 ops/s** | 1,102,350 ops/s    | 1,018,967 ops/s    | 1,494,750 ops/s |
| N=1024 | **281,152 ops/s**   | 249,718 ops/s      | 242,823 ops/s      | 474,662 ops/s   |
| N=4096 | **61,887 ops/s**    | 54,553 ops/s       | 56,587 ops/s       | 107,878 ops/s   |

Note: wat-fft provides both double precision (f64) and single precision (f32) implementations. kissfft-wasm and fftw-js use single precision only. The real FFT is ~2x faster than the complex FFT for the same input size, achieving the theoretical optimum by computing only N/2 complex FFT internally.

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

| Module                   | Algorithm                 | Best For               | Speed            |
| ------------------------ | ------------------------- | ---------------------- | ---------------- |
| `fft_radix4.wasm`        | Radix-4 Stockham + SIMD   | Power-of-4 sizes       | **Fastest**      |
| `combined_stockham.wasm` | Radix-2 Stockham + SIMD   | All power-of-2 sizes   | Fast             |
| `combined_real.wasm`     | Real FFT (r2c) + Stockham | Real-valued signals    | Fast             |
| `fft_real_radix4.wasm`   | Real FFT + Radix-4        | Real signals, N/2=pow4 | **Fastest rfft** |
| `combined_fast.wasm`     | Radix-2 (no SIMD)         | No SIMD support        | Medium           |

### Numerical Accuracy

The accuracy difference between implementations comes from trigonometric function computation:

- **Stockham/Real (~10⁻⁹)**: Uses inline 8-term Taylor series for sin/cos to avoid JavaScript import overhead. The Taylor series achieves ~10⁻¹⁰ accuracy per twiddle factor after range reduction to [-π/2, π/2]. Errors accumulate through log₂(N) butterfly stages, resulting in ~10⁻⁹ overall accuracy for typical FFT sizes.

- **Fast (~10⁻¹⁴)**: Uses JavaScript's `Math.sin`/`Math.cos` which provide full double-precision accuracy (~10⁻¹⁵), resulting in ~10⁻¹⁴ overall FFT accuracy.

**Test tolerances** are derived from these characteristics:

- Relative tolerance: `1e-9` (matches Taylor series single-operation error)
- Size scaling: `max(1e-9, N × 2e-11)` accounts for error accumulation in larger transforms
- Absolute floor: `5e-4` for property tests handles near-zero values where relative error is meaningless

For most signal processing applications, ~10⁻⁹ accuracy is more than sufficient. Use `combined_fast.wasm` if you need higher precision and can accept the ~30% performance penalty from JavaScript trig calls.

Use `fft_radix4.wasm` for power-of-4 sizes (best performance), `combined_stockham.wasm` for other power-of-2 sizes, or `combined_fast.wasm` as a fallback for environments without SIMD support.

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

- Computes N-point real FFT using N/2-point complex Stockham FFT
- Returns N/2+1 unique frequency bins (exploits conjugate symmetry)
- ~2x faster than complex FFT for real input
- Double precision (f64) for high accuracy

```javascript
// Real FFT usage
const wasmBuffer = fs.readFileSync("dist/combined_real.wasm");
const wasmModule = await WebAssembly.compile(wasmBuffer);
const instance = await WebAssembly.instantiate(wasmModule, {
  math: { sin: Math.sin, cos: Math.cos },
});
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
