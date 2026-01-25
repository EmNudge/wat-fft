# Implementation Phases

Roadmap for future optimization work.

## Phase 1: Testing & Benchmarking Infrastructure

### 1.1 Correctness Test Suite

**Tests to create:**

- Property-based tests for all FFT sizes (2-8192)
- Round-trip tests: `ifft(fft(x)) ≈ x`
- Parseval's theorem: `sum(|x|²) = sum(|X|²)/N`
- Known-value tests (impulse, sine waves, DC)
- Linearity: `fft(ax + by) = a*fft(x) + b*fft(y)`
- Shift theorem: time shift = phase rotation in frequency
- Comparison against reference implementation

### 1.2 Performance Regression Suite

**Metrics to track:**

- ops/sec for each size (64, 256, 1024, 4096)
- Memory bandwidth utilization
- Comparison vs baseline and competitors

### 1.3 Profiling Tools

- Instruction count analyzer
- Memory access pattern visualizer
- Twiddle factor reuse analyzer

---

## Phase 2: Codelet Generation System

### 2.1 Codelet Generator

Generate optimal WAT code for small FFT sizes.

**Optimizations to apply:**

1. Eliminate all loops (fully unrolled)
2. Precompute all twiddle factors as constants
3. Minimize temporary variables
4. Reorder operations for instruction pipelining
5. Use FMA where beneficial

### 2.2 Codelet Sizes

| Size | Radix | Multiplications | Additions | Priority |
| ---- | ----- | --------------- | --------- | -------- |
| 2    | 2     | 0               | 4         | High     |
| 4    | 4     | 0               | 16        | High     |
| 8    | 2×4   | 4               | 52        | High     |
| 16   | 4×4   | 24              | 148       | High     |
| 32   | 2×16  | 88              | 388       | Medium   |
| 64   | 4×16  | 264             | 964       | Medium   |

---

## Phase 3: Algorithm Improvements

### 3.1 Split-Radix Algorithm

Target: Split-radix (mixed radix-2 and radix-4)

**Benefits:**

- ~33% fewer multiplications than radix-2
- Better instruction-level parallelism

### 3.2 Radix-4 Stockham

Pure radix-4 for power-of-4 sizes (4, 16, 64, 256, 1024, 4096).

**Benefits:**

- Trivial twiddles: W_N^0 = 1, W_N^(N/4) = -i
- 25% fewer stages than radix-2
- Better for SIMD (4-way operations)

### 3.3 Mixed-Radix Support

For sizes like 12, 24, 48 (products of 2, 3, 4):

- Radix-2, Radix-3, Radix-4 kernels
- Combine hierarchically

---

## Phase 4: Memory Optimization

### 4.1 Cache-Oblivious Recursion

Use recursive decomposition that naturally fits cache.

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

- Sizes <= 64: inline constants in codelets
- Sizes > 64: compute on-the-fly with recurrence

**Twiddle recurrence:**

```
W[k+1] = W[k] * W[1]  (one complex multiply)
```

### 4.3 In-Place vs Out-of-Place

Analyze when in-place (Gentleman-Sande DIF) beats out-of-place (Stockham).

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

### Tool 1: Codelet Generator

```javascript
// Usage: node tools/codelet_generator.js --size 8 --radix 2
class CodeletGenerator {
  generateFFT(size, options) { ... }
  optimizeForFMA(ast) { ... }
  reorderForPipelining(ast) { ... }
  emitWAT(ast) { ... }
}
```

### Tool 2: Performance Comparator

```javascript
// Usage: node tools/perf_compare.js --baseline main --candidate feature-branch
// Output: "N=1024: +15% ± 2% (p < 0.01)"
```

### Tool 3: Operation Counter

```javascript
// Usage: node tools/op_counter.js modules/fft_stockham.wat
// Output:
//   f64.mul: 1,234
//   f64.add: 2,345
//   v128.load: 567
```
