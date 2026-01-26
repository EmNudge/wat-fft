/**
 * Output Order Verification Tests
 *
 * These tests are specifically designed to catch bit-reversal and permutation bugs
 * in FFT implementations. They use signals where each frequency bin has a distinct
 * value, making any output reordering immediately detectable.
 *
 * Background: FFT algorithms like Decimation-in-Frequency (DIF) naturally produce
 * bit-reversed output. If the implementation doesn't properly reorder the output,
 * or if different code paths (codelets vs general algorithms) have inconsistent
 * ordering, this can cause subtle bugs that symmetric test signals won't catch.
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { test, describe } from "node:test";
import assert from "node:assert";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Load modules
async function loadModule(name) {
  const wasmPath = path.join(__dirname, "..", "dist", name);
  if (!fs.existsSync(wasmPath)) {
    return null;
  }
  const wasmBuffer = fs.readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);
  const instance = await WebAssembly.instantiate(wasmModule);
  return instance.exports;
}

/**
 * Reference DFT - O(N^2) ground truth implementation
 * Computes X[k] = sum_{j=0}^{N-1} x[j] * exp(-2*pi*i*k*j/N)
 */
function referenceDFT(real, imag) {
  const n = real.length;
  const outReal = new Float64Array(n);
  const outImag = new Float64Array(n);

  for (let k = 0; k < n; k++) {
    let sumReal = 0;
    let sumImag = 0;
    for (let j = 0; j < n; j++) {
      const angle = (-2 * Math.PI * k * j) / n;
      const cos = Math.cos(angle);
      const sin = Math.sin(angle);
      sumReal += real[j] * cos - imag[j] * sin;
      sumImag += real[j] * sin + imag[j] * cos;
    }
    outReal[k] = sumReal;
    outImag[k] = sumImag;
  }

  return { real: outReal, imag: outImag };
}

/**
 * Reference Real DFT - for RFFT verification
 */
function referenceRealDFT(input) {
  const n = input.length;
  const n2 = n / 2;
  const outReal = new Float64Array(n2 + 1);
  const outImag = new Float64Array(n2 + 1);

  for (let k = 0; k <= n2; k++) {
    let sumReal = 0;
    let sumImag = 0;
    for (let j = 0; j < n; j++) {
      const angle = (-2 * Math.PI * k * j) / n;
      sumReal += input[j] * Math.cos(angle);
      sumImag += input[j] * Math.sin(angle);
    }
    outReal[k] = sumReal;
    outImag[k] = sumImag;
  }

  return { real: outReal, imag: outImag };
}

/**
 * Generate a "distinct bin" signal - each frequency bin gets a unique magnitude.
 */
function generateDistinctBinSignal(n) {
  const real = new Float64Array(n);

  for (let j = 0; j < n; j++) {
    let sum = 1; // DC component (A_0 = 1)
    for (let k = 1; k < n / 2; k++) {
      // Amplitude increases with frequency bin
      sum += (k + 1) * Math.cos((2 * Math.PI * k * j) / n);
    }
    // Nyquist component
    sum += (n / 2 + 1) * Math.cos(Math.PI * j); // cos(pi*j) = (-1)^j
    real[j] = sum;
  }

  return real;
}

/**
 * Seeded random number generator for reproducible tests
 */
function createRng(seed) {
  let s = seed;
  return () => {
    s = (s * 1103515245 + 12345) & 0x7fffffff;
    return (s / 0x7fffffff) * 2 - 1;
  };
}

