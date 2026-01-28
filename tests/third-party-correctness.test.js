/**
 * Third-Party FFT Library Correctness Tests
 *
 * Validates that all third-party FFT libraries used in benchmarks
 * produce correct results by comparing against our O(N^2) reference DFT.
 *
 * This ensures benchmark comparisons are meaningful - we're comparing
 * against correctly implemented FFTs.
 *
 * NOTES:
 * - pffft-wasm: Uses PFFFT_COMPLEX=1, PFFFT_REAL=0 (see benchmarks/lib/competitors.js)
 * - kissfft-js: Uses f32 internally despite accepting Float64Array
 * - fftw-js: Export is fftw.FFT (not fftw.FFTW)
 *
 * See also: tests/benchmark-correctness.test.js for validation that
 * benchmarks use the same configuration as these correctness tests.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import FFT from "fft.js";
import * as fftJsSimple from "fft-js";
import kissfft from "kissfft-js";
import webfft from "webfft";
import PFFFT from "@echogarden/pffft-wasm";
import fftw from "fftw-js";

import {
  QUICK_SIZES,
  referenceDFT,
  arraysApproxEqual,
  signals,
  maxError,
} from "./correctness/test-helper.js";

// Tolerances for different precisions
const TOLERANCE = {
  f64: { rel: 1e-9, abs: 1e-8 },
  f32: { rel: 1e-4, abs: 1e-4 },
};

// Scale tolerance by sqrt(N) for accumulated floating point errors
function scaledTolerance(n, precision) {
  const base = TOLERANCE[precision];
  const scale = Math.sqrt(n);
  return { rel: base.rel * scale, abs: base.abs * scale };
}

/**
 * Test that an FFT library produces correct results
 * @param {string} name - Library name for reporting
 * @param {function} runFFT - Function that takes (real, imag) arrays and returns {real, imag}
 * @param {string} precision - 'f64' or 'f32'
 * @param {number[]} sizes - Array of sizes to test
 * @param {object} t - Test context
 */
async function testFFTLibrary(name, runFFT, precision, sizes, t) {
  for (const size of sizes) {
    await t.test(`N=${size}`, async () => {
      const tol = scaledTolerance(size, precision);

      const testSignals = [
        { name: "impulse", signal: signals.impulse(size) },
        { name: "constant", signal: signals.constant(size) },
        { name: "alternating", signal: signals.alternating(size) },
        { name: "cosine", signal: signals.cosine(size, 3) },
        { name: "random", signal: signals.random(size, size * 17) },
      ];

      for (const { name: sigName, signal } of testSignals) {
        const result = runFFT(signal.real, signal.imag);
        const expected = referenceDFT(signal.real, signal.imag);

        const realErr = maxError(result.real, expected.real);
        const imagErr = maxError(result.imag, expected.imag);

        assert.ok(
          arraysApproxEqual(result.real, expected.real, tol.rel, tol.abs),
          `${sigName} real: max error ${realErr.toExponential(2)} exceeds tolerance ${tol.abs.toExponential(2)}`,
        );
        assert.ok(
          arraysApproxEqual(result.imag, expected.imag, tol.rel, tol.abs),
          `${sigName} imag: max error ${imagErr.toExponential(2)} exceeds tolerance ${tol.abs.toExponential(2)}`,
        );
      }
    });
  }
}

// =============================================================================
// fft.js (indutny) - Radix-4 pure JavaScript
// =============================================================================
test("fft.js (indutny) correctness", async (t) => {
  function runFFT(real, imag) {
    const n = real.length;
    const fft = new FFT(n);

    // fft.js uses interleaved complex format
    const input = fft.createComplexArray();
    for (let i = 0; i < n; i++) {
      input[i * 2] = real[i];
      input[i * 2 + 1] = imag[i];
    }

    const output = fft.createComplexArray();
    fft.transform(output, input);

    // Extract results
    const outReal = new Float64Array(n);
    const outImag = new Float64Array(n);
    for (let i = 0; i < n; i++) {
      outReal[i] = output[i * 2];
      outImag[i] = output[i * 2 + 1];
    }

    return { real: outReal, imag: outImag };
  }

  await testFFTLibrary("fft.js", runFFT, "f64", QUICK_SIZES, t);
});

