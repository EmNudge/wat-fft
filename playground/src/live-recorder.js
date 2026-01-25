/**
 * Live Recorder
 *
 * Records audio from microphone while building spectrogram in real-time.
 * Supports pause/resume and provides recorded samples when done.
 */

import { WINDOW_FUNCTIONS, COLOR_SCALES } from "./spectrogram.js";

export class LiveRecorder {
  constructor(options = {}) {
    this.canvas = options.canvas;
    this.onUpdate = options.onUpdate || (() => {});
    this.onComplete = options.onComplete || (() => {});

    // FFT settings
    this.fftSize = options.fftSize || 2048;
    this.hopSize = options.hopSize || 512;
    this.windowType = options.windowType || "hann";
    this.zeroPadding = options.zeroPadding || 2;
    this.gain = options.gain || -20;
    this.range = options.range || 80;
    this.colorScale = options.colorScale || "magma";
    this.freqScale = options.freqScale || "log";
    this.minFreq = options.minFreq || 50;
    this.maxFreq = options.maxFreq || 8000;

    // FFT context (from fft-loader)
    this.fftContext = null;

    // Audio state
    this.audioContext = null;
    this.mediaStream = null;
    this.sourceNode = null;
    this.processorNode = null;

    // Recording state
    this.isRecording = false;
    this.isPaused = false;
    this.recordedSamples = [];
    this.sampleRate = 44100;
    this.startTime = 0;
    this.pausedDuration = 0;
    this.pauseStartTime = 0;

    // Spectrogram building
    this.spectrogramFrames = [];
    this.inputBuffer = new Float32Array(this.fftSize);
    this.inputWritePos = 0;
    this.samplesProcessed = 0;
    this.windowCoeffs = null;

    // Animation
    this.animationId = null;
  }

  /**
   * Set FFT context from fft-loader
   */
  setFFTContext(fftContext) {
    this.fftContext = fftContext;
    if (fftContext) {
      this.fftSize = fftContext.size;
      this.inputBuffer = new Float32Array(this.fftSize);
      this._createWindowCoeffs();
    }
  }

  /**
   * Update settings
   */
  updateSettings(settings) {
    if (settings.fftSize !== undefined) this.fftSize = settings.fftSize;
    if (settings.hopSize !== undefined) this.hopSize = settings.hopSize;
    if (settings.windowType !== undefined) {
      this.windowType = settings.windowType;
      this._createWindowCoeffs();
    }
    if (settings.zeroPadding !== undefined) this.zeroPadding = settings.zeroPadding;
    if (settings.gain !== undefined) this.gain = settings.gain;
    if (settings.range !== undefined) this.range = settings.range;
    if (settings.colorScale !== undefined) this.colorScale = settings.colorScale;
    if (settings.freqScale !== undefined) this.freqScale = settings.freqScale;
    if (settings.minFreq !== undefined) this.minFreq = settings.minFreq;
    if (settings.maxFreq !== undefined) this.maxFreq = settings.maxFreq;
  }

  /**
   * Create window coefficients
   */
  _createWindowCoeffs() {
    const windowSize = Math.floor(this.fftSize / this.zeroPadding);
    this.windowCoeffs = new Float32Array(windowSize);
    const windowFn = WINDOW_FUNCTIONS[this.windowType] || WINDOW_FUNCTIONS.hann;
    for (let i = 0; i < windowSize; i++) {
      this.windowCoeffs[i] = windowFn(i, windowSize);
    }
  }

  /**
   * Start recording
   */
  async start() {
    if (this.isRecording) return;

    try {
      // Request microphone access
      this.mediaStream = await navigator.mediaDevices.getUserMedia({
        audio: {
          echoCancellation: false,
          noiseSuppression: false,
          autoGainControl: false,
        },
      });

      // Create audio context
      this.audioContext = new (window.AudioContext || window.webkitAudioContext)();
      this.sampleRate = this.audioContext.sampleRate;

      // Update max frequency based on sample rate
      const nyquist = this.sampleRate / 2;
      if (this.maxFreq > nyquist) {
        this.maxFreq = nyquist;
      }

      // Create source from microphone
      this.sourceNode = this.audioContext.createMediaStreamSource(this.mediaStream);

      // Create processor for sample access
      const bufferSize = 2048;
      this.processorNode = this.audioContext.createScriptProcessor(bufferSize, 1, 1);

      this.processorNode.onaudioprocess = (event) => {
        if (this.isPaused) return;
        const inputData = event.inputBuffer.getChannelData(0);
        this._processAudioChunk(inputData);
      };

      // Connect nodes
      this.sourceNode.connect(this.processorNode);
      this.processorNode.connect(this.audioContext.destination);

      // Reset state
      this.recordedSamples = [];
      this.spectrogramFrames = [];
      this.inputBuffer.fill(0);
      this.inputWritePos = 0;
      this.samplesProcessed = 0;
      this.isRecording = true;
      this.isPaused = false;
      this.startTime = performance.now();
      this.pausedDuration = 0;

      // Create window coefficients
      this._createWindowCoeffs();

      // Set canvas resolution
      this.canvas.width = 1024;
      this.canvas.height = 512;

      // Clear canvas
      const ctx = this.canvas.getContext("2d");
      ctx.fillStyle = "#0f0f23";
      ctx.fillRect(0, 0, this.canvas.width, this.canvas.height);

      // Start render loop
      this._render();

      return { sampleRate: this.sampleRate };
    } catch (err) {
      console.error("Failed to start recording:", err);
      throw err;
    }
  }

