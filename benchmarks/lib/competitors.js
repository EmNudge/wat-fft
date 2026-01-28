/**
 * Shared configuration for third-party FFT libraries.
 *
 * This module provides the SINGLE SOURCE OF TRUTH for how competitor
 * libraries are configured. Both benchmarks and correctness tests
 * import from here to ensure consistency.
 *
 * If you change how a library is called here, update the corresponding
 * correctness test to verify it still produces correct results.
 */

// =============================================================================
// pffft-wasm configuration
// From pffft.h: typedef enum { PFFFT_REAL, PFFFT_COMPLEX } pffft_transform_t;
// =============================================================================
export const PFFFT = {
  REAL: 0,
  COMPLEX: 1,
  FORWARD: 0,
  BACKWARD: 1,
  MIN_SIZE: 32, // pffft requires minimum size of 32
};

/**
 * Run pffft complex FFT
 * @param {object} pffft - The loaded pffft-wasm module
 * @param {number} size - FFT size
 * @param {Float32Array} realInput - Real part of input
 * @param {Float32Array} imagInput - Imaginary part of input
 * @returns {{real: Float32Array, imag: Float32Array}} - Output arrays
 */
export function pffftComplexFFT(pffft, size, realInput, imagInput) {
  const setup = pffft._pffft_new_setup(size, PFFFT.COMPLEX);
  const inputPtr = pffft._pffft_aligned_malloc(size * 2 * 4);
  const outputPtr = pffft._pffft_aligned_malloc(size * 2 * 4);

  try {
    const inputView = new Float32Array(pffft.HEAPF32.buffer, inputPtr, size * 2);
    for (let i = 0; i < size; i++) {
      inputView[i * 2] = realInput[i];
      inputView[i * 2 + 1] = imagInput[i];
    }

    pffft._pffft_transform_ordered(setup, inputPtr, outputPtr, 0, PFFFT.FORWARD);

    const outputView = new Float32Array(pffft.HEAPF32.buffer, outputPtr, size * 2);
    const outReal = new Float32Array(size);
    const outImag = new Float32Array(size);
    for (let i = 0; i < size; i++) {
      outReal[i] = outputView[i * 2];
      outImag[i] = outputView[i * 2 + 1];
    }

    return { real: outReal, imag: outImag };
  } finally {
    pffft._pffft_aligned_free(inputPtr);
    pffft._pffft_aligned_free(outputPtr);
    pffft._pffft_destroy_setup(setup);
  }
}

/**
 * Run pffft real FFT
 * @param {object} pffft - The loaded pffft-wasm module
 * @param {number} size - FFT size
 * @param {Float32Array} input - Real input array
 * @returns {{real: Float32Array, imag: Float32Array}} - Output (N/2+1 complex values)
 */
export function pffftRealFFT(pffft, size, input) {
  const setup = pffft._pffft_new_setup(size, PFFFT.REAL);
  const inputPtr = pffft._pffft_aligned_malloc(size * 4);
  const outputPtr = pffft._pffft_aligned_malloc(size * 4);

  try {
    const inputView = new Float32Array(pffft.HEAPF32.buffer, inputPtr, size);
    for (let i = 0; i < size; i++) {
      inputView[i] = input[i];
    }

    pffft._pffft_transform_ordered(setup, inputPtr, outputPtr, 0, PFFFT.FORWARD);

    // pffft real FFT "ordered" output format:
    // [DC_real, Nyquist_real, bin1_real, bin1_imag, bin2_real, bin2_imag, ...]
    const outputView = new Float32Array(pffft.HEAPF32.buffer, outputPtr, size);
    const numComplex = size / 2 + 1;
    const outReal = new Float32Array(numComplex);
    const outImag = new Float32Array(numComplex);

    // Bin 0 (DC) - real only
    outReal[0] = outputView[0];
    outImag[0] = 0;

    // Bin N/2 (Nyquist) - real only
    outReal[size / 2] = outputView[1];
    outImag[size / 2] = 0;

    // Bins 1 to N/2-1 - complex
    for (let i = 1; i < size / 2; i++) {
      outReal[i] = outputView[2 * i];
      outImag[i] = outputView[2 * i + 1];
    }

    return { real: outReal, imag: outImag };
  } finally {
    pffft._pffft_aligned_free(inputPtr);
    pffft._pffft_aligned_free(outputPtr);
    pffft._pffft_destroy_setup(setup);
  }
}

/**
 * Create a pffft benchmark context for repeated FFT calls
 * Used by benchmarks to avoid setup/teardown overhead in timing loop
 */
export function createPffftComplexContext(pffft, size, realInput, imagInput) {
  const setup = pffft._pffft_new_setup(size, PFFFT.COMPLEX);
  const inputPtr = pffft._pffft_aligned_malloc(size * 2 * 4);
  const outputPtr = pffft._pffft_aligned_malloc(size * 2 * 4);

  const inputView = new Float32Array(pffft.HEAPF32.buffer, inputPtr, size * 2);
  for (let i = 0; i < size; i++) {
    inputView[i * 2] = realInput[i];
    inputView[i * 2 + 1] = imagInput[i];
  }

  return {
    setup,
    inputPtr,
    outputPtr,
    run: () => {
      pffft._pffft_transform_ordered(setup, inputPtr, outputPtr, 0, PFFFT.FORWARD);
    },
    dispose: () => {
      pffft._pffft_aligned_free(inputPtr);
      pffft._pffft_aligned_free(outputPtr);
      pffft._pffft_destroy_setup(setup);
    },
  };
}

/**
 * Create a pffft benchmark context for real FFT
 */
export function createPffftRealContext(pffft, size, input) {
  const setup = pffft._pffft_new_setup(size, PFFFT.REAL);
  const inputPtr = pffft._pffft_aligned_malloc(size * 4);
  const outputPtr = pffft._pffft_aligned_malloc(size * 4);

  const inputView = new Float32Array(pffft.HEAPF32.buffer, inputPtr, size);
  for (let i = 0; i < size; i++) {
    inputView[i] = input[i];
  }

  return {
    setup,
    inputPtr,
    outputPtr,
    run: () => {
      pffft._pffft_transform_ordered(setup, inputPtr, outputPtr, 0, PFFFT.FORWARD);
    },
    dispose: () => {
      pffft._pffft_aligned_free(inputPtr);
      pffft._pffft_aligned_free(outputPtr);
      pffft._pffft_destroy_setup(setup);
    },
  };
}
