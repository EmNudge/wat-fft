import { readFile } from "fs/promises";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const distDir = join(__dirname, "dist");

/**
 * Load and instantiate a WASM module
 * @param {string} filename - Name of the wasm file in dist/
 * @returns {Promise<WebAssembly.Instance>}
 */
async function loadWasm(filename) {
  const wasmPath = join(distDir, filename);
  const wasmBuffer = await readFile(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);
  return WebAssembly.instantiate(wasmModule);
}

/**
 * Complex FFT with f64 precision (1.4-1.9x faster than fft.js)
 *
 * Exports:
 * - memory: WebAssembly.Memory
 * - precompute_twiddles(n: i32): void
 * - fft_stockham(n: i32): void
 * - ifft_stockham(n: i32): void
 *
 * Input: interleaved complex [re0, im0, re1, im1, ...] as Float64Array
 */
export async function createFFT() {
  return loadWasm("fft_combined.wasm");
}

/**
 * Complex FFT with f32 precision (up to 2.6x faster than fft.js)
 *
 * Exports:
 * - memory: WebAssembly.Memory
 * - precompute_twiddles(n: i32): void
 * - fft(n: i32): void
 * - ifft(n: i32): void
 *
 * Input: interleaved complex [re0, im0, re1, im1, ...] as Float32Array
 */
export async function createFFTf32() {
  return loadWasm("fft_stockham_f32_dual.wasm");
}

/**
 * Real FFT with f64 precision
 *
 * Exports:
 * - memory: WebAssembly.Memory
 * - precompute_twiddles(n: i32): void
 * - rfft(n: i32): void
 * - irfft(n: i32): void
 *
 * Input: real values as Float64Array of length N
 * Output: N/2+1 complex bins (interleaved) for positive frequencies
 */
export async function createRFFT() {
  return loadWasm("fft_real_combined.wasm");
}

/**
 * Real FFT with f32 precision (beats fftw-js at all sizes)
 *
 * Exports:
 * - memory: WebAssembly.Memory
 * - precompute_twiddles(n: i32): void
 * - rfft(n: i32): void
 * - irfft(n: i32): void
 *
 * Input: real values as Float32Array of length N
 * Output: N/2+1 complex bins (interleaved) for positive frequencies
 */
export async function createRFFTf32() {
  return loadWasm("fft_real_f32_dual.wasm");
}