// =============================================================================
// fft-js - Simple Cooley-Tukey pure JavaScript
// =============================================================================
test("fft-js correctness", async (t) => {
  function runFFT(real, imag) {
    const n = real.length;

    // fft-js uses array of [real, imag] pairs
    const signal = [];
    for (let i = 0; i < n; i++) {
      signal.push([real[i], imag[i]]);
    }

    const result = fftJsSimple.fft(signal);

    // Extract results
    const outReal = new Float64Array(n);
    const outImag = new Float64Array(n);
    for (let i = 0; i < n; i++) {
      outReal[i] = result[i][0];
      outImag[i] = result[i][1];
    }

    return { real: outReal, imag: outImag };
  }

  await testFFTLibrary("fft-js", runFFT, "f64", QUICK_SIZES, t);
});

// =============================================================================
// kissfft-js - Emscripten port of Kiss FFT
// NOTE: Despite accepting Float64Array, internally uses f32 precision!
// =============================================================================
test("kissfft-js correctness", async (t) => {
  for (const size of QUICK_SIZES) {
    await t.test(`N=${size}`, async () => {
      const fft = new kissfft.FFT(size);
      // Use f32 tolerance because kissfft-js uses f32 internally
      const tol = scaledTolerance(size, "f32");

      try {
        const testSignals = [
          { name: "impulse", signal: signals.impulse(size) },
          { name: "constant", signal: signals.constant(size) },
          { name: "random", signal: signals.random(size, size * 23) },
        ];

        for (const { name: sigName, signal } of testSignals) {
          // kissfft uses interleaved Float64Array
          const input = new Float64Array(size * 2);
          for (let i = 0; i < size; i++) {
            input[i * 2] = signal.real[i];
            input[i * 2 + 1] = signal.imag[i];
          }

          const output = fft.forward(input);
          const expected = referenceDFT(signal.real, signal.imag);

          // Extract results
          const outReal = new Float64Array(size);
          const outImag = new Float64Array(size);
          for (let i = 0; i < size; i++) {
            outReal[i] = output[i * 2];
            outImag[i] = output[i * 2 + 1];
          }

          const realErr = maxError(outReal, expected.real);
          const imagErr = maxError(outImag, expected.imag);

          assert.ok(
            arraysApproxEqual(outReal, expected.real, tol.rel, tol.abs),
            `${sigName} real: max error ${realErr.toExponential(2)}`,
          );
          assert.ok(
            arraysApproxEqual(outImag, expected.imag, tol.rel, tol.abs),
            `${sigName} imag: max error ${imagErr.toExponential(2)}`,
          );
        }
      } finally {
        fft.dispose();
      }
    });
  }
});

// =============================================================================
// webfft - Meta-library (uses kissWasm by default)
// =============================================================================
test("webfft correctness", async (t) => {
  for (const size of QUICK_SIZES) {
    await t.test(`N=${size}`, async () => {
      const fft = new webfft(size);
      // Use default backend (kissWasm)

      // webfft uses f32 precision
      const tol = scaledTolerance(size, "f32");

      try {
        const testSignals = [
          { name: "impulse", signal: signals.impulse(size) },
          { name: "constant", signal: signals.constant(size) },
          { name: "random", signal: signals.random(size, size * 29) },
        ];

        for (const { name: sigName, signal } of testSignals) {
          // webfft uses interleaved Float32Array
          const input = new Float32Array(size * 2);
          for (let i = 0; i < size; i++) {
            input[i * 2] = signal.real[i];
            input[i * 2 + 1] = signal.imag[i];
          }

          const output = fft.fft(input);
          const expected = referenceDFT(signal.real, signal.imag);

          // Extract results
          const outReal = new Float64Array(size);
          const outImag = new Float64Array(size);
          for (let i = 0; i < size; i++) {
            outReal[i] = output[i * 2];
            outImag[i] = output[i * 2 + 1];
          }

          const realErr = maxError(outReal, expected.real);
          const imagErr = maxError(outImag, expected.imag);

          assert.ok(
            arraysApproxEqual(outReal, expected.real, tol.rel, tol.abs),
            `${sigName} real: max error ${realErr.toExponential(2)}`,
          );
          assert.ok(
            arraysApproxEqual(outImag, expected.imag, tol.rel, tol.abs),
            `${sigName} imag: max error ${imagErr.toExponential(2)}`,
          );
        }
      } finally {
        fft.dispose();
      }
    });
  }
});

