# Optimization Experiment Log

Detailed record of all optimization experiments.

## Quick Reference

| #   | Experiment                  | Result           | Key Finding                                   |
| --- | --------------------------- | ---------------- | --------------------------------------------- |
| 1   | Dual-Complex f32 SIMD       | FAILURE -15-20%  | Branch overhead, twiddle replication hurt JIT |
| 2   | N=8 Codelet                 | FAILURE          | Stockham permutation semantics complex        |
| 3   | Radix-4 Stockham SIMD       | SUCCESS +51%     | Fewer stages + inlined SIMD crucial           |
| 4   | N=16 Codelet                | SUCCESS +54%     | Unrolled with inline twiddles                 |
| 5   | Real FFT + Radix-4          | SUCCESS          | Tests pass, faster rfft                       |
| 6   | Codelet Generator           | PARTIAL          | Correct but 320+ locals cause spills          |
| 7   | Inline SIMD cmul            | NO CHANGE        | V8 already inlines small functions            |
| 8   | Fused rfft Codelets         | SUCCESS +123%    | N=8, N=32 fused codelets                      |
| 9   | Hierarchical FFT            | SUCCESS +30pp    | DIF composition, optimal at N=1024            |
| 10  | Depth-First DIF             | FAILURE -55%     | Call overhead > cache benefit                 |
| 11  | SIMD Post-Processing        | SUCCESS +2-8pp   | v128 ops in rfft post-process                 |
| 12  | Relaxed SIMD FMA            | SUCCESS +1-5%    | Modest gains, V8 optimizes well               |
| 13  | f32 Dual-Complex rfft       | SUCCESS +73%     | Combined with dual-complex FFT                |
| 14  | f32x4 SIMD Post-Process     | SUCCESS +13pp    | Process 2 pairs per iteration                 |
| 15  | Fused FFT-64 Codelet        | SUCCESS +8%      | Eliminated 6 function calls                   |
| 16  | f32 Small-N Codelets        | SUCCESS +50pp    | Fixed W_8^3 sign bug                          |
| 16b | f32 FFT-64 Codelet          | SUCCESS +45pp    | N=128 now +30% vs fftw-js                     |
| 17  | Bit-Reversal Permutation    | FAILURE          | Hierarchical DIF != standard bitrev           |
| 18  | DIT Natural Order Codelets  | SUCCESS +4%      | Loads bit-reversed, outputs natural           |
| 19  | SIMD Threshold N=64         | SUCCESS +8pp     | Lowered threshold from 128 to 64              |
| 20  | Dual-Complex r < 2          | SUCCESS +5-12pp  | Process r=2 stages with dual-complex SIMD     |
| 21  | Dual-Group r=1 Stage        | SUCCESS +11-20pp | Process 2 groups at once, massive improvement |
| 22  | Dispatch Order Optimization | INCONCLUSIVE     | Gap at N=64/128 within benchmark variance     |
| 23  | Unrolled RFFT-64 Post-Proc  | SUCCESS +3pp     | Inline twiddles, no loops, N=64 gap → -1.5%   |
| 24  | Derived Conjugate Twiddles  | INCONCLUSIVE     | XOR derivation vs v128.const, within variance |
| 25  | Unrolled RFFT-128 Post-Proc | SUCCESS +2-5pp   | Inline twiddles, N=128 now consistently +2-6% |
| 26  | Performance Analysis Final  | COMPLETE         | Beats fftw-js at all sizes, N=64 within noise |
| 27  | Dead Code Removal           | SUCCESS +6-10pp  | 43% smaller source, better I-cache at N=64    |
| 28  | Dead Parameterized Codelets | SUCCESS          | -218 lines, cleanup of $fft_16_at/$fft_32_at  |
| 29  | IFFT Implementation         | SUCCESS          | Full inverse FFT for all modules, 27/27 tests |

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

---

## Experiment 20: Dual-Complex Threshold r < 2 (2026-01-25)

**Result**: SUCCESS - +5pp at N=128, +7-12pp at larger sizes

