/**
 * wat-fft Playground - Main Entry Point
 * Real-time FFT performance comparison with automatic regeneration
 */

import { loadFFTModule, createFFTContext } from "./fft-loader.js";
import { generateSyntheticAudio, loadAudioFile, loadAudioFromUrl } from "./audio-sources.js";
import { generateSpectrogram, renderSpectrogram, analyzeFrequencyRange } from "./spectrogram.js";
import { SpectrumAnalyzer } from "./spectrum-analyzer.js";
import { LiveRecorder } from "./live-recorder.js";
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

// Analyzer state
let analyzerModule = null;
let analyzerModuleId = "real_f32_dual";
let analyzer = null;
let analyzerStatsInterval = null;
let currentMode = "spectrogram"; // "spectrogram" or "analyzer"

// Live recorder state
let liveRecorder = null;
let _recordTimeInterval = null;

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
  freqLabels: document.getElementById("freq-labels"),
  canvasContainer: document.querySelector(".canvas-container"),
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
  stretchIndicator: document.getElementById("stretch-indicator"),
  implName: document.getElementById("impl-name"),
  stats: {
    fftTime: document.getElementById("stat-fft-time"),
    totalTime: document.getElementById("stat-total-time"),
    fftsPerSec: document.getElementById("stat-ffts-per-sec"),
    frames: document.getElementById("stat-frames"),
  },
  // Analyzer elements
  analyzerToggle: document.getElementById("analyzer-toggle"),
  analyzerStatus: document.getElementById("analyzer-status"),
  analyzerFftSelector: document.getElementById("analyzer-fft-selector"),
  analyzerFftSize: document.getElementById("analyzer-fft-size"),
  analyzerFftSizeValue: document.getElementById("analyzer-fft-size-value"),
  analyzerSmoothing: document.getElementById("analyzer-smoothing"),
  analyzerSmoothingValue: document.getElementById("analyzer-smoothing-value"),
  analyzerMinFreq: document.getElementById("analyzer-min-freq"),
  analyzerMinFreqValue: document.getElementById("analyzer-min-freq-value"),
  analyzerMaxFreq: document.getElementById("analyzer-max-freq"),
  analyzerMaxFreqValue: document.getElementById("analyzer-max-freq-value"),
  analyzerMinDb: document.getElementById("analyzer-min-db"),
  analyzerMinDbValue: document.getElementById("analyzer-min-db-value"),
  analyzerMaxDb: document.getElementById("analyzer-max-db"),
  analyzerMaxDbValue: document.getElementById("analyzer-max-db-value"),
  displayModeSelector: document.getElementById("display-mode-selector"),
  analyzerColorSelector: document.getElementById("analyzer-color-selector"),
  // Record controls
  recordControls: document.getElementById("record-controls"),
  recordBtn: document.getElementById("record-btn"),
  pauseBtn: document.getElementById("pause-btn"),
  recordTime: document.getElementById("record-time"),
  recordIndicator: document.getElementById("record-indicator"),
  recordHint: document.getElementById("record-hint"),
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

// Standard frequency points for labeling (in Hz)
const FREQ_LABEL_POINTS = [20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000];

// Update frequency labels (generate and position)
function updateFreqLabels() {
  generateFreqLabels();
  positionFreqLabels();
}

// Generate frequency label elements based on current scale and range
function generateFreqLabels() {
  const labels = elements.freqLabels;
  if (!labels) return;

  // Clear existing labels
  labels.innerHTML = "";

  // Get frequencies to show (filter to visible range)
  const visibleFreqs = FREQ_LABEL_POINTS.filter((f) => f >= minFreq && f <= maxFreq);

  // Always include min and max if not already close to a standard point
  const freqsToShow = [...visibleFreqs];
  if (!visibleFreqs.some((f) => Math.abs(f - minFreq) / minFreq < 0.2)) {
    freqsToShow.push(minFreq);
  }
  if (!visibleFreqs.some((f) => Math.abs(f - maxFreq) / maxFreq < 0.2)) {
    freqsToShow.push(maxFreq);
  }
  freqsToShow.sort((a, b) => b - a); // Sort descending (top to bottom)

  // Create label elements
  for (const freq of freqsToShow) {
    const label = document.createElement("span");
    label.className = "freq-label";
    label.textContent = formatFreq(freq);
    label.dataset.freq = freq;
    labels.appendChild(label);
  }
}

