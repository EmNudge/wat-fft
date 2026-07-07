/**
 * FFT Module Loader
 *
 * Loads and manages different FFT implementations:
 * - wat-fft WASM modules
 * - Competitor JS/WASM libraries (fft.js, kissfft-js, webfft, pffft-wasm)
 */

/**
 * Validate an FFT context produces correct output.
 * Uses a cosine signal at bin 1 frequency - energy should be concentrated at bin 1.
 * @param {object} ctx - FFT context with getInputBuffer, getOutputBuffer, run methods
 * @param {number} size - FFT size
 * @param {boolean} isReal - Whether this is a real FFT
 * @returns {boolean} True if FFT output is valid
 */
function validateFFTContext(ctx, size, isReal) {
  try {
    const input = ctx.getInputBuffer();

    // Generate cosine at bin 1 frequency: cos(2*pi*n/N) for n=0..N-1
    if (isReal) {
      for (let i = 0; i < size; i++) {
        input[i] = Math.cos((2 * Math.PI * i) / size);
      }
    } else {
      // Complex input: interleaved [re, im, re, im, ...]
      for (let i = 0; i < size; i++) {
        input[i * 2] = Math.cos((2 * Math.PI * i) / size);
        input[i * 2 + 1] = 0;
      }
    }

    ctx.run();
    const output = ctx.getOutputBuffer();

    // Compute magnitudes and find where energy is concentrated
    const numBins = isReal ? size / 2 + 1 : size;
    let bin1Mag = 0;
    let otherMagSum = 0;

    for (let i = 0; i < numBins; i++) {
      const re = output[i * 2];
      const im = output[i * 2 + 1];
      const mag = Math.sqrt(re * re + im * im);

      if (i === 1) {
        bin1Mag = mag;
      } else if (i > 0 && i < numBins - 1) {
        // Skip DC and Nyquist, sum other bins
        otherMagSum += mag;
      }
    }

    // For a pure cosine at bin 1, bin 1 should have ~N/2 magnitude
    // and other bins should be near zero
    // Allow some tolerance for floating point
    const expectedBin1Mag = size / 2;
    const bin1Ratio = bin1Mag / expectedBin1Mag;
    const otherRatio = otherMagSum / bin1Mag;

    // Bin 1 should be within 50% of expected, others should be < 10% of bin 1
    const isValid = bin1Ratio > 0.5 && bin1Ratio < 2.0 && otherRatio < 0.1;

    if (!isValid) {
      console.warn(
        `FFT validation failed: bin1Mag=${bin1Mag.toFixed(2)}, ` +
          `expected~${expectedBin1Mag}, otherMagSum=${otherMagSum.toFixed(2)}`,
      );
    }

    return isValid;
  } catch (e) {
    console.warn("FFT validation error:", e);
    return false;
  }
}

import FFT from "fft.js";
import * as fftJs from "fft-js";
import kissfft from "kissfft-js";
import webfft from "webfft";
// SIMD glue to match the SIMD pffft.wasm we serve (the bare import
// resolves to the non-SIMD build - see Experiment 57)
import PFFFT from "@echogarden/pffft-wasm/simd";

// Shared wat-fft surface registry: the single source of truth for which
// wat implementations exist. The playground enumerates it like every
// benchmark surface, so a new flagship module shows up here automatically.
import { watEntriesFor } from "../../benchmarks/shared/wat-surfaces.mjs";

// fftw-js needs to be loaded dynamically due to WASM initialization
let fftwModule = null;
async function getFFTW() {
  if (!fftwModule) {
    const fftw = await import("fftw-js");
    // fftw-js is a CommonJS module that exports { FFT, RFFT } directly
    // When imported as ESM, the default export is the module.exports object
    fftwModule = fftw.default || fftw;
  }
  return fftwModule;
}

// pffft-wasm needs async initialization
let pffftModule = null;
async function getPFFFT() {
  if (!pffftModule) {
    // Use locateFile to point to our public directory copy of pffft.wasm
    pffftModule = await PFFFT({
      locateFile: (path) => {
        if (path.endsWith(".wasm")) {
          return "/pffft.wasm";
        }
        return path;
      },
    });
  }
  return pffftModule;
}

