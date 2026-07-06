# FFT Optimization Plan: Closing the Gap with FFTW

## Executive Summary

wat-fft has achieved significant performance gains through systematic optimization. This document provides an overview - see linked sub-documents for details.

**Current Status** (Apple M5 Pro, 2026-07-06): **wat-fft beats ALL competitors at ALL sizes in ALL benchmarked transforms** — complex FFT, real FFT, and inverse real FFT (Experiment 53 closed the last gap, N=64).

| Target     | Complex FFT (f64) | Complex FFT (f32)             | Real FFT (f32)              |
| ---------- | ----------------- | ----------------------------- | --------------------------- |
| fft.js     | **+37-90%**       | **+110-230%**                 | N/A                         |
| fftw-js    | N/A               | N/A                           | **+5-55%** (beats at all N) |
| pffft-wasm | N/A               | **+21-102%** (beats at all N) | N/A                         |

---

## Documentation Index

| Document                                                          | Description                                                                    |
| ----------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| [FFTW_ANALYSIS.md](optimization/FFTW_ANALYSIS.md)                 | Why FFTW is fast: genfft codelets, operation fusion, cache-oblivious recursion |
| [COMPLETED_PRIORITIES.md](optimization/COMPLETED_PRIORITIES.md)   | Implemented optimizations: Priorities A-J with results                         |
| [FUTURE_PRIORITIES.md](optimization/FUTURE_PRIORITIES.md)         | Research completed but not implemented: split-radix, register scheduling       |
| [EXPERIMENT_LOG.md](optimization/EXPERIMENT_LOG.md)               | All 53 experiments with detailed results and lessons learned                   |
| [IMPLEMENTATION_PHASES.md](optimization/IMPLEMENTATION_PHASES.md) | Roadmap: testing infrastructure, codelet generation, SIMD deep optimization    |

---

## Key Findings Summary

### What Worked

1. **Radix-4 Stockham with SIMD** (+51% vs radix-2) - Fewer stages, inlined complex multiply
2. **Fused rfft codelets** (+123% at N=8) - Eliminate function calls and twiddle loads
3. **Hierarchical composition** (+30pp at N=64) - DIF decomposition with small codelets
4. **f32 dual-complex SIMD** (+105%) - Process 2 complex numbers per v128
5. **SIMD post-processing** (+8pp) - v128 operations for rfft post-processing
6. **Multi-twiddle split stages** (+37pp) - Deinterleave for 4 different twiddles per SIMD, reaching 95% of pffft

### What Failed

1. **Initial dual-complex attempt** (-15%) - Branch overhead hurt JIT optimization
2. **Depth-first recursive FFT** (-55%) - Call overhead > cache locality benefit
3. **Large monolithic codelets** - 300+ locals cause register spills
4. **Hierarchical composition beyond N=1024** - Instruction cache thrashing
5. **Split real/imaginary format** (-65-75%) - Format conversion overhead negates SIMD gains
6. **Native split-format FFT** (46-58%) - Stockham groups same-twiddle elements, negating 4-wide SIMD benefit

### Key Insights

- **Optimal codelet ceiling is N=1024** - Beyond this, simple loops beat hierarchical composition
- **V8 already inlines small functions** - Manual inlining rarely helps
- **Hierarchical DIF != standard bit-reversal** - Non-trivial permutation pattern
- **f32 gives ~2x SIMD throughput** - Main competitive advantage of fftw-js
- **Split format requires algorithm co-design** - Stockham groups same-twiddle elements; pffft restructures to group different-twiddle elements

---

## Performance vs Competitors

### Complex FFT vs fft.js (pure JS)

**f64 (double precision):**

| Size   | wat-fft | fft.js | Speedup  |
| ------ | ------- | ------ | -------- |
| N=64   | 3.76M   | 2.76M  | **+36%** |
| N=256  | 934K    | 550K   | **+70%** |
| N=1024 | 193K    | 113K   | **+71%** |
| N=4096 | 44.4K   | 23.4K  | **+90%** |

**f32 (single precision, fastest):**

| Size   | wat-fft f32 | fft.js | Speedup   |
| ------ | ----------- | ------ | --------- |
| N=64   | 6.1M        | 2.84M  | **+115%** |
| N=256  | 1.67M       | 572K   | **+192%** |
| N=1024 | 369K        | 114K   | **+223%** |
| N=4096 | 81K         | 23.9K  | **+239%** |

**vs pffft-wasm (f32 vs f32):**

| Size   | wat-fft f32 | pffft-wasm | Speedup  |
| ------ | ----------- | ---------- | -------- |
| N=64   | 6.0M        | 4.6M       | **+30%** |
| N=256  | 1.67M       | 1.0M       | **+67%** |
| N=1024 | 365K        | 206K       | **+77%** |
| N=4096 | 81K         | 42K        | **+93%** |

