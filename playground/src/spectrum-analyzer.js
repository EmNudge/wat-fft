/**
 * Real-time Spectrum Analyzer
 *
 * Live microphone visualization using FFT with multiple display modes:
 * - Bars: Classic bar graph
 * - Curve: Smooth line with fill
 * - Mirrored: Symmetric visualization
 */

import { WINDOW_FUNCTIONS } from "./spectrogram.js";

/**
 * Spectrum Analyzer class
 */
export class SpectrumAnalyzer {
  constructor(options = {}) {
    this.canvas = options.canvas;
    this.fftSize = options.fftSize || 2048;
    this.smoothing = options.smoothing || 0.8;
    this.minFreq = options.minFreq || 20;
    this.maxFreq = options.maxFreq || 20000;
    this.minDb = options.minDb || -90;
    this.maxDb = options.maxDb || -10;
    this.displayMode = options.displayMode || "bars";
    this.colorScheme = options.colorScheme || "gradient";
    this.windowType = options.windowType || "hann";

    this.audioContext = null;
    this.mediaStream = null;
    this.sourceNode = null;
    this.processorNode = null;
    this.animationId = null;
    this.isRunning = false;

    // FFT context (from fft-loader)
    this.fftContext = null;
    this.fftModule = null;

    // Buffers
    this.inputBuffer = new Float32Array(this.fftSize);
    this.inputWritePos = 0;
    this.magnitudes = new Float32Array(this.fftSize / 2 + 1);
    this.smoothedMagnitudes = new Float32Array(this.fftSize / 2 + 1);
    this.windowCoeffs = this._createWindowCoeffs(this.fftSize, this.windowType);

    // Peak hold for bars
    this.peakHold = new Float32Array(this.fftSize / 2 + 1);
    this.peakDecay = 0.995;

    // Stats
    this.lastFftTime = 0;
    this.fftCount = 0;
    this.fpsTime = 0;
    this.frameCount = 0;
    this.currentFps = 0;
  }

  /**
   * Create window coefficients
   */
  _createWindowCoeffs(size, type) {
    const coeffs = new Float32Array(size);
    const windowFn = WINDOW_FUNCTIONS[type] || WINDOW_FUNCTIONS.hann;
    for (let i = 0; i < size; i++) {
      coeffs[i] = windowFn(i, size);
    }
    return coeffs;
  }

  /**
   * Set FFT context from fft-loader
   */
  setFFTContext(fftContext, fftModule) {
    this.fftContext = fftContext;
    this.fftModule = fftModule;

    // Resize buffers if FFT size changed
    if (fftContext.size !== this.fftSize) {
      this.fftSize = fftContext.size;
      this.inputBuffer = new Float32Array(this.fftSize);
      this.inputWritePos = 0;
      this.magnitudes = new Float32Array(this.fftSize / 2 + 1);
      this.smoothedMagnitudes = new Float32Array(this.fftSize / 2 + 1);
      this.peakHold = new Float32Array(this.fftSize / 2 + 1);
      this.windowCoeffs = this._createWindowCoeffs(this.fftSize, this.windowType);
    }
  }

  /**
   * Update settings
   */
  updateSettings(settings) {
    if (settings.smoothing !== undefined) this.smoothing = settings.smoothing;
    if (settings.minFreq !== undefined) this.minFreq = settings.minFreq;
    if (settings.maxFreq !== undefined) this.maxFreq = settings.maxFreq;
    if (settings.minDb !== undefined) this.minDb = settings.minDb;
    if (settings.maxDb !== undefined) this.maxDb = settings.maxDb;
    if (settings.displayMode !== undefined) this.displayMode = settings.displayMode;
    if (settings.colorScheme !== undefined) this.colorScheme = settings.colorScheme;
    if (settings.windowType !== undefined) {
      this.windowType = settings.windowType;
      this.windowCoeffs = this._createWindowCoeffs(this.fftSize, this.windowType);
    }
  }