// wat-fft WASM modules, enumerated from the shared surface registry.
// Stable playground ids (referenced by UI defaults) keyed by run:precision.
const WAT_IDS = {
  "fft:f64": "combined",
  "rfft:f64": "real_combined",
  "fft:f32": "f32_dual",
  "rfft:f32": "real_f32_dual",
  "fft_split:f32": "f32_split",
  "rfft_split:f32": "real_f32_split",
};

const WAT_DESCS = {
  combined: "f64 auto dispatch",
  real_combined: "f64 real",
  f32_dual: "f32 dual-complex",
  real_f32_dual: "f32 real",
  f32_split: "f32 split, fastest",
  real_f32_split: "f32 real, fastest",
};

const WASM_MODULES = {};
for (const surfaceId of ["complex-forward", "real-forward"]) {
  for (const entry of watEntriesFor(surfaceId)) {
    const id = WAT_IDS[`${entry.run}:${entry.precision}`] ?? entry.run;
    WASM_MODULES[id] = {
      path: `/wasm/${entry.module}`,
      name: entry.name,
      desc: WAT_DESCS[id] ?? entry.precision,
      isReal: surfaceId === "real-forward",
      isF32: entry.precision === "f32",
      layout: entry.layout,
      minSize: entry.minSize,
      maxSize: entry.maxSize,
      fftFn: entry.run,
      precomputeFn: entry.precompute,
      isWatFft: true,
    };
  }
}

// JavaScript/external FFT libraries
const JS_MODULES = {
  fftjs: {
    name: "fft.js",
    desc: "JS radix-4",
    isReal: false,
    isWatFft: false,
    library: "fftjs",
  },
  fftjs_real: {
    name: "fft.js Real",
    desc: "JS real",
    isReal: true,
    isWatFft: false,
    library: "fftjs",
  },
  fft_js: {
    name: "fft-js",
    desc: "JS Cooley-Tukey",
    isReal: false,
    isWatFft: false,
    library: "fft-js",
  },
  fftw_real: {
    name: "FFTW Real",
    desc: "WASM real",
    isReal: true,
    isWatFft: false,
    library: "fftw",
  },
  kissfft: {
    name: "KissFFT",
    desc: "WASM port",
    isReal: false,
    isWatFft: false,
    library: "kissfft",
  },
  webfft: {
    name: "WebFFT",
    desc: "meta-lib f32",
    isReal: false,
    isWatFft: false,
    library: "webfft",
  },
  // Note: WebFFT Real (fftr) is not available because it produces incorrect output.
  // DC signal gives all zeros, cosine gives near-zero magnitudes.
  pffft: {
    name: "PFFFT",
    desc: "WASM SIMD f32",
    isReal: false,
    isWatFft: false,
    library: "pffft",
  },
  pffft_real: {
    name: "PFFFT Real",
    desc: "WASM SIMD f32",
    isReal: true,
    isWatFft: false,
    library: "pffft",
  },
};

const ALL_MODULES = { ...WASM_MODULES, ...JS_MODULES };

const loadedModules = new Map();

/**
 * Get all available FFT modules for UI generation
 * @returns {Array<{id: string, name: string, desc: string, isReal: boolean, isWatFft: boolean}>}
 */
export function getAvailableModules() {
  return Object.entries(ALL_MODULES).map(([id, config]) => ({
    id,
    name: config.name,
    desc: config.desc,
    isReal: config.isReal || false,
    isWatFft: config.isWatFft || false,
  }));
}

export async function loadFFTModule(moduleId) {
  if (loadedModules.has(moduleId)) {
    return loadedModules.get(moduleId);
  }

  const config = ALL_MODULES[moduleId];
  if (!config) {
    throw new Error(`Unknown FFT module: ${moduleId}`);
  }

  let module;

  if (config.isWatFft) {
    // Load WASM module
    const response = await fetch(config.path);
    if (!response.ok) {
      throw new Error(`Failed to load ${config.path}: ${response.statusText}`);
    }

    const wasmBuffer = await response.arrayBuffer();
    const wasmModule = await WebAssembly.compile(wasmBuffer);
    const instance = await WebAssembly.instantiate(wasmModule);

    module = {
      id: moduleId,
      config,
      exports: instance.exports,
      memory: instance.exports.memory,
      type: "wasm",
    };
  } else {
    // JS library wrapper
    module = {
      id: moduleId,
      config,
      type: "js",
      library: config.library,
    };

    // FFTW needs async initialization
    if (config.library === "fftw") {
      module._fftw = await getFFTW();
    }

    // PFFFT needs async initialization
    if (config.library === "pffft") {
      module._pffft = await getPFFFT();
    }
  }

  loadedModules.set(moduleId, module);
  return module;
}

