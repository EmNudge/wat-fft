# Project Instructions

## Before Starting New Work

Read the README.md to understand the project context, structure, and conventions.

## Keeping Documentation in Sync

If you make changes that would cause the README to be inaccurate (new features, changed APIs, modified build steps, etc.), update the README.md accordingly.

## WebAssembly Tooling

Prefer `wasm-tools` over WABT tools:

- Use `wasm-tools parse` instead of `wat2wasm`
- Use `wasm-tools print` instead of `wasm2wat`
- Use `wasm-tools validate` instead of `wasm-validate`

## Optimization Workflow

When exploring performance optimizations, always reference [docs/OPTIMIZATION_PLAN.md](../docs/OPTIMIZATION_PLAN.md):

1. **Before starting**: Check the plan for existing ideas, priorities, and lessons from past experiments
2. **New ideas**: Add new optimization ideas to the appropriate priority section
3. **Experiments**: Document all optimization attempts in the "Optimization Experiment Log" section with:
   - Hypothesis
   - Implementation details
   - Benchmark results (before/after)
   - Analysis of why it worked or failed
4. **After completing**: Update the status of implemented optimizations (✅ Done, ❌ Failed, etc.)
5. **Top-line metrics**: If an optimization affects performance vs competitors (fftw-js, fft.js), update the README.md performance tables
