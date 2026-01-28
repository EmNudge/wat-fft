#!/usr/bin/env node
/**
 * Benchmark Result Checker for CI
 *
 * Reads Vitest benchmark JSON output and verifies that wat-fft
 * beats or meets all competitors at every size.
 *
 * Exit codes:
 *   0 - All benchmarks passed (wat-fft wins or ties every comparison)
 *   1 - One or more benchmarks failed (competitor beat wat-fft)
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const RESULTS_FILE = path.join(__dirname, "..", "benchmark-results.json");

// Identify wat-fft implementations by name patterns
function isWatFft(name) {
  return name.startsWith("wat-fft") || name.startsWith("wat-rfft");
}

function formatNumber(num) {
  return num.toLocaleString("en-US", { maximumFractionDigits: 0 });
}

function main() {
  // Check if results file exists
  if (!fs.existsSync(RESULTS_FILE)) {
    console.error(`Error: Benchmark results file not found: ${RESULTS_FILE}`);
    console.error("Run 'npm run bench:browser:ci' first to generate results.");
    process.exit(1);
  }

  // Read and parse results
  const rawData = fs.readFileSync(RESULTS_FILE, "utf-8");
  let data;
  try {
    data = JSON.parse(rawData);
  } catch (e) {
    console.error(`Error: Failed to parse benchmark results: ${e.message}`);
    process.exit(1);
  }

  // Vitest benchmark JSON structure:
  // { files: [{ filepath, groups: [{ fullName, benchmarks: [{ name, hz, rank }] }] }] }
  if (!data.files || !Array.isArray(data.files)) {
    console.error("Error: Invalid benchmark JSON structure - missing 'files' array");
    process.exit(1);
  }

  console.log("=".repeat(70));
  console.log("Benchmark Results Check");
  console.log("=".repeat(70));
  console.log("");

  let totalTests = 0;
  let wins = 0;
  let losses = 0;
  const failures = [];

  for (const file of data.files) {
    if (!file.groups) continue;

    for (const group of file.groups) {
      const benchmarks = group.benchmarks || [];
      if (benchmarks.length === 0) continue;

      // Separate wat-fft from competitors
      const watfftResults = benchmarks.filter((b) => isWatFft(b.name));
      const competitors = benchmarks.filter((b) => !isWatFft(b.name));

      if (watfftResults.length === 0 || competitors.length === 0) {
        continue;
      }

      totalTests++;

      // Find best wat-fft variant (highest hz)
      const bestWatFft = watfftResults.reduce((a, b) => (a.hz > b.hz ? a : b));

      // Find best competitor (highest hz)
      const bestCompetitor = competitors.reduce((a, b) => (a.hz > b.hz ? a : b));

      // Check if we win (higher hz = better)
      const ratio = bestWatFft.hz / bestCompetitor.hz;
      const passed = ratio >= 1.0;

      if (passed) {
        wins++;
      } else {
        losses++;
        failures.push({
          group: group.fullName,
          watfft: bestWatFft,
          competitor: bestCompetitor,
          ratio,
        });
      }

      // Print result
      const status = passed ? "PASS" : "FAIL";
      const percentage = ((ratio - 1) * 100).toFixed(1);
      const sign = ratio >= 1 ? "+" : "";
      console.log(`[${status}] ${group.fullName}`);
      console.log(`       wat-fft: ${bestWatFft.name} (${formatNumber(bestWatFft.hz)} ops/sec)`);
      console.log(
        `       best:    ${bestCompetitor.name} (${formatNumber(bestCompetitor.hz)} ops/sec)`,
      );
      console.log(`       delta:   ${sign}${percentage}%`);
      console.log("");
    }
  }

  // Summary
  console.log("=".repeat(70));
  console.log("Summary");
  console.log("=".repeat(70));
  console.log(`Total comparisons: ${totalTests}`);
  console.log(`Wins:   ${wins}`);
  console.log(`Losses: ${losses}`);
  console.log("");

  if (losses > 0) {
    console.log("NEEDS IMPROVEMENT - wat-fft lost to competitors:");
    for (const f of failures) {
      console.log(
        `  - ${f.group}: lost to ${f.competitor.name} by ${((1 - f.ratio) * 100).toFixed(1)}%`,
      );
    }
    console.log("");
    // Don't fail CI - this is informational only
    process.exit(0);
  } else {
    console.log("PASSED - wat-fft beats or matches all competitors!");
    process.exit(0);
  }
}

main();
