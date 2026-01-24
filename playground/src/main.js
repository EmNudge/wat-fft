/**
 * wat-fft Playground - Main Entry Point
 * Real-time FFT performance comparison with automatic regeneration
 */

import { loadFFTModule, createFFTContext } from "./fft-loader.js";
import { generateSyntheticAudio, loadAudioFile } from "./audio-sources.js";
import { generateSpectrogram, renderSpectrogram } from "./spectrogram.js";

// State
let currentModule = null;
let currentModuleId = "combined";
let colorScale = "viridis";
let sourceType = "synthetic";
let loadedAudioSamples = null;
let isProcessing = false;
let pendingRegenerate = false;

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
    option.addEventListener("click", () => {
      const source = option.dataset.source;
      if (source === sourceType) return;

      options.forEach((o) => o.classList.remove("selected"));
      option.classList.add("selected");

      sourceType = source;
      elements.syntheticControls.classList.toggle("hidden", source !== "synthetic");
      elements.fileControls.classList.toggle("hidden", source !== "file");

      if (source === "synthetic" || loadedAudioSamples) {
        triggerRegenerate();
      }
    });
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

    // Ensure hop size doesn't exceed FFT size
    const effectiveHopSize = Math.min(hopSize, fftSize);

    const fftContext = createFFTContext(currentModule, fftSize);

    const spectrogram = generateSpectrogram({
      samples,
      sampleRate,
      fftContext,
      hopSize: effectiveHopSize,
    });

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
    });
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
  setupFileInput();
  renderSineComponents();

  // Initialize display values
  elements.fftSizeValue.textContent = Math.pow(2, parseInt(elements.fftSize.value));
  elements.hopSizeValue.textContent = Math.pow(2, parseInt(elements.hopSize.value));
  elements.durationValue.textContent = parseFloat(elements.duration.value).toFixed(2) + "s";
  const sampleRateIndex = parseInt(elements.sampleRate.value);
  elements.sampleRateValue.textContent = (SAMPLE_RATES[sampleRateIndex] / 1000).toFixed(1) + "k";

  // Load default module and generate
  try {
    currentModule = await loadFFTModule(currentModuleId);
    updateImplName();
    generate();
  } catch (err) {
    console.error("Failed to load default module:", err);
  }
}

init();
