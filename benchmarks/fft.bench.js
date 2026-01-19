/**
 * FFT Performance Benchmarks
 *
 * Compares our WAT/WASM FFT implementations against popular JS libraries:
 * - fft.js (indutny) - Fastest pure JS, Radix-4 implementation
 * - fft-js - Simple Cooley-Tukey implementation
 * - wat-fft (WASM) - Our original Radix-2 implementation
 * - wat-fft-fast (WASM) - Our optimized Radix-4 with precomputed twiddles
 */

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import FFT from 'fft.js';
import * as fftJs from 'fft-js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Load our original WASM FFT (Radix-2)
async function loadWasmFFT() {
  const wasmPath = path.join(__dirname, '..', 'dist', 'combined.wasm');
  const wasmBuffer = fs.readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);
  const instance = await WebAssembly.instantiate(wasmModule);
  return instance.exports;
}

// Load our fast WASM FFT (precomputed twiddles)
async function loadFastWasmFFT() {
  const wasmPath = path.join(__dirname, '..', 'dist', 'combined_fast.wasm');
  const wasmBuffer = fs.readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);
  const instance = await WebAssembly.instantiate(wasmModule, {
    math: { sin: Math.sin, cos: Math.cos }
  });
  return instance.exports;
}

// Load our SIMD WASM FFT
async function loadSimdWasmFFT() {
  const wasmPath = path.join(__dirname, '..', 'dist', 'combined_simd.wasm');
  const wasmBuffer = fs.readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);
  const instance = await WebAssembly.instantiate(wasmModule, {
    math: { sin: Math.sin, cos: Math.cos }
  });
  return instance.exports;
}

// Load our Radix-4 WASM FFT
async function loadRadix4WasmFFT() {
  const wasmPath = path.join(__dirname, '..', 'dist', 'combined_radix4.wasm');
  const wasmBuffer = fs.readFileSync(wasmPath);
  const wasmModule = await WebAssembly.compile(wasmBuffer);
  const instance = await WebAssembly.instantiate(wasmModule, {
    math: { sin: Math.sin, cos: Math.cos }
  });
  return instance.exports;
}

// Benchmark configuration
const WARMUP_ITERATIONS = 100;
const BENCHMARK_DURATION_MS = 2000; // Run each benchmark for 2 seconds
const SIZES = [64, 256, 1024, 4096];

// Generate random complex input data
function generateComplexInput(n) {
  const real = new Float64Array(n);
  const imag = new Float64Array(n);
  for (let i = 0; i < n; i++) {
    real[i] = Math.random() * 2 - 1;
    imag[i] = Math.random() * 2 - 1;
  }
  return { real, imag };
}

// Benchmark runner - runs for a fixed duration and counts operations
function runBenchmark(name, setupFn, benchFn, teardownFn = null) {
  // Warmup
  const ctx = setupFn();
  for (let i = 0; i < WARMUP_ITERATIONS; i++) {
    benchFn(ctx);
  }
  if (teardownFn) teardownFn(ctx);

  // Actual benchmark
  const freshCtx = setupFn();
  const startTime = performance.now();
  let iterations = 0;

  while (performance.now() - startTime < BENCHMARK_DURATION_MS) {
    benchFn(freshCtx);
    iterations++;
  }

  const endTime = performance.now();
  const elapsed = endTime - startTime;
  const opsPerSec = (iterations / elapsed) * 1000;

  if (teardownFn) teardownFn(freshCtx);

  return { name, iterations, elapsed, opsPerSec };
}

// Format number with thousands separator
function formatNumber(num) {
  return num.toLocaleString('en-US', { maximumFractionDigits: 0 });
}

