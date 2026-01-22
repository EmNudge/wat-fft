/**
 * Radix-4 FFT Benchmark
 * Compares radix-4 Stockham against radix-2 Stockham
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

const WARMUP_ITERATIONS = 100;
const BENCHMARK_DURATION_MS = 2000;
const SIZES = [4, 16, 64, 256, 1024, 4096];

function generateComplexInput(n) {
  const data = new Float64Array(n * 2);
  for (let i = 0; i < n * 2; i++) {
    data[i] = Math.random() * 2 - 1;
  }
  return data;
}

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

  const elapsed = performance.now() - startTime;
  const opsPerSec = (iterations / elapsed) * 1000;

  return { name, iterations, elapsed, opsPerSec };
}

function formatNumber(num) {
  return num.toLocaleString("en-US", { maximumFractionDigits: 0 });
}

async function runBenchmarks() {
  console.log("=".repeat(70));
  console.log("Radix-4 vs Radix-2 Stockham FFT Benchmark");
  console.log("=".repeat(70));
  console.log(`Duration: ${BENCHMARK_DURATION_MS}ms per test`);
  console.log(`Warmup: ${WARMUP_ITERATIONS} iterations`);
  console.log("");

  const radix4 = await loadRadix4FFT();
  const stockham = await loadStockhamFFT();

  console.log("Size     Radix-2 (ops/s)    Radix-4 (ops/s)    Speedup");
  console.log("-".repeat(60));

  for (const size of SIZES) {
    const input = generateComplexInput(size);

    // Radix-2 Stockham
    const stockhamResult = runBenchmark(
      "stockham",
      () => {
        const memory = stockham.memory;
        const data = new Float64Array(memory.buffer, 0, size * 2);
        stockham.precompute_twiddles(size);
        return { data, input, size };
      },
      (ctx) => {
        ctx.data.set(ctx.input);
        stockham.fft_stockham(ctx.size);
      },
    );

    // Radix-4
    const radix4Result = runBenchmark(
      "radix4",
      () => {
        const memory = radix4.memory;
        const data = new Float64Array(memory.buffer, 0, size * 2);
        radix4.precompute_twiddles(size);
        return { data, input, size };
      },
      (ctx) => {
        ctx.data.set(ctx.input);
        radix4.fft_radix4(ctx.size);
      },
    );

    const speedup = radix4Result.opsPerSec / stockhamResult.opsPerSec;
    const speedupStr =
      speedup >= 1
        ? `+${((speedup - 1) * 100).toFixed(1)}%`
        : `${((speedup - 1) * 100).toFixed(1)}%`;

    console.log(
      `N=${String(size).padEnd(5)} ${formatNumber(stockhamResult.opsPerSec).padStart(15)}    ${formatNumber(radix4Result.opsPerSec).padStart(15)}    ${speedupStr.padStart(8)}`,
    );
  }

  console.log("=".repeat(70));
}

runBenchmarks().catch(console.error);
