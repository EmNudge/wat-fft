# Optimization Experiment Log

Detailed record of all optimization experiments.

## Quick Reference

| #   | Experiment                   | Result           | Key Finding                                                           |
| --- | ---------------------------- | ---------------- | --------------------------------------------------------------------- |
| 1   | Dual-Complex f32 SIMD        | FAILURE -15-20%  | Branch overhead, twiddle replication hurt JIT                         |
| 2   | N=8 Codelet                  | FAILURE          | Stockham permutation semantics complex                                |
| 3   | Radix-4 Stockham SIMD        | SUCCESS +51%     | Fewer stages + inlined SIMD crucial                                   |
| 4   | N=16 Codelet                 | SUCCESS +54%     | Unrolled with inline twiddles                                         |
| 5   | Real FFT + Radix-4           | SUCCESS          | Tests pass, faster rfft                                               |
| 6   | Codelet Generator            | PARTIAL          | Correct but 320+ locals cause spills                                  |
| 7   | Inline SIMD cmul             | NO CHANGE        | V8 already inlines small functions                                    |
| 8   | Fused rfft Codelets          | SUCCESS +123%    | N=8, N=32 fused codelets                                              |
| 9   | Hierarchical FFT             | SUCCESS +30pp    | DIF composition, optimal at N=1024                                    |
| 10  | Depth-First DIF              | FAILURE -55%     | Call overhead > cache benefit                                         |
| 11  | SIMD Post-Processing         | SUCCESS +2-8pp   | v128 ops in rfft post-process                                         |
| 12  | Relaxed SIMD FMA             | SUCCESS +1-5%    | Modest gains, V8 optimizes well                                       |
| 13  | f32 Dual-Complex rfft        | SUCCESS +73%     | Combined with dual-complex FFT                                        |
| 14  | f32x4 SIMD Post-Process      | SUCCESS +13pp    | Process 2 pairs per iteration                                         |
| 15  | Fused FFT-64 Codelet         | SUCCESS +8%      | Eliminated 6 function calls                                           |
| 16  | f32 Small-N Codelets         | SUCCESS +50pp    | Fixed W_8^3 sign bug                                                  |
| 16b | f32 FFT-64 Codelet           | SUCCESS +45pp    | N=128 now +30% vs fftw-js                                             |
| 17  | Bit-Reversal Permutation     | FAILURE          | Hierarchical DIF != standard bitrev                                   |
| 18  | DIT Natural Order Codelets   | SUCCESS +4%      | Loads bit-reversed, outputs natural                                   |
| 19  | SIMD Threshold N=64          | SUCCESS +8pp     | Lowered threshold from 128 to 64                                      |
| 20  | Dual-Complex r < 2           | SUCCESS +5-12pp  | Process r=2 stages with dual-complex SIMD                             |
| 21  | Dual-Group r=1 Stage         | SUCCESS +11-20pp | Process 2 groups at once, massive improvement                         |
| 22  | Dispatch Order Optimization  | INCONCLUSIVE     | Gap at N=64/128 within benchmark variance                             |
| 23  | Unrolled RFFT-64 Post-Proc   | SUCCESS +3pp     | Inline twiddles, no loops, N=64 gap → -1.5%                           |
| 24  | Derived Conjugate Twiddles   | INCONCLUSIVE     | XOR derivation vs v128.const, within variance                         |
| 25  | Unrolled RFFT-128 Post-Proc  | SUCCESS +2-5pp   | Inline twiddles, N=128 now consistently +2-6%                         |
| 26  | Performance Analysis Final   | COMPLETE         | Beats fftw-js at all sizes, N=64 within noise                         |
| 27  | Dead Code Removal            | SUCCESS +6-10pp  | 43% smaller source, better I-cache at N=64                            |
| 28  | Dead Parameterized Codelets  | SUCCESS          | -218 lines, cleanup of $fft_16_at/$fft_32_at                          |
| 29  | IFFT Implementation          | SUCCESS          | Full inverse FFT for all modules, 27/27 tests                         |
| 30  | r=2 Stage Dual-Group         | SUCCESS +3-6pp   | Process 2 groups at once in r=2 stage                                 |
| 31  | f32 Complex FFT Dual-Group   | SUCCESS +30-40%  | Port RFFT optimizations to complex FFT module                         |
| 32  | f64 Complex FFT Dual-Group   | SUCCESS +7-10%   | Dual-group r=1/r=2 for f64 Stockham                                   |
| 33  | f64 RFFT Dual-Group          | FAILURE -10-12%  | Optimization harmful for smaller internal FFT                         |
| 34  | f32 Complex DIT Codelets     | PARTIAL          | N=8 DIT helps, N=16 DIT slower than Stockham                          |
| 35  | Loop Unrolling r>=4          | MIXED            | +2-5% at N>=512, -2% at N=64, reverted                                |
| 36  | Split Real/Imag Format       | RESEARCH         | pffft uses 4 complex/SIMD vs our 2, explains gap                      |
| 37  | Split Format Implementation  | FAILURE -65-75%  | Conversion overhead negates SIMD gains                                |
| 38  | f32 Complex FFT Benchmark    | SUCCESS          | True f32 vs f32 comparison: 85-91% of pffft                           |
| 39  | Native Split-Format FFT      | FAILURE 46-58%   | Same twiddle per group negates split format gain                      |
| 40  | Multi-Twiddle Split Stages   | SUCCESS 81-95%   | Deinterleave for 4 different twiddles per SIMD                        |
| 41  | Buffer Copy Unrolling        | INCONCLUSIVE     | Within variance, V8 handles simple loops well                         |
| 42  | Performance Analysis         | COMPLETE         | Optimization complete; beats all competitors                          |
| 43  | SIMD Split-Format IFFT       | SUCCESS          | 4x throughput for IFFT conjugation phases                             |
| 44  | f32 N=16 Radix-4 Codelet     | SUCCESS +18%     | Radix-4 codelet closes gap with f64                                   |
| 45  | Performance Gap Analysis     | COMPLETE         | Analysis only; optimization complete                                  |
| 46  | Dead Code Cleanup            | SUCCESS          | Removed unused fft_split_f32.wat (536 lines)                          |
| 47  | M5 Pro Re-Baseline           | COMPLETE         | New hardware: N=64 RFFT now loses to fftw-js                          |
| 48  | Eliminate copy_buffer        | SUCCESS +4.5-6%  | Postprocess reads ping-pong buffer directly                           |
| 49  | IFFT copy_buffer + bench     | SUCCESS +3-5%    | First IRFFT bench revealed losses at every size                       |
| 50  | SIMD IRFFT preprocess        | SUCCESS +18-24%  | Fused conjugate deleted a pass and a special case                     |
| 51  | Unrolled IRFFT preprocess    | PARTIAL +3%      | Unrolling pays off only where the time is                             |
| 52  | Native inverse FFT           | SUCCESS +5-8%    | Flipped sign mask = conjugated twiddles for free                      |
| 53  | Loop beats n=16/32 codelets  | SUCCESS +30-32%  | On M5, Stockham loop crushes DIT codelets; N=64 flips to +22% vs fftw |
| 54  | Complex-module codelet probe | NO CHANGE        | Radix-4 single-lane codelets still win on M5; keep them               |

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

---

## Experiment 30: r=2 Stage Dual-Group Optimization (2026-01-26)

**Goal**: Improve performance for N≥256 by optimizing the r=2 stage of the Stockham FFT.

**Hypothesis**: Following the success of Experiment 21 (r=1 stage dual-group processing), the r=2 stage can also benefit from processing 2 groups simultaneously. In the r=2 stage, each group has 2 elements in the first half and 2 in the second half, so processing 2 groups means handling 4 v128 loads and 4 butterflies per iteration.

**Approach**:

- Added specialized r=2 path in `$fft_general` that processes 2 groups at once
- For 2 groups: load 4 v128s (A, B for group j; C, D for group j+1)
- Apply twiddles and butterflies for both groups with less loop overhead
- Fall back to single-group processing if l (number of groups) is odd

**Result**: SUCCESS - +3 to +6pp at N≥256

| Size   | Before | After  | Improvement |
| ------ | ------ | ------ | ----------- |
| N=64   | -1.8%  | -1.8%  | stable      |
| N=128  | +6.4%  | +8.5%  | +2.1pp      |
| N=256  | +47.2% | +52.9% | **+5.7pp**  |
| N=512  | +27.1% | +33.0% | **+5.9pp**  |
| N=1024 | +15.8% | +18.6% | **+2.8pp**  |
| N=2048 | +16.4% | +21.8% | **+5.4pp**  |
| N=4096 | +14.7% | +17.8% | **+3.1pp**  |

**Analysis**: The r=2 stage optimization provides consistent improvements at larger sizes where there are more groups to process. The gains come from:

1. Reduced loop overhead (half the iterations)
2. Better instruction-level parallelism (more independent operations per iteration)
3. Amortized twiddle load cost over more butterflies

The improvement is most significant at N=256-512 where the r=2 stage represents a larger fraction of total work.

**Files modified**: `modules/fft_real_f32_dual.wat`

---

## Experiment 31: f32 Complex FFT Dual-Group Optimization (2026-01-26)

**Goal**: Port the r=1 and r=2 dual-group optimizations from `fft_real_f32_dual.wat` (Experiments 21, 30) to `fft_stockham_f32_dual.wat`.

**Hypothesis**: The f32 complex FFT module still uses single-element processing for r<4 stages, while the RFFT module has optimized dual-group processing. Applying the same optimization should yield significant gains.

**Approach**:

- Replaced the r<4 single-element processing loop with optimized r=1 and r=2 paths
- r=1 path: Process 2 groups at once, loading [A,B] and [C,D] pairs, shuffling to separate first/second elements, applying different twiddles to each group
- r=2 path: Process 2 groups (4 v128 loads), apply butterflies for both groups with interleaved twiddle loads

**Result**: SUCCESS - **+30% to +40% improvement** across all sizes

| Size   | Before | After | Improvement |
| ------ | ------ | ----- | ----------- |
| N=64   | 4.62M  | 6.18M | **+33.8%**  |
| N=256  | 1.17M  | 1.64M | **+40.2%**  |
| N=1024 | 274K   | 370K  | **+35.0%**  |
| N=2048 | 124K   | 161K  | **+30.0%**  |
| N=4096 | 61.1K  | 80.6K | **+31.9%**  |

**Analysis**: This is a much larger improvement than in the RFFT module because:

1. The complex FFT uses more r=1 and r=2 stages per transform (every stage for larger N)
2. The RFFT only calls the internal FFT once per transform, while complex FFT benchmarks measure the full algorithm
3. The dual-group optimization reduces loop overhead and improves instruction-level parallelism

**vs fft.js** (updated):

| Size   | vs fft.js Before | vs fft.js After |
| ------ | ---------------- | --------------- |
| N=64   | +65%             | **+119%**       |
| N=256  | +119%            | **+191%**       |
| N=1024 | +143%            | **+224%**       |
| N=2048 | +161%            | **+240%**       |
| N=4096 | +160%            | **+243%**       |

**Lesson**: Optimizations proven in one module should be systematically applied to related modules. The r=1/r=2 dual-group pattern is now a standard technique for Stockham FFT SIMD implementations.

**Files modified**: `modules/fft_stockham_f32_dual.wat`

---

## Experiment 32: f64 Complex FFT Dual-Group Optimization (2026-01-26)

**Goal**: Port the r=1 and r=2 dual-group optimizations from f32 modules to `fft_combined.wat`.

**Hypothesis**: The f64 Stockham FFT uses single-element processing for all stages, while f32 has optimized dual-group processing for r=1 and r=2 stages. Applying the same pattern to f64 should reduce loop overhead.

**Approach**:

- r=1 optimized path: Process 2 groups at once (4 v128 loads, 4 butterflies)
- r=2 optimized path: Process 2 groups (8 v128 loads, 4 butterflies per group)
- Fall back to single-group processing for odd group counts or r>=4

**Key difference from f32**: For f64, each v128 holds exactly 1 complex number (vs 2 for f32), so the optimization is about reducing loop iterations and amortizing overhead rather than SIMD packing efficiency.

**Result**: SUCCESS - +7-10% improvement at radix-2 sizes

