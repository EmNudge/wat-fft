# wat-fft

A high-performance FFT implementation in WebAssembly Text format that **outperforms popular JavaScript FFT libraries**.

## Performance

### Complex FFT

Benchmarked against [fft.js](https://github.com/indutny/fft.js) (the fastest pure-JS FFT) and [fft-js](https://github.com/vail-systems/node-fft):

| Size   | wat-fft (Stockham)  | wat-fft (Radix-4) | fft.js          | Speedup vs fft.js |
| ------ | ------------------- | ----------------- | --------------- | ----------------- |
| N=64   | **3,157,512 ops/s** | 2,942,236 ops/s   | 2,788,955 ops/s | **1.13x**         |
| N=256  | **723,490 ops/s**   | 570,225 ops/s     | 555,166 ops/s   | **1.30x**         |
| N=1024 | **149,126 ops/s**   | 117,337 ops/s     | 110,807 ops/s   | **1.35x**         |
| N=4096 | **28,308 ops/s**    | 25,088 ops/s      | 23,515 ops/s    | **1.20x**         |

The Stockham implementation is the fastest for N≥64, using ping-pong buffers to avoid bit-reversal overhead.

### Real FFT

Benchmarked against [kissfft-wasm](https://github.com/nicholaswmin/kissfft-wasm) and [fftw-js](https://github.com/nicholaswmin/fftw-js):

| Size   | wat-fft rfft (f64)  | kissfft-wasm (f32) | fftw-js (f32)   |
| ------ | ------------------- | ------------------ | --------------- |
| N=64   | **4,454,257 ops/s** | 3,448,822 ops/s    | 6,927,853 ops/s |
| N=256  | **1,061,203 ops/s** | 1,005,964 ops/s    | 1,497,623 ops/s |
| N=1024 | **236,412 ops/s**   | 241,045 ops/s      | 472,625 ops/s   |
| N=4096 | **52,922 ops/s**    | 55,874 ops/s       | 107,580 ops/s   |

Note: wat-fft uses double precision (f64), while kissfft-wasm and fftw-js use single precision (f32). The real FFT is ~1.5-2x faster than the complex FFT for the same input size.

## Quick Start

```bash
# Install dependencies
npm install

# Build WASM modules
npm run glue

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
const wasmBuffer = fs.readFileSync("dist/combined_stockham.wasm");
const wasmModule = await WebAssembly.compile(wasmBuffer);
const instance = await WebAssembly.instantiate(wasmModule, {
  math: { sin: Math.sin, cos: Math.cos },
});
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

Seven FFT implementations are provided, each with different trade-offs:

| Module                   | Algorithm                   | Accuracy vs fft.js | Speed       |
| ------------------------ | --------------------------- | ------------------ | ----------- |
| `combined_stockham.wasm` | Stockham Radix-2 + SIMD     | ~10⁻¹⁴             | **Fastest** |
| `combined_real.wasm`     | Real FFT (r2c) + Stockham   | ~10⁻¹⁴             | **Fastest** |
| `combined_radix4.wasm`   | Radix-4 + SIMD              | Bit-identical      | Very Fast   |
| `combined_unrolled.wasm` | Unrolled butterflies + SIMD | ~10⁻¹⁴             | Fast        |
| `combined_simd.wasm`     | Radix-2 + SIMD              | ~10⁻¹⁴             | Medium      |
| `combined_fast.wasm`     | Radix-2                     | ~10⁻¹⁴             | Medium      |
| `combined.wasm`          | Radix-2 + Taylor sin/cos    | ~10⁻⁷              | Baseline    |

### Stockham (Recommended)

Radix-2 Stockham FFT with SIMD acceleration - the fastest implementation:

- No bit-reversal needed - implicit reordering via ping-pong buffers
- Sequential memory access patterns for better cache performance
- SIMD v128 complex arithmetic
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

### Radix-4

True Radix-4 butterflies with SIMD acceleration:

- Base-4 digit-reversal permutation
- 4-point butterflies (75% fewer iterations than Radix-2)
- SIMD v128 complex arithmetic
- Bit-identical results to fft.js

### Unrolled

Hand-unrolled small butterflies (FFT-4, FFT-8, FFT-16) with general fallback:

- Reduced loop overhead for small transforms
- SIMD v128 complex arithmetic

### SIMD

Radix-2 with SIMD-accelerated complex operations:

- f64x2 parallel complex multiply
- i8x16.shuffle for real/imaginary swapping

### Fast

Radix-2 with precomputed twiddle factors (no SIMD).

### Original

Educational Radix-2 with Taylor series sin/cos computed in WASM.

## Project Structure

```
wat-fft/
├── modules/              # WAT source files
│   ├── fft_stockham.wat  # Stockham Radix-2 FFT with SIMD (fastest)
│   ├── fft_real.wat      # Real FFT (r2c) using Stockham
│   ├── fft_radix4.wat    # Radix-4 FFT with SIMD
│   ├── fft_unrolled.wat  # Unrolled butterflies with SIMD
│   ├── fft_simd.wat      # SIMD-accelerated Radix-2
│   ├── fft_fast.wat      # Optimized Radix-2
│   ├── fft_main.wat      # Original Radix-2
│   ├── math_trig.wat     # Taylor series sin/cos
│   ├── reverse_bits.wat  # Bit/digit reversal
│   └── swap.wat          # Memory swap utility
├── tests/                # Test suite
├── tools/                # Debug and analysis tools
├── benchmarks/           # Performance benchmarks
├── dist/                 # Compiled WASM (generated)
├── glue.js               # Build system
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

### Radix-4 Algorithm

The Radix-4 FFT processes 4 elements per butterfly instead of 2, reducing the number of iterations by half. The butterfly operation computes:

```
y₀ = x₀ + x₁ + x₂ + x₃
y₁ = x₀ - jx₁ - x₂ + jx₃
y₂ = x₀ - x₁ + x₂ - x₃
y₃ = x₀ + jx₁ - x₂ - jx₃
```

For sizes that aren't powers of 4 (e.g., N=8, 32, 128), a mixed Radix-4/Radix-2 approach is used.

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
npm run glue          # Build all WASM modules
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
node tests/fft.test.js --impl radix4 64 random
node tests/fft.test.js --impl unrolled 256 impulse
```

### Input patterns

- `impulse` - Single 1.0 at index 0
- `constant` - All 1.0 values
- `singleFreq` - Single cosine wave
- `random` - Seeded pseudorandom values

### Test sizes

Powers of 4: 4, 16, 64, 256, 1024
Non-powers-of-4: 8, 32, 128, 512

## License

ISC
