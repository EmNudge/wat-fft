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
  createKissFFTReal,
  createWebFFTReal,
  createFftwJsReal,
  createPffftReal,
  type FFTContext,
} from "./fft-loader";

// Benchmark configuration - matches Node.js benchmarks for parity
// Start at 32 (kissfft/webfft minimum size for real FFT)
const SIZES = [32, 64, 128, 256, 512, 1024, 2048, 4096];

describe("Real FFT Benchmarks", () => {
  for (const size of SIZES) {
    describe(`N=${size}`, () => {
      // Generate input data
      const input = generateRealInput(size);

      // Create all contexts synchronously (WASM is pre-loaded)
      const watF64 = createWatRfftF64(size);
      const watF32 = createWatRfftF32(size);
      const fftJsReal = createFftJsReal(size);
      const kissFFTReal = createKissFFTReal(size);
      const webFFTReal = createWebFFTReal(size);
      const fftwJsReal = createFftwJsReal(size);
      const pffftReal = createPffftReal(size); // null if size < 32

      const contexts: FFTContext[] = [
        watF64,
        watF32,
        fftJsReal,
        kissFFTReal,
        webFFTReal,
        fftwJsReal,
        ...(pffftReal ? [pffftReal] : []),
      ];

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

      bench("kissfft-js (real)", () => {
        kissFFTReal.inputBuffer.set(input.real32);
        kissFFTReal.run();
      });

      bench("webfft (real)", () => {
        webFFTReal.inputBuffer.set(input.real32);
        webFFTReal.run();
      });

      bench("fftw-js", () => {
        fftwJsReal.inputBuffer.set(input.real32);
        fftwJsReal.run();
      });

      // pffft-wasm only works for size >= 32 (always true in this loop)
      if (pffftReal) {
        bench("pffft-wasm (real)", () => {
          pffftReal.inputBuffer.set(input.real32);
          pffftReal.run();
        });
      }
    });
  }
});
