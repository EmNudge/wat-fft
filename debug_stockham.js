/**
 * Debug script for Stockham FFT
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Reference DFT
function referenceDFT(real, imag) {
  const n = real.length;
  const outReal = new Float64Array(n);
  const outImag = new Float64Array(n);

  for (let k = 0; k < n; k++) {
    let sumReal = 0;
    let sumImag = 0;
    for (let j = 0; j < n; j++) {
      const angle = (-2 * Math.PI * k * j) / n;
      const cos = Math.cos(angle);
      const sin = Math.sin(angle);
      sumReal += real[j] * cos - imag[j] * sin;
      sumImag += real[j] * sin + imag[j] * cos;
    }
    outReal[k] = sumReal;
    outImag[k] = sumImag;
  }

  return { real: outReal, imag: outImag };
}

async function loadStockham() {
  const wasmPath = path.join(__dirname, "dist", "combined_stockham.wasm");
  const wasmBuffer = fs.readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);
  const instance = await WebAssembly.instantiate(wasmModule, {
    math: { sin: Math.sin, cos: Math.cos },
  });
  return instance.exports;
}

async function debug() {
  const wasm = await loadStockham();
  const n = 4;

  console.log(`\n=== Debugging Stockham FFT N=${n} ===\n`);

  // Impulse input [1, 0, 0, 0]
  const real = new Float64Array(n);
  const imag = new Float64Array(n);
  real[0] = 1;

  console.log("Input:");
  for (let i = 0; i < n; i++) {
    console.log(`  [${i}] ${real[i]} + ${imag[i]}i`);
  }

  // Expected output
  const expected = referenceDFT(real, imag);
  console.log("\nExpected (from DFT):");
  for (let i = 0; i < n; i++) {
    console.log(`  [${i}] ${expected.real[i].toFixed(6)} + ${expected.imag[i].toFixed(6)}i`);
  }

  // Copy to WASM memory
  const memory = wasm.memory;
  const data = new Float64Array(memory.buffer, 0, n * 2);
  for (let i = 0; i < n; i++) {
    data[i * 2] = real[i];
    data[i * 2 + 1] = imag[i];
  }

  console.log("\nWASM memory before FFT:");
  for (let i = 0; i < n; i++) {
    console.log(`  [${i}] ${data[i * 2]} + ${data[i * 2 + 1]}i`);
  }

  // Precompute twiddles and check them
  wasm.precompute_twiddles(n);

  // Twiddles are at offset 131072
  const twiddles = new Float64Array(memory.buffer, 131072, n * 2);
  console.log("\nTwiddle factors (W^k for k=0..n-1):");
  for (let k = 0; k < n; k++) {
    const re = twiddles[k * 2];
    const im = twiddles[k * 2 + 1];
    const expectedRe = Math.cos((-2 * Math.PI * k) / n);
    const expectedIm = Math.sin((-2 * Math.PI * k) / n);
    console.log(
      `  W^${k} = ${re.toFixed(6)} + ${im.toFixed(6)}i (expected: ${expectedRe.toFixed(6)} + ${expectedIm.toFixed(6)}i)`,
    );
  }

  // Run FFT
  wasm.fft_stockham(n);

  // Read results
  const result = new Float64Array(memory.buffer, 0, n * 2);
  console.log("\nActual output:");
  for (let i = 0; i < n; i++) {
    console.log(`  [${i}] ${result[i * 2].toFixed(6)} + ${result[i * 2 + 1].toFixed(6)}i`);
  }

  // Check secondary buffer
  const secondary = new Float64Array(memory.buffer, 65536, n * 2);
  console.log("\nSecondary buffer after FFT:");
  for (let i = 0; i < n; i++) {
    console.log(`  [${i}] ${secondary[i * 2].toFixed(6)} + ${secondary[i * 2 + 1].toFixed(6)}i`);
  }

  // Now test N=32 (2 radix-4 stages + 1 radix-2)
  console.log("\n\n=== Debugging Stockham FFT N=32 ===\n");

  const n32 = 32;
  const real32 = new Float64Array(n32);
  const imag32 = new Float64Array(n32);
  real32[0] = 1; // Impulse

  console.log("Input: impulse [1, 0, 0, ...]");
  console.log(`log2(${n32}) = 5, stages = 2 radix-4 + 1 radix-2`);

  const expected32 = referenceDFT(real32, imag32);
  console.log("\nExpected (all 1s for impulse):");
  for (let i = 0; i < Math.min(8, n32); i++) {
    console.log(`  [${i}] ${expected32.real[i].toFixed(6)} + ${expected32.imag[i].toFixed(6)}i`);
  }
  console.log("  ...");

  const data32 = new Float64Array(memory.buffer, 0, n32 * 2);
  for (let i = 0; i < n32; i++) {
    data32[i * 2] = real32[i];
    data32[i * 2 + 1] = imag32[i];
  }

  wasm.precompute_twiddles(n32);
  wasm.fft_stockham(n32);

  const result32 = new Float64Array(memory.buffer, 0, n32 * 2);
  console.log("\nActual output (first 16):");
  for (let i = 0; i < 16; i++) {
    const expected_r = expected32.real[i];
    const expected_i = expected32.imag[i];
    const actual_r = result32[i * 2];
    const actual_i = result32[i * 2 + 1];
    const match =
      Math.abs(actual_r - expected_r) < 1e-10 && Math.abs(actual_i - expected_i) < 1e-10;
    console.log(`  [${i}] ${actual_r.toFixed(6)} + ${actual_i.toFixed(6)}i ${match ? "✓" : "✗"}`);
  }

  // Count errors
  let errors = 0;
  for (let i = 0; i < n32; i++) {
    if (
      Math.abs(result32[i * 2] - expected32.real[i]) > 1e-10 ||
      Math.abs(result32[i * 2 + 1] - expected32.imag[i]) > 1e-10
    ) {
      errors++;
    }
  }
  console.log(`\nTotal errors: ${errors}/${n32}`);
}

debug().catch(console.error);
