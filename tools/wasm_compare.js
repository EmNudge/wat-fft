/**
 * WASM vs JS Stage Comparison Tool
 *
 * Compares WASM Stockham FFT output against the JS reference implementation.
 * Since we can't easily hook into WASM mid-execution, we compare final outputs
 * and use the JS reference's stage-by-stage output to understand where things diverge.
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import {
  stockhamRadix2 as stockhamFFT,
  referenceDFT,
  compareResults,
} from "./stockham_reference.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

/**
 * Load WASM module
 */
async function loadWasm(name = "fft_combined") {
  const wasmPath = path.join(__dirname, "..", "dist", `${name}.wasm`);
  if (!fs.existsSync(wasmPath)) {
    throw new Error(`WASM not found: ${wasmPath}`);
  }
  const wasmBuffer = fs.readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);
  const instance = await WebAssembly.instantiate(wasmModule);
  return instance.exports;
}

/**
 * Run WASM FFT and return results
 */
function runWasmFFT(wasm, fftFunc, real, imag, precompute = true) {
  const n = real.length;
  const memory = wasm.memory;
  const data = new Float64Array(memory.buffer, 0, n * 2);

  // Copy input to WASM memory
  for (let i = 0; i < n; i++) {
    data[i * 2] = real[i];
    data[i * 2 + 1] = imag[i];
  }

  if (precompute && wasm.precompute_twiddles) {
    wasm.precompute_twiddles(n);
  }

  wasm[fftFunc](n);

  // Extract results
  const resultData = new Float64Array(memory.buffer, 0, n * 2);
  const outReal = new Float64Array(n);
  const outImag = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    outReal[i] = resultData[i * 2];
    outImag[i] = resultData[i * 2 + 1];
  }

  return { real: outReal, imag: outImag };
}

/**
 * Dump WASM memory regions for debugging
 */
function dumpWasmMemory(wasm, n, regions = ["data", "secondary", "twiddles"]) {
  const memory = wasm.memory;
  const buffer = memory.buffer;

  const result = {};

  if (regions.includes("data")) {
    const data = new Float64Array(buffer, 0, n * 2);
    result.data = {
      real: new Float64Array(n),
      imag: new Float64Array(n),
    };
    for (let i = 0; i < n; i++) {
      result.data.real[i] = data[i * 2];
      result.data.imag[i] = data[i * 2 + 1];
    }
  }

  if (regions.includes("secondary")) {
    const secondary = new Float64Array(buffer, 65536, n * 2);
    result.secondary = {
      real: new Float64Array(n),
      imag: new Float64Array(n),
    };
    for (let i = 0; i < n; i++) {
      result.secondary.real[i] = secondary[i * 2];
      result.secondary.imag[i] = secondary[i * 2 + 1];
    }
  }

  if (regions.includes("twiddles")) {
    const twiddles = new Float64Array(buffer, 131072, n * 2);
    result.twiddles = {
      real: new Float64Array(n),
      imag: new Float64Array(n),
    };
    for (let i = 0; i < n; i++) {
      result.twiddles.real[i] = twiddles[i * 2];
      result.twiddles.imag[i] = twiddles[i * 2 + 1];
    }
  }

  return result;
}

/**
 * Compare twiddle factors
 */
function compareTwiddles(wasm, n) {
  const memory = new Float64Array(wasm.memory.buffer, 131072, n * 2);

  console.log(`\nTwiddle Factor Comparison (N=${n}):`);
  console.log("─".repeat(60));
  console.log("Index    WASM                      Expected");
  console.log("─".repeat(60));

  let allMatch = true;
  for (let k = 0; k < Math.min(n, 16); k++) {
    const wasmReal = memory[k * 2];
    const wasmImag = memory[k * 2 + 1];

    const angle = (-2 * Math.PI * k) / n;
    const expReal = Math.cos(angle);
    const expImag = Math.sin(angle);

    const realMatch = Math.abs(wasmReal - expReal) < 1e-10;
    const imagMatch = Math.abs(wasmImag - expImag) < 1e-10;
    const match = realMatch && imagMatch;
    if (!match) allMatch = false;

    const wasmStr = `${wasmReal.toFixed(6)} ${wasmImag >= 0 ? "+" : ""}${wasmImag.toFixed(6)}i`;
    const expStr = `${expReal.toFixed(6)} ${expImag >= 0 ? "+" : ""}${expImag.toFixed(6)}i`;

    console.log(
      `[${k.toString().padStart(3)}]  ${wasmStr.padEnd(24)} ${expStr.padEnd(24)} ${match ? "✓" : "✗"}`,
    );
  }

  if (n > 16) {
    console.log(`... (${n - 16} more)`);
  }

  console.log("─".repeat(60));
  console.log(allMatch ? "✓ All twiddle factors match" : "✗ Some twiddle factors differ");
  return allMatch;
}

