/**
 * Browser-compatible FFT module loader for Vitest benchmarks
 *
 * Uses top-level await for async initialization to work with vitest bench.
 */

// Import WASM URLs using Vite's ?url suffix
// @ts-ignore - Vite handles these imports
import fftCombinedUrl from "../../dist/fft_combined.wasm?url";
// @ts-ignore
import fftF32Url from "../../dist/fft_stockham_f32_dual.wasm?url";
// @ts-ignore
import fftSplitUrl from "../../dist/fft_split_native_f32.wasm?url";
// @ts-ignore
import rfftCombinedUrl from "../../dist/fft_real_combined.wasm?url";
// @ts-ignore
import rfftF32Url from "../../dist/fft_real_f32_dual.wasm?url";
// @ts-ignore - pffft WASM URL for browser loading (relative path to node_modules)
import pffftWasmUrl from "../../node_modules/@echogarden/pffft-wasm/dist/simd/pffft.wasm?url";

// Import competitor libraries
import FFT from "fft.js";
import * as fftJs from "fft-js";
import kissfft from "kissfft-js";
import webfft from "webfft";
// @ts-ignore - pffft-wasm SIMD glue (the bare import resolves to the non-SIMD build)
import PFFFT from "@echogarden/pffft-wasm/simd";
// @ts-ignore - fftw-js is CommonJS but Vite can handle it
import fftwJs from "fftw-js";

// Shared wat-fft surface registry: the single source of truth for which
// wat implementations must be benchmarked on each surface.
// @ts-ignore - plain .mjs module without type declarations
import { watEntriesFor } from "../shared/wat-surfaces.mjs";

// Types
export interface FFTContext {
  name: string;
  size: number;
  isReal: boolean;
  isF32: boolean;
  inputBuffer: Float32Array | Float64Array;
  run: () => void;
  dispose?: () => void;
}

// dist wasm file name (as used in the surface registry) -> Vite URL
const WAT_WASM_URLS: Record<string, string> = {
  "fft_combined.wasm": fftCombinedUrl,
  "fft_stockham_f32_dual.wasm": fftF32Url,
  "fft_split_native_f32.wasm": fftSplitUrl,
  "fft_real_combined.wasm": rfftCombinedUrl,
  "fft_real_f32_dual.wasm": rfftF32Url,
};

/**
 * Fetch and compile a WASM module by URL (instantiation happens per
 * benchmark context, synchronously, so every context gets its own memory
 * and twiddle tables - a shared instance would let one size group's
 * precompute clobber another's).
 */
async function compileWasmByUrl(url: string): Promise<WebAssembly.Module> {
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`Failed to load WASM: ${response.statusText}`);
  }
  return WebAssembly.compile(await response.arrayBuffer());
}

// Pre-compile all wat-fft modules at module initialization time
export const watModules: Record<string, WebAssembly.Module> = Object.fromEntries(
  await Promise.all(
    Object.entries(WAT_WASM_URLS).map(async ([file, url]) => [file, await compileWasmByUrl(url)]),
  ),
);

// Initialize pffft-wasm with custom locateFile to work in browser
// eslint-disable-next-line @typescript-eslint/no-explicit-any
export const pffft: any = await PFFFT({
  locateFile: (path: string) => {
    if (path.endsWith(".wasm")) {
      return pffftWasmUrl;
    }
    return path;
  },
});

// pffft constants
const PFFFT_COMPLEX = 1; // NOT 0! (0 = PFFFT_REAL)
const PFFFT_REAL = 0;
const PFFFT_FORWARD = 0;

/**
 * Generate random complex input data
 */
export function generateComplexInput(n: number): {
  interleaved64: Float64Array;
  interleaved32: Float32Array;
  planar32: Float32Array;
} {
  const interleaved64 = new Float64Array(n * 2);
  const interleaved32 = new Float32Array(n * 2);
  // Split layout in one buffer: re in [0, n), im in [n, 2n)
  const planar32 = new Float32Array(n * 2);

  for (let i = 0; i < n; i++) {
    const r = Math.random() * 2 - 1;
    const im = Math.random() * 2 - 1;
    interleaved64[i * 2] = r;
    interleaved64[i * 2 + 1] = im;
    interleaved32[i * 2] = r;
    interleaved32[i * 2 + 1] = im;
    planar32[i] = r;
    planar32[n + i] = im;
  }

  return { interleaved64, interleaved32, planar32 };
}

/**
 * Generate random real input data
 */
export function generateRealInput(n: number): {
  real64: Float64Array;
  real32: Float32Array;
} {
  const real64 = new Float64Array(n);
  const real32 = new Float32Array(n);

  for (let i = 0; i < n; i++) {
    const r = Math.random() * 2 - 1;
    real64[i] = r;
    real32[i] = r;
  }

  return { real64, real32 };
}

// ============================================================================
// wat-fft context creators, driven by the shared surface registry
// ============================================================================

