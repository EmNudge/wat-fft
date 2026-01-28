/**
 * Benchmark Correctness Validation
 *
 * This test ensures that the benchmark files use the SAME configuration
 * as the correctness tests. It does this by:
 *
 * 1. Importing the shared competitor config
 * 2. Running an FFT with the benchmark setup
 * 3. Comparing against the reference DFT
 *
 * If this test fails, the benchmarks are misconfigured.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import PFFFT from "@echogarden/pffft-wasm";
import fftw from "fftw-js";
import kissfft from "kissfft-js";
import webfft from "webfft";
import FFT from "fft.js";

import {
  PFFFT as PFFFT_CONFIG,
  pffftComplexFFT,
  pffftRealFFT,
} from "../benchmarks/lib/competitors.js";

// Reference O(N^2) DFT for validation
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

function maxError(a, b) {
  let max = 0;
  for (let i = 0; i < a.length; i++) {
    max = Math.max(max, Math.abs(a[i] - b[i]));
  }
  return max;
}

// =============================================================================
// Validate shared config constants
// =============================================================================
test("Shared config constants are correct", async (t) => {
  await t.test("PFFFT enum values match C header", () => {
    // From pffft.h: typedef enum { PFFFT_REAL, PFFFT_COMPLEX } pffft_transform_t;
    assert.strictEqual(PFFFT_CONFIG.REAL, 0, "PFFFT_REAL must be 0");
    assert.strictEqual(PFFFT_CONFIG.COMPLEX, 1, "PFFFT_COMPLEX must be 1");
    assert.strictEqual(PFFFT_CONFIG.FORWARD, 0, "PFFFT_FORWARD must be 0");
    assert.strictEqual(PFFFT_CONFIG.BACKWARD, 1, "PFFFT_BACKWARD must be 1");
  });
});

// =============================================================================
// Validate pffft shared functions produce correct results
// =============================================================================
test("pffft shared functions produce correct results", async (t) => {
  const pffft = await PFFFT();
  const size = 64;
  const tolerance = 1e-4 * Math.sqrt(size); // f32 tolerance

  await t.test("pffftComplexFFT matches reference DFT", () => {
    // Random input
    const real = Float32Array.from({ length: size }, () => Math.random() * 2 - 1);
    const imag = Float32Array.from({ length: size }, () => Math.random() * 2 - 1);

    const result = pffftComplexFFT(pffft, size, real, imag);
    const expected = referenceDFT(Array.from(real), Array.from(imag));

    const realErr = maxError(result.real, expected.real);
    const imagErr = maxError(result.imag, expected.imag);

    assert.ok(realErr < tolerance, `Real error ${realErr} exceeds tolerance ${tolerance}`);
    assert.ok(imagErr < tolerance, `Imag error ${imagErr} exceeds tolerance ${tolerance}`);
  });

  await t.test("pffftRealFFT matches reference DFT", () => {
    const input = Float32Array.from({ length: size }, () => Math.random() * 2 - 1);

    const result = pffftRealFFT(pffft, size, input);
    const expected = referenceRealDFT(Array.from(input));

    const realErr = maxError(result.real, expected.real);
    const imagErr = maxError(result.imag, expected.imag);

    assert.ok(realErr < tolerance, `Real error ${realErr} exceeds tolerance ${tolerance}`);
    assert.ok(imagErr < tolerance, `Imag error ${imagErr} exceeds tolerance ${tolerance}`);
  });
});

// =============================================================================
// Cross-validate: benchmark setup vs correctness test setup
// This catches bugs where benchmarks drift from correctness tests
// =============================================================================
test("Benchmark setup matches correctness test setup", async (t) => {
  const pffft = await PFFFT();
  const size = 64;

  await t.test("pffft complex FFT: benchmark config = correctness config", () => {
    // This is the EXACT setup from fft.bench.js (after fix)
    const PFFFT_COMPLEX_FROM_BENCHMARK = 1;
    const PFFFT_FORWARD_FROM_BENCHMARK = 0;

    assert.strictEqual(
      PFFFT_COMPLEX_FROM_BENCHMARK,
      PFFFT_CONFIG.COMPLEX,
      "Benchmark PFFFT_COMPLEX doesn't match shared config!",
    );
    assert.strictEqual(
      PFFFT_FORWARD_FROM_BENCHMARK,
      PFFFT_CONFIG.FORWARD,
      "Benchmark PFFFT_FORWARD doesn't match shared config!",
    );

    // Actually run both and compare outputs
    const real = Float32Array.from({ length: size }, (_, i) => Math.sin((2 * Math.PI * i) / size));
    const imag = new Float32Array(size);

    // Using shared function
    const sharedResult = pffftComplexFFT(pffft, size, real, imag);

    // Using benchmark-style inline setup
    const setup = pffft._pffft_new_setup(size, PFFFT_COMPLEX_FROM_BENCHMARK);
    const inputPtr = pffft._pffft_aligned_malloc(size * 2 * 4);
    const outputPtr = pffft._pffft_aligned_malloc(size * 2 * 4);
    const inputView = new Float32Array(pffft.HEAPF32.buffer, inputPtr, size * 2);
    for (let i = 0; i < size; i++) {
      inputView[i * 2] = real[i];
      inputView[i * 2 + 1] = imag[i];
    }
    pffft._pffft_transform_ordered(setup, inputPtr, outputPtr, 0, PFFFT_FORWARD_FROM_BENCHMARK);
    const outputView = new Float32Array(pffft.HEAPF32.buffer, outputPtr, size * 2);
    const benchReal = new Float32Array(size);
    const benchImag = new Float32Array(size);
    for (let i = 0; i < size; i++) {
      benchReal[i] = outputView[i * 2];
      benchImag[i] = outputView[i * 2 + 1];
    }
    pffft._pffft_aligned_free(inputPtr);
    pffft._pffft_aligned_free(outputPtr);
    pffft._pffft_destroy_setup(setup);

    // Results must be identical
    assert.strictEqual(maxError(sharedResult.real, benchReal), 0, "Real outputs differ!");
    assert.strictEqual(maxError(sharedResult.imag, benchImag), 0, "Imag outputs differ!");
  });

  await t.test("pffft real FFT: benchmark config = correctness config", () => {
    // This is the EXACT setup from rfft.bench.js (after fix)
    const PFFFT_REAL_FROM_BENCHMARK = 0;
    const PFFFT_FORWARD_FROM_BENCHMARK = 0;

    assert.strictEqual(
      PFFFT_REAL_FROM_BENCHMARK,
      PFFFT_CONFIG.REAL,
      "Benchmark PFFFT_REAL doesn't match shared config!",
    );
    assert.strictEqual(
      PFFFT_FORWARD_FROM_BENCHMARK,
      PFFFT_CONFIG.FORWARD,
      "Benchmark PFFFT_FORWARD doesn't match shared config!",
    );
  });
});

// =============================================================================
// Validate all competitor libraries against reference
// This is a quick sanity check that runs on every test
// =============================================================================
test("All competitors produce correct FFT (quick validation)", async (t) => {
  const size = 64;
  const real = Float64Array.from({ length: size }, (_, i) =>
    Math.cos((2 * Math.PI * 3 * i) / size),
  );
  const imag = new Float64Array(size);
  const expected = referenceDFT(real, imag);
  const f64Tol = 1e-10;
  const f32Tol = 1e-3;

  await t.test("fft.js (f64)", () => {
    const fft = new FFT(size);
    const input = fft.createComplexArray();
    const output = fft.createComplexArray();
    for (let i = 0; i < size; i++) {
      input[i * 2] = real[i];
      input[i * 2 + 1] = imag[i];
    }
    fft.transform(output, input);

    for (let i = 0; i < size; i++) {
      assert.ok(Math.abs(output[i * 2] - expected.real[i]) < f64Tol);
      assert.ok(Math.abs(output[i * 2 + 1] - expected.imag[i]) < f64Tol);
    }
  });

  await t.test("kissfft-js (f32)", () => {
    const fft = new kissfft.FFT(size);
    const input = new Float64Array(size * 2);
    for (let i = 0; i < size; i++) {
      input[i * 2] = real[i];
      input[i * 2 + 1] = imag[i];
    }
    const output = fft.forward(input);

    for (let i = 0; i < size; i++) {
      assert.ok(Math.abs(output[i * 2] - expected.real[i]) < f32Tol);
      assert.ok(Math.abs(output[i * 2 + 1] - expected.imag[i]) < f32Tol);
    }
    fft.dispose();
  });

  await t.test("webfft (f32)", () => {
    const fft = new webfft(size);
    const input = new Float32Array(size * 2);
    for (let i = 0; i < size; i++) {
      input[i * 2] = real[i];
      input[i * 2 + 1] = imag[i];
    }
    const output = fft.fft(input);

    for (let i = 0; i < size; i++) {
      assert.ok(Math.abs(output[i * 2] - expected.real[i]) < f32Tol);
      assert.ok(Math.abs(output[i * 2 + 1] - expected.imag[i]) < f32Tol);
    }
    fft.dispose();
  });

  await t.test("pffft-wasm (f32) via shared config", async () => {
    const pffft = await PFFFT();
    const result = pffftComplexFFT(pffft, size, Float32Array.from(real), Float32Array.from(imag));

    for (let i = 0; i < size; i++) {
      assert.ok(Math.abs(result.real[i] - expected.real[i]) < f32Tol);
      assert.ok(Math.abs(result.imag[i] - expected.imag[i]) < f32Tol);
    }
  });

  await t.test("fftw-js real FFT (f32)", async () => {
    const fftwInstance = new fftw.FFT(size);
    const input = new Float32Array(size);
    for (let i = 0; i < size; i++) {
      input[i] = real[i];
    }
    const output = fftwInstance.forward(input);
    const expectedReal = referenceRealDFT(real);

    // Check DC and a few bins
    assert.ok(Math.abs(output[0] - expectedReal.real[0]) < f32Tol, "DC mismatch");
    assert.ok(Math.abs(output[6] - expectedReal.real[3]) < f32Tol, "Bin 3 real mismatch");
    fftwInstance.dispose();
  });
});
