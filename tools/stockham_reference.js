/**
 * Stockham FFT Reference Implementation
 *
 * Correct implementation based on:
 * - https://github.com/scientificgo/fft/blob/master/stockham.go
 * - "Computational Frameworks for the Fast Fourier Transform" by Van Loan
 *
 * Key insight: Stockham performs digit transposition incrementally.
 * At each stage, the stride changes and output positions are reordered.
 */

/**
 * Complex number operations
 */
function cmul(ar, ai, br, bi) {
  return [ar * br - ai * bi, ar * bi + ai * br];
}

function cadd(ar, ai, br, bi) {
  return [ar + br, ai + bi];
}

function csub(ar, ai, br, bi) {
  return [ar - br, ai - bi];
}

/**
 * Correct Radix-2 Stockham FFT
 * Based on Go reference implementation
 *
 * @param {Float64Array} real - Real parts
 * @param {Float64Array} imag - Imaginary parts
 * @param {Object} options - { verbose: boolean }
 * @returns {Object} { real, imag }
 */
export function stockhamRadix2(real, imag, options = {}) {
  const { verbose = false } = options;
  const n = real.length;
  const n2 = n / 2;
  const log2n = Math.log2(n);

  if (!Number.isInteger(log2n)) {
    throw new Error("N must be a power of 2");
  }

  // Initialize buffers (ping-pong)
  let src = { real: new Float64Array(real), imag: new Float64Array(imag) };
  let dst = { real: new Float64Array(n), imag: new Float64Array(n) };

  if (verbose) {
    console.log(`\n${"=".repeat(60)}`);
    console.log(`Stockham Radix-2 FFT: N=${n}`);
    console.log(`${"=".repeat(60)}`);
    console.log("\nInput:");
    printComplex(src.real, src.imag, Math.min(8, n));
  }

  // r = butterfly "radius" (half-size), starts at n/2, halves each stage
  // l = number of groups, starts at 1, doubles each stage
  let stage = 0;
  for (let r = n2, l = 1; r >= 1; r >>= 1, l <<= 1) {
    if (verbose) {
      console.log(`\n${"─".repeat(60)}`);
      console.log(`Stage ${stage}: r=${r}, l=${l}, butterflies per group=${r}`);
      console.log(`${"─".repeat(60)}`);
    }

    // Twiddle factor increment: W = e^{-s*pi*i / l} where s=1 for forward FFT
    // For stage with l groups: angle increment = -pi / l
    const twiddleAngle = -Math.PI / l;
    const wInc = [Math.cos(twiddleAngle), Math.sin(twiddleAngle)];

    // For each group
    let wj = [1, 0]; // Twiddle for position j within group, starts at W^0 = 1
    for (let j = 0; j < l; j++) {
      const jrs = j * (r << 1); // Starting index for this group (j * 2r)

      // For each butterfly in this group
      for (let k = jrs, m = jrs >> 1; k < jrs + r; k++, m++) {
        // Read: src[k] and src[k+r]
        const x0r = src.real[k],
          x0i = src.imag[k];
        let x1r = src.real[k + r],
          x1i = src.imag[k + r];

        // Apply twiddle to x1
        const [tx1r, tx1i] = cmul(x1r, x1i, wj[0], wj[1]);

        // Butterfly: y0 = x0 + W*x1, y1 = x0 - W*x1
        // Write to: dst[m] and dst[m + n/2]
        [dst.real[m], dst.imag[m]] = cadd(x0r, x0i, tx1r, tx1i);
        [dst.real[m + n2], dst.imag[m + n2]] = csub(x0r, x0i, tx1r, tx1i);

        if (verbose && j < 2 && k - jrs < 2) {
          console.log(`  j=${j}, k=${k}: read [${k},${k + r}] -> write [${m},${m + n2}]`);
        }
      }

      // Update twiddle for next j: wj *= wInc
      wj = cmul(wj[0], wj[1], wInc[0], wInc[1]);
    }

    // Swap buffers
    [src, dst] = [dst, src];
    stage++;

    if (verbose) {
      console.log(`\n  After stage (now in src):`);
      printComplex(src.real, src.imag, Math.min(8, n));
    }
  }

  if (verbose) {
    console.log(`\n${"=".repeat(60)}`);
    console.log("Final Output:");
    printComplex(src.real, src.imag, Math.min(8, n));
    console.log(`${"=".repeat(60)}\n`);
  }

  return { real: src.real, imag: src.imag };
}

/**
 * Correct Radix-4 Stockham FFT
 *
 * For radix-4, we process 4 elements per butterfly.
 * r = butterfly quarter-size, starts at n/4, quarters each stage
 * l = number of groups, starts at 1, quadruples each stage
 */