_Note: wat-fft f32 interleaved format now significantly outperforms pffft-wasm. The split-format module (Experiment 40) achieves similar performance to interleaved, providing format flexibility without sacrificing speed._

### Real FFT f32 vs fftw-js

Measured on Apple M5 Pro, Node v24.14.1 (Experiment 53, 2026-07-06): n2=16/32 cores now use the Stockham loop instead of DIT codelets.

| Size   | wat-fft f32 | fftw-js | Result   |
| ------ | ----------- | ------- | -------- |
| N=64   | 15.3M       | 12.6M   | **+22%** |
| N=128  | 8.2M        | 7.8M    | **+5%**  |
| N=256  | 4.2M        | 2.7M    | **+55%** |
| N=512  | 2.0M        | 1.6M    | **+25%** |
| N=1024 | 972K        | 833K    | **+17%** |
| N=2048 | 464K        | 409K    | **+14%** |
| N=4096 | 221K        | 192K    | **+15%** |

### Inverse Real FFT f32 vs fftw-js

Measured on Apple M5 Pro (Experiments 52-53, 2026-07-06): native inverse FFT (conjugated twiddles via flipped sign mask, 1/N folded into preprocess, no extra passes) with the n2=16/32 cores on the Stockham loop.

| Size   | wat-fft f32 | fftw-js | Result   |
| ------ | ----------- | ------- | -------- |
| N=64   | 15.4M       | 12.8M   | **+23%** |
| N=128  | 8.4M        | 8.1M    | **+4%**  |
| N=256  | 4.2M        | 3.3M    | **+29%** |
| N=512  | 2.1M        | 1.8M    | **+17%** |
| N=1024 | 989K        | 880K    | **+13%** |
| N=2048 | 467K        | 419K    | **+11%** |
| N=4096 | 225K        | 198K    | **+14%** |

---

## Remaining Gap Analysis

On Apple M5 Pro (Experiments 47-53), **no gaps remain**: wat-fft beats fftw-js at every benchmarked size in both directions (forward +5% to +55%, inverse +4% to +29%).

The last gap (N=64, both directions) closed in Experiment 53: the fully-unrolled `fft_32_dit`/`ifft_32_dit` DIT codelets turned out to be 66-97% SLOWER than the plain Stockham loop on M5 (register pressure + shuffle cost), so n=16/32 now dispatch to the loop. N=64 jumped +31-32% in one change.

Open opportunities (wins, not gaps):

- ~~**Complex f32 module small-N dispatch**~~: probed in Experiment 54 - its radix-4 single-lane codelets WIN on M5 (+34-47% vs the loop); no change needed. The Experiment 53 loss was specific to the radix-2 dual-complex DIT codelet design.
- **Radix-4-style n=32 codelet for the real module**: the complex module's radix-4 n=16 codelet does 67M ops/s where the real module's n2=32 core (now on the loop) does 30M; a 4-4-2-stage codelet could extend the N=64 win further (Experiment 54 data).
- **Native inverse for the complex f32 `ifft`**: still uses the conjugation identity with two extra full passes; Experiment 52's flipped-sign-mask approach ports directly (needs an ifft benchmark first - Experiment 49's lesson).
- **Periodic re-baselining**: two M5 findings (Experiments 47, 53) reversed old-hardware conclusions; re-run the codelet-vs-loop probes when hardware changes.

Complex FFT has no gaps: beats all competitors at all sizes (+21% to +102% vs pffft-wasm on M5 Pro).

---

## Quick Start for Contributors

1. **Read experiment log first** - Learn from what worked and failed
2. **Check completed priorities** - Don't duplicate effort
3. **Codelets must earn their place** - On M5 the Stockham loop beats DIT codelets at n>=16 (Experiment 53); isolate and A/B a core before hand-unrolling it
4. **Test thoroughly** - FFT permutation semantics are subtle
5. **Benchmark before/after** - V8 is already highly optimized

---

## Files Created During Optimization

| File                                | Purpose                              |
| ----------------------------------- | ------------------------------------ |
| `modules/fft_combined.wat`          | Auto-dispatch radix-2/4              |
| `modules/fft_stockham_f32_dual.wat` | f32 dual-complex FFT                 |
| `modules/fft_real_f32_dual.wat`     | f32 dual-complex rfft                |
| `modules/fft_real_combined.wat`     | Combined rfft with codelets          |
| `modules/fft_split_native_f32.wat`  | Native split-format FFT (experiment) |
| `tools/codelet_generator.js`        | DAG-based codelet generator          |
| `tools/generate-dit-codelet.js`     | DIT codelet generator                |
