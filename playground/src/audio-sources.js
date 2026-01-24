/**
 * Audio Source Generators
 *
 * Provides various audio sources for FFT testing:
 * - Synthetic sine wave combinations (using OfflineAudioContext)
 * - Audio file loading
 */

/**
 * Generate synthetic audio using OfflineAudioContext
 * This uses the Web Audio API to generate precise sine waves
 *
 * @param {Object} options
 * @param {number} options.sampleRate - Sample rate in Hz
 * @param {number} options.duration - Duration in seconds
 * @param {Array<{frequency: number, amplitude: number, phase?: number}>} options.components - Sine wave components
 * @returns {Promise<Float32Array>} - Audio samples
 */
export async function generateSyntheticAudio({ sampleRate, duration, components }) {
  const numSamples = Math.floor(sampleRate * duration);

  // Use OfflineAudioContext for precise generation
  const offlineCtx = new OfflineAudioContext(1, numSamples, sampleRate);

  // Create oscillators for each component
  for (const component of components) {
    const oscillator = offlineCtx.createOscillator();
    const gainNode = offlineCtx.createGain();

    oscillator.type = "sine";
    oscillator.frequency.value = component.frequency;
    gainNode.gain.value = component.amplitude;

    oscillator.connect(gainNode);
    gainNode.connect(offlineCtx.destination);

    oscillator.start(0);
    oscillator.stop(duration);
  }

  // Render the audio
  const audioBuffer = await offlineCtx.startRendering();
  return audioBuffer.getChannelData(0);
}

/**
 * Generate synthetic audio using pure JavaScript (fallback)
 * Use this if OfflineAudioContext is not available
 *
 * @param {Object} options
 * @param {number} options.sampleRate - Sample rate in Hz
 * @param {number} options.duration - Duration in seconds
 * @param {Array<{frequency: number, amplitude: number, phase?: number}>} options.components - Sine wave components
 * @returns {Float32Array} - Audio samples
 */
export function generateSyntheticAudioJS({ sampleRate, duration, components }) {
  const numSamples = Math.floor(sampleRate * duration);
  const samples = new Float32Array(numSamples);

  for (let i = 0; i < numSamples; i++) {
    const t = i / sampleRate;
    let value = 0;

    for (const component of components) {
      const phase = component.phase || 0;
      value += component.amplitude * Math.sin(2 * Math.PI * component.frequency * t + phase);
    }

    samples[i] = value;
  }

  return samples;
}

/**
 * Load audio from a file
 *
 * @param {File} file - Audio file
 * @param {number} targetSampleRate - Target sample rate for resampling
 * @returns {Promise<{samples: Float32Array, sampleRate: number, duration: number}>}
 */
export async function loadAudioFile(file, targetSampleRate = 44100) {
  const arrayBuffer = await file.arrayBuffer();
  const audioCtx = new AudioContext({ sampleRate: targetSampleRate });

  try {
    const audioBuffer = await audioCtx.decodeAudioData(arrayBuffer);
    const samples = audioBuffer.getChannelData(0); // Get first channel (mono)

    return {
      samples: new Float32Array(samples), // Copy to avoid issues when context closes
      sampleRate: audioBuffer.sampleRate,
      duration: audioBuffer.duration,
    };
  } finally {
    await audioCtx.close();
  }
}

/**
 * Preset sine wave configurations for testing
 */
export const PRESET_CONFIGS = {
  singleTone: {
    name: "Single 440Hz Tone",
    components: [{ frequency: 440, amplitude: 0.5 }],
  },
  chord: {
    name: "Major Chord (C-E-G)",
    components: [
      { frequency: 261.63, amplitude: 0.3 }, // C4
      { frequency: 329.63, amplitude: 0.3 }, // E4
      { frequency: 392.0, amplitude: 0.3 }, // G4
    ],
  },
  harmonics: {
    name: "Fundamental + Harmonics",
    components: [
      { frequency: 220, amplitude: 0.4 }, // A3
      { frequency: 440, amplitude: 0.3 }, // A4 (2nd harmonic)
      { frequency: 660, amplitude: 0.2 }, // E5 (3rd harmonic)
      { frequency: 880, amplitude: 0.1 }, // A5 (4th harmonic)
    ],
  },
  sweep: {
    name: "Low + Mid + High",
    components: [
      { frequency: 100, amplitude: 0.3 },
      { frequency: 1000, amplitude: 0.3 },
      { frequency: 5000, amplitude: 0.3 },
    ],
  },
  beating: {
    name: "Beating (440Hz + 442Hz)",
    components: [
      { frequency: 440, amplitude: 0.4 },
      { frequency: 442, amplitude: 0.4 },
    ],
  },
};
