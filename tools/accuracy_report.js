/**
 * Numerical Accuracy Report
 *
 * Measures the numerical error of every WASM FFT module against the f64
 * reference DFT, for every transform direction, across sizes. This turns
 * "the tests pass under tolerance X" into actual data: you can see how
 * error grows with N per module, compare modules, and catch precision
 * regressions that stay under coarse test tolerances.
 *
 * Metrics (all relative to the reference output's scale):
 *   max-rel:  max_i |out[i] - ref[i]| / max_i |ref[i]|
 *   rms-rel:  sqrt(sum |out-ref|^2 / sum |ref|^2)
 *   quality:  max-rel / (eps * sqrt(log2 N)) — error growth for a well-
 *             implemented FFT is O(eps * sqrt(log N)), so this column
 *             should stay roughly flat across N. A jump at one size
 *             points at a bad codelet/twiddle for that size.
 *
 * Usage:
 *   node tools/accuracy_report.js            # table
 *   node tools/accuracy_report.js --json     # also write benchmarks/results/accuracy.latest.json
 *
 * The threshold assertions live in tests/accuracy.test.js and use
 * measureAccuracy() from this file, so tool and test can never disagree.
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { referenceDFT, referenceRealDFT } from "../tests/dft-reference.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const distDir = path.join(__dirname, "..", "dist");

const F32_EPS = 2 ** -23;
const F64_EPS = 2 ** -52;

export const SIZES = [16, 32, 64, 128, 256, 512, 1024, 2048, 4096];

async function loadWasm(name) {
  const wasmBuffer = fs.readFileSync(path.join(distDir, `${name}.wasm`));
  const { instance } = await WebAssembly.instantiate(wasmBuffer, {});
  return instance.exports;
}

// Deterministic input so results are comparable across runs/commits
function seededSignal(n, seed) {
  let s = seed;
  const rand = () => {
    s = (s * 1103515245 + 12345) & 0x7fffffff;
    return (s / 0x7fffffff) * 2 - 1;
  };
  const out = new Float64Array(n);
  for (let i = 0; i < n; i++) out[i] = rand();
  return out;
}

function errorStats(actual, expected, eps, n) {
  let scale = 0;
  let refEnergy = 0;
  let maxAbs = 0;
  let diffEnergy = 0;
  for (let i = 0; i < expected.length; i++) {
    const ref = expected[i];
    const diff = Math.abs(actual[i] - ref);
    scale = Math.max(scale, Math.abs(ref));
    maxAbs = Math.max(maxAbs, diff);
    refEnergy += ref * ref;
    diffEnergy += diff * diff;
  }
  const maxRel = maxAbs / scale;
  return {
    maxRel,
    rmsRel: Math.sqrt(diffEnergy / refEnergy),
    quality: maxRel / (eps * Math.sqrt(Math.log2(n))),
  };
}

// Interleave split {real, imag} into [re0, im0, re1, im1, ...]
function interleave(real, imag) {
  const out = new Float64Array(real.length * 2);
  for (let i = 0; i < real.length; i++) {
    out[i * 2] = real[i];
    out[i * 2 + 1] = imag[i];
  }
  return out;
}

/**
 * Measure accuracy of every module x transform x size.
 * @returns {Promise<Array<{module, transform, precision, n, maxRel, rmsRel, quality}>>}
 */
