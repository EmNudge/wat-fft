/**
 * FFT Module Loader
 *
 * Loads and manages different FFT implementations:
 * - wat-fft WASM modules
 * - Competitor JS/WASM libraries (fft.js, kissfft-js)
 */

import FFT from "fft.js";
import * as fftJs from "fft-js";
import kissfft from "kissfft-js";

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

// wat-fft WASM modules
const WASM_MODULES = {
  combined: {
    path: "/wasm/fft_combined.wasm",
    name: "wat-fft Combined",
    desc: "f64 auto",
    isReal: false,
    isF32: false,
    fftFn: "fft",
    precomputeFn: "precompute_twiddles",
    isWatFft: true,
  },
  combined_stockham: {
    path: "/wasm/combined_stockham.wasm",
    name: "wat-fft Stockham",
    desc: "f64 SIMD",
    isReal: false,
    isF32: false,
    fftFn: "fft_stockham",
    precomputeFn: "precompute_twiddles",
    isWatFft: true,
  },
  real_combined: {
    path: "/wasm/fft_real_combined.wasm",
    name: "wat-fft Real",
    desc: "f64 real",
    isReal: true,
    isF32: false,
    fftFn: "rfft",
    precomputeFn: "precompute_rfft_twiddles",
    isWatFft: true,
  },
  f32_dual: {
    path: "/wasm/fft_stockham_f32_dual.wasm",
    name: "wat-fft f32",
    desc: "fastest",
    isReal: false,
    isF32: true,
    fftFn: "fft",
    precomputeFn: "precompute_twiddles",
    isWatFft: true,
  },
  real_f32_dual: {
    path: "/wasm/fft_real_f32_dual.wasm",
    name: "wat-fft Real f32",
    desc: "fast real",
    isReal: true,
    isF32: true,
    fftFn: "rfft",
    precomputeFn: "precompute_rfft_twiddles",
    isWatFft: true,
  },
};

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
};

const ALL_MODULES = { ...WASM_MODULES, ...JS_MODULES };

const loadedModules = new Map();

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
export function createFFTContext(module, size) {
  if (module.type === "wasm") {
    return createWasmFFTContext(module, size);
  } else {
    return createJSFFTContext(module, size);
  }
}

function createWasmFFTContext(module, size) {
  const { config, exports, memory } = module;
  const ArrayType = config.isF32 ? Float32Array : Float64Array;

  // Precompute twiddle factors
  exports[config.precomputeFn](size);

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
    const signal = new Array(size);
    for (let i = 0; i < size; i++) {
      signal[i] = [0, 0];
    }
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
  }

  throw new Error(`Unknown library: ${library}`);
}