Changed dual-complex processing threshold from `r < 4` to `r < 2` in fft_general. This allows the r=2 stage to use SIMD dual-complex processing (2 butterflies at once) instead of single-element processing.

For r=2 stages, each group has 2 elements per half, which is enough for dual-complex vectorization.

| Size   | Before | After  |
| ------ | ------ | ------ |
| N=128  | -17.3% | -12.1% |
| N=256  | +20.1% | +27.4% |
| N=512  | +2.9%  | +14.7% |
| N=1024 | -6.5%  | -2.5%  |
| N=2048 | -4.0%  | +7.7%  |
| N=4096 | -3.1%  | -0.7%  |

---

## Experiment 21: Dual-Group Processing for r=1 Stage (2026-01-25)

**Result**: MASSIVE SUCCESS - N=128 gap closed to -1%

For the r=1 stage (final stage of Stockham FFT), redesigned the loop to process 2 groups at once instead of 1. This leverages the contiguous memory layout where two groups' inputs span 4 consecutive complex numbers (32 bytes = 2 v128 loads).

Key insights:

- Input pairs for 2 consecutive groups are at addresses (i0, i0+8) and (i0+16, i0+24)
- Load both pairs with two v128.load operations
- Shuffle to separate first and second elements: [A, C] and [B, D]
- Load and combine twiddles for both groups
- Process both butterflies with dual-complex multiply

| Size   | Before | After  | Improvement |
| ------ | ------ | ------ | ----------- |
| N=64   | -6.7%  | -5.6%  | +1.1pp      |
| N=128  | -12.1% | -0.6%  | +11.5pp     |
| N=256  | +27.4% | +47.1% | +19.7pp     |
| N=512  | +14.7% | +28.9% | +14.2pp     |
| N=1024 | -2.5%  | +13.7% | +16.2pp     |
| N=2048 | +7.7%  | +18.7% | +11.0pp     |
| N=4096 | -0.7%  | +17.4% | +18.1pp     |

**Combined result**: wat-fft f32 now beats fftw-js at all sizes N≥256, and is within 6% at N=64/128.

---

## Experiment 22: Dispatch Order Optimization (2026-01-25)

**Hypothesis**: Reordering dispatch conditions in `$fft` to check N=32 first (most common for RFFT) would reduce branch overhead.

**Result**: INCONCLUSIVE - Within benchmark variance

Multiple runs showed N=64 gap ranging from -0.8% to -7.5%, and N=128 gap from -3% to +1.5%. The variance (±3-5pp) exceeds any potential gains from dispatch reordering.

**Approaches tested**:

1. Fast-path N=64 inline dispatch: No improvement
2. Reorder dispatch (N=32 first): No measurable change
3. Single-branch dispatch with nested ifs: Cleaner code, same performance

**Key insight**: At these small sizes, the actual FFT computation dominates. Dispatch overhead is negligible compared to:

- Memory access patterns in codelets
- SIMD shuffle operations
- Twiddle factor loading

**Conclusion**: The N=64/128 gap (~3-5%) is within measurement noise and likely represents the fundamental algorithmic difference between our Stockham implementation and FFTW's genfft codelets. Further optimization at these sizes would require significant codelet restructuring with uncertain returns.

---

## Experiment 23: Unrolled RFFT-64 Post-Processing (2026-01-25)

**Hypothesis**: Eliminating loop overhead and twiddle memory loads for N=64 RFFT post-processing by creating a fully unrolled codelet with inline v128.const twiddles.

**Approach**:

- Created `$rfft_postprocess_64` - a specialized function for n2=32 (N=64 RFFT)
- Fully unrolled all 7 SIMD iterations (processing pairs k=1..15)
- Replaced memory twiddle loads with `v128.const` inline constants
- Hardcoded all addresses (8, 24, 40, etc.)

**Result**: SUCCESS - N=64 gap reduced

| Metric    | Before | After | Improvement |
| --------- | ------ | ----- | ----------- |
| N=64 gap  | -4.7%  | -1.5% | +3.2pp      |
| N=128 gap | +0.1%  | +1.5% | +1.4pp      |

**Analysis**: The improvement is modest but consistent across multiple benchmark runs. The gains come from:

