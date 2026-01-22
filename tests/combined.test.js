/**
 * Tests for combined FFT modules (radix-2 + radix-4 with auto-dispatch)
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const distDir = path.join(__dirname, "..", "dist");

// Reference DFT for verification
function dft(input) {
  const N = input.length / 2;
  const output = new Float64Array(N * 2);

  for (let k = 0; k < N; k++) {
    let sumRe = 0,
      sumIm = 0;
    for (let n = 0; n < N; n++) {
      const angle = (-2 * Math.PI * k * n) / N;
      const cos = Math.cos(angle);
      const sin = Math.sin(angle);
      const re = input[n * 2];
      const im = input[n * 2 + 1];
      sumRe += re * cos - im * sin;
      sumIm += re * sin + im * cos;
    }
    output[k * 2] = sumRe;
    output[k * 2 + 1] = sumIm;
  }
  return output;
}

// Reference real DFT
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

function maxError(a, b) {
  let max = 0;
  for (let i = 0; i < Math.min(a.length, b.length); i++) {
    const err = Math.abs(a[i] - b[i]);
    if (err > max) max = err;
  }
  return max;
}

async function loadModule(wasmFile) {
  const wasmPath = path.join(distDir, wasmFile);
  const wasmBuffer = fs.readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);
  return WebAssembly.instantiate(wasmModule);
}

async function testComplexFFT() {
  console.log("Testing combined complex FFT (fft_combined.wasm)...\n");

  const instance = await loadModule("fft_combined.wasm");
  const { fft, precompute_twiddles, memory } = instance.exports;

  // Test sizes: mix of power-of-4 (radix-4) and non-power-of-4 (radix-2)
  const sizes = [4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096];
  // Tolerance: Taylor series errors accumulate roughly with size
  // Using 5e-11 * N gives headroom matching other test files
  const baseTolerance = 1e-9;

  for (const N of sizes) {
    const isPow4 = (N & (N - 1)) === 0 && (N & 0xaaaaaaaa) === 0;
    const algo = isPow4 ? "radix-4" : "radix-2";

    // Generate test input
    const input = new Float64Array(N * 2);
    for (let i = 0; i < N; i++) {
      input[i * 2] = Math.sin((2 * Math.PI * i) / N);
      input[i * 2 + 1] = Math.cos((3 * Math.PI * i) / N);
    }

    // Reference DFT
    const expected = dft(input);

    // WASM FFT
    const data = new Float64Array(memory.buffer, 0, N * 2);
    data.set(input);
    precompute_twiddles(N);
    fft(N);

    const err = maxError(data, expected);
    // Size-dependent tolerance: max(1e-9, N * 5e-11)
    const tolerance = Math.max(baseTolerance, N * 5e-11);
    const status = err < tolerance ? "✓" : "✗";
    console.log(
      `  N=${N.toString().padStart(4)} (${algo.padEnd(7)}): max error = ${err.toExponential(2)} ${status}`,
    );

    if (err >= tolerance) {
      console.log(`    FAILED: expected error < ${tolerance.toExponential(2)}`);
      process.exitCode = 1;
    }
  }
}

async function testRealFFT() {
  console.log("\nTesting combined real FFT (fft_real_combined.wasm)...\n");

  const instance = await loadModule("fft_real_combined.wasm");
  const { rfft, precompute_rfft_twiddles, memory } = instance.exports;

  // Test sizes: N where N/2 is power-of-4 uses radix-4, otherwise radix-2
  // N/2 power-of-4: N=8,32,128,512,2048 (N/2=4,16,64,256,1024)
  // N/2 NOT power-of-4: N=16,64,256,1024,4096 (N/2=8,32,128,512,2048)
  const sizes = [8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096];
  // Tolerance: Taylor series errors accumulate as ~N * 2e-11 (per README)
  const baseTolerance = 1e-9;

  for (const N of sizes) {
    const n2 = N / 2;
    const isPow4 = (n2 & (n2 - 1)) === 0 && (n2 & 0xaaaaaaaa) === 0;
    const algo = isPow4 ? "radix-4" : "radix-2";

    // Generate test input
    const input = new Float64Array(N);
    for (let i = 0; i < N; i++) {
      input[i] = Math.sin((2 * Math.PI * i) / N) + 0.5 * Math.cos((4 * Math.PI * i) / N);
    }

    // Reference DFT
    const expected = realDft(input);

    // WASM RFFT
    const data = new Float64Array(memory.buffer, 0, N);
    data.set(input);
    precompute_rfft_twiddles(N);
    rfft(N);

    // Output is N/2+1 complex values
    const output = new Float64Array(memory.buffer, 0, (N / 2 + 1) * 2);
    const err = maxError(output, expected);
    // Size-dependent tolerance: max(1e-9, N * 2e-11)
    const tolerance = Math.max(baseTolerance, N * 2e-11);
    const status = err < tolerance ? "✓" : "✗";
    console.log(
      `  N=${N.toString().padStart(4)} (N/2=${n2.toString().padStart(4)}, ${algo.padEnd(7)}): max error = ${err.toExponential(2)} ${status}`,
    );

    if (err >= tolerance) {
      console.log(`    FAILED: expected error < ${tolerance.toExponential(2)}`);
      process.exitCode = 1;
    }
  }
}

async function main() {
  console.log("=".repeat(60));
  console.log("Combined FFT Module Tests (radix-2 + radix-4 auto-dispatch)");
  console.log("=".repeat(60));
  console.log();

  await testComplexFFT();
  await testRealFFT();

  console.log("\n" + "=".repeat(60));
  if (process.exitCode === 1) {
    console.log("SOME TESTS FAILED");
  } else {
    console.log("ALL TESTS PASSED");
  }
  console.log("=".repeat(60));
}

main().catch(console.error);
