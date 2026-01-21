/**
 * FFT Linearity Test
 *
 * Verifies: FFT(a*x + b*y) = a*FFT(x) + b*FFT(y)
 *
 * The DFT is a linear transformation, so scaling and addition must
 * commute with the transform.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import fc from "fast-check";
import {
  loadWasmModule,
  IMPLEMENTATIONS,
  QUICK_SIZES,
  runFFT,
  arraysApproxEqual,
  signals,
  maxError,
} from "./test-helper.js";

const TOLERANCE = { f64: { rel: 1e-8, abs: 1e-8 }, f32: { rel: 1e-4, abs: 1e-4 } };

test("Linearity: FFT(ax + by) = a*FFT(x) + b*FFT(y)", async (t) => {
  for (const [implName, impl] of Object.entries(IMPLEMENTATIONS)) {
    const wasm = await loadWasmModule(impl.wasmName);
    if (!wasm) continue;

    const tol = TOLERANCE[impl.precision];

    await t.test(`${implName}: deterministic cases`, async (t) => {
      for (const size of QUICK_SIZES.filter((s) => s <= 256)) {
        await t.test(`N=${size}`, async () => {
          const x = signals.cosine(size, 1);
          const y = signals.sine(size, 2);
          const a = 2.5;
          const b = -1.7;

          // FFT(a*x + b*y)
          const combined = {
            real: Float64Array.from({ length: size }, (_, i) => a * x.real[i] + b * y.real[i]),
            imag: Float64Array.from({ length: size }, (_, i) => a * x.imag[i] + b * y.imag[i]),
          };
          const fftCombined = runFFT(wasm, impl, combined.real, combined.imag);

          // a*FFT(x) + b*FFT(y)
          const fftX = runFFT(wasm, impl, x.real, x.imag);
          const fftY = runFFT(wasm, impl, y.real, y.imag);
          const linearCombined = {
            real: Float64Array.from(
              { length: size },
              (_, i) => a * fftX.real[i] + b * fftY.real[i],
            ),
            imag: Float64Array.from(
              { length: size },
              (_, i) => a * fftX.imag[i] + b * fftY.imag[i],
            ),
          };

          assert.ok(
            arraysApproxEqual(fftCombined.real, linearCombined.real, tol.rel, tol.abs),
            `real max error: ${maxError(fftCombined.real, linearCombined.real).toExponential(2)}`,
          );
          assert.ok(
            arraysApproxEqual(fftCombined.imag, linearCombined.imag, tol.rel, tol.abs),
            `imag max error: ${maxError(fftCombined.imag, linearCombined.imag).toExponential(2)}`,
          );
        });
      }
    });

    await t.test(`${implName}: property-based`, async (t) => {
      for (const size of QUICK_SIZES.filter((s) => s <= 128)) {
        await t.test(`N=${size}`, async () => {
          const normalDouble = fc
            .double({ min: -100, max: 100, noNaN: true, noDefaultInfinity: true })
            .map((x) => (Math.abs(x) < 1e-100 ? 0 : x));

          const arrayArb = fc.array(normalDouble, { minLength: size, maxLength: size });
          const scalarArb = fc.double({ min: -10, max: 10, noNaN: true, noDefaultInfinity: true });

          fc.assert(
            fc.property(
              arrayArb,
              arrayArb,
              arrayArb,
              arrayArb,
              scalarArb,
              scalarArb,
              (xr, xi, yr, yi, a, b) => {
                const x = { real: new Float64Array(xr), imag: new Float64Array(xi) };
                const y = { real: new Float64Array(yr), imag: new Float64Array(yi) };

                // FFT(a*x + b*y)
                const combined = {
                  real: Float64Array.from(
                    { length: size },
                    (_, i) => a * x.real[i] + b * y.real[i],
                  ),
                  imag: Float64Array.from(
                    { length: size },
                    (_, i) => a * x.imag[i] + b * y.imag[i],
                  ),
                };
                const fftCombined = runFFT(wasm, impl, combined.real, combined.imag);

                // a*FFT(x) + b*FFT(y)
                const fftX = runFFT(wasm, impl, x.real, x.imag);
                const fftY = runFFT(wasm, impl, y.real, y.imag);
                const linearCombined = {
                  real: Float64Array.from(
                    { length: size },
                    (_, i) => a * fftX.real[i] + b * fftY.real[i],
                  ),
                  imag: Float64Array.from(
                    { length: size },
                    (_, i) => a * fftX.imag[i] + b * fftY.imag[i],
                  ),
                };

                // Use looser tolerance for property tests due to accumulation
                return (
                  arraysApproxEqual(fftCombined.real, linearCombined.real, 1e-5, 1e-3) &&
                  arraysApproxEqual(fftCombined.imag, linearCombined.imag, 1e-5, 1e-3)
                );
              },
            ),
            { numRuns: 30 },
          );
        });
      }
    });
  }
});

test("Linearity: scaling property FFT(a*x) = a*FFT(x)", async (t) => {
  const wasm = await loadWasmModule("stockham");
  if (!wasm) {
    t.skip("stockham WASM not found");
    return;
  }

  const impl = IMPLEMENTATIONS.stockham;

  for (const size of [64, 256, 1024]) {
    await t.test(`N=${size}`, async () => {
      const x = signals.random(size, size);
      const scalars = [0, 1, -1, 2.5, -0.5, 1e6, 1e-6];

      for (const a of scalars) {
        const scaled = {
          real: Float64Array.from(x.real, (v) => a * v),
          imag: Float64Array.from(x.imag, (v) => a * v),
        };

        const fftScaled = runFFT(wasm, impl, scaled.real, scaled.imag);
        const fftX = runFFT(wasm, impl, x.real, x.imag);
        const expected = {
          real: Float64Array.from(fftX.real, (v) => a * v),
          imag: Float64Array.from(fftX.imag, (v) => a * v),
        };

        assert.ok(
          arraysApproxEqual(fftScaled.real, expected.real, 1e-8, 1e-8),
          `scale=${a}: real error ${maxError(fftScaled.real, expected.real).toExponential(2)}`,
        );
        assert.ok(
          arraysApproxEqual(fftScaled.imag, expected.imag, 1e-8, 1e-8),
          `scale=${a}: imag error ${maxError(fftScaled.imag, expected.imag).toExponential(2)}`,
        );
      }
    });
  }
});
