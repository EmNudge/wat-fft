/**
 * Real FFT Performance Benchmarks
 *
 * Compares our WAT/WASM Real FFT implementation against:
 * - fftw-js - Emscripten port of FFTW
 *
 * Note: fftw-js uses Float32 (single precision),
 * while our implementation uses Float64 (double precision).
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import fftwJs from "fftw-js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Load our Radix-4 Real FFT WASM module (f64)
async function loadRadix4RealWasmFFT() {
  const wasmPath = path.join(__dirname, "..", "dist", "fft_real_radix4.wasm");
  const wasmBuffer = fs.readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);
  const instance = await WebAssembly.instantiate(wasmModule, {});
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
  console.log("Note: fftw-js uses Float32 (single precision)");
  console.log("      wat-fft uses Float64 (double precision)");
  console.log("");

  const radix4RealWasmExports = await loadRadix4RealWasmFFT();

  for (const size of SIZES) {
    console.log("-".repeat(70));
    console.log(`Real FFT Size: N=${size}`);
    console.log("-".repeat(70));

    const input = generateRealInput(size);

    // 1. Our WASM Real FFT with Radix-4 (f64)
    const watRfftResult = runBenchmark(
      "wat-fft rfft (f64)",
      () => {
        const memory = radix4RealWasmExports.memory;
        const data = new Float64Array(memory.buffer, 0, size);
        radix4RealWasmExports.precompute_rfft_twiddles(size);
        return { data, inputBuffer: input.real64 };
      },
      (ctx) => {
        ctx.data.set(ctx.inputBuffer);
        radix4RealWasmExports.rfft(size);
      },
    );

    // 2. fftw-js (single precision)
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

    // Calculate speedup of wat-fft vs fftw-js
    const speedup = watRfftResult.opsPerSec / fftwResult.opsPerSec;
    const speedupStr =
      speedup >= 1
        ? `+${((speedup - 1) * 100).toFixed(1)}%`
        : `${((speedup - 1) * 100).toFixed(1)}%`;

    // Print results
    console.log("");
    console.log("Library                        ops/sec");
    console.log("─".repeat(45));
    console.log(
      `${watRfftResult.name.padEnd(27)} ${formatNumber(watRfftResult.opsPerSec).padStart(10)}`,
    );
    console.log(`${fftwResult.name.padEnd(27)} ${formatNumber(fftwResult.opsPerSec).padStart(10)}`);
    console.log("");
    console.log(`wat-fft vs fftw-js: ${speedupStr}`);
    console.log("");
  }

  console.log("=".repeat(70));
  console.log("Benchmark complete!");
  console.log("=".repeat(70));
}

runBenchmarks().catch(console.error);
