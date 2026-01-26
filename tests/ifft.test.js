#!/usr/bin/env node
/**
 * IFFT Test Suite
 * Tests inverse FFT functionality across all modules
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const DIST_DIR = path.join(__dirname, "..", "dist");

// Test parameters
const SIZES = [4, 8, 16, 32, 64, 128, 256, 512, 1024];
const TOLERANCE_F32 = 1e-4;
const TOLERANCE_F64 = 1e-10;

async function loadModule(filename) {
  const wasmPath = path.join(DIST_DIR, filename);
  const wasmBuffer = fs.readFileSync(wasmPath);
  const module = await WebAssembly.compile(wasmBuffer);
  const instance = await WebAssembly.instantiate(module);
  return instance.exports;
}

function maxError(actual, expected) {
  let maxErr = 0;
  for (let i = 0; i < actual.length; i++) {
    const err = Math.abs(actual[i] - expected[i]);
    if (err > maxErr) maxErr = err;
  }
  return maxErr;
}

// Test FFT -> IFFT roundtrip for complex data (f64)
async function testComplexF64Roundtrip() {
  console.log("\nTesting f64 complex FFT -> IFFT roundtrip...");
  const fft = await loadModule("fft_combined.wasm");
  let passed = 0,
    failed = 0;

  for (const n of SIZES) {
    // Create test data
    const data = new Float64Array(fft.memory.buffer, 0, n * 2);
    const original = new Float64Array(n * 2);

    // Fill with random data
    for (let i = 0; i < n * 2; i++) {
      original[i] = Math.random() * 2 - 1;
      data[i] = original[i];
    }

    // Precompute twiddles
    fft.precompute_twiddles(n);

    // Forward FFT
    fft.fft(n);

    // Inverse FFT
    fft.ifft(n);

    // Check roundtrip accuracy
    const result = new Float64Array(fft.memory.buffer, 0, n * 2);
    const err = maxError(result, original);

    if (err < TOLERANCE_F64) {
      console.log(`  N=${n.toString().padStart(4)}: max error = ${err.toExponential(2)} \u2713`);
      passed++;
    } else {
      console.log(`  N=${n.toString().padStart(4)}: max error = ${err.toExponential(2)} FAILED`);
      failed++;
    }
  }

  return { passed, failed };
}

// Test FFT -> IFFT roundtrip for complex data (f32)
async function testComplexF32Roundtrip() {
  console.log("\nTesting f32 complex FFT -> IFFT roundtrip...");
  const fft = await loadModule("fft_stockham_f32_dual.wasm");
  let passed = 0,
    failed = 0;

  for (const n of SIZES) {
    // Create test data
    const data = new Float32Array(fft.memory.buffer, 0, n * 2);
    const original = new Float32Array(n * 2);

    // Fill with random data
    for (let i = 0; i < n * 2; i++) {
      original[i] = Math.random() * 2 - 1;
      data[i] = original[i];
    }

    // Precompute twiddles
    fft.precompute_twiddles(n);

    // Forward FFT
    fft.fft(n);

    // Inverse FFT
    fft.ifft(n);

    // Check roundtrip accuracy
    const result = new Float32Array(fft.memory.buffer, 0, n * 2);
    const err = maxError(result, original);

    if (err < TOLERANCE_F32) {
      console.log(`  N=${n.toString().padStart(4)}: max error = ${err.toExponential(2)} \u2713`);
      passed++;
    } else {
      console.log(`  N=${n.toString().padStart(4)}: max error = ${err.toExponential(2)} FAILED`);
      failed++;
    }
  }

  return { passed, failed };
}

// Test RFFT -> IRFFT roundtrip for real data (f32)
async function testRealF32Roundtrip() {
  console.log("\nTesting f32 real RFFT -> IRFFT roundtrip...");
  const fft = await loadModule("fft_real_f32_dual.wasm");
  let passed = 0,
    failed = 0;

  for (const n of SIZES.filter((s) => s >= 8)) {
    // RFFT requires N >= 8
    // Create test data (N real values)
    const data = new Float32Array(fft.memory.buffer, 0, n);
    const original = new Float32Array(n);

    // Fill with random real data
    for (let i = 0; i < n; i++) {
      original[i] = Math.random() * 2 - 1;
      data[i] = original[i];
    }

    // Precompute twiddles
    fft.precompute_rfft_twiddles(n);

    // Forward RFFT
    fft.rfft(n);

    // Inverse RFFT
    fft.irfft(n);

    // Check roundtrip accuracy
    const result = new Float32Array(fft.memory.buffer, 0, n);
    const err = maxError(result, original);

    if (err < TOLERANCE_F32) {
      console.log(`  N=${n.toString().padStart(4)}: max error = ${err.toExponential(2)} \u2713`);
      passed++;
    } else {
      console.log(`  N=${n.toString().padStart(4)}: max error = ${err.toExponential(2)} FAILED`);
      failed++;
    }
  }

  return { passed, failed };
}

// Test IFFT correctness: IFFT(FFT(x)) should equal x
async function testIfftCorrectness() {
  console.log("\nTesting IFFT mathematical correctness...");
  const fft = await loadModule("fft_combined.wasm");

  // Test with known signal: single frequency sine wave
  const n = 64;
  const data = new Float64Array(fft.memory.buffer, 0, n * 2);
  const original = new Float64Array(n * 2);

  // Create a sine wave at bin 5
  const freq = 5;
  for (let i = 0; i < n; i++) {
    original[i * 2] = Math.cos((2 * Math.PI * freq * i) / n);
    original[i * 2 + 1] = 0;
    data[i * 2] = original[i * 2];
    data[i * 2 + 1] = original[i * 2 + 1];
  }

  fft.precompute_twiddles(n);

  // Forward FFT
  fft.fft(n);

  // Check that FFT result has energy at bin 5 and n-5
  const spectrumReal = new Float64Array(fft.memory.buffer, 0, n * 2);
  const mag5 = Math.sqrt(spectrumReal[5 * 2] ** 2 + spectrumReal[5 * 2 + 1] ** 2);
  const mag59 = Math.sqrt(spectrumReal[59 * 2] ** 2 + spectrumReal[59 * 2 + 1] ** 2);

  console.log(
    `  FFT of cos(2*pi*5*t/64): bin 5 magnitude = ${mag5.toFixed(2)}, bin 59 magnitude = ${mag59.toFixed(2)}`,
  );

  // Inverse FFT
  fft.ifft(n);

  // Check roundtrip
  const result = new Float64Array(fft.memory.buffer, 0, n * 2);
  const err = maxError(result, original);

  if (err < TOLERANCE_F64 && mag5 > 30 && mag59 > 30) {
    console.log(`  Roundtrip max error = ${err.toExponential(2)} \u2713`);
    return { passed: 1, failed: 0 };
  } else {
    console.log(`  Roundtrip max error = ${err.toExponential(2)} FAILED`);
    return { passed: 0, failed: 1 };
  }
}

// Main test runner
async function main() {
  console.log("============================================================");
  console.log("IFFT Test Suite");
  console.log("============================================================");

  let totalPassed = 0;
  let totalFailed = 0;

  const tests = [
    testComplexF64Roundtrip,
    testComplexF32Roundtrip,
    testRealF32Roundtrip,
    testIfftCorrectness,
  ];

  for (const test of tests) {
    const { passed, failed } = await test();
    totalPassed += passed;
    totalFailed += failed;
  }

  console.log("\n============================================================");
  console.log(`Results: ${totalPassed}/${totalPassed + totalFailed} passed`);
  console.log("============================================================");

  if (totalFailed > 0) {
    console.log("\nSome tests FAILED!");
    process.exit(1);
  } else {
    console.log("\nAll tests passed!");
    process.exit(0);
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
