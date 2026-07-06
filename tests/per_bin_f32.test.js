/**
 * Per-Bin Validation for the f32 modules
 *
 * The existing per_bin_validation.test.js covers only the f64 modules
 * (fft_combined, fft_real_combined). This file gives the same treatment
 * to the f32 modules — most importantly the flagship split-format module
 * whose rfft_split/irfft_split are the newest, most-optimized code paths.
 *
 * For each bin k we feed a pure sinusoid (or, for inverse transforms, a
 * single-bin spectrum) and verify all the energy lands in exactly the
 * right place. This catches bin-specific bugs that aggregate error
 * metrics can hide (like the original rfft_32 bug affecting bins 9-15).
 *
 * Tolerance is N * 5e-6: single-bin spectra peak at N/2..N, and f32 FFT
 * error is a few ULPs of that peak (~N * 1e-6 worst observed).
 */

import { test, describe } from "node:test";
import assert from "node:assert";
import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const distDir = path.join(__dirname, "..", "dist");

async function loadModule(wasmFile) {
  const wasmBuffer = fs.readFileSync(path.join(distDir, wasmFile));
  const { instance } = await WebAssembly.instantiate(wasmBuffer, {});
  return instance.exports;
}

const COMPLEX_SIZES = [8, 16, 32, 64, 128, 256];
const RFFT_DUAL_SIZES = [8, 16, 32, 64, 128, 256];
const RFFT_SPLIT_SIZES = [32, 64, 128, 256]; // rfft_split requires N >= 32

const tol = (n) => n * 5e-6;

/**
 * Check a complex spectrum (as separate index->[re,im] accessor) against
 * the expectation for cosine input at targetBin: magnitude N/2 at bins
 * targetBin and N-targetBin (or N at 0/Nyquist), ~0 elsewhere.
 */
function checkComplexCosineSpectrum(n, targetBin, getBin) {
  for (let k = 0; k < n; k++) {
    const [re, im] = getBin(k);
    const magnitude = Math.hypot(re, im);
    const isDcOrNyquist = targetBin === 0 || targetBin === n / 2;
    const isTarget = isDcOrNyquist ? k === targetBin : k === targetBin || k === n - targetBin;
    const expected = isTarget ? (isDcOrNyquist ? n : n / 2) : 0;
    assert.ok(
      Math.abs(magnitude - expected) < tol(n),
      `target bin ${targetBin}, bin ${k}: expected magnitude ${expected}, got ${magnitude}`,
    );
  }
}

/** Same for a real FFT's N/2+1 bins. */
function checkRealSpectrum(n, targetBin, getBin, phase) {
  for (let k = 0; k <= n / 2; k++) {
    const [re, im] = getBin(k);
    const magnitude = Math.hypot(re, im);
    if (k === targetBin) {
      const expected = targetBin === 0 || targetBin === n / 2 ? n : n / 2;
      assert.ok(
        Math.abs(magnitude - expected) < tol(n),
        `bin ${k}: expected magnitude ${expected}, got ${magnitude} (re=${re}, im=${im})`,
      );
      if (phase === "cosine") {
        assert.ok(Math.abs(im) < tol(n), `bin ${k}: cosine should be real, im=${im}`);
        assert.ok(re > 0, `bin ${k}: cosine should have positive real, re=${re}`);
      } else if (phase === "sine") {
        assert.ok(Math.abs(re) < tol(n), `bin ${k}: sine should be imaginary, re=${re}`);
        assert.ok(im < 0, `bin ${k}: sine should have negative imag, im=${im}`);
      }
    } else {
      assert.ok(
        magnitude < tol(n),
        `target bin ${targetBin}, bin ${k}: expected ~0, got ${magnitude}`,
      );
    }
  }
}