| Size   | Before | After | Improvement |
| ------ | ------ | ----- | ----------- |
| N=32   | 6.05M  | 6.42M | **+6.1%**   |
| N=128  | 1.56M  | 1.70M | **+9.0%**   |
| N=512  | 338K   | 362K  | **+7.1%**   |
| N=2048 | 72.7K  | 77.4K | **+6.5%**   |

Note: These improvements apply to radix-2 sizes (N=8,32,128,512,2048). Radix-4 sizes (N=4,16,64,256,1024,4096) use a different algorithm and are unaffected.

**Analysis**: The gains are smaller than for f32 (7-10% vs 30-40%) because:

1. f64 has 1 complex per v128 vs 2 for f32, so the base efficiency is lower
2. The function call to `$simd_cmul` adds overhead that wasn't present in f32's inline multiply
3. Still, reducing loop iterations provides measurable improvement

**Files modified**: `modules/fft_combined.wat`

---

## Experiment 33: f64 RFFT Dual-Group Optimization (2026-01-26)

**Goal**: Port the r=1 and r=2 dual-group optimizations from Experiment 32 to the f64 RFFT module (`fft_real_combined.wat`).

**Hypothesis**: Since the f64 complex FFT (Experiment 32) showed +7-10% gains with dual-group processing, the same optimization applied to the Stockham FFT used internally by the f64 RFFT should provide similar benefits.

**Approach**:

- Same r=1 and r=2 optimized paths as Experiment 32
- Applied to `$fft_stockham_general` in `fft_real_combined.wat`

**Result**: FAILURE - 10-12% slower at all sizes

| Size   | Before | After  | Change     |
| ------ | ------ | ------ | ---------- |
| N=64   | 4.74M  | 4.19M  | **-11.6%** |
| N=256  | 1.25M  | 1.11M  | **-11.2%** |
| N=1024 | 284.7K | 254.6K | **-10.6%** |
| N=4096 | 62.7K  | 54.8K  | **-12.6%** |

**Analysis**: The optimization that worked for the complex FFT module hurts the RFFT module because:

1. **Smaller internal FFT**: RFFT operates on N/2 complex numbers internally. For N=64 RFFT, the internal FFT is only 32 points, meaning fewer stages and fewer opportunities for the optimization to pay off.

2. **Higher relative overhead**: The conditional checks (`if r=1`, `if r=2`) add overhead that dominates at smaller sizes. For the complex FFT benchmark which tests larger sizes directly (N=64, 256, 1024...), the overhead is amortized over more work.

3. **JIT optimization disruption**: The additional branching may interfere with V8's ability to optimize the hot path. The original simple loop structure is more predictable for the JIT compiler.

**Key insight**: Optimizations that work for one module don't necessarily transfer to similar code. The internal FFT size and call patterns significantly affect what optimizations are beneficial.

**Decision**: Reverted changes to `fft_real_combined.wat`. The module's performance is already acceptable (2x faster than kissfft-js at all sizes).

**Files modified**: None (changes reverted)

---

## Experiment 34: f32 Complex FFT DIT Codelets (2026-01-26)

**Goal**: Port DIT codelets from the f32 RFFT module to the f32 complex FFT module to improve small-N performance.

**Hypothesis**: The f32 complex FFT module (`fft_stockham_f32_dual.wat`) only has a specialized kernel for N=4 and uses `$fft_general` for all larger sizes. The RFFT module has specialized DIT codelets for N=8, 16, and 32 that eliminate loop overhead. Adding these to the complex FFT should improve small-N performance.

**Approach**:

- Ported `$fft_8_dit` codelet (110 lines) from `fft_real_f32_dual.wat`
- Ported `$fft_16_dit` codelet (515 lines) from `fft_real_f32_dual.wat`
- Added dispatch in `fft` export function

**Results**:

| Size | General Stockham | With $fft_8_dit | With $fft_16_dit |
| ---- | ---------------- | --------------- | ---------------- |
| N=4  | 31.4M ops/s      | 31.4M           | 31.2M            |
| N=8  | (uses N=4×2)     | **29.5M**       | 29.5M            |
| N=16 | 17.8M ops/s      | 17.8M           | **15.4M (-13%)** |

**Analysis**:

1. **N=8 DIT codelet works well**: Achieves 29.5M ops/s, comparable to N=4 (31.4M). The DIT approach eliminates loop overhead effectively for this size.

2. **N=16 DIT codelet is slower**: The complex shuffling and reorganization in the N=16 DIT codelet actually hurt performance (-13% vs general Stockham). This differs from the RFFT module where the same codelet works well.

3. **Root cause**: The general Stockham algorithm in `fft_stockham_f32_dual.wat` is already highly optimized with dual-group processing for r=1 and r=2 stages. The DIT codelet's shuffle-heavy approach can't beat the well-pipelined iterative algorithm for N>=16.

**Decision**:

- Keep `$fft_8_dit` enabled (provides ~10% improvement at N=8)
- Keep `$fft_16_dit` in code but disabled (preserved for reference)
- Did not port `$fft_32_dit` (750 lines, unlikely to help)

**Lesson**: DIT codelets with bit-reversed input are most effective for very small sizes (N<=8) where loop overhead dominates. For larger sizes, the iterative Stockham algorithm with SIMD optimizations is more efficient.

**Files modified**: `modules/fft_stockham_f32_dual.wat`

---

## Experiment 35: Loop Unrolling for r>=4 Stages (2026-01-26)

**Goal**: Reduce loop overhead in `$fft_general` for r>=4 stages by processing 4 complex numbers per iteration instead of 2.

**Hypothesis**: The inner loop processes 2 complex numbers per iteration (one v128 load from each half). Unrolling to process 4 complex numbers (2 v128 loads from each half) would reduce loop overhead and potentially allow better instruction pipelining.

**Approach**:

- Added unrolled path for r>=8 that processes 2 iterations per loop cycle
- Falls back to single-iteration loop for remaining elements and r<8

**Result**: MIXED - Helps large N, hurts small N

| Size   | Before | After | Change |
| ------ | ------ | ----- | ------ |
| N=64   | 6.24M  | 6.10M | -2.2%  |
| N=128  | 3.00M  | 3.06M | +2.0%  |
| N=256  | 1.63M  | 1.62M | -0.6%  |
| N=512  | 734K   | 749K  | +2.0%  |
| N=1024 | 366K   | 380K  | +3.8%  |
| N=2048 | 160K   | 164K  | +2.5%  |
| N=4096 | 79.5K  | 83.9K | +5.5%  |

**Analysis**: The unrolling helps at larger sizes (+2-5% at N>=512) where the r>=8 path is exercised more often. However, the additional branch check hurts small sizes (-2% at N=64) where the extra conditional overhead isn't amortized.

**Decision**: Reverted. The optimization isn't a clear win - improving large N at the cost of small N performance isn't acceptable when we're already competitive at all sizes.

**Lesson**: Loop unrolling in WASM requires careful benchmarking across all sizes. V8's optimizer handles simple loops well, so unrolling only helps when it enables instruction-level parallelism that wasn't already available.

**Files modified**: None (changes reverted)

---

## Experiment 36: Split Real/Imaginary Format Analysis (2026-01-26)

**Goal**: Understand why pffft-wasm is 5-14% faster and explore adopting their approach.

**Research Findings**:

Examined pffft-wasm source code (`node_modules/@echogarden/pffft-wasm/src/pffft.c`) and decompiled WASM.

**Key Difference: Data Layout**

pffft uses "split" format (Structure of Arrays):

- Real parts: `[re0, re1, re2, re3]` in one v128
- Imag parts: `[im0, im1, im2, im3]` in another v128
- Processes **4 complex numbers per SIMD operation**

Our approach uses "interleaved" format (Array of Structures):

- Dual-complex: `[re0, im0, re1, im1]` in one v128
- Processes **2 complex numbers per SIMD operation**

**Complex Multiply Comparison**:

```c
// pffft (split format, 4 complex):
tmp = ar * bi;           // 1 mul
ar = ar * br - ai * bi;  // 2 mul + 1 sub
ai = ai * br + tmp;      // 1 mul + 1 add
// Total: 4 muls + 1 add + 1 sub = 6 ops for 4 complex = 1.5 ops/complex
```

```wat
;; wat-fft (interleaved, 2 complex):
prod1 = x1 * wr              ;; 1 mul
swapped = shuffle(x1)         ;; 1 shuffle
x1 = prod1 + swapped*wi*sign  ;; 2 mul + 1 add
;; Total: 3 muls + 1 add + 1 shuffle = 5 ops for 2 complex = 2.5 ops/complex
```

**Split format is ~67% more efficient per complex multiply**, explaining the 5-14% gap.

---

## Experiment 37: Split Format Implementation (2026-01-26)

**Goal**: Implement split real/imaginary format FFT to match pffft's performance.

**Approach**:

Implemented complete split-format FFT in `modules/fft_split_f32.wat` using Cooley-Tukey DIT:

1. Convert interleaved input to split format with bit-reversal
2. Run iterative DIT FFT stages in split format
3. SIMD path for butterfly size m >= 4 (4 complex/op)
4. Scalar fallback for m < 4 stages
5. Convert back to interleaved for output

**Correctness**: Achieved - max error < 2.2e-5 at N=4096 vs fft.js reference.

**Performance Result**: FAILURE - 3-4x SLOWER than current implementation

| Size   | Split FFT | Dual-Complex | pffft-wasm | Split vs Dual |
| ------ | --------- | ------------ | ---------- | ------------- |
| N=64   | 2.00M     | 5.79M        | 7.07M      | -65%          |
| N=128  | 948K      | 3.06M        | 3.51M      | -69%          |
| N=256  | 451K      | 1.65M        | 1.88M      | -73%          |
| N=512  | 209K      | 738K         | 838K       | -72%          |
| N=1024 | 97K       | 375K         | 416K       | -74%          |
| N=2048 | 45K       | 167K         | 178K       | -73%          |
| N=4096 | 21K       | 82K          | 88K        | -75%          |

**Root Cause Analysis**:

The conversion overhead dominates:

1. **Bit-reversal**: O(N) function calls for `$bit_reverse` per-element
2. **Interleaved→Split**: O(N) scalar loads/stores
3. **Split→Interleaved**: O(N) scalar loads/stores
4. **Twiddle gather**: Non-consecutive strides require 8 scalar loads for 4 twiddles

pffft avoids this because it:

- Keeps data in split format internally throughout
- Only converts at the very edges of the API
- Uses specialized codelets that work directly with split data

**Key Insight**: Split format is only beneficial when you can keep data in that format throughout a pipeline. For APIs requiring interleaved input/output, the conversion overhead negates any SIMD efficiency gains.

**Lesson**: Format conversion overhead is substantial. Optimizing the algorithm inside the hot loop doesn't help if the boundary conversion is O(N). Our dual-complex interleaved approach is actually better for the interleaved API contract.

**Decision**: Abandon split format approach. Keep existing dual-complex Stockham implementation which achieves 82-94% of pffft performance without format conversion overhead.

**Files**:

- `modules/fft_split_f32.wat` - Completed implementation (archived as reference)
- `tests/fft_split_f32_debug.test.js` - Debug test (passes)
- `benchmarks/fft_split_f32.bench.js` - Performance benchmark

---

## Experiment 38: f32 Complex FFT Benchmark (2026-01-26)

**Goal**: Add f32 complex FFT to the main benchmark for fair f32-vs-f32 comparison against pffft-wasm.

**Problem**: The existing benchmark compared our f64 complex FFT against pffft-wasm's f32 FFT - an unfair comparison that made us look 50% slower. Our f32 module (`fft_stockham_f32_dual.wasm`) existed but wasn't benchmarked.

**Approach**:

- Added `loadWasmFFTf32()` to load the f32 complex FFT module
- Added `wat-fft (f32)` benchmark entry in `fft.bench.js`
- Updated notes section to clarify both implementations

**Result**: SUCCESS - True performance revealed

