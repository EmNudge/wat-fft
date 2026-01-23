/**
 * Quick test for Radix-4 FFT implementation
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

async function loadRadix4FFT() {
  const wasmPath = path.join(__dirname, "..", "dist", "fft_radix4.wasm");
  const wasmBuffer = fs.readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);
  const instance = await WebAssembly.instantiate(wasmModule);
  return instance.exports;
}

async function loadStockhamFFT() {
  const wasmPath = path.join(__dirname, "..", "dist", "combined_stockham.wasm");
  const wasmBuffer = fs.readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);
  const instance = await WebAssembly.instantiate(wasmModule);
  return instance.exports;
}

function compareResults(name, result1, result2, tolerance = 1e-9) {
  const n = result1.length / 2;
  let maxDiff = 0;
  let errors = [];

  for (let i = 0; i < n; i++) {
    const re1 = result1[i * 2];
    const im1 = result1[i * 2 + 1];
    const re2 = result2[i * 2];
    const im2 = result2[i * 2 + 1];

    const diffRe = Math.abs(re1 - re2);
    const diffIm = Math.abs(im1 - im2);
    const diff = Math.max(diffRe, diffIm);
    maxDiff = Math.max(maxDiff, diff);

    if (diff > tolerance) {
      errors.push(
        `[${i}]: (${re1.toFixed(6)}, ${im1.toFixed(6)}) vs (${re2.toFixed(6)}, ${im2.toFixed(6)}) diff=${diff.toExponential(2)}`,
      );
    }
  }

  if (errors.length > 0) {
    console.log(`✗ ${name} - max diff: ${maxDiff.toExponential(2)}`);
    errors.slice(0, 5).forEach((e) => console.log(`  ${e}`));
    if (errors.length > 5) console.log(`  ... and ${errors.length - 5} more errors`);
    return false;
  }

  console.log(`✓ ${name} - max diff: ${maxDiff.toExponential(2)}`);
  return true;
}

async function runTests() {
  console.log("Radix-4 FFT Tests\n");

  const radix4 = await loadRadix4FFT();
  const stockham = await loadStockhamFFT();

  const sizes = [4, 16, 64, 256, 1024];
  let allPassed = true;

  for (const n of sizes) {
    console.log(`\nTesting N=${n}:`);

    // Test 1: Impulse response
    {
      const memory = radix4.memory;
      const data = new Float64Array(memory.buffer, 0, n * 2);
      data.fill(0);
      data[0] = 1; // impulse at t=0

      radix4.precompute_twiddles(n);
      radix4.fft_radix4(n);

      // Expected: flat spectrum (all 1s)
      let passed = true;
      for (let i = 0; i < n; i++) {
        const re = data[i * 2];
        const im = data[i * 2 + 1];
        if (Math.abs(re - 1) > 1e-9 || Math.abs(im) > 1e-9) {
          passed = false;
          break;
        }
      }
      console.log(passed ? "  ✓ Impulse response" : "  ✗ Impulse response");
      allPassed = allPassed && passed;
    }

    // Test 2: Compare with Stockham FFT
    {
      const r4Memory = radix4.memory;
      const r4Data = new Float64Array(r4Memory.buffer, 0, n * 2);

      const stMemory = stockham.memory;
      const stData = new Float64Array(stMemory.buffer, 0, n * 2);

      // Random input
      const input = new Float64Array(n * 2);
      for (let i = 0; i < n * 2; i++) {
        input[i] = Math.random() * 2 - 1;
      }

      r4Data.set(input);
      stData.set(input);

      radix4.precompute_twiddles(n);
      stockham.precompute_twiddles(n);

      radix4.fft_radix4(n);
      stockham.fft_stockham(n);

      const r4Result = new Float64Array(r4Data);
      const stResult = new Float64Array(stData);

      const passed = compareResults("  vs Stockham", r4Result, stResult, 1e-8);
      allPassed = allPassed && passed;
    }
  }

  console.log("\n" + (allPassed ? "All tests passed!" : "Some tests failed!"));
  process.exit(allPassed ? 0 : 1);
}

runTests().catch(console.error);
