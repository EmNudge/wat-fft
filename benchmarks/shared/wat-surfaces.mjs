/**
 * wat-fft benchmark surface registry - THE single source of truth for which
 * wat-fft implementations must be measured on every benchmark surface.
 *
 * Every benchmark (Node and browser) builds its wat-fft contexts by
 * enumerating this registry instead of hand-picking modules, so a new or
 * superseding implementation added here is automatically measured
 * everywhere. `tests/benchmark-coverage.test.js` enforces the contract:
 * every entry instantiates and computes correctly, every dist/*.wasm module
 * is accounted for, and every bench file listed in BENCH_COVERAGE actually
 * enumerates its surface.
 *
 * History: the browser real-FFT benchmark silently kept measuring the old
 * dual-complex `rfft` for two module generations after `rfft_split`
 * shipped, reporting 14-35% losses to pffft that the flagship had already
 * closed. This registry exists so that class of drift fails a test instead
 * of surfacing in CI benchmark reports.
 *
 * Entry fields:
 *   name       - canonical benchmark display name (must satisfy isWatBenchName)
 *   module     - wasm file in dist/
 *   precision  - "f32" | "f64"
 *   layout     - how input is staged (see LAYOUTS below)
 *   precompute - twiddle precompute export, called once with N
 *   run        - transform export, called with N per iteration
 *   minSize    - smallest supported N (inclusive); entry is skipped below it
 *   maxSize    - largest supported N (inclusive); entry is skipped above it
 *   flagship   - exactly one per (surface, precision): the implementation
 *                whose result represents wat-fft in summaries and docs
 *   spectrumVia- (real-inverse only) forward export used to produce the
 *                Hermitian spectrum input
 *   roundtripWith - (complex-inverse only) forward export for roundtrip
 *                correctness checks
 *
 * LAYOUTS:
 *   "complex-interleaved" - 2N floats (re,im pairs) at offset 0
 *   "complex-split"       - N floats at REAL_OFFSET plane + N at IMAG_OFFSET
 *   "real-packed"         - N real floats at offset 0
 *   "real-spectrum"       - N+2 floats at offset 0 (N/2+1 interleaved bins)
 */

export const WAT_BENCH_NAME_PREFIXES = ["wat-fft", "wat-ifft", "wat-rfft", "wat-irfft"];

/** Shared predicate: is this benchmark entry a wat-fft implementation?
 *  Used by scripts/check-benchmarks.js to split wat-fft from competitors. */
export function isWatBenchName(name) {
  return WAT_BENCH_NAME_PREFIXES.some((prefix) => name.startsWith(prefix));
}

export const SURFACES = {
  "complex-forward": {
    inputKind: "complex",
    entries: [
      {
        name: "wat-fft (f64)",
        module: "fft_combined.wasm",
        precision: "f64",
        layout: "complex-interleaved",
        precompute: "precompute_twiddles",
        run: "fft",
        minSize: 8,
        maxSize: 8192,
        flagship: true, // only f64 complex implementation
      },
      {
        name: "wat-fft (f32)",
        module: "fft_stockham_f32_dual.wasm",
        precision: "f32",
        layout: "complex-interleaved",
        precompute: "precompute_twiddles",
        run: "fft",
        minSize: 8,
        maxSize: 8192,
      },
      {
        name: "wat-fft (f32 split)",
        module: "fft_split_native_f32.wasm",
        precision: "f32",
        layout: "complex-split",
        precompute: "precompute_twiddles_split",
        run: "fft_split",
        minSize: 16,
        maxSize: 8192,
        flagship: true,
      },
    ],
  },

  "complex-inverse": {
    inputKind: "complex",
    entries: [
      {
        name: "wat-ifft (f32)",
        module: "fft_stockham_f32_dual.wasm",
        precision: "f32",
        layout: "complex-interleaved",
        precompute: "precompute_twiddles",
        run: "ifft",
        roundtripWith: "fft",
        minSize: 8,
        maxSize: 8192,
      },
      {
        name: "wat-ifft (f32 split)",
        module: "fft_split_native_f32.wasm",
        precision: "f32",
        layout: "complex-split",
        precompute: "precompute_twiddles_split",
        run: "ifft_split",
        roundtripWith: "fft_split",
        minSize: 16,
        maxSize: 8192,
        flagship: true,
      },
    ],
  },

  "real-forward": {
    inputKind: "real",
    entries: [
      {
        name: "wat-rfft (f64)",
        module: "fft_real_combined.wasm",
        precision: "f64",
        layout: "real-packed",
        precompute: "precompute_rfft_twiddles",
        run: "rfft",
        minSize: 8,
        maxSize: 8192,
        flagship: true, // only f64 real implementation
      },
      {
        name: "wat-rfft (f32)",
        module: "fft_real_f32_dual.wasm",
        precision: "f32",
        layout: "real-packed",
        precompute: "precompute_rfft_twiddles",
        run: "rfft",
        minSize: 8,
        maxSize: 8192,
      },
      {
        name: "wat-rfft (f32 split)",
        module: "fft_split_native_f32.wasm",
        precision: "f32",
        layout: "real-packed",
        precompute: "precompute_rfft_twiddles_split",
        run: "rfft_split",
        minSize: 32,
        maxSize: 16384,
        flagship: true,
      },
    ],
  },

  "real-inverse": {
    inputKind: "real",
    entries: [
      {
        name: "wat-irfft (f32)",
        module: "fft_real_f32_dual.wasm",
        precision: "f32",
        layout: "real-spectrum",
        precompute: "precompute_rfft_twiddles",
        run: "irfft",
        spectrumVia: "rfft",
        minSize: 8,
        maxSize: 8192,
      },
      {
        name: "wat-irfft (f32 split)",
        module: "fft_split_native_f32.wasm",
        precision: "f32",
        layout: "real-spectrum",
        precompute: "precompute_rfft_twiddles_split",
        run: "irfft_split",
        spectrumVia: "rfft_split",
        minSize: 32,
        maxSize: 16384,
        flagship: true,
      },
    ],
  },
};

