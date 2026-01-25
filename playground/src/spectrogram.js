/**
 * Spectrogram Generator
 *
 * Audacity-style spectrogram with:
 * - Zero-padding for frequency interpolation
 * - Multiple window functions
 * - Gain/range controls
 * - Frequency scale options (linear, log, mel)
 * - Professional color gradients
 */

/**
 * Window functions
 */
const WINDOW_FUNCTIONS = {
  hann: (i, N) => 0.5 * (1 - Math.cos((2 * Math.PI * i) / (N - 1))),
  hamming: (i, N) => 0.54 - 0.46 * Math.cos((2 * Math.PI * i) / (N - 1)),
  blackman: (i, N) =>
    0.42 -
    0.5 * Math.cos((2 * Math.PI * i) / (N - 1)) +
    0.08 * Math.cos((4 * Math.PI * i) / (N - 1)),
  blackmanHarris: (i, N) => {
    const a0 = 0.35875,
      a1 = 0.48829,
      a2 = 0.14128,
      a3 = 0.01168;
    return (
      a0 -
      a1 * Math.cos((2 * Math.PI * i) / (N - 1)) +
      a2 * Math.cos((4 * Math.PI * i) / (N - 1)) -
      a3 * Math.cos((6 * Math.PI * i) / (N - 1))
    );
  },
  rectangular: () => 1,
};

/**
 * Apply window function to a frame
 */
function applyWindow(frame, windowType = "hann") {
  const N = frame.length;
  const windowed = new Float32Array(N);
  const windowFn = WINDOW_FUNCTIONS[windowType] || WINDOW_FUNCTIONS.hann;

  for (let i = 0; i < N; i++) {
    windowed[i] = frame[i] * windowFn(i, N);
  }

  return windowed;
}

/**
 * Zero-pad a frame to a target size
 */
function zeroPad(frame, targetSize) {
  if (frame.length >= targetSize) return frame;
  const padded = new Float32Array(targetSize);
  padded.set(frame);
  return padded;
}

/**
 * Compute magnitude spectrum from complex FFT output
 */
