/**
 * wat-fft Playground - Main Entry Point
 * Real-time FFT performance comparison with automatic regeneration
 */

import { loadFFTModule, createFFTContext } from "./fft-loader.js";
import { generateSyntheticAudio, loadAudioFile, loadAudioFromUrl } from "./audio-sources.js";
import { generateSpectrogram, renderSpectrogram, analyzeFrequencyRange } from "./spectrogram.js";
import SAMPLE_FILES from "virtual:sample-files";

// State
let currentModule = null;
let currentModuleId = "combined";
let colorScale = "magma";
let freqScale = "log";
let minFreq = 50;
let maxFreq = 8000;
let windowType = "hann";
let zeroPadding = 2;
let gain = -20;
let range = 80;
let sourceType = SAMPLE_FILES.length > 0 ? "file" : "synthetic";
let loadedAudioSamples = null;
let isProcessing = false;
let pendingRegenerate = false;
let lastSpectrogram = null;

// Sine wave components
let sineComponents = [
  { frequency: 440, amplitude: 0.5 },
  { frequency: 880, amplitude: 0.3 },
  { frequency: 1320, amplitude: 0.15 },
];

// Sample rate options
const SAMPLE_RATES = [22050, 44100, 48000];

// DOM Elements
const elements = {
  processing: document.getElementById("processing"),
  fftSelector: document.getElementById("fft-selector"),
  fftSize: document.getElementById("fft-size"),
  fftSizeValue: document.getElementById("fft-size-value"),
  hopSize: document.getElementById("hop-size"),
  hopSizeValue: document.getElementById("hop-size-value"),
  zeroPadding: document.getElementById("zero-padding"),
  zeroPaddingValue: document.getElementById("zero-padding-value"),
  windowType: document.getElementById("window-type"),
  gain: document.getElementById("gain"),
  gainValue: document.getElementById("gain-value"),
  range: document.getElementById("range"),
  rangeValue: document.getElementById("range-value"),
  freqScaleSelector: document.getElementById("freq-scale-selector"),
  minFreq: document.getElementById("min-freq"),
  minFreqValue: document.getElementById("min-freq-value"),
  maxFreq: document.getElementById("max-freq"),
  maxFreqValue: document.getElementById("max-freq-value"),
  autoFreq: document.getElementById("auto-freq"),
  freqLabelTop: document.getElementById("freq-label-top"),
  freqLabelBottom: document.getElementById("freq-label-bottom"),
  colorSelector: document.getElementById("color-selector"),
  sourceToggle: document.getElementById("source-toggle"),
  syntheticControls: document.getElementById("synthetic-controls"),
  fileControls: document.getElementById("file-controls"),
  duration: document.getElementById("duration"),
  durationValue: document.getElementById("duration-value"),
  sampleRate: document.getElementById("sample-rate"),
  sampleRateValue: document.getElementById("sample-rate-value"),
  sineComponentsContainer: document.getElementById("sine-components"),
  addSineBtn: document.getElementById("add-sine"),
  addHarmonicBtn: document.getElementById("add-harmonic"),
  sampleFile: document.getElementById("sample-file"),
  audioFile: document.getElementById("audio-file"),
  canvas: document.getElementById("spectrogram"),
  implName: document.getElementById("impl-name"),
  stats: {
    fftTime: document.getElementById("stat-fft-time"),
    totalTime: document.getElementById("stat-total-time"),
    fftsPerSec: document.getElementById("stat-ffts-per-sec"),
    frames: document.getElementById("stat-frames"),
  },
};

// Debounce helper
function debounce(fn, delay) {
  let timeout;
  return (...args) => {
    clearTimeout(timeout);
    timeout = setTimeout(() => fn(...args), delay);
  };
}

// Format frequency for display
function formatFreq(hz) {
  if (hz >= 1000) {
    return (hz / 1000).toFixed(1) + " kHz";
  }
  return hz + " Hz";
}