export function getModuleList() {
  return Object.entries(ALL_MODULES).map(([id, config]) => ({
    id,
    name: config.name,
    desc: config.desc,
    isReal: config.isReal,
    isWatFft: config.isWatFft,
  }));
}

/**
 * Create an FFT context for a given size
 */
export function createFFTContext(module, size, skipValidation = false) {
  let ctx;
  if (module.type === "wasm") {
    ctx = createWasmFFTContext(module, size);
  } else {
    ctx = createJSFFTContext(module, size);
  }

  // Validate FFT produces correct output (skip for benchmarks where we run many sizes)
  if (!skipValidation && size >= 64) {
    const isValid = validateFFTContext(ctx, size, ctx.isReal);
    if (!isValid) {
      const name = module.config?.name || module.library || "Unknown";
      throw new Error(
        `FFT validation failed for ${name} (size=${size}, isReal=${ctx.isReal}). ` +
          `This implementation produces incorrect output.`,
      );
    }
  }

  return ctx;
}

function createWasmFFTContext(module, size) {
  const { config, exports, memory } = module;

  if (size < config.minSize || size > config.maxSize) {
    throw new Error(
      `${config.name} supports FFT sizes ${config.minSize}..${config.maxSize} (requested ${size})`,
    );
  }

  const ArrayType = config.isF32 ? Float32Array : Float64Array;

  // Precompute twiddle factors
  exports[config.precomputeFn](size);

  if (config.layout === "complex-split") {
    // Split-plane module behind the interleaved facade the playground
    // expects: the deinterleave/interleave conversions are charged inside
    // run()/getOutputBuffer(), which is the honest cost of feeding it
    // interleaved app data (planar-native pipelines skip this).
    const realOffset =
      typeof exports.REAL_OFFSET === "number" ? exports.REAL_OFFSET : exports.REAL_OFFSET.value;
    const imagOffset =
      typeof exports.IMAG_OFFSET === "number" ? exports.IMAG_OFFSET : exports.IMAG_OFFSET.value;
    const realData = new Float32Array(memory.buffer, realOffset, size);
    const imagData = new Float32Array(memory.buffer, imagOffset, size);
    const staging = new Float32Array(size * 2);
    const output = new Float32Array(size * 2);

    return {
      module,
      size,
      inputSize: size * 2,
      outputSize: size * 2,
      ArrayType,
      isReal: false,

      getInputBuffer() {
        return staging;
      },

      getOutputBuffer() {
        for (let i = 0; i < size; i++) {
          output[i * 2] = realData[i];
          output[i * 2 + 1] = imagData[i];
        }
        return output;
      },

      run() {
        for (let i = 0; i < size; i++) {
          realData[i] = staging[i * 2];
          imagData[i] = staging[i * 2 + 1];
        }
        exports[config.fftFn](size);
      },
    };
  }

  // Interleaved-complex and packed-real modules: data lives at offset 0
  const inputSize = config.isReal ? size : size * 2;
  const outputSize = config.isReal ? (size / 2 + 1) * 2 : size * 2;

  return {
    module,
    size,
    inputSize,
    outputSize,
    ArrayType,
    isReal: config.isReal,

    getInputBuffer() {
      return new ArrayType(memory.buffer, 0, inputSize);
    },

    getOutputBuffer() {
      return new ArrayType(memory.buffer, 0, outputSize);
    },

    run() {
      exports[config.fftFn](size);
    },
  };
}

