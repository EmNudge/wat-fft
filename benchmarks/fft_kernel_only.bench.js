/**
 * Benchmark: FFT kernel only (excluding format conversion)
 *
 * This measures the raw FFT performance by excluding the
 * interleaved<->split format conversion overhead.
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import PFFFT from "@echogarden/pffft-wasm/simd";
import {
  DEFAULT_CONFIG,
  printResults,
  runBenchmark,
  saveResults,
  seededRandom,
} from "./lib/harness.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Load WASM module (no imports needed)
async function loadWasm(name) {
  const wasmPath = path.join(__dirname, "..", "dist", `${name}.wasm`);
  const wasmBuffer = fs.readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);
  const instance = await WebAssembly.instantiate(wasmModule);
  return instance.exports;
}

const SIZES = [64, 128, 256, 512, 1024, 2048, 4096];

async function runBenchmarks() {
  console.log("=".repeat(75));
  console.log("FFT Kernel-Only Benchmark (excluding format conversion)");
  console.log("=".repeat(75));
  console.log(
    `Samples: ${DEFAULT_CONFIG.samples} x ${DEFAULT_CONFIG.sampleMs}ms per test (median reported)`,
  );
  console.log("");

  const wasmSplit = await loadWasm("fft_split_native_f32");
  const pffft = await PFFFT();

  // PFFFT enum: { PFFFT_REAL=0, PFFFT_COMPLEX=1 }
  const PFFFT_COMPLEX = 1;
  const PFFFT_FORWARD = 0;

  // Constants for split format memory layout (from fft_split_native_f32)
  const SPLIT_RE_OFFSET = 0; // REAL_A_OFFSET
  const SPLIT_IM_OFFSET = 0x8000; // IMAG_A_OFFSET (32768)

  const sizeGroups = [];

  for (const n of SIZES) {
    console.log("-".repeat(75));
    console.log(`FFT Size: N=${n}`);
    console.log("-".repeat(75));

    const results = [];

    // 1. Split-format FFT kernel only (native split format, no conversion)
    const splitResult = runBenchmark(
      "wat-fft split (kernel only)",
      () => {
        const memory = wasmSplit.memory;
        const reBuffer = new Float32Array(memory.buffer, SPLIT_RE_OFFSET, n);
        const imBuffer = new Float32Array(memory.buffer, SPLIT_IM_OFFSET, n);

        // Initialize split buffers (deterministic input)
        const rand = seededRandom(n);
        for (let i = 0; i < n; i++) {
          reBuffer[i] = rand();
          imBuffer[i] = rand();
        }

        wasmSplit.precompute_twiddles_split(n);
        return { memory, n };
      },
      (ctx) => {
        wasmSplit.fft_split(ctx.n);
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
        // Initialize with deterministic input
        const rand = seededRandom(n);
        for (let i = 0; i < n * 2; i++) {
          inputView[i] = rand();
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
        const rand = seededRandom(n);
        for (let i = 0; i < n * 2; i++) {
          inputView[i] = rand();
        }
        return { setup, inputPtr, outputPtr };
      },
      (ctx) => {
        pffft._pffft_transform_ordered(ctx.setup, ctx.inputPtr, ctx.outputPtr, 0, PFFFT_FORWARD);
      },
    );
    results.push(pffftOrderedResult);

    printResults(results);
    sizeGroups.push({ size: n, results });
    console.log("");
  }

  console.log("=".repeat(75));
  console.log("Benchmark complete!");
  console.log("=".repeat(75));

  saveResults("fft-kernel-only", sizeGroups);
}

runBenchmarks().catch(console.error);
