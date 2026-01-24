/**
 * f32 Dual-Complex Real FFT Benchmark
 *
 * Compares the new dual-complex f32 rfft against:
 * - Existing f32 rfft (non-dual)
 * - fftw-js (f32)
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import fftwJs from "fftw-js";

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
  console.log("f32 Dual-Complex Real FFT Benchmark");
  console.log("=".repeat(70));
  console.log(`Duration: ${BENCHMARK_DURATION_MS}ms per test`);
  console.log(`Warmup: ${WARMUP_ITERATIONS} iterations`);
  console.log("");
  console.log("Comparing: f32 dual-complex rfft vs existing f32 rfft vs fftw-js");
  console.log("");

  const dualExports = await loadWasm("fft_real_f32_dual");
  const existingExports = await loadWasm("combined_real_f32");

  const summary = [];

  for (const size of SIZES) {
    console.log("-".repeat(70));
    console.log(`Real FFT Size: N=${size}`);
    console.log("-".repeat(70));

    const input = generateRealInput(size);
    const results = [];

    // 1. f32 Dual-Complex RFFT
    const dualResult = runBenchmark(
      "f32 dual-complex",
      () => {
        const memory = dualExports.memory;
        const data = new Float32Array(memory.buffer, 0, size);
        dualExports.precompute_rfft_twiddles(size);
        return { data, inputBuffer: input };
      },
      (ctx) => {
        ctx.data.set(ctx.inputBuffer);
        dualExports.rfft(size);
      },
    );
    results.push(dualResult);

    // 2. Existing f32 RFFT (non-dual)
    const existingResult = runBenchmark(
      "f32 existing",
      () => {
        const memory = existingExports.memory;
        const data = new Float32Array(memory.buffer, 0, size);
        existingExports.precompute_rfft_twiddles(size);
        return { data, inputBuffer: input };
      },
      (ctx) => {
        ctx.data.set(ctx.inputBuffer);
        existingExports.rfft(size);
      },
    );
    results.push(existingResult);

    // 3. fftw-js (f32)
    const fftwResult = runBenchmark(
      "fftw-js (f32)",
      () => {
        const fft = new fftwJs.FFT(size);
        return { fft, inputData: input };
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

    // Calculate speedups
    const dualVsExisting = dualResult.opsPerSec / existingResult.opsPerSec;
    const dualVsFftw = dualResult.opsPerSec / fftwResult.opsPerSec;

    // Print results
    console.log("");
    console.log("Implementation                 ops/sec      relative");
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
    console.log(
      `Dual vs existing f32: ${dualVsExisting >= 1 ? "+" : ""}${((dualVsExisting - 1) * 100).toFixed(1)}%`,
    );
    console.log(
      `Dual vs fftw-js:      ${dualVsFftw >= 1 ? "+" : ""}${((dualVsFftw - 1) * 100).toFixed(1)}%`,
    );
    console.log("");

    summary.push({
      size,
      dual: dualResult.opsPerSec,
      existing: existingResult.opsPerSec,
      fftw: fftwResult.opsPerSec,
      vsExisting: `${dualVsExisting >= 1 ? "+" : ""}${((dualVsExisting - 1) * 100).toFixed(1)}%`,
      vsFftw: `${dualVsFftw >= 1 ? "+" : ""}${((dualVsFftw - 1) * 100).toFixed(1)}%`,
    });
  }

  // Print summary
  console.log("=".repeat(70));
  console.log("Summary");
  console.log("=".repeat(70));
  console.log("");
  console.log("Size     Dual         Existing     fftw-js      vs Existing  vs fftw-js");
  console.log("─".repeat(75));
  for (const { size, dual, existing, fftw, vsExisting, vsFftw } of summary) {
    console.log(
      `N=${String(size).padEnd(5)} ${formatNumber(dual).padStart(10)}  ${formatNumber(existing).padStart(10)}  ${formatNumber(fftw).padStart(10)}     ${vsExisting.padStart(8)}    ${vsFftw.padStart(8)}`,
    );
  }
  console.log("");
  console.log("=".repeat(70));
  console.log("Benchmark complete!");
  console.log("=".repeat(70));
}

runBenchmarks().catch(console.error);
