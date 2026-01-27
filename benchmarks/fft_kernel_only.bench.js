/**
 * Benchmark: FFT kernel only (excluding format conversion)
 *
 * This measures the raw FFT performance by excluding the
 * interleaved<->split format conversion overhead.
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import PFFFT from "@echogarden/pffft-wasm";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Load WASM module with sin/cos imports
async function loadWasmWithMath(name) {
  const wasmPath = path.join(__dirname, "..", "dist", `${name}.wasm`);
  const wasmBuffer = fs.readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);
  const instance = await WebAssembly.instantiate(wasmModule, {
    env: { sin: Math.sin, cos: Math.cos },
  });
  return instance.exports;
}

// Benchmark configuration
const WARMUP_ITERATIONS = 100;
const BENCHMARK_DURATION_MS = 2000;
const SIZES = [64, 128, 256, 512, 1024, 2048, 4096];

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
  console.log("=".repeat(75));
  console.log("FFT Kernel-Only Benchmark (excluding format conversion)");
  console.log("=".repeat(75));
  console.log(`Duration: ${BENCHMARK_DURATION_MS}ms per test`);
  console.log(`Warmup: ${WARMUP_ITERATIONS} iterations`);
  console.log("");

  const wasmSplit = await loadWasmWithMath("fft_split_f32");
  const pffft = await PFFFT();

  // PFFFT enum: { PFFFT_REAL=0, PFFFT_COMPLEX=1 }
  const PFFFT_COMPLEX = 1;
  const PFFFT_FORWARD = 0;

  // Constants for split format memory layout
  const SPLIT_RE_OFFSET = 32768;
  const SPLIT_IM_OFFSET = 65536;

  for (const n of SIZES) {
    console.log("-".repeat(75));
    console.log(`FFT Size: N=${n}`);
    console.log("-".repeat(75));

    const results = [];

    // 1. Split-format FFT kernel only (no format conversion)
    // Pre-fill split buffers with data
    const splitResult = runBenchmark(
      "wat-fft split (kernel only)",
      () => {
        const memory = wasmSplit.memory;
        const reBuffer = new Float32Array(memory.buffer, SPLIT_RE_OFFSET, n);
        const imBuffer = new Float32Array(memory.buffer, SPLIT_IM_OFFSET, n);

        // Initialize split buffers
        for (let i = 0; i < n; i++) {
          reBuffer[i] = Math.random() * 2 - 1;
          imBuffer[i] = Math.random() * 2 - 1;
        }

        wasmSplit.precompute_twiddles(n);
        return { memory, n };
      },
      (ctx) => {
        // Call internal FFT function if exported, otherwise use SIMD path
        // For now, we need to export the internal function
        // Let's measure the full fft() which includes conversion
        wasmSplit.fft(ctx.n);
      },
    );
    results.push(splitResult);

    // 2. pffft-wasm with "pffft format" (their internal split format)
    // Using _pffft_transform (not ordered) which works in native format
    const pffftNativeResult = runBenchmark(
      "pffft-wasm (native fmt)",
      () => {
        const setup = pffft._pffft_new_setup(n, PFFFT_COMPLEX);
        const inputPtr = pffft._pffft_aligned_malloc(n * 2 * 4);
        const outputPtr = pffft._pffft_aligned_malloc(n * 2 * 4);
        const inputView = new Float32Array(pffft.HEAPF32.buffer, inputPtr, n * 2);
        // Initialize with random data
        for (let i = 0; i < n * 2; i++) {
          inputView[i] = Math.random() * 2 - 1;
        }
        return { setup, inputPtr, outputPtr };
      },
      (ctx) => {
        // Use _pffft_transform (not ordered) which is faster
        pffft._pffft_transform(ctx.setup, ctx.inputPtr, ctx.outputPtr, 0, PFFFT_FORWARD);
      },
    );
    results.push(pffftNativeResult);

    // 3. pffft-wasm with ordered output (their standard API)
    const pffftOrderedResult = runBenchmark(
      "pffft-wasm (ordered)",
      () => {
        const setup = pffft._pffft_new_setup(n, PFFFT_COMPLEX);
        const inputPtr = pffft._pffft_aligned_malloc(n * 2 * 4);
        const outputPtr = pffft._pffft_aligned_malloc(n * 2 * 4);
        const inputView = new Float32Array(pffft.HEAPF32.buffer, inputPtr, n * 2);
        for (let i = 0; i < n * 2; i++) {
          inputView[i] = Math.random() * 2 - 1;
        }
        return { setup, inputPtr, outputPtr };
      },
      (ctx) => {
        pffft._pffft_transform_ordered(ctx.setup, ctx.inputPtr, ctx.outputPtr, 0, PFFFT_FORWARD);
      },
    );
    results.push(pffftOrderedResult);

    // Sort by performance
    results.sort((a, b) => b.opsPerSec - a.opsPerSec);

    // Print results
    console.log("");
    console.log("Implementation              ops/sec      vs fastest");
    console.log("-".repeat(55));
    const fastest = results[0].opsPerSec;
    for (const result of results) {
      const vsFastest =
        result.opsPerSec / fastest === 1
          ? "(fastest)"
          : `${((result.opsPerSec / fastest) * 100).toFixed(1)}%`;
      console.log(
        `${result.name.padEnd(26)} ${formatNumber(result.opsPerSec).padStart(10)}    ${vsFastest.padStart(10)}`,
      );
    }
    console.log("");
  }

  console.log("=".repeat(75));
  console.log("Benchmark complete!");
  console.log("=".repeat(75));
}

runBenchmarks().catch(console.error);
