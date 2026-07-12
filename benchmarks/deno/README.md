# GPU FFT benchmark (Deno + WebGPU)

Standalone reference numbers for **webgpu-fft**
([git@github.com:AICL-Lab/gpu-fft.git](https://github.com/AICL-Lab/gpu-fft)),
a WebGPU-accelerated FFT. Run under Deno, which exposes native WebGPU without a
browser.

## Not a head-to-head

This benchmark measures webgpu-fft **in isolation**. It is intentionally not
ranked against wat-fft. A WebGPU FFT is a different class of transform:

- **Async** — every call is `await engine.fft(...)`, not a synchronous
  in-thread kernel.
- **High fixed latency** — each call pays a GPU dispatch + device round-trip.
  On an Apple M5 Pro the per-call time is ~15 ms flat from N=64 to N=65536
  because that round-trip dominates, not the transform itself.
- **Throughput-oriented** — the GPU path pays off with batching / very large or
  2D transforms, not the single-shot small-N calls wat-fft targets.

Comparing those numbers directly against a synchronous WASM kernel would be
misleading, so we don't.

### Two regimes measured

- **Latency** (`fft_gpu.bench.ts`) — one transform per call, the GPU's worst
  case. ~14–15 ms flat from N=64 to N=65536 (~70 FFTs/sec), dominated by the
  device round-trip.
- **Throughput** (`fft_gpu_throughput.ts`) — many independent transforms kept
  in flight at once so the fixed per-call latency overlaps. This is the GPU's
  favorable regime. On an M5 Pro it climbs from ~70 FFTs/sec (concurrency 1) to
  a plateau of **~420–470 FFTs/sec** (concurrency 32), roughly flat across N.

The throughput plateau is this library's ceiling, not the GPU's: webgpu-fft has
no batch API and reads results back (a device sync) on every `fft()` call, so
concurrency is the only way to overlap and it saturates well below what a truly
batched GPU FFT could sustain.

## Not in CI

CI runners have no GPU, so this benchmark is excluded from every automated run
(`test:all`, `bench`, `bench:browser:ci`). It lives outside the
`benchmarks/browser/**` glob Vitest scans and is only invoked by the dedicated
`bench:gpu` script. Run it locally on a machine with a GPU.

## Running

```bash
npm run bench:gpu
```

That runs two steps:

1. `benchmarks/deno/setup.ts` — clones and builds webgpu-fft into
   `benchmarks/deno/vendor/` (gitignored). webgpu-fft is not published to npm
   and ships only a `dist` that must be built from source. Idempotent; pass
   `--force` to rebuild.
2. `deno bench --unstable-webgpu benchmarks/deno/fft_gpu.bench.ts` — latency:
   one full forward complex FFT (upload + compute + readback) per call across
   power-of-two sizes.
3. `deno run --unstable-webgpu benchmarks/deno/fft_gpu_throughput.ts` —
   throughput: sustained FFTs/sec at increasing concurrency.

Requires [Deno](https://deno.com/) 2.x and a working GPU.

## Files

| File                    | Purpose                                                        |
| ----------------------- | -------------------------------------------------------------- |
| `fft_gpu.bench.ts`      | `Deno.bench` single-call latency (skips if WebGPU is absent)   |
| `fft_gpu_throughput.ts` | Sustained FFTs/sec vs concurrency (the GPU's favorable regime) |
| `setup.ts`              | Clones + builds webgpu-fft into the gitignored vendor dir      |
