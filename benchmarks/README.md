# Performance Benchmarks

Tools for measuring FFT performance and comparing against competitor libraries.

## Quick Reference

| Command                | Benchmark         | Competitors                                    |
| ---------------------- | ----------------- | ---------------------------------------------- |
| `npm run bench`        | Complex FFT (f64) | fft.js, fft-js, kissfft-js, webfft, pffft-wasm |
| `npm run bench:rfft`   | Real FFT (f64)    | fftw-js, kissfft-js, webfft, pffft-wasm        |
| `npm run bench:f32`    | Complex FFT (f32) | fft.js                                         |
| `npm run bench:rfft32` | Real FFT (f32)    | fftw-js                                        |

## Benchmark Files

| File                     | Purpose                                                                         |
| ------------------------ | ------------------------------------------------------------------------------- |
| `fft.bench.js`           | Main complex FFT benchmark - compares all wat-fft variants against JS libraries |
| `rfft.bench.js`          | Real FFT benchmark - compares f64 rfft against fftw-js and kissfft-js           |
| `fft_f32_dual.bench.js`  | f32 dual-complex FFT - measures the +105% dual-complex optimization             |
| `rfft_f32_dual.bench.js` | f32 dual-complex rfft - compares against fftw-js (both f32)                     |

## Running Benchmarks

### Basic Usage

```bash
# Build first (required)
npm run build

# Run main benchmarks
npm run bench        # Complex FFT
npm run bench:rfft   # Real FFT (f64)
npm run bench:f32    # Complex FFT (f32)
npm run bench:rfft32 # Real FFT (f32)
```

### Running Individual Benchmarks

```bash
node benchmarks/fft.bench.js
node benchmarks/rfft.bench.js
node benchmarks/fft_f32_dual.bench.js
node benchmarks/rfft_f32_dual.bench.js
```

## Configuration

All benchmarks use consistent configuration (defined at top of each file):

```javascript
const WARMUP_ITERATIONS = 100; // JIT warmup
const BENCHMARK_DURATION_MS = 2000; // 2 seconds per test
const SIZES = [64, 128, 256, 512, 1024, 2048, 4096];
```

## Output Format

Benchmarks output formatted tables showing:

```
======================================================================
FFT Performance Benchmarks
======================================================================
Duration: 2000ms per test
Warmup: 100 iterations

----------------------------------------------------------------------
FFT Size: N=1024
----------------------------------------------------------------------
  wat-fft (Combined):      191,234 ops/s
  fft.js:                  113,456 ops/s
  kissfft-js:               98,765 ops/s

  Winner: wat-fft (Combined) - 1.69x faster than fft.js
```

## Competitors

### Complex FFT

| Library        | Type       | Precision | Notes                                     |
| -------------- | ---------- | --------- | ----------------------------------------- |
| **fft.js**     | Pure JS    | f64       | Fastest pure JS, Radix-4 by Fedor Indutny |
| **fft-js**     | Pure JS    | f64       | Simple Cooley-Tukey implementation        |
| **kissfft-js** | Emscripten | f32\*     | Port of Kiss FFT C library                |
| **webfft**     | Meta-lib   | f32       | Meta-library with multiple backends       |
| **pffft-wasm** | Emscripten | f32       | PFFFT with SIMD support                   |

\*kissfft-js accepts Float64Array but uses f32 internally

### Real FFT

| Library        | Type       | Precision | Notes                              |
| -------------- | ---------- | --------- | ---------------------------------- |
| **fftw-js**    | Emscripten | f32       | Port of FFTW - our main competitor |
| **kissfft-js** | Emscripten | f32       | Port of Kiss FFT                   |
| **webfft**     | Meta-lib   | f32       | Meta-library with kissWasm backend |
| **pffft-wasm** | Emscripten | f32       | PFFFT (Pretty Fast FFT) with SIMD  |

### Competitor Library Notes

