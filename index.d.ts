// =============================================================================
// Low-level WASM instance types
// =============================================================================

/** Raw WASM exports for complex FFT (f64) */
export interface FFTExports {
  memory: WebAssembly.Memory;
  precompute_twiddles(n: number): void;
  fft(n: number): void;
  ifft(n: number): void;
}

/** Raw WASM exports for complex FFT (f32) */
export interface FFTf32Exports {
  memory: WebAssembly.Memory;
  precompute_twiddles(n: number): void;
  fft(n: number): void;
  ifft(n: number): void;
}

/** Raw WASM exports for real FFT (f64) */
export interface RFFTExports {
  memory: WebAssembly.Memory;
  precompute_rfft_twiddles(n: number): void;
  rfft(n: number): void;
  irfft(n: number): void;
}

/** Raw WASM exports for real FFT (f32) */
export interface RFFTf32Exports {
  memory: WebAssembly.Memory;
  precompute_rfft_twiddles(n: number): void;
  rfft(n: number): void;
  irfft(n: number): void;
}

// =============================================================================
// High-level FFT context types
// =============================================================================

/** High-level complex FFT context (f64) */
export interface FFT {
  /** FFT size (must be power of 2) */
  readonly size: number;

  /**
   * Get the input buffer for writing samples.
   * Format: interleaved complex [re0, im0, re1, im1, ...]
   * Length: size * 2
   */
  getInputBuffer(): Float64Array;

  /**
   * Get the output buffer for reading results.
   * Format: interleaved complex [re0, im0, re1, im1, ...]
   * Length: size * 2
   */
  getOutputBuffer(): Float64Array;

  /** Execute forward FFT in-place */
  forward(): void;

  /** Execute inverse FFT in-place */
  inverse(): void;

  /** Access the underlying WASM exports for advanced use */
  readonly exports: FFTExports;
}

/** High-level complex FFT context (f32) */
export interface FFTf32 {
  /** FFT size (must be power of 2) */
  readonly size: number;

  /**
   * Get the input buffer for writing samples.
   * Format: interleaved complex [re0, im0, re1, im1, ...]
   * Length: size * 2
   */
  getInputBuffer(): Float32Array;

  /**
   * Get the output buffer for reading results.
   * Format: interleaved complex [re0, im0, re1, im1, ...]
   * Length: size * 2
   */
  getOutputBuffer(): Float32Array;

  /** Execute forward FFT in-place */
  forward(): void;

  /** Execute inverse FFT in-place */
  inverse(): void;

  /** Access the underlying WASM exports for advanced use */
  readonly exports: FFTf32Exports;
}

/** High-level real FFT context (f64) */
export interface RFFT {
  /** FFT size (must be power of 2) */
  readonly size: number;

  /**
   * Get the input buffer for writing real samples.
   * Length: size
   */
  getInputBuffer(): Float64Array;

  /**
   * Get the output buffer for reading complex results.
   * Format: interleaved complex [re0, im0, re1, im1, ...]
   * Length: (size / 2 + 1) * 2
   */
  getOutputBuffer(): Float64Array;

  /** Execute forward real FFT in-place */
  forward(): void;

  /** Execute inverse real FFT in-place */
  inverse(): void;

  /** Access the underlying WASM exports for advanced use */
  readonly exports: RFFTExports;
}

/** High-level real FFT context (f32) */
export interface RFFTf32 {
  /** FFT size (must be power of 2) */
  readonly size: number;

  /**
   * Get the input buffer for writing real samples.
   * Length: size
   */
  getInputBuffer(): Float32Array;

  /**
   * Get the output buffer for reading complex results.
   * Format: interleaved complex [re0, im0, re1, im1, ...]
   * Length: (size / 2 + 1) * 2
   */
  getOutputBuffer(): Float32Array;

  /** Execute forward real FFT in-place */
  forward(): void;

  /** Execute inverse real FFT in-place */
  inverse(): void;

  /** Access the underlying WASM exports for advanced use */
  readonly exports: RFFTf32Exports;
}

// =============================================================================
// High-level factory functions (recommended)
// =============================================================================

/**
 * Create a complex FFT context with f64 precision.
 *
 * @param size - FFT size (must be power of 2)
 * @returns High-level FFT context with automatic memory management
 *
 * @example
 * ```ts
 * const fft = await createFFT(1024);
 * const input = fft.getInputBuffer();
 * // Fill input with interleaved complex data [re, im, re, im, ...]
 * input[0] = 1.0; input[1] = 0.0; // First sample
 * fft.forward();
 * const output = fft.getOutputBuffer();
 * ```
 */
export function createFFT(size: number): Promise<FFT>;

/**
 * Create a complex FFT context with f32 precision.
 * Faster than f64 for most use cases.
 *
 * @param size - FFT size (must be power of 2)
 * @returns High-level FFT context with automatic memory management
 */
export function createFFTf32(size: number): Promise<FFTf32>;

/**
 * Create a real FFT context with f64 precision.
 * Use this when your input signal is purely real (no imaginary component).
 *
 * @param size - FFT size (must be power of 2)
 * @returns High-level RFFT context with automatic memory management
 *
 * @example
 * ```ts
 * const rfft = await createRFFT(1024);
 * const input = rfft.getInputBuffer();
 * // Fill with real samples
 * for (let i = 0; i < 1024; i++) {
 *   input[i] = Math.sin(2 * Math.PI * i / 1024);
 * }
 * rfft.forward();
 * const output = rfft.getOutputBuffer(); // (512 + 1) * 2 complex values
 * ```
 */
export function createRFFT(size: number): Promise<RFFT>;

/**
 * Create a real FFT context with f32 precision.
 * Fastest option for real-valued signals.
 *
 * @param size - FFT size (must be power of 2)
 * @returns High-level RFFT context with automatic memory management
 */
export function createRFFTf32(size: number): Promise<RFFTf32>;

// =============================================================================
// Low-level factory functions (advanced)
// =============================================================================

/**
 * Create a raw WASM instance for complex FFT (f64).
 * For advanced users who need direct memory control.
 *
 * @returns Raw WebAssembly exports
 */
export function createFFTInstance(): Promise<FFTExports>;

/**
 * Create a raw WASM instance for complex FFT (f32).
 * For advanced users who need direct memory control.
 *
 * @returns Raw WebAssembly exports
 */
export function createFFTf32Instance(): Promise<FFTf32Exports>;

/**
 * Create a raw WASM instance for real FFT (f64).
 * For advanced users who need direct memory control.
 *
 * @returns Raw WebAssembly exports
 */
export function createRFFTInstance(): Promise<RFFTExports>;

/**
 * Create a raw WASM instance for real FFT (f32).
 * For advanced users who need direct memory control.
 *
 * @returns Raw WebAssembly exports
 */
export function createRFFTf32Instance(): Promise<RFFTf32Exports>;
