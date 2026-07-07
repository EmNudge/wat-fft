/**
 * Benchmark: f32 Dual-Complex Inverse FFT vs fft.js and pffft-wasm
 *
 * Note: pffft's backward transform is unscaled (no 1/N), while wat-fft and
 * fft.js include the 1/N normalization. pffft therefore does slightly less work.
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import FFT from "fft.js";
import PFFFT from "@echogarden/pffft-wasm/simd";
import {
  DEFAULT_CONFIG,
  printResults,
  runBenchmark,
  saveResults,
  seededRandom,
} from "./lib/harness.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Load WASM modules
async function loadWasm(name) {
  const wasmPath = path.join(__dirname, "..", "dist", `${name}.wasm`);
  const wasmBuffer = fs.readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);
  const instance = await WebAssembly.instantiate(wasmModule, {});
  return instance.exports;
}

const SIZES = [64, 128, 256, 512, 1024, 2048, 4096];

// Generate deterministic f32 complex input (a spectrum to invert)
function generateInputF32(n) {
  const rand = seededRandom(n);
  const input = new Float32Array(n * 2);
  for (let i = 0; i < n * 2; i++) {
    input[i] = rand();
  }
  return input;
}

async function runBenchmarks() {
  console.log("=".repeat(70));
  console.log("f32 Dual-Complex Inverse FFT Benchmark");
  console.log("=".repeat(70));
  console.log(
    `Samples: ${DEFAULT_CONFIG.samples} x ${DEFAULT_CONFIG.sampleMs}ms per test (median reported)`,
  );
  console.log("");

  const wasm = await loadWasm("fft_stockham_f32_dual");
  const pffft = await PFFFT();

  // PFFFT enums: transform type { PFFFT_REAL=0, PFFFT_COMPLEX=1 },
  // direction { PFFFT_FORWARD=0, PFFFT_BACKWARD=1 }
  const PFFFT_COMPLEX = 1;
  const PFFFT_BACKWARD = 1;

  const sizeGroups = [];

  for (const n of SIZES) {
    console.log("-".repeat(70));
    console.log(`IFFT Size: N=${n}`);
    console.log("-".repeat(70));

    const inputF32 = generateInputF32(n);
    const results = [];

    // 1. wat-fft f32 IFFT
    const wasmResult = runBenchmark(
      "wat-fft (f32)",
      () => {
        const memory = wasm.memory;
        const data = new Float32Array(memory.buffer, 0, n * 2);
        wasm.precompute_twiddles(n);
        return { data, inputBuffer: inputF32 };
      },
      (ctx) => {
        ctx.data.set(ctx.inputBuffer);
        wasm.ifft(n);
      },
    );
    results.push(wasmResult);

    // 2. pffft-wasm (f32 WASM competitor, unscaled backward transform)
    const pffftResult = runBenchmark(
      "pffft-wasm (f32)",
      () => {
        const setup = pffft._pffft_new_setup(n, PFFFT_COMPLEX);
        const inputPtr = pffft._pffft_aligned_malloc(n * 2 * 4);
        const outputPtr = pffft._pffft_aligned_malloc(n * 2 * 4);
        const inputView = new Float32Array(pffft.HEAPF32.buffer, inputPtr, n * 2);
        return { setup, inputPtr, outputPtr, inputView, inputBuffer: inputF32 };
      },
      (ctx) => {
        // Stage input per iteration, same as every other context
        ctx.inputView.set(ctx.inputBuffer);
        pffft._pffft_transform_ordered(ctx.setup, ctx.inputPtr, ctx.outputPtr, 0, PFFFT_BACKWARD);
      },
    );
    results.push(pffftResult);

    // 3. fft.js (JS reference, scaled inverse)
    const inputF64 = Array.from(inputF32);
    const fftJs = new FFT(n);
    const fftJsResult = runBenchmark(
      "fft.js (f64 JS)",
      () => {
        const fftInput = inputF64.slice();
        const fftOutput = fftJs.createComplexArray();
        return { fftInput, fftOutput };
      },
      (ctx) => {
        fftJs.inverseTransform(ctx.fftOutput, ctx.fftInput);
      },
    );
    results.push(fftJsResult);

    printResults(results);
    sizeGroups.push({ size: n, results });
    console.log("");
  }

  console.log("=".repeat(70));
  console.log("Benchmark complete!");
  console.log("=".repeat(70));

  saveResults("ifft-f32", sizeGroups);
}

runBenchmarks().catch(console.error);