// Main benchmark suite
async function runBenchmarks() {
  console.log('='.repeat(70));
  console.log('FFT Performance Benchmarks');
  console.log('='.repeat(70));
  console.log(`Duration: ${BENCHMARK_DURATION_MS}ms per test`);
  console.log(`Warmup: ${WARMUP_ITERATIONS} iterations`);
  console.log('');

  const wasmExports = await loadWasmFFT();
  const fastWasmExports = await loadFastWasmFFT();
  const simdWasmExports = await loadSimdWasmFFT();
  const radix4WasmExports = await loadRadix4WasmFFT();

  for (const size of SIZES) {
    console.log('-'.repeat(70));
    console.log(`FFT Size: N=${size}`);
    console.log('-'.repeat(70));

    const input = generateComplexInput(size);
    const results = [];

    // 1. Our original WASM FFT (Radix-2)
    const wasmResult = runBenchmark(
      'wat-fft (Radix-2)',
      () => {
        const memory = wasmExports.memory;
        const data = new Float64Array(memory.buffer, 0, size * 2);
        // Copy input to WASM memory
        for (let i = 0; i < size; i++) {
          data[i * 2] = input.real[i];
          data[i * 2 + 1] = input.imag[i];
        }
        return { data, size };
      },
      (ctx) => {
        // Reset input before each FFT (since it's in-place)
        for (let i = 0; i < ctx.size; i++) {
          ctx.data[i * 2] = input.real[i];
          ctx.data[i * 2 + 1] = input.imag[i];
        }
        wasmExports.fft(ctx.size);
      }
    );
    results.push(wasmResult);

    // 2. Our fast WASM FFT (precomputed twiddles)
    const fastWasmResult = runBenchmark(
      'wat-fft (fast)',
      () => {
        const memory = fastWasmExports.memory;
        const data = new Float64Array(memory.buffer, 0, size * 2);
        // Precompute twiddle factors once
        fastWasmExports.precompute_twiddles(size);
        // Prepare interleaved input buffer for fast copy
        const inputBuffer = new Float64Array(size * 2);
        for (let i = 0; i < size; i++) {
          inputBuffer[i * 2] = input.real[i];
          inputBuffer[i * 2 + 1] = input.imag[i];
        }
        return { data, inputBuffer, size };
      },
      (ctx) => {
        // Fast copy using TypedArray.set
        ctx.data.set(ctx.inputBuffer);
        fastWasmExports.fft_fast(ctx.size);
      }
    );
    results.push(fastWasmResult);

    // 3. Our SIMD WASM FFT (v128 parallel complex ops)
    const simdWasmResult = runBenchmark(
      'wat-fft (SIMD)',
      () => {
        const memory = simdWasmExports.memory;
        const data = new Float64Array(memory.buffer, 0, size * 2);
        // Precompute twiddle factors once
        simdWasmExports.precompute_twiddles(size);
        // Prepare interleaved input buffer for fast copy
        const inputBuffer = new Float64Array(size * 2);
        for (let i = 0; i < size; i++) {
          inputBuffer[i * 2] = input.real[i];
          inputBuffer[i * 2 + 1] = input.imag[i];
        }
        return { data, inputBuffer, size };
      },
      (ctx) => {
        // Fast copy using TypedArray.set (zero-copy style)
        ctx.data.set(ctx.inputBuffer);
        simdWasmExports.fft_simd(ctx.size);
      }
    );
    results.push(simdWasmResult);

    // 4. Our Radix-4 WASM FFT (true Radix-4 algorithm with SIMD)
    const radix4WasmResult = runBenchmark(
      'wat-fft (Radix-4)',
      () => {
        const memory = radix4WasmExports.memory;
        const data = new Float64Array(memory.buffer, 0, size * 2);
        // Precompute twiddle factors once
        radix4WasmExports.precompute_twiddles(size);
        // Prepare interleaved input buffer for fast copy
        const inputBuffer = new Float64Array(size * 2);
        for (let i = 0; i < size; i++) {
          inputBuffer[i * 2] = input.real[i];
          inputBuffer[i * 2 + 1] = input.imag[i];
        }
        return { data, inputBuffer, size };
      },
      (ctx) => {
        ctx.data.set(ctx.inputBuffer);
        radix4WasmExports.fft_radix4(ctx.size);
      }
    );
    results.push(radix4WasmResult);

    // 5. fft.js (indutny) - Radix-4, highly optimized
    const fftJsResult = runBenchmark(
      'fft.js (Radix-4)',
      () => {
        const fft = new FFT(size);
        const out = fft.createComplexArray();
        // fft.js expects interleaved [re, im, re, im, ...]
        const complexInput = fft.createComplexArray();
        for (let i = 0; i < size; i++) {
          complexInput[i * 2] = input.real[i];
          complexInput[i * 2 + 1] = input.imag[i];
        }
        return { fft, complexInput, out };
      },
      (ctx) => {
        ctx.fft.transform(ctx.out, ctx.complexInput);
      }
    );
    results.push(fftJsResult);

    // 6. fft-js - Simple Cooley-Tukey
    const fftJsSimpleResult = runBenchmark(
      'fft-js (Cooley-Tukey)',
      () => {
        // fft-js expects array of [real, imag] pairs
        const signal = [];
        for (let i = 0; i < size; i++) {
          signal.push([input.real[i], input.imag[i]]);
        }
        return { signal };
      },
      (ctx) => {
        fftJs.fft(ctx.signal);
      }
    );
    results.push(fftJsSimpleResult);

    // Sort by performance (highest ops/sec first)
    results.sort((a, b) => b.opsPerSec - a.opsPerSec);
    const fastest = results[0].opsPerSec;

    // Print results
    console.log('');
    console.log('Library                   ops/sec        relative');
    console.log('─'.repeat(50));

    for (const result of results) {
      const relative = result.opsPerSec / fastest;
      const relativeStr = relative === 1 ? '(fastest)' : `${(relative * 100).toFixed(1)}%`;
      const bar = '█'.repeat(Math.round(relative * 20));
      console.log(
        `${result.name.padEnd(22)} ${formatNumber(result.opsPerSec).padStart(10)}    ${relativeStr.padStart(10)}  ${bar}`
      );
    }
    console.log('');
  }

  console.log('='.repeat(70));
  console.log('Benchmark complete!');
  console.log('');
  console.log('Notes:');
  console.log('- wat-fft (Radix-2): Original WASM, Taylor series sin/cos');
  console.log('- wat-fft (fast): Precomputed twiddles via JS Math');
  console.log('- wat-fft (SIMD): v128 parallel complex ops + precomputed twiddles');
  console.log('- wat-fft (Radix-4): True Radix-4 with digit reversal + SIMD');
  console.log('- fft.js: Highly optimized Radix-4 JS (Fedor Indutny)');
  console.log('- fft-js: Simple Cooley-Tukey JS (educational)');
  console.log('='.repeat(70));
}

runBenchmarks().catch(console.error);
