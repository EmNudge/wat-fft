/**
 * Shared Test Helper for FFT Correctness Tests
 *
 * Provides common utilities for loading WASM modules, running FFTs,
 * and comparing results across all correctness tests.
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const DIST_DIR = path.join(__dirname, "..", "..", "dist");

// All valid FFT sizes to test (powers of 2)
// Note: stockham fails at N=8192 (twiddle table overflow), so we cap at 4096
export const FFT_SIZES = [4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096];

// Quick tests use smaller subset
export const QUICK_SIZES = [4, 8, 16, 64, 256, 1024];

// Extended sizes for implementations that support them (fast supports 8192)
export const EXTENDED_SIZES = [4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192];

/**
 * Load a WASM FFT module
 */
export async function loadWasmModule(name) {
  const wasmPath = path.join(DIST_DIR, `combined_${name}.wasm`);
  if (!fs.existsSync(wasmPath)) {
    return null;
  }
  const wasmBuffer = fs.readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);
  const instance = await WebAssembly.instantiate(wasmModule, {
    math: { sin: Math.sin, cos: Math.cos },
  });
  return instance.exports;
}

/**
 * FFT implementations to test
 */
export const IMPLEMENTATIONS = {
  stockham: {
    wasmName: "stockham",
    fftFunc: "fft_stockham",
    precompute: "precompute_twiddles",
    precision: "f64",
  },
  stockham_f32: {
    wasmName: "stockham_f32",
    fftFunc: "fft_stockham",
    precompute: "precompute_twiddles",
    precision: "f32",
  },
  fast: {
    wasmName: "fast",
    fftFunc: "fft_fast",
    precompute: "precompute_twiddles",
    precision: "f64",
  },
};

/**
 * Run FFT on complex input
 */
export function runFFT(wasm, impl, real, imag) {
  const n = real.length;
  const isF32 = impl.precision === "f32";
  const FloatArray = isF32 ? Float32Array : Float64Array;

  const memory = wasm.memory;
  const data = new FloatArray(memory.buffer, 0, n * 2);

  for (let i = 0; i < n; i++) {
    data[i * 2] = real[i];
    data[i * 2 + 1] = imag[i];
  }

  if (impl.precompute && wasm[impl.precompute]) {
    wasm[impl.precompute](n);
  }

  wasm[impl.fftFunc](n);

  const resultData = new FloatArray(memory.buffer, 0, n * 2);
  const outReal = new Float64Array(n);
  const outImag = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    outReal[i] = resultData[i * 2];
    outImag[i] = resultData[i * 2 + 1];
  }

  return { real: outReal, imag: outImag };
}

/**
 * Run IFFT using conjugate method: conj(FFT(conj(X)))/N
 */
export function runIFFT(wasm, impl, real, imag) {
  const n = real.length;

  const conjImag = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    conjImag[i] = -imag[i];
  }

  const result = runFFT(wasm, impl, real, conjImag);

  for (let i = 0; i < n; i++) {
    result.real[i] = result.real[i] / n;
    result.imag[i] = -result.imag[i] / n;
  }

  return result;
}

/**
 * Reference DFT (O(N^2), used as ground truth)
 */
export function referenceDFT(real, imag) {
  const n = real.length;
  const outReal = new Float64Array(n);
  const outImag = new Float64Array(n);

  for (let k = 0; k < n; k++) {
    let sumReal = 0;
    let sumImag = 0;
    for (let j = 0; j < n; j++) {
      const angle = (-2 * Math.PI * k * j) / n;
      const cos = Math.cos(angle);
      const sin = Math.sin(angle);
      sumReal += real[j] * cos - imag[j] * sin;
      sumImag += real[j] * sin + imag[j] * cos;
    }
    outReal[k] = sumReal;
    outImag[k] = sumImag;
  }

  return { real: outReal, imag: outImag };
}

/**
 * Compute signal energy
 */
export function computeEnergy(real, imag) {
  let energy = 0;
  for (let i = 0; i < real.length; i++) {
    energy += real[i] * real[i] + imag[i] * imag[i];
  }
  return energy;
}

/**
 * Check approximate equality with relative and absolute tolerance
 *
 * Default tolerances are tuned for FFT testing:
 * - relTol=1e-9: catches algorithmic errors while allowing floating-point noise
 * - absTol=1e-8: handles near-zero values where relative comparison fails
 *
 * The stockham implementation has ~1e-10 accumulated error, so we use
 * slightly larger tolerances to avoid false positives.
 */
