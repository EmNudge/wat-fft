# Project Instructions

## Before Starting New Work

Read the README.md to understand the project context, structure, and conventions.

## Documentation Hierarchy

For optimization work, read docs in this order:

1. **[docs/OPTIMIZATION_PLAN.md](../docs/OPTIMIZATION_PLAN.md)** - Start here. Overview of what worked/failed, current status vs competitors
2. **[docs/optimization/EXPERIMENT_LOG.md](../docs/optimization/EXPERIMENT_LOG.md)** - Detailed experiment history. Check before attempting similar optimizations
3. **[docs/optimization/COMPLETED_PRIORITIES.md](../docs/optimization/COMPLETED_PRIORITIES.md)** - What's already implemented
4. **[benchmarks/README.md](../benchmarks/README.md)** - How to measure performance
5. **[tools/README.md](../tools/README.md)** - Debug tools for FFT development

## Performance Work

**Before optimizing:**

- Check EXPERIMENT_LOG.md - the optimization may have been tried before
- Key lessons: V8 inlines small functions, hierarchical codelets fail above N=1024, depth-first recursion is slower

**Benchmarking:**

- Always run `npm run build` first
- Use `npm run bench` (complex) or `npm run bench:rfft32` (real f32) for competitor comparison
- Record before/after results with specific sizes

**After changes:**

- Document in EXPERIMENT_LOG.md with hypothesis, results, and analysis
- Update OPTIMIZATION_PLAN.md status if completing a priority
- Update README.md performance tables if top-line metrics change

## Keeping Documentation in Sync

If changes affect the README (new features, APIs, build steps), update it accordingly.

## WebAssembly Tooling

Prefer `wasm-tools` over WABT:

- `wasm-tools parse` instead of `wat2wasm`
- `wasm-tools print` instead of `wasm2wat`
- `wasm-tools validate` instead of `wasm-validate`
