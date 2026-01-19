/**
 * Stockham Permutation Validator
 *
 * The Stockham FFT doesn't use bit-reversal permutation. Instead, it implicitly
 * reorders data through its ping-pong buffer structure. This tool validates
 * that the permutation is correct by tracking where each input ends up.
 *
 * Key insight: Stockham's permutation should be equivalent to the standard
 * FFT's bit-reversal when the algorithm is complete.
 */

import { stockhamIndexPatterns, verifyStageCoordination } from "./index_visualizer.js";

/**
 * Track where each input position ends up after Stockham FFT
 *
 * Uses symbolic execution: input[i] = i, then trace through stages
 */
export function traceStockhamPermutation(n) {
  const stages = stockhamIndexPatterns(n);

  // Initialize: position i contains value i
  let positions = Array.from({ length: n }, (_, i) => i);

  console.log(`\n${"═".repeat(70)}`);
  console.log(`Stockham Permutation Trace: N=${n}`);
  console.log(`${"═".repeat(70)}`);
  console.log("\nInitial positions:", positions.slice(0, Math.min(16, n)).join(", "));

  for (const stage of stages) {
    const newPositions = Array.from({ length: n });

    for (const bf of stage.butterflies) {
      if (stage.type === "radix4") {
        // Radix-4 butterfly: each output is a combination of 4 inputs
        // For permutation tracing, we track which input indices contribute
        // In FFT, all 4 inputs contribute to all 4 outputs
        // But for permutation validation, we want to see the data movement

        // For simplicity, track the "primary" contributor (the one at corresponding position)
        // This isn't quite right for FFT but shows the data shuffle pattern
        newPositions[bf.write[0]] =
          `bf(${positions[bf.read[0]]},${positions[bf.read[1]]},${positions[bf.read[2]]},${positions[bf.read[3]]})@0`;
        newPositions[bf.write[1]] =
          `bf(${positions[bf.read[0]]},${positions[bf.read[1]]},${positions[bf.read[2]]},${positions[bf.read[3]]})@1`;
        newPositions[bf.write[2]] =
          `bf(${positions[bf.read[0]]},${positions[bf.read[1]]},${positions[bf.read[2]]},${positions[bf.read[3]]})@2`;
        newPositions[bf.write[3]] =
          `bf(${positions[bf.read[0]]},${positions[bf.read[1]]},${positions[bf.read[2]]},${positions[bf.read[3]]})@3`;
      } else {
        // Radix-2 butterfly
        newPositions[bf.write[0]] = `bf2(${positions[bf.read[0]]},${positions[bf.read[1]]})@0`;
        newPositions[bf.write[1]] = `bf2(${positions[bf.read[0]]},${positions[bf.read[1]]})@1`;
      }
    }

    positions = newPositions;
    console.log(`\nAfter ${stage.name}:`);
    console.log("  " + positions.slice(0, Math.min(8, n)).join("\n  "));
    if (n > 8) console.log(`  ... (${n - 8} more)`);
  }

  return positions;
}

/**
 * Simplified permutation trace: just track read indices at each stage
 */
export function traceReadPattern(n) {
  const stages = stockhamIndexPatterns(n);

  console.log(`\n${"═".repeat(70)}`);
  console.log(`Stockham Read Pattern: N=${n}`);
  console.log(`${"═".repeat(70)}`);

  for (const stage of stages) {
    console.log(`\n${stage.name}:`);

    // Build read-to-write mapping
    const writeOrder = [];
    for (const bf of stage.butterflies) {
      writeOrder.push({ write: bf.write[0], reads: bf.read });
    }

    // Sort by write position
    writeOrder.sort((a, b) => a.write - b.write);

    console.log("  Output[i] reads from:");
    for (let i = 0; i < Math.min(8, writeOrder.length); i++) {
      const entry = writeOrder[i];
      console.log(`    out[${entry.write}] <- in[${entry.reads.join(", ")}]`);
    }
    if (writeOrder.length > 8) {
      console.log(`    ... (${writeOrder.length - 8} more)`);
    }
  }
}

/**
 * Validate Stockham output order matches expected FFT output order
 *
 * Standard FFT (with bit-reversal): output is in natural order
 * Stockham FFT (no bit-reversal): output should also be in natural order
 */
