# FFT Optimization Plan: Closing the Gap with FFTW

## Executive Summary

FFTW-js is ~2x faster than our implementation due to:

1. **Pre-optimized codelets** for sizes 2-64
2. **Hierarchical decomposition** using optimal codelet sizes
3. **FMA (fused multiply-add)** reducing instruction count
4. **Cache-aware memory access** patterns

This document outlines a phased approach to implement these optimizations with proper tooling and testing infrastructure.

---

## Phase 1: Testing & Benchmarking Infrastructure

### 1.1 Correctness Test Suite

Before optimizing, we need robust correctness tests that will catch regressions.

**Tests to create:**

- [ ] Property-based tests for all FFT sizes (2-8192)
- [ ] Round-trip tests: `ifft(fft(x)) ≈ x`
- [ ] Parseval's theorem: `sum(|x|²) = sum(|X|²)/N`
- [ ] Known-value tests (impulse, sine waves, DC)
- [ ] Linearity: `fft(ax + by) = a*fft(x) + b*fft(y)`
- [ ] Shift theorem: time shift = phase rotation in frequency
- [ ] Comparison against reference implementation (fft.js)

**File:** `tests/fft.correctness.test.js`

### 1.2 Performance Regression Suite

Automated benchmarks that run on every change.

**Metrics to track:**

- ops/sec for each size (64, 256, 1024, 4096)
- Memory bandwidth utilization
- Cache miss rates (if measurable)
- Comparison vs baseline and competitors

**File:** `benchmarks/regression.bench.js`

### 1.3 Profiling Tools

**Tools to create:**

- [ ] Instruction count analyzer (count WASM ops)
- [ ] Memory access pattern visualizer
- [ ] Twiddle factor reuse analyzer
- [ ] Butterfly operation counter

**File:** `tools/profiler.js`

---

## Phase 2: Codelet Generation System

### 2.1 Codelet Generator

Create a tool that generates optimal WAT code for small FFT sizes.

**Approach:**

```
Input: FFT size N (2, 4, 8, 16, 32, 64)
Output: Optimized WAT function for that size
```

**Optimizations to apply:**

1. Eliminate all loops (fully unrolled)
2. Precompute all twiddle factors as constants
3. Minimize temporary variables
4. Reorder operations for instruction pipelining
5. Use FMA where beneficial

**Example output for N=8:**

```wat
(func $fft8 (param $base i32)
  ;; All 8 inputs loaded, all butterflies unrolled
  ;; Twiddles are inline constants
  ;; ~56 adds, ~24 muls for complex 8-point FFT
)
```

**File:** `tools/codelet_generator.js`

### 2.2 Codelet Sizes to Generate

| Size | Radix | Multiplications | Additions | Priority |
| ---- | ----- | --------------- | --------- | -------- |
| 2    | 2     | 0               | 4         | High     |
| 4    | 4     | 0               | 16        | High     |
| 8    | 2×4   | 4               | 52        | High     |
| 16   | 4×4   | 24              | 148       | High     |
| 32   | 2×16  | 88              | 388       | Medium   |
| 64   | 4×16  | 264             | 964       | Medium   |

### 2.3 Codelet Verification

Each generated codelet must pass:

- [ ] Correctness test against reference
- [ ] Performance test (must beat generic loop)
- [ ] Code size check (not too large)

**File:** `tests/codelet.test.js`

---

## Phase 3: Algorithm Improvements

### 3.1 Split-Radix Algorithm

Current: Pure radix-2 (1 butterfly type)
Target: Split-radix (mixed radix-2 and radix-4)

**Benefits:**

- ~33% fewer multiplications than radix-2
- Better instruction-level parallelism

**Implementation steps:**

1. [ ] Implement radix-4 butterfly
2. [ ] Implement split-radix decomposition
3. [ ] Create hybrid that uses radix-4 when N is divisible by 4

**Theoretical improvement:** ~20% faster

### 3.2 Radix-4 Stockham

Pure radix-4 for power-of-4 sizes (4, 16, 64, 256, 1024, 4096).

**Benefits:**

- Twiddles W_N^0 = 1, W_N^(N/4) = -i are trivial
- 25% fewer stages than radix-2
- Better for SIMD (4-way operations)

**File:** `modules/fft_stockham_radix4.wat`

### 3.3 Mixed-Radix Support

For sizes like 12, 24, 48 (products of 2, 3, 4):

- Radix-2 kernel
- Radix-3 kernel
- Radix-4 kernel
- Combine hierarchically

---

## Phase 4: Memory Optimization

### 4.1 Cache-Oblivious Recursion

Instead of iterative stages, use recursive decomposition that naturally fits cache.

```
fft(x, n):
  if n <= CACHE_THRESHOLD:
    use_codelet(x, n)
  else:
    fft(even, n/2)
    fft(odd, n/2)
    combine(even, odd, n)
```

### 4.2 Twiddle Factor Optimization

Current: Precompute all N/2 twiddles
Better:

- Sizes ≤64: inline constants in codelets
- Sizes >64: compute on-the-fly with recurrence

**Twiddle recurrence:**