/**
 * Test input generators
 */
const testInputs = {
  impulse: (n) => {
    const real = new Float64Array(n);
    const imag = new Float64Array(n);
    real[0] = 1;
    return { real, imag, name: "impulse" };
  },

  ramp: (n) => {
    const real = new Float64Array(n);
    const imag = new Float64Array(n);
    for (let i = 0; i < n; i++) {
      real[i] = i;
    }
    return { real, imag, name: "ramp" };
  },

  alternating: (n) => {
    const real = new Float64Array(n);
    const imag = new Float64Array(n);
    for (let i = 0; i < n; i++) {
      real[i] = i % 2 === 0 ? 1 : -1;
    }
    return { real, imag, name: "alternating" };
  },

  sine: (n) => {
    const real = new Float64Array(n);
    const imag = new Float64Array(n);
    for (let i = 0; i < n; i++) {
      real[i] = Math.sin((2 * Math.PI * i) / n);
    }
    return { real, imag, name: "sine" };
  },

  random: (n, seed = 12345) => {
    const real = new Float64Array(n);
    const imag = new Float64Array(n);
    let s = seed;
    const rand = () => {
      s = (s * 1103515245 + 12345) & 0x7fffffff;
      return (s / 0x7fffffff) * 2 - 1;
    };
    for (let i = 0; i < n; i++) {
      real[i] = rand();
      imag[i] = rand();
    }
    return { real, imag, name: "random" };
  },
};

/**
 * Print complex array
 */
function printComplex(label, real, imag, limit = 8) {
  console.log(`\n${label}:`);
  const n = real.length;
  for (let i = 0; i < Math.min(limit, n); i++) {
    const sign = imag[i] >= 0 ? "+" : "";
    console.log(`  [${i}] ${real[i].toFixed(6)} ${sign}${imag[i].toFixed(6)}i`);
  }
  if (n > limit) {
    console.log(`  ... (${n - limit} more)`);
  }
}

/**
 * Full comparison report
 */
async function fullComparison(n, inputType = "impulse", verbose = true) {
  console.log(`\n${"═".repeat(70)}`);
  console.log(`WASM vs JS Stockham Comparison: N=${n}, input=${inputType}`);
  console.log(`${"═".repeat(70)}`);

  // Load WASM
  const wasm = await loadWasm("stockham");

  // Generate input
  const input = testInputs[inputType](n);
  if (verbose) {
    printComplex("Input", input.real, input.imag);
  }

  // Run WASM
  wasm.precompute_twiddles(n);
  const wasmResult = runWasmFFT(wasm, "fft_stockham", input.real, input.imag);

  // Run JS reference
  const jsResult = stockhamFFT(input.real, input.imag, { verbose: false, returnStages: true });

  // Run DFT reference
  const dftResult = referenceDFT(input.real, input.imag);

  if (verbose) {
    printComplex("WASM Output", wasmResult.real, wasmResult.imag);
    printComplex("JS Stockham Output", jsResult.real, jsResult.imag);
    printComplex("Reference DFT", dftResult.real, dftResult.imag);
  }

  // Compare WASM vs DFT
  console.log("\n" + "─".repeat(70));
  console.log("Comparison Results:");
  console.log("─".repeat(70));

  const wasmVsDft = compareResults(wasmResult, dftResult);
  const jsVsDft = compareResults(jsResult, dftResult);
  const wasmVsJs = compareResults(wasmResult, jsResult);

  console.log(
    `\nWASM vs DFT: ${wasmVsDft.length === 0 ? "✓ MATCH" : `✗ ${wasmVsDft.length} errors`}`,
  );
  if (wasmVsDft.length > 0 && verbose) {
    for (const err of wasmVsDft.slice(0, 5)) {
      console.log(
        `  [${err.index}].${err.component}: WASM=${err.actual.toFixed(6)}, DFT=${err.expected.toFixed(6)}, diff=${err.diff.toExponential(2)}`,
      );
    }
  }

  console.log(
    `\nJS Stockham vs DFT: ${jsVsDft.length === 0 ? "✓ MATCH" : `✗ ${jsVsDft.length} errors`}`,
  );
  if (jsVsDft.length > 0 && verbose) {
    for (const err of jsVsDft.slice(0, 5)) {
      console.log(
        `  [${err.index}].${err.component}: JS=${err.actual.toFixed(6)}, DFT=${err.expected.toFixed(6)}, diff=${err.diff.toExponential(2)}`,
      );
    }
  }

  console.log(
    `\nWASM vs JS Stockham: ${wasmVsJs.length === 0 ? "✓ MATCH" : `✗ ${wasmVsJs.length} errors`}`,
  );
  if (wasmVsJs.length > 0 && verbose) {
    for (const err of wasmVsJs.slice(0, 5)) {
      console.log(
        `  [${err.index}].${err.component}: WASM=${err.actual.toFixed(6)}, JS=${err.expected.toFixed(6)}, diff=${err.diff.toExponential(2)}`,
      );
    }
  }

  // Check twiddles
  console.log("\n" + "─".repeat(70));
  compareTwiddles(wasm, n);

  console.log("\n" + "═".repeat(70));

  return {
    wasmVsDft,
    jsVsDft,
    wasmVsJs,
    wasmResult,
    jsResult,
    dftResult,
  };
}