1. Zero loop counter overhead
2. Zero memory loads for twiddles (14 loads eliminated)
3. No branch prediction at loop boundaries
4. Compiler can better schedule instructions without loop constraints

**Lesson**: Even for small loops (7 iterations), full unrolling with inline constants can provide measurable gains. The approach is limited by code size - for larger N, the code bloat would hurt I-cache performance.

**Files modified**: `modules/fft_real_f32_dual.wat`

---

## Experiment 24: Derived Conjugate Twiddles (2026-01-25)

**Hypothesis**: In RFFT post-processing, `$wn2k_rot` twiddles differ from `$wk_rot` only by sign flip on the second f32 element of each pair. We can derive one from the other using XOR with `$CONJ_MASK_F32`, eliminating 7 `v128.const` instructions.

**Approach**:

- Replaced 7 occurrences of `(local.set $wn2k_rot (v128.const ...))`
- With `(local.set $wn2k_rot (v128.xor (local.get $wk_rot) (global.get $CONJ_MASK_F32)))`
- The mask `[0, 0x80000000, 0, 0x80000000]` flips the sign of indices 1 and 3

**Result**: INCONCLUSIVE - Within benchmark variance

| Metric    | Before | After (avg of 4 runs) |
| --------- | ------ | --------------------- |
| N=64 gap  | -2.7%  | -0.9% ± 3%            |
| N=128 gap | +1.3%  | +2.8% ± 1%            |

The results show slight improvement at N=64 but high variance (ranging from -3.2% to +6.2% across runs). The optimization:

1. Reduces code size by ~112 bytes (7 × 16-byte constants)
2. Replaces constant decode with XOR (1 cycle vs ~3 cycles for constant materialization)
3. Improves instruction cache utilization slightly

**Lesson**: At this optimization level, benchmark variance (~5pp) exceeds the gains from micro-optimizations. The N=64 gap vs fftw-js represents fundamental algorithmic differences, not inefficient code.

**Files modified**: `modules/fft_real_f32_dual.wat`

---

## Experiment 25: Unrolled RFFT-128 Post-Processing (2026-01-25)

**Hypothesis**: Following the success of Experiment 23 (unrolled RFFT-64 post-processing), create a fully unrolled `$rfft_postprocess_128` with inline twiddle constants to eliminate loop overhead and memory loads for N=128 RFFT.

**Approach**:

- Created `$rfft_postprocess_128` - a specialized function for n2=64 (N=128 RFFT)
- Fully unrolled all 15 SIMD pair iterations (processing pairs k=1..30 against k=63..34)
- Single pair handling for k=31 vs k=33
- Middle element handling for k=32
- Replaced all memory twiddle loads with `v128.const` inline constants
- Derived conjugate twiddles using XOR with $CONJ_MASK_F32 (7 fewer constants per pair block)

**Result**: SUCCESS - N=128 consistently beats fftw-js

| Metric    | Before (avg) | After (avg of 3 runs) | Improvement |
| --------- | ------------ | --------------------- | ----------- |
| N=64 gap  | +0.6%        | +0.4% to +4.6%        | stable      |
| N=128 gap | +0.4%        | +2.2% to +6.1%        | +2-5pp      |

**Analysis**: The N=128 unrolled codelet provides consistent improvement by:

1. Eliminating 30 loop iterations of overhead (counter updates, branch predictions)
2. Eliminating 30 memory loads for twiddle factors
3. Enabling better instruction scheduling without loop constraints
4. The derived conjugate twiddle pattern (XOR) keeps code size manageable

**Code size**: The new function adds ~500 lines of WAT but compiles to efficient SIMD code with inline constants.

**Lesson**: For sizes where the loop body dominates execution time, unrolling with inline constants provides consistent measurable gains. The approach scales well up to ~15 iterations; beyond that, I-cache pressure may become a concern.

**Files modified**: `modules/fft_real_f32_dual.wat`

---

## Experiment 26: Performance Analysis - Optimization Complete (2026-01-25)

**Goal**: Identify remaining optimization opportunities for f32 RFFT vs fftw-js.

