/**
 * FFT Round-Trip (Inverse) Test
 *
 * Verifies: IFFT(FFT(x)) ≈ x for all inputs
 *
 * This is the fundamental correctness property - the inverse transform
 * should perfectly recover the original signal (within floating-point precision).
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import fc from "fast-check";
import {
  loadWasmModule,
  IMPLEMENTATIONS,
  FFT_SIZES,
  QUICK_SIZES,
  runFFT,
  runIFFT,
  arraysApproxEqual,
  signals,
  maxError,
} from "./test-helper.js";

// Tolerance depends on precision - tuned for stockham's ~1e-10 per-operation error
// Round-trip involves 2 FFTs, so error doubles
const TOLERANCE = { f64: { rel: 1e-8, abs: 1e-8 }, f32: { rel: 1e-4, abs: 1e-4 } };

test("Round-trip: IFFT(FFT(x)) = x", async (t) => {
  for (const [implName, impl] of Object.entries(IMPLEMENTATIONS)) {
    const wasm = await loadWasmModule(impl.wasmName);
    if (!wasm) continue;

    const tol = TOLERANCE[impl.precision];

    await t.test(`${implName}: deterministic signals`, async (t) => {
      for (const size of QUICK_SIZES) {
        await t.test(`N=${size}`, async () => {
          // Test various signal types
          const testSignals = [
            { name: "impulse", signal: signals.impulse(size) },
            { name: "constant", signal: signals.constant(size) },
            { name: "cosine", signal: signals.cosine(size, 1) },
            { name: "random", signal: signals.random(size, 42) },
          ];

          for (const { name, signal } of testSignals) {
            const transformed = runFFT(wasm, impl, signal.real, signal.imag);
            const recovered = runIFFT(wasm, impl, transformed.real, transformed.imag);

            const realErr = maxError(signal.real, recovered.real);
            const imagErr = maxError(signal.imag, recovered.imag);

            assert.ok(
              arraysApproxEqual(signal.real, recovered.real, tol.rel, tol.abs),
              `${name} real: max error ${realErr.toExponential(2)}`,
            );
            assert.ok(
              arraysApproxEqual(signal.imag, recovered.imag, tol.rel, tol.abs),
              `${name} imag: max error ${imagErr.toExponential(2)}`,
            );
          }
        });
      }
    });

    // Skip property-based tests for f32 - large random values exceed f32 precision
    if (impl.precision === "f32") continue;

    await t.test(`${implName}: property-based random inputs`, async (t) => {
      for (const size of QUICK_SIZES.filter((s) => s <= 256)) {
        await t.test(`N=${size}`, async () => {
          const normalDouble = fc
            .double({ min: -1e6, max: 1e6, noNaN: true, noDefaultInfinity: true })
            .map((x) => (Math.abs(x) < 1e-100 ? 0 : x));

          fc.assert(
            fc.property(
              fc.array(normalDouble, { minLength: size, maxLength: size }),
              fc.array(normalDouble, { minLength: size, maxLength: size }),
              (realArr, imagArr) => {
                const real = new Float64Array(realArr);
                const imag = new Float64Array(imagArr);

                const transformed = runFFT(wasm, impl, real, imag);
                const recovered = runIFFT(wasm, impl, transformed.real, transformed.imag);

                return (
                  arraysApproxEqual(real, recovered.real, tol.rel, 1e-3) &&
                  arraysApproxEqual(imag, recovered.imag, tol.rel, 1e-3)
                );
              },
            ),
            { numRuns: 50 },
          );
        });
      }
    });
  }
});

test("Round-trip: extended sizes (2-8192)", async (t) => {
  const wasm = await loadWasmModule("stockham");
  if (!wasm) {
    t.skip("stockham WASM not found");
    return;
  }

  const impl = IMPLEMENTATIONS.stockham;
  const tol = TOLERANCE[impl.precision];

  for (const size of FFT_SIZES) {
    await t.test(`N=${size}`, async () => {
      const signal = signals.random(size, size * 7);
      const transformed = runFFT(wasm, impl, signal.real, signal.imag);
      const recovered = runIFFT(wasm, impl, transformed.real, transformed.imag);

      assert.ok(
        arraysApproxEqual(signal.real, recovered.real, tol.rel, tol.abs),
        `real max error: ${maxError(signal.real, recovered.real).toExponential(2)}`,
      );
      assert.ok(
        arraysApproxEqual(signal.imag, recovered.imag, tol.rel, tol.abs),
        `imag max error: ${maxError(signal.imag, recovered.imag).toExponential(2)}`,
      );
    });
  }
});
