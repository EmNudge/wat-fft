# FFT Optimization Plan: Closing the Gap with FFTW

## Executive Summary

wat-fft has achieved significant performance gains through systematic optimization. This document provides an overview - see linked sub-documents for details.

**Current Status**: Beats fftw-js at ALL sizes for Real FFT f32, significantly faster than pure JS libraries.

| Target  | Complex FFT | Real FFT (f64)        | Real FFT (f32)                               |
| ------- | ----------- | --------------------- | -------------------------------------------- |
| fft.js  | **+40-90%** | N/A                   | N/A                                          |
| fftw-js | N/A         | **Wins N<=64, N=256** | **Wins all sizes** (+1-47% across N=64-4096) |

---

## Documentation Index

| Document                                                          | Description                                                                    |
| ----------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| [FFTW_ANALYSIS.md](optimization/FFTW_ANALYSIS.md)                 | Why FFTW is fast: genfft codelets, operation fusion, cache-oblivious recursion |
| [COMPLETED_PRIORITIES.md](optimization/COMPLETED_PRIORITIES.md)   | Implemented optimizations: Priorities A-J with results                         |
| [FUTURE_PRIORITIES.md](optimization/FUTURE_PRIORITIES.md)         | Research completed but not implemented: split-radix, register scheduling       |
| [EXPERIMENT_LOG.md](optimization/EXPERIMENT_LOG.md)               | All 19 experiments with detailed results and lessons learned                   |
| [IMPLEMENTATION_PHASES.md](optimization/IMPLEMENTATION_PHASES.md) | Roadmap: testing infrastructure, codelet generation, SIMD deep optimization    |

---

## Key Findings Summary

### What Worked

1. **Radix-4 Stockham with SIMD** (+51% vs radix-2) - Fewer stages, inlined complex multiply
2. **Fused rfft codelets** (+123% at N=8) - Eliminate function calls and twiddle loads
3. **Hierarchical composition** (+30pp at N=64) - DIF decomposition with small codelets
4. **f32 dual-complex SIMD** (+105%) - Process 2 complex numbers per v128
5. **SIMD post-processing** (+8pp) - v128 operations for rfft post-processing

### What Failed

1. **Initial dual-complex attempt** (-15%) - Branch overhead hurt JIT optimization
2. **Depth-first recursive FFT** (-55%) - Call overhead > cache locality benefit
3. **Large monolithic codelets** - 300+ locals cause register spills
4. **Hierarchical composition beyond N=1024** - Instruction cache thrashing

### Key Insights

- **Optimal codelet ceiling is N=1024** - Beyond this, simple loops beat hierarchical composition
- **V8 already inlines small functions** - Manual inlining rarely helps
- **Hierarchical DIF != standard bit-reversal** - Non-trivial permutation pattern
- **f32 gives ~2x SIMD throughput** - Main competitive advantage of fftw-js

---

## Performance vs Competitors

### Complex FFT vs fft.js (pure JS)

| Size   | wat-fft | fft.js | Speedup  |
| ------ | ------- | ------ | -------- |
| N=64   | 3.83M   | 2.79M  | **+37%** |
| N=256  | 973K    | 559K   | **+74%** |
| N=1024 | 191K    | 113K   | **+69%** |
| N=4096 | 44.4K   | 23.4K  | **+90%** |

### Real FFT f32 vs fftw-js

| Size   | wat-fft f32 | fftw-js | Result   |
| ------ | ----------- | ------- | -------- |
| N=64   | 6.67M       | 6.61M   | **+1%**  |
| N=128  | 4.29M       | 4.19M   | **+2%**  |
| N=256  | 2.17M       | 1.47M   | **+47%** |
| N=512  | 1.13M       | 845K    | **+34%** |
| N=1024 | 526K        | 447K    | **+18%** |
| N=2048 | 256K        | 224K    | **+15%** |
| N=4096 | 117K        | 105K    | **+12%** |

---

## Remaining Gap Analysis

The performance gap at larger sizes (N >= 1024) is explained by:

1. **FFTW's genfft codelets** - Better register scheduling, more CSE
2. **FFTW's cache-oblivious recursion** - Better locality at very large N
3. **Runtime planning** - FFTW selects optimal algorithm per-size

For our target use cases (N <= 4096), the gap is acceptable and further optimization has diminishing returns.

---

## Quick Start for Contributors

1. **Read experiment log first** - Learn from what worked and failed
2. **Check completed priorities** - Don't duplicate effort
3. **Small codelets only** - Keep N <= 16 to avoid register spills
4. **Test thoroughly** - FFT permutation semantics are subtle
5. **Benchmark before/after** - V8 is already highly optimized

---

## Files Created During Optimization

| File                                | Purpose                     |
| ----------------------------------- | --------------------------- |
| `modules/fft_radix4.wat`            | Radix-4 Stockham with SIMD  |
| `modules/fft_combined.wat`          | Auto-dispatch radix-2/4     |
| `modules/fft_stockham_f32_dual.wat` | f32 dual-complex FFT        |
| `modules/fft_real_f32_dual.wat`     | f32 dual-complex rfft       |
| `modules/fft_real_combined.wat`     | Combined rfft with codelets |
| `modules/fft_real_combined_fma.wat` | FMA-optimized rfft          |
| `tools/codelet_generator.js`        | DAG-based codelet generator |
| `tools/generate-dit-codelet.js`     | DIT codelet generator       |