// =============================================================================
// pffft-wasm - PFFFT with SIMD support
// Uses shared config from benchmarks/lib/competitors.js to ensure consistency
// =============================================================================
test("pffft-wasm correctness", async (t) => {
  const pffft = await PFFFT();

  // Import from shared config to ensure benchmarks and tests use same values
  const { PFFFT: PFFFT_CONFIG } = await import("../benchmarks/lib/competitors.js");
  const PFFFT_COMPLEX = PFFFT_CONFIG.COMPLEX;
  const PFFFT_FORWARD = PFFFT_CONFIG.FORWARD;

  // pffft requires minimum size of 32 for complex FFT
  const pffftSizes = QUICK_SIZES.filter((s) => s >= 32);

  for (const size of pffftSizes) {
    await t.test(`N=${size}`, async () => {
      const setup = pffft._pffft_new_setup(size, PFFFT_COMPLEX);
      const inputPtr = pffft._pffft_aligned_malloc(size * 2 * 4);
      const outputPtr = pffft._pffft_aligned_malloc(size * 2 * 4);

      // pffft uses f32 precision
      const tol = scaledTolerance(size, "f32");

      try {
        const testSignals = [
          { name: "impulse", signal: signals.impulse(size) },
          { name: "constant", signal: signals.constant(size) },
          { name: "random", signal: signals.random(size, size * 31) },
        ];

        for (const { name: sigName, signal } of testSignals) {
          // pffft uses interleaved Float32Array
          const inputView = new Float32Array(pffft.HEAPF32.buffer, inputPtr, size * 2);
          for (let i = 0; i < size; i++) {
            inputView[i * 2] = signal.real[i];
            inputView[i * 2 + 1] = signal.imag[i];
          }

          pffft._pffft_transform_ordered(setup, inputPtr, outputPtr, 0, PFFFT_FORWARD);

          const outputView = new Float32Array(pffft.HEAPF32.buffer, outputPtr, size * 2);
          const expected = referenceDFT(signal.real, signal.imag);

          // Extract results
          const outReal = new Float64Array(size);
          const outImag = new Float64Array(size);
          for (let i = 0; i < size; i++) {
            outReal[i] = outputView[i * 2];
            outImag[i] = outputView[i * 2 + 1];
          }

          const realErr = maxError(outReal, expected.real);
          const imagErr = maxError(outImag, expected.imag);

          assert.ok(
            arraysApproxEqual(outReal, expected.real, tol.rel, tol.abs),
            `${sigName} real: max error ${realErr.toExponential(2)}`,
          );
          assert.ok(
            arraysApproxEqual(outImag, expected.imag, tol.rel, tol.abs),
            `${sigName} imag: max error ${imagErr.toExponential(2)}`,
          );
        }
      } finally {
        pffft._pffft_aligned_free(inputPtr);
        pffft._pffft_aligned_free(outputPtr);
        pffft._pffft_destroy_setup(setup);
      }
    });
  }
});

// =============================================================================
// Shared: Reference Real DFT for all Real FFT tests
// =============================================================================
function referenceRealDFT(real) {
  const n = real.length;
  const n2 = n / 2;
  const outReal = new Float64Array(n2 + 1);
  const outImag = new Float64Array(n2 + 1);

  for (let k = 0; k <= n2; k++) {
    let sumReal = 0;
    let sumImag = 0;
    for (let j = 0; j < n; j++) {
      const angle = (-2 * Math.PI * k * j) / n;
      sumReal += real[j] * Math.cos(angle);
      sumImag += real[j] * Math.sin(angle);
    }
    outReal[k] = sumReal;
    outImag[k] = sumImag;
  }

  return { real: outReal, imag: outImag };
}

// Real FFT test signals generator
function realTestSignals(size) {
  return [
    {
      name: "impulse",
      real: Float64Array.from({ length: size }, (_, i) => (i === 0 ? 1 : 0)),
    },
    { name: "constant", real: new Float64Array(size).fill(1) },
    {
      name: "cosine",
      real: Float64Array.from({ length: size }, (_, i) => Math.cos((2 * Math.PI * 3 * i) / size)),
    },
    {
      name: "random",
      real: (() => {
        let s = size * 37;
        const rand = () => {
          s = (s * 1103515245 + 12345) & 0x7fffffff;
          return (s / 0x7fffffff) * 2 - 1;
        };
        return Float64Array.from({ length: size }, () => rand());
      })(),
    },
  ];
}

