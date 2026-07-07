/**
 * Real FFT Performance Benchmarks
 *
 * Compares our WAT/WASM Real FFT implementation against:
 * - fftw-js - Emscripten port of FFTW
 * - kissfft-js - Emscripten port of Kiss FFT
 * - webfft - Meta-library with multiple FFT implementations
 * - pffft-wasm - PFFFT compiled to WASM with SIMD support
 *
 * Note: fftw-js, kissfft-js, webfft, and pffft use Float32 (single precision),
 * while our implementation uses Float64 (double precision).
 */

import fftwJs from "fftw-js";
import kissfft from "kissfft-js";
import webfft from "webfft";
import PFFFT from "@echogarden/pffft-wasm/simd";
import { DEFAULT_CONFIG, printResults, runBenchmark, saveResults } from "./lib/harness.js";
import { createWatBenchContexts, generateRealInputs } from "./lib/wat-contexts.js";

// Test sizes: include both radix-4 eligible (N/2 is power-of-4) and radix-2 sizes
// Radix-4 eligible: N=8,32,128,512,2048 (N/2=4,16,64,256,1024)
// Radix-2 only: N=16,64,256,1024,4096 (N/2=8,32,128,512,2048)
const SIZES = [8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096];

async function runBenchmarks() {
  console.log("=".repeat(70));
  console.log("Real FFT Performance Benchmarks");
  console.log("=".repeat(70));
  console.log(
    `Samples: ${DEFAULT_CONFIG.samples} x ${DEFAULT_CONFIG.sampleMs}ms per test (median reported)`,
  );
  console.log("");
  console.log("Note: fftw-js/webfft/pffft use Float32 (single precision)");
  console.log("      wat-fft uses Float64 (double precision)");
  console.log("");

  const pffft = await PFFFT();

  const sizeGroups = [];

  for (const size of SIZES) {
    console.log("-".repeat(70));
    console.log(`Real FFT Size: N=${size}`);
    console.log("-".repeat(70));

    const input = generateRealInputs(size);
    const results = [];

    // wat-fft implementations: every f64 real-forward entry in the registry
    const watContexts = await createWatBenchContexts("real-forward", size, {
      precisions: ["f64"],
      input,
    });
    let combinedResult;
    for (const wat of watContexts) {
      const result = runBenchmark(wat.name, wat.setup, wat.bench);
      results.push(result);
      if (wat.entry.flagship) combinedResult = result;
    }

    // 2. fftw-js (single precision)
    const fftwResult = runBenchmark(
      "fftw-js (f32)",
      () => {
        const fft = new fftwJs.FFT(size);
        return { fft, inputData: input.real32 };
      },
      (ctx) => {
        ctx.fft.forward(ctx.inputData);
      },
      (ctx) => {
        ctx.fft.dispose();
      },
    );
    results.push(fftwResult);

    // 3. kissfft-js (single precision)
    const kissfftResult = runBenchmark(
      "kissfft-js (f32)",
      () => {
        const fft = new kissfft.FFTR(size);
        return { fft, inputData: input.real32 };
      },
      (ctx) => {
        ctx.fft.forward(ctx.inputData);
      },
      (ctx) => {
        ctx.fft.dispose();
      },
    );
    results.push(kissfftResult);

    // 4. webfft (meta-library using kissWasm)
    const webfftResult = runBenchmark(
      "webfft (f32)",
      () => {
        const fft = new webfft(size);
        fft.setSubLibrary("kissWasm");
        return { fft, inputData: input.real32 };
      },
      (ctx) => {
        ctx.fft.fftr(ctx.inputData);
      },
      (ctx) => {
        ctx.fft.dispose();
      },
    );
    results.push(webfftResult);

    // 5. pffft-wasm (PFFFT with SIMD support) - requires size >= 32
    // PFFFT enum: { PFFFT_REAL=0, PFFFT_COMPLEX=1 }
    if (size >= 32) {
      const PFFFT_REAL = 0;
      const PFFFT_FORWARD = 0;
      const pffftResult = runBenchmark(
        "pffft-wasm (f32)",
        () => {
          const setup = pffft._pffft_new_setup(size, PFFFT_REAL);
          const inputPtr = pffft._pffft_aligned_malloc(size * 4);
          const outputPtr = pffft._pffft_aligned_malloc(size * 4);
          const inputView = new Float32Array(pffft.HEAPF32.buffer, inputPtr, size);
          return { setup, inputPtr, outputPtr, inputView, inputBuffer: input.real32 };
        },
        (ctx) => {
          // Stage input per iteration, same as every other context
          ctx.inputView.set(ctx.inputBuffer);
          pffft._pffft_transform_ordered(ctx.setup, ctx.inputPtr, ctx.outputPtr, 0, PFFFT_FORWARD);
        },
        (ctx) => {
          pffft._pffft_aligned_free(ctx.inputPtr);
          pffft._pffft_aligned_free(ctx.outputPtr);
          pffft._pffft_destroy_setup(ctx.setup);
        },
      );
      results.push(pffftResult);
    }

    // Calculate speedup of wat-fft Combined vs fftw-js
    const speedup = combinedResult.opsPerSec / fftwResult.opsPerSec;
    const speedupStr =
      speedup >= 1
        ? `+${((speedup - 1) * 100).toFixed(1)}%`
        : `${((speedup - 1) * 100).toFixed(1)}%`;

    printResults(results);
    sizeGroups.push({ size, results });
    console.log("");
    console.log(`wat-fft Combined vs fftw-js: ${speedupStr}`);
    console.log("");
  }

  console.log("=".repeat(70));
  console.log("Benchmark complete!");
  console.log("=".repeat(70));

  saveResults("rfft", sizeGroups);
}

runBenchmarks().catch(console.error);
