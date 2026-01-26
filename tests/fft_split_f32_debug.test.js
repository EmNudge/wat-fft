/**
 * Debug test for split-format FFT
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { describe, it, expect, beforeAll } from "vitest";
import FFT from "fft.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

async function loadWasm(name) {
  const wasmPath = path.join(__dirname, "..", "dist", `${name}.wasm`);
  const wasmBuffer = fs.readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);
  const instance = await WebAssembly.instantiate(wasmModule, {
    env: {
      sin: Math.sin,
      cos: Math.cos,
    },
  });
  return instance.exports;
}

describe("Split Format FFT Debug", () => {
  let wasm;

  beforeAll(async () => {
    wasm = await loadWasm("fft_split_f32");
  });

  // Test a simple case where we know the answer
  it("should compute FFT of [1, 0, 0, 0] correctly (impulse)", () => {
    const n = 4;
    const memory = wasm.memory;
    const data = new Float32Array(memory.buffer, 0, n * 2);

    // Impulse: [1+0i, 0+0i, 0+0i, 0+0i]
    data.fill(0);
    data[0] = 1; // re[0]
    data[1] = 0; // im[0]

    console.log("Input (interleaved):", Array.from(data));

    wasm.precompute_twiddles(n);
    wasm.fft(n);

    console.log("Output (interleaved):", Array.from(data));

    // FFT of impulse should be all 1s (DC component everywhere)
    // Expected: [1+0i, 1+0i, 1+0i, 1+0i]
    for (let i = 0; i < n; i++) {
      const re = data[i * 2];
      const im = data[i * 2 + 1];
      console.log(`X[${i}] = ${re.toFixed(6)} + ${im.toFixed(6)}i (expected: 1 + 0i)`);
      expect(Math.abs(re - 1)).toBeLessThan(1e-4);
      expect(Math.abs(im)).toBeLessThan(1e-4);
    }
  });

  it("should compute FFT of DC signal correctly", () => {
    const n = 4;
    const memory = wasm.memory;
    const data = new Float32Array(memory.buffer, 0, n * 2);

    // DC: [1+0i, 1+0i, 1+0i, 1+0i]
    for (let i = 0; i < n; i++) {
      data[i * 2] = 1;
      data[i * 2 + 1] = 0;
    }

    console.log("Input (DC):", Array.from(data));

    wasm.precompute_twiddles(n);
    wasm.fft(n);

    console.log("Output (DC):", Array.from(data));

    // FFT of DC should be: [4+0i, 0+0i, 0+0i, 0+0i]
    console.log(`X[0] = ${data[0].toFixed(6)} + ${data[1].toFixed(6)}i (expected: 4 + 0i)`);
    expect(Math.abs(data[0] - n)).toBeLessThan(1e-4);
    expect(Math.abs(data[1])).toBeLessThan(1e-4);

    for (let i = 1; i < n; i++) {
      const re = data[i * 2];
      const im = data[i * 2 + 1];
      console.log(`X[${i}] = ${re.toFixed(6)} + ${im.toFixed(6)}i (expected: 0 + 0i)`);
      expect(Math.abs(re)).toBeLessThan(1e-4);
      expect(Math.abs(im)).toBeLessThan(1e-4);
    }
  });

  it("should match fft.js for N=4", () => {
    const n = 4;
    const memory = wasm.memory;
    const data = new Float32Array(memory.buffer, 0, n * 2);

    // Random-ish input
    const input = [1, 2, 3, 4, 5, 6, 7, 8]; // re0, im0, re1, im1, ...
    for (let i = 0; i < n * 2; i++) {
      data[i] = input[i];
    }

    console.log("\n=== N=4 comparison ===");
    console.log("Input:", input);

    // Reference FFT
    const fftJs = new FFT(n);
    const jsInput = input.slice();
    const jsOutput = fftJs.createComplexArray();
    fftJs.transform(jsOutput, jsInput);
    console.log("fft.js output:", jsOutput);

    // Our FFT
    wasm.precompute_twiddles(n);
    wasm.fft(n);
    console.log("our output:", Array.from(data));

    for (let i = 0; i < n; i++) {
      const ourRe = data[i * 2];
      const ourIm = data[i * 2 + 1];
      const jsRe = jsOutput[i * 2];
      const jsIm = jsOutput[i * 2 + 1];
      const errRe = Math.abs(ourRe - jsRe);
      const errIm = Math.abs(ourIm - jsIm);
      console.log(
        `X[${i}] ours: ${ourRe.toFixed(4)}+${ourIm.toFixed(4)}i, js: ${jsRe.toFixed(4)}+${jsIm.toFixed(4)}i, err: ${errRe.toFixed(6)}, ${errIm.toFixed(6)}`,
      );
    }
  });

  it("should match fft.js for N=8", () => {
    const n = 8;
    const memory = wasm.memory;
    const data = new Float32Array(memory.buffer, 0, n * 2);

    // Random-ish input
    const input = [];
    for (let i = 0; i < n * 2; i++) {
      input.push(i + 1);
    }
    for (let i = 0; i < n * 2; i++) {
      data[i] = input[i];
    }

    console.log("\n=== N=8 comparison ===");
    console.log("Input:", input);

    // Reference FFT
    const fftJs = new FFT(n);
    const jsInput = input.slice();
    const jsOutput = fftJs.createComplexArray();
    fftJs.transform(jsOutput, jsInput);
    console.log("fft.js output:", jsOutput);

    // Our FFT
    wasm.precompute_twiddles(n);
    wasm.fft(n);
    console.log("our output:", Array.from(data));

    let maxErr = 0;
    for (let i = 0; i < n; i++) {
      const ourRe = data[i * 2];
      const ourIm = data[i * 2 + 1];
      const jsRe = jsOutput[i * 2];
      const jsIm = jsOutput[i * 2 + 1];
      const errRe = Math.abs(ourRe - jsRe);
      const errIm = Math.abs(ourIm - jsIm);
      maxErr = Math.max(maxErr, errRe, errIm);
      console.log(
        `X[${i}] ours: ${ourRe.toFixed(4)}+${ourIm.toFixed(4)}i, js: ${jsRe.toFixed(4)}+${jsIm.toFixed(4)}i, err: ${errRe.toFixed(6)}, ${errIm.toFixed(6)}`,
      );
    }
    console.log(`Max error: ${maxErr}`);
  });

  it.each([16, 32, 64, 128, 256, 512, 1024, 2048, 4096])("should match fft.js for N=%i", (n) => {
    const memory = wasm.memory;
    const data = new Float32Array(memory.buffer, 0, n * 2);

    // Random input
    const input = [];
    for (let i = 0; i < n * 2; i++) {
      input.push(Math.random() * 2 - 1);
    }
    for (let i = 0; i < n * 2; i++) {
      data[i] = input[i];
    }

    // Reference FFT
    const fftJs = new FFT(n);
    const jsInput = input.slice();
    const jsOutput = fftJs.createComplexArray();
    fftJs.transform(jsOutput, jsInput);

    // Our FFT
    wasm.precompute_twiddles(n);
    wasm.fft(n);

    let maxErr = 0;
    for (let i = 0; i < n; i++) {
      const ourRe = data[i * 2];
      const ourIm = data[i * 2 + 1];
      const jsRe = jsOutput[i * 2];
      const jsIm = jsOutput[i * 2 + 1];
      const errRe = Math.abs(ourRe - jsRe);
      const errIm = Math.abs(ourIm - jsIm);
      maxErr = Math.max(maxErr, errRe, errIm);
    }
    console.log(`N=${n} max error: ${maxErr.toExponential(2)}`);
    expect(maxErr).toBeLessThan(1e-4);
  });
});