// =============================================================================
// kissfft-js - Real FFT (FFTR class)
// =============================================================================
test("kissfft-js correctness (Real FFT)", async (t) => {
  // kissfft FFTR requires size >= 4
  const rfftSizes = QUICK_SIZES.filter((s) => s >= 4);

  for (const size of rfftSizes) {
    await t.test(`N=${size}`, async () => {
      const fft = new kissfft.FFTR(size);
      // kissfft uses f32 internally
      const tol = scaledTolerance(size, "f32");

      try {
        for (const { name: sigName, real } of realTestSignals(size)) {
          // kissfft FFTR expects Float64Array input (but uses f32 internally)
          const input = new Float64Array(real);
          const output = fft.forward(input);

          const expected = referenceRealDFT(real);

          // kissfft FFTR output: interleaved real/imag for N/2+1 complex values
          const numComplex = size / 2 + 1;
          const outReal = new Float64Array(numComplex);
          const outImag = new Float64Array(numComplex);

          for (let i = 0; i < numComplex; i++) {
            outReal[i] = output[i * 2];
            outImag[i] = output[i * 2 + 1];
          }

          const realErr = maxError(outReal, expected.real);
          const imagErr = maxError(outImag, expected.imag);

          assert.ok(
            arraysApproxEqual(outReal, expected.real, tol.rel, tol.abs),
            `${sigName} real: max error ${realErr.toExponential(2)}`,
          );
          assert.ok(
            arraysApproxEqual(outImag, expected.imag, tol.rel, tol.abs),
            `${sigName} imag: max error ${imagErr.toExponential(2)}`,
          );
        }
      } finally {
        fft.dispose();
      }
    });
  }
});

// =============================================================================
// webfft - Real FFT (fftr method)
// BUG: webfft fftr has incorrect DC computation - constant signal returns 0 instead of N.
// Impulse works correctly but other signals have wrong DC values.
// The complex FFT (fft method) works correctly.
// =============================================================================
test("webfft correctness (Real FFT)", async (t) => {
  t.skip("webfft fftr has DC computation bug - constant signal returns 0");
});

// =============================================================================
// pffft-wasm - Real FFT (PFFFT_REAL mode)
// Uses shared config from benchmarks/lib/competitors.js to ensure consistency
// =============================================================================
test("pffft-wasm correctness (Real FFT)", async (t) => {
  const pffft = await PFFFT();

  // Import from shared config to ensure benchmarks and tests use same values
  const { PFFFT: PFFFT_CONFIG } = await import("../benchmarks/lib/competitors.js");
  const PFFFT_REAL = PFFFT_CONFIG.REAL;
  const PFFFT_FORWARD = PFFFT_CONFIG.FORWARD;

  // pffft real FFT requires minimum size of 32
  const pffftSizes = QUICK_SIZES.filter((s) => s >= 32);

  for (const size of pffftSizes) {
    await t.test(`N=${size}`, async () => {
      const setup = pffft._pffft_new_setup(size, PFFFT_REAL);
      const inputPtr = pffft._pffft_aligned_malloc(size * 4);
      const outputPtr = pffft._pffft_aligned_malloc(size * 4);

      const tol = scaledTolerance(size, "f32");

      try {
        for (const { name: sigName, real } of realTestSignals(size)) {
          const inputView = new Float32Array(pffft.HEAPF32.buffer, inputPtr, size);
          for (let i = 0; i < size; i++) {
            inputView[i] = real[i];
          }

          pffft._pffft_transform_ordered(setup, inputPtr, outputPtr, 0, PFFFT_FORWARD);

          const outputView = new Float32Array(pffft.HEAPF32.buffer, outputPtr, size);
          const expected = referenceRealDFT(real);

          // pffft real FFT "ordered" output format:
          // [DC_real, Nyquist_real, bin1_real, bin1_imag, bin2_real, bin2_imag, ...]
          // DC and Nyquist are both real (imag=0)
          const numComplex = size / 2 + 1;
          const outReal = new Float64Array(numComplex);
          const outImag = new Float64Array(numComplex);

          // Bin 0 (DC) - real only
          outReal[0] = outputView[0];
          outImag[0] = 0;

          // Bin N/2 (Nyquist) - real only
          outReal[size / 2] = outputView[1];
          outImag[size / 2] = 0;

          // Bins 1 to N/2-1 - complex
          for (let i = 1; i < size / 2; i++) {
            outReal[i] = outputView[2 * i];
            outImag[i] = outputView[2 * i + 1];
          }

          const realErr = maxError(outReal, expected.real);
          const imagErr = maxError(outImag, expected.imag);

          assert.ok(
            arraysApproxEqual(outReal, expected.real, tol.rel, tol.abs),
            `${sigName} real: max error ${realErr.toExponential(2)}`,
          );
          assert.ok(
            arraysApproxEqual(outImag, expected.imag, tol.rel, tol.abs),
            `${sigName} imag: max error ${imagErr.toExponential(2)}`,
          );
        }
      } finally {
        pffft._pffft_aligned_free(inputPtr);
        pffft._pffft_aligned_free(outputPtr);
        pffft._pffft_destroy_setup(setup);
      }
    });
  }
});

