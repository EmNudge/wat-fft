/**
 * Tests for bit-reversal and digit-reversal permutation algorithms
 * These are critical for FFT correctness
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import assert from "assert/strict";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Reference implementations in JS for verification
function bitReverse(x, numBits) {
  let result = 0;
  for (let i = 0; i < numBits; i++) {
    result = (result << 1) | (x & 1);
    x >>= 1;
  }
  return result;
}

function digitReverse4(x, numDigits) {
  // Reverse base-4 digits
  let result = 0;
  for (let i = 0; i < numDigits; i++) {
    result = (result << 2) | (x & 3);
    x >>= 2;
  }
  return result;
}

// Generate expected permutation for bit-reversal
function expectedBitReversalPermutation(n) {
  const log2n = Math.log2(n);
  const perm = [];
  for (let i = 0; i < n; i++) {
    perm.push(bitReverse(i, log2n));
  }
  return perm;
}

// Generate expected permutation for digit-reversal (base 4)
function expectedDigitReversalPermutation(n) {
  const log4n = Math.log2(n) / 2; // number of base-4 digits
  const perm = [];
  for (let i = 0; i < n; i++) {
    perm.push(digitReverse4(i, log4n));
  }
  return perm;
}

async function loadWasm(name) {
  const wasmPath = path.join(__dirname, "..", "dist", `${name}.wasm`);
  const wasmBuffer = fs.readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);
  const instance = await WebAssembly.instantiate(wasmModule, {
    math: { sin: Math.sin, cos: Math.cos },
  });
  return instance.exports;
}

async function runTests() {
  console.log("Running Permutation Algorithm tests...\n");

  // Test 1: Bit reversal function
  console.log("1. Testing bit_reverse function...");
  const wasm = await loadWasm("reverse_bits");

  const bitReverseCases = [
    // [input, log2n, expected]
    [0, 3, 0], // 000 -> 000
    [1, 3, 4], // 001 -> 100
    [2, 3, 2], // 010 -> 010
    [3, 3, 6], // 011 -> 110
    [4, 3, 1], // 100 -> 001
    [5, 3, 5], // 101 -> 101
    [6, 3, 3], // 110 -> 011
    [7, 3, 7], // 111 -> 111
    [0, 4, 0],
    [1, 4, 8],
    [15, 4, 15],
    [5, 4, 10], // 0101 -> 1010
  ];

  for (const [input, log2n, expected] of bitReverseCases) {
    const result = wasm.reverse_bits(input, log2n);
    assert.strictEqual(
      result,
      expected,
      `bit_reverse(${input}, ${log2n}) = ${result}, expected ${expected}`,
    );
  }
  console.log("   ✓ bit_reverse function correct\n");

  // Test 2: Full bit-reversal permutation
  console.log("2. Testing bit-reversal permutation for various sizes...");
  for (const n of [4, 8, 16, 32, 64]) {
    const expected = expectedBitReversalPermutation(n);
    const log2n = Math.log2(n);
    const actual = [];
    for (let i = 0; i < n; i++) {
      actual.push(wasm.reverse_bits(i, log2n));
    }
    assert.deepStrictEqual(actual, expected, `Bit-reversal permutation for N=${n}`);
    console.log(`   ✓ N=${n} correct`);
  }
  console.log("");

  // Test 3: Digit reversal (base-4) - JS reference first
  console.log("3. Testing digit-reversal (base-4) reference...");
  const digitReverseCases = [
    // For N=16 (2 base-4 digits)
    [0, 2, 0], // 00 -> 00
    [1, 2, 4], // 01 -> 10
    [2, 2, 8], // 02 -> 20
    [3, 2, 12], // 03 -> 30
    [4, 2, 1], // 10 -> 01
    [5, 2, 5], // 11 -> 11
    [6, 2, 9], // 12 -> 21
    [7, 2, 13], // 13 -> 31
    [8, 2, 2], // 20 -> 02
    [12, 2, 3], // 30 -> 03
    [15, 2, 15], // 33 -> 33
    // For N=64 (3 base-4 digits)
    [0, 3, 0],
    [1, 3, 16], // 001 -> 100
    [4, 3, 4], // 010 -> 010
    [16, 3, 1], // 100 -> 001
    [63, 3, 63], // 333 -> 333
  ];

  for (const [input, numDigits, expected] of digitReverseCases) {
    const result = digitReverse4(input, numDigits);
    assert.strictEqual(
      result,
      expected,
      `digitReverse4(${input}, ${numDigits}) = ${result}, expected ${expected}`,
    );
  }
  console.log("   ✓ digit-reversal reference correct\n");

  // Test 4: Full digit-reversal permutation
  console.log("4. Testing digit-reversal permutation for powers of 4...");
  for (const n of [4, 16, 64, 256]) {
    const expected = expectedDigitReversalPermutation(n);
    console.log(`   N=${n}: first 8 indices map to [${expected.slice(0, 8).join(", ")}]`);
  }
  console.log("");

  // Test 5: Verify permutation is self-inverse
  console.log("5. Verifying permutations are self-inverse (P[P[i]] = i)...");
  for (const n of [8, 16, 64]) {
    const log2n = Math.log2(n);
    for (let i = 0; i < n; i++) {
      const j = wasm.reverse_bits(i, log2n);
      const k = wasm.reverse_bits(j, log2n);
      assert.strictEqual(k, i, `bit_reverse(bit_reverse(${i})) should equal ${i}, got ${k}`);
    }
    console.log(`   ✓ N=${n} bit-reversal is self-inverse`);
  }

  for (const n of [4, 16, 64]) {
    const numDigits = Math.log2(n) / 2;
    for (let i = 0; i < n; i++) {
      const j = digitReverse4(i, numDigits);
      const k = digitReverse4(j, numDigits);
      assert.strictEqual(k, i, `digitReverse4(digitReverse4(${i})) should equal ${i}`);
    }
    console.log(`   ✓ N=${n} digit-reversal is self-inverse`);
  }
  console.log("");

  console.log("All permutation tests passed!");
}

runTests().catch((err) => {
  console.error("Test failed:", err.message);
  process.exit(1);
});
