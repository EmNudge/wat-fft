/**
 * Component-aware test utilities for WebAssembly Component Model
 *
 * These utilities allow testing components with mocked dependencies.
 * Components can be loaded and have their imports satisfied by:
 * - JS functions (for trig functions like sin/cos)
 * - Other components (for composition testing)
 * - Mock implementations (for isolated unit testing)
 */

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

/**
 * Load a component's core wasm (before componentization) for direct testing.
 * This bypasses the component model and tests the raw wasm module.
 *
 * @param {string} moduleName - Name of the module (e.g., "fft_stockham")
 * @param {object} imports - Import object matching the module's imports
 * @returns {Promise<WebAssembly.Instance>}
 */
export async function loadCoreModule(moduleName, imports = {}) {
  const wasmPath = path.resolve(__dirname, "..", "build", `${moduleName}.core.wasm`);
  const wasmBytes = fs.readFileSync(wasmPath);
  const { instance } = await WebAssembly.instantiate(wasmBytes, imports);
  return instance;
}

/**
 * Create standard trig imports using JS Math
 * @returns {object} Import object with sin/cos functions
 */
export function createTrigImports() {
  return {
    $root: {
      sin: Math.sin,
      cos: Math.cos,
    },
  };
}

/**
 * Create mock trig imports for testing
 * @param {object} overrides - Override specific functions
 * @returns {object} Import object with mock trig functions
 */
export function createMockTrigImports(overrides = {}) {
  return {
    $root: {
      sin: overrides.sin || ((x) => Math.sin(x)),
      cos: overrides.cos || ((x) => Math.cos(x)),
      ...overrides,
    },
  };
}

/**
 * Create imports for fft_stockham component testing
 * @param {object} overrides - Override specific imports
 * @returns {object} Import object for fft_stockham
 */
export function createStockhamImports(overrides = {}) {
  return {
    $root: {
      sin: overrides.sin || Math.sin,
      cos: overrides.cos || Math.cos,
    },
  };
}

/**
 * Create imports for fft_radix4 component testing
 * @param {object} overrides - Override specific imports
 * @returns {object} Import object for fft_radix4
 */
export function createRadix4Imports(overrides = {}) {
  const defaultReverseBits = (x, log2n) => {
    let rev = 0;
    for (let i = 0; i < log2n; i++) {
      rev = (rev << 1) | (x & 1);
      x >>= 1;
    }
    return rev;
  };

  return {
    $root: {
      sin: overrides.sin || Math.sin,
      cos: overrides.cos || Math.cos,
      "reverse-bits": overrides["reverse-bits"] || defaultReverseBits,
    },
  };
}

/**
 * Create imports for fft_fast component testing
 * @param {object} overrides - Override specific imports
 * @returns {object} Import object for fft_fast
 */
export function createFastImports(overrides = {}) {
  const defaultReverseBits = (x, log2n) => {
    let rev = 0;
    for (let i = 0; i < log2n; i++) {
      rev = (rev << 1) | (x & 1);
      x >>= 1;
    }
    return rev;
  };

  return {
    $root: {
      sin: overrides.sin || Math.sin,
      cos: overrides.cos || Math.cos,
      "reverse-bits": overrides["reverse-bits"] || defaultReverseBits,
    },
  };
}

/**
 * Create imports for fft_simd component testing
 * @param {object} overrides - Override specific imports
 * @returns {object} Import object for fft_simd
 */
export function createSimdImports(overrides = {}) {
  const defaultReverseBits = (x, log2n) => {
    let rev = 0;
    for (let i = 0; i < log2n; i++) {
      rev = (rev << 1) | (x & 1);
      x >>= 1;
    }
    return rev;
  };

  return {
    $root: {
      sin: overrides.sin || Math.sin,
      cos: overrides.cos || Math.cos,
      "reverse-bits": overrides["reverse-bits"] || defaultReverseBits,
    },
  };
}

/**
 * Test helper: Load an FFT component and return a test harness
 * @param {string} variant - FFT variant name (stockham, radix4, fast, simd, unrolled)
 * @param {object} importOverrides - Override default imports
 * @returns {Promise<object>} Test harness with exports and memory access
 */
export async function loadFFTComponent(variant, importOverrides = {}) {
  const moduleName = `fft_${variant}`;
  let imports;

  switch (variant) {
    case "stockham":
      imports = createStockhamImports(importOverrides);
      break;
    case "radix4":
      imports = createRadix4Imports(importOverrides);
      break;
    case "fast":
      imports = createFastImports(importOverrides);
      break;
    case "simd":
      imports = createSimdImports(importOverrides);
      break;
    case "unrolled":
      imports = createStockhamImports(importOverrides); // Same imports as stockham
      break;
    default:
      throw new Error(`Unknown FFT variant: ${variant}`);
  }

  const instance = await loadCoreModule(moduleName, imports);

  return {
    exports: instance.exports,
    memory: instance.exports.memory,
    variant,
  };
}

/**
 * Test helper: Write complex array to WASM memory
 * @param {WebAssembly.Memory} memory - WASM memory
 * @param {number[]} realParts - Real parts of complex numbers
 * @param {number[]} imagParts - Imaginary parts (default: all zeros)
 * @param {number} offset - Byte offset (default: 0)
 */
export function writeComplexArray(memory, realParts, imagParts = null, offset = 0) {
  const view = new Float64Array(memory.buffer, offset);
  const n = realParts.length;
  imagParts = imagParts || Array.from({ length: n }, () => 0);

  for (let i = 0; i < n; i++) {
    view[i * 2] = realParts[i];
    view[i * 2 + 1] = imagParts[i];
  }
}

/**
 * Test helper: Read complex array from WASM memory
 * @param {WebAssembly.Memory} memory - WASM memory
 * @param {number} n - Number of complex numbers
 * @param {number} offset - Byte offset (default: 0)
 * @returns {{real: number[], imag: number[]}}
 */
export function readComplexArray(memory, n, offset = 0) {
  const view = new Float64Array(memory.buffer, offset);
  const real = [];
  const imag = [];

  for (let i = 0; i < n; i++) {
    real.push(view[i * 2]);
    imag.push(view[i * 2 + 1]);
  }

  return { real, imag };
}

/**
 * Test helper: Compare FFT results with tolerance
 * @param {number[]} actual - Actual values
 * @param {number[]} expected - Expected values
 * @param {number} tolerance - Comparison tolerance (default: 1e-10)
 * @returns {boolean}
 */
export function compareResults(actual, expected, tolerance = 1e-10) {
  if (actual.length !== expected.length) return false;
  for (let i = 0; i < actual.length; i++) {
    if (Math.abs(actual[i] - expected[i]) > tolerance) return false;
  }
  return true;
}
