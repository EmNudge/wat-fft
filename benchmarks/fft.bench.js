/**
 * FFT Performance Benchmarks
 *
 * Compares our WAT/WASM FFT implementation against popular JS libraries:
 * - fft.js (indutny) - Fastest pure JS, Radix-4 implementation
 * - fft-js - Simple Cooley-Tukey implementation
 * - kissfft-js - Emscripten port of Kiss FFT
 * - webfft - Meta-library with multiple FFT implementations
 * - pffft-wasm - PFFFT compiled to WASM with SIMD support
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import FFT from "fft.js";
import * as fftJs from "fft-js";
import kissfft from "kissfft-js";
import webfft from "webfft";
import PFFFT from "@echogarden/pffft-wasm";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Load Combined WASM FFT (auto-dispatch radix-2/4)
async function loadWasmFFT() {
  const wasmPath = path.join(__dirname, "..", "dist", "fft_combined.wasm");
  const wasmBuffer = fs.readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);
  const instance = await WebAssembly.instantiate(wasmModule);
  return instance.exports;
}

// Load f32 Dual-Complex WASM FFT (f32 SIMD optimized)
async function loadWasmFFTf32() {
  const wasmPath = path.join(__dirname, "..", "dist", "fft_stockham_f32_dual.wasm");
  const wasmBuffer = fs.readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);
  const instance = await WebAssembly.instantiate(wasmModule);
  return instance.exports;
}

// Load f32 Split-format WASM FFT (native split format, 4 complex per SIMD op)
async function loadWasmFFTSplit() {
  const wasmPath = path.join(__dirname, "..", "dist", "fft_split_native_f32.wasm");
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
  const real32 = new Float32Array(n);
  const imag32 = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    real[i] = Math.random() * 2 - 1;
    imag[i] = Math.random() * 2 - 1;
    real32[i] = real[i];
    imag32[i] = imag[i];
  }
  return { real, imag, real32, imag32 };
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

  const wasmExports = await loadWasmFFT();
  const wasmExportsF32 = await loadWasmFFTf32();
  const wasmExportsSplit = await loadWasmFFTSplit();
  const pffft = await PFFFT();

  for (const size of SIZES) {
    console.log("-".repeat(70));
    console.log(`FFT Size: N=${size}`);
    console.log("-".repeat(70));

    const input = generateComplexInput(size);
    const results = [];

    // wat-fft (auto-dispatch radix-2/4) - our main implementation
    const wasmResult = runBenchmark(
      "wat-fft (f64)",
      () => {
        const memory = wasmExports.memory;
        const data = new Float64Array(memory.buffer, 0, size * 2);
        wasmExports.precompute_twiddles(size);
        const inputBuffer = new Float64Array(size * 2);
        for (let i = 0; i < size; i++) {
          inputBuffer[i * 2] = input.real[i];
          inputBuffer[i * 2 + 1] = input.imag[i];
        }
        return { data, inputBuffer, size };
      },
      (ctx) => {
        ctx.data.set(ctx.inputBuffer);
        wasmExports.fft(ctx.size);
      },
    );
    results.push(wasmResult);

    // wat-fft f32 (dual-complex SIMD optimized)
    const wasmF32Result = runBenchmark(
      "wat-fft (f32)",
      () => {
        const memory = wasmExportsF32.memory;
        const data = new Float32Array(memory.buffer, 0, size * 2);
        wasmExportsF32.precompute_twiddles(size);
        const inputBuffer = new Float32Array(size * 2);
        for (let i = 0; i < size; i++) {
          inputBuffer[i * 2] = input.real32[i];
          inputBuffer[i * 2 + 1] = input.imag32[i];
        }
        return { data, inputBuffer, size };
      },
      (ctx) => {
        ctx.data.set(ctx.inputBuffer);
        wasmExportsF32.fft(ctx.size);
      },
    );
    results.push(wasmF32Result);

    // wat-fft f32 split-format (native split format, 4 complex per SIMD op)
    const REAL_OFFSET = wasmExportsSplit.REAL_OFFSET;
    const IMAG_OFFSET = wasmExportsSplit.IMAG_OFFSET;
    const wasmSplitResult = runBenchmark(
      "wat-fft (f32 split)",
      () => {
        const memory = wasmExportsSplit.memory;
        const realData = new Float32Array(memory.buffer, REAL_OFFSET, size);
        const imagData = new Float32Array(memory.buffer, IMAG_OFFSET, size);
        wasmExportsSplit.precompute_twiddles_split(size);
        return { realData, imagData, realInput: input.real32, imagInput: input.imag32, size };
      },
      (ctx) => {
        ctx.realData.set(ctx.realInput);
        ctx.imagData.set(ctx.imagInput);
        wasmExportsSplit.fft_split(ctx.size);
      },
    );
    results.push(wasmSplitResult);

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

    // webfft (meta-library using kissWasm by default)
    const webfftResult = runBenchmark(
      "webfft (f32)",
      () => {
        const fft = new webfft(size);
        fft.setSubLibrary("kissWasm");
        const complexInput = new Float32Array(size * 2);
        for (let i = 0; i < size; i++) {
          complexInput[i * 2] = input.real[i];
          complexInput[i * 2 + 1] = input.imag[i];
        }
        return { fft, complexInput };
      },
      (ctx) => {
        ctx.fft.fft(ctx.complexInput);
      },
      (ctx) => {
        ctx.fft.dispose();
      },
    );
    results.push(webfftResult);

    // pffft-wasm (PFFFT with SIMD support)
    // PFFFT enum: { PFFFT_REAL=0, PFFFT_COMPLEX=1 }
    const PFFFT_COMPLEX = 1;
    const PFFFT_FORWARD = 0;
    const pffftResult = runBenchmark(
      "pffft-wasm (f32)",
      () => {
        const setup = pffft._pffft_new_setup(size, PFFFT_COMPLEX);
        const inputPtr = pffft._pffft_aligned_malloc(size * 2 * 4);
        const outputPtr = pffft._pffft_aligned_malloc(size * 2 * 4);
        const inputView = new Float32Array(pffft.HEAPF32.buffer, inputPtr, size * 2);
        for (let i = 0; i < size; i++) {
          inputView[i * 2] = input.real[i];
          inputView[i * 2 + 1] = input.imag[i];
        }
        return { setup, inputPtr, outputPtr, inputView };
      },
      (ctx) => {
        pffft._pffft_transform_ordered(ctx.setup, ctx.inputPtr, ctx.outputPtr, 0, PFFFT_FORWARD);
      },
      (ctx) => {
        pffft._pffft_aligned_free(ctx.inputPtr);
        pffft._pffft_aligned_free(ctx.outputPtr);
        pffft._pffft_destroy_setup(ctx.setup);
      },
    );
    results.push(pffftResult);

    // Sort by performance
    results.sort((a, b) => b.opsPerSec - a.opsPerSec);
    const fastest = results[0].opsPerSec;

    console.log("");
    console.log("Library                   ops/sec        relative");
    console.log("-".repeat(50));

    for (const result of results) {
      const relative = result.opsPerSec / fastest;
      const relativeStr = relative === 1 ? "(fastest)" : `${(relative * 100).toFixed(1)}%`;
      const bar = "#".repeat(Math.round(relative * 20));
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
  console.log("- wat-fft (f64): SIMD-optimized WASM with auto radix-2/4 dispatch");
  console.log("- wat-fft (f32): Dual-complex SIMD optimized (f32x4)");
  console.log("- wat-fft (f32 split): Split-format SIMD (4 complex per op)");
  console.log("- fft.js: Highly optimized Radix-4 JS (Fedor Indutny)");
  console.log("- kissfft-js: Emscripten port of Kiss FFT");
  console.log("- fft-js: Simple Cooley-Tukey JS (educational)");
  console.log("- webfft: Meta-library with kissWasm backend (f32)");
  console.log("- pffft-wasm: PFFFT compiled to WASM with SIMD (f32)");
  console.log("=".repeat(70));
}

runBenchmarks().catch(console.error);
