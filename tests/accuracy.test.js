/**
 * Numerical accuracy regression tests.
 *
 * Uses measureAccuracy() from tools/accuracy_report.js so the diagnostic
 * report and these assertions can never disagree. Thresholds are set ~4x
 * above the levels measured when this suite was added, so they catch
 * order-of-magnitude precision regressions (bad twiddle table, wrong
 * codelet path, dropped normalization) without flaking on rounding noise.
 *
 * Measured baselines (2026-07, see docs): f32 modules sit at max-rel
 * 1e-7..1.2e-6 (quality ~0.3-3 x eps*sqrt(log2 N), near-optimal). f64
 * modules sit at ~5e-11 for N>=32 — limited by Taylor-series twiddle
 * precision, not by f64 eps (N=16 achieves 4e-15 via exact codelets).
 * If f64 twiddle generation is ever improved, tighten MAX_REL.f64.
 */

import { test, describe, before } from "node:test";
import assert from "node:assert";
import { measureAccuracy } from "../tools/accuracy_report.js";

const MAX_REL = {
  f32: 5e-6,
  f64: 1e-9,
};

// rms-rel is tighter than max-rel; a normalization bug (e.g. missing 1/N)
// blows this up by orders of magnitude even if some bins stay close.
const RMS_REL = {
  f32: 2e-6,
  f64: 5e-10,
};

describe("Numerical accuracy vs reference DFT", () => {
  let rows;

  before(async () => {
    rows = await measureAccuracy();
  });

  test("all module/transform/size combinations were measured", () => {
    // 5 modules x directions x 9 sizes, minus rfft_split/irfft_split at N=16
    assert.ok(rows.length >= 96, `expected >= 96 measurements, got ${rows.length}`);
  });

  test("no NaN or Infinity in any measurement", () => {
    for (const r of rows) {
      assert.ok(
        Number.isFinite(r.maxRel) && Number.isFinite(r.rmsRel),
        `${r.module}::${r.transform} N=${r.n} produced non-finite error (NaN/Inf in output?)`,
      );
    }
  });

  test("max relative error within per-precision thresholds", () => {
    const failures = [];
    for (const r of rows) {
      if (r.maxRel > MAX_REL[r.precision]) {
        failures.push(
          `${r.module}::${r.transform} N=${r.n}: max-rel ${r.maxRel.toExponential(2)} > ${MAX_REL[r.precision]}`,
        );
      }
    }
    assert.deepStrictEqual(failures, []);
  });

  test("rms relative error within per-precision thresholds", () => {
    const failures = [];
    for (const r of rows) {
      if (r.rmsRel > RMS_REL[r.precision]) {
        failures.push(
          `${r.module}::${r.transform} N=${r.n}: rms-rel ${r.rmsRel.toExponential(2)} > ${RMS_REL[r.precision]}`,
        );
      }
    }
    assert.deepStrictEqual(failures, []);
  });
});