function createJSFFTContext(module, size) {
  const { config, library } = module;

  if (library === "fftjs") {
    const fft = new FFT(size);
    const complexInput = fft.createComplexArray();
    const complexOutput = fft.createComplexArray();

    if (config.isReal) {
      // Real FFT using fft.js
      const realInput = new Float64Array(size);
      // Pre-allocate output buffer for copying from Array to typed array
      const outputBuffer = new Float64Array((size / 2 + 1) * 2);

      return {
        module,
        size,
        inputSize: size,
        outputSize: (size / 2 + 1) * 2,
        ArrayType: Float64Array,
        isReal: true,
        _fft: fft,
        _realInput: realInput,
        _complexOutput: complexOutput,
        _outputBuffer: outputBuffer,

        getInputBuffer() {
          return this._realInput;
        },

        getOutputBuffer() {
          // fft.js createComplexArray() returns a regular Array, not a typed array
          // We need to copy the values to a Float64Array
          const len = this._outputBuffer.length;
          for (let i = 0; i < len; i++) {
            this._outputBuffer[i] = this._complexOutput[i];
          }
          return this._outputBuffer;
        },

        run() {
          // fft.js realTransform expects real input, outputs interleaved complex
          this._fft.realTransform(this._complexOutput, this._realInput);
        },
      };
    } else {
      // Complex FFT
      return {
        module,
        size,
        inputSize: size * 2,
        outputSize: size * 2,
        ArrayType: Float64Array,
        isReal: false,
        _fft: fft,
        _complexInput: complexInput,
        _complexOutput: complexOutput,

        getInputBuffer() {
          return this._complexInput;
        },

        getOutputBuffer() {
          return this._complexOutput;
        },

        run() {
          this._fft.transform(this._complexOutput, this._complexInput);
        },
      };
    }
  } else if (library === "fft-js") {
    // fft-js uses array of [real, imag] pairs
    const signal = Array.from({ length: size }, () => [0, 0]);
    const complexInput = new Float64Array(size * 2);
    let outputPhasors = null;

    return {
      module,
      size,
      inputSize: size * 2,
      outputSize: size * 2,
      ArrayType: Float64Array,
      isReal: false,
      _signal: signal,
      _complexInput: complexInput,

      getInputBuffer() {
        return this._complexInput;
      },

      getOutputBuffer() {
        // Convert phasors back to interleaved format
        const output = new Float64Array(size * 2);
        if (outputPhasors) {
          for (let i = 0; i < size; i++) {
            output[i * 2] = outputPhasors[i][0];
            output[i * 2 + 1] = outputPhasors[i][1];
          }
        }
        return output;
      },

      run() {
        // Convert interleaved to phasors
        for (let i = 0; i < size; i++) {
          this._signal[i][0] = this._complexInput[i * 2];
          this._signal[i][1] = this._complexInput[i * 2 + 1];
        }
        outputPhasors = fftJs.fft(this._signal);
      },
    };
  } else if (library === "fftw") {
    // FFTW context - uses pre-loaded module
    // Note: fftw-js only has real-to-complex FFT (FFT class) and real-to-real halfcomplex (RFFT class)
    // We use FFT class (r2c) for all options since it outputs interleaved complex which
    // is compatible with the spectrogram's computeMagnitude function
    const fftw = module._fftw;
    const realInput = new Float32Array(size);
    let output = null;

    return {
      module,
      size,
      inputSize: size,
      outputSize: (size / 2 + 1) * 2,
      ArrayType: Float32Array,
      isReal: true,
      _realInput: realInput,
      _fft: new fftw.FFT(size),

      getInputBuffer() {
        return this._realInput;
      },

      getOutputBuffer() {
        return output || new Float32Array((size / 2 + 1) * 2);
      },

      run() {
        output = this._fft.forward(this._realInput);
      },

      dispose() {
        this._fft.dispose();
      },
    };
  } else if (library === "kissfft") {
    const fftInstance = new kissfft.FFT(size);
    const complexInput = new Float64Array(size * 2);

    return {
      module,
      size,
      inputSize: size * 2,
      outputSize: size * 2,
      ArrayType: Float64Array,
      isReal: false,
      _fft: fftInstance,
      _complexInput: complexInput,
      _output: null,

      getInputBuffer() {
        return this._complexInput;
      },

      getOutputBuffer() {
        return this._output || new Float64Array(size * 2);
      },

      run() {
        this._output = this._fft.forward(this._complexInput);
      },

      dispose() {
        this._fft.dispose();
      },
    };
  } else if (library === "webfft") {
    // Note: WebFFT Real (fftr) is broken - produces zeros for DC signal
    // Only Complex FFT is supported
    const fftInstance = new webfft(size);
    fftInstance.setSubLibrary("kissWasm");

    const complexInput = new Float32Array(size * 2);

    return {
      module,
      size,
      inputSize: size * 2,
      outputSize: size * 2,
      ArrayType: Float32Array,
      isReal: false,
      _fft: fftInstance,
      _complexInput: complexInput,
      _output: null,

      getInputBuffer() {
        return this._complexInput;
      },

      getOutputBuffer() {
        return this._output || new Float32Array(size * 2);
      },

      run() {
        this._output = this._fft.fft(this._complexInput);
      },

      dispose() {
        this._fft.dispose();
      },
    };
  } else if (library === "pffft") {
    const pffft = module._pffft;
    // PFFFT enum: { PFFFT_REAL=0, PFFFT_COMPLEX=1 }
    const PFFFT_REAL = 0;
    const PFFFT_COMPLEX = 1;
    const PFFFT_FORWARD = 0;

    if (config.isReal) {
      // Real FFT - requires size >= 32
      if (size < 32) {
        throw new Error("PFFFT Real FFT requires size >= 32");
      }

      const setup = pffft._pffft_new_setup(size, PFFFT_REAL);
      const inputPtr = pffft._pffft_aligned_malloc(size * 4);
      const outputPtr = pffft._pffft_aligned_malloc(size * 4);
      const inputView = new Float32Array(pffft.HEAPF32.buffer, inputPtr, size);
      const outputView = new Float32Array(pffft.HEAPF32.buffer, outputPtr, size);
      // Pre-allocate interleaved output buffer for conversion
      const interleavedOutput = new Float32Array((size / 2 + 1) * 2);

      return {
        module,
        size,
        inputSize: size,
        outputSize: (size / 2 + 1) * 2,
        ArrayType: Float32Array,
        isReal: true,
        _setup: setup,
        _inputPtr: inputPtr,
        _outputPtr: outputPtr,
        _inputView: inputView,
        _outputView: outputView,
        _interleavedOutput: interleavedOutput,
        _pffft: pffft,

        getInputBuffer() {
          return this._inputView;
        },

        getOutputBuffer() {
          // Convert pffft packed format to standard interleaved complex
          // pffft format: [DC_real, Nyquist_real, bin1_real, bin1_imag, bin2_real, bin2_imag, ...]
          // Standard format: [bin0_real, bin0_imag, bin1_real, bin1_imag, ..., binN/2_real, binN/2_imag]
          const out = this._interleavedOutput;
          const pffftOut = this._outputView;
          const halfSize = size / 2;

          // Bin 0 (DC) - imag is 0
          out[0] = pffftOut[0];
          out[1] = 0;

          // Bins 1 to N/2-1 - complex
          for (let i = 1; i < halfSize; i++) {
            out[i * 2] = pffftOut[2 * i];
            out[i * 2 + 1] = pffftOut[2 * i + 1];
          }

          // Bin N/2 (Nyquist) - imag is 0
          out[halfSize * 2] = pffftOut[1];
          out[halfSize * 2 + 1] = 0;

          return out;
        },

        run() {
          this._pffft._pffft_transform_ordered(
            this._setup,
            this._inputPtr,
            this._outputPtr,
            0,
            PFFFT_FORWARD,
          );
        },

        dispose() {
          this._pffft._pffft_aligned_free(this._inputPtr);
          this._pffft._pffft_aligned_free(this._outputPtr);
          this._pffft._pffft_destroy_setup(this._setup);
        },
      };
    } else {
      // Complex FFT
      const setup = pffft._pffft_new_setup(size, PFFFT_COMPLEX);
      const inputPtr = pffft._pffft_aligned_malloc(size * 2 * 4);
      const outputPtr = pffft._pffft_aligned_malloc(size * 2 * 4);
      const inputView = new Float32Array(pffft.HEAPF32.buffer, inputPtr, size * 2);
      const outputView = new Float32Array(pffft.HEAPF32.buffer, outputPtr, size * 2);

      return {
        module,
        size,
        inputSize: size * 2,
        outputSize: size * 2,
        ArrayType: Float32Array,
        isReal: false,
        _setup: setup,
        _inputPtr: inputPtr,
        _outputPtr: outputPtr,
        _inputView: inputView,
        _outputView: outputView,
        _pffft: pffft,

        getInputBuffer() {
          return this._inputView;
        },

        getOutputBuffer() {
          return this._outputView;
        },

        run() {
          this._pffft._pffft_transform_ordered(
            this._setup,
            this._inputPtr,
            this._outputPtr,
            0,
            PFFFT_FORWARD,
          );
        },

        dispose() {
          this._pffft._pffft_aligned_free(this._inputPtr);
          this._pffft._pffft_aligned_free(this._outputPtr);
          this._pffft._pffft_destroy_setup(this._setup);
        },
      };
    }
  }

  throw new Error(`Unknown library: ${library}`);
}
