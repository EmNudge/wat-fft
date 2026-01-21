/**
 * FFT Shift Theorem Test
 *
 * Verifies: Time shift corresponds to phase rotation in frequency domain
 *
 * If x[n] has DFT X[k], then:
 *   x[n - m] has DFT X[k] * e^(-2πi*k*m/N)
 *
 * A time-domain shift of m samples corresponds to multiplying each
 * frequency bin by a complex exponential (phase rotation).
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

// Tolerances for shift tests - stockham has ~1e-10 per-operation error
const TOLERANCE = { f64: { rel: 1e-7, abs: 5e-8 }, f32: { rel: 1e-4, abs: 1e-3 } };

/**
 * Circular shift array by m positions (positive = shift right)
 */
function circularShift(arr, m) {
  const n = arr.length;
  const shift = ((m % n) + n) % n; // Normalize to [0, n)
  const result = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    result[i] = arr[(i - shift + n) % n];
  }
  return result;
}

/**
 * Apply phase rotation for time shift: multiply by e^(-2πi*k*m/N)
 */
function applyShiftPhase(real, imag, m, n) {
  const outReal = new Float64Array(n);
  const outImag = new Float64Array(n);

  for (let k = 0; k < n; k++) {
    const angle = (-2 * Math.PI * k * m) / n;
    const cos = Math.cos(angle);
    const sin = Math.sin(angle);

    // Complex multiply: (real + i*imag) * (cos + i*sin)
    outReal[k] = real[k] * cos - imag[k] * sin;
    outImag[k] = real[k] * sin + imag[k] * cos;
  }

  return { real: outReal, imag: outImag };
}

test("Shift theorem: time shift = frequency phase rotation", async (t) => {
  for (const [implName, impl] of Object.entries(IMPLEMENTATIONS)) {
    const wasm = await loadWasmModule(impl.wasmName);
    if (!wasm) continue;

    const tol = TOLERANCE[impl.precision];

    await t.test(`${implName}: shifted impulse`, async (t) => {
      for (const size of QUICK_SIZES.filter((s) => s <= 256)) {
        await t.test(`N=${size}`, async () => {
          // Original impulse at position 0
          const original = signals.impulse(size);
          const fftOriginal = runFFT(wasm, impl, original.real, original.imag);

          // Test various shifts
          const shifts = [1, 2, size / 4, size / 2, size - 1];

          for (const m of shifts) {
            // Shifted signal in time domain
            const shifted = {
              real: circularShift(original.real, m),
              imag: circularShift(original.imag, m),
            };
            const fftShifted = runFFT(wasm, impl, shifted.real, shifted.imag);

            // Expected: original FFT with phase rotation
            const expected = applyShiftPhase(fftOriginal.real, fftOriginal.imag, m, size);

            // Check magnitude is preserved (shift doesn't change magnitude)
            for (let k = 0; k < size; k++) {
              const actualMag = Math.sqrt(fftShifted.real[k] ** 2 + fftShifted.imag[k] ** 2);
              const expectedMag = Math.sqrt(expected.real[k] ** 2 + expected.imag[k] ** 2);

              assert.ok(
                approxEqual(actualMag, expectedMag, tol.rel, tol.abs),
                `shift=${m}, k=${k}: magnitude ${actualMag.toExponential(4)} vs ${expectedMag.toExponential(4)}`,
              );
            }

            // Check phase (via direct comparison of real/imag)
            for (let k = 0; k < size; k++) {
              assert.ok(
                approxEqual(fftShifted.real[k], expected.real[k], tol.rel, tol.abs),
                `shift=${m}, k=${k}: real ${fftShifted.real[k].toExponential(4)} vs ${expected.real[k].toExponential(4)}`,
              );
              assert.ok(
                approxEqual(fftShifted.imag[k], expected.imag[k], tol.rel, tol.abs),
                `shift=${m}, k=${k}: imag ${fftShifted.imag[k].toExponential(4)} vs ${expected.imag[k].toExponential(4)}`,
              );
            }
          }
        });
      }
    });

    await t.test(`${implName}: shifted random signal`, async (t) => {
      for (const size of QUICK_SIZES.filter((s) => s <= 128)) {
        await t.test(`N=${size}`, async () => {
          const original = signals.random(size, size * 17);
          const fftOriginal = runFFT(wasm, impl, original.real, original.imag);

          const shifts = [1, size / 4, size / 2];

          for (const m of shifts) {
            const shifted = {
              real: circularShift(original.real, m),
              imag: circularShift(original.imag, m),
            };
            const fftShifted = runFFT(wasm, impl, shifted.real, shifted.imag);
            const expected = applyShiftPhase(fftOriginal.real, fftOriginal.imag, m, size);

            // Check all bins
            for (let k = 0; k < size; k++) {
              assert.ok(
                approxEqual(fftShifted.real[k], expected.real[k], tol.rel, 1e-6),
                `shift=${m}, k=${k}: real mismatch`,
              );
              assert.ok(
                approxEqual(fftShifted.imag[k], expected.imag[k], tol.rel, 1e-6),
                `shift=${m}, k=${k}: imag mismatch`,
              );
            }
          }
        });
      }
    });
  }
});

test("Shift theorem: modulation (frequency shift)", async (t) => {
  // Dual of time shift: modulation in time = shift in frequency
  // x[n] * e^(2πi*m*n/N) has DFT X[k-m]

  const wasm = await loadWasmModule("stockham");
  if (!wasm) {
    t.skip("stockham WASM not found");
    return;
  }

  const impl = IMPLEMENTATIONS.stockham;

  for (const size of [64, 128]) {
    await t.test(`N=${size}`, async () => {
      const original = signals.random(size, size * 31);
      const fftOriginal = runFFT(wasm, impl, original.real, original.imag);

      const freqShifts = [1, 2, size / 4];

      for (const m of freqShifts) {
        // Modulate in time domain: multiply by e^(2πi*m*n/N)
        const modulated = {
          real: new Float64Array(size),
          imag: new Float64Array(size),
        };

        for (let n = 0; n < size; n++) {
          const angle = (2 * Math.PI * m * n) / size;
          const cos = Math.cos(angle);
          const sin = Math.sin(angle);
          // (real + i*imag) * (cos + i*sin)
          modulated.real[n] = original.real[n] * cos - original.imag[n] * sin;
          modulated.imag[n] = original.real[n] * sin + original.imag[n] * cos;
        }

        const fftModulated = runFFT(wasm, impl, modulated.real, modulated.imag);

        // Expected: circular shift of FFT bins by m
        // X[k-m] means result[k] = original[k-m], which is a right shift by m
        const expectedReal = circularShift(fftOriginal.real, m);
        const expectedImag = circularShift(fftOriginal.imag, m);

        // Use looser tolerance - modulation test compounds errors from both
        // the modulation calculation and the FFT
        for (let k = 0; k < size; k++) {
          assert.ok(
            approxEqual(fftModulated.real[k], expectedReal[k], 1e-6, 1e-5),
            `freqShift=${m}, k=${k}: real mismatch`,
          );
          assert.ok(
            approxEqual(fftModulated.imag[k], expectedImag[k], 1e-6, 1e-5),
            `freqShift=${m}, k=${k}: imag mismatch`,
          );
        }
      }
    });
  }
});
