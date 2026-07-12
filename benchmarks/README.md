# Performance Benchmarks

Tools for measuring FFT performance and comparing against competitor libraries.

## The Surface Registry (read this before adding or superseding a module)

**`shared/wat-surfaces.mjs` is the single source of truth for which wat-fft implementations get benchmarked.** Every bench file — Node and browser — builds its wat-fft contexts by enumerating the registry (`createWatBenchContexts` in `lib/wat-contexts.js` for Node, `createWatContexts` in `browser/fft-loader.ts` for the browser). Hand-rolled wat contexts in bench files are forbidden and rejected by `npm run test:bench-coverage` (part of `test:all`), which also:

- correctness-checks every registry entry against a reference DFT at N=64 (a miswired export or layout fails a test, not a benchmark report),
- fails if a `dist/*.wasm` module is neither registered nor explicitly excluded,
- fails if a bench file stops enumerating its declared surface.

**To add a new implementation or supersede a flagship: edit the registry only.** Add an entry (module file, exports, layout, size range, `flagship` flag) and every covered bench — `bench`, `bench:f32`, `bench:ifft32`, `bench:rfft`, `bench:rfft32`, `bench:irfft32`, and both browser benches — picks it up automatically.

Why this exists: the browser real-FFT benchmark kept measuring the old dual-complex `rfft` for two module generations after `rfft_split` shipped, reporting 14-35% "losses" to pffft that the flagship had already closed. The Node `bench:f32` and `bench:ifft32` had the same gap.

## Quick Reference

| Command                 | Benchmark                      | Competitors                                    |
| ----------------------- | ------------------------------ | ---------------------------------------------- |
| `npm run bench`         | Complex FFT (all wat variants) | fft.js, fft-js, kissfft-js, webfft, pffft-wasm |
| `npm run bench:rfft`    | Real FFT (f64)                 | fftw-js, kissfft-js, webfft, pffft-wasm        |
| `npm run bench:f32`     | Complex FFT (f32)              | fft.js, pffft-wasm                             |
| `npm run bench:ifft32`  | Inverse Complex FFT (f32)      | fft.js, pffft-wasm                             |
| `npm run bench:rfft32`  | Real FFT (f32)                 | fftw-js, pffft-wasm (SIMD)                     |
| `npm run bench:irfft32` | Inverse Real FFT (f32)         | fftw-js, pffft-wasm (SIMD)                     |
| `npm run bench:browser` | Browser FFT (all types)        | fft.js, fft-js, kissfft-js, webfft, pffft-wasm |
| `npm run bench:gpu`     | GPU FFT (Deno + WebGPU)        | webgpu-fft — standalone, GPU-only, not in CI   |

Every command benchmarks **all registry entries** for its surface/precision, so summaries and CI checks always include the flagship implementation.