interface WatSurfaceEntry {
  name: string;
  module: string;
  precision: "f32" | "f64";
  layout: "complex-interleaved" | "complex-split" | "real-packed" | "real-spectrum";
  precompute: string;
  run: string;
  spectrumVia?: string;
  flagship?: boolean;
}

export interface WatInput {
  interleaved64?: Float64Array;
  interleaved32?: Float32Array;
  planar32?: Float32Array;
  real64?: Float64Array;
  real32?: Float32Array;
}

function globalValue(g: number | WebAssembly.Global): number {
  return typeof g === "number" ? g : (g.value as number);
}

/**
 * Build one FFTContext per registry entry of a surface that supports
 * `size`. Each context owns a fresh module instance (own memory + twiddle
 * tables) and stages its bound input inside run(), so every implementation
 * is charged one input copy per iteration like the competitor contexts.
 */
export function createWatContexts(surfaceId: string, size: number, input: WatInput): FFTContext[] {
  const entries = watEntriesFor(surfaceId, { size }) as WatSurfaceEntry[];

  return entries.map((entry) => {
    const module = watModules[entry.module];
    if (!module) {
      throw new Error(`No preloaded wasm for ${entry.module} (add it to WAT_WASM_URLS)`);
    }
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const exports = new WebAssembly.Instance(module).exports as any;
    exports[entry.precompute](size);
    const FloatArray = entry.precision === "f32" ? Float32Array : Float64Array;

    let inputBuffer: Float32Array | Float64Array;
    let run: () => void;

    switch (entry.layout) {
      case "complex-interleaved": {
        const src = (entry.precision === "f32" ? input.interleaved32 : input.interleaved64)!;
        const data = new FloatArray(exports.memory.buffer, 0, size * 2);
        inputBuffer = data;
        run = () => {
          data.set(src);
          exports[entry.run](size);
        };
        break;
      }
      case "complex-split": {
        const re = input.planar32!.subarray(0, size);
        const im = input.planar32!.subarray(size);
        const realData = new Float32Array(
          exports.memory.buffer,
          globalValue(exports.REAL_OFFSET),
          size,
        );
        const imagData = new Float32Array(
          exports.memory.buffer,
          globalValue(exports.IMAG_OFFSET),
          size,
        );
        inputBuffer = realData;
        run = () => {
          realData.set(re);
          imagData.set(im);
          exports[entry.run](size);
        };
        break;
      }
      case "real-packed": {
        const src = (entry.precision === "f32" ? input.real32 : input.real64)!;
        const data = new FloatArray(exports.memory.buffer, 0, size);
        inputBuffer = data;
        run = () => {
          data.set(src);
          exports[entry.run](size);
        };
        break;
      }
      case "real-spectrum": {
        // Hermitian spectrum input (N/2+1 interleaved bins), produced once
        // by this instance's own forward transform.
        const src = (entry.precision === "f32" ? input.real32 : input.real64)!;
        new FloatArray(exports.memory.buffer, 0, size).set(src);
        exports[entry.spectrumVia!](size);
        const data = new FloatArray(exports.memory.buffer, 0, size + 2);
        const spectrum = new FloatArray(size + 2);
        spectrum.set(data);
        inputBuffer = data;
        run = () => {
          data.set(spectrum);
          exports[entry.run](size);
        };
        break;
      }
      default:
        throw new Error(`Unknown layout for ${entry.name}`);
    }

    return {
      name: entry.name,
      size,
      isReal: entry.layout.startsWith("real"),
      isF32: entry.precision === "f32",
      inputBuffer,
      run,
    };
  });
}

// ============================================================================
// Competitor context creators
// ============================================================================

/**
 * Create fft.js (indutny) context - Radix-4 JS
 */
export function createFftJs(size: number): FFTContext {
  const fft = new FFT(size);
  const complexInput = fft.createComplexArray();
  const complexOutput = fft.createComplexArray();
  const inputBuffer = new Float64Array(size * 2);

  return {
    name: "fft.js",
    size,
    isReal: false,
    isF32: false,
    inputBuffer,
    run: () => {
      // Copy to fft.js format
      for (let i = 0; i < size * 2; i++) {
        complexInput[i] = inputBuffer[i];
      }
      fft.transform(complexOutput, complexInput);
    },
  };
}

/**
 * Create fft.js real FFT context
 */
export function createFftJsReal(size: number): FFTContext {
  const fft = new FFT(size);
  const realInput = new Float64Array(size);
  const complexOutput = fft.createComplexArray();

  return {
    name: "fft.js (real)",
    size,
    isReal: true,
    isF32: false,
    inputBuffer: realInput,
    run: () => {
      fft.realTransform(complexOutput, realInput);
    },
  };
}

/**
 * Create fft-js (simple Cooley-Tukey) context
 */
export function createFftJsSimple(size: number): FFTContext {
  const signal: [number, number][] = Array.from({ length: size }, () => [0, 0]);
  const inputBuffer = new Float64Array(size * 2);

  return {
    name: "fft-js",
    size,
    isReal: false,
    isF32: false,
    inputBuffer,
    run: () => {
      // Convert interleaved to phasors
      for (let i = 0; i < size; i++) {
        signal[i][0] = inputBuffer[i * 2];
        signal[i][1] = inputBuffer[i * 2 + 1];
      }
      fftJs.fft(signal);
    },
  };
}