// Position frequency labels to align with actual canvas content
function positionFreqLabels() {
  const canvas = elements.canvas;
  const container = elements.canvasContainer;
  const labelsContainer = elements.freqLabels;
  const stretchIndicator = elements.stretchIndicator;

  if (!canvas || !container || !labelsContainer) return;

  // Get the container dimensions
  const containerRect = container.getBoundingClientRect();
  const containerWidth = containerRect.width;
  const containerHeight = containerRect.height;

  // Get the canvas intrinsic dimensions
  const canvasWidth = canvas.width;
  const canvasHeight = canvas.height;

  if (canvasWidth === 0 || canvasHeight === 0) return;

  // With object-fit: fill, the canvas fills the entire container
  // Calculate stretch factors for each dimension
  const stretchX = containerWidth / canvasWidth;
  const stretchY = containerHeight / canvasHeight;

  // Update stretch indicator
  if (stretchIndicator) {
    // Determine which dimension is stretched more relative to the other
    const aspectRatio = stretchX / stretchY;
    if (Math.abs(aspectRatio - 1) < 0.01) {
      // Essentially uniform scaling
      stretchIndicator.textContent = "";
    } else if (aspectRatio > 1) {
      // Stretched horizontally
      stretchIndicator.textContent = `H: ${aspectRatio.toFixed(2)}x`;
    } else {
      // Stretched vertically
      stretchIndicator.textContent = `V: ${(1 / aspectRatio).toFixed(2)}x`;
    }
  }

  // Position the labels container (fills entire height with object-fit: fill)
  labelsContainer.style.top = "0px";
  labelsContainer.style.height = containerHeight + "px";

  // Position each label according to frequency scale
  const labels = labelsContainer.querySelectorAll(".freq-label");
  const padding = 6; // Padding from top/bottom edges

  labels.forEach((label) => {
    const freq = parseFloat(label.dataset.freq);
    let position;

    if (freqScale === "log") {
      // Logarithmic positioning
      const logMin = Math.log10(minFreq);
      const logMax = Math.log10(maxFreq);
      const logFreq = Math.log10(freq);
      position = 1 - (logFreq - logMin) / (logMax - logMin); // 0 = top, 1 = bottom
    } else if (freqScale === "mel") {
      // Mel scale positioning
      const hzToMel = (hz) => 2595 * Math.log10(1 + hz / 700);
      const melMin = hzToMel(minFreq);
      const melMax = hzToMel(maxFreq);
      const melFreq = hzToMel(freq);
      position = 1 - (melFreq - melMin) / (melMax - melMin);
    } else {
      // Linear positioning
      position = 1 - (freq - minFreq) / (maxFreq - minFreq);
    }

    // Convert to pixel position with padding
    const usableHeight = containerHeight - padding * 2;
    const pixelPos = padding + position * usableHeight;

    label.style.position = "absolute";
    label.style.top = pixelPos + "px";
    label.style.transform = "translateY(-50%)";
  });
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
    updateRecorderAndRegenerate({ gain });
  });

  // Range
  elements.range.addEventListener("input", () => {
    range = parseInt(elements.range.value);
    elements.rangeValue.textContent = range + " dB";
    updateRecorderAndRegenerate({ range });
  });

  // Frequency scale
  const freqScaleOptions = elements.freqScaleSelector.querySelectorAll(".color-option");
  freqScaleOptions.forEach((option) => {
    option.addEventListener("click", () => {
      freqScaleOptions.forEach((o) => o.classList.remove("selected"));
      option.classList.add("selected");
      freqScale = option.dataset.scale;
      updateRecorderAndRegenerate({ freqScale });
    });
  });

  // Min frequency
  elements.minFreq.addEventListener("input", () => {
    minFreq = parseInt(elements.minFreq.value);
    elements.minFreqValue.textContent = minFreq + " Hz";
    updateRecorderAndRegenerate({ minFreq });
  });

  // Max frequency
  elements.maxFreq.addEventListener("input", () => {
    maxFreq = parseInt(elements.maxFreq.value);
    elements.maxFreqValue.textContent = formatFreq(maxFreq);
    updateRecorderAndRegenerate({ maxFreq });
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

    updateRecorderAndRegenerate({ minFreq, maxFreq });
  });

  // Color scale
  const colorOptions = elements.colorSelector.querySelectorAll(".color-option");
  colorOptions.forEach((option) => {
    option.addEventListener("click", () => {
      colorOptions.forEach((o) => o.classList.remove("selected"));
      option.classList.add("selected");
      colorScale = option.dataset.color;
      updateRecorderAndRegenerate({ colorScale });
    });
  });
}

