# FFT Optimization Plan: Closing the Gap with FFTW

## Executive Summary

wat-fft has achieved significant performance gains through systematic optimization. This document provides an overview - see linked sub-documents for details.

**Current Status** (Apple M5 Pro, 2026-07-06, post-Experiments 57-61): **wat-fft is the fastest complex FFT at every size** (Experiment 58's radix-4 split-format core beats pffft-wasm SIMD by 1-34% at N≥32; the interleaved module wins N=16 by +29%). Both real FFT directions were rebuilt on the same core: forward (`rfft_split`, Experiment 59) beats fftw-js by +53-193% everywhere and pffft SIMD at N≤256; inverse (`irfft_split`, Experiment 60) gained +43-83% at N≥128 and beats pffft SIMD at N≤128. Experiment 61 fused the forward post-process into the final butterfly stage where it pays — N=64 only, +15-20% (now +80-90% vs pffft SIMD there); at N≥128 both fusion designs lost to register spills and scattered access streams, so the remaining real-FFT gaps vs pffft SIMD (1-5% forward / 3-17% inverse at large N) stand, and simple pre/post-process fusion is now a measured dead end for them. Note: Experiments 1-56 accidentally raced pffft's non-SIMD build (see Experiment 57).

| Target          | Complex FFT (f64) | Complex FFT (f32)           | Real FFT forward (f32)                    | Real FFT inverse (f32)                     |
| --------------- | ----------------- | --------------------------- | ----------------------------------------- | ------------------------------------------ |
| fft.js          | **+37-90%**       | **+101-458%** (split core)  | N/A                                       | N/A                                        |
| fftw-js         | N/A               | N/A                         | **+53-193%** (beats at all N)             | **+39-115%** (beats at all N)              |
| pffft-wasm SIMD | N/A               | **+1-34%** (beats at all N) | **+10-35%** at N≤256; -1% to -5% at N≥512 | **+14-24%** at N≤128; -3% to -17% at N≥256 |

---

## Documentation Index

| Document                                                          | Description                                                                    |
| ----------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| [FFTW_ANALYSIS.md](optimization/FFTW_ANALYSIS.md)                 | Why FFTW is fast: genfft codelets, operation fusion, cache-oblivious recursion |
| [COMPLETED_PRIORITIES.md](optimization/COMPLETED_PRIORITIES.md)   | Implemented optimizations: Priorities A-J with results                         |
| [FUTURE_PRIORITIES.md](optimization/FUTURE_PRIORITIES.md)         | Research completed but not implemented: split-radix, register scheduling       |
| [EXPERIMENT_LOG.md](optimization/EXPERIMENT_LOG.md)               | All 60 experiments with detailed results and lessons learned                   |
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

**vs pffft-wasm SIMD (f32 vs f32, 2026-07-06, Experiment 58 radix-4 split core):**

| Size   | wat-fft f32 split | wat-fft f32 (interleaved) | pffft-wasm SIMD | best vs pffft |
| ------ | ----------------- | ------------------------- | --------------- | ------------- |
| N=16   | 27.4M             | 35.6M                     | 27.7M           | **+29%**      |
| N=32   | 19.8M             | 17.5M                     | 18.8M           | **+6%**       |
| N=64   | 13.8M             | 11.2M                     | 13.6M           | **+1%**       |
| N=128  | 8.91M             | 5.45M                     | 7.39M           | **+21%**      |
| N=256  | 4.86M             | 2.82M                     | 3.95M           | **+23%**      |
| N=512  | 2.15M             | 1.24M                     | 1.83M           | **+18%**      |
| N=1024 | 1.05M             | 620K                      | 913K            | **+15%**      |
| N=2048 | 538K              | 273K                      | 404K            | **+33%**      |
| N=4096 | 251K              | 133K                      | 188K            | **+34%**      |

_Note: older tables in this file compared against pffft's non-SIMD build. The split module's radix-4 core (Experiment 58) replaced the Experiment 39/40 radix-2 design and is now the fastest at N≥32._

### Real FFT f32 vs fftw-js and pffft-wasm SIMD

Measured on Apple M5 Pro, Node v24 (2026-07-06, Experiment 59): `rfft_split` on the radix-4 split core - fused deinterleaving first stage (radix-8 for odd log2(N/2)), parity-routed ping-pong with zero copy-back, split-format SIMD post-process. The old dual-complex `rfft` column is retained for comparison.

| Size   | rfft_split | old rfft | fftw-js | pffft SIMD | vs fftw   | vs pffft SIMD |
| ------ | ---------- | -------- | ------- | ---------- | --------- | ------------- |
| N=64   | 32.5M ¹    | 19.2M    | 14.6M ¹ | 17.6M ¹    | **+122%** | **+85%**      |
| N=128  | 13.9M      | 8.1M     | 7.9M    | 10.6M      | **+74%**  | **+31%**      |
| N=256  | 7.9M       | 4.2M     | 2.7M    | 7.2M       | **+189%** | **+10%**      |
| N=512  | 3.8M       | 2.0M     | 1.6M    | 3.85M      | **+130%** | -1%           |
| N=1024 | 1.95M      | 977K     | 837K    | 2.07M      | **+132%** | -5%           |
| N=2048 | 914K       | 464K     | 412K    | 946K       | **+121%** | -3.5%         |
| N=4096 | 452K       | 223K     | 191K    | 475K       | **+134%** | -5%           |

¹ N=64 re-measured 2026-07-06 with the statistical harness after Experiment 61 (fused s=1 stage + post-process at M=32); other rows are the Experiment 59 measurements.

### Inverse Real FFT f32 vs fftw-js and pffft-wasm SIMD

Measured on Apple M5 Pro (2026-07-06, Experiment 60): `irfft_split` on the radix-4 split core — fused SIMD pre-process with the 1/N normalization folded in, inverse pipeline ping-ponging B↔C, and a final s=1 stage fused with the reinterleave. The old dual-complex `irfft` column is retained for comparison (it remains fastest at N=64). pffft's backward transform is unscaled (slightly less work).

| Size   | irfft_split | old irfft | fftw-js | pffft SIMD | vs fftw   | vs pffft SIMD |
| ------ | ----------- | --------- | ------- | ---------- | --------- | ------------- |
| N=64   | 17.7M       | 19.4M     | 12.5M   | 14.3M      | **+41%**  | **+23%**      |
| N=128  | 11.9M       | 8.4M      | 8.0M    | 10.3M      | **+48%**  | **+15%**      |
| N=256  | 6.9M        | 4.3M      | 3.3M    | 7.1M       | **+111%** | -3%           |
| N=512  | 3.6M        | 2.1M      | 1.7M    | 3.75M      | **+112%** | -3%           |
| N=1024 | 1.70M       | 994K      | 870K    | 2.0M       | **+95%**  | -15%          |
| N=2048 | 860K        | 474K      | 416K    | 930K       | **+107%** | -8%           |
| N=4096 | 404K        | 226K      | 192K    | 455K       | **+110%** | -11%          |

---

## Remaining Gap Analysis

**The remaining gap is 1-5% on the forward real FFT at N=512-4096 and 3-17% on the inverse at N≥256, both vs pffft SIMD** (which runs an unscaled backward transform — strictly less work than our normalized inverse). Everything else wins: complex FFT beats pffft SIMD at every size (Experiment 58), forward real FFT beats it at N≤256 and fftw-js everywhere (Experiment 59), inverse real FFT beats it at N≤128 and fftw-js everywhere (Experiment 60).

**Why pffft SIMD wins**: 4-wide f32 butterflies in a split-re/im internal format — complex multiplies are pure mul/add with zero lane shuffles at 100% lane utilization, and its radix-4/5 decomposition takes roughly half the memory passes of a radix-2 Stockham.

**The path (Experiment 58)**: a radix-4 split-format Stockham core (fused radix-2 stage pairs, shuffle-free generic stage, 4-different-twiddle final stage). ~~Isolated probe~~ → **DONE: integrated into `fft_split_native_f32.wat`** — complex FFT now beats pffft SIMD at every size (+1-34% at N≥32; interleaved wins N=16). Remaining work:

1. ~~Productionize the radix-4 split core in `fft_split_native_f32.wat`~~ DONE (native inverse included; see Experiment 58 integration notes)
2. Give the interleaved module the same core by folding deinterleave/reinterleave shuffles into the first/last stages (pffft does exactly this in ordered mode)
3. ~~Rebuild the real FFT on the new core~~ **DONE both directions**: forward (Experiment 59, `rfft_split`) roughly doubled throughput at N≥128 via a fused deinterleaving first stage (radix-8 for odd log2(M)), parity-routed ping-pong across three buffers (zero copy-back), and a split-format SIMD post-process. Inverse (Experiment 60, `irfft_split`) mirrored it: fused SIMD pre-process with 1/N folded in, B↔C ping-pong, final s=1 stage fused with the reinterleave; +43-83% at N≥128. ~~Fuse the post-process into the final butterfly stage~~ TRIED (Experiment 61): ships only at N=64 where it won +15-20% (single-pair loop, no carried registers); at N≥128 both a paired full fusion and a carry-free split fusion measured slower — the ~28 live v128 values spill, and the standalone post-process is a cheap streaming pass that's hard to beat. The last 1-5% forward / 3-17% inverse at large N needs a different idea (or is pffft's unscaled backward, on the inverse side); don't re-attempt naive fusion
4. Reclaim the copy-back pass on odd-stage sizes of the complex API (32/64/512/1024/8192 lose ~10-20% to it; the rfft path already avoids it via parity routing)