`bench:gpu` is the exception: it measures the GPU library `webgpu-fft` on its own (not a head-to-head with wat-fft) and is excluded from CI since runners have no GPU. See [GPU Benchmark](#gpu-benchmark-deno--webgpu) below.

## Benchmark Files

### Node.js Benchmarks

| File                       | Purpose                                                                         |
| -------------------------- | ------------------------------------------------------------------------------- |
| `fft.bench.js`             | Main complex FFT benchmark - compares all wat-fft variants against JS libraries |
| `rfft.bench.js`            | Real FFT benchmark - compares f64 rfft against fftw-js and kissfft-js           |
| `fft_f32_dual.bench.js`    | f32 dual-complex FFT - measures the +105% dual-complex optimization             |
| `ifft_f32_dual.bench.js`   | f32 inverse complex FFT - native inverse vs fft.js and pffft-wasm backward      |
| `rfft_f32_dual.bench.js`   | f32 dual-complex rfft - compares against fftw-js and pffft-wasm SIMD (all f32)  |
| `irfft_f32_dual.bench.js`  | f32 inverse rfft - compares against fftw-js and pffft-wasm SIMD inverses        |
| `fft_kernel_only.bench.js` | FFT kernel only - excludes interleaved<->split format conversion overhead       |

All Node bench files use the shared statistical harness `lib/harness.js` (see Configuration below).

### Browser Benchmarks (Vitest)

| File                    | Purpose                                                   |
| ----------------------- | --------------------------------------------------------- |
| `browser/fft.bench.ts`  | Complex FFT in browser - wat-fft vs fft.js, kissfft, etc. |
| `browser/rfft.bench.ts` | Real FFT in browser - wat-rfft vs fft.js real             |
| `browser/fft-loader.ts` | WASM loader and competitor library initialization         |

### GPU Benchmark (Deno + WebGPU)

| File                         | Purpose                                                               |
| ---------------------------- | --------------------------------------------------------------------- |
| `deno/fft_gpu.bench.ts`      | GPU FFT single-call latency (`webgpu-fft`) under Deno's native WebGPU |
| `deno/fft_gpu_throughput.ts` | Sustained GPU FFTs/sec vs concurrency (the GPU's favorable regime)    |
| `deno/setup.ts`              | Clones + builds webgpu-fft into a gitignored vendor dir               |

Run with `npm run bench:gpu`. This measures the GPU library **in isolation** —
it is deliberately not compared against wat-fft (a WebGPU FFT is a different
class: async, dominated by device round-trip latency). Two regimes are
reported: single-call **latency** (~14 ms flat, the GPU's worst case) and
sustained **throughput** with many transforms in flight (~420–470 FFTs/sec peak
on an M5 Pro — the ceiling of a library that syncs on every call). It is
**excluded from CI** (runners have no GPU) and requires Deno 2.x + a real GPU.
See [`deno/README.md`](deno/README.md).

### Shared Infrastructure

| File                      | Purpose                                                                 |
| ------------------------- | ----------------------------------------------------------------------- |
| `shared/wat-surfaces.mjs` | Surface registry: which wat modules/exports every bench must measure    |
| `lib/wat-contexts.js`     | Node-side registry-driven wat contexts (module loading, input staging)  |
| `lib/harness.js`          | Statistical harness (warmup, calibrated samples, medians, JSON results) |

## Running Benchmarks

### Basic Usage

```bash
# Build first (required)
npm run build

# Run main benchmarks
npm run bench        # Complex FFT
npm run bench:rfft   # Real FFT (f64)
npm run bench:f32    # Complex FFT (f32)
npm run bench:ifft32 # Inverse Complex FFT (f32)
npm run bench:rfft32 # Real FFT (f32)
npm run bench:irfft32 # Inverse Real FFT (f32)
```

### Running Individual Benchmarks

```bash
node benchmarks/fft.bench.js
node benchmarks/rfft.bench.js
node benchmarks/fft_f32_dual.bench.js
node benchmarks/rfft_f32_dual.bench.js
```

## Configuration

All Node benchmarks share the statistical harness in `benchmarks/lib/harness.js`:

```javascript
const DEFAULT_CONFIG = {
  warmupMs: 200, // time-based JIT warmup (after warmupIterations)
  warmupIterations: 100,
  samples: 10, // independent timed samples per benchmark
  sampleMs: 150, // target duration of each sample
};
```

- **Sampling**: each benchmark runs 10 batch-calibrated samples of ~150ms (no timer calls in the hot loop, which matters at small N). Reported ops/s is the **median** across samples; min/max/CV describe the spread.
- **Deterministic inputs**: all bench files generate inputs with `seededRandom(n)` (mulberry32), so runs are reproducible across runs and machines.

## Output Format

Each size group prints a table sorted fastest-first, with a ±CV (coefficient of variation) noise column:

```
Implementation                median ops/s     ±CV      relative
------------------------------------------------------------------
wat-fft rfft_split               7,912,345    0.3%    (fastest)
pffft-wasm (SIMD)                7,193,210    0.5%        90.9%
fftw-js                          2,701,882    0.4%        34.2%
```

Every run also persists JSON to `benchmarks/results/<benchId>.latest.json` (gitignored) with full results plus metadata: git commit/branch/dirty flag, Node/V8 version, CPU model, platform, and timestamp. Passing `--save-baseline` additionally writes `<benchId>.baseline.json` for later comparison.

## Comparing Runs (bench:diff)

To judge an optimization, save a baseline before the change and diff after:

```bash
node benchmarks/rfft_f32_dual.bench.js --save-baseline   # before change
# ...make changes, npm run build...
node benchmarks/rfft_f32_dual.bench.js                   # after change
npm run bench:diff                    # compare all baseline/latest pairs
npm run bench:diff rfft-f32           # compare one benchmark id
npm run bench:diff -- --fail-on-regression   # exit 1 on significant regression
```

`scripts/bench-diff.js` flags a delta as significant (▲/▼) only when |delta| > max(2%, 3× combined CV); everything else is marked `~` (within noise). Two explicit JSON paths can also be passed to compare arbitrary runs.

**Cross-process noise caveat**: separate processes running identical code have shown swings up to -13% at small N (N=64/128 split rfft) even with within-run CV of 0.1% — thermal and code-layout effects. Confirm significant small-N deltas with a second run pair before acting on them.

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

**IMPORTANT - use the SIMD build**: `@echogarden/pffft-wasm` ships two builds, and the
bare import resolves to the **non-SIMD** build:

```json
{ ".": "./dist/non-simd/pffft.js", "./simd": "./dist/simd/pffft.js" }
```

Always `import PFFFT from "@echogarden/pffft-wasm/simd"` - the SIMD build is 2-3x faster
and is the honest competitor. Experiments 1-56 accidentally benchmarked the non-SIMD
build (see Experiment 57).

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

1. **Consistency**: the ±CV column measures within-run noise; distrust small deltas on any result with CV above ~3%
2. **Size scaling**: Performance should scale appropriately with N
3. **Regressions**: use `npm run bench:diff` against a saved baseline (noise-aware); see the experiment log for historical context

### Precision Considerations

- **f64 vs f32**: Our f64 benchmarks compare against f32 competitors (fftw-js)
- **Fair comparison**: Use `bench:rfft32` for apples-to-apples f32 comparison
- **SIMD throughput**: f32x4 processes 2 complex numbers vs f64x2's 1

## Adding New Benchmarks

1. Create `benchmarks/your_benchmark.bench.js`
2. Use the shared harness — do not hand-roll a timing loop:

   ```javascript
   import { runBenchmark, printResults, saveResults, seededRandom } from "./lib/harness.js";

   const sizeGroups = [];
   for (const size of [64, 256, 1024, 4096]) {
     const rand = seededRandom(size); // deterministic input
     const results = [];
     results.push(runBenchmark("my-impl", setupFn, benchFn, teardownFn));
     printResults(results);
     sizeGroups.push({ size, results });
   }
   saveResults("my-bench", sizeGroups); // JSON for bench:diff
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

### Vitest Browser Benchmarks

Run benchmarks in a real browser environment using Vitest's browser mode with Playwright:

```bash
# Run all browser benchmarks
npm run bench:browser

# Run specific benchmark file
npx vitest bench --run benchmarks/browser/fft.bench.ts
npx vitest bench --run benchmarks/browser/rfft.bench.ts
```

Features:

- Runs in Chromium via Playwright (headless by default)
- Measures all wat-fft variants: f64, f32, f32-split
- Compares against fft.js, fft-js, kissfft-js, webfft
- Reports ops/sec, min/max latency, and percentiles
- Shows relative performance comparisons

Browser benchmark files:

| File                    | Contents                                       |
| ----------------------- | ---------------------------------------------- |
| `browser/fft.bench.ts`  | Complex FFT benchmarks (N=64, 256, 1024, 4096) |
| `browser/rfft.bench.ts` | Real FFT benchmarks                            |
| `browser/fft-loader.ts` | WASM and competitor library loader             |

Note: pffft-wasm (SIMD build) is included via a custom `locateFile` hook in
`browser/fft-loader.ts` that serves `dist/simd/pffft.wasm` through Vite. The Vitest
server sends COOP/COEP headers so `performance.now()` gets 5µs resolution in Chromium
(without cross-origin isolation it is clamped to 100µs, quantizing every sample).

### Interactive Playground

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