// Helper to update live recorder settings and trigger appropriate regeneration
function updateRecorderAndRegenerate(settings) {
  // If in record mode with active recorder, update and redraw
  if (sourceType === "record" && liveRecorder) {
    liveRecorder.updateSettings(settings);
    // If recording or has frames, redraw immediately
    if (liveRecorder.isRecording || liveRecorder.hasFrames()) {
      liveRecorder.redraw();
      return; // Don't trigger normal regenerate
    }
  }
  // Otherwise trigger normal spectrogram regeneration
  triggerRegenerate();
}

// Audio source toggle
function setupSourceToggle() {
  const options = elements.sourceToggle.querySelectorAll(".source-option");

  options.forEach((option) => {
    option.addEventListener("click", async () => {
      const source = option.dataset.source;
      if (source === sourceType) return;

      // Stop any active recording when switching away
      if (sourceType === "record" && liveRecorder && liveRecorder.isRecording) {
        stopRecording();
      }

      options.forEach((o) => o.classList.remove("selected"));
      option.classList.add("selected");

      sourceType = source;
      elements.syntheticControls.classList.toggle("hidden", source !== "synthetic");
      elements.fileControls.classList.toggle("hidden", source !== "file");
      elements.recordControls.classList.toggle("hidden", source !== "record");

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
      } else if (source === "record") {
        // Clear canvas and show ready state
        const ctx = elements.canvas.getContext("2d");
        ctx.fillStyle = "#0f0f23";
        ctx.fillRect(0, 0, elements.canvas.width, elements.canvas.height);
        // Reset stats
        elements.stats.fftTime.textContent = "-";
        elements.stats.totalTime.textContent = "-";
        elements.stats.fftsPerSec.textContent = "-";
        elements.stats.frames.textContent = "-";
      }
    });
  });
}

// Setup live recording controls
function setupRecordingControls() {
  // Create live recorder instance
  liveRecorder = new LiveRecorder({
    canvas: elements.canvas,
    onUpdate: (status) => {
      // Update time display
      const duration = status.duration;
      const mins = Math.floor(duration / 60);
      const secs = Math.floor(duration % 60);
      elements.recordTime.textContent = `${mins}:${secs.toString().padStart(2, "0")}`;

      // Update stats
      elements.stats.frames.textContent = status.frames.toLocaleString();
    },
    onComplete: (result) => {
      // Store recorded audio as loaded audio
      loadedAudioSamples = result;
      elements.recordHint.textContent = `Recorded ${result.duration.toFixed(1)}s - click Record to start over`;
    },
  });

  // Record button
  elements.recordBtn.addEventListener("click", async () => {
    if (liveRecorder.isRecording) {
      stopRecording();
    } else {
      await startRecording();
    }
  });

  // Pause button
  elements.pauseBtn.addEventListener("click", () => {
    if (!liveRecorder.isRecording) return;

    if (liveRecorder.isPaused) {
      liveRecorder.resume();
      elements.pauseBtn.textContent = "Pause";
      elements.recordIndicator.classList.remove("paused");
      elements.recordHint.textContent = "Recording...";
    } else {
      liveRecorder.pause();
      elements.pauseBtn.textContent = "Resume";
      elements.recordIndicator.classList.add("paused");
      elements.recordHint.textContent = "Paused - click Resume to continue";
    }
  });
}