describe("Output Order Verification", async () => {
  // Test sizes that exercise different code paths
  const sizes = [8, 16, 32, 64, 128, 256, 512, 1024];

  describe("Complex FFT output ordering (f64)", async () => {
    const wasm = await loadModule("fft_combined.wasm");
    if (!wasm) {
      test.skip("fft_combined module not found");
      return;
    }

    function runFFT(wasm, real, imag) {
      const n = real.length;
      const data = new Float64Array(wasm.memory.buffer, 0, n * 2);

      for (let i = 0; i < n; i++) {
        data[i * 2] = real[i];
        data[i * 2 + 1] = imag[i];
      }

      wasm.precompute_twiddles(n);
      wasm.fft(n);

      const result = new Float64Array(wasm.memory.buffer, 0, n * 2);
      const outReal = new Float64Array(n);
      const outImag = new Float64Array(n);
      for (let i = 0; i < n; i++) {
        outReal[i] = result[i * 2];
        outImag[i] = result[i * 2 + 1];
      }
      return { real: outReal, imag: outImag };
    }

    for (const n of sizes) {
      test(`N=${n}: output[k] contains frequency bin k (not bit-reversed)`, () => {
        // Use random complex input to ensure each output bin is distinct
        const rand = createRng(42 + n);
        const real = Float64Array.from({ length: n }, () => rand());
        const imag = Float64Array.from({ length: n }, () => rand());

        const expected = referenceDFT(real, imag);
        const actual = runFFT(wasm, real, imag);

        // Verify EACH bin individually - this catches permutation errors
        const tol = Math.max(1e-9, n * 1e-11);
        for (let k = 0; k < n; k++) {
          const realErr = Math.abs(actual.real[k] - expected.real[k]);
          const imagErr = Math.abs(actual.imag[k] - expected.imag[k]);

          assert.ok(
            realErr < tol,
            `Bin ${k} real: expected ${expected.real[k].toFixed(6)}, got ${actual.real[k].toFixed(6)} (error ${realErr.toExponential(2)}). ` +
              `This may indicate bit-reversed output ordering.`,
          );
          assert.ok(
            imagErr < tol,
            `Bin ${k} imag: expected ${expected.imag[k].toFixed(6)}, got ${actual.imag[k].toFixed(6)} (error ${imagErr.toExponential(2)}). ` +
              `This may indicate bit-reversed output ordering.`,
          );
        }
      });
    }
  });

  describe("RFFT output ordering (f64)", async () => {
    const realWasm = await loadModule("fft_real_combined.wasm");
    if (!realWasm) {
      test.skip("fft_real_combined module not found");
      return;
    }

    function runRFFT(wasm, input) {
      const n = input.length;
      const n2 = n / 2;
      const data = new Float64Array(wasm.memory.buffer, 0, n);

      for (let i = 0; i < n; i++) {
        data[i] = input[i];
      }

      wasm.precompute_rfft_twiddles(n);
      wasm.rfft(n);

      const result = new Float64Array(wasm.memory.buffer, 0, (n2 + 1) * 2);
      const real = new Float64Array(n2 + 1);
      const imag = new Float64Array(n2 + 1);
      for (let i = 0; i <= n2; i++) {
        real[i] = result[i * 2];
        imag[i] = result[i * 2 + 1];
      }
      return { real, imag };
    }

    for (const n of sizes) {
      test(`N=${n}: RFFT output[k] contains frequency bin k`, () => {
        // Use random real input
        const rand = createRng(123 + n);
        const input = Float64Array.from({ length: n }, () => rand());

        const expected = referenceRealDFT(input);
        const actual = runRFFT(realWasm, input);

        const tol = Math.max(1e-9, n * 5e-11);
        for (let k = 0; k <= n / 2; k++) {
          const realErr = Math.abs(actual.real[k] - expected.real[k]);
          const imagErr = Math.abs(actual.imag[k] - expected.imag[k]);

          assert.ok(
            realErr < tol,
            `RFFT bin ${k} real: expected ${expected.real[k].toFixed(6)}, got ${actual.real[k].toFixed(6)}. ` +
              `Possible internal FFT output order mismatch.`,
          );
          assert.ok(
            imagErr < tol,
            `RFFT bin ${k} imag: expected ${expected.imag[k].toFixed(6)}, got ${actual.imag[k].toFixed(6)}. ` +
              `Possible internal FFT output order mismatch.`,
          );
        }
      });

      test(`N=${n}: RFFT with distinct-bin signal verifies output indices`, () => {
        // This signal has predictable, distinct magnitudes at each frequency bin
        const input = generateDistinctBinSignal(n);
        const actual = runRFFT(realWasm, input);

        // Tolerance needs to scale with N since we sum N/2 cosine terms
        const tol = Math.max(1e-4, n * 1e-7);

        // DC bin should have magnitude N (from A_0 = 1, X[0] = N * 1)
        assert.ok(
          Math.abs(actual.real[0] - n) < tol,
          `DC bin: expected ${n}, got ${actual.real[0]}`,
        );
        assert.ok(Math.abs(actual.imag[0]) < tol, `DC bin imag should be 0`);

        // Each other bin k should have magnitude N/2 * (k+1)
        for (let k = 1; k < n / 2; k++) {
          const expectedMag = (n / 2) * (k + 1);
          const actualMag = Math.abs(actual.real[k]); // Cosines -> real only

          assert.ok(
            Math.abs(actualMag - expectedMag) < tol,
            `Bin ${k}: expected magnitude ${expectedMag}, got ${actualMag}. ` +
              `If magnitude is correct but at wrong bin, this indicates output reordering.`,
          );
        }
      });
    }
  });

  describe("RFFT f32 output ordering", async () => {
    const f32Wasm = await loadModule("fft_real_f32_dual.wasm");
    if (!f32Wasm) {
      test.skip("fft_real_f32_dual module not found");
      return;
    }

    function runRFFT32(wasm, input) {
      const n = input.length;
      const n2 = n / 2;
      const data = new Float32Array(wasm.memory.buffer, 0, n);

      for (let i = 0; i < n; i++) {
        data[i] = input[i];
      }

      wasm.precompute_rfft_twiddles(n);
      wasm.rfft(n);

      const result = new Float32Array(wasm.memory.buffer, 0, (n2 + 1) * 2);
      const real = new Float32Array(n2 + 1);
      const imag = new Float32Array(n2 + 1);
      for (let i = 0; i <= n2; i++) {
        real[i] = result[i * 2];
        imag[i] = result[i * 2 + 1];
      }
      return { real, imag };
    }

    // Test sizes that exercise different code paths in f32
    const f32Sizes = [8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096];

    for (const n of f32Sizes) {
      test(`N=${n}: f32 RFFT output[k] contains frequency bin k`, () => {
        const rand = createRng(456 + n);
        const input = Float32Array.from({ length: n }, () => rand());

        const expected = referenceRealDFT(Array.from(input));
        const actual = runRFFT32(f32Wasm, input);

        // f32 has lower precision
        const tol = Math.max(1e-4, n * 1e-6);
        for (let k = 0; k <= n / 2; k++) {
          const realErr = Math.abs(actual.real[k] - expected.real[k]);
          const imagErr = Math.abs(actual.imag[k] - expected.imag[k]);

          assert.ok(
            realErr < tol,
            `f32 RFFT bin ${k} real: expected ${expected.real[k].toFixed(4)}, got ${actual.real[k].toFixed(4)}`,
          );
          assert.ok(
            imagErr < tol,
            `f32 RFFT bin ${k} imag: expected ${expected.imag[k].toFixed(4)}, got ${actual.imag[k].toFixed(4)}`,
          );
        }
      });
    }

    // Specific regression test for the bit-reversal bug
    test("Regression: sine wave peak at correct bin (not bit-reversed)", () => {
      const n = 64;
      const freq = 7;

      const input = new Float32Array(n);
      for (let i = 0; i < n; i++) {
        input[i] = Math.sin((2 * Math.PI * freq * i) / n);
      }

      const result = runRFFT32(f32Wasm, input);

      // Find the bin with maximum magnitude
      let maxMag = 0;
      let maxBin = -1;
      for (let k = 0; k <= n / 2; k++) {
        const mag = Math.sqrt(result.real[k] * result.real[k] + result.imag[k] * result.imag[k]);
        if (mag > maxMag) {
          maxMag = mag;
          maxBin = k;
        }
      }

      assert.strictEqual(
        maxBin,
        freq,
        `Sine wave at frequency ${freq} should have peak at bin ${freq}, but peak is at bin ${maxBin}. ` +
          `This indicates bit-reversed or otherwise reordered output.`,
      );

      const expectedMag = n / 2;
      assert.ok(
        Math.abs(maxMag - expectedMag) < 0.1,
        `Peak magnitude should be ~${expectedMag}, got ${maxMag}`,
      );
    });

    // Test multiple frequencies to catch subtler ordering issues
    test("Regression: multiple sine waves at correct bins", () => {
      const n = 128;
      const frequencies = [3, 11, 17, 29];

      const input = new Float32Array(n);
      for (let i = 0; i < n; i++) {
        let sum = 0;
        for (const f of frequencies) {
          sum += Math.sin((2 * Math.PI * f * i) / n);
        }
        input[i] = sum;
      }

      const result = runRFFT32(f32Wasm, input);

      const tol = 1.0;
      for (const freq of frequencies) {
        const mag = Math.sqrt(
          result.real[freq] * result.real[freq] + result.imag[freq] * result.imag[freq],
        );
        const expectedMag = n / 2;

        assert.ok(
          Math.abs(mag - expectedMag) < tol,
          `Frequency ${freq} should have magnitude ~${expectedMag} at bin ${freq}, got ${mag.toFixed(2)}`,
        );
      }
    });
  });

  describe("Cross-implementation consistency", async () => {
    const realWasm = await loadModule("fft_real_combined.wasm");
    const f32Wasm = await loadModule("fft_real_f32_dual.wasm");

    if (!realWasm || !f32Wasm) {
      test.skip("Required modules not found");
      return;
    }

    function runRFFT64(wasm, input) {
      const n = input.length;
      const n2 = n / 2;
      const data = new Float64Array(wasm.memory.buffer, 0, n);
      for (let i = 0; i < n; i++) data[i] = input[i];
      wasm.precompute_rfft_twiddles(n);
      wasm.rfft(n);
      const result = new Float64Array(wasm.memory.buffer, 0, (n2 + 1) * 2);
      const real = new Float64Array(n2 + 1);
      const imag = new Float64Array(n2 + 1);
      for (let i = 0; i <= n2; i++) {
        real[i] = result[i * 2];
        imag[i] = result[i * 2 + 1];
      }
      return { real, imag };
    }

    function runRFFT32(wasm, input) {
      const n = input.length;
      const n2 = n / 2;
      const data = new Float32Array(wasm.memory.buffer, 0, n);
      for (let i = 0; i < n; i++) data[i] = input[i];
      wasm.precompute_rfft_twiddles(n);
      wasm.rfft(n);
      const result = new Float32Array(wasm.memory.buffer, 0, (n2 + 1) * 2);
      const real = new Float32Array(n2 + 1);
      const imag = new Float32Array(n2 + 1);
      for (let i = 0; i <= n2; i++) {
        real[i] = result[i * 2];
        imag[i] = result[i * 2 + 1];
      }
      return { real, imag };
    }

    for (const n of [32, 64, 128, 256, 512, 1024]) {
      test(`N=${n}: f64 and f32 RFFT produce consistent output ordering`, () => {
        const rand = createRng(789 + n);
        const input = Float64Array.from({ length: n }, () => rand());

        const f64Result = runRFFT64(realWasm, input);
        const f32Result = runRFFT32(f32Wasm, input);

        // f32 has lower precision
        const tol = Math.max(1e-3, n * 1e-5);

        for (let k = 0; k <= n / 2; k++) {
          const realErr = Math.abs(f64Result.real[k] - f32Result.real[k]);
          const imagErr = Math.abs(f64Result.imag[k] - f32Result.imag[k]);

          assert.ok(
            realErr < tol,
            `Bin ${k} real: f64=${f64Result.real[k].toFixed(4)}, f32=${f32Result.real[k].toFixed(4)}. ` +
              `Large discrepancy may indicate different output ordering between implementations.`,
          );
          assert.ok(
            imagErr < tol,
            `Bin ${k} imag: f64=${f64Result.imag[k].toFixed(4)}, f32=${f32Result.imag[k].toFixed(4)}. ` +
              `Large discrepancy may indicate different output ordering between implementations.`,
          );
        }
      });
    }
  });
});
