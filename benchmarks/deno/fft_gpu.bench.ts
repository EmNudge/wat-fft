/**
 * GPU FFT benchmark (webgpu-fft) — Deno + native WebGPU.
 *
 * This measures webgpu-fft (git@github.com:AICL-Lab/gpu-fft.git) in ISOLATION.
 * It is deliberately NOT a head-to-head against wat-fft: a WebGPU FFT is a
 * different class of transform (async dispatch + device round-trip, high fixed
 * latency, throughput that only pays off at large N), so ranking it next to a
 * synchronous in-thread CPU/WASM kernel would be misleading. These are
 * standalone reference numbers for the GPU path.
 *
 * Not part of CI — CI runners have no GPU. Run locally on a machine with one:
 *
 *   npm run bench:gpu
 *   # or, after `deno run -A benchmarks/deno/setup.ts`:
 *   deno bench -A --unstable-webgpu benchmarks/deno/fft_gpu.bench.ts
 *
 * Each iteration times a full forward complex FFT including input upload and
 * result readback — the real end-to-end latency a JS caller sees.
 */

// @ts-ignore - vendored build produced by benchmarks/deno/setup.ts (gitignored)
import { createFFTEngine, isWebGPUAvailable } from "./vendor/gpu-fft/dist/index.js";

const SIZES = [64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536];

if (!(await isWebGPUAvailable())) {
  console.error(
    "WebGPU is unavailable — skipping GPU benchmark. " +
      "Run on a machine with a GPU and pass --unstable-webgpu.",
  );
  Deno.exit(0);
}

// One engine services every size (it infers N from the input length and caches
// per-N GPU buffers on first use).
const engine = await createFFTEngine();

for (const size of SIZES) {
  // Interleaved [re, im, re, im, ...] random complex signal.
  const input = new Float32Array(size * 2);
  for (let i = 0; i < size; i++) {
    input[i * 2] = Math.random() * 2 - 1;
    input[i * 2 + 1] = Math.random() * 2 - 1;
  }

  // Warm the pipeline/buffers for this N so the first timed sample isn't a
  // one-off shader-compile outlier.
  await engine.fft(input);

  Deno.bench({
    name: `webgpu-fft (GPU) N=${size}`,
    async fn() {
      await engine.fft(input);
    },
  });
}