export function stockhamRadix4(real, imag, options = {}) {
  const { verbose = false } = options;
  const n = real.length;
  const log2n = Math.log2(n);
  const log4n = log2n / 2;

  if (!Number.isInteger(log2n)) {
    throw new Error("N must be a power of 2");
  }

  // Initialize buffers
  let src = { real: new Float64Array(real), imag: new Float64Array(imag) };
  let dst = { real: new Float64Array(n), imag: new Float64Array(n) };

  if (verbose) {
    console.log(`\n${"=".repeat(60)}`);
    console.log(`Stockham Radix-4 FFT: N=${n}, log4(N)=${log4n}`);
    console.log(`${"=".repeat(60)}`);
    console.log("\nInput:");
    printComplex(src.real, src.imag, Math.min(8, n));
  }

  const numRadix4Stages = Math.floor(log4n);
  let stage = 0;

  // Radix-4 stages
  // r = quarter-butterfly-size, starts at n/4, quarters each stage
  // l = number of groups, starts at 1, quadruples each stage
  for (let r = n >> 2, l = 1; stage < numRadix4Stages; r >>= 2, l <<= 2) {
    if (verbose) {
      console.log(`\n${"─".repeat(60)}`);
      console.log(`Radix-4 Stage ${stage}: r=${r}, l=${l}`);
      console.log(`${"─".repeat(60)}`);
    }

    // Twiddle angle increment for this stage
    // Base twiddle: W_N^1 where effective N = 4*l*r at this stage
    const twiddleBase = (-2 * Math.PI) / (4 * l * r);

    for (let j = 0; j < l; j++) {
      // Twiddle factors for this j position
      const angle1 = j * twiddleBase;
      const angle2 = 2 * j * twiddleBase;
      const angle3 = 3 * j * twiddleBase;
      const w1 = [Math.cos(angle1), Math.sin(angle1)];
      const w2 = [Math.cos(angle2), Math.sin(angle2)];
      const w3 = [Math.cos(angle3), Math.sin(angle3)];

      const jrs = j * (r << 2); // j * 4r = starting position for this group

      for (let k = 0; k < r; k++) {
        // Input positions: 4 elements spaced by r within this group
        const i0 = jrs + k;
        const i1 = i0 + r;
        const i2 = i1 + r;
        const i3 = i2 + r;

        // Output positions: interleaved by l
        // m = base output position for this butterfly
        const m = (jrs >> 2) + k; // (j * 4r) / 4 + k = j*r + k
        const o0 = m;
        const o1 = o0 + (n >> 2); // m + n/4
        const o2 = o1 + (n >> 2); // m + n/2
        const o3 = o2 + (n >> 2); // m + 3n/4

        if (verbose && j < 2 && k < 2) {
          console.log(
            `  j=${j}, k=${k}: read [${i0},${i1},${i2},${i3}] -> write [${o0},${o1},${o2},${o3}]`,
          );
        }

        // Load inputs
        let x0r = src.real[i0],
          x0i = src.imag[i0];
        let x1r = src.real[i1],
          x1i = src.imag[i1];
        let x2r = src.real[i2],
          x2i = src.imag[i2];
        let x3r = src.real[i3],
          x3i = src.imag[i3];

        // Apply twiddle factors
        if (j > 0) {
          [x1r, x1i] = cmul(x1r, x1i, w1[0], w1[1]);
          [x2r, x2i] = cmul(x2r, x2i, w2[0], w2[1]);
          [x3r, x3i] = cmul(x3r, x3i, w3[0], w3[1]);
        }

        // Radix-4 DIT butterfly
        const [t0r, t0i] = cadd(x0r, x0i, x2r, x2i);
        const [t1r, t1i] = cadd(x1r, x1i, x3r, x3i);
        const [t2r, t2i] = csub(x0r, x0i, x2r, x2i);
        // t3 = (x1 - x3) * (-j) where -j means swap and negate appropriately
        const [d13r, d13i] = csub(x1r, x1i, x3r, x3i);
        const [t3r, t3i] = [d13i, -d13r]; // multiply by -j

        // Output: y0 = t0+t1, y1 = t2+t3, y2 = t0-t1, y3 = t2-t3
        [dst.real[o0], dst.imag[o0]] = cadd(t0r, t0i, t1r, t1i);
        [dst.real[o1], dst.imag[o1]] = cadd(t2r, t2i, t3r, t3i);
        [dst.real[o2], dst.imag[o2]] = csub(t0r, t0i, t1r, t1i);
        [dst.real[o3], dst.imag[o3]] = csub(t2r, t2i, t3r, t3i);
      }
    }

    [src, dst] = [dst, src];
    stage++;

    if (verbose) {
      console.log(`\n  After stage (now in src):`);
      printComplex(src.real, src.imag, Math.min(8, n));
    }
  }

  // Final radix-2 stage if needed (when log2n is odd)
  if (log2n % 2 === 1) {
    if (verbose) {
      console.log(`\n${"─".repeat(60)}`);
      console.log(`Radix-2 Final Stage`);
      console.log(`${"─".repeat(60)}`);
    }

    const n2 = n >> 1;
    // At this point, l = n/2 (from radix-4 stages)
    // r = 1 for final radix-2

    for (let j = 0; j < n2; j++) {
      const i0 = j;
      const i1 = j + n2;
      const o0 = j;
      const o1 = j + n2;

      let x0r = src.real[i0],
        x0i = src.imag[i0];
      let x1r = src.real[i1],
        x1i = src.imag[i1];

      // Twiddle: W_N^j
      if (j > 0) {
        const angle = (-2 * Math.PI * j) / n;
        const [wr, wi] = [Math.cos(angle), Math.sin(angle)];
        [x1r, x1i] = cmul(x1r, x1i, wr, wi);
      }

      [dst.real[o0], dst.imag[o0]] = cadd(x0r, x0i, x1r, x1i);
      [dst.real[o1], dst.imag[o1]] = csub(x0r, x0i, x1r, x1i);

      if (verbose && j < 4) {
        console.log(`  j=${j}: read [${i0},${i1}] -> write [${o0},${o1}]`);
      }
    }

    [src, dst] = [dst, src];

    if (verbose) {
      console.log(`\n  After radix-2 stage (now in src):`);
      printComplex(src.real, src.imag, Math.min(8, n));
    }
  }

  if (verbose) {
    console.log(`\n${"=".repeat(60)}`);
    console.log("Final Output:");
    printComplex(src.real, src.imag, Math.min(8, n));
    console.log(`${"=".repeat(60)}\n`);
  }

  return { real: src.real, imag: src.imag };
}

