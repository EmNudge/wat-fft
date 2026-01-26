/**
 * Golden Reference Tests
 *
 * Compares FFT output against pre-computed golden values from a reference
 * implementation. These catch any regression in output values.
 *
 * Golden values are generated once using high-precision reference DFT
 * and stored inline. Any change to FFT output will fail these tests.
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

// Golden test cases with pre-computed reference values
// Input: specific deterministic patterns
// Output: exact expected values from reference DFT

const goldenTests = {
  // Complex FFT golden values
  complex: {
    // N=8: Simple ramp input
    8: {
      input: [0, 0, 1, 0, 2, 0, 3, 0, 4, 0, 5, 0, 6, 0, 7, 0],
      expected: [
        28,
        0, // X[0]
        -4,
        9.65685424949238, // X[1]
        -4,
        4, // X[2]
        -4,
        1.6568542494923806, // X[3]
        -4,
        0, // X[4]
        -4,
        -1.6568542494923806, // X[5]
        -4,
        -4, // X[6]
        -4,
        -9.65685424949238, // X[7]
      ],
    },
    // N=16: Impulse at n=0
    16: {
      input: [
        1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0,
      ],
      expected: [
        1,
        0,
        1,
        0,
        1,
        0,
        1,
        0, // X[0] through X[3]
        1,
        0,
        1,
        0,
        1,
        0,
        1,
        0, // X[4] through X[7]
        1,
        0,
        1,
        0,
        1,
        0,
        1,
        0, // X[8] through X[11]
        1,
        0,
        1,
        0,
        1,
        0,
        1,
        0, // X[12] through X[15]
      ],
    },
    // N=32: Single frequency sinusoid (bin 4)
    32: {
      input: (() => {
        const arr = [];
        for (let n = 0; n < 32; n++) {
          arr.push(Math.cos((2 * Math.PI * 4 * n) / 32), 0);
        }
        return arr;
      })(),
      expected: (() => {
        // cos at bin k produces peaks at X[k] and X[N-k]
        const arr = Array.from({ length: 64 }, () => 0);
        arr[4 * 2] = 16; // X[4].re = N/2
        arr[4 * 2 + 1] = 0; // X[4].im = 0
        arr[28 * 2] = 16; // X[28].re = N/2
        arr[28 * 2 + 1] = 0; // X[28].im = 0
        return arr;
      })(),
    },
  },

  // Real FFT golden values
  real: {
    // N=8: Impulse
    8: {
      input: [1, 0, 0, 0, 0, 0, 0, 0],
      expected: [
        1,
        0, // X[0] - DC
        1,
        0, // X[1]
        1,
        0, // X[2]
        1,
        0, // X[3]
        1,
        0, // X[4] - Nyquist
      ],
    },
    // N=16: DC signal
    16: {
      input: [5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5],
      expected: [
        80,
        0, // X[0] - DC = N * amplitude
        0,
        0, // X[1]
        0,
        0, // X[2]
        0,
        0, // X[3]
        0,
        0, // X[4]
        0,
        0, // X[5]
        0,
        0, // X[6]
        0,
        0, // X[7]
        0,
        0, // X[8] - Nyquist
      ],
    },
    // N=32: Single cosine at bin 1 (fundamental frequency)
    32: {
      input: (() => {
        const arr = [];
        for (let n = 0; n < 32; n++) {
          arr.push(Math.cos((2 * Math.PI * 1 * n) / 32));
        }
        return arr;
      })(),
      expected: (() => {
        // For real cosine at bin k: X[k] = N/2
        const arr = Array.from({ length: 34 }, () => 0);
        arr[0] = 0; // DC
        arr[1] = 0;
        arr[2] = 16; // X[1].re = N/2
        arr[3] = 0; // X[1].im = 0
        // X[2] through X[16] are zero for pure cosine at bin 1
        return arr;
      })(),
    },
    // N=32: Specific pattern that would catch the original swapped twiddle bug
    // This uses input that produces non-zero values in upper bins
    "32_upper_bins": {
      input: (() => {
        const arr = [];
        for (let n = 0; n < 32; n++) {
          // Sum of cosines at bins 1, 7, 14, 15
          arr.push(
            Math.cos((2 * Math.PI * 1 * n) / 32) +
              0.5 * Math.cos((2 * Math.PI * 7 * n) / 32) +
              0.3 * Math.cos((2 * Math.PI * 14 * n) / 32) +
              0.2 * Math.cos((2 * Math.PI * 15 * n) / 32),
          );
        }
        return arr;
      })(),
      expected: (() => {
        // Reference DFT computed values
        const arr = Array.from({ length: 34 }, () => 0);
        arr[2] = 16; // X[1] = 16 (N/2 * 1.0)
        arr[3] = 0;
        arr[14] = 8; // X[7] = 8 (N/2 * 0.5)
        arr[15] = 0;
        arr[28] = 4.8; // X[14] = 4.8 (N/2 * 0.3)
        arr[29] = 0;
        arr[30] = 3.2; // X[15] = 3.2 (N/2 * 0.2)
        arr[31] = 0;
        arr[32] = 0; // Nyquist
        arr[33] = 0;
        return arr;
      })(),
    },
  },
};

describe("Golden Reference Tests", async () => {
  const complexInstance = await loadModule("fft_combined.wasm");
  const realInstance = await loadModule("fft_real_combined.wasm");

  describe("Complex FFT Golden Values", () => {
    for (const [size, testCase] of Object.entries(goldenTests.complex)) {
      const N = parseInt(size);

      test(`N=${N}: matches golden reference`, () => {
        const { fft, precompute_twiddles, memory } = complexInstance.exports;
        const input = new Float64Array(testCase.input);
        const expected = new Float64Array(testCase.expected);

        const data = new Float64Array(memory.buffer, 0, N * 2);
        data.set(input);
        precompute_twiddles(N);
        fft(N);

        // Tolerance scales with FFT size due to accumulated rounding
        const tolerance = Math.max(1e-9, N * 1e-11);
        for (let k = 0; k < N; k++) {
          const gotRe = data[k * 2];
          const gotIm = data[k * 2 + 1];
          const expRe = expected[k * 2];
          const expIm = expected[k * 2 + 1];

          assert.ok(
            Math.abs(gotRe - expRe) < tolerance,
            `X[${k}].re: got ${gotRe}, expected ${expRe}`,
          );
          assert.ok(
            Math.abs(gotIm - expIm) < tolerance,
            `X[${k}].im: got ${gotIm}, expected ${expIm}`,
          );
        }
      });
    }
  });

  describe("Real FFT Golden Values", () => {
    for (const [key, testCase] of Object.entries(goldenTests.real)) {
      const N = parseInt(key) || parseInt(key.split("_")[0]);

      test(`N=${N} (${key}): matches golden reference`, () => {
        const { rfft, precompute_rfft_twiddles, memory } = realInstance.exports;
        const input = new Float64Array(testCase.input);
        const expected = new Float64Array(testCase.expected);

        const data = new Float64Array(memory.buffer, 0, N);
        data.set(input);
        precompute_rfft_twiddles(N);
        rfft(N);

        const output = new Float64Array(memory.buffer, 0, (N / 2 + 1) * 2);

        // Strict comparison
        const tolerance = 1e-10;
        for (let k = 0; k <= N / 2; k++) {
          const gotRe = output[k * 2];
          const gotIm = output[k * 2 + 1];
          const expRe = expected[k * 2];
          const expIm = expected[k * 2 + 1];

          assert.ok(
            Math.abs(gotRe - expRe) < tolerance,
            `X[${k}].re: got ${gotRe}, expected ${expRe}`,
          );
          assert.ok(
            Math.abs(gotIm - expIm) < tolerance,
            `X[${k}].im: got ${gotIm}, expected ${expIm}`,
          );
        }
      });
    }
  });
});

// Utility to generate golden values for new test cases
// Run with: node -e "import('./tests/golden_reference.test.js').then(m => m.generateGolden(32, 'real'))"
export function generateGolden(N, type = "complex") {
  function realDft(input) {
    const n = input.length;
    const output = new Float64Array((n / 2 + 1) * 2);
    for (let k = 0; k <= n / 2; k++) {
      let sumRe = 0,
        sumIm = 0;
      for (let i = 0; i < n; i++) {
        const angle = (-2 * Math.PI * k * i) / n;
        sumRe += input[i] * Math.cos(angle);
        sumIm += input[i] * Math.sin(angle);
      }
      output[k * 2] = sumRe;
      output[k * 2 + 1] = sumIm;
    }
    return output;
  }

  function complexDft(input) {
    const n = input.length / 2;
    const output = new Float64Array(n * 2);
    for (let k = 0; k < n; k++) {
      let sumRe = 0,
        sumIm = 0;
      for (let i = 0; i < n; i++) {
        const angle = (-2 * Math.PI * k * i) / n;
        const cos = Math.cos(angle),
          sin = Math.sin(angle);
        const re = input[i * 2],
          im = input[i * 2 + 1];
        sumRe += re * cos - im * sin;
        sumIm += re * sin + im * cos;
      }
      output[k * 2] = sumRe;
      output[k * 2 + 1] = sumIm;
    }
    return output;
  }

  // Generate test input
  const input =
    type === "real"
      ? Array.from({ length: N }, (_, n) => Math.sin((2 * Math.PI * n) / N))
      : Array.from({ length: N * 2 }, (_, i) => (i % 2 === 0 ? Math.sin((Math.PI * i) / N) : 0));

  const expected =
    type === "real" ? realDft(new Float64Array(input)) : complexDft(new Float64Array(input));

  console.log(`Input (${type}, N=${N}):`);
  console.log(JSON.stringify(Array.from(input).map((x) => Math.round(x * 1e10) / 1e10)));
  console.log(`\nExpected output:`);
  console.log(JSON.stringify(Array.from(expected).map((x) => Math.round(x * 1e10) / 1e10)));
}