// Start recording
async function startRecording() {
  try {
    // Update recorder settings from current FFT settings
    const fftSize = Math.pow(2, parseInt(elements.fftSize.value));
    const hopSize = Math.pow(2, parseInt(elements.hopSize.value));

    liveRecorder.updateSettings({
      fftSize,
      hopSize,
      windowType,
      zeroPadding,
      gain,
      range,
      colorScale,
      freqScale,
      minFreq,
      maxFreq,
    });

    // Set FFT context
    const fftContext = createFFTContext(currentModule, fftSize);
    liveRecorder.setFFTContext(fftContext);

    // Start recording
    await liveRecorder.start();

    // Update UI
    elements.recordBtn.textContent = "Stop";
    elements.recordBtn.classList.add("recording");
    elements.pauseBtn.disabled = false;
    elements.recordIndicator.classList.remove("hidden");
    elements.recordHint.textContent = "Recording...";

    // Update implementation display
    elements.implName.textContent = currentModule.config.name + " (Recording)";
  } catch (err) {
    console.error("Failed to start recording:", err);
    elements.recordHint.textContent = "Error: " + (err.message || "Microphone access denied");
  }
}

// Stop recording
function stopRecording() {
  if (!liveRecorder || !liveRecorder.isRecording) return;

  const result = liveRecorder.stop();

  // Update UI
  elements.recordBtn.textContent = "Record";
  elements.recordBtn.classList.remove("recording");
  elements.pauseBtn.textContent = "Pause";
  elements.pauseBtn.disabled = true;
  elements.recordIndicator.classList.add("hidden");
  elements.recordIndicator.classList.remove("paused");

  // Update implementation display
  updateImplName();

  // Regenerate spectrogram with recorded audio
  if (result && result.samples.length > 0) {
    triggerRegenerate();
  }
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

// Analyzer setup
async function setupAnalyzer() {
  // Create analyzer instance
  analyzer = new SpectrumAnalyzer({
    canvas: elements.canvas,
    fftSize: Math.pow(2, parseInt(elements.analyzerFftSize.value)),
    smoothing: parseInt(elements.analyzerSmoothing.value) / 100,
    minFreq: parseInt(elements.analyzerMinFreq.value),
    maxFreq: parseInt(elements.analyzerMaxFreq.value),
    minDb: parseInt(elements.analyzerMinDb.value),
    maxDb: parseInt(elements.analyzerMaxDb.value),
    displayMode: "bars",
    colorScheme: "gradient",
  });

  // Load default analyzer FFT module
  try {
    analyzerModule = await loadFFTModule(analyzerModuleId);
    const fftSize = Math.pow(2, parseInt(elements.analyzerFftSize.value));
    const fftContext = createFFTContext(analyzerModule, fftSize);
    analyzer.setFFTContext(fftContext, analyzerModule);
  } catch (err) {
    console.error("Failed to load analyzer FFT module:", err);
  }

  // Toggle button
  elements.analyzerToggle.addEventListener("click", async () => {
    if (analyzer.isRunning) {
      stopAnalyzer();
    } else {
      await startAnalyzer();
    }
  });

  // FFT implementation selector
  const analyzerFftOptions = elements.analyzerFftSelector.querySelectorAll(".fft-option");
  analyzerFftOptions.forEach((option) => {
    option.addEventListener("click", async () => {
      const moduleId = option.dataset.fft;
      if (moduleId === analyzerModuleId) return;

      analyzerFftOptions.forEach((o) => o.classList.remove("selected"));
      option.classList.add("selected");

      try {
        analyzerModule = await loadFFTModule(moduleId);
        analyzerModuleId = moduleId;

        // Update analyzer FFT context
        const fftSize = Math.pow(2, parseInt(elements.analyzerFftSize.value));
        const fftContext = createFFTContext(analyzerModule, fftSize);
        analyzer.setFFTContext(fftContext, analyzerModule);

        // Update implementation display if running
        if (analyzer.isRunning) {
          updateAnalyzerImplName();
        }
      } catch (err) {
        console.error("Failed to load analyzer module:", err);
      }
    });
  });

  // FFT Size slider
  elements.analyzerFftSize.addEventListener("input", () => {
    const fftSize = Math.pow(2, parseInt(elements.analyzerFftSize.value));
    elements.analyzerFftSizeValue.textContent = fftSize;

    if (analyzerModule) {
      const fftContext = createFFTContext(analyzerModule, fftSize);
      analyzer.setFFTContext(fftContext, analyzerModule);
    }
  });

  // Smoothing slider
  elements.analyzerSmoothing.addEventListener("input", () => {
    const smoothing = parseInt(elements.analyzerSmoothing.value) / 100;
    elements.analyzerSmoothingValue.textContent = elements.analyzerSmoothing.value + "%";
    analyzer.updateSettings({ smoothing });
  });

  // Min frequency slider
  elements.analyzerMinFreq.addEventListener("input", () => {
    const minFreq = parseInt(elements.analyzerMinFreq.value);
    elements.analyzerMinFreqValue.textContent = minFreq + " Hz";
    analyzer.updateSettings({ minFreq });
  });

  // Max frequency slider
  elements.analyzerMaxFreq.addEventListener("input", () => {
    const maxFreq = parseInt(elements.analyzerMaxFreq.value);
    elements.analyzerMaxFreqValue.textContent = formatFreq(maxFreq);
    analyzer.updateSettings({ maxFreq });
  });

  // Min dB slider
  elements.analyzerMinDb.addEventListener("input", () => {
    const minDb = parseInt(elements.analyzerMinDb.value);
    elements.analyzerMinDbValue.textContent = minDb + " dB";
    analyzer.updateSettings({ minDb });
  });

  // Max dB slider
  elements.analyzerMaxDb.addEventListener("input", () => {
    const maxDb = parseInt(elements.analyzerMaxDb.value);
    elements.analyzerMaxDbValue.textContent = maxDb + " dB";
    analyzer.updateSettings({ maxDb });
  });

  // Display mode selector
  const displayModeOptions = elements.displayModeSelector.querySelectorAll(".color-option");
  displayModeOptions.forEach((option) => {
    option.addEventListener("click", () => {
      displayModeOptions.forEach((o) => o.classList.remove("selected"));
      option.classList.add("selected");
      analyzer.updateSettings({ displayMode: option.dataset.mode });
    });
  });

  // Color scheme selector
  const analyzerColorOptions = elements.analyzerColorSelector.querySelectorAll(".color-option");
  analyzerColorOptions.forEach((option) => {
    option.addEventListener("click", () => {
      analyzerColorOptions.forEach((o) => o.classList.remove("selected"));
      option.classList.add("selected");
      analyzer.updateSettings({ colorScheme: option.dataset.color });
    });
  });
}

// Start analyzer
async function startAnalyzer() {
  try {
    const result = await analyzer.start();
    elements.analyzerToggle.textContent = "Stop Microphone";
    elements.analyzerToggle.classList.add("danger");
    elements.analyzerStatus.textContent = `Listening at ${result.sampleRate} Hz`;
    updateAnalyzerImplName();

    // Start stats update interval
    analyzerStatsInterval = setInterval(updateAnalyzerStats, 100);
  } catch (err) {
    console.error("Failed to start analyzer:", err);
    elements.analyzerStatus.textContent = "Error: " + (err.message || "Microphone access denied");
  }
}

// Stop analyzer
function stopAnalyzer() {
  analyzer.stop();
  elements.analyzerToggle.textContent = "Start Microphone";
  elements.analyzerToggle.classList.remove("danger");
  elements.analyzerStatus.textContent = "Click to start real-time analysis";

  // Stop stats update interval
  if (analyzerStatsInterval) {
    clearInterval(analyzerStatsInterval);
    analyzerStatsInterval = null;
  }

  // Reset stats display
  elements.stats.fftTime.textContent = "-";
  elements.stats.totalTime.textContent = "-";
  elements.stats.fftsPerSec.textContent = "-";
  elements.stats.frames.textContent = "-";

  // Reset implementation display
  elements.implName.textContent = "Stopped";
  elements.implName.classList.remove("alt");
}

// Update analyzer stats display
function updateAnalyzerStats() {
  if (!analyzer || !analyzer.isRunning) return;

  const stats = analyzer.getStats();
  // FFT (ms): actual FFT computation time
  elements.stats.fftTime.textContent = stats.fftTime.toFixed(2);
  // Total (ms): frame time (1000/fps)
  const frameTime = stats.fps > 0 ? (1000 / stats.fps).toFixed(1) : "-";
  elements.stats.totalTime.textContent = frameTime;
  // FFTs/sec: same as FPS since we do 1 FFT per frame
  elements.stats.fftsPerSec.textContent = stats.fps.toLocaleString();
  // Frames: show sample rate
  elements.stats.frames.textContent = (stats.sampleRate / 1000).toFixed(1) + "k";
}

// Update analyzer implementation name
function updateAnalyzerImplName() {
  if (!analyzerModule) return;
  const { name } = analyzerModule.config;
  const isAlt = !analyzerModule.config.isWatFft;
  elements.implName.textContent = name + " (Live)";
  elements.implName.classList.toggle("alt", isAlt);
}

// Mode toggle handling (Spectrogram vs Live Analyzer)
function setupModeToggle() {
  const modeToggle = document.getElementById("mode-toggle");
  const spectrogramMode = document.getElementById("spectrogram-mode");
  const analyzerModeEl = document.getElementById("analyzer-mode");
  const modeOptions = modeToggle.querySelectorAll(".mode-option");

  modeOptions.forEach((option) => {
    option.addEventListener("click", () => {
      const newMode = option.dataset.mode;
      if (newMode === currentMode) return;

      const previousMode = currentMode;
      currentMode = newMode;

      // Update toggle UI
      modeOptions.forEach((o) => o.classList.remove("selected"));
      option.classList.add("selected");

      // Handle mode transitions
      if (previousMode === "analyzer" && analyzer && analyzer.isRunning) {
        // Leaving analyzer mode while running - stop analyzer
        stopAnalyzer();
      }

      if (newMode === "analyzer") {
        // Switch to analyzer mode
        spectrogramMode.classList.add("hidden");
        analyzerModeEl.classList.remove("hidden");

        // Clear canvas and show ready state
        const ctx = elements.canvas.getContext("2d");
        ctx.fillStyle = "#0f0f23";
        ctx.fillRect(0, 0, elements.canvas.width, elements.canvas.height);

        // Hide vertical frequency labels (analyzer draws its own)
        elements.freqLabels.style.display = "none";

        // Reset stats
        elements.stats.fftTime.textContent = "-";
        elements.stats.totalTime.textContent = "-";
        elements.stats.fftsPerSec.textContent = "-";
        elements.stats.frames.textContent = "-";
        elements.implName.textContent = "Stopped";
        elements.implName.classList.remove("alt");
      } else {
        // Switch to spectrogram mode
        spectrogramMode.classList.remove("hidden");
        analyzerModeEl.classList.add("hidden");

        // Show vertical frequency labels
        elements.freqLabels.style.display = "";

        // Regenerate spectrogram
        updateImplName();
        if (lastSpectrogram || sourceType === "synthetic" || loadedAudioSamples) {
          triggerRegenerate();
        }
      }
    });
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
  } else if (sourceType === "file" || sourceType === "record") {
    if (!loadedAudioSamples) {
      throw new Error(sourceType === "record" ? "No recording yet" : "No audio file loaded");
    }
    return {
      samples: loadedAudioSamples.samples,
      sampleRate: loadedAudioSamples.sampleRate,
    };
  }
  throw new Error("Unknown source type");
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
  setupRecordingControls();
  setupModeToggle();
  await setupAnalyzer();
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

  // Update label positions when canvas container resizes
  const resizeObserver = new ResizeObserver(debounce(positionFreqLabels, 50));
  resizeObserver.observe(elements.canvasContainer);

  // Initial label positioning (after first render)
  requestAnimationFrame(() => positionFreqLabels());
}

init();