// Update frequency labels
function updateFreqLabels() {
  elements.freqLabelTop.textContent = formatFreq(maxFreq);
  elements.freqLabelBottom.textContent = formatFreq(minFreq);
}

// Show/hide processing indicator
function setProcessing(processing) {
  isProcessing = processing;
  elements.processing.classList.toggle("visible", processing);
}

// Schedule regeneration (with debouncing for rapid changes)
const scheduleRegenerate = debounce(() => {
  if (!isProcessing) {
    generate();
  } else {
    pendingRegenerate = true;
  }
}, 50);

// Trigger immediate regeneration
function triggerRegenerate() {
  scheduleRegenerate();
}

// Update the implementation name display
function updateImplName() {
  if (!currentModule) return;
  const { name } = currentModule.config;
  const isAlt = !currentModule.config.isWatFft;
  elements.implName.textContent = name;
  elements.implName.classList.toggle("alt", isAlt);
}

// FFT Module Selection
function setupFFTSelector() {
  const options = elements.fftSelector.querySelectorAll(".fft-option");

  options.forEach((option) => {
    option.addEventListener("click", async () => {
      const moduleId = option.dataset.fft;
      if (moduleId === currentModuleId) return;

      options.forEach((o) => o.classList.remove("selected"));
      option.classList.add("selected");

      try {
        currentModule = await loadFFTModule(moduleId);
        currentModuleId = moduleId;
        updateImplName();
        triggerRegenerate();
      } catch (err) {
        console.error("Failed to load module:", err);
      }
    });
  });
}

// Zero padding factor options
const ZERO_PADDING_OPTIONS = [1, 2, 4];

// Spectrogram settings
function setupSpectrogramControls() {
  // FFT Size slider (powers of 2)
  elements.fftSize.addEventListener("input", () => {
    const value = Math.pow(2, parseInt(elements.fftSize.value));
    elements.fftSizeValue.textContent = value;
    triggerRegenerate();
  });

  // Hop Size slider (powers of 2)
  elements.hopSize.addEventListener("input", () => {
    const value = Math.pow(2, parseInt(elements.hopSize.value));
    elements.hopSizeValue.textContent = value;
    triggerRegenerate();
  });

  // Zero padding factor
  elements.zeroPadding.addEventListener("input", () => {
    const index = parseInt(elements.zeroPadding.value);
    zeroPadding = ZERO_PADDING_OPTIONS[index];
    elements.zeroPaddingValue.textContent = zeroPadding + "x";
    triggerRegenerate();
  });

  // Window type
  elements.windowType.addEventListener("change", () => {
    windowType = elements.windowType.value;
    triggerRegenerate();
  });

  // Gain
  elements.gain.addEventListener("input", () => {
    gain = parseInt(elements.gain.value);
    elements.gainValue.textContent = gain + " dB";
    triggerRegenerate();
  });

  // Range
  elements.range.addEventListener("input", () => {
    range = parseInt(elements.range.value);
    elements.rangeValue.textContent = range + " dB";
    triggerRegenerate();
  });

  // Frequency scale
  const freqScaleOptions = elements.freqScaleSelector.querySelectorAll(".color-option");
  freqScaleOptions.forEach((option) => {
    option.addEventListener("click", () => {
      freqScaleOptions.forEach((o) => o.classList.remove("selected"));
      option.classList.add("selected");
      freqScale = option.dataset.scale;
      triggerRegenerate();
    });
  });

  // Min frequency
  elements.minFreq.addEventListener("input", () => {
    minFreq = parseInt(elements.minFreq.value);
    elements.minFreqValue.textContent = minFreq + " Hz";
    triggerRegenerate();
  });

  // Max frequency
  elements.maxFreq.addEventListener("input", () => {
    maxFreq = parseInt(elements.maxFreq.value);
    elements.maxFreqValue.textContent = formatFreq(maxFreq);
    triggerRegenerate();
  });

  // Auto-detect frequency range
  elements.autoFreq.addEventListener("click", () => {
    if (!lastSpectrogram) return;

    const { minFreq: detectedMin, maxFreq: detectedMax } = analyzeFrequencyRange(lastSpectrogram);

    // Update state
    minFreq = detectedMin;
    maxFreq = detectedMax;

    // Update sliders
    elements.minFreq.value = minFreq;
    elements.minFreqValue.textContent = minFreq + " Hz";
    elements.maxFreq.value = maxFreq;
    elements.maxFreqValue.textContent = formatFreq(maxFreq);

    triggerRegenerate();
  });

  // Color scale
  const colorOptions = elements.colorSelector.querySelectorAll(".color-option");
  colorOptions.forEach((option) => {
    option.addEventListener("click", () => {
      colorOptions.forEach((o) => o.classList.remove("selected"));
      option.classList.add("selected");
      colorScale = option.dataset.color;
      triggerRegenerate();
    });
  });
}

