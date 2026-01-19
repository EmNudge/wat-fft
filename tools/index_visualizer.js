/**
 * Index Pattern Visualizer for FFT Algorithms
 *
 * Shows exactly which indices are read from and written to at each stage.
 * Helps identify stage coordination bugs where output of one stage
 * doesn't match expected input of the next stage.
 */

/**
 * Generate Stockham Radix-4 index patterns
 */
export function stockhamIndexPatterns(n) {
  const log2n = Math.log2(n);
  const numRadix4Stages = Math.floor(log2n / 2);
  const hasRadix2Final = log2n % 2 === 1;

  const stages = [];
  let m = 4;

  // Radix-4 stages
  for (let s = 0; s < numRadix4Stages; s++) {
    const mq = m / 4;
    const inStride = n / m;
    const butterflies = [];

    for (let j = 0; j < mq; j++) {
      for (let k = 0; k < inStride; k++) {
        // Input indices
        const i0 = k + j * inStride;
        const i1 = i0 + n / 4;
        const i2 = i1 + n / 4;
        const i3 = i2 + n / 4;

        // Output indices
        const o0 = k * m + j;
        const o1 = o0 + mq;
        const o2 = o0 + 2 * mq;
        const o3 = o0 + 3 * mq;

        butterflies.push({
          j,
          k,
          read: [i0, i1, i2, i3],
          write: [o0, o1, o2, o3],
          twiddleIndex: j > 0 ? [j * (n / m), 2 * j * (n / m), 3 * j * (n / m)] : null,
        });
      }
    }

    stages.push({
      name: `Radix-4 Stage ${s}`,
      type: "radix4",
      m,
      mq,
      inStride,
      butterflies,
    });

    m *= 4;
  }

  // Radix-2 final stage
  if (hasRadix2Final) {
    const halfN = n / 2;
    const butterflies = [];

    for (let j = 0; j < halfN; j++) {
      butterflies.push({
        j,
        k: 0,
        read: [j, j + halfN],
        write: [j, j + halfN],
        twiddleIndex: j > 0 ? [j] : null,
      });
    }

    stages.push({
      name: "Radix-2 Final",
      type: "radix2",
      butterflies,
    });
  }

  return stages;
}

/**
 * Visualize index patterns for a given N
 */
export function visualizePatterns(n, options = {}) {
  const { showAll = false, maxButterflies = 4 } = options;
  const stages = stockhamIndexPatterns(n);

  console.log(`\n${"═".repeat(70)}`);
  console.log(`Stockham FFT Index Patterns for N=${n}`);
  console.log(`${"═".repeat(70)}`);
  console.log(`Total stages: ${stages.length}`);
  console.log("");

  for (const stage of stages) {
    console.log(`${"─".repeat(70)}`);
    console.log(`${stage.name}`);
    if (stage.type === "radix4") {
      console.log(`  m=${stage.m}, mq=${stage.mq}, inStride=${stage.inStride}`);
    }
    console.log(`  Butterflies: ${stage.butterflies.length}`);
    console.log(`${"─".repeat(70)}`);

    const toShow = showAll ? stage.butterflies : stage.butterflies.slice(0, maxButterflies);

    for (const bf of toShow) {
      if (stage.type === "radix4") {
        console.log(
          `  j=${bf.j}, k=${bf.k}: read [${bf.read.join(",")}] → write [${bf.write.join(",")}]`,
        );
      } else {
        console.log(`  j=${bf.j}: read [${bf.read.join(",")}] → write [${bf.write.join(",")}]`);
      }
    }

    if (!showAll && stage.butterflies.length > maxButterflies) {
      console.log(`  ... (${stage.butterflies.length - maxButterflies} more butterflies)`);
    }
    console.log("");
  }
}

/**
 * Verify stage coordination: output positions of stage S should match
 * input positions of stage S+1
 */
