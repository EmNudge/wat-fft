/**
 * Property-Based Tests for FFT Implementations
 *
 * Tests mathematical invariants that must hold for any correct FFT:
 * - Parseval's theorem (energy preservation)
 * - Linearity
 * - Inverse property (IFFT(FFT(x)) = x)
 * - Conjugate symmetry for real inputs
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import fc from "fast-check";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Valid FFT sizes (powers of 2)
const FFT_SIZES = [16, 32, 64, 128, 256];
const STOCKHAM_SIZES = [4, 8, 16]; // Stockham only works for N≤16

// Implementations to test
const IMPLEMENTATIONS = [
  {
    name: "stockham",
    wasmName: "stockham",
    fftFunc: "fft_stockham",
    precompute: true,
    sizes: STOCKHAM_SIZES,
  },
  { name: "fast", wasmName: "fast", fftFunc: "fft_fast", precompute: true, sizes: FFT_SIZES },
];

// Load WASM module
async function loadWasm(name) {
  const wasmPath = path.join(__dirname, "..", "dist", `combined_${name}.wasm`);
  if (!fs.existsSync(wasmPath)) {
    return null;
  }
  const wasmBuffer = fs.readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);
  const instance = await WebAssembly.instantiate(wasmModule, {
    math: { sin: Math.sin, cos: Math.cos },
  });
  return instance.exports;
}

// Run FFT and return results (doesn't mutate input)
function runFFT(wasm, fftFunc, real, imag, precompute) {
  const n = real.length;
  const memory = wasm.memory;
  const data = new Float64Array(memory.buffer, 0, n * 2);

  // Copy input to WASM memory
  for (let i = 0; i < n; i++) {
    data[i * 2] = real[i];
    data[i * 2 + 1] = imag[i];
  }

  if (precompute && wasm.precompute_twiddles) {
    wasm.precompute_twiddles(n);
  }

  wasm[fftFunc](n);

  // Extract results
  const resultData = new Float64Array(memory.buffer, 0, n * 2);
  const outReal = new Float64Array(n);
  const outImag = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    outReal[i] = resultData[i * 2];
    outImag[i] = resultData[i * 2 + 1];
  }

  return { real: outReal, imag: outImag };
}

// Compute IFFT using FFT: conjugate, FFT, conjugate, scale
function runIFFT(wasm, fftFunc, real, imag, precompute) {
  const n = real.length;

  // Conjugate input
  const conjImag = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    conjImag[i] = -imag[i];
  }

  // Run FFT on conjugated input
  const result = runFFT(wasm, fftFunc, real, conjImag, precompute);

  // Conjugate and scale output
  for (let i = 0; i < n; i++) {
    result.real[i] = result.real[i] / n;
    result.imag[i] = -result.imag[i] / n;
  }

  return result;
}

// Compute energy (sum of squared magnitudes)
function computeEnergy(real, imag) {
  let energy = 0;
  for (let i = 0; i < real.length; i++) {
    energy += real[i] * real[i] + imag[i] * imag[i];
  }
  return energy;
}

// Check if two values are approximately equal
function approxEqual(a, b, tolerance = 1e-9) {
  return Math.abs(a - b) <= tolerance * Math.max(1, Math.abs(a), Math.abs(b));
}

// Check if two arrays are approximately equal
function arraysApproxEqual(arr1, arr2, tolerance = 1e-9) {
  if (arr1.length !== arr2.length) return false;
  for (let i = 0; i < arr1.length; i++) {
    if (!approxEqual(arr1[i], arr2[i], tolerance)) {
      return false;
    }
  }
  return true;
}

// Arbitrary for generating complex arrays of given size
function complexArrayArb(size) {
  return fc
    .tuple(
      fc.float64Array({
        minLength: size,
        maxLength: size,
        noNaN: true,
        noDefaultInfinity: true,
        min: -1e6,
        max: 1e6,
      }),
      fc.float64Array({
        minLength: size,
        maxLength: size,
        noNaN: true,
        noDefaultInfinity: true,
        min: -1e6,
        max: 1e6,
      }),
    )
    .map(([real, imag]) => ({ real: new Float64Array(real), imag: new Float64Array(imag) }));
}

// Arbitrary for generating real-only arrays (imag = 0)
function realArrayArb(size) {
  return fc
    .float64Array({
      minLength: size,
      maxLength: size,
      noNaN: true,
      noDefaultInfinity: true,
      min: -1e6,
      max: 1e6,
    })
    .map((real) => ({ real: new Float64Array(real), imag: new Float64Array(size).fill(0) }));
}

// Arbitrary for scalar values
const scalarArb = fc.double({ min: -100, max: 100, noNaN: true, noDefaultInfinity: true });

// Main test runner
async function runPropertyTests() {
  console.log("=".repeat(70));
  console.log("FFT Property-Based Tests");
  console.log("=".repeat(70));
  console.log("");

  // Load all WASM modules
  const modules = {};
  for (const impl of IMPLEMENTATIONS) {
    modules[impl.name] = await loadWasm(impl.wasmName);
    if (!modules[impl.name]) {
      console.log(`⚠ Skipping ${impl.name}: WASM not found`);
    }
  }
  console.log("");

  let allPassed = true;

  for (const impl of IMPLEMENTATIONS) {
    const wasm = modules[impl.name];
    if (!wasm) continue;

    console.log(`Testing: ${impl.name}`);
    console.log("-".repeat(40));

    const sizes = impl.sizes || FFT_SIZES;
    for (const size of sizes) {
      console.log(`  N=${size}`);

      // Property 1: Parseval's Theorem
      // Energy in time domain = (1/N) * Energy in frequency domain
      try {
        fc.assert(
          fc.property(complexArrayArb(size), (input) => {
            const output = runFFT(wasm, impl.fftFunc, input.real, input.imag, impl.precompute);
            const timeEnergy = computeEnergy(input.real, input.imag);
            const freqEnergy = computeEnergy(output.real, output.imag) / size;
            return approxEqual(timeEnergy, freqEnergy, 1e-8);
          }),
          { numRuns: 50, verbose: false },
        );
        process.stdout.write("    Parseval: ✓\n");
      } catch (e) {
        process.stdout.write("    Parseval: ✗\n");
        console.log(`      ${e.message.split("\n")[0]}`);
        allPassed = false;
      }

      // Property 2: Inverse Property
      // IFFT(FFT(x)) = x
      try {
        fc.assert(
          fc.property(complexArrayArb(size), (input) => {
            const transformed = runFFT(wasm, impl.fftFunc, input.real, input.imag, impl.precompute);
            const recovered = runIFFT(
              wasm,
              impl.fftFunc,
              transformed.real,
              transformed.imag,
              impl.precompute,
            );
            return (
              arraysApproxEqual(input.real, recovered.real, 1e-8) &&
              arraysApproxEqual(input.imag, recovered.imag, 1e-8)
            );
          }),
          { numRuns: 50, verbose: false },
        );
        process.stdout.write("    Inverse: ✓\n");
      } catch (e) {
        process.stdout.write("    Inverse: ✗\n");
        console.log(`      ${e.message.split("\n")[0]}`);
        allPassed = false;
      }

      // Property 3: Linearity
      // FFT(a*x + b*y) = a*FFT(x) + b*FFT(y)
      try {
        fc.assert(
          fc.property(
            complexArrayArb(size),
            complexArrayArb(size),
            scalarArb,
            scalarArb,
            (x, y, a, b) => {
              // Compute FFT(a*x + b*y)
              const combined = {
                real: new Float64Array(size),
                imag: new Float64Array(size),
              };
              for (let i = 0; i < size; i++) {
                combined.real[i] = a * x.real[i] + b * y.real[i];
                combined.imag[i] = a * x.imag[i] + b * y.imag[i];
              }
              const fftCombined = runFFT(
                wasm,
                impl.fftFunc,
                combined.real,
                combined.imag,
                impl.precompute,
              );

              // Compute a*FFT(x) + b*FFT(y)
              const fftX = runFFT(wasm, impl.fftFunc, x.real, x.imag, impl.precompute);
              const fftY = runFFT(wasm, impl.fftFunc, y.real, y.imag, impl.precompute);
              const linearCombined = {
                real: new Float64Array(size),
                imag: new Float64Array(size),
              };
              for (let i = 0; i < size; i++) {
                linearCombined.real[i] = a * fftX.real[i] + b * fftY.real[i];
                linearCombined.imag[i] = a * fftX.imag[i] + b * fftY.imag[i];
              }

              return (
                arraysApproxEqual(fftCombined.real, linearCombined.real, 1e-6) &&
                arraysApproxEqual(fftCombined.imag, linearCombined.imag, 1e-6)
              );
            },
          ),
          { numRuns: 30, verbose: false },
        );
        process.stdout.write("    Linearity: ✓\n");
      } catch (e) {
        process.stdout.write("    Linearity: ✗\n");
        console.log(`      ${e.message.split("\n")[0]}`);
        allPassed = false;
      }

      // Property 4: Conjugate Symmetry for Real Input
      // If x is real, then X[k] = conj(X[N-k])
      try {
        fc.assert(
          fc.property(realArrayArb(size), (input) => {
            const output = runFFT(wasm, impl.fftFunc, input.real, input.imag, impl.precompute);

            // Check X[k] = conj(X[N-k]) for k = 1 to N/2-1
            for (let k = 1; k < size / 2; k++) {
              const kReal = output.real[k];
              const kImag = output.imag[k];
              const nkReal = output.real[size - k];
              const nkImag = output.imag[size - k];

              // X[k] should equal conj(X[N-k])
              if (!approxEqual(kReal, nkReal, 1e-8) || !approxEqual(kImag, -nkImag, 1e-8)) {
                return false;
              }
            }

            // X[0] and X[N/2] should be real for real input
            if (!approxEqual(output.imag[0], 0, 1e-8)) return false;
            if (!approxEqual(output.imag[size / 2], 0, 1e-8)) return false;

            return true;
          }),
          { numRuns: 50, verbose: false },
        );
        process.stdout.write("    Real symmetry: ✓\n");
      } catch (e) {
        process.stdout.write("    Real symmetry: ✗\n");
        console.log(`      ${e.message.split("\n")[0]}`);
        allPassed = false;
      }
    }
    console.log("");
  }

  console.log("=".repeat(70));
  if (allPassed) {
    console.log("All property tests passed!");
    process.exit(0);
  } else {
    console.log("Some property tests failed.");
    process.exit(1);
  }
}

runPropertyTests().catch((e) => {
  console.error("Test runner error:", e);
  process.exit(1);
});
