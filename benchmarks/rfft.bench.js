/**
 * Real FFT Performance Benchmarks
 *
 * Compares our WAT/WASM Real FFT implementation against:
 * - kissfft-wasm - WebAssembly port of KissFFT
 * - fftw-js - Emscripten port of FFTW
 *
 * Note: kissfft-wasm and fftw-js use Float32 (single precision),
 * while our implementation uses Float64 (double precision).
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { rfft as kissRfft, RealFFTConfig, RealArray, ComplexArray } from "kissfft-wasm";
import fftwJs from "fftw-js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Load our Real FFT WASM module
async function loadRealWasmFFT() {
  const wasmPath = path.join(__dirname, "..", "dist", "combined_real.wasm");
  const wasmBuffer = fs.readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);
  const instance = await WebAssembly.instantiate(wasmModule, {
    math: { sin: Math.sin, cos: Math.cos },
  });
  return instance.exports;
}

// Load our Stockham WASM FFT for complex FFT comparison
async function loadStockhamWasmFFT() {
  const wasmPath = path.join(__dirname, "..", "dist", "combined_stockham.wasm");
  const wasmBuffer = fs.readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);
  const instance = await WebAssembly.instantiate(wasmModule, {
    math: { sin: Math.sin, cos: Math.cos },
  });
  return instance.exports;
}

// Benchmark configuration
const WARMUP_ITERATIONS = 100;
const BENCHMARK_DURATION_MS = 2000;
const SIZES = [64, 256, 1024, 4096];

// Generate random real input data
function generateRealInput(n) {
  const real32 = new Float32Array(n);
  const real64 = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    const val = Math.random() * 2 - 1;
    real32[i] = val;
    real64[i] = val;
  }
  return { real32, real64 };
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

  const endTime = performance.now();
  const elapsed = endTime - startTime;
  const opsPerSec = (iterations / elapsed) * 1000;

  if (teardownFn) teardownFn(freshCtx);

  return { name, iterations, elapsed, opsPerSec };
}

function formatNumber(num) {
  return num.toLocaleString("en-US", { maximumFractionDigits: 0 });
}

async function runBenchmarks() {
  console.log("=".repeat(70));
  console.log("Real FFT Performance Benchmarks");
  console.log("=".repeat(70));
  console.log(`Duration: ${BENCHMARK_DURATION_MS}ms per test`);
  console.log(`Warmup: ${WARMUP_ITERATIONS} iterations`);
  console.log("");
  console.log("Note: kissfft-wasm and fftw-js use Float32 (single precision)");
  console.log("      wat-fft uses Float64 (double precision)");
  console.log("");

  const realWasmExports = await loadRealWasmFFT();
  const stockhamWasmExports = await loadStockhamWasmFFT();

  for (const size of SIZES) {
    console.log("-".repeat(70));
    console.log(`Real FFT Size: N=${size}`);
    console.log("-".repeat(70));

    const input = generateRealInput(size);
    const results = [];

    // 1. Our WASM Real FFT (double precision)
    const watRfftResult = runBenchmark(
      "wat-fft rfft (f64)",
      () => {
        const memory = realWasmExports.memory;
        const data = new Float64Array(memory.buffer, 0, size);
        realWasmExports.precompute_rfft_twiddles(size);
        return { data, inputBuffer: input.real64 };
      },
      (ctx) => {
        ctx.data.set(ctx.inputBuffer);
        realWasmExports.rfft(size);
      },
    );
    results.push(watRfftResult);

    // 2. Our WASM complex FFT on real input (for comparison)
    const watCfftResult = runBenchmark(
      "wat-fft cfft (f64)",
      () => {
        const memory = stockhamWasmExports.memory;
        const data = new Float64Array(memory.buffer, 0, size * 2);
        stockhamWasmExports.precompute_twiddles(size);
        // Prepare interleaved buffer with im=0
        const inputBuffer = new Float64Array(size * 2);
        for (let i = 0; i < size; i++) {
          inputBuffer[i * 2] = input.real64[i];
          inputBuffer[i * 2 + 1] = 0;
        }
        return { data, inputBuffer };
      },
      (ctx) => {
        ctx.data.set(ctx.inputBuffer);
        stockhamWasmExports.fft_stockham(size);
      },
    );
    results.push(watCfftResult);

    // 3. kissfft-wasm (single precision) - using stateful API for fair comparison
    // Note: kissfft-wasm expects output ComplexArray with same nfft as input
    const kissRfftResult = runBenchmark(
      "kissfft-wasm rfft (f32)",
      () => {
        const config = new RealFFTConfig(size);
        const inputArray = new RealArray(size);
        const outputArray = new ComplexArray(size); // Same size as input, not n/2+1
        return { config, inputArray, outputArray, inputData: input.real32 };
      },
      (ctx) => {
        // Copy input data directly into WASM memory
        ctx.inputArray.asFloat32Array().set(ctx.inputData);
        ctx.config.work(ctx.inputArray, ctx.outputArray);
      },
      (ctx) => {
        ctx.config.free();
        ctx.inputArray.free();
        ctx.outputArray.free();
      },
    );
    results.push(kissRfftResult);

    // 4. kissfft-wasm simple API (includes allocation overhead)
    const kissSimpleResult = runBenchmark(
      "kissfft-wasm simple (f32)",
      () => {
        return { inputData: input.real32 };
      },
      (ctx) => {
        kissRfft(ctx.inputData);
      },
    );
    results.push(kissSimpleResult);

    // 5. fftw-js (single precision)
    const fftwResult = runBenchmark(
      "fftw-js FFT (f32)",
      () => {
        const fft = new fftwJs.FFT(size);
        return { fft, inputData: input.real32 };
      },
      (ctx) => {
        ctx.fft.forward(ctx.inputData);
      },
      (ctx) => {
        ctx.fft.dispose();
      },
    );
    results.push(fftwResult);

    // Sort by performance
    results.sort((a, b) => b.opsPerSec - a.opsPerSec);
    const fastest = results[0].opsPerSec;

    // Print results
    console.log("");
    console.log("Library                        ops/sec        relative");
    console.log("─".repeat(55));

    for (const result of results) {
      const relative = result.opsPerSec / fastest;
      const relativeStr = relative === 1 ? "(fastest)" : `${(relative * 100).toFixed(1)}%`;
      const bar = "█".repeat(Math.round(relative * 20));
      console.log(
        `${result.name.padEnd(27)} ${formatNumber(result.opsPerSec).padStart(10)}    ${relativeStr.padStart(10)}  ${bar}`,
      );
    }
    console.log("");
  }

  console.log("=".repeat(70));
  console.log("Benchmark complete!");
  console.log("");
  console.log("Notes:");
  console.log("- wat-fft rfft: Our real FFT using N/2 complex FFT + post-processing (f64)");
  console.log("- wat-fft cfft: Complex FFT on real input with im=0 for comparison (f64)");
  console.log("- kissfft-wasm rfft: KissFFT WASM with stateful API (f32)");
  console.log("- kissfft-wasm simple: KissFFT WASM simple API with allocation (f32)");
  console.log("- fftw-js: FFTW via Emscripten (f32)");
  console.log("");
  console.log("The rfft should be ~2x faster than cfft for the same input size");
  console.log("since it computes only N/2 complex FFT internally.");
  console.log("=".repeat(70));
}

runBenchmarks().catch(console.error);