  /**
   * Pause recording
   */
  pause() {
    if (!this.isRecording || this.isPaused) return;
    this.isPaused = true;
    this.pauseStartTime = performance.now();
  }

  /**
   * Resume recording
   */
  resume() {
    if (!this.isRecording || !this.isPaused) return;
    this.isPaused = false;
    this.pausedDuration += performance.now() - this.pauseStartTime;
  }

  /**
   * Stop recording and return samples
   */
  stop() {
    if (!this.isRecording) return null;

    this.isRecording = false;
    this.isPaused = false;

    if (this.animationId) {
      cancelAnimationFrame(this.animationId);
      this.animationId = null;
    }

    if (this.processorNode) {
      this.processorNode.disconnect();
      this.processorNode = null;
    }

    if (this.sourceNode) {
      this.sourceNode.disconnect();
      this.sourceNode = null;
    }

    if (this.mediaStream) {
      this.mediaStream.getTracks().forEach((track) => track.stop());
      this.mediaStream = null;
    }

    // Combine all recorded chunks into single Float32Array
    const totalSamples = this.recordedSamples.reduce((sum, chunk) => sum + chunk.length, 0);
    const samples = new Float32Array(totalSamples);
    let offset = 0;
    for (const chunk of this.recordedSamples) {
      samples.set(chunk, offset);
      offset += chunk.length;
    }

    const result = {
      samples,
      sampleRate: this.sampleRate,
      duration: totalSamples / this.sampleRate,
    };

    // Close audio context
    if (this.audioContext) {
      this.audioContext.close();
      this.audioContext = null;
    }

    this.onComplete(result);
    return result;
  }

  /**
   * Get current recording duration in seconds
   */
  getDuration() {
    if (!this.isRecording) return 0;
    const elapsed = performance.now() - this.startTime - this.pausedDuration;
    if (this.isPaused) {
      return (this.pauseStartTime - this.startTime - this.pausedDuration) / 1000;
    }
    return elapsed / 1000;
  }

  /**
   * Process incoming audio chunk
   */
  _processAudioChunk(samples) {
    // Store samples for later use
    this.recordedSamples.push(new Float32Array(samples));

    // Add to ring buffer for FFT processing
    for (let i = 0; i < samples.length; i++) {
      this.inputBuffer[this.inputWritePos] = samples[i];
      this.inputWritePos = (this.inputWritePos + 1) % this.fftSize;
      this.samplesProcessed++;

      // Check if we have enough samples for a new FFT frame
      const windowSize = Math.floor(this.fftSize / this.zeroPadding);
      if (this.samplesProcessed >= this.hopSize && this.samplesProcessed >= windowSize) {
        this._processFFTFrame();
        this.samplesProcessed = 0;
      }
    }
  }

  /**
   * Process one FFT frame
   */
  _processFFTFrame() {
    if (!this.fftContext) return;

    const windowSize = Math.floor(this.fftSize / this.zeroPadding);
    const numBins = this.fftSize / 2 + 1;

    // Get linearized buffer with window applied
    const paddedInput = new Float32Array(this.fftSize);
    for (let i = 0; i < windowSize; i++) {
      const bufIdx = (this.inputWritePos - windowSize + i + this.fftSize) % this.fftSize;
      paddedInput[i] = this.inputBuffer[bufIdx] * this.windowCoeffs[i];
    }

    // Copy to FFT input buffer
    const inputBuffer = this.fftContext.getInputBuffer();
    if (this.fftContext.isReal) {
      inputBuffer.set(paddedInput);
    } else {
      for (let i = 0; i < this.fftSize; i++) {
        inputBuffer[i * 2] = paddedInput[i];
        inputBuffer[i * 2 + 1] = 0;
      }
    }

    // Run FFT
    this.fftContext.run();

    // Get output and compute magnitudes - store raw dB values
    const outputBuffer = this.fftContext.getOutputBuffer();
    const frame = new Float32Array(numBins);

    for (let i = 0; i < numBins; i++) {
      const re = outputBuffer[i * 2];
      const im = outputBuffer[i * 2 + 1];
      const magnitude = Math.sqrt(re * re + im * im) / (this.fftSize / 2);

      // Skip DC bins - store very low dB value
      if (i < 3) {
        frame[i] = -200;
        continue;
      }

      // Store raw dB value (normalization happens during rendering)
      frame[i] = 20 * Math.log10(magnitude + 1e-10);
    }

    this.spectrogramFrames.push(frame);
  }

