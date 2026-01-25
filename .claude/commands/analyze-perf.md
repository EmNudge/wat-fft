# Performance Analysis Command

Analyze wat-fft performance benchmarks, identify where we lose to competitors, and suggest optimization strategies.

## Your Task

You are a performance optimization expert analyzing the wat-fft WebAssembly FFT library. Your goal is to:

1. **Understand current performance** by running benchmarks
2. **Identify gaps** where competitors (fftw-js, fft.js) beat us
3. **Analyze root causes** using profiling tools
4. **Propose concrete optimizations** based on experiment history

## Documentation to Read First

Read these files in order to understand context:

1. **docs/OPTIMIZATION_PLAN.md** - Overview of what worked/failed, current status
2. **docs/optimization/EXPERIMENT_LOG.md** - Detailed experiment history (check before suggesting something already tried)
3. **docs/optimization/COMPLETED_PRIORITIES.md** - What's already implemented
4. **docs/optimization/FUTURE_PRIORITIES.md** - Research done but not implemented
5. **benchmarks/README.md** - How to run benchmarks and interpret results

## Available Tools

### Benchmarking (run `npm run build` first!)

| Command                | What it measures                                |
| ---------------------- | ----------------------------------------------- |
| `npm run bench`        | Complex FFT (f64) vs fft.js, fft-js, kissfft-js |
| `npm run bench:rfft`   | Real FFT (f64) vs fftw-js, kissfft-js           |
| `npm run bench:f32`    | Complex FFT (f32) vs fft.js                     |
| `npm run bench:rfft32` | Real FFT (f32) vs fftw-js - **main competitor** |

### Debug Tools (in tools/ directory)

| Tool                       | Purpose                         | Command                            |
| -------------------------- | ------------------------------- | ---------------------------------- |
| `stockham_reference.js`    | JS reference with stage logging | `npm run debug:ref -- 16 -v`       |
| `index_visualizer.js`      | Show read/write patterns        | `npm run debug:index -- 32 verify` |
| `wasm_compare.js`          | Compare WASM vs JS vs DFT       | `npm run debug:stockham -- multi`  |
| `butterfly_tester.js`      | Test butterfly math             | `npm run test:butterfly`           |
| `permutation_validator.js` | Validate data flow              | `npm run debug:perm -- 16`         |

### V8 Profiling

```bash
# Generate V8 profile
node --prof benchmarks/rfft_f32_dual.bench.js
node --prof-process isolate-*.log > profile.txt

# Flamegraph with 0x
npx 0x benchmarks/rfft_f32_dual.bench.js
```

## Analysis Workflow

1. **Build the project**: `npm run build`

2. **Run benchmarks** to get current performance data:
   - `npm run bench:rfft32` (our main competition is fftw-js for real FFT)
   - `npm run bench` (complex FFT vs fft.js)

3. **Identify problem sizes**: Note which N values we lose at

4. **Read experiment history**: Check if the optimization was already tried in EXPERIMENT_LOG.md

5. **Profile if needed**: Use V8 profiling to find bottlenecks

6. **Cross-reference with FFTW_ANALYSIS.md**: Understand why FFTW is fast

7. **Propose optimizations** with:
   - Specific hypothesis
   - Which sizes would improve
   - Implementation approach
   - Expected gains
   - Risks (check what failed before)

## Key Constraints

- **Optimal codelet ceiling is N=1024** - Beyond this, simple loops beat hierarchical composition
- **Keep codelets small (N <= 16)** - Large codelets cause register spills
- **V8 already inlines small functions** - Manual inlining rarely helps
- **f32 gives ~2x SIMD throughput** - This is fftw-js's main advantage

## Output Format

Provide a structured analysis with:

1. **Current Performance Summary** - Table of benchmark results
2. **Gap Analysis** - Where we lose and by how much
3. **Root Cause Analysis** - Why we lose at those sizes
4. **Optimization Recommendations** - Ranked by expected impact
5. **Implementation Plan** - Concrete next steps

Focus on actionable insights, not general advice.