/**
 * Create kissfft-js context
 */
export function createKissFFT(size: number): FFTContext {
  const fftInstance = new kissfft.FFT(size);
  const inputBuffer = new Float64Array(size * 2);

  return {
    name: "kissfft-js",
    size,
    isReal: false,
    isF32: false,
    inputBuffer,
    run: () => {
      fftInstance.forward(inputBuffer);
    },
    dispose: () => {
      fftInstance.dispose();
    },
  };
}

/**
 * Create webfft context (using kissWasm backend)
 */
export function createWebFFT(size: number): FFTContext {
  const fftInstance = new webfft(size);
  fftInstance.setSubLibrary("kissWasm");
  const inputBuffer = new Float32Array(size * 2);

  return {
    name: "webfft",
    size,
    isReal: false,
    isF32: true,
    inputBuffer,
    run: () => {
      fftInstance.fft(inputBuffer);
    },
    dispose: () => {
      fftInstance.dispose();
    },
  };
}

/**
 * Create kissfft-js real FFT context
 */
export function createKissFFTReal(size: number): FFTContext {
  const fftInstance = new kissfft.FFTR(size);
  const inputBuffer = new Float32Array(size);

  return {
    name: "kissfft-js (real)",
    size,
    isReal: true,
    isF32: true,
    inputBuffer,
    run: () => {
      fftInstance.forward(inputBuffer);
    },
    dispose: () => {
      fftInstance.dispose();
    },
  };
}

/**
 * Create webfft real FFT context (using kissWasm backend)
 */
export function createWebFFTReal(size: number): FFTContext {
  const fftInstance = new webfft(size);
  fftInstance.setSubLibrary("kissWasm");
  const inputBuffer = new Float32Array(size);

  return {
    name: "webfft (real)",
    size,
    isReal: true,
    isF32: true,
    inputBuffer,
    run: () => {
      fftInstance.fftr(inputBuffer);
    },
    dispose: () => {
      fftInstance.dispose();
    },
  };
}

/**
 * Create pffft-wasm complex FFT context (SIMD-accelerated f32)
 * Requires size >= 32
 */
export function createPffftComplex(size: number): FFTContext | null {
  if (size < 32) return null; // pffft minimum size

  const setup = pffft._pffft_new_setup(size, PFFFT_COMPLEX);
  const inputPtr = pffft._pffft_aligned_malloc(size * 2 * 4); // complex f32 = size * 2 floats
  const outputPtr = pffft._pffft_aligned_malloc(size * 2 * 4);

  const inputBuffer = new Float32Array(size * 2);

  return {
    name: "pffft-wasm",
    size,
    isReal: false,
    isF32: true,
    inputBuffer,
    run: () => {
      // Copy input to WASM memory
      const wasmInput = new Float32Array(pffft.HEAPF32.buffer, inputPtr, size * 2);
      wasmInput.set(inputBuffer);
      pffft._pffft_transform_ordered(setup, inputPtr, outputPtr, 0, PFFFT_FORWARD);
    },
    dispose: () => {
      pffft._pffft_aligned_free(inputPtr);
      pffft._pffft_aligned_free(outputPtr);
      pffft._pffft_destroy_setup(setup);
    },
  };
}

/**
 * Create fftw-js real FFT context (f32)
 */
export function createFftwJsReal(size: number): FFTContext {
  const fft = new fftwJs.FFT(size);
  const inputBuffer = new Float32Array(size);

  return {
    name: "fftw-js",
    size,
    isReal: true,
    isF32: true,
    inputBuffer,
    run: () => {
      fft.forward(inputBuffer);
    },
    dispose: () => {
      fft.dispose();
    },
  };
}

/**
 * Create pffft-wasm real FFT context (SIMD-accelerated f32)
 * Requires size >= 32
 */
export function createPffftReal(size: number): FFTContext | null {
  if (size < 32) return null; // pffft minimum size

  const setup = pffft._pffft_new_setup(size, PFFFT_REAL);
  const inputPtr = pffft._pffft_aligned_malloc(size * 4); // real f32 = size floats
  const outputPtr = pffft._pffft_aligned_malloc(size * 4);

  const inputBuffer = new Float32Array(size);

  return {
    name: "pffft-wasm (real)",
    size,
    isReal: true,
    isF32: true,
    inputBuffer,
    run: () => {
      // Copy input to WASM memory
      const wasmInput = new Float32Array(pffft.HEAPF32.buffer, inputPtr, size);
      wasmInput.set(inputBuffer);
      pffft._pffft_transform_ordered(setup, inputPtr, outputPtr, 0, PFFFT_FORWARD);
    },
    dispose: () => {
      pffft._pffft_aligned_free(inputPtr);
      pffft._pffft_aligned_free(outputPtr);
      pffft._pffft_destroy_setup(setup);
    },
  };
}
