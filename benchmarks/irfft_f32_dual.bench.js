/**
 * f32 Dual-Complex Inverse Real FFT Benchmark
 *
 * Compares the f32 irfft against fftw-js (f32) inverse
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import fftwJs from "fftw-js";
import PFFFT from "@echogarden/pffft-wasm/simd";

const PFFFT_REAL = 0;
const PFFFT_BACKWARD = 1;

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

async function loadWasm(name) {
  const wasmPath = path.join(__dirname, "..", "dist", `${name}.wasm`);
  const wasmBuffer = fs.readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);
  const instance = await WebAssembly.instantiate(wasmModule, {});
  return instance.exports;
}

const WARMUP_ITERATIONS = 100;
const BENCHMARK_DURATION_MS = 2000;
const SIZES = [64, 128, 256, 512, 1024, 2048, 4096];

function generateRealInput(n) {
  const data = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    data[i] = Math.random() * 2 - 1;
  }
  return data;
}

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
  console.log("f32 Inverse Real FFT Benchmark");
  console.log("=".repeat(70));
  console.log(`Duration: ${BENCHMARK_DURATION_MS}ms per test`);
  console.log(`Warmup: ${WARMUP_ITERATIONS} iterations`);
  console.log("");

  const wasmExports = await loadWasm("fft_real_f32_dual");
  const splitExports = await loadWasm("fft_split_native_f32");
  const pffft = await PFFFT();

  const summary = [];

  for (const size of SIZES) {
    console.log("-".repeat(70));
    console.log(`Inverse Real FFT Size: N=${size}`);
    console.log("-".repeat(70));

    const input = generateRealInput(size);
    const results = [];

    // 1. f32 IRFFT
    const wasmResult = runBenchmark(
      "wat-fft (f32)",
      () => {
        const memory = wasmExports.memory;
        // Spectrum: N/2+1 complex values = N+2 floats
        const data = new Float32Array(memory.buffer, 0, size + 2);
        wasmExports.precompute_rfft_twiddles(size);
        // Produce a real spectrum by running the forward RFFT once
        new Float32Array(memory.buffer, 0, size).set(input);
        wasmExports.rfft(size);
        const spectrum = new Float32Array(size + 2);
        spectrum.set(data);
        return { data, spectrum };
      },
      (ctx) => {
        ctx.data.set(ctx.spectrum);
        wasmExports.irfft(size);
      },
    );
    results.push(wasmResult);

    // 2. f32 split-core IRFFT (Experiment 60)
    const splitResult = runBenchmark(
      "wat-fft split (f32)",
      () => {
        const memory = splitExports.memory;
        // Spectrum: N/2+1 complex values = N+2 floats
        const data = new Float32Array(memory.buffer, 0, size + 2);
        splitExports.precompute_rfft_twiddles_split(size);
        // Produce a real spectrum by running the forward RFFT once
        new Float32Array(memory.buffer, 0, size).set(input);
        splitExports.rfft_split(size);
        const spectrum = new Float32Array(size + 2);
        spectrum.set(data);
        return { data, spectrum };
      },
      (ctx) => {
        ctx.data.set(ctx.spectrum);
        splitExports.irfft_split(size);
      },
    );
    results.push(splitResult);

    // 3. fftw-js (f32)
    const fftwResult = runBenchmark(
      "fftw-js (f32)",
      () => {
        const fft = new fftwJs.FFT(size);
        const spectrum = fft.forward(input);
        return { fft, spectrum };
      },
      (ctx) => {
        ctx.fft.inverse(ctx.spectrum);
      },
      (ctx) => {
        ctx.fft.dispose();
      },
    );
    results.push(fftwResult);

    // 4. pffft-wasm SIMD (f32) - unscaled backward transform
    const pffftResult = runBenchmark(
      "pffft-wasm SIMD (f32)",
      () => {
        const setup = pffft._pffft_new_setup(size, PFFFT_REAL);
        const inputPtr = pffft._pffft_aligned_malloc(size * 4);
        const outputPtr = pffft._pffft_aligned_malloc(size * 4);
        // Produce a real spectrum by running the forward transform once
        new Float32Array(pffft.HEAPF32.buffer, inputPtr, size).set(input);
        pffft._pffft_transform_ordered(setup, inputPtr, outputPtr, 0, 0);
        const spectrum = new Float32Array(size);
        spectrum.set(new Float32Array(pffft.HEAPF32.buffer, outputPtr, size));
        return { setup, inputPtr, outputPtr, spectrum };
      },
      (ctx) => {
        new Float32Array(pffft.HEAPF32.buffer, ctx.inputPtr, size).set(ctx.spectrum);
        pffft._pffft_transform_ordered(ctx.setup, ctx.inputPtr, ctx.outputPtr, 0, PFFFT_BACKWARD);
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

    // Calculate speedup (best wat-fft implementation: the split core)
    const vsFftw = splitResult.opsPerSec / fftwResult.opsPerSec;
    const vsPffft = splitResult.opsPerSec / pffftResult.opsPerSec;

    // Print results
    console.log("");
    console.log("Implementation                 ops/sec      relative");
    console.log("-".repeat(55));
    const fastest = results[0].opsPerSec;
    for (const result of results) {
      const relative = result.opsPerSec / fastest;
      const relativeStr = relative === 1 ? "(fastest)" : `${(relative * 100).toFixed(1)}%`;
      console.log(
        `${result.name.padEnd(27)} ${formatNumber(result.opsPerSec).padStart(10)}    ${relativeStr.padStart(10)}`,
      );
    }
    console.log("");
    console.log(`wat-fft vs fftw-js: ${vsFftw >= 1 ? "+" : ""}${((vsFftw - 1) * 100).toFixed(1)}%`);
    console.log(
      `wat-fft vs pffft-simd: ${vsPffft >= 1 ? "+" : ""}${((vsPffft - 1) * 100).toFixed(1)}%`,
    );
    console.log("");

    summary.push({
      size,
      wasm: splitResult.opsPerSec,
      fftw: fftwResult.opsPerSec,
      pffft: pffftResult.opsPerSec,
      vsFftw: `${vsFftw >= 1 ? "+" : ""}${((vsFftw - 1) * 100).toFixed(1)}%`,
      vsPffft: `${vsPffft >= 1 ? "+" : ""}${((vsPffft - 1) * 100).toFixed(1)}%`,
    });
  }

  // Print summary
  console.log("=".repeat(70));
  console.log("Summary");
  console.log("=".repeat(70));
  console.log("");
  console.log("Size     wat-fft      fftw-js    pffft-simd   vs fftw-js  vs pffft-simd");
  console.log("-".repeat(75));
  for (const { size, wasm, fftw, pffft: pf, vsFftw, vsPffft } of summary) {
    console.log(
      `N=${String(size).padEnd(5)} ${formatNumber(wasm).padStart(10)}  ${formatNumber(fftw).padStart(10)}  ${formatNumber(pf).padStart(10)}     ${vsFftw.padStart(8)}     ${vsPffft.padStart(8)}`,
    );
  }
  console.log("");
  console.log("=".repeat(70));
  console.log("Benchmark complete!");
  console.log("=".repeat(70));
}

runBenchmarks().catch(console.error);