| Size   | wat-fft (f32) | pffft-wasm (f32) | vs pffft-wasm |
| ------ | ------------- | ---------------- | ------------- |
| N=16   | 14.1M         | 16.3M            | 87%           |
| N=32   | 9.4M          | 10.7M            | 88%           |
| N=64   | 6.1M          | 7.2M             | 85%           |
| N=128  | 3.1M          | 3.6M             | 87%           |
| N=256  | 1.7M          | 1.9M             | 86%           |
| N=512  | 742K          | 843K             | 88%           |
| N=1024 | 369K          | 422K             | 87%           |
| N=2048 | 164K          | 181K             | 91%           |
| N=4096 | 81K           | 89K              | 91%           |

**Analysis**:

The f32 comparison shows we're at **85-91% of pffft-wasm's performance**, not the 44-54% the f64 comparison suggested. This is a much more competitive position.

The remaining gap (~10-15%) is explained by Experiment 36/37's analysis: pffft uses split real/imaginary format internally which allows processing 4 complex numbers per SIMD operation vs our 2. Without changing our API contract (interleaved format), we cannot close this gap.

**Key finding**: Our f32 complex FFT is already highly competitive. The 10-15% gap vs pffft is fundamental due to format differences - not a code quality issue.

**Files modified**: `benchmarks/fft.bench.js`

---

## Experiment 39: Native Split-Format FFT (2026-01-26)

**Goal**: Create a native split-format FFT API that eliminates format conversion overhead from Experiment 37.

**Hypothesis**: Experiment 37 failed because it converted interleaved→split→interleaved on every call. A native API that accepts split-format input and returns split-format output should eliminate this overhead and close the gap with pffft-wasm.

**Approach**:

Created new module `modules/fft_split_native_f32.wat`:

1. Memory layout with separate real/imag buffers (no conversion needed)
2. Stockham algorithm adapted for split format
3. SIMD stage function processing 4 elements per iteration
4. Taylor series sin/cos with range reduction for twiddle computation
5. API: `precompute_twiddles_split(N)`, `fft_split(N)`, `ifft_split(N)`

**Correctness**: SUCCESS - All 22 tests pass with max error < 1e-4

**Performance Result**: FAILURE - 46-58% of pffft-wasm (SLOWER than interleaved!)

| Size   | Split Native | Interleaved f32 | pffft-wasm | Split vs pffft |
| ------ | ------------ | --------------- | ---------- | -------------- |
| N=64   | 3.4M         | 6.0M            | 7.1M       | 48%            |
| N=128  | 1.6M         | 3.1M            | 3.5M       | 46%            |
| N=256  | 932K         | 1.6M            | 1.9M       | 49%            |
| N=512  | 406K         | 733K            | 826K       | 49%            |
| N=1024 | 224K         | 366K            | 413K       | 54%            |
| N=2048 | 98K          | 157K            | 174K       | 56%            |
| N=4096 | 51K          | 79K             | 88K        | 58%            |

**Root Cause Analysis**:

The SIMD implementation only processes 4 elements _with the same twiddle_:

```wat
;; Current approach: splat same twiddle to all 4 lanes
(local.set $w_re (f32x4.splat (f32.load (local.get $tw_re_addr))))
;; All 4 elements use the SAME twiddle
```

This is because in Stockham, elements within the same group share the same twiddle:

- For group j: all k=0..r-1 use twiddle W^(j \* tw_step)

pffft's approach uses 4 _different_ twiddles per SIMD operation by restructuring the algorithm so that 4 consecutive elements have 4 different twiddles. This requires a fundamentally different FFT structure (likely radix-4 at base with special data organization).

**Key Insight**: Split format is necessary but not sufficient. The algorithm must be co-designed with the data layout to use 4 different twiddles per SIMD operation. Our Stockham algorithm naturally groups elements that share twiddles, which doesn't benefit from 4-wide SIMD on twiddle multiplies.

**Comparison of approaches**:

| Approach                 | Twiddles per SIMD op    | Performance vs pffft |
| ------------------------ | ----------------------- | -------------------- |
| Our interleaved Stockham | 1 (splatted to 2 lanes) | 85-91%               |
| Our split Stockham       | 1 (splatted to 4 lanes) | 46-58%               |
| pffft split              | 4 different             | 100% (baseline)      |

The extra overhead in split format (separate load/store for real and imag) isn't compensated by any efficiency gain since we still use only 1 unique twiddle per SIMD operation.

**Conclusion**: Closing the 10-15% gap with pffft requires fundamental algorithm restructuring, not just data format changes. The current interleaved dual-complex approach (85-91%) is optimal for Stockham-based FFT.

**Files created**:

- `modules/fft_split_native_f32.wat` - Complete native split FFT implementation
- `tests/fft_split_native.test.js` - Test suite (22/22 passing)
- `tests/debug_split.js` - Debug comparison tool

**Files modified**:

- `build.js` - Added split-format module to build
- `benchmarks/fft.bench.js` - Added split-format benchmark

---

## Experiment 40: Multi-Twiddle Split Stages (2026-01-26)

**Goal**: Restructure the split-format FFT to use 4 different twiddles per SIMD operation, matching pffft's approach.

**Key Insight from Experiment 39**: The failure was NOT due to split format itself, but because we were splatting the same twiddle to all 4 SIMD lanes. The algorithm structure must be changed to use 4 different twiddles per operation.

**The Breakthrough**: For r=1 stage, consecutive input pairs (a,b) use consecutive twiddles!

```
Input layout: [a0,b0,a1,b1,a2,b2,a3,b3,...]
Twiddles:     W^0, W^1, W^2, W^3, ...  (consecutive!)
```

By loading 8 floats and deinterleaving with `i8x16.shuffle`:

- a_re = [a0, a1, a2, a3] (from even positions)
- b_re = [b0, b1, b2, b3] (from odd positions)
- Load 4 consecutive twiddles: W^0, W^1, W^2, W^3
- Complex multiply with 4 DIFFERENT twiddles - TRUE 4-wide SIMD!

**Implementation**:

1. **Specialized r=1 stage** (`$fft_stage_r1_simd`):
   - Deinterleave consecutive pairs to get 4 a's and 4 b's
   - Load 4 consecutive twiddles
   - Apply 4 different twiddles per SIMD operation
   - Store consecutive outputs to each half

2. **Specialized r=2 stage** (`$fft_stage_r2_simd`):
   - Process 2 groups at once (4 elements total)
   - 2 different twiddles, each used twice
   - Partial benefit from multi-twiddle SIMD

3. **Generic r>=4 stage** (unchanged):
   - Same twiddle per group (splat approach)
   - Still needed for early stages

**Result**: SUCCESS - Massive performance improvement!

| Size   | Before (Exp 39) | After (Exp 40) | Improvement |
| ------ | --------------- | -------------- | ----------- |
| N=64   | 48% of pffft    | **81.5%**      | +34pp       |
| N=256  | 49%             | **87.3%**      | +38pp       |
| N=1024 | 54%             | **90.6%**      | +37pp       |
| N=4096 | 58%             | **94.9%**      | +37pp       |

**Comparison with interleaved f32**:

| Size   | Split (Exp 40) | Interleaved f32 | Winner      |
| ------ | -------------- | --------------- | ----------- |
| N=64   | 81.5%          | 84.3%           | Interleaved |
| N=256  | 87.3%          | 85.7%           | **Split**   |
| N=512  | 80.4%          | 89.0%           | Interleaved |
| N=1024 | 90.6%          | 88.0%           | **Split**   |
| N=4096 | 94.9%          | 90.8%           | **Split**   |

At N>=256 (non-radix-4 sizes excluded), split-format now beats interleaved!

**Why It Works**:

The r=1 and r=2 stages dominate the operation count for larger N:

- For N=1024: r=1 processes N/2=512 butterflies, r=2 processes N/4=256
- These two stages alone account for 75% of total butterflies
- Optimizing them with true multi-twiddle SIMD has outsized impact

**Key Code - Deinterleave for r=1**:

```wat
;; Load [a0,b0,a1,b1,a2,b2,a3,b3]
(local.set $v0 (v128.load ...))
(local.set $v1 (v128.load ...))

;; Deinterleave: a = [a0,a1,a2,a3], b = [b0,b1,b2,b3]
(local.set $a_re (i8x16.shuffle 0 1 2 3 8 9 10 11 16 17 18 19 24 25 26 27
  (local.get $v0) (local.get $v1)))
(local.set $b_re (i8x16.shuffle 4 5 6 7 12 13 14 15 20 21 22 23 28 29 30 31
  (local.get $v0) (local.get $v1)))

;; Load 4 CONSECUTIVE twiddles
(local.set $w_re (v128.load (i32.add (global.get $TWIDDLE_RE_OFFSET) ...)))

;; Complex multiply with 4 DIFFERENT twiddles!
```

**Remaining Gap Analysis**:

At N=4096, we're now at 94.9% of pffft. The remaining 5% is likely due to:

1. pffft's radix-4 base (fewer stages overall)
2. pffft's specialized codelets for small N
3. Our r>=4 stages still use splat (same twiddle)

**Files modified**:

- `modules/fft_split_native_f32.wat` - Added specialized r=1 and r=2 stages

---

## Experiment 41: Buffer Copy Unrolling (2026-01-26)

**Goal**: Reduce loop overhead in `$copy_buffer` by processing 64 bytes (4 v128) per iteration instead of 16.

**Hypothesis**: The buffer copy function is called when FFT results end up in the secondary buffer (after odd number of stages). Unrolling from 1 to 4 loads/stores per iteration should reduce loop overhead, especially at larger N where more bytes are copied.

**Approach**:

- Modified `$copy_buffer` in both `fft_stockham_f32_dual.wat` and `fft_real_f32_dual.wat`
- Added 4x unrolled loop processing 64 bytes per iteration
- Fallback loop handles remaining 0-48 bytes

**Result**: INCONCLUSIVE - Within benchmark variance

| Size   | Before | After  | Change |
| ------ | ------ | ------ | ------ |
| N=64   | +1.2%  | -2.1%  | -3.3pp |
| N=128  | +8.4%  | +11.1% | +2.7pp |
| N=4096 | +22.3% | +20.9% | -1.4pp |

**Analysis**: The optimization showed mixed results within benchmark variance (~3-5pp). This is consistent with Experiment 35's findings:

1. V8's JIT already optimizes simple loops effectively
2. Unrolling adds code complexity and I-cache pressure
3. The copy operation is O(N) vs O(N log N) for FFT, making it a small fraction of total time
4. At small N, the extra conditional overhead hurts; at large N, gains are marginal

**Decision**: Reverted changes. The simple loop is optimal for this use case.

**Lesson**: Buffer copy is not a bottleneck. Focus optimization efforts on the FFT stages themselves.

**Files modified**: None (changes reverted)

---

## Experiment 42: Performance Analysis Session (2026-01-28)

**Goal**: Systematic analysis of remaining optimization opportunities after 41 experiments.

**Benchmark Results**:

| Module      | Size   | ops/sec | vs Competitor                   |
| ----------- | ------ | ------- | ------------------------------- |
| f32 RFFT    | N=64   | 6.92M   | -0.9% vs fftw-js (within noise) |
| f32 RFFT    | N=128  | 4.77M   | **+8.3%** vs fftw-js            |
| f32 RFFT    | N=256  | 2.33M   | **+54.9%** vs fftw-js           |
| f32 Complex | N=64   | 6.09M   | **+31%** vs pffft-wasm          |
| f32 Complex | N=256  | 1.68M   | **+64%** vs pffft-wasm          |
| f32 Complex | N=1024 | 376K    | **+83%** vs pffft-wasm          |

**Opportunities Analyzed**:

1. **Precomputed twiddle address delta** - Computing `tw_step * 16` once per stage instead of per-iteration
   - Status: NOT IMPLEMENTED
   - Reason: Experiment 35 showed similar micro-optimizations hurt N=64 by -2%; V8 JIT already optimizes constant expressions well
   - Expected gain: <0.5%, with regression risk

2. **Multi-twiddle r>=4 for split-format** - Using 4 different twiddles per SIMD in r>=4 stages
   - Status: NOT FEASIBLE
   - Reason: In Stockham, consecutive elements within a group share the same twiddle by design; would require fundamental algorithm restructuring (radix-4 base like pffft)

