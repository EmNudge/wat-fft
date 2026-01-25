# Completed Optimization Priorities

This document summarizes optimizations that have been implemented.

## Priority A: Twiddle-Butterfly Fusion - ALREADY IMPLEMENTED

**Status**: Already in our code from the start

Our code already fuses twiddle multiply with butterfly in a single loop iteration. Experiment 7 confirmed that inlining `$simd_cmul` provides no additional benefit - V8 already inlines small functions.

**Conclusion**: This optimization path is exhausted.

---

## Priority B: Fused Real-FFT Codelets - UP TO +123%

**Status**: Implemented for N=8 and N=32

Created specialized rfft codelets that fuse pack + FFT + unpack.

**Results vs fftw-js:**
| Size | Improvement |
|------|-------------|
| N=8 | **+123.8%** |
| N=32 | **+45.7%** |

**Implementation:**

- `$rfft_8`: Fully fused with inline FFT-4 and hardcoded post-processing twiddles
- `$rfft_32`: Calls `$fft_16` codelet then hardcoded post-processing

---

## Priority F: Hierarchical Small-Codelet Composition - OPTIMAL CEILING REACHED

**Status**: Implemented for N=32 through N=1024. N=1024 is the optimal ceiling.

Uses small codelets (N=4, N=16) as building blocks via DIF decomposition.

**Results vs fftw-js:**
| Size | Before | After |
|--------|---------|------------|
| N=64 | -30% | **+3.4%** |
| N=128 | -33% | -16.8% |
| N=256 | -17% | **+12.3%** |
| N=512 | -21% | -15.8% |
| N=1024 | -40% | -26.9% |

**Limitation discovered**: Extending to N=2048 made N=4096 **7% slower** due to instruction cache thrashing. Code size grows exponentially.

---

## Priority G: Real-Only Arithmetic in Early Stages - NOT APPLICABLE

Our pack-based rfft algorithm already achieves computational savings through a different mechanism (N/2 FFT instead of N FFT via packing pairs of reals as complex).

---

## Priority H: SIMD Pack/Unpack Fusion - +2-8pp

**Status**: Implemented via SIMD post-processing

Created `$rfft_postprocess_simd` using v128 SIMD operations for all post-processing computations.

**Results:**
| Size | Improvement |
|--------|-------------|
| N=128 | +8.5pp |
| N=256 | +6.7pp |
| N=512 | +2.3pp |
| N=1024 | +5.0pp |
| N=2048 | +5.6pp |
| N=4096 | +4.1pp |

---

## Priority I: f32 SIMD Dual-Complex - UP TO +105%

**Status**: Implemented for both complex FFT and real FFT

Process 2 f32 complex numbers per v128 register, doubling SIMD throughput.

**Complex FFT results:**
| Size | vs Original f32 | vs fft.js |
|--------|-----------------|-----------|
| N=64 | +50.6% | +64.1% |
| N=256 | +74.7% | +110.0% |
| N=1024 | +92.1% | +142.5% |
| N=4096 | +104.8% | +164.1% |

**Real FFT results vs fftw-js:**
| Size | vs fftw-js |
|--------|------------|
| N=256 | **+21.1%** |
| N=512 | **+1.2%** |
| N=1024 | -4.3% |
| N=4096 | -3.8% |

---

## Priority J: Relaxed SIMD FMA - +1% to +5%

**Status**: Implemented

Used `f64x2.relaxed_madd` (fused multiply-add) to reduce instruction count.

**Results:**
| Size | Speedup |
|--------|---------|
| N=128 | +4.9% |
| N=512 | +1.1% |
| N=2048 | +2.6% |
| N=4096 | +1.7% |

Gains smaller than expected because V8's JIT already optimizes well.