/**
 * Find first divergence point between arrays
 */
function _findDivergence(actual, expected, tolerance = 1e-10) {
  const n = Math.min(actual.length, expected.length);
  for (let i = 0; i < n; i++) {
    if (Math.abs(actual[i] - expected[i]) > tolerance) {
      return {
        index: i,
        actual: actual[i],
        expected: expected[i],
        diff: Math.abs(actual[i] - expected[i]),
      };
    }
  }
  return null;
}

/**
 * Run comparison for multiple sizes
 */
async function testMultipleSizes(sizes = [4, 8, 16, 32, 64], inputType = "impulse") {
  console.log(`\n${"═".repeat(70)}`);
  console.log(`Multi-Size Stockham Comparison: ${inputType} input`);
  console.log(`${"═".repeat(70)}\n`);

  const wasm = await loadWasm("stockham");
  const results = [];

  console.log("Size     WASM vs DFT    JS vs DFT    WASM vs JS");
  console.log("─".repeat(55));

  for (const n of sizes) {
    const input = testInputs[inputType](n);

    wasm.precompute_twiddles(n);
    const wasmResult = runWasmFFT(wasm, "fft_stockham", input.real, input.imag);
    const jsResult = stockhamFFT(input.real, input.imag);
    const dftResult = referenceDFT(input.real, input.imag);

    const wasmVsDft = compareResults(wasmResult, dftResult);
    const jsVsDft = compareResults(jsResult, dftResult);
    const wasmVsJs = compareResults(wasmResult, jsResult);

    const wasmDftStatus = wasmVsDft.length === 0 ? "✓" : `✗ (${wasmVsDft.length})`;
    const jsDftStatus = jsVsDft.length === 0 ? "✓" : `✗ (${jsVsDft.length})`;
    const wasmJsStatus = wasmVsJs.length === 0 ? "✓" : `✗ (${wasmVsJs.length})`;

    console.log(
      `N=${n.toString().padEnd(5)}  ${wasmDftStatus.padEnd(13)} ${jsDftStatus.padEnd(12)} ${wasmJsStatus}`,
    );

    results.push({ n, wasmVsDft, jsVsDft, wasmVsJs });
  }

  console.log("─".repeat(55));

  const passing = results.filter((r) => r.wasmVsDft.length === 0);
  const failing = results.filter((r) => r.wasmVsDft.length > 0);

  console.log(`\n✓ Passing sizes: ${passing.map((r) => r.n).join(", ") || "none"}`);
  console.log(`✗ Failing sizes: ${failing.map((r) => r.n).join(", ") || "none"}`);

  return results;
}

// CLI interface
if (process.argv[1].endsWith("wasm_compare.js")) {
  const cmd = process.argv[2] || "compare";
  const n = parseInt(process.argv[3]) || 16;
  const inputType = process.argv[4] || "impulse";

  switch (cmd) {
    case "compare":
      fullComparison(n, inputType).catch(console.error);
      break;
    case "multi":
      testMultipleSizes([4, 8, 16, 32, 64], inputType).catch(console.error);
      break;
    case "twiddles":
      loadWasm("stockham")
        .then((wasm) => {
          wasm.precompute_twiddles(n);
          compareTwiddles(wasm, n);
        })
        .catch(console.error);
      break;
    default:
      console.log("Usage:");
      console.log("  node wasm_compare.js compare [N] [inputType]  - Compare WASM vs JS");
      console.log("  node wasm_compare.js multi [sizes] [inputType] - Test multiple sizes");
      console.log("  node wasm_compare.js twiddles [N]              - Check twiddle factors");
      console.log("");
      console.log("Input types: impulse, ramp, alternating, sine, random");
  }
}

export {
  loadWasm,
  runWasmFFT,
  dumpWasmMemory,
  compareTwiddles,
  testInputs,
  fullComparison,
  testMultipleSizes,
};
