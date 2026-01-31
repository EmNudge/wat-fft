import type {
  FFT,
  FFTf32,
  RFFT,
  RFFTf32,
  FFTExports,
  FFTf32Exports,
  RFFTExports,
  RFFTf32Exports,
} from "./index.js";

// Re-export types for convenience
export type { FFT, FFTf32, RFFT, RFFTf32, FFTExports, FFTf32Exports, RFFTExports, RFFTf32Exports };

// =============================================================================
// Low-level instance factories (return raw WASM exports)
// =============================================================================

/**
 * Create a raw WASM instance for complex FFT (f64).
 * @param wasmUrl - URL to fft_combined.wasm
 */
export function createFFTInstance(wasmUrl: string | URL): Promise<FFTExports>;

/**
 * Create a raw WASM instance for complex FFT (f32).
 * @param wasmUrl - URL to fft_stockham_f32_dual.wasm
 */
export function createFFTf32Instance(wasmUrl: string | URL): Promise<FFTf32Exports>;

/**
 * Create a raw WASM instance for real FFT (f64).
 * @param wasmUrl - URL to fft_real_combined.wasm
 */
export function createRFFTInstance(wasmUrl: string | URL): Promise<RFFTExports>;

/**
 * Create a raw WASM instance for real FFT (f32).
 * @param wasmUrl - URL to fft_real_f32_dual.wasm
 */
export function createRFFTf32Instance(wasmUrl: string | URL): Promise<RFFTf32Exports>;

// =============================================================================
// High-level context factories (recommended)
// =============================================================================

/**
 * Create a high-level complex FFT context (f64).
 *
 * @param size - FFT size (must be power of 2)
 * @param wasmUrl - URL to fft_combined.wasm
 *
 * @example
 * ```ts
 * import { createFFT } from "@emnudge/wat-fft/browser";
 * import wasmUrl from "@emnudge/wat-fft/wasm/fft.wasm?url";
 *
 * const fft = await createFFT(1024, wasmUrl);
 * ```
 */
export function createFFT(size: number, wasmUrl: string | URL): Promise<FFT>;

/**
 * Create a high-level complex FFT context (f32).
 *
 * @param size - FFT size (must be power of 2)
 * @param wasmUrl - URL to fft_stockham_f32_dual.wasm
 */
export function createFFTf32(size: number, wasmUrl: string | URL): Promise<FFTf32>;

/**
 * Create a high-level real FFT context (f64).
 *
 * @param size - FFT size (must be power of 2)
 * @param wasmUrl - URL to fft_real_combined.wasm
 */
export function createRFFT(size: number, wasmUrl: string | URL): Promise<RFFT>;

/**
 * Create a high-level real FFT context (f32).
 *
 * @param size - FFT size (must be power of 2)
 * @param wasmUrl - URL to fft_real_f32_dual.wasm
 *
 * @example
 * ```ts
 * import { createRFFTf32 } from "@emnudge/wat-fft/browser";
 * import wasmUrl from "@emnudge/wat-fft/wasm/rfft-f32.wasm?url";
 *
 * const rfft = await createRFFTf32(1024, wasmUrl);
 * const input = rfft.getInputBuffer();
 * input.set(audioSamples);
 * rfft.forward();
 * const spectrum = rfft.getOutputBuffer();
 * ```
 */
export function createRFFTf32(size: number, wasmUrl: string | URL): Promise<RFFTf32>;
