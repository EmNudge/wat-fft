# Optimization Experiment Log

Detailed record of all optimization experiments.

## Quick Reference

| #   | Experiment                 | Result          | Key Finding                                   |
| --- | -------------------------- | --------------- | --------------------------------------------- |
| 1   | Dual-Complex f32 SIMD      | FAILURE -15-20% | Branch overhead, twiddle replication hurt JIT |
| 2   | N=8 Codelet                | FAILURE         | Stockham permutation semantics complex        |
| 3   | Radix-4 Stockham SIMD      | SUCCESS +51%    | Fewer stages + inlined SIMD crucial           |
| 4   | N=16 Codelet               | SUCCESS +54%    | Unrolled with inline twiddles                 |
| 5   | Real FFT + Radix-4         | SUCCESS         | Tests pass, faster rfft                       |
| 6   | Codelet Generator          | PARTIAL         | Correct but 320+ locals cause spills          |
| 7   | Inline SIMD cmul           | NO CHANGE       | V8 already inlines small functions            |
| 8   | Fused rfft Codelets        | SUCCESS +123%   | N=8, N=32 fused codelets                      |
| 9   | Hierarchical FFT           | SUCCESS +30pp   | DIF composition, optimal at N=1024            |
| 10  | Depth-First DIF            | FAILURE -55%    | Call overhead > cache benefit                 |
| 11  | SIMD Post-Processing       | SUCCESS +2-8pp  | v128 ops in rfft post-process                 |
| 12  | Relaxed SIMD FMA           | SUCCESS +1-5%   | Modest gains, V8 optimizes well               |
| 13  | f32 Dual-Complex rfft      | SUCCESS +73%    | Combined with dual-complex FFT                |
| 14  | f32x4 SIMD Post-Process    | SUCCESS +13pp   | Process 2 pairs per iteration                 |
| 15  | Fused FFT-64 Codelet       | SUCCESS +8%     | Eliminated 6 function calls                   |
| 16  | f32 Small-N Codelets       | SUCCESS +50pp   | Fixed W_8^3 sign bug                          |
| 16b | f32 FFT-64 Codelet         | SUCCESS +45pp   | N=128 now +30% vs fftw-js                     |
| 17  | Bit-Reversal Permutation   | FAILURE         | Hierarchical DIF != standard bitrev           |
| 18  | DIT Natural Order Codelets | SUCCESS +4%     | Loads bit-reversed, outputs natural           |
| 19  | SIMD Threshold N=64        | SUCCESS +8pp    | Lowered threshold from 128 to 64              |

---

## Experiment 1: Dual-Complex f32 SIMD (2026-01-21)

**Hypothesis**: Process 2 f32 complex numbers per v128 register.

**Result**: FAILURE - 15-20% SLOWER

**Analysis**: Overhead outweighed benefits:

1. `if (r >= 2)` branch in every iteration
2. Extra shuffle for twiddle replication
3. Complex control flow hurt JIT

**Lesson**: Simple, predictable loops optimize better than clever branching.

---

## Experiment 2: N=8 Codelet (2026-01-21)

**Result**: FAILURE - Incorrect output

**Analysis**: Stockham FFT has complex permutation semantics. Each stage reorders data differently than Cooley-Tukey DIT.

**Lesson**: Codelet generation should be automated, not hand-written.

---

## Experiment 3: Radix-4 Stockham with SIMD (2026-01-21)

**Result**: SUCCESS - Up to +51.3% faster than radix-2

| Size   | Radix-2 | Radix-4 SIMD | Speedup |
| ------ | ------- | ------------ | ------- |
| N=16   | 10.4M   | 12.2M        | +16.9%  |
| N=64   | 3.5M    | 3.9M         | +10.5%  |
| N=1024 | 169K    | 196K         | +16.3%  |
| N=4096 | 29.5K   | 44.6K        | +51.3%  |

**Key**: Inlined SIMD complex multiply critical. Function call version was 25-40% slower.

---

## Experiment 4: N=16 Fully Unrolled Codelet (2026-01-21)

**Result**: SUCCESS - +54.6% speedup at N=16

All 16 loads, 2 radix-4 stages fully unrolled, inline twiddle constants, no loops.

---

## Experiment 5: Real FFT with Radix-4 (2026-01-21)

**Result**: SUCCESS - All tests pass, faster rfft for power-of-4 N/2 sizes.

---

## Experiment 6: Automated Codelet Generator (2026-01-22)

**Result**: PARTIAL SUCCESS - Correct but limited performance gains

**Analysis**:

- Codelets numerically correct (max error ~10⁻¹⁵)
- N=32 codelet: 320+ locals causing register spills
- N=64 codelet: 768+ locals → stack memory spills

**Key Insight**: FFTW's approach of composing small codelets (N<=16) is superior to large monolithic codelets.

