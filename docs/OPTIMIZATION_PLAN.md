# FFT Optimization Plan: Closing the Gap with FFTW

## Executive Summary

wat-fft has achieved significant performance gains through systematic optimization. This document provides an overview - see linked sub-documents for details.

**Current Status** (Apple M5 Pro, 2026-07-05): Complex FFT beats ALL competitors at ALL sizes. Real FFT beats fftw-js at N≥128; fftw-js is ~5-7% faster at N=64 on this hardware. Inverse Real FFT beats fftw-js at N≥256; fftw-js is faster at N=64/128 (see Remaining Gap Analysis).

| Target     | Complex FFT (f64) | Complex FFT (f32)             | Real FFT (f32)                       |
| ---------- | ----------------- | ----------------------------- | ------------------------------------ |
| fft.js     | **+37-90%**       | **+110-230%**                 | N/A                                  |
| fftw-js    | N/A               | N/A                           | **+4-54%** at N≥128, **-6%** at N=64 |
| pffft-wasm | N/A               | **+21-102%** (beats at all N) | N/A                                  |

---

## Documentation Index

| Document                                                          | Description                                                                    |
| ----------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| [FFTW_ANALYSIS.md](optimization/FFTW_ANALYSIS.md)                 | Why FFTW is fast: genfft codelets, operation fusion, cache-oblivious recursion |
| [COMPLETED_PRIORITIES.md](optimization/COMPLETED_PRIORITIES.md)   | Implemented optimizations: Priorities A-J with results                         |
| [FUTURE_PRIORITIES.md](optimization/FUTURE_PRIORITIES.md)         | Research completed but not implemented: split-radix, register scheduling       |
| [EXPERIMENT_LOG.md](optimization/EXPERIMENT_LOG.md)               | All 51 experiments with detailed results and lessons learned                   |
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

Measured on Apple M5 Pro, Node v24.14.1 (Experiments 47-48, 2026-07-05). Earlier docs were benchmarked on older hardware; margins shifted with the microarchitecture change.

| Size   | wat-fft f32 | fftw-js | Result   |
| ------ | ----------- | ------- | -------- |
| N=64   | 12.1M       | 12.9M   | **-6%**  |
| N=128  | 8.3M        | 8.0M    | **+4%**  |
| N=256  | 4.2M        | 2.7M    | **+54%** |
| N=512  | 2.0M        | 1.6M    | **+23%** |
| N=1024 | 966K        | 844K    | **+15%** |
| N=2048 | 461K        | 411K    | **+12%** |
| N=4096 | 220K        | 195K    | **+13%** |

### Inverse Real FFT f32 vs fftw-js

Measured on Apple M5 Pro (Experiments 50-51, 2026-07-05): SIMD preprocess with fused conjugate, unrolled N=64/128 codelets.

| Size   | wat-fft f32 | fftw-js | Result   |
| ------ | ----------- | ------- | -------- |
| N=64   | 10.9M       | 12.7M   | **-14%** |
| N=128  | 7.8M        | 8.3M    | **-7%**  |
| N=256  | 3.9M        | 3.3M    | **+16%** |
| N=512  | 1.9M        | 1.8M    | **+8%**  |
| N=1024 | 921K        | 881K    | **+4%**  |
| N=2048 | 438K        | 421K    | **+4%**  |
| N=4096 | 209K        | 195K    | **+6%**  |

---

## Remaining Gap Analysis

On Apple M5 Pro (Experiments 47-51), the open gaps are:

- **IRFFT N=64/128**: fftw-js `inverse` is faster at N=64 (-14%) and N=128 (-7%). Experiment 50 (SIMD preprocess + fused conjugate) closed most of the original gap — IRFFT wins at all sizes N≥256 (+4% to +19%) — and Experiment 51 (unrolled preprocess codelets) added +3% at N=128. The residual is structural: the inverse does an extra `$scale_and_conjugate` full-buffer pass the forward path doesn't have. Removing it needs a native inverse Stockham (negated twiddles) with the 1/N scale folded into the preprocess constants.
- **N=64 RFFT**: fftw-js is consistently ~5-7% faster (outside noise). Profiling shows 67% of time in `$fft_32_dit` (68 locals, register-spill territory) — the prior "tied" result was hardware-specific. Re-investigation on M5 is open work; Experiments 22-25/44 findings were from older hardware.
- **Forward RFFT N≥128**: Consistently faster (+4% to +54%)

Complex FFT has no gaps: beats all competitors at all sizes (+21% to +102% vs pffft-wasm on M5 Pro).

---

## Quick Start for Contributors

1. **Read experiment log first** - Learn from what worked and failed
2. **Check completed priorities** - Don't duplicate effort
3. **Small codelets only** - Keep N <= 16 to avoid register spills
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