**Benchmark Results** (2 runs):

| Size   | Run 1 vs fftw-js | Run 2 vs fftw-js |
| ------ | ---------------- | ---------------- |
| N=64   | -2.7%            | +1.7%            |
| N=128  | +9.0%            | +4.9%            |
| N=256  | +37.1%           | +49.2%           |
| N=512  | +27.6%           | +29.3%           |
| N=1024 | +13.5%           | +27.0%           |
| N=2048 | +15.8%           | +16.9%           |
| N=4096 | +11.2%           | N/A              |

**Analysis**:

1. **N=64 gap is within variance**: The -2.7% and +1.7% difference between runs (4.4pp swing) confirms Experiment 22's conclusion that the N=64 gap is measurement noise, not a real performance deficit.

2. **All sizes N≥128 consistently beat fftw-js**: Margins range from +4.9% to +49.2%.

3. **Optimization approaches considered and rejected**:
   - _Fused $rfft_64 codelet_: Would eliminate memory round-trip between FFT-32 and post-processing, but the non-contiguous access pattern (Z[k] vs Z[32-k]) would require complex shuffling that may not be faster than memory access. The FFT-32 stores t0-t15 contiguously, but post-processing needs pairs from opposite ends.
   - _Loop unrolling in $rfft_postprocess_simd_: Diminishing returns since we're already +27-49% at N≥256.

**Conclusion**: **Optimization is complete**. wat-fft f32 RFFT now matches or beats fftw-js at all sizes. The N=64 gap is within benchmark variance and not actionable. Future work should focus on new features rather than further optimization.

**Files modified**: `docs/OPTIMIZATION_PLAN.md` (updated performance tables)

---

## Experiment 27: Dead Code Removal (2026-01-25)

**Goal**: Remove unused legacy codelets to reduce module size and potentially improve I-cache utilization.

**Dead functions identified**:

1. `$fft_8` (DIF): Superseded by `$fft_8_dit`
2. `$fft_16` (DIF): Superseded by `$fft_16_dit`
3. `$fft_32` (DIF): Superseded by `$fft_32_dit`
4. `$fft_64` (hierarchical DIF): Unused, not called
5. `$fft_64_dit`: 1848 lines, too many locals causing register spills (never used)

**Result**: SUCCESS - Improved performance and maintainability

| Metric                 | Before | After     | Change   |
| ---------------------- | ------ | --------- | -------- |
| Source lines           | 5,748  | 3,299     | **-43%** |
| N=64 vs fftw-js (avg)  | ~-1%   | **+5-9%** | +6-10pp  |
| N=128 vs fftw-js (avg) | +2-5%  | **+5-7%** | +2pp     |
| All sizes              | Win    | **Win**   | stable   |

**Analysis**: Removing 2,449 lines of dead code had an unexpected positive side effect:

1. **Smaller WASM module**: Fewer functions = less code to parse/compile
2. **Better I-cache**: No wasted space for unused functions
3. **Cleaner codebase**: Easier to maintain and understand

The N=64 performance improvement (+6-10pp) suggests the dead code was causing some I-cache pressure at small sizes where the working set fits entirely in cache.

**Lesson**: Dead code removal is a legitimate optimization technique for WebAssembly. Large unused functions can impact performance even if never executed.

**Files modified**: `modules/fft_real_f32_dual.wat`

---

## Experiment 28: Dead Parameterized Codelet Removal (2026-01-25)

**Goal**: Remove remaining dead code (`$fft_16_at`, `$fft_32_at`) discovered during performance analysis.

**Dead functions identified**:

1. `$fft_16_at`: Parameterized N=16 codelet (operates at offset), ~105 lines
2. `$fft_32_at`: Parameterized N=32 codelet (calls $fft_16_at), ~110 lines

These were intended for building a hierarchical N=64 codelet but were never integrated after the DIT codelets proved more effective.

**Verification**: `grep "call \$fft_16_at"` and `grep "call \$fft_32_at"` confirmed neither function is called.

**Result**: SUCCESS - Minor cleanup, maintained performance