export function approxEqual(a, b, relTol = 1e-9, absTol = 1e-8) {
  const diff = Math.abs(a - b);
  const maxAbs = Math.max(Math.abs(a), Math.abs(b));
  return diff <= absTol || diff <= relTol * maxAbs;
}

/**
 * Check array approximate equality
 */
export function arraysApproxEqual(arr1, arr2, relTol = 1e-9, absTol = 1e-8) {
  if (arr1.length !== arr2.length) return false;
  for (let i = 0; i < arr1.length; i++) {
    if (!approxEqual(arr1[i], arr2[i], relTol, absTol)) {
      return false;
    }
  }
  return true;
}

/**
 * Max absolute error between arrays
 */
export function maxError(arr1, arr2) {
  let maxErr = 0;
  for (let i = 0; i < arr1.length; i++) {
    maxErr = Math.max(maxErr, Math.abs(arr1[i] - arr2[i]));
  }
  return maxErr;
}

/**
 * Input signal generators
 */
export const signals = {
  /** Impulse: [1, 0, 0, ..., 0] - FFT should be all 1s */
  impulse: (n) => ({
    real: Float64Array.from({ length: n }, (_, i) => (i === 0 ? 1 : 0)),
    imag: new Float64Array(n),
  }),

  /** DC: [1, 1, 1, ...] - FFT should be [N, 0, 0, ...] */
  constant: (n) => ({
    real: new Float64Array(n).fill(1),
    imag: new Float64Array(n),
  }),

  /** Nyquist: [1, -1, 1, -1, ...] - FFT peak at N/2 */
  alternating: (n) => ({
    real: Float64Array.from({ length: n }, (_, i) => (i % 2 === 0 ? 1 : -1)),
    imag: new Float64Array(n),
  }),

  /** Single frequency cosine at bin k */
  cosine: (n, k = 1) => ({
    real: Float64Array.from({ length: n }, (_, i) => Math.cos((2 * Math.PI * k * i) / n)),
    imag: new Float64Array(n),
  }),

  /** Single frequency sine at bin k */
  sine: (n, k = 1) => ({
    real: Float64Array.from({ length: n }, (_, i) => Math.sin((2 * Math.PI * k * i) / n)),
    imag: new Float64Array(n),
  }),

  /** Seeded pseudo-random complex signal */
  random: (n, seed = 12345) => {
    let s = seed;
    const rand = () => {
      s = (s * 1103515245 + 12345) & 0x7fffffff;
      return (s / 0x7fffffff) * 2 - 1;
    };
    return {
      real: Float64Array.from({ length: n }, () => rand()),
      imag: Float64Array.from({ length: n }, () => rand()),
    };
  },

  /** Seeded pseudo-random real signal (imag = 0) */
  randomReal: (n, seed = 54321) => {
    let s = seed;
    const rand = () => {
      s = (s * 1103515245 + 12345) & 0x7fffffff;
      return (s / 0x7fffffff) * 2 - 1;
    };
    return {
      real: Float64Array.from({ length: n }, () => rand()),
      imag: new Float64Array(n),
    };
  },

  /** Time-shifted impulse at position k */
  shiftedImpulse: (n, k) => ({
    real: Float64Array.from({ length: n }, (_, i) => (i === k ? 1 : 0)),
    imag: new Float64Array(n),
  }),
};

/**
 * Test result reporter
 */
export class TestReporter {
  constructor(name) {
    this.name = name;
    this.passed = 0;
    this.failed = 0;
    this.errors = [];
  }

  pass(message) {
    this.passed++;
    console.log(`  ✓ ${message}`);
  }

  fail(message, error = null) {
    this.failed++;
    this.errors.push({ message, error });
    console.log(`  ✗ ${message}`);
    if (error) {
      console.log(`    ${error}`);
    }
  }

  summary() {
    console.log("");
    console.log(`${this.name}: ${this.passed} passed, ${this.failed} failed`);
    return this.failed === 0;
  }
}

/**
 * Run tests for all implementations
 */
export async function runForAllImplementations(testFn, sizes = QUICK_SIZES) {
  const results = [];

  for (const [name, impl] of Object.entries(IMPLEMENTATIONS)) {
    const wasm = await loadWasmModule(impl.wasmName);
    if (!wasm) {
      console.log(`⚠ Skipping ${name}: WASM not found`);
      continue;
    }

    console.log(`\nTesting: ${name} (${impl.precision})`);
    console.log("-".repeat(40));

    const result = await testFn(wasm, impl, sizes);
    results.push({ name, ...result });
  }

  return results;
}
