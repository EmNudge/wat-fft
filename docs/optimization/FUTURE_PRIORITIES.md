# Future Optimization Priorities

Research completed but not yet implemented.

## Priority C: DAG-Based Codelet Optimization

**Expected**: +10-20% for codelets

Build a codelet generator that:

1. Constructs operation DAG from FFT algorithm
2. Applies CSE (common subexpression elimination)
3. Schedules for register pressure
4. Emits optimized WAT

**Key CSE opportunities:**

- Twiddle factors: W_N^k and W_N^{N-k} are conjugates
- Butterfly symmetry: a+b and a-b share inputs
- Real-data symmetry: Exploits conjugate pairs

**Complexity**: High

---

## Priority D: Depth-First Recursive FFT

**Expected**: +15-25% for N >= 1024

**Already tested (Experiment 10)**: Did NOT provide expected improvement.

- N=4096: **-55%** vs iterative
- N=8192: **-11%** (gap narrows at larger sizes)

**Root cause**: Function call overhead and bit-reversal cost outweigh cache locality benefits. The iterative Stockham algorithm avoids bit-reversal entirely.

**Conclusion**: Not worth pursuing for our target sizes (N <= 4096).

---

## Priority E: Register-Aware Scheduling

**Expected**: +5-10%

Schedule operations to minimize live variables using Sethi-Ullman style numbering. Target: keep live values <= 16 (typical register file size).

**Complexity**: High

---

## Priority K: Split-Radix Algorithm

**Expected**: +6-10%

Hybrid radix-2/radix-4 achieving lowest proven arithmetic count:

- DFT(N) = DFT(N/2) of even + two DFT(N/4) of interleaved odd
- Modified split-radix achieves ~6% fewer flops

**Trade-offs:**

- More complex recursion pattern
- We already have radix-4 SIMD, so gains are incremental
- At large sizes, memory bandwidth (not arithmetic) is the bottleneck

**Complexity**: High
**Priority**: Lower than f32 SIMD (already done)

---

## Priority L: Conjugate-Pair Split-Radix

**Expected**: +5-15% for rfft

Groups W^k and W^{N-k} (conjugates) together, reducing twiddle memory bandwidth by ~50%.

**Trade-offs:**

- We already have SIMD post-processing optimization
- Hierarchical codelets use hardcoded twiddles up to N=1024
- Main benefit is for N > 1024

**Complexity**: Medium-High

---

## Priority M: Better Register Scheduling for Codelets

**Expected**: +10-20%

Improve codelet generator with optimal scheduling that minimizes simultaneous live values:

1. Build dependency DAG
2. Number nodes by minimum required registers
3. Execute in order keeping live values <= 16

**Complexity**: High
**Value**: High for extending codelets beyond N=16

---

## Priority N: Memory Alignment Hints

**Expected**: +0-5%

Add alignment hints to SIMD loads:

```wat
(v128.load align=16 (local.get $addr))
```

**Reality**: Intel benchmarks show "no meaningful performance difference" for data access.

**Complexity**: Low
**Priority**: Lowest

---

## Not Applicable to Our Use Case

| Optimization          | Why Not Applicable                   |
| --------------------- | ------------------------------------ |
| Bailey's 4-Step FFT   | Only for N >= 1M (our max is 4096)   |
| Cache blocking/tiling | N=4096 working set (64KB) fits in L2 |
| Depth-first recursion | Tested, overhead > benefit           |
| Runtime planning      | fftw-js uses fixed plans             |
