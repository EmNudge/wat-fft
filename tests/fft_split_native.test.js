/**
 * Tests for native split-format FFT
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import FFT from "fft.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

async function loadWasm() {
  const wasmPath = path.join(__dirname, "..", "dist", "fft_split_native_f32.wasm");
  const wasmBuffer = fs.readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);
  const instance = await WebAssembly.instantiate(wasmModule, {});
  return instance.exports;
}

// Generate random test data
function generateTestData(n) {
  const real = new Float32Array(n);
  const imag = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    real[i] = Math.random() * 2 - 1;
    imag[i] = Math.random() * 2 - 1;
  }
  return { real, imag };
}

// Reference FFT using fft.js
function referenceFFT(real, imag) {
  const n = real.length;
  const fft = new FFT(n);

  // fft.js uses interleaved format
  const input = fft.createComplexArray();
  for (let i = 0; i < n; i++) {
    input[i * 2] = real[i];
    input[i * 2 + 1] = imag[i];
  }

  const output = fft.createComplexArray();
  fft.transform(output, input);

  // Extract back to split format
  const outReal = new Float64Array(n);
  const outImag = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    outReal[i] = output[i * 2];
    outImag[i] = output[i * 2 + 1];
  }

  return { real: outReal, imag: outImag };
}

// Compare arrays with tolerance
function compareArrays(a, b, tolerance = 1e-4) {
  if (a.length !== b.length) return { match: false, maxError: Infinity };

  let maxError = 0;
  for (let i = 0; i < a.length; i++) {
    const error = Math.abs(a[i] - b[i]);
    maxError = Math.max(maxError, error);
  }

  return { match: maxError < tolerance, maxError };
}

async function runTests() {
  console.log("Testing native split-format FFT...\n");

  const wasm = await loadWasm();
  const REAL_OFFSET = wasm.REAL_OFFSET;
  const IMAG_OFFSET = wasm.IMAG_OFFSET;

  const sizes = [4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096];
  let passed = 0;
  let failed = 0;

  console.log("Forward FFT tests:");
  for (const n of sizes) {
    const input = generateTestData(n);
    const expected = referenceFFT(input.real, input.imag);

    // Load input into WASM memory (split format)
    const realView = new Float32Array(wasm.memory.buffer, REAL_OFFSET, n);
    const imagView = new Float32Array(wasm.memory.buffer, IMAG_OFFSET, n);
    realView.set(input.real);
    imagView.set(input.imag);

    // Precompute twiddles and run FFT
    wasm.precompute_twiddles_split(n);
    wasm.fft_split(n);

    // Read output
    const outputReal = new Float32Array(wasm.memory.buffer, REAL_OFFSET, n);
    const outputImag = new Float32Array(wasm.memory.buffer, IMAG_OFFSET, n);

    // Compare with reference
    // Use tolerance of 5e-3 since we compare f32 Taylor series against f64 native trig
    const realResult = compareArrays(outputReal, expected.real, 5e-3);
    const imagResult = compareArrays(outputImag, expected.imag, 5e-3);
    const maxError = Math.max(realResult.maxError, imagResult.maxError);

    if (realResult.match && imagResult.match) {
      console.log(`  N=${n.toString().padStart(4)}: max error = ${maxError.toExponential(2)} ✓`);
      passed++;
    } else {
      console.log(`  N=${n.toString().padStart(4)}: max error = ${maxError.toExponential(2)} ✗`);
      failed++;
    }
  }

  console.log("\nRoundtrip FFT->IFFT tests:");
  for (const n of sizes) {
    const input = generateTestData(n);

    // Load input into WASM memory
    const realView = new Float32Array(wasm.memory.buffer, REAL_OFFSET, n);
    const imagView = new Float32Array(wasm.memory.buffer, IMAG_OFFSET, n);
    realView.set(input.real);
    imagView.set(input.imag);

    // Save original input
    const origReal = new Float32Array(input.real);
    const origImag = new Float32Array(input.imag);

    // Precompute twiddles and run FFT then IFFT
    wasm.precompute_twiddles_split(n);
    wasm.fft_split(n);
    wasm.ifft_split(n);

    // Read output
    const outputReal = new Float32Array(wasm.memory.buffer, REAL_OFFSET, n);
    const outputImag = new Float32Array(wasm.memory.buffer, IMAG_OFFSET, n);

    // Compare with original input (looser tolerance for f32 Taylor series)
    const realResult = compareArrays(outputReal, origReal, 1e-2);
    const imagResult = compareArrays(outputImag, origImag, 1e-2);
    const maxError = Math.max(realResult.maxError, imagResult.maxError);

    if (realResult.match && imagResult.match) {
      console.log(`  N=${n.toString().padStart(4)}: max error = ${maxError.toExponential(2)} ✓`);
      passed++;
    } else {
      console.log(`  N=${n.toString().padStart(4)}: max error = ${maxError.toExponential(2)} ✗`);
      failed++;
    }
  }

  console.log("\n" + "=".repeat(60));
  console.log(`Results: ${passed}/${passed + failed} passed`);
  console.log("=".repeat(60));

  if (failed > 0) {
    process.exit(1);
  }
}

runTests().catch(console.error);
