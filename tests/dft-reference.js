/**
 * Shared Reference DFT Implementations
 *
 * These are O(N^2) naive DFT implementations used as ground truth
 * for verifying FFT correctness. Not optimized for performance.
 */

/**
 * Reference DFT for complex input
 * @param {Float64Array} real - Real parts of input
 * @param {Float64Array} imag - Imaginary parts of input
 * @returns {{real: Float64Array, imag: Float64Array}} DFT output
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
 * Reference DFT for real input (returns only positive frequencies)
 * @param {Float64Array} real - Real input samples
 * @returns {{real: Float64Array, imag: Float64Array}} DFT output (N/2+1 complex values)
 */
export function referenceRealDFT(real) {
  const n = real.length;
  const n2 = n / 2;
  const outReal = new Float64Array(n2 + 1);
  const outImag = new Float64Array(n2 + 1);

  for (let k = 0; k <= n2; k++) {
    let sumReal = 0;
    let sumImag = 0;
    for (let j = 0; j < n; j++) {
      const angle = (-2 * Math.PI * k * j) / n;
      sumReal += real[j] * Math.cos(angle);
      sumImag += real[j] * Math.sin(angle);
    }
    outReal[k] = sumReal;
    outImag[k] = sumImag;
  }

  return { real: outReal, imag: outImag };
}

/**
 * Reference inverse DFT
 * @param {Float64Array} real - Real parts of frequency domain
 * @param {Float64Array} imag - Imaginary parts of frequency domain
 * @returns {{real: Float64Array, imag: Float64Array}} Time domain output
 */
export function referenceIDFT(real, imag) {
  const n = real.length;
  const outReal = new Float64Array(n);
  const outImag = new Float64Array(n);

  for (let k = 0; k < n; k++) {
    let sumReal = 0;
    let sumImag = 0;
    for (let j = 0; j < n; j++) {
      const angle = (2 * Math.PI * k * j) / n; // Positive angle for inverse
      const cos = Math.cos(angle);
      const sin = Math.sin(angle);
      sumReal += real[j] * cos - imag[j] * sin;
      sumImag += real[j] * sin + imag[j] * cos;
    }
    outReal[k] = sumReal / n;
    outImag[k] = sumImag / n;
  }

  return { real: outReal, imag: outImag };
}

/**
 * Compare FFT output with expected values
 * @param {{real: Float64Array, imag: Float64Array}} actual - Actual FFT output
 * @param {{real: Float64Array, imag: Float64Array}} expected - Expected output
 * @param {number} tolerance - Maximum allowed difference
 * @returns {Array} Array of error objects, empty if all values match
 */
export function compareResults(actual, expected, tolerance = 1e-10) {
  const n = expected.real.length;
  const errors = [];

  for (let i = 0; i < n; i++) {
    const realDiff = Math.abs(actual.real[i] - expected.real[i]);
    const imagDiff = Math.abs(actual.imag[i] - expected.imag[i]);

    if (realDiff > tolerance) {
      errors.push({
        index: i,
        component: "real",
        actual: actual.real[i],
        expected: expected.real[i],
        diff: realDiff,
      });
    }
    if (imagDiff > tolerance) {
      errors.push({
        index: i,
        component: "imag",
        actual: actual.imag[i],
        expected: expected.imag[i],
        diff: imagDiff,
      });
    }
  }

  return errors;
}

/**
 * Compute energy (sum of squared magnitudes)
 * @param {Float64Array} real - Real parts
 * @param {Float64Array} imag - Imaginary parts
 * @returns {number} Total energy
 */
export function computeEnergy(real, imag) {
  let energy = 0;
  for (let i = 0; i < real.length; i++) {
    energy += real[i] * real[i] + imag[i] * imag[i];
  }
  return energy;
}

/**
 * Test input generators
 */
export const inputGenerators = {
  /**
   * Impulse signal: [1, 0, 0, ..., 0]
   * FFT should produce flat spectrum (all 1s)
   */
  impulse: (n) => {
    const real = new Float64Array(n);
    const imag = new Float64Array(n);
    real[0] = 1;
    return { real, imag, name: "impulse" };
  },

  /**
   * Constant signal: [1, 1, 1, ..., 1]
   * FFT should produce DC peak (N at bin 0, 0 elsewhere)
   */
  constant: (n) => {
    const real = new Float64Array(n).fill(1);
    const imag = new Float64Array(n);
    return { real, imag, name: "constant" };
  },

  /**
   * Single frequency cosine
   * FFT should produce peaks at bins 1 and N-1
   */
  singleFreq: (n) => {
    const real = new Float64Array(n);
    const imag = new Float64Array(n);
    for (let i = 0; i < n; i++) {
      real[i] = Math.cos((2 * Math.PI * i) / n);
    }
    return { real, imag, name: "single-freq" };
  },

  /**
   * Seeded pseudo-random signal for reproducibility
   */
  random: (n, seed = 12345) => {
    const real = new Float64Array(n);
    const imag = new Float64Array(n);
    let s = seed;
    const rand = () => {
      s = (s * 1103515245 + 12345) & 0x7fffffff;
      return (s / 0x7fffffff) * 2 - 1;
    };
    for (let i = 0; i < n; i++) {
      real[i] = rand();
      imag[i] = rand();
    }
    return { real, imag, name: "random" };
  },

  /**
   * Alternating signal: [1, -1, 1, -1, ...]
   * FFT should produce Nyquist peak (N at bin N/2)
   */
  alternating: (n) => {
    const real = new Float64Array(n);
    const imag = new Float64Array(n);
    for (let i = 0; i < n; i++) {
      real[i] = i % 2 === 0 ? 1 : -1;
    }
    return { real, imag, name: "alternating" };
  },

  /**
   * Real-only random signal (imaginary = 0)
   */
  realRandom: (n, seed = 54321) => {
    const real = new Float64Array(n);
    const imag = new Float64Array(n);
    let s = seed;
    const rand = () => {
      s = (s * 1103515245 + 12345) & 0x7fffffff;
      return (s / 0x7fffffff) * 2 - 1;
    };
    for (let i = 0; i < n; i++) {
      real[i] = rand();
    }
    return { real, imag, name: "real-random" };
  },
};
