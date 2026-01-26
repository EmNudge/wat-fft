#!/usr/bin/env node
/**
 * WASM Dead Code Linter
 *
 * Uses Twiggy (https://rustwasm.github.io/twiggy/) to detect unreferenced
 * code in WASM binaries. This catches dead functions that are compiled but
 * never called from any export.
 *
 * Prerequisites:
 *   cargo install twiggy
 *
 * Usage:
 *   node tools/lint-wasm-dead-code.js [--fix] [--verbose]
 *
 * Options:
 *   --fix      Show suggestions for removing dead code
 *   --verbose  Show all output, including clean modules
 *   --strict   Fail on any dead code (default: only fail on primary modules)
 */

import { spawnSync } from "child_process";
import { readdirSync, existsSync } from "fs";
import { join } from "path";

// Primary modules that MUST have zero dead code
const PRIMARY_MODULES = [
  "fft_real_f32_dual.wasm", // Main f32 RFFT - our fastest implementation
  "fft_combined.wasm", // Main complex FFT
];

// Secondary modules where dead code is a warning (legacy/experimental)
const SECONDARY_MODULES = [
  "fft_real_combined.wasm", // Legacy f64 RFFT
  "fft_stockham_f32_dual.wasm", // f32 complex FFT
];

const DIST_DIR = "dist";

function checkTwiggyInstalled() {
  const result = spawnSync("twiggy", ["--version"], { encoding: "utf8" });
  if (result.error || result.status !== 0) {
    console.error("Error: Twiggy is not installed.");
    console.error("Install it with: cargo install twiggy");
    console.error("See: https://rustwasm.github.io/twiggy/concepts/concepts.html");
    process.exit(1);
  }
  return result.stdout.trim();
}

function runTwiggyGarbage(wasmPath) {
  const result = spawnSync("twiggy", ["garbage", "--all", wasmPath], {
    encoding: "utf8",
  });

  if (result.error) {
    return { error: result.error.message, items: [] };
  }

  if (result.status !== 0) {
    return { error: result.stderr || "Unknown error", items: [] };
  }

  // Parse twiggy output
  const lines = result.stdout.trim().split("\n");
  const items = [];
  let totalBytes = 0;
  let totalPercent = 0;

  for (const line of lines) {
    // Skip header lines
    if (line.includes("Bytes") || line.includes("───") || !line.trim()) continue;

    // Parse: " 71551 ┊ 29.49% ┊ fft_1024"
    const match = line.match(/^\s*(\d+)\s*┊\s*([\d.]+)%\s*┊\s*(.+)$/);
    if (match) {
      const bytes = parseInt(match[1], 10);
      const percent = parseFloat(match[2]);
      const name = match[3].trim();

      if (name.startsWith("Σ")) {
        // Summary line
        totalBytes = bytes;
        totalPercent = percent;
      } else if (!name.startsWith("...")) {
        items.push({ name, bytes, percent });
      }
    }
  }

  return { items, totalBytes, totalPercent };
}

function formatBytes(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function main() {
  const args = process.argv.slice(2);
  const verbose = args.includes("--verbose");
  const strict = args.includes("--strict");
  const showFix = args.includes("--fix");

  console.log("WASM Dead Code Lint");
  console.log("=".repeat(50));

  const twiggyVersion = checkTwiggyInstalled();
  if (verbose) {
    console.log(`Using ${twiggyVersion}`);
  }

  if (!existsSync(DIST_DIR)) {
    console.error(`Error: ${DIST_DIR} directory not found. Run 'npm run build' first.`);
    process.exit(1);
  }

  const wasmFiles = readdirSync(DIST_DIR).filter((f) => f.endsWith(".wasm"));

  if (wasmFiles.length === 0) {
    console.error("No WASM files found in dist/");
    process.exit(1);
  }

  let hasErrors = false;
  let hasWarnings = false;
  const results = [];

  for (const file of wasmFiles) {
    const wasmPath = join(DIST_DIR, file);
    const result = runTwiggyGarbage(wasmPath);

    if (result.error) {
      console.error(`\nError analyzing ${file}: ${result.error}`);
      hasErrors = true;
      continue;
    }

    const isPrimary = PRIMARY_MODULES.includes(file);
    const isSecondary = SECONDARY_MODULES.includes(file);
    const hasGarbage = result.items.length > 0;

    results.push({
      file,
      isPrimary,
      isSecondary,
      ...result,
    });

    // Determine status
    if (hasGarbage) {
      if (isPrimary || strict) {
        hasErrors = true;
      } else if (isSecondary) {
        hasWarnings = true;
      }
    }
  }

  // Print results
  console.log("");
  for (const r of results) {
    const status =
      r.items.length === 0 ? "✓" : r.isPrimary || strict ? "✗" : r.isSecondary ? "⚠" : "?";
    const statusText =
      r.items.length === 0
        ? "clean"
        : `${r.items.length} dead functions (${formatBytes(r.totalBytes)}, ${r.totalPercent.toFixed(1)}%)`;

    if (r.items.length === 0 && !verbose) {
      continue; // Skip clean modules unless verbose
    }

    console.log(`${status} ${r.file}: ${statusText}`);

    if (r.items.length > 0 && (verbose || r.isPrimary || strict)) {
      for (const item of r.items.slice(0, 10)) {
        console.log(`    - ${item.name} (${formatBytes(item.bytes)})`);
      }
      if (r.items.length > 10) {
        console.log(`    ... and ${r.items.length - 10} more`);
      }
    }
  }

  // Summary
  console.log("");
  console.log("-".repeat(50));

  const cleanCount = results.filter((r) => r.items.length === 0).length;
  const errorCount = results.filter((r) => r.items.length > 0 && (r.isPrimary || strict)).length;
  const warnCount = results.filter((r) => r.items.length > 0 && r.isSecondary && !strict).length;

  console.log(
    `${cleanCount}/${results.length} modules clean, ${errorCount} errors, ${warnCount} warnings`,
  );

  if (showFix && (hasErrors || hasWarnings)) {
    console.log("");
    console.log("To fix dead code:");
    console.log("  1. Search for the function in modules/*.wat with: grep -n 'func $name'");
    console.log("  2. Verify it's not called: grep 'call $name' modules/*.wat");
    console.log("  3. Remove the function and rebuild: npm run build");
    console.log("  4. Run tests to verify: npm test");
  }

  if (hasErrors) {
    console.log("");
    console.log("FAILED: Primary modules have dead code that must be removed.");
    process.exit(1);
  }

  if (hasWarnings && verbose) {
    console.log("");
    console.log("WARNING: Secondary modules have dead code (use --strict to fail)");
  }

  console.log("");
  console.log("PASSED");
  process.exit(0);
}

main();