// Audio source toggle
function setupSourceToggle() {
  const options = elements.sourceToggle.querySelectorAll(".source-option");

  options.forEach((option) => {
    option.addEventListener("click", async () => {
      const source = option.dataset.source;
      if (source === sourceType) return;

      options.forEach((o) => o.classList.remove("selected"));
      option.classList.add("selected");

      sourceType = source;
      elements.syntheticControls.classList.toggle("hidden", source !== "synthetic");
      elements.fileControls.classList.toggle("hidden", source !== "file");

      if (source === "synthetic") {
        triggerRegenerate();
      } else if (source === "file") {
        // Auto-load first sample file if available and no audio loaded yet
        if (!loadedAudioSamples && SAMPLE_FILES.length > 0) {
          elements.sampleFile.value = SAMPLE_FILES[0].value;
          await loadSampleFile(SAMPLE_FILES[0].value);
        } else if (loadedAudioSamples) {
          triggerRegenerate();
        }
      }
    });
  });
}

// Load a sample file from URL
async function loadSampleFile(url) {
  if (!url) return;

  try {
    setProcessing(true);
    const sampleRateIndex = parseInt(elements.sampleRate.value);
    const targetRate = SAMPLE_RATES[sampleRateIndex];
    const result = await loadAudioFromUrl(url, targetRate);
    loadedAudioSamples = result;
    triggerRegenerate();
  } catch (err) {
    console.error("Failed to load sample file:", err);
  } finally {
    setProcessing(false);
  }
}

// Setup sample file selector
function setupSampleFileSelector() {
  // Populate dropdown with discovered sample files
  const sampleSection = document.getElementById("sample-file-section");

  if (SAMPLE_FILES.length === 0) {
    // Hide sample section if no samples found
    if (sampleSection) sampleSection.classList.add("hidden");
    return;
  }

  // Add options to the select
  for (const sample of SAMPLE_FILES) {
    const option = document.createElement("option");
    option.value = sample.value;
    option.textContent = sample.label;
    elements.sampleFile.appendChild(option);
  }

  elements.sampleFile.addEventListener("change", async () => {
    const url = elements.sampleFile.value;
    if (url) {
      // Clear any uploaded file selection
      elements.audioFile.value = "";
      await loadSampleFile(url);
    }
  });
}

