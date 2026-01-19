/**
 * Single Butterfly Tester
 *
 * Tests FFT butterfly operations in isolation to verify the math is correct
 * independent of the overall algorithm structure.
 */

import path from "path";
import { fileURLToPath } from "url";
import fc from "fast-check";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

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

// Multiply by -j: (a + bi) * (-j) = b - ai
function mulNegJ(ar, ai) {
  return [ai, -ar];
}

// Multiply by +j: (a + bi) * j = -b + ai
function mulPosJ(ar, ai) {
  return [-ai, ar];
}

/**
 * Reference Radix-2 butterfly (DIT)
 * y0 = x0 + W * x1
 * y1 = x0 - W * x1
 */
function radix2Butterfly(x0r, x0i, x1r, x1i, wr, wi) {
  const [wx1r, wx1i] = cmul(x1r, x1i, wr, wi);
  const [y0r, y0i] = cadd(x0r, x0i, wx1r, wx1i);
  const [y1r, y1i] = csub(x0r, x0i, wx1r, wx1i);
  return { y0: [y0r, y0i], y1: [y1r, y1i] };
}

/**
 * Reference Radix-4 butterfly (DIT)
 * t0 = x0 + x2
 * t1 = x1 + x3
 * t2 = x0 - x2
 * t3 = (x1 - x3) * (-j)
 *
 * y0 = t0 + t1
 * y1 = t2 + t3
 * y2 = t0 - t1
 * y3 = t2 - t3
 */
function radix4Butterfly(x0r, x0i, x1r, x1i, x2r, x2i, x3r, x3i) {
  const [t0r, t0i] = cadd(x0r, x0i, x2r, x2i);
  const [t1r, t1i] = cadd(x1r, x1i, x3r, x3i);
  const [t2r, t2i] = csub(x0r, x0i, x2r, x2i);
  const [diff13r, diff13i] = csub(x1r, x1i, x3r, x3i);
  const [t3r, t3i] = mulNegJ(diff13r, diff13i);

  return {
    y0: cadd(t0r, t0i, t1r, t1i),
    y1: cadd(t2r, t2i, t3r, t3i),
    y2: csub(t0r, t0i, t1r, t1i),
    y3: csub(t2r, t2i, t3r, t3i),
  };
}

/**
 * Reference Radix-4 butterfly with twiddle factors applied
 * x1 = x1 * W1, x2 = x2 * W2, x3 = x3 * W3 before butterfly
 */
function radix4ButterflyWithTwiddles(
  x0r,
  x0i,
  x1r,
  x1i,
  x2r,
  x2i,
  x3r,
  x3i,
  w1r,
  w1i,
  w2r,
  w2i,
  w3r,
  w3i,
) {
  // Apply twiddles
  [x1r, x1i] = cmul(x1r, x1i, w1r, w1i);
  [x2r, x2i] = cmul(x2r, x2i, w2r, w2i);
  [x3r, x3i] = cmul(x3r, x3i, w3r, w3i);

  return radix4Butterfly(x0r, x0i, x1r, x1i, x2r, x2i, x3r, x3i);
}

/**
 * Verify 4-point DFT via radix-4 butterfly equals direct DFT
 */
function verify4PointDFT(x0r, x0i, x1r, x1i, x2r, x2i, x3r, x3i) {
  // Radix-4 butterfly (no twiddles for 4-point DFT at first stage)
  const butterfly = radix4Butterfly(x0r, x0i, x1r, x1i, x2r, x2i, x3r, x3i);

  // Direct 4-point DFT
  const dft = [];
  const inputs = [
    [x0r, x0i],
    [x1r, x1i],
    [x2r, x2i],
    [x3r, x3i],
  ];

  for (let k = 0; k < 4; k++) {
    let sumR = 0,
      sumI = 0;
    for (let n = 0; n < 4; n++) {
      const angle = (-2 * Math.PI * k * n) / 4;
      const [wr, wi] = [Math.cos(angle), Math.sin(angle)];
      const [pr, pi] = cmul(inputs[n][0], inputs[n][1], wr, wi);
      sumR += pr;
      sumI += pi;
    }
    dft.push([sumR, sumI]);
  }

  return {
    butterfly: [butterfly.y0, butterfly.y1, butterfly.y2, butterfly.y3],
    dft,
    match: dft.every((d, i) => {
      const b = [butterfly.y0, butterfly.y1, butterfly.y2, butterfly.y3][i];
      return Math.abs(d[0] - b[0]) < 1e-10 && Math.abs(d[1] - b[1]) < 1e-10;
    }),
  };
}

