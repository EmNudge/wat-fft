# Performance Analysis Command

Analyze wat-fft performance and identify opportunities for continuous improvement.

## Arguments

- `--implement` or `-i`: After analysis, implement the top-priority optimization
- `--quick` or `-q`: Skip benchmarks, use cached results from docs
- No args: Full analysis with fresh benchmarks

## Quick Start

1. **Build**: `npm run build`
2. **Run benchmarks**: `npm run bench:rfft32` (f32 RFFT) or `npm run bench` (complex FFT)
3. **Analyze results** and identify improvement opportunities

## Current Status

**We beat all competitors.** The focus now is continuous improvement:

- f32 RFFT: +5-48% faster than fftw-js at all sizes N≥128, tied at N=64
- Complex FFT: +40-90% faster than fft.js at all sizes
- 26 optimization experiments completed (see EXPERIMENT_LOG.md)

## Key Constraints (from experiments)

- Optimal codelet ceiling: N=1024 (I-cache thrashing beyond)
- Keep codelets small: N ≤ 16 to avoid register spills (300+ locals)
- f32 gives 2x SIMD throughput vs f64
- V8 already inlines small functions (manual inlining rarely helps)
- Depth-first recursive is slower (-55% due to call overhead)

## Analysis Workflow

### Step 1: Run Benchmarks (skip with --quick)

```bash
npm run build && npm run bench:rfft32
```

### Step 2: Identify Improvement Opportunities

Look for opportunities in these categories:

**Performance improvements:**

- Sizes with lower relative throughput (even if winning)
- High variance between runs (unstable hot paths)
- Sizes not yet optimized (N > 4096, non-power-of-2)

**Code quality improvements:**

- Repeated patterns that could be unified
- Dead code or unused functions
- Missing test coverage for edge cases

**Feature additions:**

- Inverse FFT optimization
- Batched/streaming FFT for real-time use
- Additional precisions or formats

### Step 3: Propose Improvements

For each opportunity, document:

- **Target**: What to improve
- **Hypothesis**: Why current implementation is suboptimal
- **Approach**: Specific code changes
- **Expected gain**: Based on similar experiments
- **Risk**: What could regress

### Step 4: Implement (if --implement flag)

1. Record baseline numbers
2. Modify the relevant WAT module
3. Run `npm run build && npm test` (verify correctness)
4. Run benchmarks 2-3 times for stable results
5. If successful:
   - Add entry to EXPERIMENT_LOG.md
   - Update OPTIMIZATION_PLAN.md if metrics changed
   - Commit with descriptive message

## Output Format

```markdown
# Performance Analysis

## Benchmark Results

[Table of current performance with ops/sec]

## Improvement Opportunities

### High Priority

[Opportunities with clear path to measurable gains]

### Medium Priority

[Opportunities requiring research or with uncertain gains]

### Low Priority / Future Work

[Nice-to-haves, out-of-scope items]

## Top Recommendation

**Target**: [What to improve]
**Hypothesis**: [Why it's suboptimal]
**Approach**: [Specific changes]
**Expected Gain**: [Estimate]
**Files to Modify**: [List]

## Implementation Plan

[Step-by-step if --implement]
```

## Implementation Guidelines

1. **Measure first**: Get baseline numbers before changing anything
2. **Change one thing**: Don't combine multiple optimizations
3. **Test correctness**: Run `npm test` after changes
4. **Benchmark thoroughly**: Run 2-3 times for stable results
5. **Document everything**: Update EXPERIMENT_LOG.md with results

### Proven Optimization Patterns

**Fused codelets** (Experiments 8, 15, 16b):

- Combine FFT + post-processing into single function
- Eliminate function call overhead
- Hardcode twiddle factors

**Dual-complex processing** (Experiments 13, 14, 20, 21):

- Process 2 f32 complex numbers per v128
- Requires restructuring loops and shuffles
- Best gains at larger N

**Unrolled post-processing** (Experiments 23, 25):

- Fully unroll small loops with inline v128.const twiddles
- Eliminates loop overhead and memory loads
- Limited to ~15 iterations before I-cache pressure

### Files Reference

| File                                  | Purpose                      |
| ------------------------------------- | ---------------------------- |
| `modules/fft_real_f32_dual.wat`       | Main f32 RFFT implementation |
| `modules/fft_stockham_f32_dual.wat`   | f32 complex FFT              |
| `benchmarks/rfft_f32_dual.bench.js`   | RFFT benchmark               |
| `docs/optimization/EXPERIMENT_LOG.md` | Record results here          |

## Profiling Commands

```bash
# V8 profile
node --prof benchmarks/rfft_f32_dual.bench.js
node --prof-process isolate-*.log > profile.txt

# Quick size-specific test
node -e "
const fft = require('./dist/fft_real_f32_dual.js');
const N = 64;
for(let i=0; i<1000000; i++) fft.rfft(new Float32Array(N));
"
```

## Ideas for Future Exploration

- **Larger N (8192+)**: May need different algorithm (split-radix, Bluestein)
- **Non-power-of-2**: Chirp-Z or mixed-radix approaches
- **Multi-threading**: SharedArrayBuffer + workers for parallel FFT
- **IFFT optimization**: Currently uses same code path as forward FFT
- **Memory pooling**: Reduce allocation overhead for repeated calls
