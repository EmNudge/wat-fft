/**
 * f32 Dual-Complex Inverse Real FFT Benchmark
 *
 * Compares the f32 irfft against fftw-js (f32) inverse
 */

import fftwJs from "fftw-js";
import PFFFT from "@echogarden/pffft-wasm/simd";
import {
  DEFAULT_CONFIG,
  formatNumber,
  printResults,
  runBenchmark,
  saveResults,
} from "./lib/harness.js";
import { createWatBenchContexts, generateRealInputs } from "./lib/wat-contexts.js";

const PFFFT_REAL = 0;
const PFFFT_BACKWARD = 1;

const SIZES = [64, 128, 256, 512, 1024, 2048, 4096];

async function runBenchmarks() {
  console.log("=".repeat(70));
  console.log("f32 Inverse Real FFT Benchmark");
  console.log("=".repeat(70));
  console.log(
    `Samples: ${DEFAULT_CONFIG.samples} x ${DEFAULT_CONFIG.sampleMs}ms per test (median reported)`,
  );
  console.log("");

  const pffft = await PFFFT();

  const summary = [];
  const sizeGroups = [];

  for (const size of SIZES) {
    console.log("-".repeat(70));
    console.log(`Inverse Real FFT Size: N=${size}`);
    console.log("-".repeat(70));

    const input = generateRealInputs(size);
    const results = [];

    // wat-fft implementations: every f32 real-inverse entry in the registry
    // (each setup produces its spectrum input via the module's own forward)
    const watContexts = await createWatBenchContexts("real-inverse", size, {
      precisions: ["f32"],
      input,
    });
    let splitResult;
    for (const wat of watContexts) {
      const result = runBenchmark(wat.name, wat.setup, wat.bench);
      results.push(result);
      if (wat.entry.flagship) splitResult = result;
    }

    // 3. fftw-js (f32)
    const fftwResult = runBenchmark(
      "fftw-js (f32)",
      () => {
        const fft = new fftwJs.FFT(size);
        const spectrum = fft.forward(input.real32);
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
        new Float32Array(pffft.HEAPF32.buffer, inputPtr, size).set(input.real32);
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

    // Calculate speedup (best wat-fft implementation: the split core)
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

  saveResults("irfft-f32", sizeGroups);
}

runBenchmarks().catch(console.error);
