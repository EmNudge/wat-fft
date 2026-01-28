# Scripts

Code generation and CI utility scripts for wat-fft development.

## Scripts

### Code Generators

These scripts generate optimized WAT code with precomputed twiddle factors:

| Script                        | Purpose                                       |
| ----------------------------- | --------------------------------------------- |
| `gen_fft_1024.js`             | Generates `$fft_512_at` and `$fft_1024` code  |
| `generate_fused_fft64.js`     | Generates fully fused FFT-64 codelet          |
| `generate_fused_fft64_fma.js` | FFT-64 variant using FMA (fused multiply-add) |

**Usage:**

```bash
node scripts/gen_fft_1024.js > output.wat
node scripts/generate_fused_fft64.js > fft64.wat
```

Generated code is typically pasted into `modules/*.wat` files during optimization work.

### CI Utilities

| Script                | Purpose                                  |
| --------------------- | ---------------------------------------- |
| `check-benchmarks.js` | Verifies wat-fft beats competitors in CI |

**Usage:**

```bash
# Run after browser benchmarks generate JSON output
npm run bench:browser:ci
node scripts/check-benchmarks.js
```

Exit codes:

- `0` - All benchmarks passed (wat-fft wins or ties)
- `1` - Regression detected (competitor beat wat-fft)

## When to Use

- **Optimization work**: Use generators to create new codelets with different radix sizes
- **CI debugging**: Run `check-benchmarks.js` locally to debug CI failures
- **Experimentation**: Modify generators to test different twiddle computation approaches

## Related

- [tools/README.md](../tools/README.md) - Debug and analysis tools
- [benchmarks/README.md](../benchmarks/README.md) - Benchmark infrastructure
- [docs/optimization/EXPERIMENT_LOG.md](../docs/optimization/EXPERIMENT_LOG.md) - Results from using these generators