/**
 * Filter a surface's entries for a benchmark run.
 * Options: size (skip entries whose [minSize, maxSize] excludes it),
 * precisions (e.g. ["f32"] for f32-only comparison benches).
 */
export function watEntriesFor(surfaceId, { size, precisions } = {}) {
  const surface = SURFACES[surfaceId];
  if (!surface) {
    throw new Error(`Unknown benchmark surface: ${surfaceId}`);
  }
  return surface.entries.filter((entry) => {
    if (precisions && !precisions.includes(entry.precision)) return false;
    if (size !== undefined && (size < entry.minSize || size > entry.maxSize)) return false;
    return true;
  });
}

/** The flagship entry for a surface at a given precision.
 *  Without a precision, the f32 flagship wins (it is the fastest tier). */
export function flagshipFor(surfaceId, precision) {
  const entries = watEntriesFor(surfaceId, precision ? { precisions: [precision] } : {});
  const flagships = entries.filter((e) => e.flagship);
  return flagships.find((e) => e.precision === "f32") ?? flagships[0];
}

/**
 * Which bench files must measure which surface. The coverage test asserts
 * each file enumerates the registry (calls the shared context builder with
 * the declared surface id) so its wat-fft coverage cannot go stale.
 * `precisions` documents (and bounds) intentional precision-scoped benches.
 */
export const BENCH_COVERAGE = [
  { file: "benchmarks/fft.bench.js", surface: "complex-forward" },
  { file: "benchmarks/fft_f32_dual.bench.js", surface: "complex-forward", precisions: ["f32"] },
  { file: "benchmarks/ifft_f32_dual.bench.js", surface: "complex-inverse", precisions: ["f32"] },
  { file: "benchmarks/rfft.bench.js", surface: "real-forward", precisions: ["f64"] },
  { file: "benchmarks/rfft_f32_dual.bench.js", surface: "real-forward", precisions: ["f32"] },
  { file: "benchmarks/irfft_f32_dual.bench.js", surface: "real-inverse", precisions: ["f32"] },
  { file: "benchmarks/browser/fft.bench.ts", surface: "complex-forward" },
  { file: "benchmarks/browser/rfft.bench.ts", surface: "real-forward" },
];

/**
 * dist/*.wasm modules intentionally NOT in any surface entry, with the
 * reason. The coverage test fails if a built module is neither referenced
 * by an entry nor listed here - adding a new module forces a decision.
 */
export const EXCLUDED_MODULES = {
  // (none currently - all built modules are benchmarked)
};

/**
 * Benchmark files exempt from surface coverage (internal probes that
 * deliberately measure something other than the public API).
 */
export const EXCLUDED_BENCH_FILES = {
  "benchmarks/fft_kernel_only.bench.js":
    "internal probe: measures the split kernel without input staging",
};