Open opportunities (smaller wins):

- ~~**Complex f32 module small-N dispatch**~~: probed in Experiment 54 - its radix-4 single-lane codelets WIN on M5 (+34-47% vs the loop); no change needed. The Experiment 53 loss was specific to the radix-2 dual-complex DIT codelet design.
- ~~**Radix-4-style n=32 codelet for the real module**~~: DONE in Experiment 56 - a packed dual-16 radix-4 codelet (even/odd DIT halves ride in the previously wasted upper v128 lanes, zero deinterleave shuffles) beats the loop by +55-84% in isolation; real N=64 jumped +25% forward / +26% inverse.
- **Packed n=32 codelet for the complex f32 module**: the Experiment 56 codelet design should port directly (write-to-0 variant + fused 1/N inverse); complex N=32 still runs on the loop. Untracked in competitor benches, so a small win.
- **Memory-staged n=64 codelet**: the lane-packing trick is used up at n=32; an n=64 codelet needs staging through memory between stages. N=128 (weakest margin, +4%) is the size that would benefit.
- ~~**Native inverse for the complex f32 `ifft`**~~: DONE in Experiment 55 - flipped-sign-mask port of Experiment 52 plus inverse n=8/16 codelets; ifft gained +13-22% and now matches forward fft throughput exactly (benchmark: `npm run bench:ifft32`).
- **Periodic re-baselining**: two M5 findings (Experiments 47, 53) reversed old-hardware conclusions, and Experiment 57 reversed the competitive picture entirely; re-run probes when hardware changes and audit competitor builds (`exports` maps!) when adding libraries.
- **f64 twiddle precision**: the accuracy report (below) shows the f64 modules plateau ~4-5 decimal digits short of f64 precision; more accurate twiddle generation is the identified fix.