```
W[k+1] = W[k] * W[1]  (one complex multiply)
```

### 4.3 In-Place vs Out-of-Place

Analyze when in-place (Gentleman-Sande DIF) is better than out-of-place (Stockham).

---

## Phase 5: SIMD Deep Optimization

### 5.1 f32x4 Dual-Complex Operations

Pack 2 complex f32 numbers per v128 register.

**Current:** 1 complex per SIMD op
**Target:** 2 complex per SIMD op (requires algorithm restructuring)

### 5.2 Radix-4 SIMD Butterfly

A radix-4 butterfly naturally processes 4 values, perfect for f32x4.

```wat
;; Process 4 complex values in 2 v128 registers
;; Input: [x0, x1] [x2, x3] as v128 pairs
;; Output: [X0, X1] [X2, X3] with full SIMD utilization
```

### 5.3 Memory Coalescing

Ensure consecutive memory accesses for SIMD loads/stores.

---

## Tooling To Build

### Tool 1: Codelet Generator (`tools/codelet_generator.js`)

```javascript
// Usage: node tools/codelet_generator.js --size 8 --radix 2 --output modules/codelets/
// Generates: fft8.wat with fully unrolled, optimized code

class CodeletGenerator {
  generateFFT(size, options) { ... }
  optimizeForFMA(ast) { ... }
  reorderForPipelining(ast) { ... }
  emitWAT(ast) { ... }
}
```

### Tool 2: Performance Comparator (`tools/perf_compare.js`)

```javascript
// Usage: node tools/perf_compare.js --baseline main --candidate feature-branch
// Output: Performance diff table with statistical significance

async function comparePerformance(baseline, candidate, sizes) {
  // Run both, compute confidence intervals
  // Report: "N=1024: +15% ± 2% (p < 0.01)"
}
```

### Tool 3: Operation Counter (`tools/op_counter.js`)

```javascript
// Usage: node tools/op_counter.js modules/fft_stockham.wat
// Output:
//   f64.mul: 1,234
//   f64.add: 2,345
//   v128.load: 567
//   Total ops per butterfly: 12.3

function countOperations(watFile) {
  // Parse WAT, count by opcode type
}
```

### Tool 4: Memory Access Analyzer (`tools/mem_analyzer.js`)

```javascript
// Instrument WASM to log all memory accesses
// Visualize access patterns, detect cache-unfriendly patterns
```

---

## Test Suite Structure

```
tests/
├── correctness/
│   ├── fft.roundtrip.test.js      # ifft(fft(x)) = x
│   ├── fft.parseval.test.js       # Energy preservation
│   ├── fft.linearity.test.js      # Linearity property
│   ├── fft.shift.test.js          # Shift theorem
│   └── fft.reference.test.js      # Compare to fft.js
├── codelets/
│   ├── codelet.n2.test.js         # 2-point correctness
│   ├── codelet.n4.test.js         # 4-point correctness
│   ├── codelet.n8.test.js         # 8-point correctness
│   └── ...
├── performance/
│   ├── perf.regression.test.js    # Must not regress
│   ├── perf.scaling.test.js       # O(N log N) verification
│   └── perf.memory.test.js        # Memory bandwidth
└── integration/
    ├── real_fft.test.js           # Real FFT specific
    └── streaming.test.js          # Repeated FFT calls
```

---

## Migration Checklist

For each optimization, follow this checklist:

### Pre-Implementation

- [ ] Write correctness tests for affected code paths
- [ ] Establish baseline performance numbers
- [ ] Document expected improvement (with citation if applicable)

### Implementation

- [ ] Implement in isolated module
- [ ] Run correctness tests
- [ ] Run performance benchmarks
- [ ] Compare operation counts

### Post-Implementation

- [ ] All tests pass
- [ ] Performance improved (or explain why not)
- [ ] Code reviewed
- [ ] Documentation updated
- [ ] Benchmark results recorded

---

## Expected Performance Gains

| Optimization      | Expected Gain   | Effort | Priority |
| ----------------- | --------------- | ------ | -------- |
| N=8 codelet       | +15% for N≤64   | Low    | 1        |
| N=16 codelet      | +10% for N≤256  | Low    | 2        |
| Radix-4 Stockham  | +20% overall    | Medium | 3        |
| Split-radix       | +25% overall    | High   | 4        |
| SIMD dual-complex | +30% for f32    | High   | 5        |
| Cache-oblivious   | +10% for N>1024 | Medium | 6        |

**Target:** Match or exceed FFTW-js performance within 10%.

---

## References

1. FFTW Paper: "The Design and Implementation of FFTW3" (Frigo & Johnson, 2005)
2. Split-Radix: "On Computing the Split-Radix FFT" (Sorensen et al., 1986)
3. Stockham: "High-Speed Convolution and Correlation" (Stockham, 1966)
4. SIMD FFT: "Faster FFTs via SIMD" (Franz, 2020)

---

## Next Steps

1. **Immediate:** Create `tests/correctness/` test suite
2. **Week 1:** Build codelet generator, generate N=8,16 codelets
3. **Week 2:** Implement radix-4 Stockham
4. **Week 3:** Benchmark and iterate