3. **Taylor series coefficient folding** - Replace `f32.div(x2, -6.0)` with `f32.mul(x2, -0.166667)`
   - Status: NOT IMPLEMENTED
   - Reason: Only affects precompute phase (called once), not hot path

4. **N=64 RFFT gap** - Currently -0.9% to -2% vs fftw-js
   - Status: CONFIRMED AS BENCHMARK VARIANCE
   - Evidence: Multiple runs show range from -2.7% to +5% (Experiments 22-26)
   - Conclusion: Not a real performance deficit

**Conclusion**: **Optimization is complete for current architecture.**

The codebase achieves:

- **+31% to +90%** vs pffft-wasm (complex FFT)
- **+8% to +55%** vs fftw-js at N≥128 (real FFT)
- **~tied** at N=64 (within benchmark variance)

Further gains would require:

1. Fundamental algorithm changes (radix-4 base structure like pffft)
2. New features (batched FFT, streaming, larger N, non-power-of-2)

**Files modified**: None (analysis only)

---

## Experiment 43: SIMD-Accelerated Split-Format IFFT (2026-01-28)

**Goal**: Improve IFFT performance in the split-format module by using SIMD for conjugation operations.

**Observation**: The split-format module's `ifft_split` function used scalar `f32.neg` and `f32.mul` operations, processing one element at a time. The interleaved modules use `v128.xor` for conjugation, processing 4 elements per iteration.

**Approach**:

- Replaced scalar conjugation loop with `f32x4.neg` (4 elements per iteration)
- Replaced scalar scale loop with `f32x4.mul` and `f32x4.splat` for scaling
- Changed loop increment from 4 bytes to 16 bytes per iteration

**Changes**:

```wat
;; Before (scalar):
(f32.store (local.get $addr) (f32.neg (f32.load (local.get $addr))))
(local.set $i (i32.add (local.get $i) (i32.const 4)))

;; After (SIMD):
(v128.store (local.get $addr) (f32x4.neg (v128.load (local.get $addr))))
(local.set $i (i32.add (local.get $i) (i32.const 16)))
```

**Result**: SUCCESS - Code quality improvement

- All 22 split-format tests pass
- IFFT roundtrip errors unchanged (max ~1.5e-6)
- Forward FFT performance unaffected

**Analysis**: This is a code quality improvement that aligns the split-format module with the SIMD practices used in the interleaved modules. The IFFT is not benchmarked, but the change improves code consistency and theoretical IFFT throughput by 4x for the conjugation phases.

**Lesson**: Consistency across modules makes the codebase easier to maintain. SIMD patterns that work in one module should be applied systematically.

**Files modified**: `modules/fft_split_native_f32.wat`

---

## Experiment 44: f32 N=16 Radix-4 Codelet (2026-01-28)

**Goal**: Improve f32 complex FFT performance at N=16, which underperformed f64.

**Observation**: The f32 complex FFT at N=16 (14.1M ops/s) was 20% slower than f64 (17.6M ops/s). This is counterintuitive since f32 should be faster due to 2x SIMD throughput. The f32 module fell through to `$fft_general` for N=16, while f64 had a specialized `$fft_16` radix-4 codelet.

**Hypothesis**: A radix-4 N=16 codelet for f32 would eliminate loop overhead and match f64 performance.

**Approach**:

- Port the f64 `$fft_16` radix-4 algorithm to f32
- Use single-complex-per-lane (like f64) rather than dual-complex packing
- 2 stages instead of 4 for radix-2 Stockham
- Hardcoded twiddle factors (W_16^k for k=1,2,3,4,6,9)
- Update dispatch in both `fft` and `ifft` paths (via shared `$fft_dispatch`)

**Result**: SUCCESS - +18% improvement at N=16

| Metric        | Before     | After      | Change |
| ------------- | ---------- | ---------- | ------ |
| f32 N=16      | 14.1M op/s | 16.7M op/s | +18%   |
| Gap vs f64    | 20% slower | 5% slower  | +15pp  |
| vs pffft-wasm | +0%        | +20%       | +20pp  |
| vs fft.js     | +22%       | +45%       | +23pp  |

**Analysis**:

The radix-4 algorithm reduces N=16 from 4 stages (radix-2) to 2 stages. Key benefits:

1. **Fewer iterations**: 2 stages × 4 groups vs 4 stages × varying groups
2. **No loop overhead**: Fully unrolled butterflies
3. **Inline twiddles**: `v128.const` eliminates memory loads
4. **Better register usage**: 20 locals vs dynamic allocation in general loop