These notes were discovered through correctness testing (see `tests/third-party-correctness.test.js`):

#### pffft-wasm

**IMPORTANT**: The PFFFT enum values are:

```javascript
const PFFFT_REAL = 0;
const PFFFT_COMPLEX = 1; // NOT 0!
const PFFFT_FORWARD = 0;
const PFFFT_BACKWARD = 1;
```

Using `PFFFT_COMPLEX = 0` will actually run a Real FFT, giving incorrect results for complex input.

#### kissfft-js

- Accepts `Float64Array` input but **internally uses f32 precision**
- Expect errors around 1e-6, not 1e-15

#### webfft

- Complex FFT (`fft()`) works correctly
- **Real FFT (`fftr()`) has a bug**: DC component returns 0 for constant signals
- The library is still useful for performance comparison but real FFT results are incorrect

#### fftw-js

- Export is `fftw.FFT` (not `fftw.FFTW`)
- Only provides Real FFT, not Complex FFT

## Interpreting Results

### Key Metrics

- **ops/s**: FFT operations per second (higher is better)
- **vs fft.js**: Percentage faster/slower than fft.js baseline
- **vs fftw-js**: Percentage faster/slower than fftw-js baseline

### What to Look For

1. **Consistency**: Results should be stable across multiple runs (±5%)
2. **Size scaling**: Performance should scale appropriately with N
3. **Regressions**: Compare against previous benchmark results in experiment log

### Precision Considerations

- **f64 vs f32**: Our f64 benchmarks compare against f32 competitors (fftw-js)
- **Fair comparison**: Use `bench:rfft32` for apples-to-apples f32 comparison
- **SIMD throughput**: f32x4 processes 2 complex numbers vs f64x2's 1

## Adding New Benchmarks

1. Create `benchmarks/your_benchmark.bench.js`
2. Follow the existing pattern:

   ```javascript
   const WARMUP_ITERATIONS = 100;
   const BENCHMARK_DURATION_MS = 2000;

   function runBenchmark(name, setupFn, benchFn, teardownFn = null) {
     // Warmup
     const ctx = setupFn();
     for (let i = 0; i < WARMUP_ITERATIONS; i++) {
       benchFn(ctx);
     }

     // Timed run
     const freshCtx = setupFn();
     const startTime = performance.now();
     let iterations = 0;
     while (performance.now() - startTime < BENCHMARK_DURATION_MS) {
       benchFn(freshCtx);
       iterations++;
     }

     const elapsed = performance.now() - startTime;
     const opsPerSec = (iterations / elapsed) * 1000;
     return { name, iterations, elapsed, opsPerSec };
   }
   ```

3. Add npm script to `package.json` if needed

## Profiling Tips

### Node.js Profiling

```bash
# Generate V8 profile
node --prof benchmarks/fft.bench.js

# Process the profile
node --prof-process isolate-*.log > profile.txt
```

### Sampling with 0x

```bash
npx 0x benchmarks/fft.bench.js
# Opens flamegraph in browser
```

### Memory Analysis

```bash
node --expose-gc benchmarks/fft.bench.js
# Add gc() calls in benchmark to measure memory
```

## Browser-Based Benchmarking

For interactive browser-based benchmarking, use the **Benchmark Mode** in the [playground](../playground/):

```bash
cd playground
npm install
npm run dev
# Open http://localhost:5173 and select "Benchmark" mode
```

The playground benchmark offers:

- Multi-select implementation comparison with visual results
- Configurable iterations (10-1000) and warmup runs (0-50)
- Results table rendered on canvas with fastest-per-size highlighting
- One-click markdown export with browser info

This is useful for:

- Testing in different browsers (Chrome, Firefox, Safari)
- Sharing results with browser fingerprint
- Quick visual comparison without CLI

## Historical Results

See [docs/optimization/EXPERIMENT_LOG.md](../docs/optimization/EXPERIMENT_LOG.md) for historical benchmark results from all optimization experiments.