/**
 * Property-based tests for butterfly operations
 */
function runButterflyTests() {
  console.log("═".repeat(70));
  console.log("Butterfly Operation Tests");
  console.log("═".repeat(70));
  console.log("");

  // Complex number arbitrary
  const complexArb = fc.tuple(
    fc.double({ min: -100, max: 100, noNaN: true, noDefaultInfinity: true }),
    fc.double({ min: -100, max: 100, noNaN: true, noDefaultInfinity: true }),
  );

  // Twiddle factor arbitrary (unit complex number)
  const _twiddleArb = fc
    .double({ min: 0, max: 2 * Math.PI })
    .map((angle) => [Math.cos(angle), Math.sin(angle)]);

  let allPassed = true;

  // Test 1: Radix-2 butterfly is self-inverse (up to scaling)
  console.log("1. Radix-2 butterfly inverse property...");
  try {
    fc.assert(
      fc.property(complexArb, complexArb, ([x0r, x0i], [x1r, x1i]) => {
        // Forward: y = butterfly(x) with W = 1
        const fwd = radix2Butterfly(x0r, x0i, x1r, x1i, 1, 0);

        // Inverse: x' = butterfly(y) / 2 with W = 1
        const inv = radix2Butterfly(fwd.y0[0], fwd.y0[1], fwd.y1[0], fwd.y1[1], 1, 0);

        // Should get back original (scaled by 2)
        return (
          Math.abs(inv.y0[0] / 2 - x0r) < 1e-9 &&
          Math.abs(inv.y0[1] / 2 - x0i) < 1e-9 &&
          Math.abs(inv.y1[0] / 2 - x1r) < 1e-9 &&
          Math.abs(inv.y1[1] / 2 - x1i) < 1e-9
        );
      }),
      { numRuns: 100 },
    );
    console.log("   ✓ Passed\n");
  } catch (e) {
    console.log("   ✗ Failed:", e.message.split("\n")[0], "\n");
    allPassed = false;
  }

  // Test 2: Radix-4 butterfly matches 4-point DFT
  console.log("2. Radix-4 butterfly matches 4-point DFT...");
  try {
    fc.assert(
      fc.property(
        complexArb,
        complexArb,
        complexArb,
        complexArb,
        ([x0r, x0i], [x1r, x1i], [x2r, x2i], [x3r, x3i]) => {
          const result = verify4PointDFT(x0r, x0i, x1r, x1i, x2r, x2i, x3r, x3i);
          return result.match;
        },
      ),
      { numRuns: 100 },
    );
    console.log("   ✓ Passed\n");
  } catch (e) {
    console.log("   ✗ Failed:", e.message.split("\n")[0], "\n");
    allPassed = false;
  }

  // Test 3: Radix-4 linearity
  console.log("3. Radix-4 butterfly linearity...");
  try {
    fc.assert(
      fc.property(
        complexArb,
        complexArb,
        complexArb,
        complexArb,
        complexArb,
        complexArb,
        complexArb,
        complexArb,
        fc.double({ min: -10, max: 10, noNaN: true }),
        (x0, x1, x2, x3, y0, y1, y2, y3, a) => {
          // butterfly(a*x) should equal a*butterfly(x)
          const bfX = radix4Butterfly(x0[0], x0[1], x1[0], x1[1], x2[0], x2[1], x3[0], x3[1]);
          const bfAX = radix4Butterfly(
            a * x0[0],
            a * x0[1],
            a * x1[0],
            a * x1[1],
            a * x2[0],
            a * x2[1],
            a * x3[0],
            a * x3[1],
          );

          return (
            Math.abs(bfAX.y0[0] - a * bfX.y0[0]) < 1e-9 * Math.max(1, Math.abs(a)) &&
            Math.abs(bfAX.y0[1] - a * bfX.y0[1]) < 1e-9 * Math.max(1, Math.abs(a)) &&
            Math.abs(bfAX.y1[0] - a * bfX.y1[0]) < 1e-9 * Math.max(1, Math.abs(a)) &&
            Math.abs(bfAX.y1[1] - a * bfX.y1[1]) < 1e-9 * Math.max(1, Math.abs(a)) &&
            Math.abs(bfAX.y2[0] - a * bfX.y2[0]) < 1e-9 * Math.max(1, Math.abs(a)) &&
            Math.abs(bfAX.y2[1] - a * bfX.y2[1]) < 1e-9 * Math.max(1, Math.abs(a)) &&
            Math.abs(bfAX.y3[0] - a * bfX.y3[0]) < 1e-9 * Math.max(1, Math.abs(a)) &&
            Math.abs(bfAX.y3[1] - a * bfX.y3[1]) < 1e-9 * Math.max(1, Math.abs(a))
          );
        },
      ),
      { numRuns: 100 },
    );
    console.log("   ✓ Passed\n");
  } catch (e) {
    console.log("   ✗ Failed:", e.message.split("\n")[0], "\n");
    allPassed = false;
  }

  // Test 4: mul_neg_j is correct
  console.log("4. mul_neg_j: (a+bi)*(-j) = b - ai...");
  try {
    fc.assert(
      fc.property(complexArb, ([ar, ai]) => {
        const [rr, ri] = mulNegJ(ar, ai);
        // (a + bi) * (-j) = (a + bi) * (0 - 1i) = -ai + b(-1)i*i = -ai - b(-1) = b - ai
        // So result should be [b, -a] = [ai, -ar]
        return Math.abs(rr - ai) < 1e-10 && Math.abs(ri - -ar) < 1e-10;
      }),
      { numRuns: 100 },
    );
    console.log("   ✓ Passed\n");
  } catch (e) {
    console.log("   ✗ Failed:", e.message.split("\n")[0], "\n");
    allPassed = false;
  }

  // Test 5: mul_pos_j is correct
  console.log("5. mul_pos_j: (a+bi)*j = -b + ai...");
  try {
    fc.assert(
      fc.property(complexArb, ([ar, ai]) => {
        const [rr, ri] = mulPosJ(ar, ai);
        // (a + bi) * j = (a + bi) * (0 + 1i) = ai + bi*i = ai - b = -b + ai
        // So result should be [-b, a] = [-ai, ar]
        return Math.abs(rr - -ai) < 1e-10 && Math.abs(ri - ar) < 1e-10;
      }),
      { numRuns: 100 },
    );
    console.log("   ✓ Passed\n");
  } catch (e) {
    console.log("   ✗ Failed:", e.message.split("\n")[0], "\n");
    allPassed = false;
  }

  // Test 6: Complex multiply associativity
  console.log("6. Complex multiply associativity: (a*b)*c = a*(b*c)...");
  try {
    fc.assert(
      fc.property(complexArb, complexArb, complexArb, ([ar, ai], [br, bi], [cr, ci]) => {
        const [abr, abi] = cmul(ar, ai, br, bi);
        const [abc1r, abc1i] = cmul(abr, abi, cr, ci);

        const [bcr, bci] = cmul(br, bi, cr, ci);
        const [abc2r, abc2i] = cmul(ar, ai, bcr, bci);

        return Math.abs(abc1r - abc2r) < 1e-8 && Math.abs(abc1i - abc2i) < 1e-8;
      }),
      { numRuns: 100 },
    );
    console.log("   ✓ Passed\n");
  } catch (e) {
    console.log("   ✗ Failed:", e.message.split("\n")[0], "\n");
    allPassed = false;
  }

  // Summary
  console.log("═".repeat(70));
  if (allPassed) {
    console.log("All butterfly tests passed!");
  } else {
    console.log("Some butterfly tests failed.");
  }
  console.log("═".repeat(70));

  return allPassed;
}

