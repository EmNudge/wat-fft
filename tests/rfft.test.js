/**
 * Real FFT Test Suite
 *
 * Tests the Real FFT (r2c) implementation against:
 * - Known analytical results for standard test signals
 * - Reference complex FFT with imaginary part set to zero
 * - Parseval's theorem for energy conservation
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { test, describe } from "node:test";
import assert from "node:assert";
import { referenceRealDFT, compareResults } from "./dft-reference.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Load Real FFT WASM module
async function loadRealWasm() {
  const wasmPath = path.join(__dirname, "..", "dist", "fft_real_combined.wasm");
  if (!fs.existsSync(wasmPath)) {
    throw new Error(`WASM file not found: ${wasmPath}`);
  }
  const wasmBuffer = fs.readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);
  const instance = await WebAssembly.instantiate(wasmModule);
  return instance.exports;
}

// Load Complex FFT WASM for comparison
async function loadComplexWasm() {
  const wasmPath = path.join(__dirname, "..", "dist", "fft_combined.wasm");
  if (!fs.existsSync(wasmPath)) {
    throw new Error(`WASM file not found: ${wasmPath}`);
  }
  const wasmBuffer = fs.readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);
  const instance = await WebAssembly.instantiate(wasmModule);
  return instance.exports;
}

// Run real FFT and extract results
function runRFFT(wasm, input) {
  const n = input.length;
  const n2 = n / 2;
  const memory = wasm.memory;
  const data = new Float64Array(memory.buffer, 0, n);

  // Copy real input to WASM memory
  for (let i = 0; i < n; i++) {
    data[i] = input[i];
  }

  // Precompute twiddles and run rfft
  wasm.precompute_rfft_twiddles(n);
  wasm.rfft(n);

  // Extract results (N/2+1 complex values)
  const resultData = new Float64Array(memory.buffer, 0, (n2 + 1) * 2);
  const real = new Float64Array(n2 + 1);
  const imag = new Float64Array(n2 + 1);
  for (let i = 0; i <= n2; i++) {
    real[i] = resultData[i * 2];
    imag[i] = resultData[i * 2 + 1];
  }

  return { real, imag };
}

// Run complex FFT on real input (im=0) for comparison
function runComplexFFT(wasm, realInput) {
  const n = realInput.length;
  const memory = wasm.memory;
  const data = new Float64Array(memory.buffer, 0, n * 2);

  // Copy input to WASM memory with imaginary part = 0
  for (let i = 0; i < n; i++) {
    data[i * 2] = realInput[i];
    data[i * 2 + 1] = 0;
  }

  // Precompute twiddles and run FFT
  wasm.precompute_twiddles(n);
  wasm.fft(n);

  // Extract all N complex values
  const resultData = new Float64Array(memory.buffer, 0, n * 2);
  const real = new Float64Array(n);
  const imag = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    real[i] = resultData[i * 2];
    imag[i] = resultData[i * 2 + 1];
  }

  return { real, imag };
}

// Tolerance helper: Taylor series trig functions have ~1e-9 accuracy per operation,
// which accumulates with size. Using size-dependent tolerance matching README.
function getTolerance(n) {
  return Math.max(1e-9, n * 5e-11);
}

describe("Real FFT", async () => {
  const realWasm = await loadRealWasm();
  const complexWasm = await loadComplexWasm();
  const sizes = [8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096];

  describe("Impulse response", () => {
    for (const n of sizes) {
      test(`N=${n}: impulse -> flat spectrum`, () => {
        // Input: [1, 0, 0, ..., 0]
        const input = new Float64Array(n);
        input[0] = 1;

        const result = runRFFT(realWasm, input);

        // Expected: all frequency bins should be 1 + 0i
        const tol = getTolerance(n);
        for (let k = 0; k <= n / 2; k++) {
          assert.ok(
            Math.abs(result.real[k] - 1) < tol,
            `Bin ${k} real: expected 1, got ${result.real[k]}`,
          );
          assert.ok(
            Math.abs(result.imag[k]) < tol,
            `Bin ${k} imag: expected 0, got ${result.imag[k]}`,
          );
        }
      });
    }
  });

  describe("DC signal", () => {
    for (const n of sizes) {
      test(`N=${n}: constant -> DC only`, () => {
        // Input: [1, 1, 1, ..., 1]
        const input = new Float64Array(n).fill(1);

        const result = runRFFT(realWasm, input);

        // Expected: DC bin (k=0) should be N, all others should be 0
        const tol = getTolerance(n);
        assert.ok(
          Math.abs(result.real[0] - n) < tol,
          `DC real: expected ${n}, got ${result.real[0]}`,
        );
        assert.ok(Math.abs(result.imag[0]) < tol, `DC imag: expected 0, got ${result.imag[0]}`);

        for (let k = 1; k <= n / 2; k++) {
          assert.ok(
            Math.abs(result.real[k]) < tol,
            `Bin ${k} real: expected 0, got ${result.real[k]}`,
          );
          assert.ok(
            Math.abs(result.imag[k]) < tol,
            `Bin ${k} imag: expected 0, got ${result.imag[k]}`,
          );
        }
      });
    }
  });

  describe("Nyquist signal", () => {
    for (const n of sizes) {
      test(`N=${n}: alternating -> Nyquist only`, () => {
        // Input: [1, -1, 1, -1, ...]
        const input = new Float64Array(n);
        for (let i = 0; i < n; i++) {
          input[i] = i % 2 === 0 ? 1 : -1;
        }

        const result = runRFFT(realWasm, input);
        const tol = getTolerance(n);

        // Expected: Nyquist bin (k=N/2) should be N, all others should be 0
        const n2 = n / 2;
        for (let k = 0; k < n2; k++) {
          assert.ok(
            Math.abs(result.real[k]) < tol,
            `Bin ${k} real: expected 0, got ${result.real[k]}`,
          );
          assert.ok(
            Math.abs(result.imag[k]) < tol,
            `Bin ${k} imag: expected 0, got ${result.imag[k]}`,
          );
        }
        assert.ok(
          Math.abs(result.real[n2] - n) < tol,
          `Nyquist real: expected ${n}, got ${result.real[n2]}`,
        );
        assert.ok(
          Math.abs(result.imag[n2]) < tol,
          `Nyquist imag: expected 0, got ${result.imag[n2]}`,
        );
      });
    }
  });

  describe("Comparison with complex FFT", () => {
    for (const n of sizes) {
      test(`N=${n}: rfft matches complex FFT for real input`, () => {
        // Random real input
        let seed = 12345 + n;
        const rand = () => {
          seed = (seed * 1103515245 + 12345) & 0x7fffffff;
          return (seed / 0x7fffffff) * 2 - 1;
        };

        const input = new Float64Array(n);
        for (let i = 0; i < n; i++) {
          input[i] = rand();
        }

        // Run real FFT
        const rfftResult = runRFFT(realWasm, input);

        // Run complex FFT on same input with im=0
        const cfftResult = runComplexFFT(complexWasm, input);

        // Compare first N/2+1 bins (the unique frequencies for real input)
        const tol = getTolerance(n);
        for (let k = 0; k <= n / 2; k++) {
          assert.ok(
            Math.abs(rfftResult.real[k] - cfftResult.real[k]) < tol,
            `Bin ${k} real: rfft=${rfftResult.real[k]}, cfft=${cfftResult.real[k]}`,
          );
          assert.ok(
            Math.abs(rfftResult.imag[k] - cfftResult.imag[k]) < tol,
            `Bin ${k} imag: rfft=${rfftResult.imag[k]}, cfft=${cfftResult.imag[k]}`,
          );
        }
      });
    }
  });

  describe("Comparison with reference DFT", () => {
    for (const n of sizes) {
      test(`N=${n}: matches reference DFT`, () => {
        // Random real input
        let seed = 54321 + n;
        const rand = () => {
          seed = (seed * 1103515245 + 12345) & 0x7fffffff;
          return (seed / 0x7fffffff) * 2 - 1;
        };

        const input = new Float64Array(n);
        for (let i = 0; i < n; i++) {
          input[i] = rand();
        }

        const actual = runRFFT(realWasm, input);
        const expected = referenceRealDFT(input);

        const tol = getTolerance(n);
        const errors = compareResults(actual, expected, tol);
        if (errors.length > 0) {
          const firstErrors = errors.slice(0, 5);
          const errMsg = firstErrors
            .map((e) => `[${e.index}].${e.component}: got ${e.actual}, expected ${e.expected}`)
            .join("\n");
          assert.fail(`Found ${errors.length} errors:\n${errMsg}`);
        }
      });
    }
  });

  describe("Parseval's theorem", () => {
    for (const n of sizes) {
      test(`N=${n}: energy conservation`, () => {
        // Random real input
        let seed = 98765 + n;
        const rand = () => {
          seed = (seed * 1103515245 + 12345) & 0x7fffffff;
          return (seed / 0x7fffffff) * 2 - 1;
        };

        const input = new Float64Array(n);
        for (let i = 0; i < n; i++) {
          input[i] = rand();
        }

        // Time domain energy: sum of squares
        let timeEnergy = 0;
        for (let i = 0; i < n; i++) {
          timeEnergy += input[i] * input[i];
        }

        // Frequency domain energy
        const result = runRFFT(realWasm, input);
        let freqEnergy = 0;
        const n2 = n / 2;

        // DC component (count once)
        freqEnergy += result.real[0] * result.real[0] + result.imag[0] * result.imag[0];

        // Middle bins (count twice due to conjugate symmetry)
        for (let k = 1; k < n2; k++) {
          freqEnergy += 2 * (result.real[k] * result.real[k] + result.imag[k] * result.imag[k]);
        }

        // Nyquist component (count once)
        freqEnergy += result.real[n2] * result.real[n2] + result.imag[n2] * result.imag[n2];

        // Parseval: time_energy = freq_energy / N
        freqEnergy /= n;

        const tol = getTolerance(n);
        assert.ok(
          Math.abs(timeEnergy - freqEnergy) < tol,
          `Parseval violated: time=${timeEnergy}, freq=${freqEnergy}`,
        );
      });
    }
  });

  describe("Single frequency sinusoids", () => {
    for (const n of [64, 256, 1024]) {
      for (const freq of [1, 2, 4]) {
        if (freq <= n / 2) {
          test(`N=${n}: cosine at frequency ${freq}`, () => {
            // Input: cos(2*pi*freq*i/n)
            const input = new Float64Array(n);
            for (let i = 0; i < n; i++) {
              input[i] = Math.cos((2 * Math.PI * freq * i) / n);
            }

            const result = runRFFT(realWasm, input);
            const tol = getTolerance(n);

            // Expected: peak at bin `freq` with magnitude N/2
            // All other bins should be ~0
            for (let k = 0; k <= n / 2; k++) {
              const magnitude = Math.sqrt(
                result.real[k] * result.real[k] + result.imag[k] * result.imag[k],
              );

              if (k === freq) {
                assert.ok(
                  Math.abs(magnitude - n / 2) < tol,
                  `Bin ${k}: expected magnitude ${n / 2}, got ${magnitude}`,
                );
              } else {
                assert.ok(
                  Math.abs(magnitude) < tol,
                  `Bin ${k}: expected magnitude 0, got ${magnitude}`,
                );
              }
            }
          });

          test(`N=${n}: sine at frequency ${freq}`, () => {
            // Input: sin(2*pi*freq*i/n)
            const input = new Float64Array(n);
            for (let i = 0; i < n; i++) {
              input[i] = Math.sin((2 * Math.PI * freq * i) / n);
            }

            const result = runRFFT(realWasm, input);
            const tol = getTolerance(n);

            // Expected: peak at bin `freq` with magnitude N/2
            // The imaginary part should be -N/2 (for positive frequency)
            for (let k = 0; k <= n / 2; k++) {
              const magnitude = Math.sqrt(
                result.real[k] * result.real[k] + result.imag[k] * result.imag[k],
              );

              if (k === freq) {
                assert.ok(
                  Math.abs(magnitude - n / 2) < tol,
                  `Bin ${k}: expected magnitude ${n / 2}, got ${magnitude}`,
                );
                // For sine, real should be ~0 and imag should be ~ -N/2
                assert.ok(
                  Math.abs(result.real[k]) < tol,
                  `Bin ${k} real: expected ~0, got ${result.real[k]}`,
                );
                assert.ok(
                  Math.abs(result.imag[k] + n / 2) < tol,
                  `Bin ${k} imag: expected ${-n / 2}, got ${result.imag[k]}`,
                );
              } else {
                assert.ok(
                  Math.abs(magnitude) < tol,
                  `Bin ${k}: expected magnitude 0, got ${magnitude}`,
                );
              }
            }
          });
        }
      }
    }
  });
});
