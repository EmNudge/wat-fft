# wat-fft

A high-performance FFT implementation in WebAssembly Text format that **significantly outperforms popular JavaScript FFT libraries**.

## Performance

### Complex FFT

Benchmarked against [pffft-wasm](https://www.npmjs.com/package/@echogarden/pffft-wasm) (fastest WASM FFT):

| Size   | wat-fft (f32)       | pffft-wasm (f32) | vs pffft |
| ------ | ------------------- | ---------------- | -------- |
| N=64   | **6,030,000 ops/s** | 6,950,000 ops/s  | 87%      |
| N=128  | **3,050,000 ops/s** | 3,390,000 ops/s  | 90%      |
| N=256  | **1,620,000 ops/s** | 1,850,000 ops/s  | 88%      |
| N=512  | **709,000 ops/s**   | 782,000 ops/s    | 91%      |
| N=1024 | **365,000 ops/s**   | 407,000 ops/s    | 90%      |
| N=2048 | **161,000 ops/s**   | 171,000 ops/s    | 94%      |
| N=4096 | **79,600 ops/s**    | 88,100 ops/s     | 90%      |

```mermaid
---
config:
    xyChart:
        width: 700
        height: 400
    themeVariables:
        xyChart:
            plotColorPalette: "#4ade80, #60a5fa, #f59e0b, #a855f7, #f87171"
---
xychart-beta
    title "Complex FFT Performance (Million ops/s)"
    x-axis [N=64, N=128, N=256, N=512, N=1024, N=2048, N=4096]
    y-axis "Million ops/s" 0 --> 8
    line [3.76, 1.67, 0.95, 0.36, 0.19, 0.078, 0.044]
    line [6.03, 3.05, 1.62, 0.71, 0.36, 0.161, 0.080]
    line [6.95, 3.39, 1.85, 0.78, 0.41, 0.171, 0.088]
    line [2.75, 1.08, 0.55, 0.22, 0.10, 0.046, 0.023]
    line [1.85, 0.79, 0.44, 0.18, 0.10, 0.039, 0.021]
```

> 🟢 **wat-fft f64** · 🔵 **wat-fft f32** · 🟠 **pffft-wasm** · 🟣 **fft.js** · 🔴 **kissfft-js**

**wat-fft f32** is within 10% of pffft-wasm (the fastest WASM FFT) while being **2-3.6x faster** than fft.js. **Choose f64** (`fft_combined.wasm`) for double precision. **Choose f32** (`fft_stockham_f32_dual.wasm`) for maximum single-precision speed.

### Real FFT

Benchmarked against [fftw-js](https://www.npmjs.com/package/fftw-js) (Emscripten port of FFTW):

| Size   | wat-fft (f32)       | fftw-js (f32)   | vs fftw-js |
| ------ | ------------------- | --------------- | ---------- |
| N=64   | **6,690,000 ops/s** | 6,730,000 ops/s | **~tied**  |
| N=128  | **4,610,000 ops/s** | 4,250,000 ops/s | **+9%**    |
| N=256  | **2,130,000 ops/s** | 1,460,000 ops/s | **+46%**   |
| N=512  | **1,180,000 ops/s** | 887,000 ops/s   | **+33%**   |
| N=1024 | **527,000 ops/s**   | 454,000 ops/s   | **+16%**   |
| N=2048 | **274,000 ops/s**   | 224,000 ops/s   | **+23%**   |
| N=4096 | **125,000 ops/s**   | 104,000 ops/s   | **+20%**   |

```mermaid
---
config:
    xyChart:
        width: 700
        height: 400
    themeVariables:
        xyChart:
            plotColorPalette: "#4ade80, #60a5fa, #f87171, #f59e0b, #a855f7"
---
xychart-beta
    title "Real FFT Performance (Million ops/s)"
    x-axis [N=64, N=128, N=256, N=512, N=1024, N=2048, N=4096]
    y-axis "Million ops/s" 0 --> 8
    line [4.74, 2.93, 1.27, 0.75, 0.28, 0.16, 0.063]
    line [6.69, 4.61, 2.13, 1.18, 0.527, 0.274, 0.125]
    line [6.73, 4.25, 1.46, 0.89, 0.454, 0.224, 0.104]
    line [4.51, 1.94, 0.99, 0.40, 0.20, 0.085, 0.041]
    line [2.85, 1.75, 0.75, 0.41, 0.17, 0.092, 0.039]
```

> 🟢 **wat-fft f64** · 🔵 **wat-fft f32** · 🔴 **fftw-js** · 🟠 **pffft-wasm** · 🟣 **kissfft-js**

**wat-fft f32 beats fftw-js at N≥128** (+9% to +46%). **Choose f64** (`fft_real_combined.wasm`) for double precision. **Choose f32** (`fft_real_f32_dual.wasm`) for maximum single-precision speed.

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