/**
 * Manual test with specific values
 */
function manualButterflyTest() {
  console.log("\n" + "═".repeat(70));
  console.log("Manual Butterfly Tests");
  console.log("═".repeat(70));

  // Test: Radix-4 with simple inputs
  console.log("\nRadix-4 butterfly with inputs [1, 0, 0, 0]:");
  const bf1 = radix4Butterfly(1, 0, 0, 0, 0, 0, 0, 0);
  console.log("  y0 =", bf1.y0.map((x) => x.toFixed(4)).join(" + ") + "i");
  console.log("  y1 =", bf1.y1.map((x) => x.toFixed(4)).join(" + ") + "i");
  console.log("  y2 =", bf1.y2.map((x) => x.toFixed(4)).join(" + ") + "i");
  console.log("  y3 =", bf1.y3.map((x) => x.toFixed(4)).join(" + ") + "i");
  console.log("  Expected: all [1, 0] (impulse -> flat spectrum)");

  // Test: Radix-4 with [1, 1, 1, 1]
  console.log("\nRadix-4 butterfly with inputs [1, 1, 1, 1]:");
  const bf2 = radix4Butterfly(1, 0, 1, 0, 1, 0, 1, 0);
  console.log("  y0 =", bf2.y0.map((x) => x.toFixed(4)).join(" + ") + "i");
  console.log("  y1 =", bf2.y1.map((x) => x.toFixed(4)).join(" + ") + "i");
  console.log("  y2 =", bf2.y2.map((x) => x.toFixed(4)).join(" + ") + "i");
  console.log("  y3 =", bf2.y3.map((x) => x.toFixed(4)).join(" + ") + "i");
  console.log("  Expected: [4,0], [0,0], [0,0], [0,0] (DC only)");

  // Test: Radix-4 with [1, -1, 1, -1]
  console.log("\nRadix-4 butterfly with inputs [1, -1, 1, -1]:");
  const bf3 = radix4Butterfly(1, 0, -1, 0, 1, 0, -1, 0);
  console.log("  y0 =", bf3.y0.map((x) => x.toFixed(4)).join(" + ") + "i");
  console.log("  y1 =", bf3.y1.map((x) => x.toFixed(4)).join(" + ") + "i");
  console.log("  y2 =", bf3.y2.map((x) => x.toFixed(4)).join(" + ") + "i");
  console.log("  y3 =", bf3.y3.map((x) => x.toFixed(4)).join(" + ") + "i");
  console.log("  Expected: [0,0], [0,0], [4,0], [0,0] (Nyquist only)");

  // Verify against DFT
  console.log("\nVerification against 4-point DFT:");
  const verify = verify4PointDFT(1, 0, 0, 0, 0, 0, 0, 0);
  console.log(
    "  Butterfly:",
    verify.butterfly.map((c) => `[${c[0].toFixed(2)}, ${c[1].toFixed(2)}]`).join(", "),
  );
  console.log(
    "  DFT:      ",
    verify.dft.map((c) => `[${c[0].toFixed(2)}, ${c[1].toFixed(2)}]`).join(", "),
  );
  console.log("  Match:", verify.match ? "✓" : "✗");
}

// Export functions
export {
  cmul,
  cadd,
  csub,
  mulNegJ,
  mulPosJ,
  radix2Butterfly,
  radix4Butterfly,
  radix4ButterflyWithTwiddles,
  verify4PointDFT,
  runButterflyTests,
};

// CLI
if (process.argv[1].endsWith("butterfly_tester.js")) {
  runButterflyTests();
  manualButterflyTest();
}
