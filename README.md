# wat-fft

A high-performance FFT implementation in WebAssembly Text format that **outperforms popular JavaScript FFT libraries**.

## Performance

Benchmarked against [fft.js](https://github.com/indutny/fft.js) (the fastest pure-JS FFT) and [fft-js](https://github.com/vail-systems/node-fft):

| Size | wat-fft (Radix-4) | fft.js | Speedup |
|------|-------------------|--------|---------|
| N=64 | 2,952,533 ops/s | 2,808,648 ops/s | **1.05x** |
| N=256 | 570,736 ops/s | 562,946 ops/s | **1.01x** |
| N=1024 | 119,865 ops/s | 113,465 ops/s | **1.06x** |
| N=4096 | 25,741 ops/s | 23,673 ops/s | **1.09x** |

The Radix-4 WASM implementation produces **bit-identical results** to fft.js.

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
- [WABT](https://github.com/WebAssembly/wabt) (`wat2wasm`)

```bash
# macOS
brew install wabt

# Ubuntu/Debian
apt-get install wabt
```

## Usage

```javascript
import fs from 'fs';

// Load the WASM module
const wasmBuffer = fs.readFileSync('dist/combined_radix4.wasm');
const wasmModule = await WebAssembly.compile(wasmBuffer);
const instance = await WebAssembly.instantiate(wasmModule, {
  math: { sin: Math.sin, cos: Math.cos }
});
const fft = instance.exports;

// Prepare input (interleaved complex: [re0, im0, re1, im1, ...])
const N = 1024;
const data = new Float64Array(fft.memory.buffer, 0, N * 2);
for (let i = 0; i < N; i++) {
  data[i * 2] = Math.sin(2 * Math.PI * i / N);     // real
  data[i * 2 + 1] = 0;                              // imaginary
}

// Compute FFT
fft.precompute_twiddles(N);
fft.fft_radix4(N);

// Results are in-place in data[]
console.log('DC component:', data[0], data[1]);
```

## Implementations

Four FFT implementations are provided, each with different trade-offs:

| Module | Algorithm | Accuracy vs fft.js | Speed |
|--------|-----------|-------------------|-------|
| `combined_radix4.wasm` | Radix-4 + SIMD | Bit-identical | Fastest |
| `combined_simd.wasm` | Radix-2 + SIMD | ~10⁻¹⁴ | Fast |
| `combined_fast.wasm` | Radix-2 | ~10⁻¹⁴ | Fast |
| `combined.wasm` | Radix-2 + Taylor sin/cos | ~10⁻⁷ | Baseline |

### Radix-4 (Recommended)

The fastest implementation using true Radix-4 butterflies with SIMD acceleration:

- Base-4 digit-reversal permutation
- 4-point butterflies (75% fewer iterations than Radix-2)
- SIMD v128 complex arithmetic
- Precomputed twiddle factors via JS Math imports

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
│   ├── fft_radix4.wat    # Radix-4 FFT with SIMD
│   ├── fft_simd.wat      # SIMD-accelerated Radix-2
│   ├── fft_fast.wat      # Optimized Radix-2
│   ├── fft_main.wat      # Original Radix-2
│   ├── math_trig.wat     # Taylor series sin/cos
│   ├── reverse_bits.wat  # Bit/digit reversal
│   └── swap.wat          # Memory swap utility
├── tests/                # Test suite
├── benchmarks/           # Performance benchmarks
├── dist/                 # Compiled WASM (generated)
├── glue.js               # Build system
└── package.json
```

## How It Works

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
- Twiddle factors stored at offset 131072 (128KB)

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
npm run bench         # Run performance benchmarks
npm run test:permutation  # Test permutation algorithms
```

## License

ISC