// Legacy export for compatibility
export function stockhamFFT(real, imag, options = {}) {
  return stockhamRadix4(real, imag, options);
}

/**
 * Print complex array nicely
 */
function printComplex(real, imag, limit = 8) {
  const n = real.length;
  for (let i = 0; i < Math.min(limit, n); i++) {
    const sign = imag[i] >= 0 ? "+" : "";
    console.log(`  [${i}] ${real[i].toFixed(6)} ${sign}${imag[i].toFixed(6)}i`);
  }
  if (n > limit) {
    console.log(`  ... (${n - limit} more)`);
  }
}

/**
 * Reference DFT for verification
 */
export function referenceDFT(real, imag) {
  const n = real.length;
  const outReal = new Float64Array(n);
  const outImag = new Float64Array(n);

  for (let k = 0; k < n; k++) {
    let sumReal = 0;
    let sumImag = 0;
    for (let j = 0; j < n; j++) {
      const angle = (-2 * Math.PI * k * j) / n;
      const cos = Math.cos(angle);
      const sin = Math.sin(angle);
      sumReal += real[j] * cos - imag[j] * sin;
      sumImag += real[j] * sin + imag[j] * cos;
    }
    outReal[k] = sumReal;
    outImag[k] = sumImag;
  }

  return { real: outReal, imag: outImag };
}

/**
 * Compare two complex arrays
 */
export function compareResults(actual, expected, tolerance = 1e-10) {
  const n = expected.real.length;
  const errors = [];

  for (let i = 0; i < n; i++) {
    const realDiff = Math.abs(actual.real[i] - expected.real[i]);
    const imagDiff = Math.abs(actual.imag[i] - expected.imag[i]);

    if (realDiff > tolerance) {
      errors.push({
        index: i,
        component: "real",
        actual: actual.real[i],
        expected: expected.real[i],
        diff: realDiff,
      });
    }
    if (imagDiff > tolerance) {
      errors.push({
        index: i,
        component: "imag",
        actual: actual.imag[i],
        expected: expected.imag[i],
        diff: imagDiff,
      });
    }
  }

  return errors;
}

// CLI for quick testing
if (process.argv[1]?.endsWith("stockham_reference.js")) {
  const n = parseInt(process.argv[2]) || 16;
  const verbose = process.argv.includes("--verbose") || process.argv.includes("-v");
  const useRadix2 = process.argv.includes("--radix2");

  console.log(`Testing Stockham ${useRadix2 ? "radix-2" : "radix-4"} reference with N=${n}`);

  // Generate test input
  const real = new Float64Array(n);
  const imag = new Float64Array(n);
  real[0] = 1; // impulse

  // Run Stockham
  const result = useRadix2
    ? stockhamRadix2(real, imag, { verbose })
    : stockhamRadix4(real, imag, { verbose });

  // Compare with DFT
  const expected = referenceDFT(real, imag);
  const errors = compareResults(result, expected);

  if (errors.length === 0) {
    console.log("\n✓ Stockham reference matches DFT!");
  } else {
    console.log(`\n✗ ${errors.length} errors found:`);
    for (const err of errors.slice(0, 5)) {
      console.log(
        `  [${err.index}].${err.component}: got ${err.actual.toFixed(10)}, expected ${err.expected.toFixed(10)}`,
      );
    }
  }

  // Test multiple sizes
  console.log("\n--- Testing multiple sizes ---");
  for (const testN of [4, 8, 16, 32, 64, 128]) {
    const testReal = new Float64Array(testN);
    const testImag = new Float64Array(testN);
    testReal[0] = 1;

    const testResult = useRadix2
      ? stockhamRadix2(testReal, testImag, { verbose: false })
      : stockhamRadix4(testReal, testImag, { verbose: false });
    const testExpected = referenceDFT(testReal, testImag);
    const testErrors = compareResults(testResult, testExpected);

    console.log(
      `N=${testN.toString().padStart(4)}: ${testErrors.length === 0 ? "✓" : `✗ (${testErrors.length} errors)`}`,
    );
  }
}
