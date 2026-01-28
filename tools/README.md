# FFT Debug Tools

Tools for debugging Stockham and other FFT implementations.

## Quick Reference

| Tool                       | Purpose                         | Command                            |
| -------------------------- | ------------------------------- | ---------------------------------- |
| `stockham_reference.js`    | JS reference with stage logging | `npm run debug:ref -- 16 -v`       |
| `index_visualizer.js`      | Show read/write patterns        | `npm run debug:index -- 32 verify` |
| `wasm_compare.js`          | Compare WASM vs JS vs DFT       | `npm run debug:stockham -- multi`  |
| `butterfly_tester.js`      | Test butterfly math             | `npm run test:butterfly`           |
| `permutation_validator.js` | Validate data flow              | `npm run debug:perm -- 16`         |
| `lint-wasm-dead-code.js`   | Find dead code in WASM          | `npm run lint:wasm`                |
| `fft_split_f32_debug.js`   | Debug split-format f32 FFT      | `npm run debug:split`              |

## Usage

### Stage-by-Stage Reference

```bash
npm run debug:ref -- 16 -v        # Verbose output showing each stage
npm run debug:ref -- 32           # Quick correctness check
```

### Index Patterns

```bash
npm run debug:index -- 16 patterns   # Show read/write indices
npm run debug:index -- 32 verify     # Check stage coordination
npm run debug:index -- 16 trace 0    # Trace input[0] through stages
npm run debug:index -- 16 draw 0     # ASCII diagram of stage 0
```

### WASM Comparison

```bash
npm run debug:stockham -- compare 16 impulse   # Single test
npm run debug:stockham -- multi                # Test N=4,8,16,32,64
npm run debug:stockham -- twiddles 32          # Check twiddle factors
```

Input types: `impulse`, `ramp`, `alternating`, `sine`, `random`

### Permutation Validation

```bash
npm run debug:perm -- 16 validate   # Check all positions written once
npm run debug:perm -- 16 table      # Input->output contribution
npm run debug:perm -- 16 bitrev     # Compare to bit-reversal
```

### Split-Format FFT Debug

Interactive vitest-based tool for debugging the split-format f32 FFT implementation:

```bash
npm run debug:split   # Run with vitest (shows detailed output)
```

Compares output against fft.js reference at various sizes with verbose logging.

### WASM Dead Code Linter

Uses [Twiggy](https://rustwasm.github.io/twiggy/) to detect unreferenced code in WASM binaries.

```bash
npm run lint:wasm              # Basic check (warnings for secondary modules)
npm run lint:wasm -- --verbose # Show all modules and dead functions
npm run lint:wasm -- --strict  # Fail on any dead code
npm run lint:wasm -- --fix     # Show fix instructions
```

**Prerequisites**: Install Twiggy with `cargo install twiggy`

Primary modules (`fft_real_f32_dual.wasm`, `fft_combined.wasm`) must have zero dead code. Secondary modules show warnings only.

## Typical Debug Workflow

1. **Identify failing size**: `npm run debug:stockham -- multi`
2. **Check stage coordination**: `npm run debug:index -- 32 verify`
3. **Trace data flow**: `npm run debug:ref -- 32 -v`
4. **Compare outputs**: `npm run debug:stockham -- compare 32 impulse`
5. **Test butterfly math**: `npm run test:butterfly`

## Dead Code Removal Workflow

1. **Run lint**: `npm run lint:wasm -- --verbose --fix`
2. **Find the function**: `grep -n 'func $function_name' modules/*.wat`
3. **Verify not called**: `grep 'call $function_name' modules/*.wat`
4. **Remove and test**: Delete the function, `npm run build && npm test`
