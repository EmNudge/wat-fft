/**
 * Component Model Test Suite
 *
 * Tests FFT components with mocked dependencies to demonstrate
 * isolated unit testing capabilities enabled by the Component Model.
 * This allows testing:
 * - Components with custom sin/cos implementations
 * - Components with mocked reverse-bits to verify integration
 * - Individual component behavior without external dependencies
 */

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  loadCoreModule,
  loadFFTComponent,
  createStockhamImports,
  createFastImports,
  writeComplexArray,
  readComplexArray,
  compareResults,
} from "./component-utils.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Reference DFT for verification
function referenceDFT(real, imag) {
  const n = real.length;
  const outReal = new Float64Array(n);
  const outImag = new Float64Array(n);

  for (let k = 0; k < n; k++) {
    let sumReal = 0;
    let sumImag = 0;
    for (let j = 0; j < n; j++) {
      const angle = (-2 * Math.PI * k * j) / n;
      sumReal += real[j] * Math.cos(angle) - imag[j] * Math.sin(angle);
      sumImag += real[j] * Math.sin(angle) + imag[j] * Math.cos(angle);
    }
    outReal[k] = sumReal;
    outImag[k] = sumImag;
  }

  return { real: outReal, imag: outImag };
}

// Test results tracking
let totalTests = 0;
let passedTests = 0;
const failedTests = [];

function test(name, fn) {
  totalTests++;
  try {
    fn();
    passedTests++;
    process.stdout.write(".");
  } catch (e) {
    failedTests.push({ name, error: e.message });
    process.stdout.write("F");
  }
}

async function testAsync(name, fn) {
  totalTests++;
  try {
    await fn();
    passedTests++;
    process.stdout.write(".");
  } catch (e) {
    failedTests.push({ name, error: e.message });
    process.stdout.write("F");
  }
}

function assertEqual(actual, expected, msg = "") {
  if (actual !== expected) {
    throw new Error(`${msg}: expected ${expected}, got ${actual}`);
  }
}

function assertApprox(actual, expected, tolerance = 1e-10, msg = "") {
  if (Math.abs(actual - expected) > tolerance) {
    throw new Error(
      `${msg}: expected ~${expected}, got ${actual} (diff: ${Math.abs(actual - expected)})`,
    );
  }
}

function assertArrayApprox(actual, expected, tolerance = 1e-10, msg = "") {
  if (actual.length !== expected.length) {
    throw new Error(`${msg}: length mismatch ${actual.length} vs ${expected.length}`);
  }
  for (let i = 0; i < actual.length; i++) {
    if (Math.abs(actual[i] - expected[i]) > tolerance) {
      throw new Error(`${msg}[${i}]: expected ~${expected[i]}, got ${actual[i]}`);
    }
  }
}

// Check if core modules exist
function coreModuleExists(name) {
  const corePath = path.join(__dirname, "..", "build", `${name}.core.wasm`);
  return fs.existsSync(corePath);
}

console.log("=".repeat(70));
console.log("Component Model Test Suite");
console.log("=".repeat(70));
console.log("");

// Test 1: Load stockham with JS Math imports
console.log("Testing fft_stockham with JS Math imports...");

if (coreModuleExists("fft_stockham")) {
  await testAsync("stockham: loads with createStockhamImports", async () => {
    const imports = createStockhamImports();
    const instance = await loadCoreModule("fft_stockham", imports);
    assertEqual(typeof instance.exports["fft-stockham"], "function");
    assertEqual(typeof instance.exports["precompute-twiddles"], "function");
  });

  await testAsync("stockham: impulse response", async () => {
    const imports = createStockhamImports();
    const instance = await loadCoreModule("fft_stockham", imports);
    const memory = instance.exports.memory;
    const precompute = instance.exports["precompute-twiddles"];
    const fft = instance.exports["fft-stockham"];

    const n = 8;
    const real = [1, 0, 0, 0, 0, 0, 0, 0];
    writeComplexArray(memory, real);

    precompute(n);
    fft(n);

    const result = readComplexArray(memory, n);
    // Impulse -> all ones in frequency domain
    for (let i = 0; i < n; i++) {
      assertApprox(result.real[i], 1, 1e-10, `real[${i}]`);
      assertApprox(result.imag[i], 0, 1e-10, `imag[${i}]`);
    }
  });

  await testAsync("stockham: random input matches reference DFT", async () => {
    const imports = createStockhamImports();
    const instance = await loadCoreModule("fft_stockham", imports);
    const memory = instance.exports.memory;
    const precompute = instance.exports["precompute-twiddles"];
    const fft = instance.exports["fft-stockham"];

    const n = 16;
    const real = Array.from({ length: n }, () => Math.random() * 2 - 1);
    const imag = Array.from({ length: n }, () => Math.random() * 2 - 1);

    writeComplexArray(memory, real, imag);
    precompute(n);
    fft(n);

    const result = readComplexArray(memory, n);
    const expected = referenceDFT(real, imag);

    // Tolerance: 1e-8 for Taylor series trig (see fft_stockham.wat)
    // Taylor series provides ~1e-10 accuracy per operation; 1e-8 allows for
    // accumulation through log2(16)=4 butterfly stages with safety margin
    assertArrayApprox(result.real, Array.from(expected.real), 1e-8, "real");
    assertArrayApprox(result.imag, Array.from(expected.imag), 1e-8, "imag");
  });

  // Test that stockham is self-contained (uses inline Taylor series sin/cos)
  await testAsync("stockham: works without external trig imports (self-contained)", async () => {
    // Stockham now uses inline Taylor series - no JS sin/cos needed
    // Load with empty imports to verify self-containment
    const instance = await loadCoreModule("fft_stockham", {});
    const memory = instance.exports.memory;
    const precompute = instance.exports["precompute-twiddles"];
    const fft = instance.exports["fft-stockham"];

    const n = 8;
    const real = [1, 2, 3, 4, 5, 6, 7, 8];
    writeComplexArray(memory, real);

    precompute(n);
    fft(n);

    const result = readComplexArray(memory, n);
    const expected = referenceDFT(
      real,
      Array.from({ length: n }, () => 0),
    );

    // Verify it produces correct results without external imports
    // Tolerance: 1e-8 for inline Taylor series (see fft_stockham.wat for derivation)
    assertArrayApprox(result.real, Array.from(expected.real), 1e-8, "real");
    assertArrayApprox(result.imag, Array.from(expected.imag), 1e-8, "imag");
  });
} else {
  console.log("  (skipped - fft_stockham.core.wasm not found)");
}
console.log("");

