/**
 * Tests for Depth-First Recursive FFT
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import FFT from "fft.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Load the recursive FFT WASM module
async function loadRecursiveWasm() {
  const wasmPath = path.join(__dirname, "..", "dist", "fft_recursive.wasm");
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
  const input = new Float64Array(n * 2);
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

// Test sizes
const SIZES = [2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096];

async function runTests() {
  console.log("Loading WASM modules...");
  const recursive = await loadRecursiveWasm();

  console.log("\nTesting Depth-First Recursive FFT against fft.js reference");
  console.log("=".repeat(60));

  let allPassed = true;

  for (const n of SIZES) {
    // Generate input
    const input = generateInput(n);

    // Copy to recursive module memory
    const recMem = new Float64Array(recursive.memory.buffer, 0, n * 2);
    recMem.set(input);
    recursive.precompute_twiddles(n);

    // Run recursive FFT
    recursive.fft(n);

    // Get reference output from fft.js
    const refOutput = referenceFFT(Array.from(input), n);

    // Read recursive output
    const recOutput = new Float64Array(recursive.memory.buffer, 0, n * 2);

    // Compare (use 1e-8 threshold due to Taylor series sin/cos approximations)
    const err = maxError(recOutput, refOutput);
    const passed = err < 1e-8;

    const status = passed ? "PASS" : "FAIL";
    console.log(`N=${n.toString().padStart(4)}: ${status} (max error: ${err.toExponential(2)})`);

    if (!passed) {
      allPassed = false;
      // Print first few values for debugging
      console.log(
        "  First 4 recursive:",
        Array.from(recOutput.slice(0, 8)).map((x) => x.toFixed(6)),
      );
      console.log(
        "  First 4 reference:",
        Array.from(refOutput.slice(0, 8)).map((x) => x.toFixed(6)),
      );
    }
  }

  console.log("\n" + "=".repeat(60));
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
