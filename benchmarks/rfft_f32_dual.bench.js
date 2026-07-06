/**
 * f32 Dual-Complex Real FFT Benchmark
 *
 * Compares the f32 rfft against fftw-js (f32) and pffft-wasm SIMD (f32)
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import fftwJs from "fftw-js";
import PFFFT from "@echogarden/pffft-wasm/simd";
import {
  DEFAULT_CONFIG,
  formatNumber,
  printResults,
  runBenchmark,
  saveResults,
  seededRandom,
} from "./lib/harness.js";

const PFFFT_REAL = 0;
const PFFFT_FORWARD = 0;

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

async function loadWasm(name) {
  const wasmPath = path.join(__dirname, "..", "dist", `${name}.wasm`);
  const wasmBuffer = fs.readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);
  const instance = await WebAssembly.instantiate(wasmModule, {});
  return instance.exports;
}

const SIZES = [64, 128, 256, 512, 1024, 2048, 4096];

function generateRealInput(n) {
  const rand = seededRandom(n);
  const data = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    data[i] = rand();
  }
  return data;
}

async function runBenchmarks() {
  console.log("=".repeat(70));
  console.log("f32 Real FFT Benchmark");
  console.log("=".repeat(70));
  console.log(
    `Samples: ${DEFAULT_CONFIG.samples} x ${DEFAULT_CONFIG.sampleMs}ms per test (median reported)`,
  );
  console.log("");

  const wasmExports = await loadWasm("fft_real_f32_dual");
  const splitExports = await loadWasm("fft_split_native_f32");
  const pffft = await PFFFT();

  const summary = [];
  const sizeGroups = [];

  for (const size of SIZES) {
    console.log("-".repeat(70));
    console.log(`Real FFT Size: N=${size}`);
    console.log("-".repeat(70));

    const input = generateRealInput(size);
    const results = [];

    // 1. f32 RFFT
    const wasmResult = runBenchmark(
      "wat-fft (f32)",
      () => {
        const memory = wasmExports.memory;
        const data = new Float32Array(memory.buffer, 0, size);
        wasmExports.precompute_rfft_twiddles(size);
        return { data, inputBuffer: input };
      },
      (ctx) => {
        ctx.data.set(ctx.inputBuffer);
        wasmExports.rfft(size);
      },
    );
    results.push(wasmResult);

    // 2. f32 split-core RFFT (Experiment 59)
    const splitResult = runBenchmark(
      "wat-fft split (f32)",
      () => {
        const memory = splitExports.memory;
        const data = new Float32Array(memory.buffer, 0, size);
        splitExports.precompute_rfft_twiddles_split(size);
        return { data, inputBuffer: input };
      },
      (ctx) => {
        ctx.data.set(ctx.inputBuffer);
        splitExports.rfft_split(size);
      },
    );
    results.push(splitResult);

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

    // 3. pffft-wasm SIMD (f32)
    const pffftResult = runBenchmark(
      "pffft-wasm SIMD (f32)",
      () => {
        const setup = pffft._pffft_new_setup(size, PFFFT_REAL);
        const inputPtr = pffft._pffft_aligned_malloc(size * 4);
        const outputPtr = pffft._pffft_aligned_malloc(size * 4);
        return { setup, inputPtr, outputPtr, inputData: input };
      },
      (ctx) => {
        new Float32Array(pffft.HEAPF32.buffer, ctx.inputPtr, size).set(ctx.inputData);
        pffft._pffft_transform_ordered(ctx.setup, ctx.inputPtr, ctx.outputPtr, 0, PFFFT_FORWARD);
      },
      (ctx) => {
        pffft._pffft_aligned_free(ctx.inputPtr);
        pffft._pffft_aligned_free(ctx.outputPtr);
        pffft._pffft_destroy_setup(ctx.setup);
      },
    );
    results.push(pffftResult);

    // Calculate speedup (split-core rfft, the flagship, vs competitors)
    const vsFftw = splitResult.opsPerSec / fftwResult.opsPerSec;
    const vsPffft = splitResult.opsPerSec / pffftResult.opsPerSec;

    printResults(results);
    sizeGroups.push({ size, results });
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

  saveResults("rfft-f32", sizeGroups);
}

runBenchmarks().catch(console.error);
