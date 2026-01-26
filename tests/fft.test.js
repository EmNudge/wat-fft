/**
 * Comprehensive FFT Test Suite
 *
 * Tests the main complex FFT implementation against a reference DFT with various
 * input sizes and patterns.
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import {
  referenceDFT,
  inputGenerators as sharedInputGenerators,
  compareResults,
} from "./dft-reference.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Load WASM module
async function loadWasm(name) {
  const wasmPath = path.join(__dirname, "..", "dist", `${name}.wasm`);
  if (!fs.existsSync(wasmPath)) {
    return null;
  }
  const wasmBuffer = fs.readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);
  const instance = await WebAssembly.instantiate(wasmModule);
  return instance.exports;
}

// Use shared input generators from dft-reference.js
const inputGenerators = sharedInputGenerators;

// Standard test sizes (powers of 2)
const STANDARD_SIZES = [4, 8, 16, 32, 64, 128, 256, 512, 1024];
// Large sizes supported by modules
const LARGE_SIZES = [2048, 4096];
const ALL_SIZES = [...STANDARD_SIZES, ...LARGE_SIZES];

// Run FFT and extract results
function runFFT(wasm, input, n) {
  const memory = wasm.memory;
  const data = new Float64Array(memory.buffer, 0, n * 2);

  // Copy input to WASM memory
  for (let i = 0; i < n; i++) {
    data[i * 2] = input.real[i];
    data[i * 2 + 1] = input.imag[i];
  }

  // Precompute twiddles if needed
  if (wasm.precompute_twiddles) {
    wasm.precompute_twiddles(n);
  }

  // Run FFT
  wasm.fft(n);

  // Extract results
  const resultData = new Float64Array(memory.buffer, 0, n * 2);
  const real = new Float64Array(n);
  const imag = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    real[i] = resultData[i * 2];
    imag[i] = resultData[i * 2 + 1];
  }

  return { real, imag };
}

// Main test runner
async function runTests() {
  console.log("=".repeat(70));
  console.log("FFT Comprehensive Test Suite");
  console.log("=".repeat(70));
  console.log("");

  let totalTests = 0;
  let passedTests = 0;
  let failedTests = [];

  // Load WASM module
  const wasm = await loadWasm("fft_combined");
  if (!wasm) {
    console.error("Could not load fft_combined.wasm");
    process.exit(1);
  }

  console.log("Testing: fft_combined (Complex FFT f64)");
  console.log("-".repeat(40));

  for (const size of ALL_SIZES) {
    for (const [genName, generator] of Object.entries(inputGenerators)) {
      const input = generator(size);
      const expected = referenceDFT(input.real, input.imag);

      let actual;
      let testError = null;

      try {
        actual = runFFT(wasm, input, size);
      } catch (e) {
        testError = e.message;
      }

      totalTests++;

      // Tolerance derivation for Taylor series trig:
      // - Taylor series sin/cos accuracy: ~1e-10 per operation
      // - Error accumulation: O(log2(N)) butterfly stages
      // - Formula: max(1e-9, N * 5e-11) matches combined.test.js
      const tolerance = Math.max(1e-9, size * 5e-11);

      if (testError) {
        failedTests.push({
          size,
          input: genName,
          error: testError,
        });
        process.stdout.write("E");
      } else {
        const errors = compareResults(actual, expected, tolerance);

        if (errors.length === 0) {
          passedTests++;
          process.stdout.write(".");
        } else {
          failedTests.push({
            size,
            input: genName,
            errors: errors.slice(0, 5), // First 5 errors
          });
          process.stdout.write("F");
        }
      }
    }
  }
  console.log("");
  console.log("");

  // Summary
  console.log("=".repeat(70));
  console.log(`Results: ${passedTests}/${totalTests} passed`);
  console.log("=".repeat(70));

  if (failedTests.length > 0) {
    console.log("");
    console.log("FAILURES:");
    console.log("");

    for (const failure of failedTests) {
      console.log(`N=${failure.size} input=${failure.input}`);

      if (failure.error) {
        console.log(`  Error: ${failure.error}`);
      } else if (failure.errors) {
        for (const err of failure.errors) {
          console.log(
            `  [${err.index}].${err.component}: got ${err.actual.toFixed(10)}, expected ${err.expected.toFixed(10)} (diff: ${err.diff.toExponential(2)})`,
          );
        }
        if (failure.errors.length === 5) {
          console.log("  ... (showing first 5 errors)");
        }
      }
      console.log("");
    }

    process.exit(1);
  } else {
    console.log("");
    console.log("All tests passed!");
    process.exit(0);
  }
}

// Single size test (for debugging)
async function testSingleSize(size, inputType = "random") {
  console.log(`Testing fft_combined with N=${size}, input=${inputType}`);
  console.log("");

  const wasm = await loadWasm("fft_combined");

  if (!wasm) {
    console.error("Could not load fft_combined.wasm");
    process.exit(1);
  }

  const input = inputGenerators[inputType](size);
  const expected = referenceDFT(input.real, input.imag);
  const actual = runFFT(wasm, input, size);

  console.log("Input (first 8):");
  for (let i = 0; i < Math.min(8, size); i++) {
    console.log(`  [${i}] ${input.real[i].toFixed(6)} + ${input.imag[i].toFixed(6)}i`);
  }
  console.log("");

  console.log("Expected vs Actual (first 8):");
  console.log("Index".padEnd(8) + "Expected".padEnd(30) + "Actual".padEnd(30) + "Match");
  console.log("-".repeat(80));

  const tolerance = 1e-10;
  let allMatch = true;

  for (let i = 0; i < Math.min(8, size); i++) {
    const expStr = `${expected.real[i].toFixed(6)} + ${expected.imag[i].toFixed(6)}i`;
    const actStr = `${actual.real[i].toFixed(6)} + ${actual.imag[i].toFixed(6)}i`;
    const realMatch = Math.abs(actual.real[i] - expected.real[i]) < tolerance;
    const imagMatch = Math.abs(actual.imag[i] - expected.imag[i]) < tolerance;
    const match = realMatch && imagMatch;
    if (!match) allMatch = false;
    console.log(`[${i}]`.padEnd(8) + expStr.padEnd(30) + actStr.padEnd(30) + (match ? "+" : "x"));
  }

  console.log("");
  console.log(allMatch ? "All shown values match!" : "Some values do not match.");

  // Full comparison
  const errors = compareResults(actual, expected, tolerance);
  if (errors.length > 0) {
    console.log(`\nTotal errors: ${errors.length}/${size * 2} components`);
  }
}

// CLI handling
const args = process.argv.slice(2);

if (args.length === 0) {
  runTests();
} else if (args[0] === "--size" && args.length >= 2) {
  testSingleSize(parseInt(args[1]), args[2] || "random");
} else if (args[0] === "--help") {
  console.log("FFT Test Suite");
  console.log("");
  console.log("Usage:");
  console.log("  node fft.test.js                    Run all tests");
  console.log("  node fft.test.js --size SIZE [INPUT]");
  console.log("                                      Test single size");
  console.log("");
  console.log("Input types: impulse, constant, singleFreq, random");
  console.log("");
  console.log("Examples:");
  console.log("  node fft.test.js --size 64 random");
  console.log("  node fft.test.js --size 256 impulse");
} else {
  console.error("Unknown arguments. Use --help for usage.");
  process.exit(1);
}
