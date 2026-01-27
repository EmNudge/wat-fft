/**
 * Browser-based Real FFT Performance Benchmarks using Vitest
 *
 * Compares wat-fft real FFT implementations against competitors.
 *
 * Run with: npm run bench:browser
 */

import { describe, bench, afterAll } from "vitest";
import {
  generateRealInput,
  createWatRfftF64,
  createWatRfftF32,
  createFftJsReal,
  type FFTContext,
} from "./fft-loader";

// Benchmark configuration
const SIZES = [64, 256, 1024, 4096];

describe("Real FFT Benchmarks", () => {
  for (const size of SIZES) {
    describe(`N=${size}`, () => {
      // Generate input data
      const input = generateRealInput(size);

      // Create all contexts synchronously (WASM is pre-loaded)
      const watF64 = createWatRfftF64(size);
      const watF32 = createWatRfftF32(size);
      const fftJsReal = createFftJsReal(size);

      const contexts: FFTContext[] = [watF64, watF32, fftJsReal];

      afterAll(() => {
        for (const ctx of contexts) {
          ctx.dispose?.();
        }
      });

      bench("wat-rfft (f64)", () => {
        watF64.inputBuffer.set(input.real64);
        watF64.run();
      });

      bench("wat-rfft (f32)", () => {
        watF32.inputBuffer.set(input.real32);
        watF32.run();
      });

      bench("fft.js (real)", () => {
        fftJsReal.inputBuffer.set(input.real64);
        fftJsReal.run();
      });
    });
  }
});
