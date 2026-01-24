/**
 * Benchmark: f32 Dual-Complex FFT vs original f32 and fftw-js
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

// Benchmark configuration
const WARMUP_ITERATIONS = 100;
const BENCHMARK_DURATION_MS = 2000;
const SIZES = [64, 256, 1024, 2048, 4096];

// Generate random f32 complex input
function generateInputF32(n) {
  const input = new Float32Array(n * 2);
  for (let i = 0; i < n * 2; i++) {
    input[i] = Math.random() * 2 - 1;
  }
  return input;
}

function formatNumber(num) {
  if (num >= 1e6) return (num / 1e6).toFixed(2) + "M";
  if (num >= 1e3) return (num / 1e3).toFixed(1) + "K";
  return num.toFixed(0);
}

// Benchmark runner
function runBenchmark(name, setupFn, benchFn) {
  const ctx = setupFn();
  for (let i = 0; i < WARMUP_ITERATIONS; i++) {
    benchFn(ctx);
  }

  const startTime = performance.now();
  let iterations = 0;

  while (performance.now() - startTime < BENCHMARK_DURATION_MS) {
    benchFn(ctx);
    iterations++;
  }

  const elapsed = performance.now() - startTime;
  const opsPerSec = (iterations / elapsed) * 1000;

  return { name, iterations, elapsed, opsPerSec };
}

async function runBenchmarks() {
  console.log("=".repeat(80));
  console.log("f32 Dual-Complex FFT Benchmark");
  console.log("=".repeat(80));
  console.log(`Duration: ${BENCHMARK_DURATION_MS}ms per test`);
  console.log(`Warmup: ${WARMUP_ITERATIONS} iterations`);
  console.log("");

  const dual = await loadWasm("fft_stockham_f32_dual");
  const original = await loadWasm("combined_stockham_f32");

  for (const n of SIZES) {
    console.log("-".repeat(80));
    console.log(`FFT Size: N=${n}`);
    console.log("-".repeat(80));

    const inputF32 = generateInputF32(n);
    const results = [];

    // 1. Dual-complex f32 FFT
    const dualResult = runBenchmark(
      "f32 Dual-Complex",
      () => {
        const memory = dual.memory;
        const data = new Float32Array(memory.buffer, 0, n * 2);
        dual.precompute_twiddles(n);
        return { data, inputBuffer: inputF32 };
      },
      (ctx) => {
        ctx.data.set(ctx.inputBuffer);
        dual.fft(n);
      },
    );
    results.push(dualResult);

    // 2. Original f32 FFT
    const origResult = runBenchmark(
      "f32 Original",
      () => {
        const memory = original.memory;
        const data = new Float32Array(memory.buffer, 0, n * 2);
        original.precompute_twiddles(n);
        return { data, inputBuffer: inputF32 };
      },
      (ctx) => {
        ctx.data.set(ctx.inputBuffer);
        original.fft_stockham(n);
      },
    );
    results.push(origResult);

    // 3. fft.js (JS reference)
    const inputF64 = Array.from(inputF32);
    const fftJs = new FFT(n);
    const fftJsResult = runBenchmark(
      "fft.js (JS)",
      () => {
        const fftInput = inputF64.slice();
        const fftOutput = fftJs.createComplexArray();
        return { fftInput, fftOutput };
      },
      (ctx) => {
        fftJs.transform(ctx.fftOutput, ctx.fftInput);
      },
    );
    results.push(fftJsResult);

    // Sort by performance
    results.sort((a, b) => b.opsPerSec - a.opsPerSec);

    // Print results
    console.log("");
    console.log("Implementation              ops/sec      vs fastest    vs Original   vs fft.js");
    console.log("─".repeat(80));
    const fastest = results[0].opsPerSec;
    for (const result of results) {
      const vsFastest =
        result.opsPerSec / fastest === 1
          ? "(fastest)"
          : `${((result.opsPerSec / fastest) * 100).toFixed(1)}%`;
      const vsOrig =
        result.name === "f32 Original"
          ? "-"
          : `${result.opsPerSec >= origResult.opsPerSec ? "+" : ""}${(((result.opsPerSec - origResult.opsPerSec) / origResult.opsPerSec) * 100).toFixed(1)}%`;
      const vsFftJs =
        result.name === "fft.js (JS)"
          ? "-"
          : `${result.opsPerSec >= fftJsResult.opsPerSec ? "+" : ""}${(((result.opsPerSec - fftJsResult.opsPerSec) / fftJsResult.opsPerSec) * 100).toFixed(1)}%`;
      console.log(
        `${result.name.padEnd(22)} ${formatNumber(result.opsPerSec).padStart(10)}    ${vsFastest.padStart(10)}    ${vsOrig.padStart(10)}    ${vsFftJs.padStart(10)}`,
      );
    }
    console.log("");
  }

  console.log("=".repeat(80));
  console.log("Benchmark complete!");
  console.log("=".repeat(80));
}

runBenchmarks().catch(console.error);
