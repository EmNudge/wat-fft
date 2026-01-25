# Performance Analysis Command

Analyze wat-fft performance, identify gaps vs competitors, and optionally implement optimizations.

## Arguments

- `--implement` or `-i`: After analysis, implement the top-priority optimization
- `--quick` or `-q`: Skip benchmarks, use cached results from docs
- No args: Full analysis with fresh benchmarks

## Quick Start

1. **Build**: `npm run build`
2. **Run main benchmark**: `npm run bench:rfft32` (f32 RFFT vs fftw-js)
3. **Analyze results** and propose optimizations

## Key Context (Don't Re-read Unless Needed)

**Current Status** (from OPTIMIZATION_PLAN.md):

- f32 RFFT: Beats fftw-js at N≥256 (+13-49%), loses at N=64 (-7%), N=128 (-3%)
- Complex FFT: Beats fft.js by +40-90% at all sizes
- f64 RFFT: Loses to fftw-js (expected - f64x2 vs f32x4 SIMD)

**What Already Failed** (from EXPERIMENT_LOG.md):

- Depth-first recursive: -55% (call overhead)
- Large codelets (N>32): Register spills (300+ locals)
- Manual function inlining: No gain (V8 already inlines)
- Hierarchical beyond N=1024: I-cache thrashing

**Key Constraints**:

- Optimal codelet ceiling: N=1024
- Keep codelets small: N ≤ 16 to avoid register spills
- f32 gives 2x SIMD throughput vs f64

## Analysis Workflow

### Step 1: Run Benchmarks (skip with --quick)

```bash
npm run build && npm run bench:rfft32
```

Focus on f32 RFFT - this is where we compete with fftw-js.

### Step 2: Identify Gaps

Look for sizes where we lose. Currently:

- N=64: ~-7% vs fftw-js
- N=128: ~-3% vs fftw-js

### Step 3: Propose Optimizations

For each gap, propose a fix with:

- **Hypothesis**: Why we're slow
- **Approach**: Specific code changes
- **Expected gain**: Based on similar experiments
- **Risk**: What could go wrong

### Step 4: Implement (if --implement flag)

After analysis, implement the top optimization:

1. Create a new experiment branch
2. Modify the relevant WAT module
3. Run `npm run build && npm run bench:rfft32`
4. Compare before/after
5. If successful:
   - Add entry to EXPERIMENT_LOG.md
   - Update OPTIMIZATION_PLAN.md if metrics changed
   - Commit with descriptive message

## Output Format

```markdown
# Performance Analysis

## Benchmark Results

[Table of current performance]

## Gap Analysis

[Where we lose and by how much]

## Top Optimization Opportunity

**Target**: [Size and gap]
**Hypothesis**: [Why we're slow]
**Approach**: [Specific changes]
**Expected Gain**: [Estimate]
**Files to Modify**: [List]

## Implementation Plan

[Step-by-step if --implement]
```

## Implementation Guidelines

When implementing optimizations:

1. **Measure first**: Get baseline numbers before changing anything
2. **Change one thing**: Don't combine multiple optimizations
3. **Test correctness**: Run `npm test` after changes
4. **Benchmark thoroughly**: Run benchmark 2-3 times for stable results
5. **Document everything**: Update EXPERIMENT_LOG.md with results

### Common Optimization Patterns

**Fused codelets** (Experiments 8, 15, 16b):

- Combine FFT + post-processing into single function
- Eliminate function call overhead
- Hardcode twiddle factors

**Dual-complex processing** (Experiments 13, 14, 20, 21):

- Process 2 f32 complex numbers per v128
- Requires restructuring loops and shuffles
- Best gains at larger N

**SIMD threshold tuning** (Experiment 19):

- Simple one-line changes can have big impact
- Lower thresholds to use SIMD at smaller N

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
