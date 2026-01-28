/**
 * Browser-based FFT Performance Benchmarks using Vitest
 *
 * Compares wat-fft WASM implementations against popular JS libraries
 * in a real browser environment using Playwright.
 *
 * Run with: npm run bench:browser
 */

import { describe, bench, afterAll } from "vitest";
import {
  generateComplexInput,
  createWatFftF64,
  createWatFftF32,
  createWatFftSplit,
  createFftJs,
  createFftJsSimple,
  createKissFFT,
  createWebFFT,
  createPffftComplex,
  type FFTContext,
} from "./fft-loader";

// Benchmark configuration - matches Node.js benchmarks for parity
const SIZES = [16, 32, 64, 128, 256, 512, 1024, 2048, 4096];

describe("Complex FFT Benchmarks", () => {
  for (const size of SIZES) {
    describe(`N=${size}`, () => {
      // Generate input data
      const input = generateComplexInput(size);

      // Create all contexts synchronously (WASM is pre-loaded)
      const watF64 = createWatFftF64(size);
      const watF32 = createWatFftF32(size);
      const watSplit = createWatFftSplit(size);
      const fftJs = createFftJs(size);
      const fftJsSimple = createFftJsSimple(size);
      const kissFFT = createKissFFT(size);
      const webFFT = createWebFFT(size);
      const pffft = createPffftComplex(size); // null if size < 32

      const contexts: FFTContext[] = [
        watF64,
        watF32,
        watSplit,
        fftJs,
        fftJsSimple,
        kissFFT,
        webFFT,
        ...(pffft ? [pffft] : []),
      ];

      afterAll(() => {
        for (const ctx of contexts) {
          ctx.dispose?.();
        }
      });

      bench("wat-fft (f64)", () => {
        watF64.inputBuffer.set(input.interleaved64);
        watF64.run();
      });

      bench("wat-fft (f32)", () => {
        watF32.inputBuffer.set(input.interleaved32);
        watF32.run();
      });

      bench("wat-fft (f32 split)", () => {
        watSplit.inputBuffer.set(input.interleaved32);
        watSplit.run();
      });

      bench("fft.js", () => {
        fftJs.inputBuffer.set(input.interleaved64);
        fftJs.run();
      });

      bench("fft-js", () => {
        fftJsSimple.inputBuffer.set(input.interleaved64);
        fftJsSimple.run();
      });

      bench("kissfft-js", () => {
        kissFFT.inputBuffer.set(input.interleaved64);
        kissFFT.run();
      });

      bench("webfft", () => {
        webFFT.inputBuffer.set(input.interleaved32);
        webFFT.run();
      });

      // pffft-wasm only works for size >= 32
      if (pffft) {
        bench("pffft-wasm", () => {
          pffft.inputBuffer.set(input.interleaved32);
          pffft.run();
        });
      }
    });
  }
});
