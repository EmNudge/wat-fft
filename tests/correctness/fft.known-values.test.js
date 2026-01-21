/**
 * FFT Known Values Test
 *
 * Tests FFT against signals with mathematically known transforms:
 * - Impulse: δ[n] → 1 (flat spectrum)
 * - DC: 1 → N·δ[k] (single peak at DC)
 * - Cosine: cos(2πk₀n/N) → (N/2)(δ[k-k₀] + δ[k+k₀])
 * - Sine: sin(2πk₀n/N) → (N/2i)(δ[k-k₀] - δ[k+k₀])
 * - Nyquist: (-1)^n → N·δ[k-N/2]
 *
 * These tests verify the FFT produces correct magnitudes and phases
 * for analytically tractable signals.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import {
  loadWasmModule,
  IMPLEMENTATIONS,
  QUICK_SIZES,
  runFFT,
  approxEqual,
  signals,
} from "./test-helper.js";

// Tolerances account for accumulated floating-point error in FFT (O(N log N) ops)
// The stockham implementation has ~1e-10 per-operation error, leading to ~1e-8
// accumulated error for large N. For N=1024, we observe ~1e-8 absolute errors.
const TOLERANCE = { f64: { rel: 1e-7, abs: 5e-8 }, f32: { rel: 1e-4, abs: 1e-3 } };

test("Known values: impulse δ[n] → flat spectrum", async (t) => {
  for (const [implName, impl] of Object.entries(IMPLEMENTATIONS)) {
    const wasm = await loadWasmModule(impl.wasmName);
    if (!wasm) continue;

    const tol = TOLERANCE[impl.precision];

    await t.test(implName, async (t) => {
      for (const size of QUICK_SIZES) {
        await t.test(`N=${size}`, async () => {
          const signal = signals.impulse(size);
          const result = runFFT(wasm, impl, signal.real, signal.imag);

          // FFT of impulse at n=0 should be all 1s (constant spectrum)
          for (let k = 0; k < size; k++) {
            assert.ok(
              approxEqual(result.real[k], 1, tol.rel, tol.abs),
              `real[${k}] = ${result.real[k]}, expected 1`,
            );
            assert.ok(
              approxEqual(result.imag[k], 0, tol.rel, tol.abs),
              `imag[${k}] = ${result.imag[k]}, expected 0`,
            );
          }
        });
      }
    });
  }
});

test("Known values: DC (constant) → impulse at k=0", async (t) => {
  for (const [implName, impl] of Object.entries(IMPLEMENTATIONS)) {
    const wasm = await loadWasmModule(impl.wasmName);
    if (!wasm) continue;

    const tol = TOLERANCE[impl.precision];

    await t.test(implName, async (t) => {
      for (const size of QUICK_SIZES) {
        await t.test(`N=${size}`, async () => {
          const signal = signals.constant(size);
          const result = runFFT(wasm, impl, signal.real, signal.imag);

          // FFT of constant 1 should be N at k=0, 0 elsewhere
          assert.ok(
            approxEqual(result.real[0], size, tol.rel, tol.abs),
            `real[0] = ${result.real[0]}, expected ${size}`,
          );
          assert.ok(
            approxEqual(result.imag[0], 0, tol.rel, tol.abs),
            `imag[0] = ${result.imag[0]}, expected 0`,
          );

          for (let k = 1; k < size; k++) {
            assert.ok(
              approxEqual(result.real[k], 0, tol.rel, tol.abs),
              `real[${k}] = ${result.real[k]}, expected 0`,
            );
            assert.ok(
              approxEqual(result.imag[k], 0, tol.rel, tol.abs),
              `imag[${k}] = ${result.imag[k]}, expected 0`,
            );
          }
        });
      }
    });
  }
});

test("Known values: Nyquist (-1)^n → impulse at k=N/2", async (t) => {
  for (const [implName, impl] of Object.entries(IMPLEMENTATIONS)) {
    const wasm = await loadWasmModule(impl.wasmName);
    if (!wasm) continue;

    const tol = TOLERANCE[impl.precision];

    await t.test(implName, async (t) => {
      for (const size of QUICK_SIZES) {
        await t.test(`N=${size}`, async () => {
          const signal = signals.alternating(size);
          const result = runFFT(wasm, impl, signal.real, signal.imag);

          // FFT of alternating should be N at k=N/2, 0 elsewhere
          const nyquist = size / 2;

          for (let k = 0; k < size; k++) {
            const expectedReal = k === nyquist ? size : 0;
            assert.ok(
              approxEqual(result.real[k], expectedReal, tol.rel, tol.abs),
              `real[${k}] = ${result.real[k]}, expected ${expectedReal}`,
            );
            assert.ok(
              approxEqual(result.imag[k], 0, tol.rel, tol.abs),
              `imag[${k}] = ${result.imag[k]}, expected 0`,
            );
          }
        });
      }
    });
  }
});

test("Known values: cosine → symmetric peaks at ±k₀", async (t) => {
  for (const [implName, impl] of Object.entries(IMPLEMENTATIONS)) {
    const wasm = await loadWasmModule(impl.wasmName);
    if (!wasm) continue;

    const tol = TOLERANCE[impl.precision];

    await t.test(implName, async (t) => {
      for (const size of QUICK_SIZES) {
        await t.test(`N=${size}`, async () => {
          // Test with frequency bin k0 = 3 (or 1 for small sizes)
          const k0 = size >= 8 ? 3 : 1;
          const signal = signals.cosine(size, k0);
          const result = runFFT(wasm, impl, signal.real, signal.imag);

          // cos(2πk₀n/N) → (N/2)(δ[k-k₀] + δ[k-(N-k₀)])
          // Peaks at k₀ and N-k₀, magnitude N/2, no imaginary component
          const peakMag = size / 2;

          for (let k = 0; k < size; k++) {
            const isPeak = k === k0 || k === size - k0;
            const expectedReal = isPeak ? peakMag : 0;

            assert.ok(
              approxEqual(result.real[k], expectedReal, tol.rel, tol.abs),
              `real[${k}] = ${result.real[k]}, expected ${expectedReal}`,
            );
            assert.ok(
              approxEqual(result.imag[k], 0, tol.rel, tol.abs),
              `imag[${k}] = ${result.imag[k]}, expected 0`,
            );
          }
        });
      }
    });
  }
});

test("Known values: sine → antisymmetric peaks at ±k₀", async (t) => {
  for (const [implName, impl] of Object.entries(IMPLEMENTATIONS)) {
    const wasm = await loadWasmModule(impl.wasmName);
    if (!wasm) continue;

    const tol = TOLERANCE[impl.precision];

    await t.test(implName, async (t) => {
      for (const size of QUICK_SIZES) {
        await t.test(`N=${size}`, async () => {
          const k0 = size >= 8 ? 3 : 1;
          const signal = signals.sine(size, k0);
          const result = runFFT(wasm, impl, signal.real, signal.imag);

          // sin(2πk₀n/N) → (N/2i)(δ[k-k₀] - δ[k-(N-k₀)])
          // = (-N/2)i at k₀, (+N/2)i at N-k₀
          // Real parts are 0, imaginary parts are ∓N/2
          const peakMag = size / 2;

          for (let k = 0; k < size; k++) {
            let expectedImag = 0;
            if (k === k0) expectedImag = -peakMag;
            else if (k === size - k0) expectedImag = peakMag;

            assert.ok(
              approxEqual(result.real[k], 0, tol.rel, tol.abs),
              `real[${k}] = ${result.real[k]}, expected 0`,
            );
            assert.ok(
              approxEqual(result.imag[k], expectedImag, tol.rel, tol.abs),
              `imag[${k}] = ${result.imag[k]}, expected ${expectedImag}`,
            );
          }
        });
      }
    });
  }
});

test("Known values: shifted impulse δ[n-m]", async (t) => {
  for (const [implName, impl] of Object.entries(IMPLEMENTATIONS)) {
    const wasm = await loadWasmModule(impl.wasmName);
    if (!wasm) continue;

    const tol = TOLERANCE[impl.precision];

    await t.test(implName, async (t) => {
      for (const size of QUICK_SIZES.filter((s) => s <= 256)) {
        await t.test(`N=${size}`, async () => {
          // Impulse at position m has FFT: e^(-2πi*k*m/N) for all k
          const m = size / 4;
          const signal = signals.shiftedImpulse(size, m);
          const result = runFFT(wasm, impl, signal.real, signal.imag);

          for (let k = 0; k < size; k++) {
            const angle = (-2 * Math.PI * k * m) / size;
            const expectedReal = Math.cos(angle);
            const expectedImag = Math.sin(angle);

            assert.ok(
              approxEqual(result.real[k], expectedReal, tol.rel, tol.abs),
              `real[${k}] = ${result.real[k]}, expected ${expectedReal}`,
            );
            assert.ok(
              approxEqual(result.imag[k], expectedImag, tol.rel, tol.abs),
              `imag[${k}] = ${result.imag[k]}, expected ${expectedImag}`,
            );
          }
        });
      }
    });
  }
});

test("Known values: conjugate symmetry for real input", async (t) => {
  for (const [implName, impl] of Object.entries(IMPLEMENTATIONS)) {
    const wasm = await loadWasmModule(impl.wasmName);
    if (!wasm) continue;

    const tol = TOLERANCE[impl.precision];

    await t.test(implName, async (t) => {
      for (const size of QUICK_SIZES) {
        await t.test(`N=${size}`, async () => {
          // For real input, X[k] = conj(X[N-k])
          const signal = signals.randomReal(size, size * 7);
          const result = runFFT(wasm, impl, signal.real, signal.imag);

          // X[0] and X[N/2] should be real (zero imaginary)
          assert.ok(
            approxEqual(result.imag[0], 0, tol.rel, 1e-8),
            `imag[0] = ${result.imag[0]}, expected 0 (DC should be real)`,
          );
          assert.ok(
            approxEqual(result.imag[size / 2], 0, tol.rel, 1e-8),
            `imag[N/2] = ${result.imag[size / 2]}, expected 0 (Nyquist should be real)`,
          );

          // X[k] = conj(X[N-k]) for k = 1 to N/2-1
          for (let k = 1; k < size / 2; k++) {
            const nk = size - k;
            assert.ok(
              approxEqual(result.real[k], result.real[nk], tol.rel, tol.abs),
              `real[${k}] = ${result.real[k]} should equal real[${nk}] = ${result.real[nk]}`,
            );
            assert.ok(
              approxEqual(result.imag[k], -result.imag[nk], tol.rel, tol.abs),
              `imag[${k}] = ${result.imag[k]} should equal -imag[${nk}] = ${-result.imag[nk]}`,
            );
          }
        });
      }
    });
  }
});

test("Known values: magnitude spectrum properties", async (t) => {
  const wasm = await loadWasmModule("stockham");
  if (!wasm) {
    t.skip("stockham WASM not found");
    return;
  }

  const impl = IMPLEMENTATIONS.stockham;

  for (const size of [64, 256]) {
    await t.test(`N=${size}: magnitude bounds`, async () => {
      // For input bounded by M, FFT magnitude at any bin is bounded by N*M
      const M = 1;
      const signal = signals.random(size, size);

      // Normalize to [-M, M]
      const maxVal = Math.max(...signal.real.map(Math.abs), ...signal.imag.map(Math.abs));
      const scale = M / maxVal;
      const normalized = {
        real: Float64Array.from(signal.real, (v) => v * scale),
        imag: Float64Array.from(signal.imag, (v) => v * scale),
      };

      const result = runFFT(wasm, impl, normalized.real, normalized.imag);

      for (let k = 0; k < size; k++) {
        const mag = Math.sqrt(result.real[k] ** 2 + result.imag[k] ** 2);
        assert.ok(
          mag <= size * M * Math.SQRT2 + 1e-6,
          `magnitude[${k}] = ${mag} exceeds bound ${size * M * Math.SQRT2}`,
        );
      }
    });
  }
});
