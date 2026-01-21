/**
 * FFT Parseval's Theorem Test
 *
 * Verifies: sum(|x|²) = sum(|X|²) / N
 *
 * Energy in time domain equals energy in frequency domain (scaled by N).
 * This is a fundamental conservation property of the DFT.
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
  computeEnergy,
  approxEqual,
  signals,
} from "./test-helper.js";

// Energy comparison tolerance (relative)
const ENERGY_TOL = { f64: 1e-10, f32: 1e-4 };

test("Parseval's theorem: time energy = freq energy / N", async (t) => {
  for (const [implName, impl] of Object.entries(IMPLEMENTATIONS)) {
    const wasm = await loadWasmModule(impl.wasmName);
    if (!wasm) continue;

    const tol = ENERGY_TOL[impl.precision];

    await t.test(`${implName}: deterministic signals`, async (t) => {
      for (const size of QUICK_SIZES) {
        await t.test(`N=${size}`, async () => {
          const testSignals = [
            { name: "impulse", signal: signals.impulse(size) },
            { name: "constant", signal: signals.constant(size) },
            { name: "alternating", signal: signals.alternating(size) },
            { name: "cosine", signal: signals.cosine(size, 3) },
            { name: "random", signal: signals.random(size, 123) },
          ];

          for (const { name, signal } of testSignals) {
            const timeEnergy = computeEnergy(signal.real, signal.imag);
            const output = runFFT(wasm, impl, signal.real, signal.imag);
            const freqEnergy = computeEnergy(output.real, output.imag) / size;

            assert.ok(
              approxEqual(timeEnergy, freqEnergy, tol),
              `${name}: time=${timeEnergy.toExponential(4)}, freq=${freqEnergy.toExponential(4)}`,
            );
          }
        });
      }
    });

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

                const timeEnergy = computeEnergy(real, imag);
                const output = runFFT(wasm, impl, real, imag);
                const freqEnergy = computeEnergy(output.real, output.imag) / size;

                return approxEqual(timeEnergy, freqEnergy, 1e-6);
              },
            ),
            { numRuns: 100 },
          );
        });
      }
    });
  }
});

test("Parseval: extended sizes (2-8192)", async (t) => {
  const wasm = await loadWasmModule("stockham");
  if (!wasm) {
    t.skip("stockham WASM not found");
    return;
  }

  const impl = IMPLEMENTATIONS.stockham;
  const tol = ENERGY_TOL[impl.precision];

  for (const size of FFT_SIZES) {
    await t.test(`N=${size}`, async () => {
      const signal = signals.random(size, size * 13);
      const timeEnergy = computeEnergy(signal.real, signal.imag);
      const output = runFFT(wasm, impl, signal.real, signal.imag);
      const freqEnergy = computeEnergy(output.real, output.imag) / size;

      const relError = Math.abs(timeEnergy - freqEnergy) / Math.max(timeEnergy, 1e-10);
      assert.ok(
        approxEqual(timeEnergy, freqEnergy, tol),
        `relative error: ${relError.toExponential(2)}`,
      );
    });
  }
});
