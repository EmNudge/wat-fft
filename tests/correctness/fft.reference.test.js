/**
 * FFT Reference Comparison Test
 *
 * Compares our FFT implementation against:
 * 1. Our own O(N^2) DFT reference implementation
 * 2. fft.js library (well-tested FFT implementation)
 *
 * This catches algorithmic bugs by comparing against known-good implementations.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import FFT from "fft.js";
import {
  loadWasmModule,
  IMPLEMENTATIONS,
  FFT_SIZES,
  QUICK_SIZES,
  runFFT,
  referenceDFT,
  arraysApproxEqual,
  signals,
  maxError,
} from "./test-helper.js";

// Tolerances tuned for stockham which has ~1e-10 per-operation error
const TOLERANCE = { f64: { rel: 1e-7, abs: 5e-8 }, f32: { rel: 1e-4, abs: 1e-3 } };

// For DFT comparison, use looser tolerance for large N (both DFT and FFT accumulate error)
function dftTolerance(n, precision) {
  const base = precision === "f64" ? 1e-8 : 1e-4;
  return base * Math.sqrt(n);
}

test("Reference DFT comparison", async (t) => {
  for (const [implName, impl] of Object.entries(IMPLEMENTATIONS)) {
    const wasm = await loadWasmModule(impl.wasmName);
    if (!wasm) continue;

    await t.test(`${implName}: vs O(N^2) DFT`, async (t) => {
      // Only test small sizes for O(N^2) DFT
      const sizes = QUICK_SIZES.filter((s) => s <= 256);

      for (const size of sizes) {
        await t.test(`N=${size}`, async () => {
          const testSignals = [
            { name: "impulse", signal: signals.impulse(size) },
            { name: "constant", signal: signals.constant(size) },
            { name: "cosine", signal: signals.cosine(size, 3) },
            { name: "random", signal: signals.random(size, size * 11) },
          ];

          const tol = dftTolerance(size, impl.precision);

          for (const { name, signal } of testSignals) {
            const wasmResult = runFFT(wasm, impl, signal.real, signal.imag);
            const dftResult = referenceDFT(signal.real, signal.imag);

            const realErr = maxError(wasmResult.real, dftResult.real);
            const imagErr = maxError(wasmResult.imag, dftResult.imag);

            assert.ok(
              arraysApproxEqual(wasmResult.real, dftResult.real, tol, tol),
              `${name} real: max error ${realErr.toExponential(2)} (tol=${tol.toExponential(2)})`,
            );
            assert.ok(
              arraysApproxEqual(wasmResult.imag, dftResult.imag, tol, tol),
              `${name} imag: max error ${imagErr.toExponential(2)} (tol=${tol.toExponential(2)})`,
            );
          }
        });
      }
    });
  }
});

test("fft.js comparison", async (t) => {
  for (const [implName, impl] of Object.entries(IMPLEMENTATIONS)) {
    const wasm = await loadWasmModule(impl.wasmName);
    if (!wasm) continue;

    const tol = TOLERANCE[impl.precision];

    await t.test(`${implName}: vs fft.js`, async (t) => {
      for (const size of QUICK_SIZES) {
        await t.test(`N=${size}`, async () => {
          const fftjs = new FFT(size);

          const testSignals = [
            { name: "impulse", signal: signals.impulse(size) },
            { name: "constant", signal: signals.constant(size) },
            { name: "alternating", signal: signals.alternating(size) },
            { name: "cosine", signal: signals.cosine(size, 5) },
            { name: "random", signal: signals.random(size, size * 23) },
          ];

          for (const { name, signal } of testSignals) {
            // Run our FFT
            const wasmResult = runFFT(wasm, impl, signal.real, signal.imag);

            // Run fft.js (expects interleaved format)
            const input = new Array(size * 2);
            for (let i = 0; i < size; i++) {
              input[i * 2] = signal.real[i];
              input[i * 2 + 1] = signal.imag[i];
            }
            const output = fftjs.createComplexArray();
            fftjs.transform(output, input);

            // Extract fft.js results
            const fftjsReal = new Float64Array(size);
            const fftjsImag = new Float64Array(size);
            for (let i = 0; i < size; i++) {
              fftjsReal[i] = output[i * 2];
              fftjsImag[i] = output[i * 2 + 1];
            }

            const realErr = maxError(wasmResult.real, fftjsReal);
            const imagErr = maxError(wasmResult.imag, fftjsImag);

            assert.ok(
              arraysApproxEqual(wasmResult.real, fftjsReal, tol.rel, tol.abs),
              `${name} real: max error ${realErr.toExponential(2)}`,
            );
            assert.ok(
              arraysApproxEqual(wasmResult.imag, fftjsImag, tol.rel, tol.abs),
              `${name} imag: max error ${imagErr.toExponential(2)}`,
            );
          }
        });
      }
    });
  }
});

test("fft.js comparison: extended sizes", async (t) => {
  const wasm = await loadWasmModule("stockham");
  if (!wasm) {
    t.skip("stockham WASM not found");
    return;
  }

  const impl = IMPLEMENTATIONS.stockham;
  const tol = TOLERANCE[impl.precision];

  for (const size of FFT_SIZES) {
    await t.test(`N=${size}`, async () => {
      const fftjs = new FFT(size);
      const signal = signals.random(size, size * 37);

      // Run our FFT
      const wasmResult = runFFT(wasm, impl, signal.real, signal.imag);

      // Run fft.js
      const input = new Array(size * 2);
      for (let i = 0; i < size; i++) {
        input[i * 2] = signal.real[i];
        input[i * 2 + 1] = signal.imag[i];
      }
      const output = fftjs.createComplexArray();
      fftjs.transform(output, input);

      const fftjsReal = new Float64Array(size);
      const fftjsImag = new Float64Array(size);
      for (let i = 0; i < size; i++) {
        fftjsReal[i] = output[i * 2];
        fftjsImag[i] = output[i * 2 + 1];
      }

      assert.ok(
        arraysApproxEqual(wasmResult.real, fftjsReal, tol.rel, tol.abs),
        `real max error: ${maxError(wasmResult.real, fftjsReal).toExponential(2)}`,
      );
      assert.ok(
        arraysApproxEqual(wasmResult.imag, fftjsImag, tol.rel, tol.abs),
        `imag max error: ${maxError(wasmResult.imag, fftjsImag).toExponential(2)}`,
      );
    });
  }
});

test("Implementation consistency", async (t) => {
  // All our implementations should produce the same results
  const implementations = [];
  for (const [name, impl] of Object.entries(IMPLEMENTATIONS)) {
    if (impl.precision !== "f64") continue; // Compare only same precision
    const wasm = await loadWasmModule(impl.wasmName);
    if (wasm) {
      implementations.push({ name, wasm, impl });
    }
  }

  if (implementations.length < 2) {
    t.skip("Need at least 2 implementations to compare");
    return;
  }

  for (const size of QUICK_SIZES) {
    await t.test(`N=${size}`, async () => {
      const signal = signals.random(size, size * 41);

      const results = implementations.map(({ name, wasm, impl }) => ({
        name,
        result: runFFT(wasm, impl, signal.real, signal.imag),
      }));

      // Compare all pairs
      // Note: stockham has ~1e-10 accumulated error vs fast's ~1e-15
      // so we need tolerance that accommodates the less precise implementation
      for (let i = 1; i < results.length; i++) {
        const base = results[0];
        const other = results[i];

        assert.ok(
          arraysApproxEqual(base.result.real, other.result.real, 1e-8, 1e-8),
          `${base.name} vs ${other.name}: real mismatch`,
        );
        assert.ok(
          arraysApproxEqual(base.result.imag, other.result.imag, 1e-8, 1e-8),
          `${base.name} vs ${other.name}: imag mismatch`,
        );
      }
    });
  }
});