// Test 2: Test fast variant (self-contained with internal swap and reverse-bits)
console.log("Testing fft_fast (self-contained module)...");

if (coreModuleExists("fft_fast")) {
  await testAsync("fast: loads with createFastImports", async () => {
    const imports = createFastImports();
    const instance = await loadCoreModule("fft_fast", imports);
    assertEqual(typeof instance.exports["fft-fast"], "function");
    assertEqual(typeof instance.exports["precompute-twiddles"], "function");
  });

  await testAsync("fast: random input matches reference DFT", async () => {
    const { exports, memory } = await loadFFTComponent("fast");
    const precompute = exports["precompute-twiddles"];
    const fft = exports["fft-fast"];

    const n = 16;
    const real = Array.from({ length: n }, () => Math.random() * 2 - 1);
    const imag = Array.from({ length: n }, () => Math.random() * 2 - 1);

    writeComplexArray(memory, real, imag);
    precompute(n);
    fft(n);

    const result = readComplexArray(memory, n);
    const expected = referenceDFT(real, imag);

    assertArrayApprox(result.real, Array.from(expected.real), 1e-10, "real");
    assertArrayApprox(result.imag, Array.from(expected.imag), 1e-10, "imag");
  });
} else {
  console.log("  (skipped - fft_fast.core.wasm not found)");
}
console.log("");

// Test 3: Demonstrate mocking for fault injection (using fft_fast which still accepts trig imports)
console.log("Testing fault injection via mocks...");

if (coreModuleExists("fft_fast")) {
  await testAsync("fast: detects incorrect sin implementation via output comparison", async () => {
    // Use slightly wrong sin to demonstrate detection
    const badImports = createFastImports({
      sin: (x) => Math.sin(x) * 1.001, // 0.1% error
    });

    const instance = await loadCoreModule("fft_fast", badImports);
    const memory = instance.exports.memory;
    const precompute = instance.exports["precompute-twiddles"];
    const fft = instance.exports["fft-fast"];

    const n = 8;
    const real = [1, 2, 3, 4, 5, 6, 7, 8];
    writeComplexArray(memory, real);

    precompute(n);
    fft(n);

    const result = readComplexArray(memory, n);
    const expected = referenceDFT(
      real,
      Array.from({ length: n }, () => 0),
    );

    // This should NOT match perfectly due to injected fault
    let hasError = false;
    for (let i = 0; i < n; i++) {
      if (
        Math.abs(result.real[i] - expected.real[i]) > 1e-10 ||
        Math.abs(result.imag[i] - expected.imag[i]) > 1e-10
      ) {
        hasError = true;
        break;
      }
    }

    if (!hasError) {
      throw new Error("Expected error to be detected with faulty sin");
    }
  });
}
console.log("");

// Test 4: Verify helper utilities
console.log("Testing helper utilities...");

test("writeComplexArray/readComplexArray roundtrip", () => {
  const buffer = new ArrayBuffer(1024);
  const memory = { buffer };

  const real = [1.5, 2.5, 3.5, 4.5];
  const imag = [0.1, 0.2, 0.3, 0.4];

  writeComplexArray(memory, real, imag);
  const result = readComplexArray(memory, 4);

  assertArrayApprox(result.real, real, 1e-15, "real roundtrip");
  assertArrayApprox(result.imag, imag, 1e-15, "imag roundtrip");
});

test("writeComplexArray defaults imag to zeros", () => {
  const buffer = new ArrayBuffer(1024);
  const memory = { buffer };

  const real = [1, 2, 3, 4];
  writeComplexArray(memory, real);
  const result = readComplexArray(memory, 4);

  assertArrayApprox(result.real, real, 1e-15, "real");
  assertArrayApprox(result.imag, [0, 0, 0, 0], 1e-15, "imag should be zeros");
});

test("compareResults returns true for matching arrays", () => {
  const a = [1, 2, 3, 4];
  const b = [1, 2, 3, 4];
  assertEqual(compareResults(a, b), true, "identical arrays");
});

test("compareResults returns false for mismatched arrays", () => {
  const a = [1, 2, 3, 4];
  const b = [1, 2, 3, 5];
  assertEqual(compareResults(a, b), false, "different arrays");
});

test("compareResults respects tolerance", () => {
  const a = [1.0];
  const b = [1.0000001];
  assertEqual(compareResults(a, b, 1e-6), true, "within tolerance");
  assertEqual(compareResults(a, b, 1e-8), false, "outside tolerance");
});
console.log("");

// Summary
console.log("");
console.log("=".repeat(70));
console.log(`Results: ${passedTests}/${totalTests} passed`);
console.log("=".repeat(70));

if (failedTests.length > 0) {
  console.log("");
  console.log("FAILURES:");
  for (const { name, error } of failedTests) {
    console.log(`  ✗ ${name}`);
    console.log(`    ${error}`);
  }
  process.exit(1);
} else {
  console.log("");
  console.log("All component tests passed!");
  process.exit(0);
}
