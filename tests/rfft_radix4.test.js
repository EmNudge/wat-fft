/**
 * Real FFT Radix-4 Tests
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

async function loadRfftRadix4() {
  const wasmPath = path.join(__dirname, "..", "dist", "fft_real_radix4.wasm");
  const wasmBuffer = fs.readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);
  const instance = await WebAssembly.instantiate(wasmModule);
  return instance.exports;
}

async function loadStockhamRfft() {
  const wasmPath = path.join(__dirname, "..", "dist", "combined_real.wasm");
  const wasmBuffer = fs.readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);
  const instance = await WebAssembly.instantiate(wasmModule, {
    math: { sin: Math.sin, cos: Math.cos },
  });
  return instance.exports;
}

async function runTests() {
  console.log("Real FFT Radix-4 Tests\n");

  const radix4 = await loadRfftRadix4();
  const stockham = await loadStockhamRfft();

  // Test power-of-4 sizes where N/2 is power of 4: N=8 (N/2=4), N=32, N=128, N=512, N=2048
  const sizes = [8, 32, 128, 512, 2048];
  let allPassed = true;

  for (const n of sizes) {
    console.log("Testing N=" + n + ":");

    // Generate random real input
    const input = new Float64Array(n);
    for (let i = 0; i < n; i++) {
      input[i] = Math.random() * 2 - 1;
    }

    // Run radix-4 rfft
    const r4Memory = radix4.memory;
    const r4Data = new Float64Array(r4Memory.buffer, 0, n + 2);
    for (let i = 0; i < n; i++) {
      r4Data[i] = input[i];
    }
    radix4.precompute_rfft_twiddles(n);
    radix4.rfft(n);
    const r4Result = new Float64Array(r4Data.slice(0, n + 2));

    // Run stockham rfft
    const stMemory = stockham.memory;
    const stData = new Float64Array(stMemory.buffer, 0, n + 2);
    for (let i = 0; i < n; i++) {
      stData[i] = input[i];
    }
    stockham.precompute_rfft_twiddles(n);
    stockham.rfft(n);
    const stResult = new Float64Array(stData.slice(0, n + 2));

    // Compare
    let maxDiff = 0;
    const n2 = n / 2;
    for (let i = 0; i <= n2; i++) {
      const diffRe = Math.abs(r4Result[i * 2] - stResult[i * 2]);
      const diffIm = Math.abs(r4Result[i * 2 + 1] - stResult[i * 2 + 1]);
      maxDiff = Math.max(maxDiff, diffRe, diffIm);
    }

    const passed = maxDiff < 1e-8;
    const status = passed ? "✓" : "✗";
    console.log("  " + status + " vs Stockham - max diff: " + maxDiff.toExponential(2));
    allPassed = allPassed && passed;
  }

  console.log("\n" + (allPassed ? "All tests passed!" : "Some tests failed!"));
  process.exit(allPassed ? 0 : 1);
}

runTests().catch(console.error);
