/**
 * FFT Performance Benchmarks
 *
 * Compares our WAT/WASM FFT implementation against popular JS libraries:
 * - fft.js (indutny) - Fastest pure JS, Radix-4 implementation
 * - fft-js - Simple Cooley-Tukey implementation
 * - kissfft-js - Emscripten port of Kiss FFT
 * - webfft - Meta-library with multiple FFT implementations
 * - pffft-wasm - PFFFT compiled to WASM with SIMD support
 */

import FFT from "fft.js";
import * as fftJs from "fft-js";
import kissfft from "kissfft-js";
import webfft from "webfft";
import PFFFT from "@echogarden/pffft-wasm/simd";
import { DEFAULT_CONFIG, printResults, runBenchmark, saveResults } from "./lib/harness.js";
import { createWatBenchContexts, generateComplexInputs } from "./lib/wat-contexts.js";

// Include both power-of-4 (16, 64, 256, 1024, 4096) and non-power-of-4 (32, 128, 512, 2048)
const SIZES = [16, 32, 64, 128, 256, 512, 1024, 2048, 4096];

async function runBenchmarks() {
  console.log("=".repeat(70));
  console.log("FFT Performance Benchmarks");
  console.log("=".repeat(70));
  console.log(
    `Samples: ${DEFAULT_CONFIG.samples} x ${DEFAULT_CONFIG.sampleMs}ms per test (median reported)`,
  );
  console.log("");

  const pffft = await PFFFT();

  const sizeGroups = [];

  for (const size of SIZES) {
    console.log("-".repeat(70));
    console.log(`FFT Size: N=${size}`);
    console.log("-".repeat(70));

    const input = generateComplexInputs(size);
    const results = [];

    // wat-fft implementations: every complex-forward entry in the registry
    // (f64 combined, f32 dual-complex, f32 split - flagship)
    const watContexts = await createWatBenchContexts("complex-forward", size, { input });
    for (const wat of watContexts) {
      results.push(runBenchmark(wat.name, wat.setup, wat.bench));
    }

    // fft.js (indutny)
    const fftJsResult = runBenchmark(
      "fft.js (Radix-4)",
      () => {
        const fft = new FFT(size);
        const out = fft.createComplexArray();
        const complexInput = fft.createComplexArray();
        for (let i = 0; i < size; i++) {
          complexInput[i * 2] = input.re64[i];
          complexInput[i * 2 + 1] = input.im64[i];
        }
        return { fft, complexInput, out };
      },
      (ctx) => {
        ctx.fft.transform(ctx.out, ctx.complexInput);
      },
    );
    results.push(fftJsResult);

    // fft-js
    const fftJsSimpleResult = runBenchmark(
      "fft-js (Cooley-Tukey)",
      () => {
        const signal = [];
        for (let i = 0; i < size; i++) {
          signal.push([input.re64[i], input.im64[i]]);
        }
        return { signal };
      },
      (ctx) => {
        fftJs.fft(ctx.signal);
      },
    );
    results.push(fftJsSimpleResult);

    // kissfft-js
    const kissfftResult = runBenchmark(
      "kissfft-js",
      () => {
        const fft = new kissfft.FFT(size);
        // kissfft expects interleaved complex input
        const complexInput = new Float64Array(size * 2);
        for (let i = 0; i < size; i++) {
          complexInput[i * 2] = input.re64[i];
          complexInput[i * 2 + 1] = input.im64[i];
        }
        return { fft, complexInput };
      },
      (ctx) => {
        ctx.fft.forward(ctx.complexInput);
      },
      (ctx) => {
        ctx.fft.dispose();
      },
    );
    results.push(kissfftResult);

    // webfft (meta-library using kissWasm by default)
    const webfftResult = runBenchmark(
      "webfft (f32)",
      () => {
        const fft = new webfft(size);
        fft.setSubLibrary("kissWasm");
        const complexInput = new Float32Array(size * 2);
        for (let i = 0; i < size; i++) {
          complexInput[i * 2] = input.re64[i];
          complexInput[i * 2 + 1] = input.im64[i];
        }
        return { fft, complexInput };
      },
      (ctx) => {
        ctx.fft.fft(ctx.complexInput);
      },
      (ctx) => {
        ctx.fft.dispose();
      },
    );
    results.push(webfftResult);

    // pffft-wasm (PFFFT with SIMD support)
    // PFFFT enum: { PFFFT_REAL=0, PFFFT_COMPLEX=1 }
    const PFFFT_COMPLEX = 1;
    const PFFFT_FORWARD = 0;
    const pffftResult = runBenchmark(
      "pffft-wasm (f32)",
      () => {
        const setup = pffft._pffft_new_setup(size, PFFFT_COMPLEX);
        const inputPtr = pffft._pffft_aligned_malloc(size * 2 * 4);
        const outputPtr = pffft._pffft_aligned_malloc(size * 2 * 4);
        const inputView = new Float32Array(pffft.HEAPF32.buffer, inputPtr, size * 2);
        const inputBuffer = new Float32Array(size * 2);
        for (let i = 0; i < size; i++) {
          inputBuffer[i * 2] = input.re64[i];
          inputBuffer[i * 2 + 1] = input.im64[i];
        }
        return { setup, inputPtr, outputPtr, inputView, inputBuffer };
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

    printResults(results);
    sizeGroups.push({ size, results });
    console.log("");
  }

  console.log("=".repeat(70));
  console.log("Benchmark complete!");
  console.log("");
  console.log("Notes:");
  console.log("- wat-fft (f64): SIMD-optimized WASM with auto radix-2/4 dispatch");
  console.log("- wat-fft (f32): Dual-complex SIMD optimized (f32x4)");
  console.log("- wat-fft (f32 split): Split-format SIMD (4 complex per op)");
  console.log("- fft.js: Highly optimized Radix-4 JS (Fedor Indutny)");
  console.log("- kissfft-js: Emscripten port of Kiss FFT");
  console.log("- fft-js: Simple Cooley-Tukey JS (educational)");
  console.log("- webfft: Meta-library with kissWasm backend (f32)");
  console.log("- pffft-wasm: PFFFT compiled to WASM with SIMD (f32)");
  console.log("=".repeat(70));

  saveResults("fft", sizeGroups);
}

runBenchmarks().catch(console.error);
