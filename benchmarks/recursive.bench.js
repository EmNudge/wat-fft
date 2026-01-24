/**
 * Benchmark: Depth-First Recursive FFT vs other implementations
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
const SIZES = [64, 256, 1024, 2048, 4096, 8192];

// Generate random complex input
function generateInput(n) {
  const input = new Float64Array(n * 2);
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
  console.log("=".repeat(70));
  console.log("Depth-First Recursive FFT Benchmark");
  console.log("=".repeat(70));
  console.log(`Duration: ${BENCHMARK_DURATION_MS}ms per test`);
  console.log(`Warmup: ${WARMUP_ITERATIONS} iterations`);
  console.log("");

  const recursive = await loadWasm("fft_recursive");
  const combined = await loadWasm("fft_combined");
  const radix4 = await loadWasm("fft_radix4");

  for (const n of SIZES) {
    console.log("-".repeat(70));
    console.log(`FFT Size: N=${n}`);
    console.log("-".repeat(70));

    const input = generateInput(n);
    const results = [];

    // 1. Recursive DIF FFT
    const recursiveResult = runBenchmark(
      "Recursive DIF",
      () => {
        const memory = recursive.memory;
        const data = new Float64Array(memory.buffer, 0, n * 2);
        recursive.precompute_twiddles(n);
        return { data, inputBuffer: input };
      },
      (ctx) => {
        ctx.data.set(ctx.inputBuffer);
        recursive.fft(n);
      },
    );
    results.push(recursiveResult);

    // 2. Combined (Radix-4/Radix-2 auto-dispatch)
    const combinedResult = runBenchmark(
      "Combined (auto)",
      () => {
        const memory = combined.memory;
        const data = new Float64Array(memory.buffer, 0, n * 2);
        combined.precompute_twiddles(n);
        return { data, inputBuffer: input };
      },
      (ctx) => {
        ctx.data.set(ctx.inputBuffer);
        combined.fft(n);
      },
    );
    results.push(combinedResult);

    // 3. Pure Radix-4 (for power-of-4 sizes)
    const isPow4 = (n & (n - 1)) === 0 && (n & 0xaaaaaaaa) === 0;
    if (isPow4) {
      const radix4Result = runBenchmark(
        "Radix-4",
        () => {
          const memory = radix4.memory;
          const data = new Float64Array(memory.buffer, 0, n * 2);
          radix4.precompute_twiddles(n);
          return { data, inputBuffer: input };
        },
        (ctx) => {
          ctx.data.set(ctx.inputBuffer);
          radix4.fft_radix4(n);
        },
      );
      results.push(radix4Result);
    }

    // 4. fft.js (JS reference)
    const fftJs = new FFT(n);
    const fftJsResult = runBenchmark(
      "fft.js (JS)",
      () => {
        const fftInput = Array.from(input);
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
    console.log("Implementation              ops/sec      vs fastest    vs Combined");
    console.log("─".repeat(70));
    const fastest = results[0].opsPerSec;
    for (const result of results) {
      const vsFastest = result.opsPerSec / fastest;
      const vsCombined = result.opsPerSec / combinedResult.opsPerSec;
      const vsFastestStr = vsFastest === 1 ? "(fastest)" : `${(vsFastest * 100).toFixed(1)}%`;
      const vsCombinedStr =
        result.name === "Combined (auto)"
          ? "-"
          : `${vsCombined >= 1 ? "+" : ""}${((vsCombined - 1) * 100).toFixed(1)}%`;
      console.log(
        `${result.name.padEnd(22)} ${formatNumber(result.opsPerSec).padStart(10)}    ${vsFastestStr.padStart(10)}    ${vsCombinedStr.padStart(10)}`,
      );
    }
    console.log("");
  }

  console.log("=".repeat(70));
  console.log("Benchmark complete!");
  console.log("=".repeat(70));
}

runBenchmarks().catch(console.error);