// =============================================================================
// fftw-js - Emscripten port of FFTW (Real FFT)
// NOTE: The export is fftw.FFT (not fftw.FFTW)
// =============================================================================
test("fftw-js correctness (Real FFT)", async (t) => {
  // fftw-js minimum size is 8
  const fftwSizes = QUICK_SIZES.filter((s) => s >= 8);

  for (const size of fftwSizes) {
    await t.test(`N=${size}`, async () => {
      // CORRECT: fftw.FFT (not fftw.FFTW)
      const fftwInstance = new fftw.FFT(size);

      // fftw-js uses f32 precision
      const tol = scaledTolerance(size, "f32");

      try {
        for (const { name: sigName, real } of realTestSignals(size)) {
          // fftw-js expects Float32Array input
          const input = new Float32Array(size);
          for (let i = 0; i < size; i++) {
            input[i] = real[i];
          }

          const output = fftwInstance.forward(input);
          const expected = referenceRealDFT(real);

          // fftw-js output format: interleaved real/imag for N/2+1 complex values
          const numComplex = size / 2 + 1;
          const outReal = new Float64Array(numComplex);
          const outImag = new Float64Array(numComplex);

          for (let i = 0; i < numComplex; i++) {
            outReal[i] = output[i * 2];
            outImag[i] = output[i * 2 + 1];
          }

          const realErr = maxError(outReal, expected.real);
          const imagErr = maxError(outImag, expected.imag);

          assert.ok(
            arraysApproxEqual(outReal, expected.real, tol.rel, tol.abs),
            `${sigName} real: max error ${realErr.toExponential(2)}`,
          );
          assert.ok(
            arraysApproxEqual(outImag, expected.imag, tol.rel, tol.abs),
            `${sigName} imag: max error ${imagErr.toExponential(2)}`,
          );
        }
      } finally {
        fftwInstance.dispose();
      }
    });
  }
});

// =============================================================================
// Cross-library consistency test
// =============================================================================
test("Cross-library consistency", async (t) => {
  await t.test("All f64 libraries agree", async () => {
    const size = 64;
    const signal = signals.random(size, 42);

    // fft.js
    const fftjs = new FFT(size);
    const fftjsInput = fftjs.createComplexArray();
    for (let i = 0; i < size; i++) {
      fftjsInput[i * 2] = signal.real[i];
      fftjsInput[i * 2 + 1] = signal.imag[i];
    }
    const fftjsOutput = fftjs.createComplexArray();
    fftjs.transform(fftjsOutput, fftjsInput);

    // fft-js
    const fftJsSignal = [];
    for (let i = 0; i < size; i++) {
      fftJsSignal.push([signal.real[i], signal.imag[i]]);
    }
    const fftJsResult = fftJsSimple.fft(fftJsSignal);

    // Compare fft.js vs fft-js (both are true f64)
    for (let i = 0; i < size; i++) {
      assert.ok(
        Math.abs(fftjsOutput[i * 2] - fftJsResult[i][0]) < 1e-10,
        `fft.js vs fft-js real[${i}] mismatch`,
      );
      assert.ok(
        Math.abs(fftjsOutput[i * 2 + 1] - fftJsResult[i][1]) < 1e-10,
        `fft.js vs fft-js imag[${i}] mismatch`,
      );
    }
  });

  await t.test("f32 libraries agree within precision", async () => {
    const size = 64;
    const signal = signals.random(size, 42);

    // webfft (f32)
    const wfft = new webfft(size);
    const wfftInput = new Float32Array(size * 2);
    for (let i = 0; i < size; i++) {
      wfftInput[i * 2] = signal.real[i];
      wfftInput[i * 2 + 1] = signal.imag[i];
    }
    const wfftOutput = wfft.fft(wfftInput);

    // kissfft (internally f32)
    const kiss = new kissfft.FFT(size);
    const kissInput = new Float64Array(size * 2);
    for (let i = 0; i < size; i++) {
      kissInput[i * 2] = signal.real[i];
      kissInput[i * 2 + 1] = signal.imag[i];
    }
    const kissOutput = kiss.forward(kissInput);

    // Compare webfft vs kissfft (both use f32 internally)
    const f32Tol = 1e-4;
    for (let i = 0; i < size; i++) {
      assert.ok(
        Math.abs(wfftOutput[i * 2] - kissOutput[i * 2]) < f32Tol,
        `webfft vs kissfft real[${i}] mismatch: ${wfftOutput[i * 2]} vs ${kissOutput[i * 2]}`,
      );
      assert.ok(
        Math.abs(wfftOutput[i * 2 + 1] - kissOutput[i * 2 + 1]) < f32Tol,
        `webfft vs kissfft imag[${i}] mismatch`,
      );
    }

    wfft.dispose();
    kiss.dispose();
  });
});
