/**
 * Benchmark Coverage Validation
 *
 * Enforces the wat-fft surface registry contract
 * (benchmarks/shared/wat-surfaces.mjs):
 *
 * 1. The registry itself is well-formed (unique names, one flagship per
 *    surface+precision, names the CI checker will recognize).
 * 2. Every built dist/*.wasm module is either benchmarked via a registry
 *    entry or explicitly excluded with a reason - a new module cannot
 *    silently skip benchmarking.
 * 3. Every registry entry instantiates and computes CORRECT results
 *    (checked against a reference DFT / roundtrip at N=64) - a wrong
 *    export name or layout fails here, not in a benchmark report.
 * 4. Every bench file declared in BENCH_COVERAGE actually enumerates the
 *    registry for its surface - the browser rfft bench measuring a stale
 *    module for two generations is the failure mode this kills.
 *
 * If this test fails after you add or supersede an implementation, update
 * benchmarks/shared/wat-surfaces.mjs (and only it) - the benches follow.
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  SURFACES,
  BENCH_COVERAGE,
  EXCLUDED_MODULES,
  EXCLUDED_BENCH_FILES,
  isWatBenchName,
  watEntriesFor,
  flagshipFor,
} from "../benchmarks/shared/wat-surfaces.mjs";
import {
  createWatBenchContexts,
  loadWatModule,
  generateComplexInputs,
  generateRealInputs,
} from "../benchmarks/lib/wat-contexts.js";

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const N = 64; // within [minSize, maxSize] of every registry entry

// =============================================================================
// Reference transforms (f64)
// =============================================================================

function referenceDFT(re, im, sign) {
  const n = re.length;
  const outRe = new Float64Array(n);
  const outIm = new Float64Array(n);
  for (let k = 0; k < n; k++) {
    let sr = 0;
    let si = 0;
    for (let j = 0; j < n; j++) {
      const angle = (sign * 2 * Math.PI * k * j) / n;
      const c = Math.cos(angle);
      const s = Math.sin(angle);
      sr += re[j] * c - im[j] * s;
      si += re[j] * s + im[j] * c;
    }
    outRe[k] = sr;
    outIm[k] = si;
  }
  return { re: outRe, im: outIm };
}

function maxAbsDiff(a, b) {
  let max = 0;
  for (let i = 0; i < a.length; i++) {
    max = Math.max(max, Math.abs(a[i] - b[i]));
  }
  return max;
}

// Loose tolerance: this test catches miswired exports/layouts (errors are
// O(magnitude)), not precision regressions (tests/accuracy.test.js does).
const TOLERANCE = { f32: 1e-3, f64: 1e-9 };

// =============================================================================
// 1. Registry sanity
// =============================================================================

test("registry is well-formed", () => {
  const seenNames = new Set();
  for (const [surfaceId, surface] of Object.entries(SURFACES)) {
    assert.ok(surface.entries.length > 0, `${surfaceId} has entries`);

    const flagshipsByPrecision = new Map();
    for (const entry of surface.entries) {
      assert.ok(
        isWatBenchName(entry.name),
        `"${entry.name}" must match the wat-fft name prefixes (scripts/check-benchmarks.js splits wat-fft from competitors by name)`,
      );
      assert.ok(
        !seenNames.has(entry.name),
        `duplicate benchmark name "${entry.name}" - names key saved results and diffs`,
      );
      seenNames.add(entry.name);
      assert.ok(entry.minSize <= entry.maxSize, `${entry.name} has a valid size range`);
      if (entry.flagship) {
        assert.ok(
          !flagshipsByPrecision.has(entry.precision),
          `${surfaceId} has multiple ${entry.precision} flagships`,
        );
        flagshipsByPrecision.set(entry.precision, entry);
      }
    }

    for (const precision of new Set(surface.entries.map((e) => e.precision))) {
      assert.ok(
        flagshipsByPrecision.has(precision),
        `${surfaceId} needs a ${precision} flagship entry`,
      );
    }
    assert.ok(flagshipFor(surfaceId), `${surfaceId} resolves a flagship`);
  }
});

// =============================================================================
// 2. Every built module is accounted for
// =============================================================================

test("every dist/*.wasm module is benchmarked or explicitly excluded", () => {
  const built = fs
    .readdirSync(path.join(ROOT, "dist"))
    .filter((f) => f.endsWith(".wasm"))
    .sort();
  assert.ok(built.length > 0, "dist/ has built modules - run npm run build first");

  const referenced = new Set(
    Object.values(SURFACES).flatMap((s) => s.entries.map((e) => e.module)),
  );

  for (const file of built) {
    assert.ok(
      referenced.has(file) || file in EXCLUDED_MODULES,
      `dist/${file} is neither referenced by a registry entry nor listed in ` +
        `EXCLUDED_MODULES - decide how (or why not) to benchmark it in ` +
        `benchmarks/shared/wat-surfaces.mjs`,
    );
  }

  for (const file of Object.keys(EXCLUDED_MODULES)) {
    assert.ok(built.includes(file), `EXCLUDED_MODULES lists unknown module ${file}`);
  }
});

// =============================================================================
// 3. Every entry instantiates and computes correctly at N=64
// =============================================================================

test("every registry entry has working exports", async () => {
  for (const surface of Object.values(SURFACES)) {
    for (const entry of surface.entries) {
      const exports = await loadWatModule(entry.module);
      for (const exportName of [entry.precompute, entry.run, entry.spectrumVia].filter(Boolean)) {
        assert.equal(
          typeof exports[exportName],
          "function",
          `${entry.module} must export ${exportName}() (entry "${entry.name}")`,
        );
      }
    }
  }
});

test("complex-forward entries match the reference DFT", async () => {
  const input = generateComplexInputs(N);
  const ref = referenceDFT(input.re64, input.im64, -1);
  const contexts = await createWatBenchContexts("complex-forward", N, { input });
  assert.equal(contexts.length, SURFACES["complex-forward"].entries.length);

  for (const ctx of contexts) {
    const state = ctx.setup();
    ctx.bench(state);
    const { re, im } = readComplexOutput(ctx, await loadWatModule(ctx.entry.module));
    const err = Math.max(maxAbsDiff(re, ref.re), maxAbsDiff(im, ref.im));
    assert.ok(
      err <= TOLERANCE[ctx.entry.precision] * N,
      `${ctx.name}: max error ${err} vs reference DFT - miswired export or layout?`,
    );
  }
});

test("complex-inverse entries match the reference inverse DFT", async () => {
  const input = generateComplexInputs(N);
  const ref = referenceDFT(input.re64, input.im64, +1);
  const contexts = await createWatBenchContexts("complex-inverse", N, { input });
  assert.equal(contexts.length, SURFACES["complex-inverse"].entries.length);

  for (const ctx of contexts) {
    const state = ctx.setup();
    ctx.bench(state);
    const { re, im } = readComplexOutput(ctx, await loadWatModule(ctx.entry.module));
    // wat-fft inverse transforms are normalized (1/N)
    let err = 0;
    for (let i = 0; i < N; i++) {
      err = Math.max(err, Math.abs(re[i] - ref.re[i] / N), Math.abs(im[i] - ref.im[i] / N));
    }
    assert.ok(
      err <= TOLERANCE[ctx.entry.precision],
      `${ctx.name}: max error ${err} vs normalized inverse DFT`,
    );
  }
});

test("real-forward entries match the reference real DFT", async () => {
  const input = generateRealInputs(N);
  const ref = referenceDFT(input.real64, new Float64Array(N), -1);
  const contexts = await createWatBenchContexts("real-forward", N, { input });
  assert.equal(contexts.length, SURFACES["real-forward"].entries.length);

  for (const ctx of contexts) {
    const state = ctx.setup();
    ctx.bench(state);
    const exports = await loadWatModule(ctx.entry.module);
    const FloatArray = ctx.entry.precision === "f32" ? Float32Array : Float64Array;
    const out = new FloatArray(exports.memory.buffer, 0, N + 2);
    let err = 0;
    for (let k = 0; k <= N / 2; k++) {
      err = Math.max(err, Math.abs(out[2 * k] - ref.re[k]), Math.abs(out[2 * k + 1] - ref.im[k]));
    }
    assert.ok(
      err <= TOLERANCE[ctx.entry.precision] * N,
      `${ctx.name}: max error ${err} vs reference real DFT`,
    );
  }
});

test("real-inverse entries roundtrip the real signal", async () => {
  const input = generateRealInputs(N);
  const contexts = await createWatBenchContexts("real-inverse", N, { input });
  assert.equal(contexts.length, SURFACES["real-inverse"].entries.length);

  for (const ctx of contexts) {
    const state = ctx.setup(); // produces the spectrum via the module's own forward
    ctx.bench(state); // inverse back to the time domain at offset 0
    const exports = await loadWatModule(ctx.entry.module);
    const FloatArray = ctx.entry.precision === "f32" ? Float32Array : Float64Array;
    const out = new FloatArray(exports.memory.buffer, 0, N);
    const src = ctx.entry.precision === "f32" ? input.real32 : input.real64;
    const err = maxAbsDiff(out, src);
    assert.ok(err <= TOLERANCE[ctx.entry.precision], `${ctx.name}: roundtrip max error ${err}`);
  }
});

function readComplexOutput(ctx, exports) {
  const FloatArray = ctx.entry.precision === "f32" ? Float32Array : Float64Array;
  if (ctx.entry.layout === "complex-split") {
    const realOffset =
      typeof exports.REAL_OFFSET === "number" ? exports.REAL_OFFSET : exports.REAL_OFFSET.value;
    const imagOffset =
      typeof exports.IMAG_OFFSET === "number" ? exports.IMAG_OFFSET : exports.IMAG_OFFSET.value;
    return {
      re: new Float32Array(exports.memory.buffer, realOffset, N),
      im: new Float32Array(exports.memory.buffer, imagOffset, N),
    };
  }
  const data = new FloatArray(exports.memory.buffer, 0, N * 2);
  const re = new Float64Array(N);
  const im = new Float64Array(N);
  for (let i = 0; i < N; i++) {
    re[i] = data[2 * i];
    im[i] = data[2 * i + 1];
  }
  return { re, im };
}

// =============================================================================
// 4. Bench files actually enumerate the registry
// =============================================================================

test("every covered bench file enumerates its declared surface", () => {
  for (const { file, surface } of BENCH_COVERAGE) {
    const fullPath = path.join(ROOT, file);
    assert.ok(fs.existsSync(fullPath), `BENCH_COVERAGE lists missing file ${file}`);
    const source = fs.readFileSync(fullPath, "utf-8");

    // Registry enumeration evidence: the Node helper, the browser helper,
    // or the raw registry accessor (used by the playground loader)
    const enumerators = ["createWatBenchContexts(", "createWatContexts(", "watEntriesFor("];
    assert.ok(
      enumerators.some((e) => source.includes(e)),
      `${file} must build its wat-fft contexts by enumerating the shared registry ` +
        `(one of: ${enumerators.join(" ")})`,
    );
    assert.ok(
      source.includes(`"${surface}"`),
      `${file} must enumerate the "${surface}" surface it is declared to cover`,
    );

    // Bench files must not hand-roll wat module loading around the registry
    const modules = Object.values(SURFACES).flatMap((s) => s.entries.map((e) => e.module));
    for (const module of new Set(modules)) {
      assert.ok(
        !source.includes(module),
        `${file} references ${module} directly - go through the registry instead`,
      );
    }
  }
});

test("every surface is covered by at least one Node bench file", () => {
  for (const surfaceId of Object.keys(SURFACES)) {
    const nodeCovered = BENCH_COVERAGE.some(
      (c) => c.surface === surfaceId && c.file.endsWith(".js"),
    );
    assert.ok(nodeCovered, `surface ${surfaceId} has no Node bench file in BENCH_COVERAGE`);
  }
});

test("every *.bench.* file is covered or explicitly excluded", () => {
  const benchFiles = [];
  for (const dir of ["benchmarks", "benchmarks/browser"]) {
    for (const f of fs.readdirSync(path.join(ROOT, dir))) {
      if (/\.bench\.(js|ts)$/.test(f)) benchFiles.push(`${dir}/${f}`);
    }
  }
  const covered = new Set(BENCH_COVERAGE.map((c) => c.file));
  for (const file of benchFiles) {
    assert.ok(
      covered.has(file) || file in EXCLUDED_BENCH_FILES,
      `${file} is neither in BENCH_COVERAGE nor EXCLUDED_BENCH_FILES - declare its surface ` +
        `in benchmarks/shared/wat-surfaces.mjs`,
    );
  }
});

test("watEntriesFor size filtering drops out-of-range entries", () => {
  // rfft_split requires N >= 32: at N=16 only the other implementations remain
  const at16 = watEntriesFor("real-forward", { size: 16 });
  assert.ok(!at16.some((e) => e.run === "rfft_split"));
  const at64 = watEntriesFor("real-forward", { size: 64 });
  assert.ok(at64.some((e) => e.run === "rfft_split"));
});

// =============================================================================
// 5. The CI checker shares the wat-name predicate
// =============================================================================

test("scripts/check-benchmarks.js uses the shared isWatBenchName predicate", () => {
  const source = fs.readFileSync(path.join(ROOT, "scripts", "check-benchmarks.js"), "utf-8");
  assert.ok(
    source.includes("wat-surfaces.mjs") && source.includes("isWatBenchName"),
    "check-benchmarks.js must import isWatBenchName from benchmarks/shared/wat-surfaces.mjs " +
      "so registry names and CI classification cannot diverge",
  );
});