export function verifyStageCoordination(n) {
  const stages = stockhamIndexPatterns(n);
  const issues = [];

  console.log(`\n${"═".repeat(70)}`);
  console.log(`Stage Coordination Check for N=${n}`);
  console.log(`${"═".repeat(70)}\n`);

  for (let s = 0; s < stages.length - 1; s++) {
    const currentStage = stages[s];
    const nextStage = stages[s + 1];

    // Collect all write positions from current stage
    const writePositions = new Set();
    for (const bf of currentStage.butterflies) {
      for (const pos of bf.write) {
        writePositions.add(pos);
      }
    }

    // Collect all read positions from next stage
    const readPositions = new Set();
    for (const bf of nextStage.butterflies) {
      for (const pos of bf.read) {
        readPositions.add(pos);
      }
    }

    // Check coverage
    const writtenNotRead = [...writePositions].filter((p) => !readPositions.has(p));
    const readNotWritten = [...readPositions].filter((p) => !writePositions.has(p));

    console.log(`${currentStage.name} → ${nextStage.name}:`);
    console.log(`  Write positions: ${writePositions.size}`);
    console.log(`  Read positions:  ${readPositions.size}`);

    if (writtenNotRead.length > 0 || readNotWritten.length > 0) {
      console.log(`  ⚠ MISMATCH:`);
      if (writtenNotRead.length > 0) {
        console.log(
          `    Written but never read: [${writtenNotRead.slice(0, 10).join(", ")}${writtenNotRead.length > 10 ? "..." : ""}]`,
        );
        issues.push({
          from: currentStage.name,
          to: nextStage.name,
          type: "written_not_read",
          positions: writtenNotRead,
        });
      }
      if (readNotWritten.length > 0) {
        console.log(
          `    Read but never written: [${readNotWritten.slice(0, 10).join(", ")}${readNotWritten.length > 10 ? "..." : ""}]`,
        );
        issues.push({
          from: currentStage.name,
          to: nextStage.name,
          type: "read_not_written",
          positions: readNotWritten,
        });
      }
    } else {
      console.log(`  ✓ All positions match`);
    }
    console.log("");
  }

  // Summary
  console.log(`${"═".repeat(70)}`);
  if (issues.length === 0) {
    console.log(`✓ All stage transitions are properly coordinated`);
  } else {
    console.log(`✗ Found ${issues.length} coordination issues`);
  }
  console.log(`${"═".repeat(70)}\n`);

  return issues;
}

/**
 * Show data flow: trace where each input element ends up
 */
export function traceDataFlow(n, inputIndex = 0) {
  const stages = stockhamIndexPatterns(n);

  console.log(`\n${"═".repeat(70)}`);
  console.log(`Data Flow Trace: N=${n}, tracking input[${inputIndex}]`);
  console.log(`${"═".repeat(70)}\n`);

  let currentPositions = new Set([inputIndex]);

  console.log(`Input: position ${inputIndex}`);

  for (const stage of stages) {
    const nextPositions = new Set();

    for (const bf of stage.butterflies) {
      // Check if any of our tracked positions are read by this butterfly
      const readIdx = bf.read.findIndex((r) => currentPositions.has(r));
      if (readIdx !== -1) {
        // This butterfly reads from one of our positions
        // In FFT, each input affects all outputs of the butterfly
        for (const out of bf.write) {
          nextPositions.add(out);
        }
      }
    }

    console.log(`\n${stage.name}:`);
    console.log(`  Input from: [${[...currentPositions].sort((a, b) => a - b).join(", ")}]`);
    console.log(`  Output to:  [${[...nextPositions].sort((a, b) => a - b).join(", ")}]`);

    currentPositions = nextPositions;
  }

  console.log(
    `\nFinal output positions: [${[...currentPositions].sort((a, b) => a - b).join(", ")}]`,
  );
  console.log("");

  return currentPositions;
}

/**
 * Generate ASCII diagram of stage index patterns
 */
export function drawStagePattern(n, stageIndex = 0) {
  const stages = stockhamIndexPatterns(n);

  if (stageIndex >= stages.length) {
    console.log(`Stage ${stageIndex} does not exist (max: ${stages.length - 1})`);
    return;
  }

  const stage = stages[stageIndex];

  console.log(`\n${stage.name} - Read/Write Pattern (N=${n}):`);
  console.log("");

  // Create mapping from write position to read positions
  const writeToRead = new Map();
  for (const bf of stage.butterflies) {
    for (let i = 0; i < bf.write.length; i++) {
      if (!writeToRead.has(bf.write[i])) {
        writeToRead.set(bf.write[i], []);
      }
      writeToRead.get(bf.write[i]).push(...bf.read);
    }
  }

  // Draw the pattern
  const width = Math.min(n, 32);
  console.log("Read indices:");
  console.log("  " + Array.from({ length: width }, (_, i) => i.toString().padStart(3)).join(""));

  console.log("\nWrite indices:");
  for (let w = 0; w < Math.min(n, 16); w++) {
    const reads = writeToRead.get(w) || [];
    const readStr = reads
      .slice(0, 4)
      .map((r) => r.toString().padStart(2))
      .join(",");
    console.log(`  [${w.toString().padStart(2)}] ← [${readStr}]`);
  }
  if (n > 16) {
    console.log(`  ... (${n - 16} more)`);
  }
  console.log("");
}

// CLI interface
if (process.argv[1].endsWith("index_visualizer.js")) {
  const n = parseInt(process.argv[2]) || 16;
  const cmd = process.argv[3] || "all";

  switch (cmd) {
    case "patterns":
      visualizePatterns(n, { showAll: process.argv.includes("--all") });
      break;
    case "verify":
      verifyStageCoordination(n);
      break;
    case "trace":
      const idx = parseInt(process.argv[4]) || 0;
      traceDataFlow(n, idx);
      break;
    case "draw":
      const stageIdx = parseInt(process.argv[4]) || 0;
      drawStagePattern(n, stageIdx);
      break;
    case "all":
    default:
      visualizePatterns(n);
      verifyStageCoordination(n);
      break;
  }
}
