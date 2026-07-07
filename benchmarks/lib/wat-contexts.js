/**
 * Node-side wat-fft benchmark contexts, driven by the shared surface
 * registry (benchmarks/shared/wat-surfaces.mjs).
 *
 * Bench files call createWatBenchContexts(surfaceId, size, options) and get
 * one { name, setup, bench } per registry entry, ready to hand to the
 * harness's runBenchmark(). Input staging is charged inside bench() for
 * every layout (one .set() worth of bytes), matching how competitor
 * contexts are measured.
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";
import { watEntriesFor } from "../shared/wat-surfaces.mjs";
import { seededRandom } from "./harness.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const DIST_DIR = path.join(__dirname, "..", "..", "dist");

const moduleCache = new Map();

export async function loadWatModule(moduleFile) {
  if (!moduleCache.has(moduleFile)) {
    const buffer = fs.readFileSync(path.join(DIST_DIR, moduleFile));
    const wasmModule = await WebAssembly.compile(buffer);
    const instance = await WebAssembly.instantiate(wasmModule, {});
    moduleCache.set(moduleFile, instance.exports);
  }
  return moduleCache.get(moduleFile);
}

/** Seeded complex input in every representation the layouts need. */
export function generateComplexInputs(n) {
  const rand = seededRandom(n);
  const interleaved64 = new Float64Array(n * 2);
  const interleaved32 = new Float32Array(n * 2);
  const re64 = new Float64Array(n);
  const im64 = new Float64Array(n);
  const re32 = new Float32Array(n);
  const im32 = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    const re = rand() * 2 - 1;
    const im = rand() * 2 - 1;
    interleaved64[i * 2] = re;
    interleaved64[i * 2 + 1] = im;
    interleaved32[i * 2] = re;
    interleaved32[i * 2 + 1] = im;
    re64[i] = re;
    im64[i] = im;
    re32[i] = re;
    im32[i] = im;
  }
  return { interleaved64, interleaved32, re64, im64, re32, im32 };
}

/** Seeded real input (f64 + f32 views of the same values). */
export function generateRealInputs(n) {
  const rand = seededRandom(n);
  const real64 = new Float64Array(n);
  const real32 = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    const v = rand() * 2 - 1;
    real64[i] = v;
    real32[i] = v;
  }
  return { real64, real32 };
}

function globalValue(g) {
  return typeof g === "number" ? g : g.value;
}

/**
 * Build harness-ready benchmark contexts for every registry entry of a
 * surface that supports `size` (and matches `precisions`, if given).
 *
 * `input` is the object from generateComplexInputs / generateRealInputs;
 * pass the same values to competitor contexts for a fair comparison.
 *
 * Returns [{ name, entry, setup, bench }] for use as
 *   runBenchmark(ctx.name, ctx.setup, ctx.bench)
 */
export async function createWatBenchContexts(surfaceId, size, { precisions, input } = {}) {
  const entries = watEntriesFor(surfaceId, { size, precisions });
  const contexts = [];

  for (const entry of entries) {
    const exports = await loadWatModule(entry.module);
    const FloatArray = entry.precision === "f32" ? Float32Array : Float64Array;

    let setup;
    let bench;

    switch (entry.layout) {
      case "complex-interleaved": {
        const src = entry.precision === "f32" ? input.interleaved32 : input.interleaved64;
        setup = () => {
          exports[entry.precompute](size);
          const data = new FloatArray(exports.memory.buffer, 0, size * 2);
          return { data, src };
        };
        bench = (ctx) => {
          ctx.data.set(ctx.src);
          exports[entry.run](size);
        };
        break;
      }

      case "complex-split": {
        setup = () => {
          exports[entry.precompute](size);
          const realData = new FloatArray(
            exports.memory.buffer,
            globalValue(exports.REAL_OFFSET),
            size,
          );
          const imagData = new FloatArray(
            exports.memory.buffer,
            globalValue(exports.IMAG_OFFSET),
            size,
          );
          return { realData, imagData, re: input.re32, im: input.im32 };
        };
        bench = (ctx) => {
          ctx.realData.set(ctx.re);
          ctx.imagData.set(ctx.im);
          exports[entry.run](size);
        };
        break;
      }

      case "real-packed": {
        const src = entry.precision === "f32" ? input.real32 : input.real64;
        setup = () => {
          exports[entry.precompute](size);
          const data = new FloatArray(exports.memory.buffer, 0, size);
          return { data, src };
        };
        bench = (ctx) => {
          ctx.data.set(ctx.src);
          exports[entry.run](size);
        };
        break;
      }

      case "real-spectrum": {
        // Input is a Hermitian spectrum (N/2+1 interleaved bins = N+2
        // floats), produced once by the module's own forward transform.
        const src = entry.precision === "f32" ? input.real32 : input.real64;
        setup = () => {
          exports[entry.precompute](size);
          new FloatArray(exports.memory.buffer, 0, size).set(src);
          exports[entry.spectrumVia](size);
          const data = new FloatArray(exports.memory.buffer, 0, size + 2);
          const spectrum = new FloatArray(size + 2);
          spectrum.set(data);
          return { data, spectrum };
        };
        bench = (ctx) => {
          ctx.data.set(ctx.spectrum);
          exports[entry.run](size);
        };
        break;
      }

      default:
        throw new Error(`Unknown layout "${entry.layout}" for ${entry.name}`);
    }

    contexts.push({ name: entry.name, entry, setup, bench });
  }

  return contexts;
}
