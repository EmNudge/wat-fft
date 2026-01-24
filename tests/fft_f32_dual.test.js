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
const SIZES = [4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096];

async function runTests() {
  console.log("Loading WASM modules...");
  const dual = await loadWasm("fft_stockham_f32_dual");

  // Also load original f32 for comparison
  const original = await loadWasm("combined_stockham_f32");

  console.log("\nTesting f32 Dual-Complex FFT against fft.js reference");
  console.log("=".repeat(70));

  let allPassed = true;

  for (const n of SIZES) {
    // Generate input (f32)
    const input = generateInput(n);

    // Copy to dual module memory
    const dualMem = new Float32Array(dual.memory.buffer, 0, n * 2);
    dualMem.set(input);
    dual.precompute_twiddles(n);
    dual.fft(n);

    // Copy to original f32 module memory for comparison
    const origMem = new Float32Array(original.memory.buffer, 0, n * 2);
    origMem.set(input);
    original.precompute_twiddles(n);
    original.fft_stockham(n);

    // Get reference output from fft.js (using f64 internally)
    const inputF64 = Array.from(input);
    const refOutput = referenceFFT(inputF64, n);

    // Read dual output
    const dualOutput = new Float32Array(dual.memory.buffer, 0, n * 2);

    // Read original output
    const origOutput = new Float32Array(original.memory.buffer, 0, n * 2);

    // Compare dual vs reference (f32 has ~1e-5 precision)
    const dualErr = maxError(dualOutput, refOutput);
    const origErr = maxError(origOutput, refOutput);
    const dualVsOrig = maxError(dualOutput, origOutput);

    // f32 should be within 1e-4 of reference
    const threshold = 1e-4;
    const dualPassed = dualErr < threshold;
    const origPassed = origErr < threshold;

    const status = dualPassed ? "PASS" : "FAIL";
    console.log(
      `N=${n.toString().padStart(4)}: ${status} (dual err: ${dualErr.toExponential(2)}, orig err: ${origErr.toExponential(2)}, dual vs orig: ${dualVsOrig.toExponential(2)})`,
    );

    if (!dualPassed) {
      allPassed = false;
      console.log(
        "  First 4 dual:    ",
        Array.from(dualOutput.slice(0, 8)).map((x) => x.toFixed(6)),
      );
      console.log(
        "  First 4 original:",
        Array.from(origOutput.slice(0, 8)).map((x) => x.toFixed(6)),
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