  /**
   * Start microphone capture
   */
  async start() {
    if (this.isRunning) return;

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

      // Update max frequency based on actual sample rate
      const nyquist = this.audioContext.sampleRate / 2;
      if (this.maxFreq > nyquist) {
        this.maxFreq = nyquist;
      }

      // Create source from microphone
      this.sourceNode = this.audioContext.createMediaStreamSource(this.mediaStream);

      // Use ScriptProcessorNode for sample access (AudioWorklet would be better but more complex)
      const bufferSize = 2048;
      this.processorNode = this.audioContext.createScriptProcessor(bufferSize, 1, 1);

      this.processorNode.onaudioprocess = (event) => {
        const inputData = event.inputBuffer.getChannelData(0);
        this._processAudioChunk(inputData);
      };

      // Connect nodes
      this.sourceNode.connect(this.processorNode);
      this.processorNode.connect(this.audioContext.destination);

      this.isRunning = true;
      this.fpsTime = performance.now();
      this.frameCount = 0;

      // Set canvas resolution for analyzer
      this.canvas.width = 1024;
      this.canvas.height = 512;

      // Start render loop
      this._render();

      return { sampleRate: this.audioContext.sampleRate };
    } catch (err) {
      console.error("Failed to start microphone:", err);
      throw err;
    }
  }

  /**
   * Stop capture
   */
  stop() {
    this.isRunning = false;

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

    if (this.audioContext) {
      this.audioContext.close();
      this.audioContext = null;
    }

    // Clear canvas
    if (this.canvas) {
      const ctx = this.canvas.getContext("2d");
      ctx.fillStyle = "#0f0f23";
      ctx.fillRect(0, 0, this.canvas.width, this.canvas.height);
    }

    // Reset smoothed magnitudes
    this.smoothedMagnitudes.fill(0);
    this.peakHold.fill(0);
  }

  /**
   * Process incoming audio chunk
   */
  _processAudioChunk(samples) {
    // Ring buffer append
    for (let i = 0; i < samples.length; i++) {
      this.inputBuffer[this.inputWritePos] = samples[i];
      this.inputWritePos = (this.inputWritePos + 1) % this.fftSize;
    }
  }

  /**
   * Run FFT on current buffer
   */
  _runFFT() {
    if (!this.fftContext) return;

    const fftStart = performance.now();

    // Get linearized buffer (unwrap ring buffer)
    const linearBuffer = new Float32Array(this.fftSize);
    for (let i = 0; i < this.fftSize; i++) {
      const idx = (this.inputWritePos + i) % this.fftSize;
      linearBuffer[i] = this.inputBuffer[idx] * this.windowCoeffs[i];
    }

    // Copy to FFT input buffer
    const inputBuffer = this.fftContext.getInputBuffer();
    if (this.fftContext.isReal) {
      inputBuffer.set(linearBuffer);
    } else {
      // Complex input: interleave with zeros for imaginary
      for (let i = 0; i < this.fftSize; i++) {
        inputBuffer[i * 2] = linearBuffer[i];
        inputBuffer[i * 2 + 1] = 0;
      }
    }

    // Run FFT
    this.fftContext.run();

    // Get output and compute magnitudes
    const outputBuffer = this.fftContext.getOutputBuffer();
    const numBins = this.fftSize / 2 + 1;

    for (let i = 0; i < numBins; i++) {
      const re = outputBuffer[i * 2];
      const im = outputBuffer[i * 2 + 1];
      const magnitude = Math.sqrt(re * re + im * im) / (this.fftSize / 2);
      this.magnitudes[i] = magnitude;

      // Apply smoothing
      this.smoothedMagnitudes[i] =
        this.smoothing * this.smoothedMagnitudes[i] + (1 - this.smoothing) * magnitude;

      // Update peak hold
      if (this.smoothedMagnitudes[i] > this.peakHold[i]) {
        this.peakHold[i] = this.smoothedMagnitudes[i];
      } else {
        this.peakHold[i] *= this.peakDecay;
      }
    }

    this.lastFftTime = performance.now() - fftStart;
    this.fftCount++;
  }

  /**
   * Render loop
   */
  _render() {
    if (!this.isRunning) return;

    // Run FFT
    this._runFFT();

    // Update FPS
    this.frameCount++;
    const now = performance.now();
    if (now - this.fpsTime >= 1000) {
      this.currentFps = this.frameCount;
      this.frameCount = 0;
      this.fpsTime = now;
    }

    // Draw visualization
    this._draw();

    // Schedule next frame
    this.animationId = requestAnimationFrame(() => this._render());
  }

  /**
   * Draw visualization
   */
  _draw() {
    const ctx = this.canvas.getContext("2d");
    const width = this.canvas.width;
    const height = this.canvas.height;

    // Clear canvas
    ctx.fillStyle = "#0f0f23";
    ctx.fillRect(0, 0, width, height);

    if (!this.audioContext) return;

    const sampleRate = this.audioContext.sampleRate;
    const nyquist = sampleRate / 2;
    const numBins = this.fftSize / 2 + 1;

    // Calculate bin range for display
    const minBin = Math.floor((this.minFreq / nyquist) * (numBins - 1));
    const maxBin = Math.ceil((this.maxFreq / nyquist) * (numBins - 1));
    const displayBins = maxBin - minBin;

    switch (this.displayMode) {
      case "bars":
        this._drawBars(ctx, width, height, minBin, maxBin, displayBins);
        break;
      case "curve":
        this._drawCurve(ctx, width, height, minBin, maxBin, displayBins);
        break;
      case "mirrored":
        this._drawMirrored(ctx, width, height, minBin, maxBin, displayBins);
        break;
    }

    // Draw frequency labels
    this._drawFreqLabels(ctx, width, height);
  }

  /**
   * Convert magnitude to normalized height
   */
  _magnitudeToHeight(magnitude, maxHeight) {
    const db = 20 * Math.log10(magnitude + 1e-10);
    const normalized = (db - this.minDb) / (this.maxDb - this.minDb);
    return Math.max(0, Math.min(1, normalized)) * maxHeight;
  }

  /**
   * Get color for value (0-1)
   */
  _getColor(value, index, total) {
    if (this.colorScheme === "gradient") {
      // Rainbow gradient based on frequency
      const hue = (index / total) * 280;
      const lightness = 40 + value * 30;
      return `hsl(${hue}, 100%, ${lightness}%)`;
    } else if (this.colorScheme === "green") {
      const intensity = Math.floor(100 + value * 155);
      return `rgb(74, ${intensity}, 128)`;
    } else if (this.colorScheme === "blue") {
      const intensity = Math.floor(100 + value * 155);
      return `rgb(96, ${Math.floor(165 * (0.5 + value * 0.5))}, ${intensity})`;
    } else if (this.colorScheme === "fire") {
      if (value < 0.5) {
        const t = value * 2;
        return `rgb(${Math.floor(255 * t)}, ${Math.floor(100 * t)}, 0)`;
      } else {
        const t = (value - 0.5) * 2;
        return `rgb(255, ${Math.floor(100 + 155 * t)}, ${Math.floor(255 * t)})`;
      }
    }
    return `rgb(74, 222, 128)`;
  }

  /**
   * Draw bar visualization
   */
  _drawBars(ctx, width, height, minBin, maxBin, displayBins) {
    // Use logarithmic frequency bins for more musical spacing
    const numDisplayBars = Math.min(displayBins, Math.floor(width / 3));
    const barWidth = width / numDisplayBars - 1;
    const gap = 1;

    for (let i = 0; i < numDisplayBars; i++) {
      // Map display bar to frequency bin (logarithmic)
      const t = i / (numDisplayBars - 1);
      const logMin = Math.log10(this.minFreq);
      const logMax = Math.log10(this.maxFreq);
      const freq = Math.pow(10, logMin + t * (logMax - logMin));
      const bin = Math.floor((freq / (this.audioContext.sampleRate / 2)) * (this.fftSize / 2));

      if (bin < 0 || bin >= this.smoothedMagnitudes.length) continue;

      const magnitude = this.smoothedMagnitudes[bin];
      const barHeight = this._magnitudeToHeight(magnitude, height - 40);
      const peakHeight = this._magnitudeToHeight(this.peakHold[bin], height - 40);

      const x = i * (barWidth + gap);
      const y = height - 20 - barHeight;

      // Main bar
      const value = barHeight / (height - 40);
      ctx.fillStyle = this._getColor(value, i, numDisplayBars);
      ctx.fillRect(x, y, barWidth, barHeight);

      // Peak indicator
      ctx.fillStyle = "rgba(255, 255, 255, 0.8)";
      ctx.fillRect(x, height - 20 - peakHeight, barWidth, 2);
    }
  }

  /**
   * Draw curve visualization
   */
  _drawCurve(ctx, width, height, minBin, maxBin, displayBins) {
    const points = [];
    const numPoints = Math.min(displayBins, width);

    for (let i = 0; i < numPoints; i++) {
      // Logarithmic frequency mapping
      const t = i / (numPoints - 1);
      const logMin = Math.log10(this.minFreq);
      const logMax = Math.log10(this.maxFreq);
      const freq = Math.pow(10, logMin + t * (logMax - logMin));
      const bin = Math.floor((freq / (this.audioContext.sampleRate / 2)) * (this.fftSize / 2));

      if (bin < 0 || bin >= this.smoothedMagnitudes.length) continue;

      const magnitude = this.smoothedMagnitudes[bin];
      const y = this._magnitudeToHeight(magnitude, height - 40);
      const x = (i / (numPoints - 1)) * width;

      points.push({ x, y: height - 20 - y });
    }

    if (points.length < 2) return;

    // Draw filled area
    ctx.beginPath();
    ctx.moveTo(0, height - 20);

    for (const point of points) {
      ctx.lineTo(point.x, point.y);
    }

    ctx.lineTo(width, height - 20);
    ctx.closePath();

    // Gradient fill
    const gradient = ctx.createLinearGradient(0, 0, 0, height);
    gradient.addColorStop(0, "rgba(74, 222, 128, 0.8)");
    gradient.addColorStop(0.5, "rgba(96, 165, 250, 0.5)");
    gradient.addColorStop(1, "rgba(96, 165, 250, 0.1)");
    ctx.fillStyle = gradient;
    ctx.fill();

    // Draw line on top
    ctx.beginPath();
    ctx.moveTo(points[0].x, points[0].y);
    for (let i = 1; i < points.length; i++) {
      ctx.lineTo(points[i].x, points[i].y);
    }
    ctx.strokeStyle = "#4ade80";
    ctx.lineWidth = 2;
    ctx.stroke();
  }

  /**
   * Draw mirrored visualization
   */
  _drawMirrored(ctx, width, height, minBin, maxBin, displayBins) {
    const centerY = height / 2;
    const numDisplayBars = Math.min(displayBins, Math.floor(width / 3));
    const barWidth = width / numDisplayBars - 1;
    const gap = 1;

    for (let i = 0; i < numDisplayBars; i++) {
      // Logarithmic frequency mapping
      const t = i / (numDisplayBars - 1);
      const logMin = Math.log10(this.minFreq);
      const logMax = Math.log10(this.maxFreq);
      const freq = Math.pow(10, logMin + t * (logMax - logMin));
      const bin = Math.floor((freq / (this.audioContext.sampleRate / 2)) * (this.fftSize / 2));

      if (bin < 0 || bin >= this.smoothedMagnitudes.length) continue;

      const magnitude = this.smoothedMagnitudes[bin];
      const barHeight = this._magnitudeToHeight(magnitude, (height - 60) / 2);

      const x = i * (barWidth + gap);
      const value = barHeight / ((height - 60) / 2);
      ctx.fillStyle = this._getColor(value, i, numDisplayBars);

      // Top half (mirrored up)
      ctx.fillRect(x, centerY - barHeight, barWidth, barHeight);
      // Bottom half (mirrored down)
      ctx.fillRect(x, centerY, barWidth, barHeight);
    }

    // Center line
    ctx.strokeStyle = "rgba(255, 255, 255, 0.3)";
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(0, centerY);
    ctx.lineTo(width, centerY);
    ctx.stroke();
  }

  /**
   * Draw frequency labels
   */
  _drawFreqLabels(ctx, width, height) {
    ctx.fillStyle = "rgba(255, 255, 255, 0.6)";
    ctx.font = "11px monospace";

    // Frequency labels at bottom
    const freqs = [100, 200, 500, 1000, 2000, 5000, 10000, 20000];
    const logMin = Math.log10(this.minFreq);
    const logMax = Math.log10(this.maxFreq);
    const margin = 25; // Minimum margin from edges

    for (const freq of freqs) {
      if (freq < this.minFreq || freq > this.maxFreq) continue;

      const logFreq = Math.log10(freq);
      const x = ((logFreq - logMin) / (logMax - logMin)) * width;

      // Skip labels too close to edges
      if (x < margin || x > width - margin) continue;

      let label;
      if (freq >= 1000) {
        label = freq / 1000 + "k";
      } else {
        label = freq.toString();
      }

      ctx.textAlign = "center";
      ctx.fillText(label, x, height - 5);
    }
  }

  /**
   * Get current stats
   */
  getStats() {
    return {
      fftTime: this.lastFftTime,
      fps: this.currentFps,
      sampleRate: this.audioContext?.sampleRate || 0,
      fftSize: this.fftSize,
    };
  }
}