function computeMagnitude(complexOutput, isReal, fftSize) {
  const numBins = fftSize / 2 + 1;
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
function magnitudeToDb(magnitude) {
  return 20 * Math.log10(magnitude + 1e-10);
}

/**
 * Frequency scale conversions
 */
function hzToMel(hz) {
  return 2595 * Math.log10(1 + hz / 700);
}

function melToHz(mel) {
  return 700 * (Math.pow(10, mel / 2595) - 1);
}

/**
 * Create frequency bin mapping for different scales
 */
function createFrequencyMapping(
  numBins,
  sampleRate,
  fftSize,
  scale,
  displayBins,
  minFreq,
  maxFreq,
) {
  const nyquist = sampleRate / 2;
  const effectiveMinFreq = Math.max(minFreq || 20, 1);
  const effectiveMaxFreq = Math.min(maxFreq || nyquist, nyquist);

  if (scale === "linear") {
    // For linear scale with freq limits, we need a mapping
    const mapping = new Float32Array(displayBins);
    for (let i = 0; i < displayBins; i++) {
      const hz = effectiveMinFreq + (i / (displayBins - 1)) * (effectiveMaxFreq - effectiveMinFreq);
      mapping[i] = (hz / nyquist) * (numBins - 1);
    }
    return mapping;
  }

  const mapping = new Float32Array(displayBins);

  if (scale === "log") {
    const logMin = Math.log10(effectiveMinFreq);
    const logMax = Math.log10(effectiveMaxFreq);

    for (let i = 0; i < displayBins; i++) {
      const logHz = logMin + (i / (displayBins - 1)) * (logMax - logMin);
      const hz = Math.pow(10, logHz);
      mapping[i] = (hz / nyquist) * (numBins - 1);
    }
  } else if (scale === "mel") {
    const minMel = hzToMel(effectiveMinFreq);
    const maxMel = hzToMel(effectiveMaxFreq);

    for (let i = 0; i < displayBins; i++) {
      const mel = minMel + (i / (displayBins - 1)) * (maxMel - minMel);
      const hz = melToHz(mel);
      mapping[i] = (hz / nyquist) * (numBins - 1);
    }
  }

  return mapping;
}

/**
 * Interpolate spectrum using frequency mapping
 */
function remapSpectrum(spectrum, mapping, displayBins) {
  if (!mapping) return spectrum;

  const remapped = new Float32Array(displayBins);

  for (let i = 0; i < displayBins; i++) {
    const srcBin = mapping[i];
    const binLow = Math.floor(srcBin);
    const binHigh = Math.min(binLow + 1, spectrum.length - 1);
    const frac = srcBin - binLow;

    // Linear interpolation between bins
    remapped[i] = spectrum[binLow] * (1 - frac) + spectrum[binHigh] * frac;
  }

  return remapped;
}

/**
 * Color scales for spectrogram rendering
 */
const COLOR_SCALES = {
  // Audacity-style: Blue → Cyan → Green → Yellow → Red → White
  audacity: (t) => {
    if (t < 0.2) {
      // Black to Blue
      const s = t / 0.2;
      return [0, 0, Math.floor(255 * s)];
    } else if (t < 0.4) {
      // Blue to Cyan
      const s = (t - 0.2) / 0.2;
      return [0, Math.floor(255 * s), 255];
    } else if (t < 0.6) {
      // Cyan to Green
      const s = (t - 0.4) / 0.2;
      return [0, 255, Math.floor(255 * (1 - s))];
    } else if (t < 0.8) {
      // Green to Yellow
      const s = (t - 0.6) / 0.2;
      return [Math.floor(255 * s), 255, 0];
    } else {
      // Yellow to White
      const s = (t - 0.8) / 0.2;
      return [255, 255, Math.floor(255 * s)];
    }
  },
  viridis: (t) => {
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
    // Attempt to match Audacity's inferno-like purple → orange → white
    if (t < 0.25) {
      // Black to dark purple
      const s = t / 0.25;
      return [Math.floor(20 * s), 0, Math.floor(80 * s)];
    } else if (t < 0.5) {
      // Dark purple to magenta/red
      const s = (t - 0.25) / 0.25;
      return [Math.floor(20 + 180 * s), 0, Math.floor(80 + 40 * s)];
    } else if (t < 0.75) {
      // Magenta to orange
      const s = (t - 0.5) / 0.25;
      return [Math.floor(200 + 55 * s), Math.floor(100 * s), Math.floor(120 * (1 - s))];
    } else {
      // Orange to white
      const s = (t - 0.75) / 0.25;
      return [255, Math.floor(100 + 155 * s), Math.floor(200 * s)];
    }
  },
  grayscale: (t) => {
    const v = Math.floor(255 * t);
    return [v, v, v];
  },
  // Hot: Black → Red → Yellow → White
  hot: (t) => {
    if (t < 0.33) {
      return [Math.floor(255 * (t / 0.33)), 0, 0];
    } else if (t < 0.67) {
      return [255, Math.floor(255 * ((t - 0.33) / 0.34)), 0];
    } else {
      return [255, 255, Math.floor(255 * ((t - 0.67) / 0.33))];
    }
  },
  // Inferno: Black → Purple → Red → Orange → Yellow (matplotlib inferno)
  inferno: (t) => {
    // Attempt to approximate matplotlib's inferno colormap
    if (t < 0.15) {
      const s = t / 0.15;
      return [Math.floor(10 + 50 * s), 0, Math.floor(20 + 60 * s)];
    } else if (t < 0.4) {
      const s = (t - 0.15) / 0.25;
      return [Math.floor(60 + 120 * s), Math.floor(20 * s), Math.floor(80 + 40 * s)];
    } else if (t < 0.65) {
      const s = (t - 0.4) / 0.25;
      return [Math.floor(180 + 60 * s), Math.floor(20 + 60 * s), Math.floor(120 - 100 * s)];
    } else if (t < 0.85) {
      const s = (t - 0.65) / 0.2;
      return [255, Math.floor(80 + 120 * s), Math.floor(20 - 20 * s)];
    } else {
      const s = (t - 0.85) / 0.15;
      return [255, Math.floor(200 + 55 * s), Math.floor(100 * s)];
    }
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
 * @param {string} options.windowType - Window function type
 * @param {number} options.zeroPadding - Zero padding factor (1, 2, 4, etc.)
 * @param {number} options.gain - Gain in dB (white point)
 * @param {number} options.range - Dynamic range in dB
 * @returns {Object} - Spectrogram data and timing info
 */
export function generateSpectrogram({
  samples,
  sampleRate,
  fftContext,
  hopSize,
  windowType = "hann",
  zeroPadding = 1,
  gain = 0,
  range = 80,
}) {
  const { size: fftSize, isReal } = fftContext;
  const windowSize = Math.floor(fftSize / zeroPadding);
  const numBins = fftSize / 2 + 1;

  // Calculate number of frames based on window size (not padded FFT size)
  const numFrames = Math.floor((samples.length - windowSize) / hopSize) + 1;

  if (numFrames <= 0) {
    throw new Error("Audio too short for the given FFT size");
  }

  // Allocate spectrogram data (in dB)
  const spectrogram = new Float32Array(numFrames * numBins);

  // Timing
  let fftTime = 0;
  const startTime = performance.now();

  for (let frame = 0; frame < numFrames; frame++) {
    const offset = frame * hopSize;

    // Extract frame at window size (before zero-padding)
    const frameData = samples.slice(offset, offset + windowSize);

    // Apply window function
    const windowed = applyWindow(frameData, windowType);

    // Zero-pad if needed
    const padded = zeroPadding > 1 ? zeroPad(windowed, fftSize) : windowed;

    // Copy to FFT input buffer
    const inputBuffer = fftContext.getInputBuffer();

    if (isReal) {
      inputBuffer.set(padded);
    } else {
      for (let i = 0; i < fftSize; i++) {
        inputBuffer[i * 2] = padded[i] || 0;
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

    // Store magnitudes in dB with gain/range normalization
    // Skip DC bin (index 0) and near-DC bins to avoid DC offset issues
    const dcBinsToSkip = 3;
    for (let bin = 0; bin < numBins; bin++) {
      if (bin < dcBinsToSkip) {
        // Zero out DC and near-DC bins
        spectrogram[frame * numBins + bin] = 0;
        continue;
      }
      // Normalize magnitude by FFT size to get consistent dB values
      const normalizedMag = magnitudes[bin] / (fftSize / 2);
      const db = magnitudeToDb(normalizedMag);
      // Normalize: gain is white point, range is dynamic range
      // Values above gain become 1.0, values below (gain - range) become 0.0
      const normalized = (db - (gain - range)) / range;
      spectrogram[frame * numBins + bin] = Math.max(0, Math.min(1, normalized));
    }
  }

  const totalTime = performance.now() - startTime;

  return {
    data: spectrogram,
    numFrames,
    numBins,
    fftSize,
    windowSize,
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
 * @param {string} options.freqScale - Frequency scale (linear, log, mel)
 * @param {number} options.minFreq - Minimum frequency to display (Hz)
 * @param {number} options.maxFreq - Maximum frequency to display (Hz)
 */
export function renderSpectrogram({
  canvas,
  spectrogram,
  colorScale = "magma",
  freqScale = "log",
  minFreq = 50,
  maxFreq = 8000,
}) {
  const ctx = canvas.getContext("2d");
  const { data, numFrames, numBins, sampleRate, fftSize } = spectrogram;

  // Determine display height
  const displayBins = Math.min(numBins, 512);

  // Create frequency mapping
  const freqMapping = createFrequencyMapping(
    numBins,
    sampleRate,
    fftSize,
    freqScale,
    displayBins,
    minFreq,
    maxFreq,
  );

  // Resize canvas to fit spectrogram
  canvas.width = numFrames;
  canvas.height = displayBins;

  const imageData = ctx.createImageData(numFrames, displayBins);
  const pixels = imageData.data;

  const colorFn = COLOR_SCALES[colorScale] || COLOR_SCALES.audacity;

  for (let frame = 0; frame < numFrames; frame++) {
    // Get this frame's spectrum
    const frameOffset = frame * numBins;
    const frameSpectrum = data.slice(frameOffset, frameOffset + numBins);

    // Remap to display scale if needed
    const displaySpectrum = freqMapping
      ? remapSpectrum(frameSpectrum, freqMapping, displayBins)
      : frameSpectrum;

    for (let bin = 0; bin < displayBins; bin++) {
      const value = Math.max(0, Math.min(1, displaySpectrum[bin]));
      const [r, g, b] = colorFn(value);

      // High frequencies at top, low at bottom
      // In canvas, y=0 is top, so we map high bins (high freq) to low y values
      const y = displayBins - 1 - bin;
      const pixelIndex = (y * numFrames + frame) * 4;

      pixels[pixelIndex] = r;
      pixels[pixelIndex + 1] = g;
      pixels[pixelIndex + 2] = b;
      pixels[pixelIndex + 3] = 255;
    }
  }

  ctx.putImageData(imageData, 0, 0);
}

/**
 * Analyze spectrogram to find the frequency range with actual content
 * Returns suggested min/max frequencies based on energy distribution
 */
export function analyzeFrequencyRange(spectrogram) {
  const { data, numFrames, numBins, sampleRate } = spectrogram;
  const nyquist = sampleRate / 2;

  // Compute average energy per frequency bin across all frames
  const avgEnergy = new Float32Array(numBins);
  for (let bin = 0; bin < numBins; bin++) {
    let sum = 0;
    for (let frame = 0; frame < numFrames; frame++) {
      sum += data[frame * numBins + bin];
    }
    avgEnergy[bin] = sum / numFrames;
  }

  // Find the max energy and its location
  let maxEnergy = 0;
  let peakBin = 0;
  for (let bin = 0; bin < numBins; bin++) {
    if (avgEnergy[bin] > maxEnergy) {
      maxEnergy = avgEnergy[bin];
      peakBin = bin;
    }
  }

  if (maxEnergy === 0) {
    return { minFreq: 20, maxFreq: nyquist };
  }

  // Calculate noise floor as the median of the upper 25% of bins (typically just noise)
  const upperBins = avgEnergy.slice(Math.floor(numBins * 0.75));
  const sortedUpper = [...upperBins].sort((a, b) => a - b);
  const noiseFloor = sortedUpper[Math.floor(sortedUpper.length / 2)];

  // Threshold is noise floor + 20% of the dynamic range above noise
  const dynamicRange = maxEnergy - noiseFloor;
  const threshold = noiseFloor + dynamicRange * 0.15;

  // Find lowest bin with energy above threshold (start from DC, skip first few bins)
  let minBin = 3; // Skip DC bins
  for (let bin = 3; bin < peakBin; bin++) {
    if (avgEnergy[bin] > threshold) {
      minBin = bin;
      break;
    }
  }

  // Find highest bin with energy above threshold (search down from top)
  let maxBin = numBins - 1;
  for (let bin = numBins - 1; bin > peakBin; bin--) {
    if (avgEnergy[bin] > threshold) {
      maxBin = bin;
      break;
    }
  }

  // Convert bins to frequencies
  const binToHz = (bin) => (bin / (numBins - 1)) * nyquist;
  let minFreq = Math.floor(binToHz(minBin) / 10) * 10; // Round down to 10Hz
  let maxFreq = Math.ceil(binToHz(maxBin) / 100) * 100; // Round up to 100Hz

  // Ensure reasonable bounds
  minFreq = Math.max(20, minFreq);
  maxFreq = Math.min(nyquist, maxFreq);
  maxFreq = Math.max(minFreq + 500, maxFreq);

  return { minFreq, maxFreq };
}

export { WINDOW_FUNCTIONS, COLOR_SCALES };