// Synthetic audio controls
function setupSyntheticControls() {
  // Duration slider
  elements.duration.addEventListener("input", () => {
    const value = parseFloat(elements.duration.value);
    elements.durationValue.textContent = value.toFixed(2) + "s";
    triggerRegenerate();
  });

  // Sample rate slider
  elements.sampleRate.addEventListener("input", () => {
    const index = parseInt(elements.sampleRate.value);
    const rate = SAMPLE_RATES[index];
    elements.sampleRateValue.textContent = (rate / 1000).toFixed(1) + "k";
    triggerRegenerate();
  });

  // Add sine wave
  elements.addSineBtn.addEventListener("click", () => {
    sineComponents.push({ frequency: 440, amplitude: 0.3 });
    renderSineComponents();
    triggerRegenerate();
  });

  // Add harmonic
  elements.addHarmonicBtn.addEventListener("click", () => {
    const baseFreq = sineComponents[0]?.frequency || 440;
    const harmonic = sineComponents.length + 1;
    sineComponents.push({
      frequency: Math.round(baseFreq * harmonic),
      amplitude: Math.max(0.05, 0.5 / harmonic),
    });
    renderSineComponents();
    triggerRegenerate();
  });
}

// Render sine wave component controls
function renderSineComponents() {
  elements.sineComponentsContainer.innerHTML = "";

  sineComponents.forEach((component, index) => {
    const div = document.createElement("div");
    div.className = "sine-component";

    div.innerHTML = `
      <div class="sine-header">
        <span>Wave ${index + 1}</span>
        <button class="small danger remove-btn" ${sineComponents.length <= 1 ? "disabled" : ""}>Remove</button>
      </div>
      <div class="slider-row">
        <label>Freq</label>
        <input type="range" class="freq-slider" min="20" max="8000" value="${component.frequency}" step="1" />
        <span class="slider-value freq-value">${component.frequency} Hz</span>
      </div>
      <div class="slider-row">
        <label>Amp</label>
        <input type="range" class="amp-slider" min="0" max="100" value="${Math.round(component.amplitude * 100)}" step="1" />
        <span class="slider-value amp-value">${(component.amplitude * 100).toFixed(0)}%</span>
      </div>
    `;

    const freqSlider = div.querySelector(".freq-slider");
    const freqValue = div.querySelector(".freq-value");
    const ampSlider = div.querySelector(".amp-slider");
    const ampValue = div.querySelector(".amp-value");
    const removeBtn = div.querySelector(".remove-btn");

    freqSlider.addEventListener("input", () => {
      component.frequency = parseInt(freqSlider.value);
      freqValue.textContent = component.frequency + " Hz";
      triggerRegenerate();
    });

    ampSlider.addEventListener("input", () => {
      component.amplitude = parseInt(ampSlider.value) / 100;
      ampValue.textContent = Math.round(component.amplitude * 100) + "%";
      triggerRegenerate();
    });

    removeBtn.addEventListener("click", () => {
      if (sineComponents.length > 1) {
        sineComponents.splice(index, 1);
        renderSineComponents();
        triggerRegenerate();
      }
    });

    elements.sineComponentsContainer.appendChild(div);
  });
}

// File input handling
function setupFileInput() {
  elements.audioFile.addEventListener("change", async () => {
    const file = elements.audioFile.files[0];
    if (!file) return;

    // Clear sample file selection when uploading a custom file
    elements.sampleFile.value = "";

    try {
      setProcessing(true);
      const sampleRateIndex = parseInt(elements.sampleRate.value);
      const targetRate = SAMPLE_RATES[sampleRateIndex];
      const result = await loadAudioFile(file, targetRate);
      loadedAudioSamples = result;
      triggerRegenerate();
    } catch (err) {
      console.error("Failed to load audio file:", err);
    } finally {
      setProcessing(false);
    }
  });
}

// Get current audio samples
async function getAudioSamples() {
  const sampleRateIndex = parseInt(elements.sampleRate.value);
  const sampleRate = SAMPLE_RATES[sampleRateIndex];
  const duration = parseFloat(elements.duration.value);

  if (sourceType === "synthetic") {
    const samples = await generateSyntheticAudio({
      sampleRate,
      duration,
      components: sineComponents,
    });
    return { samples, sampleRate };
  } else {
    if (!loadedAudioSamples) {
      throw new Error("No audio file loaded");
    }
    return {
      samples: loadedAudioSamples.samples,
      sampleRate: loadedAudioSamples.sampleRate,
    };
  }
}

