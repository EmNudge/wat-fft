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
// @ts-ignore - pffft-wasm default export is a factory function
import PFFFT from "@echogarden/pffft-wasm";
// @ts-ignore - fftw-js is CommonJS but Vite can handle it
import fftwJs from "fftw-js";

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

// WASM module cache
const wasmCache = new Map<string, WebAssembly.Instance>();

/**
 * Load a WASM module by URL
 */
async function loadWasmByUrl(url: string): Promise<WebAssembly.Instance> {
  if (wasmCache.has(url)) {
    return wasmCache.get(url)!;
  }

  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`Failed to load WASM: ${response.statusText}`);
  }

  const buffer = await response.arrayBuffer();
  const module = await WebAssembly.compile(buffer);
  const instance = await WebAssembly.instantiate(module);

  wasmCache.set(url, instance);
  return instance;
}

// Pre-load all WASM modules at module initialization time
export const wasmModules = await Promise.all([
  loadWasmByUrl(fftCombinedUrl),
  loadWasmByUrl(fftF32Url),
  loadWasmByUrl(fftSplitUrl),
  loadWasmByUrl(rfftCombinedUrl),
  loadWasmByUrl(rfftF32Url),
]).then(([fftCombined, fftF32, fftSplit, rfftCombined, rfftF32]) => ({
  fftCombined,
  fftF32,
  fftSplit,
  rfftCombined,
  rfftF32,
}));

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
} {
  const interleaved64 = new Float64Array(n * 2);
  const interleaved32 = new Float32Array(n * 2);

  for (let i = 0; i < n; i++) {
    const r = Math.random() * 2 - 1;
    const im = Math.random() * 2 - 1;
    interleaved64[i * 2] = r;
    interleaved64[i * 2 + 1] = im;
    interleaved32[i * 2] = r;
    interleaved32[i * 2 + 1] = im;
  }

  return { interleaved64, interleaved32 };
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
// wat-fft context creators (synchronous since WASM is pre-loaded)
// ============================================================================

/**
 * Create wat-fft f64 complex FFT context
 */
export function createWatFftF64(size: number): FFTContext {
  const exports = wasmModules.fftCombined.exports as {
    memory: WebAssembly.Memory;
    precompute_twiddles: (n: number) => void;
    fft: (n: number) => void;
  };

  exports.precompute_twiddles(size);
  const data = new Float64Array(exports.memory.buffer, 0, size * 2);

  return {
    name: "wat-fft (f64)",
    size,
    isReal: false,
    isF32: false,
    inputBuffer: data,
    run: () => exports.fft(size),
  };
}

/**
 * Create wat-fft f32 complex FFT context
 */
export function createWatFftF32(size: number): FFTContext {
  const exports = wasmModules.fftF32.exports as {
    memory: WebAssembly.Memory;
    precompute_twiddles: (n: number) => void;
    fft: (n: number) => void;
  };

  exports.precompute_twiddles(size);
  const data = new Float32Array(exports.memory.buffer, 0, size * 2);

  return {
    name: "wat-fft (f32)",
    size,
    isReal: false,
    isF32: true,
    inputBuffer: data,
    run: () => exports.fft(size),
  };
}

/**
 * Create wat-fft f32 split-format FFT context
 */
export function createWatFftSplit(size: number): FFTContext {
  const exports = wasmModules.fftSplit.exports as {
    memory: WebAssembly.Memory;
    REAL_OFFSET: WebAssembly.Global;
    IMAG_OFFSET: WebAssembly.Global;
    precompute_twiddles_split: (n: number) => void;
    fft_split: (n: number) => void;
  };

  exports.precompute_twiddles_split(size);

  const realOffset =
    typeof exports.REAL_OFFSET === "number" ? exports.REAL_OFFSET : exports.REAL_OFFSET.value;
  const imagOffset =
    typeof exports.IMAG_OFFSET === "number" ? exports.IMAG_OFFSET : exports.IMAG_OFFSET.value;

  const realData = new Float32Array(exports.memory.buffer, realOffset, size);
  const imagData = new Float32Array(exports.memory.buffer, imagOffset, size);
  const inputBuffer = new Float32Array(size * 2);

  return {
    name: "wat-fft (f32 split)",
    size,
    isReal: false,
    isF32: true,
    inputBuffer,
    run: () => {
      // Copy interleaved input to split format
      for (let i = 0; i < size; i++) {
        realData[i] = inputBuffer[i * 2];
        imagData[i] = inputBuffer[i * 2 + 1];
      }
      exports.fft_split(size);
    },
  };
}

/**
 * Create wat-fft f64 real FFT context
 */
export function createWatRfftF64(size: number): FFTContext {
  const exports = wasmModules.rfftCombined.exports as {
    memory: WebAssembly.Memory;
    precompute_rfft_twiddles: (n: number) => void;
    rfft: (n: number) => void;
  };

  exports.precompute_rfft_twiddles(size);
  const data = new Float64Array(exports.memory.buffer, 0, size);

  return {
    name: "wat-rfft (f64)",
    size,
    isReal: true,
    isF32: false,
    inputBuffer: data,
    run: () => exports.rfft(size),
  };
}

/**
 * Create wat-fft f32 real FFT context
 */
export function createWatRfftF32(size: number): FFTContext {
  const exports = wasmModules.rfftF32.exports as {
    memory: WebAssembly.Memory;
    precompute_rfft_twiddles: (n: number) => void;
    rfft: (n: number) => void;
  };

  exports.precompute_rfft_twiddles(size);
  const data = new Float32Array(exports.memory.buffer, 0, size);

  return {
    name: "wat-rfft (f32)",
    size,
    isReal: true,
    isF32: true,
    inputBuffer: data,
    run: () => exports.rfft(size),
  };
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
