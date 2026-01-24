/**
 * Real FFT FMA Optimization Benchmark
 *
 * Compares the standard SIMD implementation against the relaxed SIMD FMA version.
 * Both use Float64 (double precision).
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Load standard WASM module
async function loadStandardWasm() {
  const wasmPath = path.join(__dirname, "..", "dist", "fft_real_combined.wasm");
  const wasmBuffer = fs.readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);
  const instance = await WebAssembly.instantiate(wasmModule, {});
  return instance.exports;
}

// Load FMA WASM module
async function loadFmaWasm() {
  const wasmPath = path.join(__dirname, "..", "dist", "fft_real_combined_fma.wasm");
  const wasmBuffer = fs.readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);
  const instance = await WebAssembly.instantiate(wasmModule, {});
  return instance.exports;
}

// Benchmark configuration
const WARMUP_ITERATIONS = 100;
const BENCHMARK_DURATION_MS = 2000;
// Focus on sizes that use the SIMD post-processing path (N >= 128)
const SIZES = [128, 256, 512, 1024, 2048, 4096];

// Generate random real input data
function generateRealInput(n) {
  const real64 = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    real64[i] = Math.random() * 2 - 1;
  }
  return real64;
}

// Benchmark runner
function runBenchmark(name, setupFn, benchFn) {
  const ctx = setupFn();
  for (let i = 0; i < WARMUP_ITERATIONS; i++) {
    benchFn(ctx);
  }

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

  return { name, iterations, elapsed, opsPerSec };
}

function formatNumber(num) {
  return num.toLocaleString("en-US", { maximumFractionDigits: 0 });
}

async function runBenchmarks() {
  console.log("=".repeat(70));
  console.log("Real FFT FMA Optimization Benchmark");
  console.log("=".repeat(70));
  console.log(`Duration: ${BENCHMARK_DURATION_MS}ms per test`);
  console.log(`Warmup: ${WARMUP_ITERATIONS} iterations`);
  console.log("");
  console.log("Comparing: Standard SIMD vs Relaxed SIMD FMA");
  console.log("Both implementations use Float64 (double precision)");
  console.log("");

  const standardExports = await loadStandardWasm();
  const fmaExports = await loadFmaWasm();

  const summary = [];

  for (const size of SIZES) {
    console.log("-".repeat(70));
    console.log(`Real FFT Size: N=${size}`);
    console.log("-".repeat(70));

    const input = generateRealInput(size);
    const results = [];

    // 1. Standard SIMD version
    const standardResult = runBenchmark(
      "Standard SIMD (f64)",
      () => {
        const memory = standardExports.memory;
        const data = new Float64Array(memory.buffer, 0, size);
        standardExports.precompute_rfft_twiddles(size);
        return { data, inputBuffer: input };
      },
      (ctx) => {
        ctx.data.set(ctx.inputBuffer);
        standardExports.rfft(size);
      },
    );
    results.push(standardResult);

    // 2. FMA version
    const fmaResult = runBenchmark(
      "Relaxed SIMD FMA (f64)",
      () => {
        const memory = fmaExports.memory;
        const data = new Float64Array(memory.buffer, 0, size);
        fmaExports.precompute_rfft_twiddles(size);
        return { data, inputBuffer: input };
      },
      (ctx) => {
        ctx.data.set(ctx.inputBuffer);
        fmaExports.rfft(size);
      },
    );
    results.push(fmaResult);

    // Calculate speedup
    const speedup = fmaResult.opsPerSec / standardResult.opsPerSec;
    const speedupStr =
      speedup >= 1
        ? `+${((speedup - 1) * 100).toFixed(1)}%`
        : `${((speedup - 1) * 100).toFixed(1)}%`;

    // Print results
    console.log("");
    console.log("Implementation                 ops/sec      relative");
    console.log("─".repeat(55));
    const fastest = Math.max(...results.map((r) => r.opsPerSec));
    for (const result of results) {
      const relative = result.opsPerSec / fastest;
      const relativeStr = relative === 1 ? "(fastest)" : `${(relative * 100).toFixed(1)}%`;
      console.log(
        `${result.name.padEnd(27)} ${formatNumber(result.opsPerSec).padStart(10)}    ${relativeStr.padStart(10)}`,
      );
    }
    console.log("");
    console.log(`FMA speedup: ${speedupStr}`);
    console.log("");

    summary.push({
      size,
      standard: standardResult.opsPerSec,
      fma: fmaResult.opsPerSec,
      speedup: speedupStr,
    });
  }

  // Print summary table
  console.log("=".repeat(70));
  console.log("Summary");
  console.log("=".repeat(70));
  console.log("");
  console.log("Size     Standard        FMA             Speedup");
  console.log("─".repeat(50));
  for (const { size, standard, fma, speedup } of summary) {
    console.log(
      `N=${String(size).padEnd(5)} ${formatNumber(standard).padStart(10)} ops/s  ${formatNumber(fma).padStart(10)} ops/s   ${speedup.padStart(7)}`,
    );
  }
  console.log("");
  console.log("=".repeat(70));
  console.log("Benchmark complete!");
  console.log("=".repeat(70));
}

runBenchmarks().catch(console.error);
