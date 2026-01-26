/**
 * Twiddle Factor Validation Test
 *
 * Extracts hardcoded twiddle constants from WAT source files and validates
 * them against computed values. This catches bugs where real/imaginary parts
 * are swapped or incorrect values are used.
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const modulesDir = path.join(__dirname, "..", "modules");

// Compute correct twiddle factor W_N^k = e^(-2πik/N) = (cos(-2πk/N), sin(-2πk/N))
function computeTwiddle(N, k) {
  const angle = (-2 * Math.PI * k) / N;
  return { re: Math.cos(angle), im: Math.sin(angle) };
}

// Extract twiddle constants from WAT source
// Looks for patterns like: W_32^15=(-0.9807..., -0.1950...)
function extractTwiddleComments(source) {
  const twiddles = [];
  const regex = /W_(\d+)\^(\d+)\s*=\s*\(\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*\)/g;
  let match;
  while ((match = regex.exec(source)) !== null) {
    twiddles.push({
      N: parseInt(match[1]),
      k: parseInt(match[2]),
      re: parseFloat(match[3]),
      im: parseFloat(match[4]),
      line: source.substring(0, match.index).split("\n").length,
    });
  }
  return twiddles;
}

function validateTwiddles(filename) {
  const filepath = path.join(modulesDir, filename);
  if (!fs.existsSync(filepath)) {
    console.log(`  Skipping ${filename} (not found)`);
    return { passed: 0, failed: 0 };
  }

  const source = fs.readFileSync(filepath, "utf-8");
  const twiddles = extractTwiddleComments(source);

  let passed = 0;
  let failed = 0;

  for (const tw of twiddles) {
    const expected = computeTwiddle(tw.N, tw.k);
    const errRe = Math.abs(tw.re - expected.re);
    const errIm = Math.abs(tw.im - expected.im);

    // Determine tolerance based on precision in comment
    // f32 comments have ~4-7 decimal digits, f64 have ~16
    const reDigits = tw.re.toString().replace(/^-?0?\.?/, "").length;
    const imDigits = tw.im.toString().replace(/^-?0?\.?/, "").length;
    const minDigits = Math.min(reDigits, imDigits);
    // Use 1e-3 for low precision (catches swapped values), 1e-10 for high precision
    const tolerance = minDigits > 10 ? 1e-10 : 1e-3;

    // Also check for swapped values (the actual bug we're catching)
    const swappedErrRe = Math.abs(tw.re - expected.im);
    const swappedErrIm = Math.abs(tw.im - expected.re);
    const looksSwapped =
      swappedErrRe < errRe * 0.1 && swappedErrIm < errIm * 0.1 && (errRe > 0.1 || errIm > 0.1);

    if (looksSwapped) {
      console.log(`  FAIL line ${tw.line}: W_${tw.N}^${tw.k} - VALUES APPEAR SWAPPED`);
      console.log(`    Comment:  (${tw.re}, ${tw.im})`);
      console.log(`    Expected: (${expected.re.toFixed(16)}, ${expected.im.toFixed(16)})`);
      failed++;
    } else if (errRe > tolerance || errIm > tolerance) {
      console.log(`  FAIL line ${tw.line}: W_${tw.N}^${tw.k}`);
      console.log(`    Comment:  (${tw.re}, ${tw.im})`);
      console.log(`    Expected: (${expected.re.toFixed(16)}, ${expected.im.toFixed(16)})`);
      failed++;
    } else {
      passed++;
    }
  }

  return { passed, failed };
}

function main() {
  console.log("=".repeat(60));
  console.log("Twiddle Factor Validation Test");
  console.log("=".repeat(60));
  console.log();

  const files = [
    "fft_combined.wat",
    "fft_real_combined.wat",
    "fft_stockham_f32_dual.wat",
    "fft_real_f32_dual.wat",
  ];

  let totalPassed = 0;
  let totalFailed = 0;

  for (const file of files) {
    console.log(`Checking ${file}...`);
    const { passed, failed } = validateTwiddles(file);
    totalPassed += passed;
    totalFailed += failed;
    if (failed === 0 && passed > 0) {
      console.log(`  ${passed} twiddle constants validated ✓`);
    } else if (passed === 0 && failed === 0) {
      console.log(`  No twiddle comments found`);
    }
    console.log();
  }

  console.log("=".repeat(60));
  if (totalFailed > 0) {
    console.log(`FAILED: ${totalFailed} incorrect twiddles found`);
    process.exitCode = 1;
  } else {
    console.log(`PASSED: ${totalPassed} twiddle constants validated`);
  }
  console.log("=".repeat(60));
}

main();
