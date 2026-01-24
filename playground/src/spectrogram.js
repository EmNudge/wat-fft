/**
 * Spectrogram Generator
 *
 * Computes and renders spectrograms using wat-fft
 */

/**
 * Apply Hann window to a frame
 */
function applyHannWindow(frame) {
  const N = frame.length;
  const windowed = new Float32Array(N);

  for (let i = 0; i < N; i++) {
    const window = 0.5 * (1 - Math.cos((2 * Math.PI * i) / (N - 1)));
    windowed[i] = frame[i] * window;
  }

  return windowed;
}

/**
 * Compute magnitude spectrum from complex FFT output
 */
function computeMagnitude(complexOutput, isReal, fftSize) {
  // For real FFT: output is N/2+1 complex values
  // For complex FFT: output is N complex values, we only need first N/2+1
  const numBins = isReal ? fftSize / 2 + 1 : fftSize / 2 + 1;
  const magnitudes = new Float32Array(numBins);

  for (let i = 0; i < numBins; i++) {
    const re = complexOutput[i * 2];
    const im = complexOutput[i * 2 + 1];
    magnitudes[i] = Math.sqrt(re * re + im * im);
  }

  return magnitudes;
}

/**
 * Convert magnitude to decibels
 */
function magnitudeToDb(magnitude, minDb = -100) {
  const db = 20 * Math.log10(magnitude + 1e-10);
  return Math.max(db, minDb);
}

/**
 * Color scales for spectrogram rendering
 */
const COLOR_SCALES = {
  viridis: (t) => {
    // Simplified viridis approximation
    const r = Math.max(
      0,
      Math.min(255, Math.floor(255 * (0.267 + 0.329 * t + 2.66 * t * t - 2.35 * t * t * t))),
    );
    const g = Math.max(
      0,
      Math.min(255, Math.floor(255 * (0.004 + 1.42 * t - 1.54 * t * t + 0.69 * t * t * t))),
    );
    const b = Math.max(
      0,
      Math.min(255, Math.floor(255 * (0.329 + 1.42 * t - 2.49 * t * t + 1.33 * t * t * t))),
    );
    return [r, g, b];
  },
  magma: (t) => {
    // Simplified magma approximation
    const r = Math.max(0, Math.min(255, Math.floor(255 * (0.001 + 1.06 * t + 0.19 * t * t))));
    const g = Math.max(
      0,
      Math.min(255, Math.floor(255 * (0.001 + 0.55 * t + 0.87 * t * t - 0.43 * t * t * t))),
    );
    const b = Math.max(
      0,
      Math.min(255, Math.floor(255 * (0.014 + 2.21 * t - 2.49 * t * t + 1.17 * t * t * t))),
    );
    return [r, g, b];
  },
  grayscale: (t) => {
    const v = Math.floor(255 * t);
    return [v, v, v];
  },
};

/**
 * Generate spectrogram data
 *
 * @param {Object} options
 * @param {Float32Array} options.samples - Audio samples
 * @param {number} options.sampleRate - Sample rate
 * @param {Object} options.fftContext - FFT context from createFFTContext
 * @param {number} options.hopSize - Hop size between frames
 * @returns {Object} - Spectrogram data and timing info
 */
export function generateSpectrogram({ samples, sampleRate, fftContext, hopSize }) {
  const { size: fftSize, isReal } = fftContext;
  const numBins = fftSize / 2 + 1;

  // Calculate number of frames
  const numFrames = Math.floor((samples.length - fftSize) / hopSize) + 1;

  if (numFrames <= 0) {
    throw new Error("Audio too short for the given FFT size");
  }

  // Allocate spectrogram data
  const spectrogram = new Float32Array(numFrames * numBins);

  // Timing
  let fftTime = 0;
  const startTime = performance.now();

  for (let frame = 0; frame < numFrames; frame++) {
    const offset = frame * hopSize;

    // Extract and window the frame
    const frameData = samples.slice(offset, offset + fftSize);
    const windowed = applyHannWindow(frameData);

    // Copy to FFT input buffer
    const inputBuffer = fftContext.getInputBuffer();

    if (isReal) {
      // Real FFT: just copy the windowed samples
      inputBuffer.set(windowed);
    } else {
      // Complex FFT: interleave with zeros for imaginary part
      for (let i = 0; i < fftSize; i++) {
        inputBuffer[i * 2] = windowed[i];
        inputBuffer[i * 2 + 1] = 0;
      }
    }

    // Run FFT
    const fftStart = performance.now();
    fftContext.run();
    fftTime += performance.now() - fftStart;

    // Get output and compute magnitude
    const outputBuffer = fftContext.getOutputBuffer();
    const magnitudes = computeMagnitude(outputBuffer, isReal, fftSize);

    // Store magnitudes (convert to dB)
    for (let bin = 0; bin < numBins; bin++) {
      const db = magnitudeToDb(magnitudes[bin]);
      // Normalize to 0-1 range (assuming -100dB to 0dB range)
      spectrogram[frame * numBins + bin] = (db + 100) / 100;
    }
  }

  const totalTime = performance.now() - startTime;

  return {
    data: spectrogram,
    numFrames,
    numBins,
    fftSize,
    hopSize,
    sampleRate,
    duration: samples.length / sampleRate,
    timing: {
      fftTime,
      totalTime,
      fftsPerSecond: (numFrames / fftTime) * 1000,
    },
  };
}

/**
 * Render spectrogram to canvas
 *
 * @param {Object} options
 * @param {HTMLCanvasElement} options.canvas - Target canvas
 * @param {Object} options.spectrogram - Spectrogram data from generateSpectrogram
 * @param {string} options.colorScale - Color scale name
 */
export function renderSpectrogram({ canvas, spectrogram, colorScale = "viridis" }) {
  const ctx = canvas.getContext("2d");
  const { data, numFrames, numBins } = spectrogram;

  // Resize canvas to fit spectrogram
  canvas.width = numFrames;
  canvas.height = numBins;

  const imageData = ctx.createImageData(numFrames, numBins);
  const pixels = imageData.data;

  const colorFn = COLOR_SCALES[colorScale] || COLOR_SCALES.viridis;

  for (let frame = 0; frame < numFrames; frame++) {
    for (let bin = 0; bin < numBins; bin++) {
      const value = Math.max(0, Math.min(1, data[frame * numBins + bin]));
      const [r, g, b] = colorFn(value);

      // Flip vertically (low frequencies at bottom)
      const y = numBins - 1 - bin;
      const pixelIndex = (y * numFrames + frame) * 4;

      pixels[pixelIndex] = r;
      pixels[pixelIndex + 1] = g;
      pixels[pixelIndex + 2] = b;
      pixels[pixelIndex + 3] = 255;
    }
  }

  ctx.putImageData(imageData, 0, 0);
}