---

## Measurement & Accuracy Tooling (2026-07-06)

New instrumentation so experiments are judged against measured noise instead of eyeballed 2s runs:

- **Statistical bench harness** (`benchmarks/lib/harness.js`): all 7 Node bench files now share it. Warmup + 10 batch-calibrated ~150ms samples per benchmark; reports median ops/s with a ±CV column; inputs are seeded (mulberry32) so runs are reproducible. Every run persists JSON to `benchmarks/results/<benchId>.latest.json` with git/machine metadata; `--save-baseline` writes a baseline copy.
- **Noise-aware diff** (`npm run bench:diff`, `scripts/bench-diff.js`): compares baseline vs latest, flags deltas only when |delta| > max(2%, 3× combined CV). Caveat found during validation: cross-process runs of identical code swung up to -13% at small N (N=64/128 split rfft) despite 0.1% within-run CV (thermal/code-layout); confirm small-N deltas with a second run pair.
- **Accuracy diagnostics** (`npm run accuracy`, `tools/accuracy_report.js`): max-rel/rms-rel error vs f64 reference DFT for every module × transform × size, plus a `quality` column (max-rel / (eps·√log₂N)) that should stay flat with N. `tests/accuracy.test.js` asserts thresholds from the same measurement code; `tests/per_bin_f32.test.js` extends per-bin validation to the f32 modules (the test class that would have caught the historical rfft_32 bins-9-15 bug, now covering the flagship split module). Both are part of `test:all`.

**Identified opportunity — f64 twiddle precision**: the f32 modules are numerically near-optimal (quality 0.3-3), but the f64 modules (`fft_combined`, `fft_real_combined`) plateau at max-rel ~5e-11 for N≥32 — quality ~65,000-175,000, i.e. 4-5 orders of magnitude above f64 eps. Exception: `fft_combined` N=16 and `fft_real_combined` N=32 hit true f64 precision (~4e-15), so those paths use exact/hardcoded twiddles. Root cause is almost certainly the Taylor-series trig in `precompute_twiddles` (fine for f32, limiting for f64). More accurate twiddle generation (higher-order Taylor, argument reduction, or hardcoded tables) would gain ~4 decimal digits of f64 accuracy; if fixed, tighten `MAX_REL.f64` in `tests/accuracy.test.js`.

---

## Quick Start for Contributors

1. **Read experiment log first** - Learn from what worked and failed
2. **Check completed priorities** - Don't duplicate effort
3. **Codelets must earn their place** - On M5 the Stockham loop beats DIT codelets at n>=16 (Experiment 53); isolate and A/B a core before hand-unrolling it
4. **Test thoroughly** - FFT permutation semantics are subtle
5. **Benchmark before/after** - V8 is already highly optimized

---

## Files Created During Optimization

| File                                  | Purpose                                               |
| ------------------------------------- | ----------------------------------------------------- |
| `modules/fft_combined.wat`            | Auto-dispatch radix-2/4                               |
| `modules/fft_stockham_f32_dual.wat`   | f32 dual-complex FFT                                  |
| `modules/fft_real_f32_dual.wat`       | f32 dual-complex rfft                                 |
| `modules/fft_real_combined.wat`       | Combined rfft with codelets                           |
| `modules/fft_split_native_f32.wat`    | Radix-4 split-format complex FFT + real FFT (fastest) |
| `tools/codelet_generator.js`          | DAG-based codelet generator                           |
| `tools/generate-dit-codelet.js`       | DIT codelet generator                                 |
| `tools/generate-radix4-32-codelet.js` | Packed dual-16 radix-4 n=32 codelets (Experiment 56)  |
