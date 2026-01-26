This project is aimed to be the fastest implementation of the fft for all environments that support JavaScript. It is doing this by building it from scratch in webassembly.

Our README should be concise and convincing. We should generate docs so sessions have memory.
Docs should be generated in the docs folder. Individual docs should not get too large.
Always summarize for eseential data.

After making a big change, spin up a sub-agent to properly document the changes.

If attempting a complex task, spin up a sub-agent to investigate if there is a tool or process available to make this task simpler.

Always add new tests when you find a possible flaw. Use debug tools to better understand the problems and possible solutions.

Always attempt to automate a kind of testing or performance analysis into the regular flow of work. We should get deep rich automated signals for how to best optimize our programs.

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
- Run "npm run format" so we format our markdown appropriately

## Keeping Documentation in Sync

If changes affect the README (new features, APIs, build steps), update it accordingly.

## README Performance Tables and Graphs

When updating performance comparisons in the README:

- **Tables**: Only include the best competitor (the one closest to or beating us)
- **Graphs**: Include all competitors for full context
- **Remove from tables**: If we beat a competitor, remove them from the table (but keep in graph)
- Focus tables on the most meaningful comparison; graphs tell the full story

## WebAssembly Tooling

Prefer `wasm-tools` over WABT:

- `wasm-tools parse` instead of `wat2wasm`
- `wasm-tools print` instead of `wasm2wat`
- `wasm-tools validate` instead of `wasm-validate`
