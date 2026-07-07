/**
 * Browser-based FFT Performance Benchmarks using Vitest
 *
 * Compares wat-fft WASM implementations against popular JS libraries
 * in a real browser environment using Playwright. wat-fft contexts are
 * enumerated from the shared surface registry
 * (benchmarks/shared/wat-surfaces.mjs), so every registered
 * complex-forward implementation is always measured.
 *
 * Run with: npm run bench:browser
 */

import { describe, bench, afterAll } from "vitest";
import {
  generateComplexInput,
  createWatContexts,
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

      // wat-fft implementations: every complex-forward registry entry that
      // supports this size (each owns its instance; input staging is
      // charged inside run())
      const watContexts = createWatContexts("complex-forward", size, input);

      // Competitor contexts (WASM is pre-loaded)
      const fftJs = createFftJs(size);
      const fftJsSimple = createFftJsSimple(size);
      const kissFFT = createKissFFT(size);
      const webFFT = createWebFFT(size);
      const pffft = createPffftComplex(size); // null if size < 32

      const contexts: FFTContext[] = [
        ...watContexts,
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

      for (const ctx of watContexts) {
        bench(ctx.name, () => {
          ctx.run();
        });
      }

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
