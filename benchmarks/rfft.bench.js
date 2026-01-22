/**
 * Real FFT Performance Benchmarks
 *
 * Compares our WAT/WASM Real FFT implementation against:
 * - fftw-js - Emscripten port of FFTW
 * - kissfft-js - Emscripten port of Kiss FFT
 *
 * Note: fftw-js and kissfft-js use Float32 (single precision),
 * while our implementation uses Float64 (double precision).
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import fftwJs from "fftw-js";
import kissfft from "kissfft-js";

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

// Load our Combined Real FFT WASM module (f64, auto-dispatch)
async function loadCombinedRealWasmFFT() {
  const wasmPath = path.join(__dirname, "..", "dist", "fft_real_combined.wasm");
  const wasmBuffer = fs.readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);
  const instance = await WebAssembly.instantiate(wasmModule, {});
  return instance.exports;
}

// Benchmark configuration
const WARMUP_ITERATIONS = 100;
const BENCHMARK_DURATION_MS = 2000;
// Test sizes: include both radix-4 eligible (N/2 is power-of-4) and radix-2 sizes
// Radix-4 eligible: N=8,32,128,512,2048 (N/2=4,16,64,256,1024)
// Radix-2 only: N=16,64,256,1024,4096 (N/2=8,32,128,512,2048)
const SIZES = [8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096];

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
  const combinedRealWasmExports = await loadCombinedRealWasmFFT();

  for (const size of SIZES) {
    // N/2 is the internal complex FFT size
    const n2 = size / 2;
    const n2IsPow4 = (n2 & (n2 - 1)) === 0 && (n2 & 0xaaaaaaaa) === 0;

    console.log("-".repeat(70));
    console.log(`Real FFT Size: N=${size} (N/2=${n2}, ${n2IsPow4 ? "radix-4" : "radix-2"})`);
    console.log("-".repeat(70));

    const input = generateRealInput(size);
    const results = [];

    // 1. Our WASM Combined Real FFT (f64) - RECOMMENDED
    const combinedResult = runBenchmark(
      "wat-fft Combined (f64)",
      () => {
        const memory = combinedRealWasmExports.memory;
        const data = new Float64Array(memory.buffer, 0, size);
        combinedRealWasmExports.precompute_rfft_twiddles(size);
        return { data, inputBuffer: input.real64 };
      },
      (ctx) => {
        ctx.data.set(ctx.inputBuffer);
        combinedRealWasmExports.rfft(size);
      },
    );
    results.push(combinedResult);

    // 2. Our WASM Real FFT with Radix-4 (f64) - only for sizes where N/2 is power-of-4
    if (n2IsPow4) {
      const radix4Result = runBenchmark(
        "wat-fft Radix-4 (f64)",
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
      results.push(radix4Result);
    }

    // 3. fftw-js (single precision)
    const fftwResult = runBenchmark(
      "fftw-js (f32)",
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

    // 4. kissfft-js (single precision)
    const kissfftResult = runBenchmark(
      "kissfft-js (f32)",
      () => {
        const fft = new kissfft.FFTR(size);
        return { fft, inputData: input.real32 };
      },
      (ctx) => {
        ctx.fft.forward(ctx.inputData);
      },
      (ctx) => {
        ctx.fft.dispose();
      },
    );
    results.push(kissfftResult);

    // Sort by performance
    results.sort((a, b) => b.opsPerSec - a.opsPerSec);

    // Calculate speedup of wat-fft Combined vs fftw-js
    const speedup = combinedResult.opsPerSec / fftwResult.opsPerSec;
    const speedupStr =
      speedup >= 1
        ? `+${((speedup - 1) * 100).toFixed(1)}%`
        : `${((speedup - 1) * 100).toFixed(1)}%`;

    // Print results
    console.log("");
    console.log("Library                        ops/sec      relative");
    console.log("─".repeat(55));
    const fastest = results[0].opsPerSec;
    for (const result of results) {
      const relative = result.opsPerSec / fastest;
      const relativeStr = relative === 1 ? "(fastest)" : `${(relative * 100).toFixed(1)}%`;
      console.log(
        `${result.name.padEnd(27)} ${formatNumber(result.opsPerSec).padStart(10)}    ${relativeStr.padStart(10)}`,
      );
    }
    console.log("");
    console.log(`wat-fft Combined vs fftw-js: ${speedupStr}`);
    console.log("");
  }

  console.log("=".repeat(70));
  console.log("Benchmark complete!");
  console.log("=".repeat(70));
}

runBenchmarks().catch(console.error);