The f32 codelet uses the same single-complex-per-lane approach as f64. Dual-complex packing was attempted but the complex shuffling required for radix-4 negated the benefits (similar to Experiment 34's N=16 DIT finding).

**Key implementation detail**: The IFFT was initially broken because it called `$fft_general` directly instead of going through dispatch. Fixed by creating a shared `$fft_dispatch` function used by both `fft` export and `ifft`.

**Lesson**: When f32 underperforms f64 at a specific size, check if f64 has a specialized codelet that f32 lacks. Direct algorithm ports often work well.

**Files modified**: `modules/fft_stockham_f32_dual.wat`

---

## Experiment 45: Performance Gap Analysis (2026-01-28)

**Goal**: Systematic analysis of remaining optimization opportunities after 44 experiments.

**Benchmark Results** (fresh run):

f32 RFFT vs fftw-js:
| Size | wat-fft | fftw-js | Difference |
|--------|-------------|-------------|-------------|
| N=64 | 6,899,289 | 6,896,359 | **tied** |
| N=128 | 4,777,760 | 4,361,914 | **+9.5%** |
| N=256 | 2,320,659 | 1,526,977 | **+52.0%** |
| N=512 | 1,217,055 | 916,632 | **+32.8%** |
| N=1024 | 556,221 | 472,571 | **+17.7%** |
| N=2048 | 280,109 | 231,264 | **+21.1%** |
| N=4096 | 127,372 | 107,567 | **+18.4%** |

f32 Complex FFT vs pffft-wasm:
| Size | wat-fft f32 | pffft-wasm | Speedup |
|--------|--------------|-------------|-----------|
| N=16 | 16,787,814 | 14,108,078 | **+19%** |
| N=32 | 9,208,039 | 7,733,461 | **+19%** |
| N=64 | 6,024,070 | 4,560,912 | **+32%** |
| N=256 | 1,642,827 | 1,011,889 | **+62%** |
| N=1024 | 369,381 | 203,193 | **+82%** |
| N=4096 | 80,678 | 42,567 | **+90%** |

**Analysis**:

1. **wat-fft beats all competitors at all sizes** - no significant gaps remain

2. **N=16 f32 vs f64 gap (5%)**: The f32 N=16 codelet (16.8M ops/s) is 5% slower than f64 (17.6M ops/s). Root cause: f32 uses `v128.load64_zero` wasting 50% of SIMD capacity, but radix-4 data dependencies prevent dual-complex packing. Fixing this would require algorithm restructuring with uncertain returns.

3. **N=32 optimization potential**: Micro-benchmarks show N=32 (16M ops/s) drops 2.9x from N=16 (46M ops/s), steeper than theoretical O(N log N). An N=32 codelet could help, but:
   - N=32 is not a power of 4, requiring mixed-radix approach
   - The `$fft_32_dit` in RFFT module uses 68 locals (risk of register spills)
   - Experiment 34 found DIT codelets slower than Stockham for complex FFT

4. **N=64 optimization**: Power of 4, but would require 64+ locals (high spill risk per Experiment 6)

**Opportunities Considered and Rejected**:

1. **N=32 radix-8 codelet**: Complex implementation, 32 = 8 × 4 requires hybrid approach
2. **Hierarchical N=32 (call N=16 twice)**: Experiment 10 showed function call overhead hurts
3. **Global constant hoisting**: `v128.const` patterns repeated 8-12 times, but JIT likely optimizes
4. **Port `$fft_32_dit` from RFFT**: Experiment 34 found DIT approach slower for complex FFT

**Conclusion**: **Optimization is complete for current architecture.**

The codebase is highly optimized after 44 experiments. Remaining opportunities have:

- High implementation complexity
- Uncertain performance returns
- Risk of regressions at other sizes

Future improvements would require:

1. Fundamental algorithm changes (split-radix, different radix patterns)
2. Architecture-specific tuning (different strategies for different CPUs)
3. New features (batched FFT, streaming, larger N)

**Files modified**: None (analysis only)

---

## Experiment 46: Dead Code Cleanup (2026-01-28)

**Goal**: Remove unused `fft_split_f32.wat` module discovered during performance analysis.

**Background**: The `fft_split_f32.wat` module (536 lines) was created in Experiment 37 as an initial split-format implementation, but was superseded by `fft_split_native_f32.wat` in Experiment 39. The old module:

- Was NOT included in build.js (not compiled)
- Had no test coverage in the main test suite
- Was only referenced by debug tools and benchmarks
- Used incorrect memory offsets (different from the native split module)

**Files removed**:

- `modules/fft_split_f32.wat` - 536 lines of dead code
- `tools/fft_split_f32_debug.js` - Associated debug tool
- `benchmarks/fft_split_f32.bench.js` - Associated benchmark

**Files updated**:

- `benchmarks/fft_kernel_only.bench.js` - Updated to use `fft_split_native_f32` instead
- `package.json` - Updated debug:split script
- `tools/README.md` - Removed reference to deleted tool

**Result**: SUCCESS - Cleaner codebase, no production impact

| Metric             | Before   | After    |
| ------------------ | -------- | -------- |
| modules/ total WAT | 7,610    | 7,074    |
| Dead source files  | 3        | 0        |
| Build output       | Same     | Same     |
| Tests              | All pass | All pass |
| Kernel benchmark   | Works    | Works    |

**Lesson**: Regular dead code audits prevent accumulation of unused code. The `fft_split_f32.wat` was kept "for reference" but served no purpose since the native split module has different API and memory layout.

---

## Experiment 47: Performance Re-Baseline on Apple M5 Pro (2026-07-05)

**Goal**: Fresh benchmark analysis on new hardware (Apple M5 Pro, Node v24.14.1). Prior baselines (Experiments 26-45) were measured on different hardware.

**Environment change**: Absolute throughput roughly doubled for both wat-fft and competitors (e.g., RFFT N=64: 6.9M → 12M ops/s), but relative margins shifted significantly.

**f32 RFFT vs fftw-js** (two runs, consistent):

| Size   | Run 1 | Run 2 | Prior baseline |
| ------ | ----- | ----- | -------------- |
| N=64   | -4.5% | -6.3% | tied           |
| N=128  | +2.1% | +3.7% | +9.5%          |
| N=256  | +44%  | +47%  | +52%           |
| N=512  | +24%  | +27%  | +33%           |
| N=1024 | +10%  | +11%  | +18%           |
| N=2048 | +11%  | +13%  | +21%           |
| N=4096 | +7.5% | +8.7% | +18%           |

**Key finding**: On M5 Pro, wat-fft **loses to fftw-js at N=64** (-4.5% to -6.3%, outside noise) and margins at N>=1024 roughly halved. The "beats all competitors at all sizes" claim no longer holds for RFFT on this hardware.

**f32 Complex FFT vs pffft-wasm**: Still dominant everywhere — +21% (N=32) up to +102% (N=4096, split format). No action needed.

**Profiling** (`node --prof`, wasm function ticks):

- RFFT N=64: `fft_32_dit` 67%, `rfft_postprocess_64` 21%, glue ~12%
- RFFT N=4096: `fft_general` 68%, `rfft_postprocess_simd` 23.5%, **`copy_buffer` 4.8%**

**Opportunities identified**:

1. **Eliminate `copy_buffer` (LOW risk, ~4-5% at affected sizes)**: When the Stockham stage count is odd, the result lands in the secondary buffer and `copy_buffer` does a full extra pass before post-processing. Parameterizing `rfft_postprocess_simd` with a source offset (writing to buffer 0) removes the pass entirely.
2. **`fft_32_dit` register pressure (HIGH risk)**: 68 locals, 67% of N=64 RFFT time. The M5 loss concentrates here. Prior attempts (Experiments 22-25, 44) found no wins on old hardware, but the microarchitecture shift may change spill economics. Needs fresh investigation, not a rerun of old ideas.
3. **Docs re-baseline**: README/OPTIMIZATION_PLAN tables reflect old-hardware numbers.

**Files modified**: None (analysis only)

**Lesson**: Performance claims are hardware-relative. A microarchitecture change (M5 Pro) flipped N=64 from tied to losing and halved large-N margins without any code change — periodic re-baselining is part of maintenance.

---

## Experiment 48: Eliminate copy_buffer via Source-Parameterized Post-Processing (2026-07-05)

**Goal**: Remove the redundant full-array copy identified in Experiment 47 profiling (`copy_buffer` = 4.8% of RFFT N=4096 time).

**Hypothesis**: When the Stockham stage count is odd, the FFT result lands in the secondary ping-pong buffer and `copy_buffer` does a full extra pass just so post-processing can read from offset 0. Since `rfft_postprocess_simd` already touches every element, it can read directly from wherever the result landed and write to offset 0, eliminating the pass. Affected sizes (odd stage count, SIMD path): N=256, N=1024, N=4096.

**Changes** (`modules/fft_real_f32_dual.wat`):

- `$fft_general` now returns the buffer offset where the result landed (0 or `SECONDARY_OFFSET`) instead of copying back
- New `$fft_nc` (no-copy): the old `$fft` dispatch, returning the result offset (codelets always return 0)
- `$fft` is now a thin wrapper: `$fft_nc` + conditional `copy_buffer` (preserves semantics for `$ifft`/`$irfft`)
- `$rfft_postprocess_simd` takes a `$src` param: reads Z from `$src`, writes X to offset 0; `$src = 0` reproduces the original in-place behavior exactly
- `$rfft` passes the offset straight through on the SIMD path (N >= 256); the unrolled/scalar paths keep a guard copy (which never fires today: N <= 128 always lands at offset 0)

**Results** (Apple M5 Pro, two runs each, wat-fft ops/s):

| Size   | Before (best) | After (best) | Change    | vs fftw-js after |
| ------ | ------------- | ------------ | --------- | ---------------- |
| N=64   | 12.07M        | 12.09M       | ~0        | -6.3%            |
| N=128  | 8.07M         | 8.26M        | +2%       | +3.8%            |
| N=256  | 4.00M         | 4.17M        | **+4.5%** | **+54.3%**       |
| N=512  | 2.01M         | 2.02M        | ~0        | +23.3%           |
| N=1024 | 918K          | 966K         | **+5.2%** | **+14.5%**       |
| N=2048 | 457K          | 461K         | ~0        | +12.2%           |
| N=4096 | 207K          | 220K         | **+6.3%** | **+13.1%**       |

**Result**: SUCCESS — gains landed exactly at the predicted odd-stage-count sizes; unaffected sizes unchanged (within noise). All 27 tests pass.

**Lesson**: Profile-guided elimination of whole memory passes beats micro-tuning arithmetic. The copy was invisible in per-stage reasoning but obvious in the function-level tick profile. The same pattern (postprocess reads from ping-pong result buffer) may apply to the f64 RFFT module and the IFFT path.

---

## Experiment 49: Eliminate copy_buffer in IFFT Path + First IRFFT Benchmark (2026-07-05)

**Goal**: Apply the Experiment 48 pattern to the inverse path of `fft_real_f32_dual.wat`, and add an IRFFT benchmark so the inverse path has automated performance signal.

**Hypothesis**: `$ifft` was `conjugate_buffer -> $fft -> scale_and_conjugate`. The `$fft` wrapper does a conditional full-buffer copy when the Stockham result lands in the secondary ping-pong buffer, then `scale_and_conjugate` re-reads and re-writes every element anyway. Reading directly from the landing buffer removes a whole memory pass at odd-stage-count sizes (IRFFT N=256, 1024, 4096, where the internal N/2-point FFT has an odd stage count).

**Changes**:

- `modules/fft_real_f32_dual.wat`: `$scale_and_conjugate` takes a `$src` param (reads from `$src`, writes to offset 0); `$ifft` calls `$fft_nc` and passes the returned offset through; removed the now-dead `$fft` wrapper
- `benchmarks/irfft_f32_dual.bench.js` (new): IRFFT vs fftw-js `inverse`, same harness as the rfft bench; `npm run bench:irfft32`

**Results** (Apple M5 Pro, two runs each, wat-fft ops/s, best of two):

| Size   | Before | After | Change     | vs fftw-js after |
| ------ | ------ | ----- | ---------- | ---------------- |
| N=64   | 8.99M  | 8.81M | ~0 (noise) | -22.5%           |
| N=128  | 6.20M  | 6.15M | ~0         | -22.6%           |
| N=256  | 3.02M  | 3.11M | **+3.1%**  | -1.7% to +0.3%   |
| N=512  | 1.53M  | 1.54M | ~0         | -9.6%            |
| N=1024 | 710K   | 743K  | **+4.6%**  | -10.2%           |
| N=2048 | 353K   | 350K  | ~0         | -13.3%           |
| N=4096 | 163K   | 171K  | **+4.7%**  | -11.9%           |

**Result**: SUCCESS — gains landed exactly at the predicted odd-stage sizes; other sizes within noise. Forward RFFT re-benchmarked, unchanged. All 27 tests pass (irfft roundtrip covered by `test:ifft`).

**NEW FINDING — IRFFT loses to fftw-js at every size** (-1% to -28%, previously invisible with no benchmark). The forward RFFT wins at N>=128, so the gap is specific to the inverse path. Likely suspects, in profiling order:

1. `$irfft_preprocess` is fully scalar (the forward `rfft_postprocess_simd` is SIMD) — no SIMD or unrolled variants exist
2. `$ifft` does two extra full passes (`conjugate_buffer`, then conjugate again inside `scale_and_conjugate`) because it computes IFFT via conjugation; fusing the initial conjugate into `irfft_preprocess` (it already touches every element) would remove one pass, and a native inverse Stockham (negated twiddles) would remove both
3. fftw-js uses a dedicated c2r plan with no such overhead

This is now the largest known performance gap in the library — bigger than the N=64 RFFT gap (-6%).

**Lesson**: Unbenchmarked code paths hide large regressions. The inverse path was assumed to inherit forward-path performance because it reuses the same FFT core, but its pre/post-processing was never given the same optimization treatment. Every exported entry point should have a benchmark.

## Experiment 50: SIMD IRFFT Preprocess with Fused Conjugate (2026-07-05)

**Goal**: Close the IRFFT gap found in Experiment 49 by attacking its top two suspects at once: the fully scalar `$irfft_preprocess` and the extra `conjugate_buffer` full-buffer pass in the conjugation-based IFFT.

**Hypothesis**: The inverse preprocess formula has the same sum/diff/complex-multiply shape as the forward one, so `$rfft_postprocess_simd`'s dual-pair v128 structure transfers directly. And since the preprocess already touches every element, it can emit `conj(Z)` for free (one xor per store), letting the IFFT identity `IFFT(Z) = (1/N) * conj(FFT(conj(Z)))` skip its initial conjugate pass entirely.

**Changes** (`modules/fft_real_f32_dual.wat`):

- `$irfft_preprocess` rewritten as dual-pair SIMD mirroring `$rfft_postprocess_simd`, with three inverse-specific twists:
  - Uses `conj(W_rot) = (W.im, W.re)` for the k side — a plain re/im shuffle, no sign flip needed
  - Both sides reuse `W[k]` (since `conj(W_rot_{n2-k}) = W_rot_k`), so each dual pair needs ONE twiddle load where the forward needs two
  - Output is conjugated in the final store (`v128.xor` with `CONJ_MASK_F32`), which makes the middle-element special case (`Z[mid] = conj(X[mid])`) the identity — that branch is deleted outright
- `$irfft` now calls `$fft_nc` + `$scale_and_conjugate` directly; the dead `$ifft` wrapper and `$conjugate_buffer` are removed

**Results** (Apple M5 Pro, two runs each, wat-fft ops/s, best of two):

| Size   | Before | After  | Change     | vs fftw-js: before → after |
| ------ | ------ | ------ | ---------- | -------------------------- |
| N=64   | 9.15M  | 10.82M | **+18.3%** | -29.2% → -16.2%            |
| N=128  | 6.29M  | 7.54M  | **+19.9%** | -23.9% → -8.6%             |
| N=256  | 3.17M  | 3.90M  | **+23.0%** | -3.6% → **+16.4%**         |
| N=512  | 1.56M  | 1.92M  | **+22.9%** | -11.7% → **+8.0%**         |
| N=1024 | 751K   | 921K   | **+22.6%** | -11.4% → **+4.0%**         |
| N=2048 | 357K   | 438K   | **+22.6%** | -13.5% → **+3.6%**         |
| N=4096 | 169K   | 209K   | **+23.5%** | -14.0% → **+5.8%**         |

**Result**: SUCCESS — +18-24% at every size. IRFFT now BEATS fftw-js at all sizes N>=256 (was losing at every size). Forward RFFT re-benchmarked, unchanged within noise. All 27 tests pass (IRFFT roundtrip error 3.25e-11).

**Remaining gap**: N=64 (-16%) and N=128 (-9%) still lose. The forward path closes these sizes with fully-unrolled postprocess codelets (`$rfft_postprocess_64/128`, Experiments 23/25); mirroring those for the inverse preprocess is the natural next step. A native inverse Stockham (negated twiddles) would additionally remove the final `scale_and_conjugate` conjugate, but with the gap now this small the unrolled-codelet route is lower risk.

**Lessons**:

- A structurally-identical formula means a proven SIMD pattern ports nearly mechanically — the whole rewrite validated and passed tests on the first build
- Fusing a sign flip into a pass that already touches every element is free (one xor), and here it also deleted a special case: conjugating `conj(X[mid])` is the identity, so the middle-element branch vanished
- The inverse's twiddle symmetry (`conj(W_rot_{n2-k}) = W_rot_k`) halves twiddle loads vs the forward equivalent — inverting a transform sometimes exposes structure the forward direction lacks

## Experiment 51: Unrolled IRFFT Preprocess Codelets for N=64/128 (2026-07-05)

**Goal**: Close the remaining small-N IRFFT gap (N=64 -16%, N=128 -9% after Experiment 50) by mirroring the forward path's unrolled postprocess codelets (`$rfft_postprocess_64/128`, Experiments 23/25) for the inverse preprocess.

**Hypothesis**: The forward path wins N=64/128 partly through fully-unrolled postprocess with inline `v128.const` twiddles; the inverse should benefit the same way, eliminating loop overhead and twiddle memory loads.

**Changes**:

- `tools/generate-irfft-preprocess-codelet.js` (new): emits the unrolled WAT — hand-writing ~750 lines of mechanical SIMD was not sensible, and the generator makes regeneration trivial if the formula changes
- `modules/fft_real_f32_dual.wat`: `$irfft_preprocess_64` / `$irfft_preprocess_128` (generated), dispatched by size in `$irfft`. Each pair block inlines `conj(W_rot)` as a `v128.const` and derives the second side's `W_rot` with a single xor (`CONJ_MASK_F32` flips the re-lane) — the same symmetry the loop version exploits, so each dual pair needs one constant, not two

**Results** (Apple M5 Pro, two runs each, wat-fft ops/s, best of two, baseline = Experiment 50):

| Size  | Before | After  | Change     | vs fftw-js after |
| ----- | ------ | ------ | ---------- | ---------------- |
| N=64  | 10.82M | 10.86M | ~0 (noise) | -14.1%           |
| N=128 | 7.54M  | 7.79M  | **+3.3%**  | -6.6%            |

All other sizes unchanged (dispatch falls through to the generic SIMD loop). Forward RFFT re-benchmarked, unchanged. All 27 tests pass; explicit irfft roundtrip verified at N=32/64/128/256/512 (max error 1.7e-6 f32).

**Result**: PARTIAL — N=128 gains +3.3% (consistent across runs), N=64 within noise. Kept: the gain is real at N=128, there are no regressions, and the codelets are generated (low maintenance cost).

**Analysis**: Unrolling helped the forward path more because the forward postprocess is the FINAL pass over the data. The inverse preprocess at these sizes covers only n2/2 = 16/32 pair slots, while the dominant costs sit elsewhere: `$fft_32_dit`/`$fft_64` core (67% of time at this size per Experiment 47 profiling) plus the inverse-only `$scale_and_conjugate` full-buffer pass that the forward path simply doesn't have. That extra pass is now the structural difference: forward = FFT + postprocess, inverse = preprocess + FFT + scale_and_conjugate.

**Next step for the remaining gap**: A native inverse Stockham FFT (negated twiddles) would eliminate the final conjugate, and the 1/N scale can be folded into the preprocess constants (linearity) — together removing the entire `$scale_and_conjugate` pass. That is the remaining structural overhead at N=64 (-14%) and N=128 (-7%).

**Lesson**: Unrolling pays off in proportion to the fraction of runtime the loop actually occupies. The same optimization that gave the forward path its small-N edge gave the inverse only +3% because the inverse's bottleneck is an extra full-buffer pass, not loop overhead. Measure where the time is before porting a winning optimization to a sibling path.

## Experiment 52: Native Inverse FFT - Eliminate scale_and_conjugate (2026-07-05)

**Goal**: Remove the IRFFT's last structural overhead vs the forward path: the `$scale_and_conjugate` full-buffer pass required by the conjugation identity `IFFT(Z) = (1/N) * conj(FFT(conj(Z)))`. This was the documented next step from Experiment 51.

**Hypothesis**: A native inverse FFT (conjugated twiddles) plus the 1/N scale folded into the preprocess constants (linearity) makes IRFFT structurally identical to the forward RFFT: one preprocess pass + one FFT, no extra pass at any size.

**Key enablers** (why this was cheap despite "negated twiddles" sounding like a second twiddle table):

1. **Flipped sign mask = conjugated twiddles.** The Stockham's dual-complex multiply computes `b*w` as `b*wr + swap(b)*wi*SIGN_MASK` with `SIGN_MASK = [-1,1,-1,1]`. Conjugating `w` only negates `wi`, which is equivalent to using `[1,-1,1,-1]` instead. So `$fft_general` gained a `$sign` v128 param and serves both directions from ONE twiddle table at zero inner-loop cost.
2. **Start-buffer parity control.** `$fft_general` also gained a `$src_start` param. With log2(n) stages the ping-pong lands at `$src_start XOR parity`, so for odd-stage sizes the preprocess writes to SECONDARY and the inverse FFT lands at offset 0 - no landing-buffer copy either.
3. **Generated inverse codelets.** `tools/generate-dit-codelet.js --inverse` emits `$ifft_8/16/32_dit` (conjugated hardcoded twiddles, new J twiddle-type emitters mirroring NEG_J); the generator was first verified to reproduce all three forward codelets byte-identically, and the inverse codelets were validated standalone against a reference inverse DFT (max err < 1e-6) before integration. `$ifft_4` is hand-written (mask flip on the `-j` multiply).
4. **Free scale fold.** The preprocess formula already multiplies by 0.5, so emitting `Z/n2` is just `half = 0.5/n2` (exact in binary fp). Dropping Experiment 50's fused output conjugate removes one xor per store; the middle element returns as an explicit `conj(X[mid])/n2` store.

**Changes**:

- `modules/fft_real_f32_dual.wat`: `$SIGN_MASK_INV` global; `$fft_general(n, src_start, sign)`; `$ifft_4/8/16/32_dit` codelets; `$ifft_nc` dispatch; `$irfft_preprocess(n2, dst)` emits `Z/n2` unconjugated; regenerated `$irfft_preprocess_64/128`; `$irfft` picks the start buffer by stage parity; `$scale_and_conjugate` deleted
- `tools/generate-dit-codelet.js`: `--inverse` flag (forward output verified unchanged)
- `tools/generate-irfft-preprocess-codelet.js`: emits scaled unconjugated output + middle element

**Results** (Apple M5 Pro, two runs each, wat-fft ops/s, best of two, baseline = Experiment 51):

| Size   | Before | After  | Change    | vs fftw-js: before → after |
| ------ | ------ | ------ | --------- | -------------------------- |
| N=64   | 11.13M | 11.75M | **+5.5%** | -16.0% → -6.9%             |
| N=128  | 7.84M  | 8.48M  | **+8.3%** | -6.4% → **+4.1%**          |
| N=256  | 3.96M  | 4.23M  | **+6.9%** | +20.2% → **+28.8%**        |
| N=512  | 1.94M  | 2.08M  | **+7.2%** | +7.3% → **+19.3%**         |
| N=1024 | 929K   | 995K   | **+7.1%** | +3.0% → **+12.4%**         |
| N=2048 | 440K   | 471K   | **+7.0%** | +2.6% → **+13.7%**         |
| N=4096 | 210K   | 227K   | **+8.2%** | +4.2% → **+15.0%**         |

**Result**: SUCCESS - +5-8% at every size (the eliminated pass existed at every size). IRFFT now beats fftw-js at all sizes N>=128; the N=64 gap halved (-16% → -7%). Forward RFFT re-benchmarked: relative standings unchanged (the `$fft_general` param change cost nothing - the mask lives in a local either way). All 27 tests pass; roundtrip error slightly IMPROVED (1.13e-6 vs 1.7e-6, likely because scaling down early keeps intermediate magnitudes smaller).

**Remaining gap**: N=64 IRFFT (-7%) now matches the forward N=64 RFFT gap (-6%) almost exactly - both paths are structurally identical (preprocess/postprocess + `$fft_32_dit` core), and Experiment 47 profiling puts 67% of the time in `$fft_32_dit` (68 locals, register-spill territory). The inverse-specific overhead is gone; what remains is the shared small-N core.

**Lessons**:

- "Inverse needs its own twiddles" is wrong for this multiply structure: conjugation is a sign flip that folds into an existing constant. Check whether a "different constants" variant is really a "different one constant" variant before duplicating tables or code.
- Ping-pong landing parity is controllable for free by choosing the START buffer - a producer that writes to a chosen buffer anyway (the preprocess) absorbs the choice with zero cost.
- Validating generated code standalone (reference DFT comparison) before integration catches generator bugs where they are cheap to debug.

## Experiment 53: Stockham Loop Beats n=16/32 DIT Codelets on M5 (2026-07-06)

**Goal**: Attack the last open gap (N=64: forward -6%, inverse -7% vs fftw-js). Fresh profiling put 70-72% of N=64 time in the `fft_32_dit`/`ifft_32_dit` core.

**Diagnostic first**: Before designing a new codelet (radix-4, fusion, register scheduling), a core-isolated micro-benchmark compared the DIT codelets against plain `$fft_general` at the same sizes (both exported from scratch builds of the real module, correctness cross-checked on identical inputs):

| Core | Codelet | Stockham loop | Loop advantage      |
| ---- | ------- | ------------- | ------------------- |
| n=32 | 18.1M   | 30.0M         | **+66%**            |
| n=16 | 23.3M   | 45.7M         | **+97%**            |
| n=8  | 96.2M   | 81.2M         | -16% (codelet wins) |

The fully-unrolled dual-complex DIT codelets - the assumed advantage at small N since Experiments 8/23 - are a large LOSS on Apple M5. The codelets hold all 16 dual-packed v128 registers live across 5 stages with ~6 shuffles per dual butterfly; the loop streams through memory with far fewer live values. The M5 microarchitecture punishes the former and rewards the latter (old hardware showed the reverse).

**Changes**:

- `$fft_nc` / `$ifft_nc`: n=16 and n=32 now dispatch to `$fft_general`; codelets remain only for n<=8
- `$rfft_postprocess_64`: reads Z from SECONDARY (n2=32 Stockham has an odd stage count, so it always lands there) - a mechanical +65536 on its 19 input loads; writes the spectrum to offset 0 as before. The N=64/128 branches moved ahead of the copy_buffer guard
- `$irfft_preprocess_64`: regenerated to write Z to SECONDARY so the inverse Stockham lands at offset 0 (generator now derives the dst base from stage parity); `$irfft` start-parity threshold lowered to n2>=16
- Deleted `fft_16_dit`, `fft_32_dit`, `ifft_16_dit`, `ifft_32_dit` (~183KB of WAT, regenerable via `tools/generate-dit-codelet.js`)

**Results** (Apple M5 Pro, two runs each, best of two, baseline = Experiment 52):

| Path       | Before | After  | Change   | vs fftw-js: before → after |
| ---------- | ------ | ------ | -------- | -------------------------- |
| RFFT N=64  | 11.65M | 15.33M | **+32%** | -5.7% → **+22%**           |
| IRFFT N=64 | 11.75M | 15.40M | **+31%** | -6.9% → **+23%**           |
| RFFT N=32  | 17.6M  | 26.3M  | **+49%** | (not in competitor bench)  |
| IRFFT N=32 | 24.8M  | 30.0M  | **+21%** | (not in competitor bench)  |

All other sizes unchanged within noise (N=16 keeps its n=8 codelet). All 27 tests pass.

**Result**: SUCCESS - **wat-fft now beats fftw-js at every size in both directions.** The N=64 "register-spill re-investigation" flagged since Experiment 47 resolved not by building a better codelet but by deleting the codelet.

**Lessons**:

- When a component is suspect, benchmark it in ISOLATION against the simplest alternative before designing its replacement. A 30-minute core-vs-loop probe eliminated three speculative codelet redesigns and found a bigger win than any of them promised.
- Microarchitecture shifts can invert past conclusions wholesale: the unrolled codelets earned their place on 2026-January hardware (Experiments 8/23/34) and lost it on M5. Optimizations tied to register/shuffle economics need re-validation per hardware generation, and dispatch thresholds are cheap to flip.
- Deterministic landing parity (Experiment 52's insight) is what made this switch free: the N=64 pre/post-processing codelets simply hardcode the other buffer instead of paying a copy pass.

**Follow-up**: `fft_stockham_f32_dual.wat` (complex FFT) still dispatches small sizes to its own codelets (radix-4 N=16 from Experiment 44, etc.). It dominates its competitors so there is no gap to close, but the same codelet-vs-loop probe may find free wins there.

## Experiment 54: Complex-Module Codelet-vs-Loop Probe (2026-07-06)

**Goal**: Answer Experiment 53's follow-up - do the complex f32 module's small-N codelets (`fft_stockham_f32_dual.wat`) also lose to the Stockham loop on M5?

**Method**: Same core-isolation A/B as Experiment 53 (scratch module exporting each core; production-realistic, i.e. `$fft_general`'s internal copy-back at odd stage counts is included). Correctness cross-checked first (f32 roundoff-level differences only).

**Results** (Apple M5 Pro, best of 5 runs):

| Core | Codelet     | `$fft_general` | Winner           |
| ---- | ----------- | -------------- | ---------------- |
| n=16 | 67.4M ops/s | 45.8M ops/s    | codelet **+47%** |
| n=8  | 96.8M ops/s | 72.1M ops/s    | codelet **+34%** |

**Result**: NO CHANGE - the complex module's codelets win decisively on M5. Dispatch stays as-is.

**Analysis**: This is the opposite of the Experiment 53 finding, and it isolates WHY the real module's codelets lost. The two modules use different codelet designs:

- Real module (deleted): radix-2 dual-complex DIT - 16 v128 registers live across 5 stages, ~6 shuffles per dual butterfly. 23.3M ops/s at n=16.
- Complex module (kept): radix-4 single-complex-per-lane (Experiment 44) - fewer stages, minimal shuffling, small live set. **67.4M ops/s at n=16 - 2.9x faster for the same transform.**

So "codelets lost on M5" (Experiment 53) was never about codelets per se; it was about that codelet DESIGN. Radix-4 single-lane codelets remain excellent on M5.

**Future direction (data, not a commitment)**: the real module's N=64 path now runs its n2=32 core on the loop at 30.0M ops/s. The complex module's radix-4 style at n=16 does 67.4M; a radix-4-style n=32 codelet (4-4-2 stages) could plausibly beat 30M and add another chunk at N=64 - now a win-extending experiment rather than a gap-closing one.

**Lesson**: When an A/B flips on new hardware, check whether the losing side is one DESIGN of the approach or the approach itself before generalizing. One probe (Experiment 53) said "codelets lose on M5"; the sibling module's different codelet design wins by +47% on the same hardware.

## Experiment 55: Native Inverse FFT for the Complex f32 Module (2026-07-06)

**Goal**: Port Experiment 52's native-inverse approach to `fft_stockham_f32_dual.wat`. Its `ifft` still used the conjugation identity `IFFT(Z) = (1/N) * conj(FFT(conj(Z)))`, paying TWO extra full-buffer passes (`$conjugate_buffer` before, `$scale_and_conjugate` after) that the forward path doesn't have.

**Benchmark first** (Experiment 49's lesson): the complex ifft path had no benchmark. Added `benchmarks/ifft_f32_dual.bench.js` (`npm run bench:ifft32`) comparing against pffft-wasm backward (unscaled) and fft.js `inverseTransform`. Baseline confirmed the structural overhead: ifft ran 12-16% slower than forward fft at every size (e.g. N=1024: 536K vs 606K).

**Changes** (`modules/fft_stockham_f32_dual.wat`):

- `$SIGN_MASK_INV` global `[1,-1,1,-1]`: the dual-complex multiply computes `b*w` as `b*wr + swap(b)*wi*sign`, so the flipped mask negates `wi` = conjugated twiddles from the SAME table at zero inner-loop cost (Experiment 52's key insight, ported unchanged)
- `$fft_general(n, sign, scale)`: `$sign` selects direction; `$scale` (1.0 forward, 1/N inverse) is folded into the final-stage (r=1) butterfly stores - the 1/N normalization costs 2 extra `f32x4.mul` per dual butterfly in ONE stage instead of a full pass
- New `$ifft_8_dit` and `$ifft_16` codelets: mirrors of the forward codelets with conjugated hardcoded twiddles (`-j` rotations become `+j` via mask flip; generic multiplies negate the wi constant) and 1/N folded into the final stores. Validated against a reference inverse DFT (max err < 9e-8) in addition to roundtrip tests
- `ifft` dispatch mirrors `fft` dispatch: n=4/8/16 codelets, else `$fft_general` with `$SIGN_MASK_INV` and a 1/n splat
- Deleted `$conjugate_buffer`, `$scale_and_conjugate`, and the now-unused `$CONJ_MASK`

Unlike the real module (Experiment 52), no start-buffer parity trick is needed: input arrives at offset 0, so odd-stage sizes keep the same `$copy_buffer` as the forward path - inverse and forward are now structurally identical.

**Results** (Apple M5 Pro, two runs each, best of two, wat-fft ifft ops/s):

| Size   | Before | After  | Change   | Forward fft (same day) |
| ------ | ------ | ------ | -------- | ---------------------- |
| N=64   | 9.13M  | 11.14M | **+22%** | 11.06M                 |
| N=128  | 4.56M  | 5.29M  | **+16%** | 5.24M                  |
| N=256  | 2.42M  | 2.77M  | **+14%** | 2.78M                  |
| N=512  | 1.06M  | 1.23M  | **+16%** | 1.22M                  |
| N=1024 | 536K   | 615K   | **+15%** | 610K                   |
| N=2048 | 239K   | 271K   | **+13%** | 270K                   |
| N=4096 | 116K   | 133K   | **+15%** | 134K                   |

**Result**: SUCCESS - +13-22% at every size, and ifft now matches forward fft throughput exactly (the entire structural overhead is gone). vs pffft-wasm's unscaled backward transform: +36% to +85%. Forward fft re-benchmarked: no regression at any size (the `$scale=1.0` multiply in the last stage is free within noise). All 27 core tests and the full extended suite pass; roundtrip error unchanged (~1e-6).

**Lessons**:

- The Experiment 52 recipe (sign-mask flip + fold 1/N into an existing pass) ported to a second module with zero surprises - a validated structural optimization on one module is a low-risk, high-confidence win on its siblings. Check sibling modules whenever a structural pass-elimination lands.
- Folding a scale into the final Stockham stage (rather than a preprocess, which the complex module doesn't have) works equally well: a parameterized multiply in one stage is noise, a separate full-buffer pass is 13-16%.

## Experiment 56: Packed Dual-16 Radix-4 n=32 Codelet for the Real Module (2026-07-06)

**Goal**: Take the win-extending opportunity flagged by Experiment 54: the real module's N=64 path ran its n2=32 core on the Stockham loop at 30M ops/s while the complex module's radix-4 codelet design does 67M at n=16. Build a radix-4-style n=32 codelet and extend the N=64 win.

**Design insight**: The complex module's winning codelet computes ONE complex number per v128 and wastes lanes 2-3. A DIT even/odd split of the 32-point FFT needs two independent 16-point FFTs with identical structure and twiddles - so pack the even-index sequence's FFT into lanes 0-1 and the odd-index sequence's into lanes 2-3 of the SAME registers. Because z[2j], z[2j+1] are 16 contiguous bytes, one full-width `v128.load` packs both halves with ZERO deinterleave shuffles: the whole 16-point radix-4 network (4-4 stages) runs at the same instruction count as one single-lane fft_16 but computes both halves. A final radix-2 combine applies hardcoded W_32^p to the odd-half lanes via per-lane constants (`[1,1,wr,wr]` / `[0,0,-wi,wi]` - the identity rides in the low lanes, no lane extraction) and stores X[p], X[p+16] from an add/sub of the two lane halves.

Two refinements over the fft_16 idiom: full-width per-pair swap shuffles (`4 5 6 7 0 1 2 3 12 13 14 15 8 9 10 11`) keep the lane halves independent, and the cmul sign vector is folded into the wi constant (one mul fewer per twiddle). Codelets are generated by `tools/generate-radix4-32-codelet.js` (forward + inverse from one template: conjugated twiddles, flipped rotJ sign; inverse is unscaled - 1/N lives in the IRFFT preprocess per Experiment 52).

**Isolated probe first** (Experiment 53's lesson - same core-A/B method, correctness cross-checked against an f64 reference DFT before timing):

| Core (n=32) | Stockham loop | New codelet | Codelet advantage |
| ----------- | ------------- | ----------- | ----------------- |
| forward     | 31.6M ops/s   | 51.1M       | **+55-62%**       |
| inverse     | 30.3M ops/s   | 53.7M       | **+77-84%**       |

The codelet is also ~4x MORE accurate (max err 6.8e-7 vs 2.6e-6 vs the reference): hardcoded f32 twiddles beat table loads.

**Integration** (`modules/fft_real_f32_dual.wat`): `$fft_32_r4` reads offset 0 and writes SECONDARY (matching the odd-stage-count landing parity `$rfft_postprocess_64` already expects); `$ifft_32_r4` reads SECONDARY and writes 0 (matching `$irfft`'s parity-picked start). `$fft_nc` dispatches n=32 to the codelet; `$ifft_nc` does too, guarded on `$src_start == SECONDARY` to protect future dispatch changes. No pre/post-processing changes needed - the deterministic-parity contract (Experiments 52-53) made the swap drop-in.

**Results** (Apple M5 Pro, `npm run bench:rfft32` / `bench:irfft32`, two runs, best shown, baseline = Experiment 53):

| Path       | Before | After | Change   | vs fftw-js: before → after |
| ---------- | ------ | ----- | -------- | -------------------------- |
| RFFT N=64  | 15.7M  | 19.7M | **+25%** | +21% → **+54%**            |
| IRFFT N=64 | 15.4M  | 19.5M | **+26%** | +23% → **+54%**            |

All other sizes unchanged within noise. All 27 tests pass; roundtrip error unchanged.

**Result**: SUCCESS - the largest single-size jump since Experiment 53, on a size that was already winning.

**Lessons**:

- When a fast codelet design wastes SIMD lanes, look for a DECOMPOSITION whose independent sub-transforms can ride in the wasted lanes. The DIT even/odd split was ideal here because (a) both halves share twiddles, so lane-splatted constants work unchanged, and (b) the even/odd interleaving matches the memory layout exactly, so the packing costs zero shuffles.
- The packing trick applies once: an n=64 version would need its dual-16 sub-FFTs' lanes already occupied. n=64 would need memory staging between stages - unexplored, and N=128 (weakest margin, +4%) is the size that would benefit.
- The complex f32 module still dispatches n=32 to its Stockham loop; the same codelet (write-to-0 variant, plus a fused-scale inverse) would likely add a similar win at complex N=32. Not benchmarked against competitors at that size, so left as a follow-up.

## Experiment 57: Browser Benchmark Audit - We've Been Racing pffft's Non-SIMD Build (2026-07-06)

**Goal**: Run the browser benchmarks (`npm run bench:browser`, Vitest + Playwright Chromium) locally and explain why wat-fft is not on top there.

**Finding**: In Chromium, pffft-wasm wins every complex FFT size N>=128 (1.08-1.33x faster than wat-fft f32) and every real FFT size N>=128 (1.04-1.90x faster than wat-rfft f32). wat-fft still wins N<=64 in both suites.

**Root cause**: The `@echogarden/pffft-wasm` package ships two builds, and its exports map resolves the bare import to the NON-SIMD build:

```json
{ ".": "./dist/non-simd/pffft.js", "./simd": "./dist/simd/pffft.js" }
```

Every Node benchmark (`fft.bench.js`, `rfft.bench.js`, `fft_f32_dual.bench.js`, ...) does `import PFFFT from "@echogarden/pffft-wasm"` and therefore races the scalar build - while the browser loader (`benchmarks/browser/fft-loader.ts`) points `locateFile` at `dist/simd/pffft.wasm` and gets the real SIMD build. The README's "pffft-wasm (PFFFT with SIMD)" tables are actually non-SIMD numbers.

**Confirmation in Node** (high-resolution timers, Apple M5 Pro, Node v24 - rules out Chromium's 0.1ms `performance.now()` coarsening as the explanation; per-iteration input copy included for all parties, same as existing benchmarks):

| Size   | Complex: wat-fft f32 | pffft SIMD | pffft non-SIMD | wat/SIMD  | Real: wat-rfft f32 | pffft SIMD | wat/SIMD  |
| ------ | -------------------- | ---------- | -------------- | --------- | ------------------ | ---------- | --------- |
| N=64   | 11.27M               | 10.95M     | 6.20M          | **1.03x** | 19.45M             | 15.37M     | **1.27x** |
| N=128  | 5.27M                | 6.44M      | 3.16M          | 0.82x     | 8.15M              | 10.25M     | 0.79x     |
| N=256  | 2.81M                | 3.76M      | 1.65M          | 0.75x     | 4.16M              | 7.05M      | 0.59x     |
| N=512  | 1.25M                | 1.78M      | 700K           | 0.70x     | 2.01M              | 3.79M      | 0.53x     |
| N=1024 | 579K                 | 904K       | 345K           | 0.64x     | 971K               | 2.05M      | 0.47x     |
| N=2048 | 272K                 | 407K       | 147K           | 0.67x     | 458K               | 927K       | 0.49x     |
| N=4096 | 135K                 | 189K       | 70K            | 0.71x     | 221K               | 471K       | 0.47x     |

The non-SIMD column matches the README's pffft numbers almost exactly, confirming which build the historical benchmarks measured.

**Why pffft SIMD is faster**: PFFFT's core runs every butterfly 4-wide on f32x4 with a SIMD-reordered internal ("z-domain") format - split re/im inside vectors, so complex multiplies are pure mul/add with no lane shuffles, and 100% lane utilization at every stage. wat-fft's dual-complex interleaved approach computes 2 complex values per v128 and pays shuffles for every cmul. The stabilized ~2x real-FFT gap and ~1.4x complex gap at large N match that lane-utilization difference. The gap is a real algorithmic/layout deficit, not measurement noise.

**Secondary observations**:

- Chromium clamps `performance.now()` to 0.1ms without cross-origin isolation; all tinybench samples in browser runs are quantized to 0/0.1ms. Ordering is still trustworthy (confirmed by Node), but absolute browser hz values are noisy. Adding COOP/COEP headers to the Vitest server would restore 5us timers.
- `benchmarks/README.md` still says pffft-wasm is not included in browser benchmarks - outdated, the loader includes it.
- The browser loader imports the non-SIMD glue JS but swaps in the SIMD wasm via `locateFile`; it works (identical export surface) but should import `dist/simd/pffft.js` directly.

**Result**: FINDING - "beats all competitors" (README, OPTIMIZATION_PLAN) only holds vs pffft's non-SIMD build. Against pffft SIMD, wat-fft leads only at N<=64. Claims and Node benchmarks need updating (`@echogarden/pffft-wasm/simd`), and closing the gap likely requires pffft-style 4-wide split-format processing in the core stages.

**Lessons**:

- When benchmarking a package that ships multiple builds, check its `exports` map - the bare import may not be the build its README advertises.
- Browser benchmarks caught this precisely because the browser loader had to load the wasm by URL and picked the SIMD file explicitly. Divergent loader paths between environments are worth auditing whenever results disagree across environments.

## Experiment 58: Radix-4 Split-Format Core Beats pffft SIMD (2026-07-06)

**Goal**: Close the Experiment 57 gap. pffft SIMD leads because (a) its split-re/im internal format makes every complex multiply pure mul/add with zero shuffles at 100% lane utilization, and (b) its radix-4/5 decomposition takes ~half the memory passes of our radix-2 Stockham.

**Design**: Fuse consecutive radix-2 Stockham stage pairs (r, l) + (r/2, 2l) into one radix-4 stage. With s = r/2 and w = e^(-i*pi*j/(2l)), group j reads quarters a,b,c,d at stride s from base j\*4s and writes:

```
t0 = a + w^2 c;  t1 = a - w^2 c;  t2 = w b + w^3 d;  t3 = w b - w^3 d
dst[q] = t0+t2;  dst[q+n/4] = t1 - i*t3;  dst[q+n/2] = t0-t2;  dst[q+3n/4] = t1 + i*t3
```

(q = j\*s + t). In split format the -i rotation is an operand swap + negate - **zero shuffles in the generic stage**. One twiddle triple per group, splatted (hoisted out of the t loop). The final s=1 stage needs 4 different twiddle triples per v128: a 4x4 transpose (8 shuffles/plane) gathers a/b/c/d and twiddles are contiguous loads from per-stage tables laid out as w1re[l] w1im[l] w2re[l] w2im[l] w3re[l] w3im[l]. For N = 2\*4^p, one leading radix-2 stage (l=1, twiddle = 1: pure 4-wide add/sub, no twiddle loads) makes the remaining stage count divisible by 2. For n=4^p and 2\*4^p, s only ever hits {>=4, 1} - no s=2 kernel needed.

**Probe** (`tools/fft_r4_split_probe.wat` + `.harness.mjs`, n = 4^p only; JS prototype validated 2\*4^p too): correctness vs f64 reference DFT is rel ~2e-7 at all sizes - also ~4x more accurate than the old split module thanks to fewer stages.

**Results** (Apple M5 Pro, Node v24, input copy per iteration for all, best of two runs):

| Size   | r4-split probe | old split (r2) | dual (interleaved) | pffft SIMD | probe vs pffft | probe vs dual |
| ------ | -------------- | -------------- | ------------------ | ---------- | -------------- | ------------- |
| N=64   | 17.4M          | 11.0M          | 11.3M              | 11.1M      | **+56%**       | **+54%**      |
| N=256  | 5.01M          | 2.96M          | 2.78M              | 3.86M      | **+30%**       | **+80%**      |
| N=1024 | 1.18M          | 673K           | 628K               | 918K       | **+29%**       | **+88%**      |
| N=4096 | 256K           | 149K           | 135K               | 190K       | **+35%**       | **+90%**      |

**Result**: SUCCESS (probe) - the radix-4 split-format core beats pffft SIMD by 29-56% and our flagship interleaved module by 54-90%. The two structural deficits identified in Experiment 57 (pass count + shuffle overhead) account for essentially the entire gap.

**Integration roadmap**:

1. Productionize in `fft_split_native_f32.wat`: WAT twiddle precompute (new per-stage layout), leading radix-2 stage for N=2\*4^p, output parity handling, conjugate-twiddle inverse
2. Interleaved API on the same core: fold deinterleave into first-stage loads and reinterleave into last-stage stores (pffft's ordered mode does exactly this)
3. Rebuild the real FFT on the new core - pffft's real transform is faster than its own half-size complex transform, so a natively-vectorized real path is the end state

**Lessons**:

- Fusing two radix-2 Stockham stages algebraically (rather than redesigning from a radix-4 reference) preserved the memory-layout conventions, which made the WAT port mechanical and correct on the first compile.
- Split format + radix-4 is multiplicative, not additive: split alone lost (Exp 39), multi-twiddle radix-2 split roughly tied interleaved (Exp 40), but radix-4 split wins big - the format only pays off once the stage math is shuffle-free AND the pass count halves.

### Experiment 58 Integration (same day)

The radix-4 core was integrated into `modules/fft_split_native_f32.wat` (n>=16; n=4/8 keep the old paths):

- `precompute_twiddles_split` now also derives per-stage twiddle triples (forward + conjugated inverse) from the classic W_N^k table - no new trig code. Memory grew 4 -> 5 pages for the two stage-table regions (0x30000 fwd, 0x40000 inv; sized for n=8192).
- `$stage_r2_lead` (twiddle-free 4-wide add/sub) runs first when log2(n) is odd, making the remaining stage count divisible by 2; s only ever hits {>=4, 1}, so just two radix-4 kernels are needed.
- `ifft_split` is now a NATIVE inverse: conjugated stage tables + one 1/N scale pass, replacing the conjugate-wrapper (which cost two extra full passes). **Gotcha found in testing**: conjugating the twiddle tables is NOT enough - the hardcoded -i rotation inside the radix-4 butterfly is itself a twiddle and must flip to +i. Implemented by swapping the two middle output-block addresses via an `$inv` param (branch-free address select, kernels shared between fft/ifft).
- Odd-stage-count sizes (32, 64, 512, 1024, 8192) pay one SIMD copy-back pass to honor the output-in-buffer-A API contract; even-stage sizes (16, 128, 256, 2048, 4096) don't.

**Official results** (`npm run bench`, per-iteration input copy for all):

| Size   | wat-fft f32 split | pffft SIMD | old dual (interleaved) | vs pffft SIMD | vs dual  |
| ------ | ----------------- | ---------- | ---------------------- | ------------- | -------- |
| N=16   | 27.4M             | 27.7M      | 35.6M (dual wins)      | -1%           | -23%     |
| N=32   | 19.8M             | 18.8M      | 17.5M                  | **+6%**       | **+13%** |
| N=64   | 13.8M             | 13.6M      | 11.2M                  | **+1%**       | **+23%** |
| N=128  | 8.91M             | 7.39M      | 5.45M                  | **+21%**      | **+64%** |
| N=256  | 4.86M             | 3.95M      | 2.82M                  | **+23%**      | **+72%** |
| N=512  | 2.15M             | 1.83M      | 1.24M                  | **+18%**      | **+74%** |
| N=1024 | 1.05M             | 913K       | 620K                   | **+15%**      | **+69%** |
| N=2048 | 538K              | 404K       | 273K                   | **+33%**      | **+97%** |
| N=4096 | 251K              | 188K       | 133K                   | **+34%**      | **+89%** |

**Result**: SUCCESS - wat-fft is again the fastest complex FFT at every size (split module at N>=32, interleaved dual at N=16). All 27 core tests, 22 split tests, and the 52+14 third-party/bench-correctness tests pass; forward error improved ~2x vs the old radix-2 split path.

**Follow-ups**: (a) N=32/64/512/1024 lose ~10-20% to the copy-back pass - an exported raw-output variant or in-driver parity trick could reclaim it; (b) port the core to the interleaved API by folding deinterleave/reinterleave into the first/last stage loads/stores; (c) rebuild the real FFT on this core (the remaining pffft SIMD win: real N>=128).

## Experiment 59: Real FFT on the Radix-4 Split Core (2026-07-06)

**Goal**: Close the last pffft SIMD gap - real FFT N>=128 trailed by 23-53% both directions (Experiment 57 baseline). Rebuild the forward real FFT on the Experiment 58 radix-4 split-format core.

**Design** (`rfft_split` in `fft_split_native_f32.wat`, N >= 32, same API contract as the old `rfft`: N real f32 at offset 0 in, N/2+1 interleaved complex out at offset 0):

1. **Fused first stage**: the M = N/2 complex core's first stage reads the packed real input at offset 0 directly, folding the even/odd deinterleave shuffles into its loads - no standalone deinterleave pass. Even log2(M): a twiddle-free radix-4 first stage (l=1, w=1). Odd log2(M): a **radix-8 first stage** replacing deinterleave + leading radix-2 + first radix-4 (three passes -> one); its twiddles are the constants 1, -i, sqrt(2)/2\*(1-+i), so it stays shuffle-free splat arithmetic.
2. **Parity-routed ping-pong, zero copy-back**: the fused stage always writes buffer B (never overlaps the input, which ends where B begins). The remaining stages ping-pong against A when the remainder is even (result returns to B) or against a new buffer C when odd (result ends in C). Either way the result avoids A, so the post-process can stream its output over A. The complex module's copy-back pass has no equivalent here at any size.
3. **Split-format SIMD post-process**: G/H even/odd-spectrum recombination entirely in split planes - forward loads of Z[k..k+3], one lane-reverse shuffle for Z[M-k-3..M-k], contiguous split twiddle loads (new W_N^k table at 0x50000), pure mul/add math, and interleave-on-store shuffles writing X directly in output format. 6 shuffles per 8 output bins. DC/Nyquist handled scalar; Nyquist is stored after the loop because at N=16384 it lands on the first bytes of buffer B, which the loop still reads as Z[1].

Memory grew 5 -> 8 pages (rfft twiddle table + buffer C). The core driver was refactored into `$fft_r4_pipeline` (arbitrary start point and buffer pair) with `$fft_r4_core_nc`/`$fft_r4_core` wrappers; the complex `fft_split`/`ifft_split` paths are unchanged and still pass all 22 tests.

**Correctness**: max relative error vs f64 reference DFT <= 1.1e-6 across N=32..16384 for impulse/sinusoid/random inputs (36/36 tests). Matches the old `rfft` to f32 rounding.

**Results** (Apple M5 Pro, Node v24, per-iteration input copy for all, 2 official runs):

| Size   | rfft_split | old rfft | fftw-js | pffft SIMD | vs old    | vs pffft SIMD |
| ------ | ---------- | -------- | ------- | ---------- | --------- | ------------- |
| N=64   | 19.1-21.9M | 19.2M    | 12.5M   | 14.2-15.3M | ~tie      | **+35-43%**   |
| N=128  | 13.9M      | 8.1M     | 7.9M    | 10.5M      | **+71%**  | **+31%**      |
| N=256  | 7.9M       | 4.2M     | 2.7M    | 7.2M       | **+88%**  | **+10%**      |
| N=512  | 3.8M       | 2.0M     | 1.6M    | 3.8M       | **+87%**  | -1%           |
| N=1024 | 1.95M      | 977K     | 837K    | 2.07M      | **+100%** | -5%           |
| N=2048 | 914K       | 464K     | 412K    | 946K       | **+97%**  | -3.5%         |
| N=4096 | 452K       | 223K     | 191K    | 475K       | **+103%** | -5%           |

**Result**: SUCCESS - the real FFT roughly doubled at every size N>=128, now beats pffft SIMD at N<=256 and sits within 1-5% at N=512-4096 (was 23-53% behind). fftw-js is beaten by +130-190% at N>=512.

**Lessons**:

- The memory-pass model predicts f32 FFT throughput on M5 almost exactly: each eliminated full pass over the data was worth its predicted share. Count passes before writing code.
- A radix-8 first stage is free in split format when it is the FIRST stage: all its twiddles are constants, so fusing three radix-2 levels costs no table loads and no shuffles beyond the deinterleave that had to happen anyway.
- Three ping-pong buffers + parity routing eliminate copy-back passes structurally: pick the partner buffer so the result lands where the next consumer wants it, instead of copying afterwards.

**Remaining gap / next step (Experiment 60 candidate)**: the last 1-5% at N>=512 is exactly one more pass: pffft fuses its real-FFT finalization into the final butterfly stage. Fusing our post-process into the s=1 stage requires pairing stage iterations j and M/4-4-j with a one-vector software-pipeline carry (mirrored blocks are misaligned by one element) - intricate but well-understood.
