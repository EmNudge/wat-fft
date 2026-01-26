/**
 * FFT Performance Benchmarks
 *
 * Compares our WAT/WASM FFT implementations against popular JS libraries:
 * - fft.js (indutny) - Fastest pure JS, Radix-4 implementation
 * - fft-js - Simple Cooley-Tukey implementation
 * - kissfft-js - Emscripten port of Kiss FFT
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import FFT from "fft.js";
import * as fftJs from "fft-js";
import kissfft from "kissfft-js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Load Stockham WASM FFT (self-contained, no imports needed)
async function loadStockhamWasmFFT() {
  const wasmPath = path.join(__dirname, "..", "dist", "combined_stockham.wasm");
  const wasmBuffer = fs.readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);
  const instance = await WebAssembly.instantiate(wasmModule);
  return instance.exports;
}

// Load Fast WASM FFT (non-SIMD fallback)
async function loadFastWasmFFT() {
  const wasmPath = path.join(__dirname, "..", "dist", "combined_fast.wasm");
  const wasmBuffer = fs.readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);
  const instance = await WebAssembly.instantiate(wasmModule, {
    math: { sin: Math.sin, cos: Math.cos },
  });
  return instance.exports;
}

// Load Combined WASM FFT (auto-dispatch radix-2/4)
async function loadCombinedWasmFFT() {
  const wasmPath = path.join(__dirname, "..", "dist", "fft_combined.wasm");
  const wasmBuffer = fs.readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);
  const instance = await WebAssembly.instantiate(wasmModule);
  return instance.exports;
}

// Benchmark configuration
const WARMUP_ITERATIONS = 100;
const BENCHMARK_DURATION_MS = 2000;
// Include both power-of-4 (16, 64, 256, 1024, 4096) and non-power-of-4 (32, 128, 512, 2048)
const SIZES = [16, 32, 64, 128, 256, 512, 1024, 2048, 4096];

// Generate random complex input data
function generateComplexInput(n) {
  const real = new Float64Array(n);
  const imag = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    real[i] = Math.random() * 2 - 1;
    imag[i] = Math.random() * 2 - 1;
  }
  return { real, imag };
}

// Benchmark runner
function runBenchmark(name, setupFn, benchFn, teardownFn = null) {
  const ctx = setupFn();
  for (let i = 0; i < WARMUP_ITERATIONS; i++) {
    benchFn(ctx);
  }
  if (teardownFn) teardownFn(ctx);

  const freshCtx = setupFn();
  const startTime = performance.now();
  let iterations = 0;

  while (performance.now() - startTime < BENCHMARK_DURATION_MS) {
    benchFn(freshCtx);
    iterations++;
  }

  const elapsed = performance.now() - startTime;
  const opsPerSec = (iterations / elapsed) * 1000;

  if (teardownFn) teardownFn(freshCtx);

  return { name, iterations, elapsed, opsPerSec };
}

function formatNumber(num) {
  return num.toLocaleString("en-US", { maximumFractionDigits: 0 });
}

async function runBenchmarks() {
  console.log("=".repeat(70));
  console.log("FFT Performance Benchmarks");
  console.log("=".repeat(70));
  console.log(`Duration: ${BENCHMARK_DURATION_MS}ms per test`);
  console.log(`Warmup: ${WARMUP_ITERATIONS} iterations`);
  console.log("");

  const stockhamExports = await loadStockhamWasmFFT();
  const fastExports = await loadFastWasmFFT();
  const combinedExports = await loadCombinedWasmFFT();

  for (const size of SIZES) {
    console.log("-".repeat(70));
    console.log(`FFT Size: N=${size}`);
    console.log("-".repeat(70));

    const input = generateComplexInput(size);
    const results = [];

    // wat-fft Stockham (radix-2)
    const stockhamResult = runBenchmark(
      "wat-fft (Radix-2)",
      () => {
        const memory = stockhamExports.memory;
        const data = new Float64Array(memory.buffer, 0, size * 2);
        stockhamExports.precompute_twiddles(size);
        const inputBuffer = new Float64Array(size * 2);
        for (let i = 0; i < size; i++) {
          inputBuffer[i * 2] = input.real[i];
          inputBuffer[i * 2 + 1] = input.imag[i];
        }
        return { data, inputBuffer, size };
      },
      (ctx) => {
        ctx.data.set(ctx.inputBuffer);
        stockhamExports.fft_stockham(ctx.size);
      },
    );
    results.push(stockhamResult);

    // wat-fft Combined (auto-dispatch radix-2/4) - recommended for all sizes
    const combinedResult = runBenchmark(
      `wat-fft (Combined)`,
      () => {
        const memory = combinedExports.memory;
        const data = new Float64Array(memory.buffer, 0, size * 2);
        combinedExports.precompute_twiddles(size);
        const inputBuffer = new Float64Array(size * 2);
        for (let i = 0; i < size; i++) {
          inputBuffer[i * 2] = input.real[i];
          inputBuffer[i * 2 + 1] = input.imag[i];
        }
        return { data, inputBuffer, size };
      },
      (ctx) => {
        ctx.data.set(ctx.inputBuffer);
        combinedExports.fft(ctx.size);
      },
    );
    results.push(combinedResult);

    // wat-fft Fast (non-SIMD fallback)
    const fastResult = runBenchmark(
      "wat-fft (fast)",
      () => {
        const memory = fastExports.memory;
        const data = new Float64Array(memory.buffer, 0, size * 2);
        fastExports.precompute_twiddles(size);
        const inputBuffer = new Float64Array(size * 2);
        for (let i = 0; i < size; i++) {
          inputBuffer[i * 2] = input.real[i];
          inputBuffer[i * 2 + 1] = input.imag[i];
        }
        return { data, inputBuffer, size };
      },
      (ctx) => {
        ctx.data.set(ctx.inputBuffer);
        fastExports.fft_fast(ctx.size);
      },
    );
    results.push(fastResult);

    // fft.js (indutny)
    const fftJsResult = runBenchmark(
      "fft.js (Radix-4)",
      () => {
        const fft = new FFT(size);
        const out = fft.createComplexArray();
        const complexInput = fft.createComplexArray();
        for (let i = 0; i < size; i++) {
          complexInput[i * 2] = input.real[i];
          complexInput[i * 2 + 1] = input.imag[i];
        }
        return { fft, complexInput, out };
      },
      (ctx) => {
        ctx.fft.transform(ctx.out, ctx.complexInput);
      },
    );
    results.push(fftJsResult);

    // fft-js
    const fftJsSimpleResult = runBenchmark(
      "fft-js (Cooley-Tukey)",
      () => {
        const signal = [];
        for (let i = 0; i < size; i++) {
          signal.push([input.real[i], input.imag[i]]);
        }
        return { signal };
      },
      (ctx) => {
        fftJs.fft(ctx.signal);
      },
    );
    results.push(fftJsSimpleResult);

    // kissfft-js
    const kissfftResult = runBenchmark(
      "kissfft-js",
      () => {
        const fft = new kissfft.FFT(size);
        // kissfft expects interleaved complex input
        const complexInput = new Float64Array(size * 2);
        for (let i = 0; i < size; i++) {
          complexInput[i * 2] = input.real[i];
          complexInput[i * 2 + 1] = input.imag[i];
        }
        return { fft, complexInput };
      },
      (ctx) => {
        ctx.fft.forward(ctx.complexInput);
      },
      (ctx) => {
        ctx.fft.dispose();
      },
    );
    results.push(kissfftResult);

    // Sort by performance
    results.sort((a, b) => b.opsPerSec - a.opsPerSec);
    const fastest = results[0].opsPerSec;

    console.log("");
    console.log("Library                   ops/sec        relative");
    console.log("─".repeat(50));

    for (const result of results) {
      const relative = result.opsPerSec / fastest;
      const relativeStr = relative === 1 ? "(fastest)" : `${(relative * 100).toFixed(1)}%`;
      const bar = "█".repeat(Math.round(relative * 20));
      console.log(
        `${result.name.padEnd(22)} ${formatNumber(result.opsPerSec).padStart(10)}    ${relativeStr.padStart(10)}  ${bar}`,
      );
    }
    console.log("");
  }

  console.log("=".repeat(70));
  console.log("Benchmark complete!");
  console.log("");
  console.log("Notes:");
  console.log("- wat-fft (Combined): Auto-selects radix-4 or radix-2 (RECOMMENDED)");
  console.log("- wat-fft (Radix-2): SIMD radix-2 Stockham for all power-of-2");
  console.log("- wat-fft (fast): Non-SIMD fallback for older environments");
  console.log("- fft.js: Highly optimized Radix-4 JS (Fedor Indutny)");
  console.log("- kissfft-js: Emscripten port of Kiss FFT");
  console.log("- fft-js: Simple Cooley-Tukey JS (educational)");
  console.log("=".repeat(70));
}

runBenchmarks().catch(console.error);
