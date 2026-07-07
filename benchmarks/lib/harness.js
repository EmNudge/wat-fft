/**
 * Shared benchmark harness with statistical sampling and JSON persistence.
 *
 * Replaces the old single-2s-run measurement with repeated fixed-duration
 * samples so every result carries noise information (median, min/max, CV).
 * A result whose CV is above ~3% should not be trusted for small deltas.
 *
 * Results are persisted to benchmarks/results/<benchId>.latest.json with
 * machine + git metadata so runs can be compared across commits with
 * scripts/bench-diff.js:
 *
 *   node benchmarks/foo.bench.js --save-baseline   # before a change
 *   node benchmarks/foo.bench.js                   # after a change
 *   npm run bench:diff                             # compare, noise-aware
 */

import { execSync } from "child_process";
import fs from "fs";
import os from "os";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

export const RESULTS_DIR = path.join(__dirname, "..", "results");

export const DEFAULT_CONFIG = {
  warmupMs: 200, // JIT warmup per benchmark (at least warmupIterations)
  warmupIterations: 100,
  samples: 10, // independent timed samples per benchmark
  sampleMs: 150, // target duration of each sample
};

/**
 * Run one benchmark with statistical sampling.
 *
 * Keeps the (name, setupFn, benchFn, teardownFn) signature of the old
 * per-file runBenchmark helpers so call sites only change imports.
 *
 * The returned opsPerSec is the MEDIAN across samples (robust to OS
 * scheduling spikes); min/max/cv describe the spread.
 */
export function runBenchmark(name, setupFn, benchFn, teardownFn = null, config = {}) {
  const { warmupMs, warmupIterations, samples, sampleMs } = { ...DEFAULT_CONFIG, ...config };

  // Warmup on a throwaway context: fixed iterations, then time-based
  const warmupCtx = setupFn();
  for (let i = 0; i < warmupIterations; i++) benchFn(warmupCtx);
  const warmupStart = performance.now();
  while (performance.now() - warmupStart < warmupMs) benchFn(warmupCtx);
  if (teardownFn) teardownFn(warmupCtx);

  const ctx = setupFn();

  // Calibrate batch size so each timing sample runs ~sampleMs without
  // calling performance.now() in the hot loop (matters at small N where
  // one FFT is ~30ns and a timer call would dominate).
  let batchIters = 1;
  for (;;) {
    const t0 = performance.now();
    for (let i = 0; i < batchIters; i++) benchFn(ctx);
    const elapsed = performance.now() - t0;
    if (elapsed >= sampleMs / 4) {
      batchIters = Math.max(1, Math.round((batchIters / elapsed) * sampleMs));
      break;
    }
    batchIters *= 4;
  }

  const sampleOpsPerSec = [];
  for (let s = 0; s < samples; s++) {
    const t0 = performance.now();
    for (let i = 0; i < batchIters; i++) benchFn(ctx);
    const elapsed = performance.now() - t0;
    sampleOpsPerSec.push((batchIters / elapsed) * 1000);
  }

  if (teardownFn) teardownFn(ctx);

  const stats = computeStats(sampleOpsPerSec);
  return {
    name,
    opsPerSec: stats.median,
    median: stats.median,
    mean: stats.mean,
    min: stats.min,
    max: stats.max,
    cv: stats.cv,
    samples: sampleOpsPerSec,
    iterationsPerSample: batchIters,
  };
}

/**
 * Deterministic PRNG (mulberry32) in [-1, 1) so benchmark inputs are
 * identical across runs and machines — removes input data as a source of
 * run-to-run variance when diffing results.
 */
export function seededRandom(seed = 0x5eed) {
  let s = seed >>> 0;
  return () => {
    s = (s + 0x6d2b79f5) >>> 0;
    let t = s;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return (((t ^ (t >>> 14)) >>> 0) / 4294967296) * 2 - 1;
  };
}

