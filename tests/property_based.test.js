/**
 * Property-Based Testing for FFT
 *
 * Uses random inputs to catch bugs that specific test cases miss.
 * The original rfft_32 bug was masked because test inputs had near-zero
 * values for certain bins. Random testing would have caught it.
 *
 * These tests use relaxed tolerances (1e-6 relative) to focus on catching
 * major bugs (swapped values, wrong signs) rather than precision validation.
 * Precision is validated by the other test suites.
 */

import { test, describe } from "node:test";
import fc from "fast-check";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const distDir = path.join(__dirname, "..", "dist");

// Reference DFT implementations
function complexDft(input) {
  const N = input.length / 2;
  const output = new Float64Array(N * 2);
  for (let k = 0; k < N; k++) {
    let sumRe = 0,
      sumIm = 0;
    for (let n = 0; n < N; n++) {
      const angle = (-2 * Math.PI * k * n) / N;
      const cos = Math.cos(angle),
        sin = Math.sin(angle);
      const re = input[n * 2],
        im = input[n * 2 + 1];
      sumRe += re * cos - im * sin;
      sumIm += re * sin + im * cos;
    }
    output[k * 2] = sumRe;
    output[k * 2 + 1] = sumIm;
  }
  return output;
}

function realDft(input) {
  const N = input.length;
  const output = new Float64Array((N / 2 + 1) * 2);
  for (let k = 0; k <= N / 2; k++) {
    let sumRe = 0,
      sumIm = 0;
    for (let n = 0; n < N; n++) {
      const angle = (-2 * Math.PI * k * n) / N;
      sumRe += input[n] * Math.cos(angle);
      sumIm += input[n] * Math.sin(angle);
    }
    output[k * 2] = sumRe;
    output[k * 2 + 1] = sumIm;
  }
  return output;
}

async function loadModule(wasmFile) {
  const wasmPath = path.join(distDir, wasmFile);
  const wasmBuffer = fs.readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);
  return WebAssembly.instantiate(wasmModule);
}

// Relative error check - catches major bugs while allowing FFT's inherent error
// The FFT uses Taylor series approximations that introduce ~1e-6 relative error
function checkRelativeError(got, expected, relTolerance = 1e-5) {
  const absTolerance = 1e-8; // For values near zero
  const err = Math.abs(got - expected);
  const tol = Math.max(absTolerance, Math.abs(expected) * relTolerance);
  return err <= tol;
}

const sizes = [8, 16, 32, 64, 128, 256];

describe("Property-Based FFT Tests", async () => {
  const complexInstance = await loadModule("fft_combined.wasm");
  const realInstance = await loadModule("fft_real_combined.wasm");

  describe("Complex FFT: Random inputs match reference", () => {
    for (const N of sizes) {
      test(`N=${N}`, () => {
        const { fft, precompute_twiddles, memory } = complexInstance.exports;

        fc.assert(
          fc.property(
            fc.array(fc.double({ min: -10, max: 10, noNaN: true, noDefaultInfinity: true }), {
              minLength: N * 2,
              maxLength: N * 2,
            }),
            (inputArray) => {
              const input = new Float64Array(inputArray);
              const expected = complexDft(input);

              const data = new Float64Array(memory.buffer, 0, N * 2);
              data.set(input);
              precompute_twiddles(N);
              fft(N);

              for (let k = 0; k < N; k++) {
                if (
                  !checkRelativeError(data[k * 2], expected[k * 2]) ||
                  !checkRelativeError(data[k * 2 + 1], expected[k * 2 + 1])
                ) {
                  return false;
                }
              }
              return true;
            },
          ),
          { numRuns: 20 },
        );
      });
    }
  });

  describe("Real FFT: Random inputs match reference", () => {
    for (const N of sizes) {
      test(`N=${N}`, () => {
        const { rfft, precompute_rfft_twiddles, memory } = realInstance.exports;

        fc.assert(
          fc.property(
            fc.array(fc.double({ min: -10, max: 10, noNaN: true, noDefaultInfinity: true }), {
              minLength: N,
              maxLength: N,
            }),
            (inputArray) => {
              const input = new Float64Array(inputArray);
              const expected = realDft(input);

              const data = new Float64Array(memory.buffer, 0, N);
              data.set(input);
              precompute_rfft_twiddles(N);
              rfft(N);

              const output = new Float64Array(memory.buffer, 0, (N / 2 + 1) * 2);

              // Check each bin - THE KEY TEST that would catch swapped twiddles
              for (let k = 0; k <= N / 2; k++) {
                if (
                  !checkRelativeError(output[k * 2], expected[k * 2]) ||
                  !checkRelativeError(output[k * 2 + 1], expected[k * 2 + 1])
                ) {
                  console.log(
                    `  Bin ${k} failed: got (${output[k * 2]}, ${output[k * 2 + 1]}), expected (${expected[k * 2]}, ${expected[k * 2 + 1]})`,
                  );
                  return false;
                }
              }
              return true;
            },
          ),
          { numRuns: 20 },
        );
      });
    }
  });

  describe("Complex FFT: Parseval's theorem (energy conservation)", () => {
    for (const N of sizes) {
      test(`N=${N}`, () => {
        const { fft, precompute_twiddles, memory } = complexInstance.exports;

        fc.assert(
          fc.property(
            fc.array(fc.double({ min: -10, max: 10, noNaN: true, noDefaultInfinity: true }), {
              minLength: N * 2,
              maxLength: N * 2,
            }),
            (inputArray) => {
              const input = new Float64Array(inputArray);

              // Time-domain energy
              let timeEnergy = 0;
              for (let i = 0; i < N; i++) {
                timeEnergy += input[i * 2] ** 2 + input[i * 2 + 1] ** 2;
              }

              const data = new Float64Array(memory.buffer, 0, N * 2);
              data.set(input);
              precompute_twiddles(N);
              fft(N);

              // Frequency-domain energy (scaled by 1/N for Parseval)
              let freqEnergy = 0;
              for (let i = 0; i < N; i++) {
                freqEnergy += data[i * 2] ** 2 + data[i * 2 + 1] ** 2;
              }
              freqEnergy /= N;

              return checkRelativeError(freqEnergy, timeEnergy, 1e-6);
            },
          ),
          { numRuns: 20 },
        );
      });
    }
  });

  describe("Real FFT: DC and Nyquist are purely real", () => {
    for (const N of sizes) {
      test(`N=${N}`, () => {
        const { rfft, precompute_rfft_twiddles, memory } = realInstance.exports;

        fc.assert(
          fc.property(
            fc.array(fc.double({ min: -10, max: 10, noNaN: true, noDefaultInfinity: true }), {
              minLength: N,
              maxLength: N,
            }),
            (inputArray) => {
              const input = new Float64Array(inputArray);

              const data = new Float64Array(memory.buffer, 0, N);
              data.set(input);
              precompute_rfft_twiddles(N);
              rfft(N);

              const output = new Float64Array(memory.buffer, 0, (N / 2 + 1) * 2);

              // DC (k=0) and Nyquist (k=N/2) should have zero imaginary part
              const dcIm = Math.abs(output[1]);
              const nyquistIm = Math.abs(output[N + 1]);

              return dcIm < 1e-10 && nyquistIm < 1e-10;
            },
          ),
          { numRuns: 20 },
        );
      });
    }
  });
});
