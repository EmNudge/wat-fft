/**
 * Per-Bin Validation Tests
 *
 * Tests each frequency bin independently using single-frequency inputs.
 * This catches bugs that only affect specific bins (like the original
 * rfft_32 bug that only affected bins 9-15).
 *
 * For each bin k, we input a pure sinusoid at that frequency and verify
 * the energy appears in the correct output bin.
 */

import { test, describe } from "node:test";
import assert from "node:assert";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const distDir = path.join(__dirname, "..", "dist");

async function loadModule(wasmFile) {
  const wasmPath = path.join(distDir, wasmFile);
  const wasmBuffer = fs.readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);
  return WebAssembly.instantiate(wasmModule);
}

const sizes = [8, 16, 32, 64, 128, 256];

describe("Per-Bin Validation Tests", async () => {
  const complexInstance = await loadModule("fft_combined.wasm");
  const realInstance = await loadModule("fft_real_combined.wasm");

  describe("Complex FFT: Single frequency per bin", () => {
    for (const N of sizes) {
      describe(`N=${N}`, () => {
        for (let targetBin = 0; targetBin < N; targetBin++) {
          test(`bin ${targetBin}: cosine input produces correct output`, () => {
            const { fft, precompute_twiddles, memory } = complexInstance.exports;

            // Input: cos(2π * targetBin * n / N) as complex (real part only)
            const input = new Float64Array(N * 2);
            for (let n = 0; n < N; n++) {
              input[n * 2] = Math.cos((2 * Math.PI * targetBin * n) / N);
              input[n * 2 + 1] = 0;
            }

            const data = new Float64Array(memory.buffer, 0, N * 2);
            data.set(input);
            precompute_twiddles(N);
            fft(N);

            // Expected: energy at bin targetBin and bin (N - targetBin) for cosine
            // X[k] = N/2 for k = targetBin and k = N - targetBin (when targetBin > 0)
            // X[0] = N for k = 0 (DC)
            const tolerance = N * 1e-10;

            for (let k = 0; k < N; k++) {
              const magnitude = Math.sqrt(data[k * 2] ** 2 + data[k * 2 + 1] ** 2);

              if (targetBin === 0) {
                // DC input: all energy at bin 0
                if (k === 0) {
                  assert.ok(
                    Math.abs(magnitude - N) < tolerance,
                    `Bin ${k}: expected magnitude ${N}, got ${magnitude}`,
                  );
                } else {
                  assert.ok(magnitude < tolerance, `Bin ${k}: expected ~0, got ${magnitude}`);
                }
              } else if (targetBin === N / 2) {
                // Nyquist input: all energy at bin N/2
                if (k === N / 2) {
                  assert.ok(
                    Math.abs(magnitude - N) < tolerance,
                    `Bin ${k}: expected magnitude ${N}, got ${magnitude}`,
                  );
                } else {
                  assert.ok(magnitude < tolerance, `Bin ${k}: expected ~0, got ${magnitude}`);
                }
              } else {
                // General case: energy split between bin k and bin N-k
                const isTarget = k === targetBin || k === N - targetBin;
                if (isTarget) {
                  assert.ok(
                    Math.abs(magnitude - N / 2) < tolerance,
                    `Bin ${k}: expected magnitude ${N / 2}, got ${magnitude}`,
                  );
                } else {
                  assert.ok(magnitude < tolerance, `Bin ${k}: expected ~0, got ${magnitude}`);
                }
              }
            }
          });
        }
      });
    }
  });

  describe("Real FFT: Single frequency per bin", () => {
    for (const N of sizes) {
      describe(`N=${N}`, () => {
        // For real FFT, we only have bins 0 to N/2
        for (let targetBin = 0; targetBin <= N / 2; targetBin++) {
          test(`bin ${targetBin}: cosine input produces correct output`, () => {
            const { rfft, precompute_rfft_twiddles, memory } = realInstance.exports;

            // Input: cos(2π * targetBin * n / N)
            const input = new Float64Array(N);
            for (let n = 0; n < N; n++) {
              input[n] = Math.cos((2 * Math.PI * targetBin * n) / N);
            }

            const data = new Float64Array(memory.buffer, 0, N);
            data.set(input);
            precompute_rfft_twiddles(N);
            rfft(N);

            const output = new Float64Array(memory.buffer, 0, (N / 2 + 1) * 2);
            const tolerance = N * 1e-10;

            // Check each output bin
            for (let k = 0; k <= N / 2; k++) {
              const re = output[k * 2];
              const im = output[k * 2 + 1];
              const magnitude = Math.sqrt(re ** 2 + im ** 2);

              if (k === targetBin) {
                // This bin should have the energy
                const expectedMag = targetBin === 0 || targetBin === N / 2 ? N : N / 2;
                assert.ok(
                  Math.abs(magnitude - expectedMag) < tolerance,
                  `Bin ${k}: expected magnitude ${expectedMag}, got ${magnitude} (re=${re}, im=${im})`,
                );

                // For cosine input, the phase should be 0 (purely real, positive)
                if (magnitude > tolerance) {
                  assert.ok(
                    Math.abs(im) < tolerance,
                    `Bin ${k}: expected imaginary ≈ 0 for cosine, got ${im}`,
                  );
                  assert.ok(re > 0, `Bin ${k}: expected positive real for cosine, got ${re}`);
                }
              } else {
                // Other bins should be near zero
                assert.ok(
                  magnitude < tolerance,
                  `Bin ${k}: expected ~0, got magnitude ${magnitude} (re=${re}, im=${im})`,
                );
              }
            }
          });

          test(`bin ${targetBin}: sine input produces correct output`, () => {
            const { rfft, precompute_rfft_twiddles, memory } = realInstance.exports;

            // Skip DC and Nyquist for sine (sin(0) = 0, sin(N/2 * n) for integer n is 0 or alternating)
            if (targetBin === 0 || targetBin === N / 2) return;

            // Input: sin(2π * targetBin * n / N)
            const input = new Float64Array(N);
            for (let n = 0; n < N; n++) {
              input[n] = Math.sin((2 * Math.PI * targetBin * n) / N);
            }

            const data = new Float64Array(memory.buffer, 0, N);
            data.set(input);
            precompute_rfft_twiddles(N);
            rfft(N);

            const output = new Float64Array(memory.buffer, 0, (N / 2 + 1) * 2);
            const tolerance = N * 1e-10;

            for (let k = 0; k <= N / 2; k++) {
              const re = output[k * 2];
              const im = output[k * 2 + 1];
              const magnitude = Math.sqrt(re ** 2 + im ** 2);

              if (k === targetBin) {
                const expectedMag = N / 2;
                assert.ok(
                  Math.abs(magnitude - expectedMag) < tolerance,
                  `Bin ${k}: expected magnitude ${expectedMag}, got ${magnitude}`,
                );

                // For sine input, the phase should be -π/2 (purely imaginary, negative)
                if (magnitude > tolerance) {
                  assert.ok(
                    Math.abs(re) < tolerance,
                    `Bin ${k}: expected real ≈ 0 for sine, got ${re}`,
                  );
                  assert.ok(im < 0, `Bin ${k}: expected negative imaginary for sine, got ${im}`);
                }
              } else {
                assert.ok(
                  magnitude < tolerance,
                  `Bin ${k}: expected ~0, got magnitude ${magnitude}`,
                );
              }
            }
          });
        }
      });
    }
  });

  describe("Real FFT: All bins simultaneously (mixed frequencies)", () => {
    for (const N of sizes) {
      test(`N=${N}: multiple frequencies detected correctly`, () => {
        const { rfft, precompute_rfft_twiddles, memory } = realInstance.exports;

        // Input: sum of cosines at various bins with different amplitudes
        const amplitudes = new Map();
        const testBins = [1, Math.floor(N / 4), Math.floor(N / 2) - 1];
        testBins.forEach((bin, i) => amplitudes.set(bin, 1 / (i + 1)));

        const input = new Float64Array(N);
        for (let n = 0; n < N; n++) {
          let value = 0;
          for (const [bin, amp] of amplitudes) {
            value += amp * Math.cos((2 * Math.PI * bin * n) / N);
          }
          input[n] = value;
        }

        const data = new Float64Array(memory.buffer, 0, N);
        data.set(input);
        precompute_rfft_twiddles(N);
        rfft(N);

        const output = new Float64Array(memory.buffer, 0, (N / 2 + 1) * 2);
        const tolerance = N * 1e-9;

        // Verify each bin
        for (let k = 0; k <= N / 2; k++) {
          const re = output[k * 2];
          const im = output[k * 2 + 1];
          const magnitude = Math.sqrt(re ** 2 + im ** 2);

          if (amplitudes.has(k)) {
            const expectedMag = (N / 2) * amplitudes.get(k);
            assert.ok(
              Math.abs(magnitude - expectedMag) < tolerance,
              `Bin ${k}: expected magnitude ${expectedMag.toFixed(4)}, got ${magnitude.toFixed(4)}`,
            );
          } else if (k !== 0 && k !== N / 2) {
            // Non-target bins should be near zero (DC and Nyquist may have residual)
            assert.ok(magnitude < tolerance, `Bin ${k}: expected ~0, got ${magnitude.toFixed(6)}`);
          }
        }
      });
    }
  });

  // This specific test would have caught the original rfft_32 bug
  describe("Regression: rfft_32 upper bins (bins 9-15)", () => {
    test("N=32: each upper bin (9-15) individually", () => {
      const { rfft, precompute_rfft_twiddles, memory } = realInstance.exports;
      const N = 32;
      const tolerance = N * 1e-10;

      for (let targetBin = 9; targetBin <= 15; targetBin++) {
        // Test cosine at this bin
        const input = new Float64Array(N);
        for (let n = 0; n < N; n++) {
          input[n] = Math.cos((2 * Math.PI * targetBin * n) / N);
        }

        const data = new Float64Array(memory.buffer, 0, N);
        data.set(input);
        precompute_rfft_twiddles(N);
        rfft(N);

        const output = new Float64Array(memory.buffer, 0, (N / 2 + 1) * 2);

        // Check that energy is in the correct bin
        const re = output[targetBin * 2];
        const im = output[targetBin * 2 + 1];
        const magnitude = Math.sqrt(re ** 2 + im ** 2);

        assert.ok(
          Math.abs(magnitude - N / 2) < tolerance,
          `Bin ${targetBin}: expected magnitude ${N / 2}, got ${magnitude}`,
        );
        assert.ok(Math.abs(im) < tolerance, `Bin ${targetBin}: expected im ≈ 0, got ${im}`);

        // Check that other bins are near zero
        for (let k = 0; k <= N / 2; k++) {
          if (k === targetBin) continue;
          const otherMag = Math.sqrt(output[k * 2] ** 2 + output[k * 2 + 1] ** 2);
          assert.ok(
            otherMag < tolerance,
            `Testing bin ${targetBin}: bin ${k} should be ~0, got ${otherMag}`,
          );
        }
      }
    });
  });
});