describe("Per-bin validation: f32 modules", async () => {
  const split = await loadModule("fft_split_native_f32.wasm");
  const dual = await loadModule("fft_stockham_f32_dual.wasm");
  const realDual = await loadModule("fft_real_f32_dual.wasm");

  describe("fft_split_native_f32: fft_split (complex, split format)", () => {
    for (const n of COMPLEX_SIZES) {
      test(`N=${n}: every bin`, () => {
        const re = new Float32Array(split.memory.buffer, split.REAL_OFFSET, n);
        const im = new Float32Array(split.memory.buffer, split.IMAG_OFFSET, n);
        split.precompute_twiddles_split(n);

        for (let targetBin = 0; targetBin < n; targetBin++) {
          for (let i = 0; i < n; i++) {
            re[i] = Math.cos((2 * Math.PI * targetBin * i) / n);
            im[i] = 0;
          }
          split.fft_split(n);
          checkComplexCosineSpectrum(n, targetBin, (k) => [re[k], im[k]]);
        }
      });
    }
  });

  describe("fft_stockham_f32_dual: fft (complex, interleaved)", () => {
    for (const n of COMPLEX_SIZES) {
      test(`N=${n}: every bin`, () => {
        const data = new Float32Array(dual.memory.buffer, 0, n * 2);
        dual.precompute_twiddles(n);

        for (let targetBin = 0; targetBin < n; targetBin++) {
          for (let i = 0; i < n; i++) {
            data[i * 2] = Math.cos((2 * Math.PI * targetBin * i) / n);
            data[i * 2 + 1] = 0;
          }
          dual.fft(n);
          checkComplexCosineSpectrum(n, targetBin, (k) => [data[k * 2], data[k * 2 + 1]]);
        }
      });
    }
  });

  describe("fft_split_native_f32: rfft_split", () => {
    for (const n of RFFT_SPLIT_SIZES) {
      test(`N=${n}: every bin, cosine and sine`, () => {
        split.precompute_rfft_twiddles_split(n);

        for (let targetBin = 0; targetBin <= n / 2; targetBin++) {
          const input = new Float32Array(split.memory.buffer, 0, n);
          for (let i = 0; i < n; i++) {
            input[i] = Math.cos((2 * Math.PI * targetBin * i) / n);
          }
          split.rfft_split(n);
          const out = new Float32Array(split.memory.buffer, 0, n + 2);
          checkRealSpectrum(n, targetBin, (k) => [out[2 * k], out[2 * k + 1]], "cosine");

          if (targetBin > 0 && targetBin < n / 2) {
            const sineInput = new Float32Array(split.memory.buffer, 0, n);
            for (let i = 0; i < n; i++) {
              sineInput[i] = Math.sin((2 * Math.PI * targetBin * i) / n);
            }
            split.rfft_split(n);
            const sineOut = new Float32Array(split.memory.buffer, 0, n + 2);
            checkRealSpectrum(n, targetBin, (k) => [sineOut[2 * k], sineOut[2 * k + 1]], "sine");
          }
        }
      });
    }
  });

  describe("fft_split_native_f32: irfft_split (single-bin spectrum -> sinusoid)", () => {
    for (const n of RFFT_SPLIT_SIZES) {
      test(`N=${n}: every bin`, () => {
        split.precompute_rfft_twiddles_split(n);

        for (let targetBin = 0; targetBin <= n / 2; targetBin++) {
          const spec = new Float32Array(split.memory.buffer, 0, n + 2);
          spec.fill(0);
          spec[2 * targetBin] = targetBin === 0 || targetBin === n / 2 ? n : n / 2;
          split.irfft_split(n);

          const out = new Float32Array(split.memory.buffer, 0, n);
          for (let i = 0; i < n; i++) {
            const expected = Math.cos((2 * Math.PI * targetBin * i) / n);
            assert.ok(
              Math.abs(out[i] - expected) < tol(n) / n + 1e-5,
              `bin ${targetBin}, sample ${i}: expected ${expected}, got ${out[i]}`,
            );
          }
        }
      });
    }
  });

  describe("fft_real_f32_dual: rfft", () => {
    for (const n of RFFT_DUAL_SIZES) {
      test(`N=${n}: every bin, cosine and sine`, () => {
        realDual.precompute_rfft_twiddles(n);

        for (let targetBin = 0; targetBin <= n / 2; targetBin++) {
          const input = new Float32Array(realDual.memory.buffer, 0, n);
          for (let i = 0; i < n; i++) {
            input[i] = Math.cos((2 * Math.PI * targetBin * i) / n);
          }
          realDual.rfft(n);
          const out = new Float32Array(realDual.memory.buffer, 0, n + 2);
          checkRealSpectrum(n, targetBin, (k) => [out[2 * k], out[2 * k + 1]], "cosine");

          if (targetBin > 0 && targetBin < n / 2) {
            const sineInput = new Float32Array(realDual.memory.buffer, 0, n);
            for (let i = 0; i < n; i++) {
              sineInput[i] = Math.sin((2 * Math.PI * targetBin * i) / n);
            }
            realDual.rfft(n);
            const sineOut = new Float32Array(realDual.memory.buffer, 0, n + 2);
            checkRealSpectrum(n, targetBin, (k) => [sineOut[2 * k], sineOut[2 * k + 1]], "sine");
          }
        }
      });
    }
  });

  describe("fft_real_f32_dual: irfft (single-bin spectrum -> sinusoid)", () => {
    for (const n of RFFT_DUAL_SIZES) {
      test(`N=${n}: every bin`, () => {
        realDual.precompute_rfft_twiddles(n);

        for (let targetBin = 0; targetBin <= n / 2; targetBin++) {
          const spec = new Float32Array(realDual.memory.buffer, 0, n + 2);
          spec.fill(0);
          spec[2 * targetBin] = targetBin === 0 || targetBin === n / 2 ? n : n / 2;
          realDual.irfft(n);

          const out = new Float32Array(realDual.memory.buffer, 0, n);
          for (let i = 0; i < n; i++) {
            const expected = Math.cos((2 * Math.PI * targetBin * i) / n);
            assert.ok(
              Math.abs(out[i] - expected) < tol(n) / n + 1e-5,
              `bin ${targetBin}, sample ${i}: expected ${expected}, got ${out[i]}`,
            );
          }
        }
      });
    }
  });
});
