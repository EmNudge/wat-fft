/**
 * Tests for f32 Dual-Complex FFT
 *
 * Verifies that the dual-complex implementation produces the same
 * results as the reference fft.js library.
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import FFT from "fft.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Load WASM modules
async function loadWasm(name) {
  const wasmPath = path.join(__dirname, "..", "dist", `${name}.wasm`);
  const wasmBuffer = fs.readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);
  const instance = await WebAssembly.instantiate(wasmModule, {});
  return instance.exports;
}

// Reference FFT using fft.js library
function referenceFFT(input, n) {
  const fft = new FFT(n);
  const out = fft.createComplexArray();
  fft.transform(out, input);
  return out;
}

// Generate random complex input
function generateInput(n) {
  const input = new Float32Array(n * 2);
  for (let i = 0; i < n * 2; i++) {
    input[i] = Math.random() * 2 - 1;
  }
  return input;
}

// Compute max absolute error between two arrays
function maxError(a, b) {
  let maxErr = 0;
  for (let i = 0; i < a.length; i++) {
    maxErr = Math.max(maxErr, Math.abs(a[i] - b[i]));
  }
  return maxErr;
}

// Test sizes (must be powers of 2, >= 4)
const SIZES = [4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192];

async function runTests() {
  console.log("Loading WASM module...");
  const wasm = await loadWasm("fft_stockham_f32_dual");

  console.log("\nTesting f32 Dual-Complex FFT against fft.js reference");
  console.log("=".repeat(70));

  let allPassed = true;

  for (const n of SIZES) {
    // Generate input (f32)
    const input = generateInput(n);

    // Copy to module memory
    const mem = new Float32Array(wasm.memory.buffer, 0, n * 2);
    mem.set(input);
    wasm.precompute_twiddles(n);
    wasm.fft(n);

    // Get reference output from fft.js (using f64 internally)
    const inputF64 = Array.from(input);
    const refOutput = referenceFFT(inputF64, n);

    // Read output
    const output = new Float32Array(wasm.memory.buffer, 0, n * 2);

    // Compare vs reference (f32 has ~1e-5 precision)
    const err = maxError(output, refOutput);

    // f32 error grows with N due to accumulated rounding
    // Use size-dependent threshold: base 1e-4 scaled by sqrt(N/1024)
    const threshold = 1e-4 * Math.sqrt(n / 1024);
    const passed = err < threshold;

    const status = passed ? "PASS" : "FAIL";
    console.log(`N=${n.toString().padStart(4)}: ${status} (error: ${err.toExponential(2)})`);

    if (!passed) {
      allPassed = false;
      console.log(
        "  First 4 output:   ",
        Array.from(output.slice(0, 8)).map((x) => x.toFixed(6)),
      );
      console.log(
        "  First 4 reference:",
        Array.from(refOutput.slice(0, 8)).map((x) => x.toFixed(6)),
      );
    }
  }

  console.log("\n" + "=".repeat(70));
  if (allPassed) {
    console.log("All tests PASSED!");
    process.exit(0);
  } else {
    console.log("Some tests FAILED!");
    process.exit(1);
  }
}

runTests().catch((err) => {
  console.error(err);
  process.exit(1);
});