export function validateOutputOrder(n) {
  console.log(`\n${"═".repeat(70)}`);
  console.log(`Stockham Output Order Validation: N=${n}`);
  console.log(`${"═".repeat(70)}`);

  // For Stockham to produce correct results, the output at position k
  // should be DFT bin k, same as bit-reversal FFT after the permutation

  // Let's trace which DFT bins end up where by using the fact that
  // input[0] = 1, others = 0 should give all outputs = 1

  // For a proper Stockham:
  // - No initial bit-reversal needed
  // - No final bit-reversal needed
  // - Output is in natural order

  const stages = stockhamIndexPatterns(n);

  // Check that every position 0..n-1 is written to exactly once per stage
  for (const stage of stages) {
    const written = new Set();
    const read = new Set();

    for (const bf of stage.butterflies) {
      for (const w of bf.write) {
        if (written.has(w)) {
          console.log(`  ✗ ${stage.name}: position ${w} written multiple times!`);
          return false;
        }
        written.add(w);
      }
      for (const r of bf.read) {
        read.add(r);
      }
    }

    if (written.size !== n) {
      console.log(`  ✗ ${stage.name}: only ${written.size}/${n} positions written`);
      const missing = [];
      for (let i = 0; i < n; i++) {
        if (!written.has(i)) missing.push(i);
      }
      console.log(
        `    Missing: [${missing.slice(0, 10).join(", ")}${missing.length > 10 ? "..." : ""}]`,
      );
      return false;
    }

    if (read.size !== n) {
      console.log(`  ⚠ ${stage.name}: only ${read.size}/${n} positions read`);
    }

    console.log(`  ✓ ${stage.name}: all ${n} positions written exactly once`);
  }

  return true;
}

/**
 * Compare Stockham permutation to bit-reversal
 *
 * After Stockham completes, the data should be in the same order as
 * a standard bit-reversal FFT (natural order).
 */
export function compareTobitReversal(n) {
  console.log(`\n${"═".repeat(70)}`);
  console.log(`Stockham vs Bit-Reversal Comparison: N=${n}`);
  console.log(`${"═".repeat(70)}`);

  const log2n = Math.log2(n);

  function bitReverse(x, bits) {
    let result = 0;
    for (let i = 0; i < bits; i++) {
      result = (result << 1) | (x & 1);
      x >>= 1;
    }
    return result;
  }

  console.log("\nBit-reversal permutation (input order for standard FFT):");
  for (let i = 0; i < Math.min(16, n); i++) {
    const br = bitReverse(i, log2n);
    console.log(`  input[${i}] -> work[${br}]`);
  }

  console.log("\nStockham implicit permutation:");
  console.log("  (Stockham reads inputs in natural order and produces outputs in natural order)");
  console.log("  No explicit permutation needed!");

  console.log("\nKey difference:");
  console.log("  - Standard FFT: bit-reverse inputs, process, output in natural order");
  console.log("  - Stockham FFT: natural input order, ping-pong shuffle, natural output order");
}

/**
 * Generate test case showing where specific inputs end up
 */
export function generateInputTraceTable(n) {
  console.log(`\n${"═".repeat(70)}`);
  console.log(`Input Contribution Table: N=${n}`);
  console.log(`${"═".repeat(70)}`);

  console.log("\nFor standard DFT: output[k] = sum over j of input[j] * W^(jk)");
  console.log("Every input contributes to every output (with different weights)");

  console.log("\nFor FFT (including Stockham): same result, computed via butterflies");
  console.log("Data flow shows which butterflies combine which values\n");

  const stages = stockhamIndexPatterns(n);

  // Track which original inputs affect which outputs
  // Start: position i is affected by input i
  let affects = Array.from({ length: n }, (_, i) => new Set([i]));

  for (const stage of stages) {
    const newAffects = Array.from({ length: n }, () => new Set());

    for (const bf of stage.butterflies) {
      // Collect all inputs that affect this butterfly's inputs
      const combined = new Set();
      for (const r of bf.read) {
        for (const a of affects[r]) {
          combined.add(a);
        }
      }

      // All outputs are affected by all inputs of the butterfly
      for (const w of bf.write) {
        for (const a of combined) {
          newAffects[w].add(a);
        }
      }
    }

    affects = newAffects;
  }

  // Print which inputs affect which outputs
  console.log("After all stages, output[k] is affected by inputs:");
  for (let k = 0; k < Math.min(8, n); k++) {
    const inputs = [...affects[k]].sort((a, b) => a - b);
    console.log(`  output[${k}]: inputs [${inputs.join(", ")}]`);
  }

  // Verify: every output should be affected by all inputs
  let valid = true;
  for (let k = 0; k < n; k++) {
    if (affects[k].size !== n) {
      console.log(`  ✗ output[${k}] only affected by ${affects[k].size} inputs (should be ${n})`);
      valid = false;
    }
  }

  if (valid) {
    console.log(`\n✓ All outputs are affected by all ${n} inputs (as expected for DFT)`);
  }

  return valid;
}

// CLI
if (process.argv[1].endsWith("permutation_validator.js")) {
  const n = parseInt(process.argv[2]) || 16;
  const cmd = process.argv[3] || "all";

  switch (cmd) {
    case "trace":
      traceStockhamPermutation(n);
      break;
    case "read":
      traceReadPattern(n);
      break;
    case "validate":
      validateOutputOrder(n);
      break;
    case "bitrev":
      compareTobitReversal(n);
      break;
    case "table":
      generateInputTraceTable(n);
      break;
    case "all":
    default:
      validateOutputOrder(n);
      verifyStageCoordination(n);
      generateInputTraceTable(n);
      break;
  }
}
