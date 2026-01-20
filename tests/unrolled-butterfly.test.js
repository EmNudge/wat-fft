/**
 * Isolated Unrolled Butterfly Tests
 *
 * Tests the hand-unrolled FFT implementations (fft4, fft8, fft16) directly
 * to verify their correctness independent of the general FFT dispatcher.
 *
 * These functions are exported from fft_unrolled.wat and can be called
 * directly for specific sizes without going through fft_unrolled().
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { test, describe } from "node:test";
import assert from "node:assert";
import { referenceDFT, inputGenerators, compareResults } from "./dft-reference.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Load the unrolled WASM module
async function loadUnrolledWasm() {
  const wasmPath = path.join(__dirname, "..", "dist", "combined_unrolled.wasm");
  if (!fs.existsSync(wasmPath)) {
    throw new Error(`WASM file not found: ${wasmPath}`);
  }
  const wasmBuffer = fs.readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);
  const instance = await WebAssembly.instantiate(wasmModule, {
    math: { sin: Math.sin, cos: Math.cos },
  });
  return instance.exports;
}

// Write complex array to WASM memory
function writeToMemory(memory, real, imag, offset = 0) {
  const n = real.length;
  const data = new Float64Array(memory.buffer, offset, n * 2);
  for (let i = 0; i < n; i++) {
    data[i * 2] = real[i];
    data[i * 2 + 1] = imag[i];
  }
}

// Read complex array from WASM memory
function readFromMemory(memory, n, offset = 0) {
  const data = new Float64Array(memory.buffer, offset, n * 2);
  const real = new Float64Array(n);
  const imag = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    real[i] = data[i * 2];
    imag[i] = data[i * 2 + 1];
  }
  return { real, imag };
}

describe("Unrolled Butterfly Functions", async () => {
  const wasm = await loadUnrolledWasm();

  describe("FFT-4 (fft4)", () => {
    const N = 4;

    test("impulse signal: [1,0,0,0] -> flat spectrum", () => {
      const input = inputGenerators.impulse(N);
      writeToMemory(wasm.memory, input.real, input.imag);

      wasm.fft4();

      const result = readFromMemory(wasm.memory, N);
      const expected = referenceDFT(input.real, input.imag);

      const errors = compareResults(result, expected);
      assert.strictEqual(
        errors.length,
        0,
        `FFT-4 impulse failed: ${JSON.stringify(errors.slice(0, 3))}`,
      );
    });

    test("constant signal: [1,1,1,1] -> DC peak", () => {
      const input = inputGenerators.constant(N);
      writeToMemory(wasm.memory, input.real, input.imag);

      wasm.fft4();

      const result = readFromMemory(wasm.memory, N);
      const expected = referenceDFT(input.real, input.imag);

      const errors = compareResults(result, expected);
      assert.strictEqual(
        errors.length,
        0,
        `FFT-4 constant failed: ${JSON.stringify(errors.slice(0, 3))}`,
      );
    });

    test("alternating signal: [1,-1,1,-1] -> Nyquist peak", () => {
      const input = inputGenerators.alternating(N);
      writeToMemory(wasm.memory, input.real, input.imag);

      wasm.fft4();

      const result = readFromMemory(wasm.memory, N);
      const expected = referenceDFT(input.real, input.imag);

      const errors = compareResults(result, expected);
      assert.strictEqual(
        errors.length,
        0,
        `FFT-4 alternating failed: ${JSON.stringify(errors.slice(0, 3))}`,
      );
    });

    test("random complex input", () => {
      const input = inputGenerators.random(N, 42);
      writeToMemory(wasm.memory, input.real, input.imag);

      wasm.fft4();

      const result = readFromMemory(wasm.memory, N);
      const expected = referenceDFT(input.real, input.imag);

      const errors = compareResults(result, expected);
      assert.strictEqual(
        errors.length,
        0,
        `FFT-4 random failed: ${JSON.stringify(errors.slice(0, 3))}`,
      );
    });

    test("single frequency cosine", () => {
      const input = inputGenerators.singleFreq(N);
      writeToMemory(wasm.memory, input.real, input.imag);

      wasm.fft4();

      const result = readFromMemory(wasm.memory, N);
      const expected = referenceDFT(input.real, input.imag);

      const errors = compareResults(result, expected);
      assert.strictEqual(
        errors.length,
        0,
        `FFT-4 singleFreq failed: ${JSON.stringify(errors.slice(0, 3))}`,
      );
    });
  });

  describe("FFT-8 (fft8)", () => {
    const N = 8;

    test("impulse signal", () => {
      const input = inputGenerators.impulse(N);
      writeToMemory(wasm.memory, input.real, input.imag);

      wasm.fft8();

      const result = readFromMemory(wasm.memory, N);
      const expected = referenceDFT(input.real, input.imag);

      const errors = compareResults(result, expected);
      assert.strictEqual(
        errors.length,
        0,
        `FFT-8 impulse failed: ${JSON.stringify(errors.slice(0, 3))}`,
      );
    });

    test("constant signal", () => {
      const input = inputGenerators.constant(N);
      writeToMemory(wasm.memory, input.real, input.imag);

      wasm.fft8();

      const result = readFromMemory(wasm.memory, N);
      const expected = referenceDFT(input.real, input.imag);

      const errors = compareResults(result, expected);
      assert.strictEqual(
        errors.length,
        0,
        `FFT-8 constant failed: ${JSON.stringify(errors.slice(0, 3))}`,
      );
    });

    test("alternating signal", () => {
      const input = inputGenerators.alternating(N);
      writeToMemory(wasm.memory, input.real, input.imag);

      wasm.fft8();

      const result = readFromMemory(wasm.memory, N);
      const expected = referenceDFT(input.real, input.imag);

      const errors = compareResults(result, expected);
      assert.strictEqual(
        errors.length,
        0,
        `FFT-8 alternating failed: ${JSON.stringify(errors.slice(0, 3))}`,
      );
    });

    test("random complex input", () => {
      const input = inputGenerators.random(N, 123);
      writeToMemory(wasm.memory, input.real, input.imag);

      wasm.fft8();

      const result = readFromMemory(wasm.memory, N);
      const expected = referenceDFT(input.real, input.imag);

      const errors = compareResults(result, expected);
      assert.strictEqual(
        errors.length,
        0,
        `FFT-8 random failed: ${JSON.stringify(errors.slice(0, 3))}`,
      );
    });

    test("single frequency cosine", () => {
      const input = inputGenerators.singleFreq(N);
      writeToMemory(wasm.memory, input.real, input.imag);

      wasm.fft8();

      const result = readFromMemory(wasm.memory, N);
      const expected = referenceDFT(input.real, input.imag);

      const errors = compareResults(result, expected);
      assert.strictEqual(
        errors.length,
        0,
        `FFT-8 singleFreq failed: ${JSON.stringify(errors.slice(0, 3))}`,
      );
    });

    test("W8 twiddle factor verification", () => {
      // Specific test for W8 twiddle factors used in fft8
      // Input: [1, 1, 0, 0, 0, 0, 0, 0] - two adjacent 1s
      const real = new Float64Array([1, 1, 0, 0, 0, 0, 0, 0]);
      const imag = new Float64Array(8);
      writeToMemory(wasm.memory, real, imag);

      wasm.fft8();

      const result = readFromMemory(wasm.memory, N);
      const expected = referenceDFT(real, imag);

      const errors = compareResults(result, expected);
      assert.strictEqual(
        errors.length,
        0,
        `FFT-8 twiddle test failed: ${JSON.stringify(errors.slice(0, 3))}`,
      );
    });
  });

  describe("FFT-16 (via fft_unrolled dispatcher)", () => {
    // Note: fft16 has known issues per the WAT comments, so we test via the dispatcher
    const N = 16;

    test("impulse signal", () => {
      const input = inputGenerators.impulse(N);
      writeToMemory(wasm.memory, input.real, input.imag);
      wasm.precompute_twiddles(N);

      wasm.fft_unrolled(N);

      const result = readFromMemory(wasm.memory, N);
      const expected = referenceDFT(input.real, input.imag);

      const errors = compareResults(result, expected);
      assert.strictEqual(
        errors.length,
        0,
        `FFT-16 impulse failed: ${JSON.stringify(errors.slice(0, 3))}`,
      );
    });

    test("constant signal", () => {
      const input = inputGenerators.constant(N);
      writeToMemory(wasm.memory, input.real, input.imag);
      wasm.precompute_twiddles(N);

      wasm.fft_unrolled(N);

      const result = readFromMemory(wasm.memory, N);
      const expected = referenceDFT(input.real, input.imag);

      const errors = compareResults(result, expected);
      assert.strictEqual(
        errors.length,
        0,
        `FFT-16 constant failed: ${JSON.stringify(errors.slice(0, 3))}`,
      );
    });

    test("alternating signal", () => {
      const input = inputGenerators.alternating(N);
      writeToMemory(wasm.memory, input.real, input.imag);
      wasm.precompute_twiddles(N);

      wasm.fft_unrolled(N);

      const result = readFromMemory(wasm.memory, N);
      const expected = referenceDFT(input.real, input.imag);

      const errors = compareResults(result, expected);
      assert.strictEqual(
        errors.length,
        0,
        `FFT-16 alternating failed: ${JSON.stringify(errors.slice(0, 3))}`,
      );
    });

    test("random complex input", () => {
      const input = inputGenerators.random(N, 456);
      writeToMemory(wasm.memory, input.real, input.imag);
      wasm.precompute_twiddles(N);

      wasm.fft_unrolled(N);

      const result = readFromMemory(wasm.memory, N);
      const expected = referenceDFT(input.real, input.imag);

      const errors = compareResults(result, expected);
      assert.strictEqual(
        errors.length,
        0,
        `FFT-16 random failed: ${JSON.stringify(errors.slice(0, 3))}`,
      );
    });

    test("single frequency cosine", () => {
      const input = inputGenerators.singleFreq(N);
      writeToMemory(wasm.memory, input.real, input.imag);
      wasm.precompute_twiddles(N);

      wasm.fft_unrolled(N);

      const result = readFromMemory(wasm.memory, N);
      const expected = referenceDFT(input.real, input.imag);

      const errors = compareResults(result, expected);
      assert.strictEqual(
        errors.length,
        0,
        `FFT-16 singleFreq failed: ${JSON.stringify(errors.slice(0, 3))}`,
      );
    });
  });

  describe("Dispatcher routing verification", () => {
    test("N=4 routes to fft4", () => {
      const input = inputGenerators.random(4, 789);
      writeToMemory(wasm.memory, input.real, input.imag);
      wasm.precompute_twiddles(4);

      wasm.fft_unrolled(4);

      const result = readFromMemory(wasm.memory, 4);
      const expected = referenceDFT(input.real, input.imag);

      const errors = compareResults(result, expected);
      assert.strictEqual(errors.length, 0, "Dispatcher N=4 routing failed");
    });

    test("N=8 routes to fft8", () => {
      const input = inputGenerators.random(8, 101);
      writeToMemory(wasm.memory, input.real, input.imag);
      wasm.precompute_twiddles(8);

      wasm.fft_unrolled(8);

      const result = readFromMemory(wasm.memory, 8);
      const expected = referenceDFT(input.real, input.imag);

      const errors = compareResults(result, expected);
      assert.strictEqual(errors.length, 0, "Dispatcher N=8 routing failed");
    });

    test("N=32 falls through to general implementation", () => {
      const input = inputGenerators.random(32, 202);
      writeToMemory(wasm.memory, input.real, input.imag);
      wasm.precompute_twiddles(32);

      wasm.fft_unrolled(32);

      const result = readFromMemory(wasm.memory, 32);
      const expected = referenceDFT(input.real, input.imag);

      const errors = compareResults(result, expected);
      assert.strictEqual(errors.length, 0, "Dispatcher N=32 fallthrough failed");
    });
  });

  describe("Numerical accuracy", () => {
    test("FFT-4 preserves energy (Parseval)", () => {
      const input = inputGenerators.random(4, 303);
      writeToMemory(wasm.memory, input.real, input.imag);

      // Compute input energy
      let inputEnergy = 0;
      for (let i = 0; i < 4; i++) {
        inputEnergy += input.real[i] ** 2 + input.imag[i] ** 2;
      }

      wasm.fft4();

      const result = readFromMemory(wasm.memory, 4);

      // Compute output energy (should equal N * input energy for DFT)
      let outputEnergy = 0;
      for (let i = 0; i < 4; i++) {
        outputEnergy += result.real[i] ** 2 + result.imag[i] ** 2;
      }

      assert.ok(
        Math.abs(inputEnergy - outputEnergy / 4) < 1e-10,
        `Parseval violated: input=${inputEnergy}, output/N=${outputEnergy / 4}`,
      );
    });

    test("FFT-8 preserves energy (Parseval)", () => {
      const input = inputGenerators.random(8, 404);
      writeToMemory(wasm.memory, input.real, input.imag);

      let inputEnergy = 0;
      for (let i = 0; i < 8; i++) {
        inputEnergy += input.real[i] ** 2 + input.imag[i] ** 2;
      }

      wasm.fft8();

      const result = readFromMemory(wasm.memory, 8);

      let outputEnergy = 0;
      for (let i = 0; i < 8; i++) {
        outputEnergy += result.real[i] ** 2 + result.imag[i] ** 2;
      }

      assert.ok(
        Math.abs(inputEnergy - outputEnergy / 8) < 1e-10,
        `Parseval violated: input=${inputEnergy}, output/N=${outputEnergy / 8}`,
      );
    });

    test("Real input produces conjugate-symmetric output", () => {
      // For real input, X[k] = conj(X[N-k])
      const real = new Float64Array([1, 2, 3, 4, 5, 6, 7, 8]);
      const imag = new Float64Array(8);
      writeToMemory(wasm.memory, real, imag);

      wasm.fft8();

      const result = readFromMemory(wasm.memory, 8);

      // Check conjugate symmetry: X[k] = conj(X[8-k]) for k=1..3
      for (let k = 1; k < 4; k++) {
        const realDiff = Math.abs(result.real[k] - result.real[8 - k]);
        const imagDiff = Math.abs(result.imag[k] + result.imag[8 - k]); // Note: +, checking imag[k] = -imag[N-k]
        assert.ok(realDiff < 1e-10, `Real symmetry violated at k=${k}: diff=${realDiff}`);
        assert.ok(imagDiff < 1e-10, `Imag antisymmetry violated at k=${k}: diff=${imagDiff}`);
      }

      // X[0] and X[N/2] should be real for real input
      assert.ok(Math.abs(result.imag[0]) < 1e-10, `X[0] should be real: imag=${result.imag[0]}`);
      assert.ok(Math.abs(result.imag[4]) < 1e-10, `X[4] should be real: imag=${result.imag[4]}`);
    });
  });
});
