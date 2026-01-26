# wat-fft

A high-performance FFT implementation in WebAssembly Text format that **significantly outperforms popular JavaScript FFT libraries**.

## Performance

### Complex FFT

Benchmarked against [fft.js](https://github.com/indutny/fft.js) (fastest pure-JS FFT):

| Size   | wat-fft (f64)       | fft.js          | vs fft.js |
| ------ | ------------------- | --------------- | --------- |
| N=64   | **3,830,000 ops/s** | 2,794,000 ops/s | **+37%**  |
| N=128  | **1,586,000 ops/s** | 1,105,000 ops/s | **+44%**  |
| N=256  | **973,000 ops/s**   | 559,000 ops/s   | **+74%**  |
| N=512  | **344,000 ops/s**   | 223,000 ops/s   | **+54%**  |
| N=1024 | **191,000 ops/s**   | 113,000 ops/s   | **+69%**  |
| N=2048 | **74,500 ops/s**    | 47,200 ops/s    | **+58%**  |
| N=4096 | **44,400 ops/s**    | 23,400 ops/s    | **+90%**  |

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
    x-axis [N=64, N=128, N=256, N=512, N=1024, N=2048, N=4096]
    y-axis "Million ops/s" 0 --> 5
    line [3.83, 1.59, 0.97, 0.34, 0.19, 0.074, 0.044]
    line [4.60, 2.40, 1.17, 0.54, 0.27, 0.124, 0.062]
    line [2.79, 1.11, 0.56, 0.22, 0.11, 0.047, 0.023]
    line [1.90, 0.80, 0.45, 0.18, 0.10, 0.041, 0.022]
```

> 🟢 **wat-fft f64** · 🔵 **wat-fft f32** · 🟣 **fft.js** · 🔴 **kissfft-js**

**Choose f64** (`fft_combined.wasm`) for double precision - **+37% to +90% faster** than fft.js at all sizes. **Choose f32** (`fft_stockham_f32_dual.wasm`) for maximum speed with single precision - up to **2.6x faster** than fft.js.

### Real FFT

Benchmarked against [fftw-js](https://www.npmjs.com/package/fftw-js) (Emscripten port of FFTW):

| Size   | wat-fft (f32)       | fftw-js (f32)   | vs fftw-js |
| ------ | ------------------- | --------------- | ---------- |
| N=64   | **6,800,000 ops/s** | 6,500,000 ops/s | **+5%**    |
| N=128  | **4,400,000 ops/s** | 4,200,000 ops/s | **+5%**    |
| N=256  | **2,200,000 ops/s** | 1,480,000 ops/s | **+48%**   |
| N=512  | **1,150,000 ops/s** | 900,000 ops/s   | **+27%**   |
| N=1024 | **520,000 ops/s**   | 465,000 ops/s   | **+12%**   |
| N=2048 | **267,000 ops/s**   | 228,000 ops/s   | **+17%**   |
| N=4096 | **121,000 ops/s**   | 106,000 ops/s   | **+14%**   |

```mermaid
---
config:
    xyChart:
        width: 700
        height: 400
    themeVariables:
        xyChart:
            plotColorPalette: "#4ade80, #60a5fa, #f87171, #a855f7"
---
xychart-beta
    title "Real FFT Performance (Million ops/s)"
    x-axis [N=64, N=128, N=256, N=512, N=1024, N=2048, N=4096]
    y-axis "Million ops/s" 0 --> 8
    line [4.80, 2.99, 1.28, 0.76, 0.27, 0.16, 0.062]
    line [6.80, 4.40, 2.20, 1.15, 0.52, 0.267, 0.121]
    line [6.50, 4.20, 1.48, 0.90, 0.465, 0.228, 0.106]
    line [2.93, 1.74, 0.75, 0.42, 0.17, 0.094, 0.039]
```

> 🟢 **wat-fft f64** · 🔵 **wat-fft f32** · 🔴 **fftw-js** · 🟣 **kissfft-js**

**wat-fft f32 beats fftw-js at all sizes** (+5% to +48%). **Choose f64** (`fft_real_combined.wasm`) for double precision. **Choose f32** (`fft_real_f32_dual.wasm`) for maximum single-precision speed.

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

// Load the WASM module
// No JavaScript imports needed - trig functions are computed inline
const wasmBuffer = fs.readFileSync("dist/fft_combined.wasm");
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
fft.fft(N);

// Results are in-place in data[]
console.log("DC component:", data[0], data[1]);

// Compute inverse FFT (roundtrip back to original)
fft.ifft(N);
console.log("Recovered signal:", data[0], data[1]);
```

## Implementations

**Recommended modules:**

| Module                       | Use Case               | Precision | Inverse |
| ---------------------------- | ---------------------- | --------- | ------- |
| `fft_combined.wasm`          | Complex FFT (any size) | f64       | `ifft`  |
| `fft_real_combined.wasm`     | Real FFT (any size)    | f64       | -       |
| `fft_stockham_f32_dual.wasm` | Complex FFT (fastest)  | f32       | `ifft`  |
| `fft_real_f32_dual.wasm`     | Real FFT (fastest)     | f32       | `irfft` |

See [docs/IMPLEMENTATIONS.md](docs/IMPLEMENTATIONS.md) for detailed documentation of all modules, usage examples, and numerical accuracy information.

## How It Works

See [docs/HOW_IT_WORKS.md](docs/HOW_IT_WORKS.md) for algorithm details including:

- Real FFT algorithm (N-point real using N/2-point complex)
- Memory layout and buffer organization
- SIMD complex multiply implementation
- Stockham and Radix-4 FFT algorithms
- Taylor series trigonometry

## Scripts

```bash
npm run build         # Build all WASM modules
npm test              # Run all tests
npm run bench         # Run complex FFT benchmarks
npm run bench:rfft    # Run real FFT benchmarks
npm run bench:rfft32  # Run f32 real FFT benchmarks
npm run test:fft      # Run comprehensive FFT tests
npm run test:rfft     # Run real FFT tests
```

## Development Tools

| Documentation                                          | Description                              |
| ------------------------------------------------------ | ---------------------------------------- |
| [benchmarks/README.md](benchmarks/README.md)           | Performance benchmarks and profiling     |
| [tools/README.md](tools/README.md)                     | Debug tools for FFT development          |
| [docs/OPTIMIZATION_PLAN.md](docs/OPTIMIZATION_PLAN.md) | Optimization strategy and experiment log |

## Playground

An interactive browser-based playground is available for testing FFT performance with real-world tasks like spectrogram generation.

```bash
cd playground
npm install
npm run dev
```

Features:

- **Multiple FFT implementations**: Compare performance of different wat-fft modules
- **Audio sources**: Generate synthetic sine wave combinations using Web Audio API's OfflineAudioContext, or load your own audio files
- **Spectrogram visualization**: Real-time spectrogram rendering with configurable FFT size, hop size, and color scales
- **Spectrum analyzer**: Live microphone input with bar, curve, and mirrored visualization modes
- **Performance metrics**: Track FFT execution time and throughput

Add your own sample audio files to `playground/public/samples/`.

## Testing FFT Implementations

The comprehensive FFT test suite (`tests/fft.test.js`) tests all implementations against a reference DFT with various input sizes and patterns.

### Run all FFT tests

```bash
npm run test:fft
```

### Test a specific size and pattern

```bash
node tests/fft.test.js 64 random
node tests/fft.test.js 256 impulse
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