---

## Experiment 7: Inline SIMD Complex Multiply (2026-01-22)

**Result**: NO IMPROVEMENT

V8's TurboFan JIT already inlines small hot functions like `$simd_cmul`.

---

## Experiment 8: Fused Real-FFT Codelets (2026-01-22)

**Result**: SIGNIFICANT IMPROVEMENT

| Size | vs fftw-js  |
| ---- | ----------- |
| N=8  | **+123.8%** |
| N=32 | **+45.7%**  |

- `$rfft_8`: Fully fused, inline FFT-4, hardcoded post-processing twiddles
- `$rfft_32`: Hybrid - calls `$fft_16` + hardcoded post-processing

---

## Experiment 9: Hierarchical FFT Composition (2026-01-23)

**Result**: SIGNIFICANT IMPROVEMENT

DIF decomposition with parameterized codelets ($fft_16_at, $fft_32_at, etc.).

| Size   | Before | After      |
| ------ | ------ | ---------- |
| N=64   | -30%   | **+3.4%**  |
| N=256  | -17%   | **+12.3%** |
| N=1024 | -40%   | -26.9%     |

**Failed extension**: $fft_2048 made N=4096 7% slower (instruction cache thrashing).

**Optimal ceiling**: N=1024

---

## Experiment 10: Depth-First Recursive DIF FFT (2026-01-23)

**Result**: SLOWER THAN EXPECTED

| Size   | vs Combined |
| ------ | ----------- |
| N=64   | -37%        |
| N=1024 | -50%        |
| N=4096 | -55%        |
| N=8192 | -11%        |

**Why**: Function call overhead + bit-reversal permutation cost. Iterative Stockham avoids bit-reversal via ping-pong buffers.

---

## Experiment 11: SIMD Post-Processing for Real FFT (2026-01-24)

**Result**: SUCCESS - 2-8pp improvement

Created `$rfft_postprocess_simd` using v128 operations.

---

## Experiment 12: Relaxed SIMD FMA (2026-01-24)

**Result**: MODEST IMPROVEMENT - +1% to +5%

Smaller than expected because V8 already optimizes SIMD sequences well.

---

## Experiment 13: f32 Dual-Complex Real FFT (2026-01-24)

**Result**: SIGNIFICANT IMPROVEMENT - +28% to +73% vs existing f32 rfft

Discovery: Existing f32 rfft wasn't using dual-complex optimization.

---

## Experiment 14: f32x4 SIMD Post-Processing (2026-01-24)

**Result**: +5 to +13pp vs fftw-js

Process 2 complex pairs per iteration matching dual-complex FFT core throughput.

---

## Experiment 15: Fully Fused FFT-64 Codelet (2026-01-24)

**Result**: SUCCESS - N=128 gap halved

Eliminated 6 function calls per FFT-64 by inlining all stages.

---

## Experiment 16: f32 Dual-Complex Small-N Codelets (2026-01-24)

**Discovery**: Existing $fft_8, $fft_16 codelets were dead code with bugs.

**Root cause**: W_8^3 twiddle had wrong sign on imaginary part.

**After fix**:
| Size | vs fftw-js Before | vs fftw-js After |
|-------|-------------------|------------------|
| N=64 | -17% | **+33.1%** |
| N=128 | -17% | -14.9% |

---

## Experiment 16b: f32 FFT-64 Codelet (2026-01-24)

**Result**: MASSIVE SUCCESS

| Size  | vs fftw-js Before | vs fftw-js After |
| ----- | ----------------- | ---------------- |
| N=128 | -15%              | **+30%**         |
| N=256 | -1.5%             | **+21%**         |

Now beats fftw-js at N=64 to N=512.

---

## Experiment 17: Bit-Reversal Permutation (2026-01-25)

**Result**: FAILURE - Incorrect output

**Root cause**: Hierarchical DIF produces non-standard permutation, not simple bit-reversal.

For hierarchical FFT-32, index `b4 b3 b2 b1 b0` maps to `b4 b0 b1 b2 b3` (MSB stays, lower bits reversed), not standard `b0 b1 b2 b3 b4`.

---

## Experiment 18: DIT Codelets with Natural Order Output (2026-01-25)

**Result**: SUCCESS

Created DIT codelets that load bit-reversed input and output natural order.

| Size | Before | After  |
| ---- | ------ | ------ |
| N=64 | -17.6% | -13.3% |

Generated N=64 codelet proved slower than Stockham due to shuffle overhead.

---

## Experiment 19: SIMD RFFT Post-Processing Threshold (2026-01-25)

**Result**: SUCCESS - +8.3pp at N=64

Changed SIMD threshold from N >= 128 to N >= 64. Simple one-line change with dramatic impact.

| Size | Before | After |
| ---- | ------ | ----- |
| N=64 | -12.5% | -4.2% |
