// Browser-compatible entry point using fetch instead of fs

/**
 * Load and instantiate a WASM module from a URL
 * @param {string | URL} url - URL to the wasm file
 * @returns {Promise<WebAssembly.Instance>}
 */
async function loadWasm(url) {
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`Failed to load WASM from ${url}: ${response.statusText}`);
  }
  const wasmBuffer = await response.arrayBuffer();
  const wasmModule = await WebAssembly.compile(wasmBuffer);
  return WebAssembly.instantiate(wasmModule);
}

// =============================================================================
// Low-level instance factories (return raw WASM exports)
// =============================================================================

/**
 * Create a raw WASM instance for complex FFT (f64).
 * @param {string | URL} wasmUrl - URL to fft_combined.wasm
 * @returns {Promise<import('./index.js').FFTExports>}
 */
export async function createFFTInstance(wasmUrl) {
  const instance = await loadWasm(wasmUrl);
  return /** @type {import('./index.js').FFTExports} */ (instance.exports);
}

/**
 * Create a raw WASM instance for complex FFT (f32).
 * @param {string | URL} wasmUrl - URL to fft_stockham_f32_dual.wasm
 * @returns {Promise<import('./index.js').FFTf32Exports>}
 */
export async function createFFTf32Instance(wasmUrl) {
  const instance = await loadWasm(wasmUrl);
  return /** @type {import('./index.js').FFTf32Exports} */ (instance.exports);
}

/**
 * Create a raw WASM instance for real FFT (f64).
 * @param {string | URL} wasmUrl - URL to fft_real_combined.wasm
 * @returns {Promise<import('./index.js').RFFTExports>}
 */
export async function createRFFTInstance(wasmUrl) {
  const instance = await loadWasm(wasmUrl);
  return /** @type {import('./index.js').RFFTExports} */ (instance.exports);
}

/**
 * Create a raw WASM instance for real FFT (f32).
 * @param {string | URL} wasmUrl - URL to fft_real_f32_dual.wasm
 * @returns {Promise<import('./index.js').RFFTf32Exports>}
 */
export async function createRFFTf32Instance(wasmUrl) {
  const instance = await loadWasm(wasmUrl);
  return /** @type {import('./index.js').RFFTf32Exports} */ (instance.exports);
}

// =============================================================================
// High-level context factories (recommended)
// =============================================================================

/**
 * Create a high-level complex FFT context (f64).
 * @param {number} size - FFT size (must be power of 2)
 * @param {string | URL} wasmUrl - URL to fft_combined.wasm
 * @returns {Promise<import('./index.js').FFT>}
 */
export async function createFFT(size, wasmUrl) {
  const exports = await createFFTInstance(wasmUrl);
  exports.precompute_twiddles(size);

  const bufferLength = size * 2;

  return {
    size,
    exports,
    getInputBuffer() {
      return new Float64Array(exports.memory.buffer, 0, bufferLength);
    },
    getOutputBuffer() {
      return new Float64Array(exports.memory.buffer, 0, bufferLength);
    },
    forward() {
      exports.fft(size);
    },
    inverse() {
      exports.ifft(size);
    },
  };
}

/**
 * Create a high-level complex FFT context (f32).
 * @param {number} size - FFT size (must be power of 2)
 * @param {string | URL} wasmUrl - URL to fft_stockham_f32_dual.wasm
 * @returns {Promise<import('./index.js').FFTf32>}
 */
export async function createFFTf32(size, wasmUrl) {
  const exports = await createFFTf32Instance(wasmUrl);
  exports.precompute_twiddles(size);

  const bufferLength = size * 2;

  return {
    size,
    exports,
    getInputBuffer() {
      return new Float32Array(exports.memory.buffer, 0, bufferLength);
    },
    getOutputBuffer() {
      return new Float32Array(exports.memory.buffer, 0, bufferLength);
    },
    forward() {
      exports.fft(size);
    },
    inverse() {
      exports.ifft(size);
    },
  };
}

/**
 * Create a high-level real FFT context (f64).
 * @param {number} size - FFT size (must be power of 2)
 * @param {string | URL} wasmUrl - URL to fft_real_combined.wasm
 * @returns {Promise<import('./index.js').RFFT>}
 */
export async function createRFFT(size, wasmUrl) {
  const exports = await createRFFTInstance(wasmUrl);
  exports.precompute_rfft_twiddles(size);

  const outputLength = (size / 2 + 1) * 2;

  return {
    size,
    exports,
    getInputBuffer() {
      return new Float64Array(exports.memory.buffer, 0, size);
    },
    getOutputBuffer() {
      return new Float64Array(exports.memory.buffer, 0, outputLength);
    },
    forward() {
      exports.rfft(size);
    },
    inverse() {
      exports.irfft(size);
    },
  };
}

/**
 * Create a high-level real FFT context (f32).
 * @param {number} size - FFT size (must be power of 2)
 * @param {string | URL} wasmUrl - URL to fft_real_f32_dual.wasm
 * @returns {Promise<import('./index.js').RFFTf32>}
 */
export async function createRFFTf32(size, wasmUrl) {
  const exports = await createRFFTf32Instance(wasmUrl);
  exports.precompute_rfft_twiddles(size);

  const outputLength = (size / 2 + 1) * 2;

  return {
    size,
    exports,
    getInputBuffer() {
      return new Float32Array(exports.memory.buffer, 0, size);
    },
    getOutputBuffer() {
      return new Float32Array(exports.memory.buffer, 0, outputLength);
    },
    forward() {
      exports.rfft(size);
    },
    inverse() {
      exports.irfft(size);
    },
  };
}
