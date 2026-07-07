/**
 * Browser-based Real FFT Performance Benchmarks using Vitest
 *
 * Compares wat-fft real FFT implementations against competitors.
 * wat-fft contexts are enumerated from the shared surface registry
 * (benchmarks/shared/wat-surfaces.mjs), so every registered real-forward
 * implementation - including the flagship rfft_split - is always measured.
 *
 * Run with: npm run bench:browser
 */

import { describe, bench, afterAll } from "vitest";
import {
  generateRealInput,
  createWatContexts,
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

      // wat-fft implementations: every real-forward registry entry that
      // supports this size (each owns its instance; input staging is
      // charged inside run())
      const watContexts = createWatContexts("real-forward", size, input);

      // Competitor contexts (WASM is pre-loaded)
      const fftJsReal = createFftJsReal(size);
      const kissFFTReal = createKissFFTReal(size);
      const webFFTReal = createWebFFTReal(size);
      const fftwJsReal = createFftwJsReal(size);
      const pffftReal = createPffftReal(size); // null if size < 32

      const contexts: FFTContext[] = [
        ...watContexts,
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

      for (const ctx of watContexts) {
        bench(ctx.name, () => {
          ctx.run();
        });
      }

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