| Metric           | Before | After | Change       |
| ---------------- | ------ | ----- | ------------ |
| Source lines     | 3,299  | 3,081 | **-218**     |
| N=64 vs fftw-js  | +2-3%  | +2-4% | Within noise |
| N=128 vs fftw-js | +4-5%  | +5%   | Within noise |
| All other sizes  | Win    | Win   | Stable       |

**Benchmark Results** (2 runs after):

| Size   | Run 1  | Run 2  |
| ------ | ------ | ------ |
| N=64   | +2.3%  | +3.6%  |
| N=128  | +4.8%  | +5.1%  |
| N=256  | +46.4% | +48.2% |
| N=512  | +27.3% | +27.4% |
| N=1024 | +13.8% | +16.0% |
| N=2048 | +15.2% | +17.7% |
| N=4096 | +14.4% | +14.6% |

**Analysis**: This cleanup is more about code hygiene than performance. The 218 lines removed were truly dead code - never called and never executed. Unlike Experiment 27 which removed ~2,449 lines and showed measurable I-cache improvements, this smaller removal doesn't produce measurable performance changes but keeps the codebase clean.

**Lesson**: Regular dead code audits are valuable for maintenance. Use `grep` to verify function references before removal.

**Files modified**: `modules/fft_real_f32_dual.wat`

---

## Experiment 29: IFFT Implementation (2026-01-25)

**Goal**: Add inverse FFT functionality to all modules to enable full roundtrip signal processing.

**Approach**: IFFT(X) = (1/N) \* conj(FFT(conj(X)))

This uses the mathematical identity that the inverse DFT is equivalent to conjugating the input, applying the forward FFT, then conjugating and scaling the output.

**Implementation**:

1. **f64 Complex FFT** (`fft_combined.wat`):
   - Added `$CONJ_MASK` global for sign-flip of imaginary parts
   - Added `$conjugate_buffer`, `$scale_and_conjugate` helpers
   - Added specialized `$ifft_4` kernel using +j instead of -j twiddles
   - Exported `ifft(n)` function

2. **f32 Complex FFT** (`fft_stockham_f32_dual.wat`):
   - Same approach with f32x4 SIMD for dual-complex processing
   - Conjugate mask: `[0, 0x80000000, 0, 0x80000000]` (flip sign of both imag parts)

3. **f32 Real FFT** (`fft_real_f32_dual.wat`):
   - Added `$irfft_preprocess` to invert the RFFT post-processing step
   - Key formula: Z'[k] = 0.5 _ (X[k] + conj(X[n2-k]) + conj(W_rot) _ (X[k] - conj(X[n2-k])))
   - Special handling for DC (k=0) and middle element (k=n2/2)
   - Exported `irfft(n)` function

**Challenges Solved**:

1. **Middle element bug**: Forward RFFT at k=n2/2 gives X[k] = conj(Z'[k]) because W_rot = -1. The inverse is Z'[k] = conj(X[k]), not Z'[k] = 2\*X[k] as initially implemented.

2. **DC element packing**: The DC and Nyquist components are packed as (DC.re, Nyquist.re). Unpacking requires: Z[0] = (X[0].re + X[0].im)/2 + i\*(X[0].re - X[0].im)/2

**Result**: SUCCESS - All 27 tests pass

| Test Suite                    | Passed | Max Error (typical) |
| ----------------------------- | ------ | ------------------- |
| f64 Complex FFT->IFFT         | 9/9    | ~7e-11              |
| f32 Complex FFT->IFFT         | 9/9    | ~1e-6               |
| f32 Real RFFT->IRFFT          | 8/8    | ~1e-6               |
| Mathematical correctness test | 1/1    | 3e-11               |

**Performance**: Forward FFT performance unchanged. IFFT has same complexity as forward FFT plus O(N) conjugate operations.

**Files modified**:

- `modules/fft_combined.wat` - Added IFFT for f64 complex
- `modules/fft_stockham_f32_dual.wat` - Added IFFT for f32 complex
- `modules/fft_real_f32_dual.wat` - Added IRFFT for f32 real
- `tests/ifft.test.js` - New comprehensive test suite