export async function measureAccuracy(sizes = SIZES) {
  const f64 = await loadWasm("fft_combined");
  const f32dual = await loadWasm("fft_stockham_f32_dual");
  const split = await loadWasm("fft_split_native_f32");
  const realF64 = await loadWasm("fft_real_combined");
  const realF32 = await loadWasm("fft_real_f32_dual");

  const rows = [];
  const add = (module, transform, precision, n, stats) =>
    rows.push({ module, transform, precision, n, ...stats });

  for (const n of sizes) {
    const sigRe = seededSignal(n, 12345 + n);
    const sigIm = seededSignal(n, 54321 + n);
    const realSig = seededSignal(n, 98765 + n);
    const spectrum = referenceDFT(sigRe, sigIm);
    const realSpectrum = referenceRealDFT(realSig);
    const interleavedIn = interleave(sigRe, sigIm);
    const interleavedSpec = interleave(spectrum.real, spectrum.imag);
    const interleavedRealSpec = interleave(realSpectrum.real, realSpectrum.imag);

    // --- fft_combined (f64, interleaved) ---
    {
      const data = new Float64Array(f64.memory.buffer, 0, n * 2);
      f64.precompute_twiddles(n);

      data.set(interleavedIn);
      f64.fft(n);
      add("fft_combined", "fft", "f64", n, errorStats(data, interleavedSpec, F64_EPS, n));

      data.set(interleavedSpec);
      f64.ifft(n);
      add("fft_combined", "ifft", "f64", n, errorStats(data, interleavedIn, F64_EPS, n));
    }

    // --- fft_stockham_f32_dual (f32, interleaved) ---
    {
      const data = new Float32Array(f32dual.memory.buffer, 0, n * 2);
      f32dual.precompute_twiddles(n);

      data.set(interleavedIn);
      f32dual.fft(n);
      add("fft_stockham_f32_dual", "fft", "f32", n, errorStats(data, interleavedSpec, F32_EPS, n));

      data.set(interleavedSpec);
      f32dual.ifft(n);
      add("fft_stockham_f32_dual", "ifft", "f32", n, errorStats(data, interleavedIn, F32_EPS, n));
    }

    // --- fft_split_native_f32 (f32, split re/im arrays) ---
    {
      const re = new Float32Array(split.memory.buffer, split.REAL_OFFSET, n);
      const im = new Float32Array(split.memory.buffer, split.IMAG_OFFSET, n);
      split.precompute_twiddles_split(n);

      re.set(sigRe);
      im.set(sigIm);
      split.fft_split(n);
      const fwd = interleave(re, im);
      add(
        "fft_split_native_f32",
        "fft_split",
        "f32",
        n,
        errorStats(fwd, interleavedSpec, F32_EPS, n),
      );

      re.set(spectrum.real);
      im.set(spectrum.imag);
      split.ifft_split(n);
      const inv = interleave(re, im);
      add(
        "fft_split_native_f32",
        "ifft_split",
        "f32",
        n,
        errorStats(inv, interleavedIn, F32_EPS, n),
      );
    }

    // rfft_split/irfft_split require N >= 32
    if (n >= 32) {
      split.precompute_rfft_twiddles_split(n);

      new Float32Array(split.memory.buffer, 0, n).set(realSig);
      split.rfft_split(n);
      const out = new Float32Array(split.memory.buffer, 0, n + 2);
      add(
        "fft_split_native_f32",
        "rfft_split",
        "f32",
        n,
        errorStats(out, interleavedRealSpec, F32_EPS, n),
      );

      new Float32Array(split.memory.buffer, 0, n + 2).set(interleavedRealSpec);
      split.irfft_split(n);
      const inv = new Float32Array(split.memory.buffer, 0, n);
      add("fft_split_native_f32", "irfft_split", "f32", n, errorStats(inv, realSig, F32_EPS, n));
    }

    // --- fft_real_combined (f64, packed real -> N/2+1 interleaved bins) ---
    {
      new Float64Array(realF64.memory.buffer, 0, n).set(realSig);
      realF64.precompute_rfft_twiddles(n);
      realF64.rfft(n);
      const out = new Float64Array(realF64.memory.buffer, 0, n + 2);
      add("fft_real_combined", "rfft", "f64", n, errorStats(out, interleavedRealSpec, F64_EPS, n));
    }

    // --- fft_real_f32_dual (f32, packed real -> N/2+1 interleaved bins) ---
    {
      realF32.precompute_rfft_twiddles(n);

      new Float32Array(realF32.memory.buffer, 0, n).set(realSig);
      realF32.rfft(n);
      const out = new Float32Array(realF32.memory.buffer, 0, n + 2);
      add("fft_real_f32_dual", "rfft", "f32", n, errorStats(out, interleavedRealSpec, F32_EPS, n));

      new Float32Array(realF32.memory.buffer, 0, n + 2).set(interleavedRealSpec);
      realF32.irfft(n);
      const inv = new Float32Array(realF32.memory.buffer, 0, n);
      add("fft_real_f32_dual", "irfft", "f32", n, errorStats(inv, realSig, F32_EPS, n));
    }
  }

  return rows;
}

function printReport(rows) {
  const byModule = new Map();
  for (const row of rows) {
    const key = `${row.module} :: ${row.transform} (${row.precision})`;
    if (!byModule.has(key)) byModule.set(key, []);
    byModule.get(key).push(row);
  }

  console.log("=".repeat(74));
  console.log("FFT Numerical Accuracy Report (vs f64 reference DFT, seeded input)");
  console.log("=".repeat(74));
  console.log("quality = max-rel / (eps*sqrt(log2 N)); should stay roughly flat with N");

  for (const [key, moduleRows] of byModule) {
    console.log("");
    console.log(key);
    console.log("  N        max-rel      rms-rel    quality");
    console.log("  " + "-".repeat(44));
    for (const r of moduleRows) {
      console.log(
        `  ${String(r.n).padEnd(6)} ${r.maxRel.toExponential(2).padStart(9)}  ${r.rmsRel.toExponential(2).padStart(9)} ${r.quality.toFixed(1).padStart(9)}`,
      );
    }
  }
  console.log("");
}

async function main() {
  const rows = await measureAccuracy();
  printReport(rows);

  if (process.argv.includes("--json")) {
    const resultsDir = path.join(__dirname, "..", "benchmarks", "results");
    fs.mkdirSync(resultsDir, { recursive: true });
    const outPath = path.join(resultsDir, "accuracy.latest.json");
    fs.writeFileSync(
      outPath,
      JSON.stringify({ version: 1, timestamp: new Date().toISOString(), rows }, null, 2) + "\n",
    );
    console.log(`JSON saved: ${path.relative(process.cwd(), outPath)}`);
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
