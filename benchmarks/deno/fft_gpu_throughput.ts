/**
 * GPU FFT throughput sweep (webgpu-fft) — Deno + native WebGPU.
 *
 * The latency benchmark (fft_gpu.bench.ts) measures ONE transform per call and
 * is dominated by the device round-trip (~14 ms flat). That is the GPU's worst
 * case. This sweep instead measures sustained THROUGHPUT: how many independent
 * length-N FFTs the GPU completes per second when many are kept in flight at
 * once, so the fixed per-call latency overlaps across transforms.
 *
 * webgpu-fft has no batch API and reads results back (a device sync) on every
 * fft() call, so the only way to overlap is concurrency across independent
 * engines. Throughput rises with concurrency and then saturates once the
 * device is busy — that plateau is this library's real ceiling.
 *
 * Not part of CI (no GPU on runners). Run locally:
 *
 *   npm run bench:gpu            # runs this after the latency bench
 *   deno run -A --unstable-webgpu benchmarks/deno/fft_gpu_throughput.ts
 */

// @ts-ignore - vendored build produced by benchmarks/deno/setup.ts (gitignored)
import { createFFTEngine, isWebGPUAvailable } from "./vendor/gpu-fft/dist/index.js";

const SIZES = [256, 1024, 4096];
const CONCURRENCY = [1, 8, 32];
const MEASURE_MS = 1500; // wall-clock budget per (size, concurrency) cell

if (!(await isWebGPUAvailable())) {
  console.error("WebGPU unavailable — skipping GPU throughput sweep.");
  Deno.exit(0);
}

function randomComplex(n: number): Float32Array {
  const a = new Float32Array(n * 2);
  for (let i = 0; i < a.length; i++) a[i] = Math.random() * 2 - 1;
  return a;
}

console.log("webgpu-fft — sustained forward-FFT throughput (concurrent, in-flight)\n");
console.log("| N".padEnd(9) + "| concurrency | FFTs/sec  | ms/FFT (amortized) |");
console.log(
  "| " +
    "-".repeat(6) +
    " | " +
    "-".repeat(11) +
    " | " +
    "-".repeat(9) +
    " | " +
    "-".repeat(18) +
    " |",
);

for (const size of SIZES) {
  let peak = 0;
  for (const k of CONCURRENCY) {
    // One independent engine per in-flight slot (a single engine's per-N
    // buffers are shared, so concurrent same-N calls on it would clobber).
    const engines = await Promise.all(Array.from({ length: k }, () => createFFTEngine()));
    const inputs = engines.map(() => randomComplex(size));

    // Warm every engine's pipeline/buffers for this N.
    await Promise.all(engines.map((e, i) => e.fft(inputs[i])));

    let done = 0;
    const start = performance.now();
    while (performance.now() - start < MEASURE_MS) {
      await Promise.all(engines.map((e, i) => e.fft(inputs[i])));
      done += k;
    }
    const ms = performance.now() - start;
    const perSec = (done / ms) * 1000;
    peak = Math.max(peak, perSec);

    console.log(
      `| ${String(size).padEnd(6)} | ${String(k).padEnd(11)} | ${perSec.toFixed(0).padStart(9)} | ${(
        ms / done
      )
        .toFixed(3)
        .padStart(18)} |`,
    );
    engines.forEach((e) => e.dispose());
  }
  console.log(
    `| ${String(size).padEnd(6)} | ${"peak".padEnd(11)} | ${peak.toFixed(0).padStart(9)} | ${"".padStart(
      18,
    )} |`,
  );
}

console.log(
  "\nThroughput saturates because webgpu-fft syncs (reads back) on every call; " +
    "the plateau is this library's ceiling, not the GPU's.",
);