  /**
   * Render loop
   */
  _render() {
    if (!this.isRecording) return;

    this._draw();
    this.onUpdate({
      duration: this.getDuration(),
      frames: this.spectrogramFrames.length,
      isPaused: this.isPaused,
    });

    this.animationId = requestAnimationFrame(() => this._render());
  }

  /**
   * Draw spectrogram
   */
  _draw() {
    const ctx = this.canvas.getContext("2d");
    const width = this.canvas.width;
    const height = this.canvas.height;
    const numBins = this.fftSize / 2 + 1;
    const numFrames = this.spectrogramFrames.length;

    if (numFrames === 0) return;

    // Clear canvas
    ctx.fillStyle = "#0f0f23";
    ctx.fillRect(0, 0, width, height);

    // Calculate display parameters
    const displayBins = Math.min(numBins, height);
    const freqMapping = this._createFrequencyMapping(numBins, displayBins);

    // Determine which frames to show (fit to canvas width or scroll)
    const maxFrames = width;
    const startFrame = Math.max(0, numFrames - maxFrames);
    const framesToDraw = Math.min(numFrames, maxFrames);

    const colorFn = COLOR_SCALES[this.colorScale] || COLOR_SCALES.magma;

    // Create image data
    const imageData = ctx.createImageData(framesToDraw, displayBins);
    const pixels = imageData.data;

    for (let f = 0; f < framesToDraw; f++) {
      const frame = this.spectrogramFrames[startFrame + f];

      for (let bin = 0; bin < displayBins; bin++) {
        // Remap frequency bin
        const srcBin = freqMapping[bin];
        const binLow = Math.floor(srcBin);
        const binHigh = Math.min(binLow + 1, frame.length - 1);
        const frac = srcBin - binLow;

        // Interpolate raw dB values
        const dbValue = frame[binLow] * (1 - frac) + frame[binHigh] * frac;

        // Apply gain/range normalization
        const normalized = (dbValue - (this.gain - this.range)) / this.range;
        const value = Math.max(0, Math.min(1, normalized));

        const [r, g, b] = colorFn(value);

        // High frequencies at top
        const y = displayBins - 1 - bin;
        const pixelIndex = (y * framesToDraw + f) * 4;

        pixels[pixelIndex] = r;
        pixels[pixelIndex + 1] = g;
        pixels[pixelIndex + 2] = b;
        pixels[pixelIndex + 3] = 255;
      }
    }

    // Draw at right edge if scrolling, otherwise left-aligned
    const xOffset = numFrames > maxFrames ? 0 : 0;
    ctx.putImageData(imageData, xOffset, 0);

    // Draw recording position indicator (vertical line at current position)
    if (numFrames < maxFrames) {
      ctx.strokeStyle = this.isPaused ? "#f59e0b" : "#4ade80";
      ctx.lineWidth = 2;
      ctx.beginPath();
      ctx.moveTo(numFrames, 0);
      ctx.lineTo(numFrames, displayBins);
      ctx.stroke();
    }
  }

  /**
   * Redraw the spectrogram with current settings (for when settings change)
   */
  redraw() {
    if (this.spectrogramFrames.length > 0) {
      this._draw();
    }
  }

  /**
   * Check if we have recorded frames
   */
  hasFrames() {
    return this.spectrogramFrames.length > 0;
  }

  /**
   * Create frequency bin mapping
   */
  _createFrequencyMapping(numBins, displayBins) {
    const nyquist = this.sampleRate / 2;
    const mapping = new Float32Array(displayBins);

    if (this.freqScale === "linear") {
      for (let i = 0; i < displayBins; i++) {
        const hz = this.minFreq + (i / (displayBins - 1)) * (this.maxFreq - this.minFreq);
        mapping[i] = (hz / nyquist) * (numBins - 1);
      }
    } else if (this.freqScale === "log") {
      const logMin = Math.log10(this.minFreq);
      const logMax = Math.log10(this.maxFreq);
      for (let i = 0; i < displayBins; i++) {
        const logHz = logMin + (i / (displayBins - 1)) * (logMax - logMin);
        const hz = Math.pow(10, logHz);
        mapping[i] = (hz / nyquist) * (numBins - 1);
      }
    } else if (this.freqScale === "mel") {
      const hzToMel = (hz) => 2595 * Math.log10(1 + hz / 700);
      const melToHz = (mel) => 700 * (Math.pow(10, mel / 2595) - 1);
      const minMel = hzToMel(this.minFreq);
      const maxMel = hzToMel(this.maxFreq);
      for (let i = 0; i < displayBins; i++) {
        const mel = minMel + (i / (displayBins - 1)) * (maxMel - minMel);
        const hz = melToHz(mel);
        mapping[i] = (hz / nyquist) * (numBins - 1);
      }
    }

    return mapping;
  }
}
