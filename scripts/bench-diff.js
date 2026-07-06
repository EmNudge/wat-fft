#!/usr/bin/env node
/**
 * Noise-aware benchmark comparison tool.
 *
 * Compares two benchmark result JSONs produced by benchmarks/lib/harness.js
 * and flags deltas that exceed the measured run-to-run noise. This is how
 * optimization experiments should be judged: a +2% "win" with 3% CV is noise.
 *
 * Usage:
 *   npm run bench:diff                        # all <id>.baseline.json vs <id>.latest.json
 *   node scripts/bench-diff.js rfft-f32       # one benchmark id
 *   node scripts/bench-diff.js a.json b.json  # two explicit files
 *   node scripts/bench-diff.js --fail-on-regression   # exit 1 on significant regression
 *
 * Workflow:
 *   node benchmarks/rfft_f32_dual.bench.js --save-baseline   # before change
 *   ...make changes, npm run build...
 *   node benchmarks/rfft_f32_dual.bench.js                   # after change
 *   npm run bench:diff
 *
 * Significance: |delta| must exceed max(2%, 3 * combined CV). With the
 * harness's 10-sample medians, CV is typically <1%, so real changes >3%
 * are reliably detected while sub-noise deltas are labeled "~".
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const RESULTS_DIR = path.join(__dirname, "..", "benchmarks", "results");

const MIN_SIGNIFICANT = 0.02; // never flag below 2% regardless of CV
const CV_MULTIPLIER = 3;

function loadJson(p) {
  return JSON.parse(fs.readFileSync(p, "utf-8"));
}

function indexResults(payload) {
  // Map "N=<size>/<name>" -> result
  const map = new Map();
  for (const { size, results } of payload.sizes) {
    for (const r of results) {
      map.set(`N=${size}/${r.name}`, { size, ...r });
    }
  }
  return map;
}

function formatOps(num) {
  return num.toLocaleString("en-US", { maximumFractionDigits: 0 });
}

function comparePair(baselinePath, latestPath) {
  const baseline = loadJson(baselinePath);
  const latest = loadJson(latestPath);

  const before = indexResults(baseline);
  const after = indexResults(latest);

  console.log("=".repeat(78));
  console.log(`Benchmark: ${latest.benchId}`);
  console.log(
    `  baseline: ${baseline.meta.git?.commit ?? "?"}${baseline.meta.git?.dirty ? "+dirty" : ""} @ ${baseline.meta.timestamp}`,
  );
  console.log(
    `  latest:   ${latest.meta.git?.commit ?? "?"}${latest.meta.git?.dirty ? "+dirty" : ""} @ ${latest.meta.timestamp}`,
  );
  if (baseline.meta.cpu !== latest.meta.cpu) {
    console.log(`  WARNING: different CPUs (${baseline.meta.cpu} vs ${latest.meta.cpu})`);
  }
  console.log("=".repeat(78));
  console.log("Key                                          baseline       latest    delta");
  console.log("-".repeat(78));

  let regressions = 0;
  let improvements = 0;

  for (const [key, b] of before) {
    const a = after.get(key);
    if (!a) continue;

    const delta = a.opsPerSec / b.opsPerSec - 1;
    const noise = Math.max(MIN_SIGNIFICANT, CV_MULTIPLIER * Math.hypot(a.cv ?? 0, b.cv ?? 0));
    const significant = Math.abs(delta) > noise;

    let marker = "  ~";
    if (significant && delta > 0) {
      marker = "  ▲";
      improvements++;
    } else if (significant && delta < 0) {
      marker = "  ▼";
      regressions++;
    }

    const deltaStr = `${delta >= 0 ? "+" : ""}${(delta * 100).toFixed(1)}%`;
    console.log(
      `${key.padEnd(42)} ${formatOps(b.opsPerSec).padStart(12)} ${formatOps(a.opsPerSec).padStart(12)} ${deltaStr.padStart(7)}${marker}`,
    );
  }

  for (const key of after.keys()) {
    if (!before.has(key)) {
      console.log(`${key.padEnd(42)} ${"(new)".padStart(12)}`);
    }
  }

  console.log("-".repeat(78));
  console.log(
    `Significant: ${improvements} improvement(s), ${regressions} regression(s) ` +
      `(threshold: max(${MIN_SIGNIFICANT * 100}%, ${CV_MULTIPLIER}x combined CV); ~ = within noise)`,
  );
  console.log("");

  return { improvements, regressions };
}

function main() {
  const args = process.argv.slice(2).filter((a) => !a.startsWith("--"));
  const failOnRegression = process.argv.includes("--fail-on-regression");

  const pairs = [];

  if (args.length === 2 && args.every((a) => a.endsWith(".json"))) {
    pairs.push([path.resolve(args[0]), path.resolve(args[1])]);
  } else if (args.length === 1) {
    pairs.push([
      path.join(RESULTS_DIR, `${args[0]}.baseline.json`),
      path.join(RESULTS_DIR, `${args[0]}.latest.json`),
    ]);
  } else {
    // Auto-discover every benchId with both a baseline and a latest file
    if (!fs.existsSync(RESULTS_DIR)) {
      console.error(`No results directory at ${RESULTS_DIR}.`);
      console.error("Run a benchmark with --save-baseline first, then re-run it after changes.");
      process.exit(1);
    }
    const files = fs.readdirSync(RESULTS_DIR);
    const ids = files
      .filter((f) => f.endsWith(".baseline.json"))
      .map((f) => f.replace(".baseline.json", ""));
    for (const id of ids) {
      if (files.includes(`${id}.latest.json`)) {
        pairs.push([
          path.join(RESULTS_DIR, `${id}.baseline.json`),
          path.join(RESULTS_DIR, `${id}.latest.json`),
        ]);
      }
    }
    if (pairs.length === 0) {
      console.error("No baseline/latest pairs found in benchmarks/results/.");
      console.error("Run a benchmark with --save-baseline first, then re-run it after changes.");
      process.exit(1);
    }
  }

  let totalRegressions = 0;
  for (const [baselinePath, latestPath] of pairs) {
    for (const p of [baselinePath, latestPath]) {
      if (!fs.existsSync(p)) {
        console.error(`Missing results file: ${p}`);
        process.exit(1);
      }
    }
    const { regressions } = comparePair(baselinePath, latestPath);
    totalRegressions += regressions;
  }

  if (failOnRegression && totalRegressions > 0) {
    process.exit(1);
  }
}

main();