// Main generation function
async function generate() {
  if (!currentModule) {
    console.error("No FFT module loaded");
    return;
  }

  if (isProcessing) {
    pendingRegenerate = true;
    return;
  }

  setProcessing(true);

  try {
    const { samples, sampleRate } = await getAudioSamples();

    const fftSize = Math.pow(2, parseInt(elements.fftSize.value));
    const hopSize = Math.pow(2, parseInt(elements.hopSize.value));

    // Ensure hop size doesn't exceed FFT size (adjusted for zero padding)
    const windowSize = Math.floor(fftSize / zeroPadding);
    const effectiveHopSize = Math.min(hopSize, windowSize);

    const fftContext = createFFTContext(currentModule, fftSize);

    const spectrogram = generateSpectrogram({
      samples,
      sampleRate,
      fftContext,
      hopSize: effectiveHopSize,
      windowType,
      zeroPadding,
      gain,
      range,
    });

    // Store for auto-detection
    lastSpectrogram = spectrogram;

    // Update stats
    elements.stats.fftTime.textContent = spectrogram.timing.fftTime.toFixed(1);
    elements.stats.totalTime.textContent = spectrogram.timing.totalTime.toFixed(1);
    elements.stats.fftsPerSec.textContent = Math.round(
      spectrogram.timing.fftsPerSecond,
    ).toLocaleString();
    elements.stats.frames.textContent = spectrogram.numFrames.toLocaleString();

    // Render
    renderSpectrogram({
      canvas: elements.canvas,
      spectrogram,
      colorScale,
      freqScale,
      minFreq,
      maxFreq,
    });

    // Update frequency labels
    updateFreqLabels();
  } catch (err) {
    console.error("Generation error:", err);
  } finally {
    setProcessing(false);

    // Check if another regeneration was requested while processing
    if (pendingRegenerate) {
      pendingRegenerate = false;
      setTimeout(generate, 10);
    }
  }
}

// Initialize
async function init() {
  setupFFTSelector();
  setupSpectrogramControls();
  setupSourceToggle();
  setupSyntheticControls();
  setupSampleFileSelector();
  setupFileInput();
  renderSineComponents();

  // Initialize display values
  elements.fftSizeValue.textContent = Math.pow(2, parseInt(elements.fftSize.value));
  elements.hopSizeValue.textContent = Math.pow(2, parseInt(elements.hopSize.value));
  elements.zeroPaddingValue.textContent =
    ZERO_PADDING_OPTIONS[parseInt(elements.zeroPadding.value)] + "x";
  elements.gainValue.textContent = elements.gain.value + " dB";
  elements.rangeValue.textContent = elements.range.value + " dB";
  elements.durationValue.textContent = parseFloat(elements.duration.value).toFixed(2) + "s";
  const sampleRateIndex = parseInt(elements.sampleRate.value);
  elements.sampleRateValue.textContent = (SAMPLE_RATES[sampleRateIndex] / 1000).toFixed(1) + "k";

  // Set initial source type UI state
  const sourceOptions = elements.sourceToggle.querySelectorAll(".source-option");
  sourceOptions.forEach((o) => {
    o.classList.toggle("selected", o.dataset.source === sourceType);
  });
  elements.syntheticControls.classList.toggle("hidden", sourceType !== "synthetic");
  elements.fileControls.classList.toggle("hidden", sourceType !== "file");

  // Load default module
  try {
    currentModule = await loadFFTModule(currentModuleId);
    updateImplName();
  } catch (err) {
    console.error("Failed to load default module:", err);
    return;
  }

  // Load first sample file if using file source, otherwise generate synthetic
  if (sourceType === "file" && SAMPLE_FILES.length > 0) {
    elements.sampleFile.value = SAMPLE_FILES[0].value;
    await loadSampleFile(SAMPLE_FILES[0].value);
  } else {
    generate();
  }
}

init();