export function computeStats(values) {
  const sorted = [...values].sort((a, b) => a - b);
  const n = sorted.length;
  const mid = Math.floor(n / 2);
  const median = n % 2 === 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
  const mean = values.reduce((a, b) => a + b, 0) / n;
  const variance = values.reduce((a, b) => a + (b - mean) ** 2, 0) / (n > 1 ? n - 1 : 1);
  const stddev = Math.sqrt(variance);
  return {
    median,
    mean,
    min: sorted[0],
    max: sorted[n - 1],
    stddev,
    cv: mean > 0 ? stddev / mean : 0,
  };
}

export function formatNumber(num) {
  return num.toLocaleString("en-US", { maximumFractionDigits: 0 });
}

/** Print one size group's results sorted fastest-first, with noise info. */
export function printResults(results) {
  const sorted = [...results].sort((a, b) => b.opsPerSec - a.opsPerSec);
  const fastest = sorted[0].opsPerSec;
  console.log("");
  console.log("Implementation                median ops/s     ±CV      relative");
  console.log("-".repeat(66));
  for (const r of sorted) {
    const relative = r.opsPerSec / fastest;
    const relativeStr = relative === 1 ? "(fastest)" : `${(relative * 100).toFixed(1)}%`;
    const cvStr = `${(r.cv * 100).toFixed(1)}%`;
    console.log(
      `${r.name.padEnd(27)} ${formatNumber(r.opsPerSec).padStart(12)}  ${cvStr.padStart(6)}  ${relativeStr.padStart(11)}`,
    );
  }
  return sorted;
}

function gitInfo() {
  const run = (cmd) => {
    try {
      return execSync(cmd, { encoding: "utf-8", stdio: ["ignore", "pipe", "ignore"] }).trim();
    } catch {
      return null;
    }
  };
  return {
    commit: run("git rev-parse --short HEAD"),
    branch: run("git rev-parse --abbrev-ref HEAD"),
    dirty: run("git status --porcelain") !== "",
  };
}

export function collectMeta() {
  return {
    timestamp: new Date().toISOString(),
    node: process.version,
    v8: process.versions.v8,
    platform: `${os.platform()} ${os.release()} ${os.arch()}`,
    cpu: os.cpus()[0]?.model ?? "unknown",
    git: gitInfo(),
  };
}

/**
 * Persist a benchmark run to benchmarks/results/.
 *
 * @param {string} benchId - stable id, e.g. "rfft-f32" (used as filename)
 * @param {Array<{size: number, results: Array}>} sizeGroups
 * @param {object} [config] - harness config used for the run
 *
 * Writes <benchId>.latest.json always; with --save-baseline on the CLI
 * also writes <benchId>.baseline.json for later bench:diff comparison.
 */
export function saveResults(benchId, sizeGroups, config = DEFAULT_CONFIG) {
  fs.mkdirSync(RESULTS_DIR, { recursive: true });
  const payload = {
    version: 1,
    benchId,
    meta: collectMeta(),
    config,
    sizes: sizeGroups.map(({ size, results }) => ({
      size,
      results: results.map(({ name, opsPerSec, min, max, cv, iterationsPerSample }) => ({
        name,
        opsPerSec,
        min,
        max,
        cv,
        iterationsPerSample,
      })),
    })),
  };

  const latestPath = path.join(RESULTS_DIR, `${benchId}.latest.json`);
  fs.writeFileSync(latestPath, JSON.stringify(payload, null, 2) + "\n");
  const saved = [latestPath];

  if (process.argv.includes("--save-baseline")) {
    const baselinePath = path.join(RESULTS_DIR, `${benchId}.baseline.json`);
    fs.writeFileSync(baselinePath, JSON.stringify(payload, null, 2) + "\n");
    saved.push(baselinePath);
  }

  console.log("");
  for (const p of saved) {
    console.log(`Results saved: ${path.relative(process.cwd(), p)}`);
  }
  return payload;
}
