import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

async function test() {
  // Load working f32 FFT
  const workingPath = path.join(__dirname, "..", "dist", "fft_stockham_f32_dual.wasm");
  const workingBuf = fs.readFileSync(workingPath);
  const workingMod = await WebAssembly.compile(workingBuf);
  const workingInst = await WebAssembly.instantiate(workingMod);
  const working = workingInst.exports;

  // Load split FFT
  const splitPath = path.join(__dirname, "..", "dist", "fft_split_native_f32.wasm");
  const splitBuf = fs.readFileSync(splitPath);
  const splitMod = await WebAssembly.compile(splitBuf);
  const splitInst = await WebAssembly.instantiate(splitMod);
  const split = splitInst.exports;

  // Test N=64
  const N = 64;

  // Random input
  const real = [];
  const imag = [];
  for (let i = 0; i < N; i++) {
    real.push(Math.sin(i * 0.3) * 0.5);
    imag.push(Math.cos(i * 0.2) * 0.3);
  }

  // Run working FFT (interleaved format)
  const workingView = new Float32Array(working.memory.buffer, 0, N * 2);
  for (let i = 0; i < N; i++) {
    workingView[i * 2] = real[i];
    workingView[i * 2 + 1] = imag[i];
  }
  working.precompute_twiddles(N);
  working.fft(N);

  console.log("Working FFT output (first 8):");
  for (let i = 0; i < Math.min(8, N); i++) {
    console.log(
      "  X[" +
        i +
        "] = " +
        workingView[i * 2].toFixed(6) +
        " + " +
        workingView[i * 2 + 1].toFixed(6) +
        "i",
    );
  }

  // Run split FFT
  const splitRe = new Float32Array(split.memory.buffer, 0, N);
  const splitIm = new Float32Array(split.memory.buffer, 0x8000, N);
  for (let i = 0; i < N; i++) {
    splitRe[i] = real[i];
    splitIm[i] = imag[i];
  }
  split.precompute_twiddles_split(N);
  split.fft_split(N);

  console.log("\nSplit FFT output (first 8):");
  for (let i = 0; i < Math.min(8, N); i++) {
    console.log("  X[" + i + "] = " + splitRe[i].toFixed(6) + " + " + splitIm[i].toFixed(6) + "i");
  }

  // Compare
  console.log("\nDifference:");
  let maxErr = 0;
  for (let i = 0; i < N; i++) {
    const errRe = Math.abs(workingView[i * 2] - splitRe[i]);
    const errIm = Math.abs(workingView[i * 2 + 1] - splitIm[i]);
    maxErr = Math.max(maxErr, errRe, errIm);
    if (errRe > 1e-5 || errIm > 1e-5) {
      console.log(
        "  X[" + i + "]: re err=" + errRe.toExponential(2) + ", im err=" + errIm.toExponential(2),
      );
    }
  }
  console.log("Max error vs working: " + maxErr.toExponential(2));
}

test();
